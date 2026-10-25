// Deterministic, offline OIDC issuer test double. Not a production component.
import { createServer } from "node:http";
import {
  createHash,
  generateKeyPairSync,
  randomBytes,
  sign,
} from "node:crypto";
import { readFileSync } from "node:fs";

const issuer = process.env.ISSUER;
const clientId = process.env.CLIENT_ID;
const clientSecret = readFileSync(
  process.env.CLIENT_SECRET_FILE,
  "utf8",
).trim();
const tokenTtl = Number(process.env.TOKEN_TTL_SECONDS ?? "300");
const port = Number(process.env.PORT ?? "8080");

// Each identity has a stable subject. `refresh` describes claim changes on refresh.
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
  "missing-verified": {
    sub: "sub-missing-verified",
    email: "member@example.test",
  },
  "email-change": {
    sub: "sub-email-change",
    email: "member@example.test",
    email_verified: true,
    refresh: { email: "changed@example.test", email_verified: true },
  },
  "unverify-on-refresh": {
    sub: "sub-unverify-on-refresh",
    email: "member@example.test",
    email_verified: true,
    refresh: { email_verified: false },
  },
  "revoked-refresh": {
    sub: "sub-revoked-refresh",
    email: "member@example.test",
    email_verified: true,
    refresh: "invalid_grant",
  },
};

const { publicKey, privateKey } = generateKeyPairSync("rsa", {
  modulusLength: 2048,
});
const kid = randomBytes(8).toString("hex");
const jwk = {
  ...publicKey.export({ format: "jwk" }),
  kid,
  alg: "RS256",
  use: "sig",
};

const codes = new Map();
const refreshTokens = new Map();

const b64url = (value) => Buffer.from(value).toString("base64url");

function idToken(claims, nonce) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT", kid }));
  const payload = b64url(
    JSON.stringify({
      iss: issuer,
      aud: clientId,
      iat: now,
      exp: now + tokenTtl,
      ...(nonce ? { nonce } : {}),
      ...claims,
    }),
  );
  const signature = sign(
    "RSA-SHA256",
    Buffer.from(`${header}.${payload}`),
    privateKey,
  );
  return `${header}.${payload}.${b64url(signature)}`;
}

function claimsFor(user, refreshed) {
  const { refresh, ...base } = users[user];
  return refreshed && typeof refresh === "object"
    ? { ...base, ...refresh }
    : base;
}

// Like Google, refresh tokens are not rotated: a refresh response omits
// refresh_token and the original token stays valid.
function tokenResponse(user, nonce, refreshed) {
  const response = {
    access_token: randomBytes(24).toString("base64url"),
    token_type: "Bearer",
    expires_in: tokenTtl,
    id_token: idToken(
      claimsFor(user, refreshed),
      refreshed ? undefined : nonce,
    ),
  };
  if (!refreshed) {
    response.refresh_token = randomBytes(24).toString("base64url");
    refreshTokens.set(response.refresh_token, { user, nonce });
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

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
}

function clientAuthenticated(req, form) {
  const basic = req.headers.authorization?.match(/^Basic (.+)$/);
  if (basic) {
    const [id, secret] = Buffer.from(basic[1], "base64")
      .toString("utf8")
      .split(":")
      .map(decodeURIComponent);
    return id === clientId && secret === clientSecret;
  }
  return (
    form.get("client_id") === clientId &&
    form.get("client_secret") === clientSecret
  );
}

createServer(async (req, res) => {
  const url = new URL(req.url, issuer);
  try {
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
        scopes_supported: ["openid", "email", "profile"],
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
      if (req.method === "GET") {
        const options = Object.keys(users)
          .map((user) => `<button name="user" value="${user}">${user}</button>`)
          .join("");
        return send(res, 200, `<form method="post">${options}</form>`);
      }
      const user = (await readBody(req)).get("user");
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
      const form = await readBody(req);
      if (!clientAuthenticated(req, form))
        return send(res, 401, { error: "invalid_client" });
      if (form.get("grant_type") === "authorization_code") {
        const grant = codes.get(form.get("code"));
        codes.delete(form.get("code"));
        const verifier = form.get("code_verifier") ?? "";
        const challenge = createHash("sha256")
          .update(verifier)
          .digest("base64url");
        if (
          !grant ||
          grant.redirect !== form.get("redirect_uri") ||
          grant.challenge !== challenge
        ) {
          return send(res, 400, { error: "invalid_grant" });
        }
        return send(res, 200, tokenResponse(grant.user, grant.nonce, false));
      }
      if (form.get("grant_type") === "refresh_token") {
        const grant = refreshTokens.get(form.get("refresh_token"));
        if (!grant || users[grant.user].refresh === "invalid_grant") {
          return send(res, 400, { error: "invalid_grant" });
        }
        return send(res, 200, tokenResponse(grant.user, grant.nonce, true));
      }
      return send(res, 400, { error: "unsupported_grant_type" });
    }
    return send(res, 404, { error: "not_found" });
  } catch (error) {
    console.error(error);
    return send(res, 500, { error: "server_error" });
  }
}).listen(port, () =>
  console.log(`mock OIDC issuer ${issuer} listening on ${port}`),
);
