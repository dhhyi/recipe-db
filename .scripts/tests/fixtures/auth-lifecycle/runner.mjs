import assert from "node:assert/strict";
import { request } from "node:http";
import { readFileSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

const app = "http://app.poc.test";
const bearer = readFileSync("/run/secrets/bearer", "utf8").trim();
const sessionFile = "/state/session.json";

class Jar {
  constructor(cookies = {}) {
    this.cookies = { ...cookies };
  }
  header() {
    return Object.entries(this.cookies)
      .map(([name, value]) => `${name}=${value}`)
      .join("; ");
  }
  apply(cookies) {
    for (const cookie of cookies) {
      const [pair, ...attributes] = cookie
        .split(";")
        .map((part) => part.trim());
      const index = pair.indexOf("=");
      const name = pair.slice(0, index);
      const value = pair.slice(index + 1);
      const expires = attributes.find((value) => /^expires=/i.test(value));
      if (
        !value ||
        attributes.some((value) => /^max-age=0$/i.test(value)) ||
        (expires && Date.parse(expires.slice(8)) <= Date.now())
      ) {
        delete this.cookies[name];
      } else {
        this.cookies[name] = value;
      }
    }
  }
}

function http(path, { method = "GET", jar, body, headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const req = request(
      new URL(path, app),
      {
        method,
        timeout: 20000,
        headers: {
          ...headers,
          ...(jar?.header() ? { Cookie: jar.header() } : {}),
        },
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          const cookies = res.headers["set-cookie"] ?? [];
          jar?.apply(cookies);
          resolve({
            status: res.statusCode,
            headers: res.headers,
            cookies,
            text: Buffer.concat(chunks).toString("utf8"),
          });
        });
        res.on("error", reject);
      },
    );
    req.on("timeout", () => req.destroy(new Error("lifecycle HTTP timeout")));
    req.on("error", reject);
    req.end(body);
  });
}

async function gql(jar, authorization) {
  return http("/graphql", {
    method: "POST",
    jar,
    headers: {
      "Content-Type": "application/json",
      ...(authorization ? { Authorization: authorization } : {}),
    },
    body: JSON.stringify({
      query:
        "{ capabilities: myCapabilities { role canManageRecipes canRate } }",
    }),
  });
}

function role(response, expected) {
  assert.equal(response.status, 200, "GraphQL capability query failed");
  const result = JSON.parse(response.text);
  assert.equal(
    result.errors,
    undefined,
    "unexpected GraphQL authentication error",
  );
  assert.equal(result.data.capabilities.role, expected);
  assert.equal(result.data.capabilities.canManageRecipes, expected === "owner");
  assert.equal(result.data.capabilities.canRate, expected !== "anonymous");
}

function deniedCookie(response) {
  assert(
    response.status >= 400,
    "presented invalid session must fail explicitly",
  );
  assert(
    !response.text.includes('"role":"owner"'),
    "denied session retained owner access",
  );
}

async function login(user) {
  const jar = new Jar();
  const start = await http("/oauth2/start?rd=%2Fidentity", { jar });
  assert.equal(start.status, 302, "login start failed");
  const target = new URL(start.headers.location);
  assert.equal(target.searchParams.get("code_challenge_method"), "S256");
  assert(target.searchParams.get("nonce"), "OIDC nonce missing");
  const approved = await http(target.toString(), {
    method: "POST",
    body: `user=${user}`,
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
  });
  assert.equal(approved.status, 302, "mock authorization failed");
  const callback = await http(approved.headers.location, { jar });
  return { jar, callback };
}

async function signedIn(user) {
  const { jar, callback } = await login(user);
  assert.equal(callback.status, 302, "callback failed");
  assert(jar.cookies._oauth2_proxy, "callback did not set session cookie");
  const cookie = callback.cookies.find((value) =>
    value.startsWith("_oauth2_proxy="),
  );
  assert(
    /httponly/i.test(cookie) && /samesite=lax/i.test(cookie),
    "session cookie attributes missing",
  );
  assert(
    !/;\s*secure/i.test(cookie),
    "isolated HTTP fixture unexpectedly uses Secure cookies",
  );
  return jar;
}

async function ready() {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const response = await gql();
      const start = await http("/oauth2/start?rd=%2Fidentity");
      if (response.status === 200 && start.status === 302) return;
    } catch (error) {
      if (!["ECONNREFUSED", "ECONNRESET", "EAI_AGAIN"].includes(error.code))
        throw error;
    }
    await sleep(1000);
  }
  throw new Error("integrated authentication stack did not become ready");
}

async function basic() {
  await ready();
  role(await gql(), "anonymous");
  let owner;
  for (const [user, expected] of [
    ["owner", "owner"],
    ["member", "member"],
    ["outsider", "anonymous"],
  ]) {
    const jar = await signedIn(user);
    role(await gql(jar), expected);
    const identity = await http("/identity", { jar });
    assert.equal(identity.headers["cache-control"], "no-store");
    assert(
      identity.text.includes(`auth-role="${expected}"`),
      "browse identity disagrees with GraphQL",
    );
    if (user === "owner") {
      owner = jar;
    }
  }
  const { jar, callback } = await login("unverified");
  assert(
    callback.status >= 400 && !jar.cookies._oauth2_proxy,
    "unverified email was admitted",
  );
  deniedCookie(await gql(jar));
  role(await gql(), "anonymous");
  const rejected = JSON.parse(
    (await gql(owner, "Bearer deliberately-invalid")).text,
  );
  assert.equal(rejected.errors[0].extensions.code, "invalid-credentials");
  assert(
    !rejected.data?.capabilities,
    "invalid bearer fell back to valid cookie",
  );
  const malformed = new Jar({ _oauth2_proxy: "malformed" });
  deniedCookie(await gql(malformed));
  assert(
    !malformed.cookies._oauth2_proxy,
    "GraphQL clearing cookie not relayed",
  );
  role(await gql(malformed), "anonymous");
  const ssr = new Jar({ _oauth2_proxy: "malformed" });
  await http("/identity", { jar: ssr });
  assert(!ssr.cookies._oauth2_proxy, "browse did not relay clearing cookie");
  role(await gql(ssr), "anonymous");
  console.log(
    "PASS integrated callback, roles, unverified denial, bearer precedence and cookie clearing",
  );
}

async function lifecycle() {
  const active = await signedIn("owner");
  const idle = await signedIn("owner");
  const revoked = await signedIn("revoked");
  const started = Date.now();
  await sleep(22000);
  const renewal = await http("/identity", { jar: active });
  assert(
    renewal.text.includes('auth-role="owner"'),
    "browse refresh lost identity",
  );
  assert(
    renewal.cookies.some(
      (value) =>
        value.startsWith("_oauth2_proxy=") &&
        !value.startsWith("_oauth2_proxy=;"),
    ),
    "browse did not relay renewed session cookie",
  );
  await sleep(22000);
  role(await gql(active), "owner");
  deniedCookie(await gql(revoked));
  role(await gql(revoked), "anonymous");
  await sleep(22000);
  assert(
    Date.now() - started > 60000,
    "sliding-policy threshold was not exercised",
  );
  role(await gql(active), "owner");
  deniedCookie(await gql(idle));
  role(await gql(idle), "anonymous");
  const replay = new Jar(active.cookies);
  const logout = await http("/oauth2/sign_out?rd=%2Fidentity", { jar: active });
  assert.equal(logout.status, 302, "logout failed");
  assert(!active.cookies._oauth2_proxy, "logout did not clear cookie");
  role(await gql(active), "anonymous");
  deniedCookie(await gql(replay));
  role(await gql(await signedIn("owner")), "owner");
  console.log(
    "PASS accelerated refresh/sliding beyond 60s, idle expiry, revoked refresh, logout/replay and explicit recovery",
  );
}

async function prepare() {
  const jar = await signedIn("owner");
  role(await gql(jar), "owner");
  writeFileSync(sessionFile, JSON.stringify(jar.cookies), { mode: 0o600 });
  console.log("PASS fresh isolated session prepared");
}

async function outage() {
  const saved = JSON.parse(readFileSync(sessionFile, "utf8"));
  role(await gql(), "anonymous");
  role(await gql(undefined, `Bearer ${bearer}`), "owner");
  deniedCookie(await gql(new Jar(saved)));
  const identity = await http("/identity", { jar: new Jar(saved) });
  assert.equal(identity.headers["cache-control"], "no-store");
  assert(
    !identity.text.includes('auth-role="owner"'),
    "failed auth dependency leaked owner identity",
  );
  console.log(
    "PASS dependency outage: anonymous and bearer available, cookie fails closed, SSR has no owner",
  );
}

async function recovered() {
  await ready();
  const jar = new Jar(JSON.parse(readFileSync(sessionFile, "utf8")));
  role(await gql(jar), "owner");
  const identity = await http("/identity", { jar });
  assert(
    identity.text.includes('auth-role="owner"'),
    "SSR identity did not recover",
  );
  writeFileSync(sessionFile, JSON.stringify(jar.cookies), { mode: 0o600 });
  console.log("PASS same session recovered after dependency restart");
}

async function lost() {
  const jar = new Jar(JSON.parse(readFileSync(sessionFile, "utf8")));
  deniedCookie(await gql(jar));
  role(await gql(jar), "anonymous");
  role(await gql(await signedIn("owner")), "owner");
  console.log("PASS isolated Redis data loss requires explicit re-login");
}

const phases = { basic, lifecycle, prepare, outage, recovered, lost };
const phase = phases[process.argv[2]];
assert(phase, "unknown lifecycle phase");
await phase();
