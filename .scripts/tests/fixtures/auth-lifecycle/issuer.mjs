// Adapted from the archived auth-poc issuer at revision 50b522d.
// Only this issuer is mocked; application services are real built images.
import { createServer } from "node:http";
import {
  createHash,
  generateKeyPairSync,
  randomBytes,
  sign,
} from "node:crypto";
import { readFileSync } from "node:fs";

const issuer = "http://idp.poc.test";
const clientId = "recipe-db-auth-lifecycle";
const clientSecret = readFileSync("/run/secrets/client", "utf8").trim();
const users = {
  owner: {
    sub: "sub-owner",
    email: "owner@example.test",
    email_verified: true,
  },
  member: {
    sub: "sub-member",
    email: "member@example.test",
    email_verified: true,
  },
  outsider: {
    sub: "sub-outsider",
    email: "outsider@example.test",
    email_verified: true,
  },
  unverified: {
    sub: "sub-unverified",
    email: "member@example.test",
    email_verified: false,
  },
  revoked: {
    sub: "sub-revoked",
    email: "member@example.test",
    email_verified: true,
  },
};
const { publicKey, privateKey } = generateKeyPairSync("rsa", {
  modulusLength: 2048,
});
const jwk = {
  ...publicKey.export({ format: "jwk" }),
  kid: "lifecycle",
  alg: "RS256",
  use: "sig",
};
const codes = new Map();
const refreshTokens = new Map();
const b64 = (value) => Buffer.from(value).toString("base64url");

function tokenResponse(user, nonce, refreshed) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64(
    JSON.stringify({ alg: "RS256", typ: "JWT", kid: jwk.kid }),
  );
  const payload = b64(
    JSON.stringify({
      iss: issuer,
      aud: clientId,
      iat: now,
      exp: now + 30,
      ...(nonce ? { nonce } : {}),
      ...users[user],
    }),
  );
  const signed = `${header}.${payload}`;
  const response = {
    access_token: randomBytes(24).toString("base64url"),
    token_type: "Bearer",
    expires_in: 30,
    id_token: `${signed}.${b64(sign("RSA-SHA256", Buffer.from(signed), privateKey))}`,
  };
  if (!refreshed) {
    response.refresh_token = randomBytes(24).toString("base64url");
    refreshTokens.set(response.refresh_token, user);
  }
  return response;
}

function send(res, status, body, headers = {}) {
  const json = typeof body !== "string";
  res.writeHead(status, {
    "content-type": json ? "application/json" : "text/html; charset=utf-8",
    "cache-control": "no-store",
    ...headers,
  });
  res.end(json ? JSON.stringify(body) : body);
}

async function form(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
}

function authenticated(req, values) {
  const basic = req.headers.authorization?.match(/^Basic (.+)$/);
  if (basic) {
    const [id, secret] = Buffer.from(basic[1], "base64")
      .toString("utf8")
      .split(":")
      .map(decodeURIComponent);
    return id === clientId && secret === clientSecret;
  }
  return (
    values.get("client_id") === clientId &&
    values.get("client_secret") === clientSecret
  );
}

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, issuer);
    if (url.pathname === "/healthz") return send(res, 200, { ok: true });
    if (url.pathname === "/.well-known/openid-configuration") {
      return send(res, 200, {
        issuer,
        authorization_endpoint: `${issuer}/authorize`,
        token_endpoint: `${issuer}/token`,
        jwks_uri: `${issuer}/jwks`,
        response_types_supported: ["code"],
        subject_types_supported: ["public"],
        id_token_signing_alg_values_supported: ["RS256"],
        scopes_supported: ["openid", "email"],
        claims_supported: ["sub", "email", "email_verified"],
        code_challenge_methods_supported: ["S256"],
      });
    }
    if (url.pathname === "/jwks") return send(res, 200, { keys: [jwk] });
    if (url.pathname === "/authorize") {
      const redirect = url.searchParams.get("redirect_uri");
      if (url.searchParams.get("client_id") !== clientId || !redirect) {
        return send(res, 400, { error: "invalid_request" });
      }
      if (req.method !== "POST") return send(res, 200, "Isolated test issuer");
      const user = (await form(req)).get("user");
      if (!Object.hasOwn(users, user))
        return send(res, 400, { error: "unknown_user" });
      const code = randomBytes(16).toString("base64url");
      codes.set(code, {
        user,
        nonce: url.searchParams.get("nonce"),
        redirect,
        challenge: url.searchParams.get("code_challenge"),
      });
      const target = new URL(redirect);
      target.searchParams.set("code", code);
      target.searchParams.set("state", url.searchParams.get("state") ?? "");
      return send(res, 302, "", { location: target.toString() });
    }
    if (url.pathname === "/token" && req.method === "POST") {
      const values = await form(req);
      if (!authenticated(req, values))
        return send(res, 401, { error: "invalid_client" });
      if (values.get("grant_type") === "authorization_code") {
        const grant = codes.get(values.get("code"));
        codes.delete(values.get("code"));
        const challenge = createHash("sha256")
          .update(values.get("code_verifier") ?? "")
          .digest("base64url");
        if (
          !grant ||
          grant.redirect !== values.get("redirect_uri") ||
          grant.challenge !== challenge
        ) {
          return send(res, 400, { error: "invalid_grant" });
        }
        return send(res, 200, tokenResponse(grant.user, grant.nonce, false));
      }
      if (values.get("grant_type") === "refresh_token") {
        const user = refreshTokens.get(values.get("refresh_token"));
        if (!user || user === "revoked")
          return send(res, 400, { error: "invalid_grant" });
        return send(res, 200, tokenResponse(user, undefined, true));
      }
      return send(res, 400, { error: "unsupported_grant_type" });
    }
    return send(res, 404, { error: "not_found" });
  } catch (error) {
    console.error(error);
    send(res, 500, { error: "server_error" });
  }
}).listen(8080);

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
