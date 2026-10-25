// GraphQL-equivalent identity echo and authorization test double.
// Roles come only from one read-only mounted JSON file loaded at startup.
import { createServer } from "node:http";
import { appendFileSync, readFileSync } from "node:fs";

const accountsFile = "/run/secrets/auth-accounts.json";
const expectedIssuer = process.env.EXPECTED_ISSUER;
const allowedOrigins = new Set(
  (process.env.ALLOWED_ORIGINS ?? "").split(",").filter(Boolean),
);
const effectsFile = process.env.EFFECTS_FILE;
const port = Number(process.env.PORT ?? "8080");

function loadAccounts() {
  const parsed = JSON.parse(readFileSync(accountsFile, "utf8"));
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("account map must be a JSON object");
  }
  const accounts = new Map();
  for (const [email, role] of Object.entries(parsed)) {
    if (email !== email.toLowerCase() || !/^[^@\s]+@[^@\s]+$/.test(email)) {
      throw new Error(`invalid account email: ${email}`);
    }
    if (role !== "member" && role !== "owner")
      throw new Error(`unknown role for ${email}`);
    accounts.set(email, role);
  }
  if (![...accounts.values()].includes("owner"))
    throw new Error("at least one owner is required");
  return accounts;
}

const accounts = loadAccounts();
console.log(`loaded ${accounts.size} account entries`);

const echoedHeader =
  /^(x-auth-request-|x-forwarded-user|x-forwarded-email|x-forwarded-groups|x-user|x-role|gap-auth|remote-user)/;

// Identity is trusted only because the target is reachable solely through
// Traefik, which strips these headers and sets them from the auth response.
function identityFrom(headers) {
  const sub = headers["x-auth-request-user"];
  const email = headers["x-auth-request-email"];
  const issuer = headers["x-auth-request-issuer"];
  const verified = headers["x-auth-request-email-verified"];
  if (
    sub === undefined &&
    email === undefined &&
    issuer === undefined &&
    verified === undefined
  ) {
    return { identity: null };
  }
  if (!sub || issuer !== expectedIssuer)
    return { error: "invalid-identity-context" };
  const emailVerified = verified === "true";
  const role =
    emailVerified && email ? (accounts.get(email.toLowerCase()) ?? null) : null;
  return {
    identity: {
      issuer,
      subject: sub,
      email: email ?? null,
      emailVerified,
      role,
    },
  };
}

function csrfRejection(req) {
  const site = req.headers["sec-fetch-site"];
  if (site !== undefined && site !== "same-origin" && site !== "none")
    return "cross-site request";
  const origin = req.headers.origin;
  if (origin !== undefined && !allowedOrigins.has(origin))
    return "untrusted origin";
  const json = (req.headers["content-type"] ?? "").startsWith(
    "application/json",
  );
  if (!json && req.headers["x-recipe-db-csrf"] !== "1")
    return "missing CSRF request header";
  return null;
}

const requiredRole = {
  rate: "member",
  deleteRecipe: "owner",
  uploadImage: "owner",
};
const rank = { member: 1, owner: 2 };

function send(res, status, body) {
  res.writeHead(status, {
    "content-type": "application/json",
    "cache-control": "no-store",
  });
  res.end(JSON.stringify(body));
}

const error = (code, message) => ({
  errors: [{ message, extensions: { code } }],
});

async function readOperation(req, url) {
  if (req.method === "GET")
    return { operation: url.searchParams.get("operation") };
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks).toString("latin1");
  const type = req.headers["content-type"] ?? "";
  if (type.startsWith("application/json")) return JSON.parse(body);
  const boundary = type.match(/boundary=(?:"([^"]+)"|([^;]+))/);
  if (type.startsWith("multipart/form-data") && boundary) {
    const parts = body.split(`--${boundary[1] ?? boundary[2]}`);
    const operations = parts.find((part) => /name="operations"/.test(part));
    const file = parts.find((part) => /name="1"; filename=/.test(part));
    if (!operations) throw new Error("missing operations part");
    const parsed = JSON.parse(
      operations.slice(operations.indexOf("\r\n\r\n") + 4).trim(),
    );
    return { ...parsed, fileBytes: file ? file.length : 0 };
  }
  const form = new URLSearchParams(body);
  return { operation: form.get("operation"), marker: form.get("marker") };
}

createServer(async (req, res) => {
  const url = new URL(req.url, "http://target");
  if (url.pathname === "/healthz") return send(res, 200, { ok: true });
  if (url.pathname !== "/graphql")
    return send(res, 404, error("not-found", "not found"));
  let request;
  try {
    request = await readOperation(req, url);
  } catch {
    return send(res, 400, error("bad-request", "malformed request"));
  }
  const { identity, error: identityError } = identityFrom(req.headers);
  if (identityError)
    return send(res, 401, error(identityError, "untrusted identity context"));
  const operation = request.operation;

  if (operation === "publicRecipes") {
    return send(res, 200, {
      data: { recipes: [{ id: "1", title: "Public soup" }] },
    });
  }
  if (operation === "whoami") {
    const received = Object.fromEntries(
      Object.entries(req.headers).filter(([name]) => echoedHeader.test(name)),
    );
    return send(res, 200, {
      data: {
        identity,
        receivedIdentityHeaders: received,
        cookieNames: (req.headers.cookie ?? "")
          .split(";")
          .map((pair) => pair.trim().split("=", 1)[0])
          .filter(Boolean),
        authorizationPresent: req.headers.authorization !== undefined,
      },
    });
  }
  if (Object.hasOwn(requiredRole, operation)) {
    if (req.method !== "POST")
      return send(res, 405, error("method-not-allowed", "use POST"));
    const csrf = csrfRejection(req);
    if (csrf) return send(res, 403, error("csrf-rejected", csrf));
    if (!identity)
      return send(
        res,
        401,
        error("authentication-required", "sign in required"),
      );
    if (!identity.role || rank[identity.role] < rank[requiredRole[operation]]) {
      return send(
        res,
        403,
        error("forbidden", `${requiredRole[operation]} role required`),
      );
    }
    appendFileSync(
      effectsFile,
      `${JSON.stringify({ operation, subject: identity.subject, role: identity.role, marker: request.marker ?? null })}\n`,
    );
    return send(res, 200, {
      data: { [operation]: true, fileBytes: request.fileBytes },
    });
  }
  return send(res, 400, error("unknown-operation", "unknown operation"));
}).listen(port, () => console.log(`target listening on ${port}`));
