// Minimal server-rendered caller representing browse. It forwards only the
// session cookie to GraphQL through Traefik and never relays identity headers.
import { createServer, request } from "node:http";

const graphqlUrl = new URL(process.env.GRAPHQL_URL);
const appOrigin = process.env.APP_ORIGIN;
const sessionCookie = /^_oauth2_proxy(_\d+)?$/;
const port = Number(process.env.PORT ?? "8080");
const sharedCache = new Map();

function sessionCookies(header) {
  return (header ?? "")
    .split(";")
    .map((pair) => pair.trim())
    .filter((pair) => sessionCookie.test(pair.split("=", 1)[0]))
    .join("; ");
}

function graphql(body, cookie) {
  const payload = JSON.stringify(body);
  const headers = {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
  };
  if (cookie) headers.cookie = cookie;
  return new Promise((resolve, reject) => {
    const req = request(graphqlUrl, { method: "POST", headers }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let json = null;
        try {
          json = JSON.parse(text);
        } catch {}
        const setCookies = (res.headers["set-cookie"] ?? []).filter((value) =>
          sessionCookie.test(value.split("=", 1)[0]),
        );
        resolve({ status: res.statusCode, json, setCookies });
      });
    });
    req.on("error", reject);
    req.end(payload);
  });
}

function html(
  res,
  status,
  body,
  { setCookies = [], credentialed = false, cache = "" } = {},
) {
  res.writeHead(status, {
    "content-type": "text/html; charset=utf-8",
    "cache-control":
      credentialed || status !== 200
        ? "private, no-store"
        : "public, max-age=60",
    vary: "Cookie",
    ...(cache ? { "x-browse-cache": cache } : {}),
    ...(setCookies.length ? { "set-cookie": setCookies } : {}),
  });
  res.end(`<!doctype html><title>browse</title>${body}`);
}

function failure(res, result) {
  if (result.status === 401) {
    return html(
      res,
      401,
      '<p id="state">signed-out</p><p>Your sign-in is no longer valid. <a href="/oauth2/start?rd=/browse/page">Sign in again</a> or <a href="/browse/page">continue browsing</a>.</p>',
      { setCookies: result.setCookies },
    );
  }
  return html(
    res,
    503,
    '<p id="state">unavailable</p><p>Sign-in is temporarily unavailable.</p>',
    {
      setCookies: result.setCookies,
    },
  );
}

function csrfRejection(req) {
  const site = req.headers["sec-fetch-site"];
  if (site !== undefined && site !== "same-origin") return "cross-site request";
  if (req.headers.origin !== appOrigin) return "missing or untrusted origin";
  return null;
}

async function readForm(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
}

createServer(async (req, res) => {
  const url = new URL(req.url, appOrigin);
  try {
    if (url.pathname === "/healthz") return html(res, 200, "ok");
    const cookie = sessionCookies(req.headers.cookie);
    if (url.pathname === "/browse/page" && req.method === "GET") {
      if (!cookie && sharedCache.has("page")) {
        return html(res, 200, sharedCache.get("page"), { cache: "hit" });
      }
      const whoami = await graphql({ operation: "whoami" }, cookie);
      if (whoami.status !== 200) return failure(res, whoami);
      const recipes = await graphql({ operation: "publicRecipes" }, cookie);
      if (recipes.status !== 200) return failure(res, recipes);
      const identity = whoami.json.data.identity;
      const body = [
        `<p id="identity">${identity ? `${identity.email} (${identity.role ?? "no role"})` : "anonymous"}</p>`,
        `<ul>${recipes.json.data.recipes.map((recipe) => `<li>${recipe.title}</li>`).join("")}</ul>`,
        `<script type="application/json" id="internal">${JSON.stringify(whoami.json.data)}</script>`,
      ].join("");
      if (!cookie) sharedCache.set("page", body);
      return html(res, 200, body, {
        setCookies: [...whoami.setCookies, ...recipes.setCookies],
        credentialed: Boolean(cookie),
        cache: cookie ? "bypass" : "miss",
      });
    }
    if (url.pathname === "/browse/rate" && req.method === "POST") {
      const csrf = csrfRejection(req);
      if (csrf)
        return html(res, 403, `<p id="state">csrf-rejected</p><p>${csrf}</p>`);
      const form = await readForm(req);
      const result = await graphql(
        { operation: "rate", marker: form.get("marker") },
        cookie,
      );
      if (result.status === 200) {
        return html(res, 200, '<p id="state">rated</p>', {
          setCookies: result.setCookies,
          credentialed: true,
        });
      }
      if (result.status === 401 || result.status >= 500)
        return failure(res, result);
      return html(
        res,
        result.status,
        `<p id="state">${result.json?.errors?.[0]?.extensions?.code}</p>`,
        {
          setCookies: result.setCookies,
          credentialed: true,
        },
      );
    }
    return html(res, 404, "not found");
  } catch (error) {
    console.error(error);
    return html(res, 502, '<p id="state">upstream-error</p>');
  }
}).listen(port, () => console.log(`browse caller listening on ${port}`));
