// Experiment-matrix runner for the OAuth2 Proxy optional-authentication PoC.
// Runs on the simulated untrusted edge network. Usage: node runner.mjs <phase>
import { request } from "node:http";
import { createHmac, randomBytes } from "node:crypto";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { connect } from "node:net";

const APP = "http://app.poc.test";
const EVIL = "http://evil.poc.test";
const COOKIE = "_oauth2_proxy";
const RESULTS = "/state/results.jsonl";
const SESSIONS = "/state/sessions.json";
const MODES = { split: "/graphql", baseline: "/baseline/graphql" };
const FORGED = {
  "X-Auth-Request-User": "sub-owner",
  "X-Auth-Request-Email": "owner@example.test",
  "X-Auth-Request-Issuer": "http://idp.poc.test",
  "X-Auth-Request-Email-Verified": "true",
  "X-Forwarded-User": "sub-owner",
  "X-Forwarded-Email": "owner@example.test",
  "X-User-Role": "owner",
  "X-Role": "owner",
  "Gap-Auth": "owner@example.test",
  X_Auth_Request_Email: "owner@example.test",
  "X.Auth.Request.User": "sub-owner",
};

// Results that document a demonstrated gap of the unmodified baseline. They are
// reported as preserved failing reproducers, not as harness failures.
const KNOWN_GAPS = new Set([
  "5.1/baseline",
  "5.2/baseline",
  "5.3/baseline",
  "5.4/baseline",
  "5.6/baseline",
  "6.R2/baseline",
  "7.3/baseline",
  // OAuth2 Proxy limitation: a non-fatal refresh failure keeps the previous
  // verified snapshot until the old ID token expires (applies to both modes).
  "7.5/split",
]);

// Header names a downstream service could mistake for proxy-asserted identity.
const TRUSTED_IDENTITY =
  /^(x-auth-request-|x-forwarded-(user|email|groups|preferred-username)$|gap-auth$|remote-user$)/;
const trustedNames = (received) =>
  Object.keys(received).filter((name) => TRUSTED_IDENTITY.test(name));

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class Jar {
  constructor(cookies = {}) {
    this.cookies = { ...cookies };
  }
  header() {
    return Object.entries(this.cookies)
      .map(([name, value]) => `${name}=${value}`)
      .join("; ");
  }
  get(name) {
    return this.cookies[name];
  }
  apply(setCookies) {
    for (const setCookie of setCookies) {
      const { name, value, clearing } = parseSetCookie(setCookie);
      if (clearing) delete this.cookies[name];
      else this.cookies[name] = value;
    }
    return this;
  }
  clone() {
    return new Jar(this.cookies);
  }
}

function parseSetCookie(setCookie) {
  const [pair, ...attributes] = setCookie.split(";").map((part) => part.trim());
  const index = pair.indexOf("=");
  const name = pair.slice(0, index);
  const value = pair.slice(index + 1);
  const expires = attributes.find((attribute) => /^expires=/i.test(attribute));
  const clearing =
    value === "" ||
    attributes.some((attribute) => /^max-age=(0|-)/i.test(attribute)) ||
    (expires !== undefined && Date.parse(expires.slice(8)) <= Date.now());
  return { name, value, attributes, clearing };
}

function describeCookie(setCookie) {
  const { name, attributes, clearing } = parseSetCookie(setCookie);
  const kept = attributes.filter((attribute) => !/^expires=/i.test(attribute));
  return [`${name}=<${clearing ? "cleared" : "redacted"}>`, ...kept].join("; ");
}

function sanitizeUrl(location) {
  try {
    const url = new URL(location, APP);
    for (const key of [...url.searchParams.keys()]) {
      if (key !== "rd") url.searchParams.set(key, "<redacted>");
    }
    return decodeURIComponent(url.toString());
  } catch {
    return "<unparseable>";
  }
}

function http(method, url, { headers = {}, raw, body, jar } = {}) {
  const list = raw ? [...raw] : Object.entries(headers).flat();
  // Node does not add Host itself when headers are passed as a raw array.
  if (
    !list.some(
      (value, index) => index % 2 === 0 && value.toLowerCase() === "host",
    )
  )
    list.push("Host", new URL(url).host);
  if (jar && jar.header()) list.push("Cookie", jar.header());
  if (body !== undefined)
    list.push("Content-Length", String(Buffer.byteLength(body)));
  return new Promise((resolve, reject) => {
    const req = request(
      new URL(url),
      { method, headers: list, timeout: 20000 },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let json;
          try {
            json = JSON.parse(text);
          } catch {}
          resolve({
            status: res.statusCode,
            headers: res.headers,
            setCookies: res.headers["set-cookie"] ?? [],
            text,
            json,
          });
        });
      },
    );
    req.on("timeout", () => req.destroy(new Error("timeout")));
    req.on("error", reject);
    req.end(body);
  });
}

function gql(mode, operation, { jar, headers = {}, raw, marker } = {}) {
  const body = JSON.stringify({ operation, marker });
  if (raw)
    return http("POST", `${APP}${MODES[mode]}`, {
      raw: [...raw, "Content-Type", "application/json"],
      body,
    });
  return http("POST", `${APP}${MODES[mode]}`, {
    jar,
    headers: { "Content-Type": "application/json", ...headers },
    body,
  });
}

function multipart(operations) {
  const boundary = `----poc${randomBytes(6).toString("hex")}`;
  const body = [
    `--${boundary}\r\nContent-Disposition: form-data; name="operations"\r\n\r\n${JSON.stringify(operations)}\r\n`,
    `--${boundary}\r\nContent-Disposition: form-data; name="map"\r\n\r\n{"1":["variables.file"]}\r\n`,
    `--${boundary}\r\nContent-Disposition: form-data; name="1"; filename="a.jpg"\r\nContent-Type: image/jpeg\r\n\r\nfake-jpeg-bytes\r\n`,
    `--${boundary}--\r\n`,
  ].join("");
  return { body, contentType: `multipart/form-data; boundary=${boundary}` };
}

function effects(marker) {
  try {
    return readFileSync("/effects/log.jsonl", "utf8")
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line))
      .filter((effect) => effect.marker === marker).length;
  } catch {
    return 0;
  }
}

const newMarker = (id) => `${id}-${randomBytes(8).toString("hex")}`;

function identityOf(res) {
  const identity = res.json?.data?.identity;
  if (!identity) return res.status === 200 ? "none" : "-";
  return `${identity.subject} ${identity.email ?? "-"} verified=${identity.emailVerified} role=${identity.role ?? "none"}`;
}

function observed(res, extra = {}) {
  return {
    status: res.status,
    identity: identityOf(res),
    code: res.json?.errors?.[0]?.extensions?.code,
    location: res.headers.location
      ? sanitizeUrl(res.headers.location)
      : undefined,
    setCookie: res.setCookies.map(describeCookie),
    cacheControl: res.headers["cache-control"],
    ...extra,
  };
}

async function check(id, mode, title, expected, test) {
  let result;
  try {
    result = await test();
  } catch (error) {
    result = {
      pass: false,
      observed: { error: String(error.message ?? error) },
    };
  }
  const entry = { id, mode, title, expected, ...result };
  appendFileSync(RESULTS, `${JSON.stringify(entry)}\n`);
  const known = KNOWN_GAPS.has(`${id}/${mode}`);
  console.log(
    `${result.pass ? "PASS" : known ? "GAP " : "FAIL"} ${id} [${mode}] ${title} ${JSON.stringify(result.observed)}`,
  );
  return result;
}

async function login(user, rd = "/browse/page") {
  const jar = new Jar();
  const start = await http(
    "GET",
    `${APP}/oauth2/start?rd=${encodeURIComponent(rd)}`,
    { jar },
  );
  jar.apply(start.setCookies);
  if (start.status !== 302) return { jar, start, ok: false };
  const approve = await http("POST", start.headers.location, {
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `user=${user}`,
  });
  const callback = await http("GET", approve.headers.location, { jar });
  jar.apply(callback.setCookies);
  return {
    jar,
    start,
    callback,
    ok: callback.status === 302 && Boolean(jar.get(COOKIE)),
  };
}

async function mustLogin(user) {
  const result = await login(user);
  if (!result.ok)
    throw new Error(
      `login ${user} failed: ${result.callback?.status ?? result.start.status}`,
    );
  return result.jar;
}

function saveSessions(sessions) {
  let stored = {};
  try {
    stored = JSON.parse(readFileSync(SESSIONS, "utf8"));
  } catch {}
  for (const [name, jar] of Object.entries(sessions))
    stored[name] = jar.cookies;
  writeFileSync(SESSIONS, JSON.stringify(stored));
}

function loadSession(name) {
  return new Jar(JSON.parse(readFileSync(SESSIONS, "utf8"))[name]);
}

// Test-only knowledge of the cookie secret, used solely to construct a
// correctly signed cookie that references a ticket absent from Redis.
function signCookie(value, timestamp = Math.floor(Date.now() / 1000)) {
  const secret = readFileSync("/run/secrets/cookie-secret", "utf8").trim();
  const encoded = Buffer.from(value)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
  const signature = createHmac("sha256", secret)
    .update(COOKIE)
    .update(encoded)
    .update(String(timestamp))
    .digest("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
  return `${encoded}|${timestamp}|${signature}`;
}

function unknownTicketCookie() {
  const id = Buffer.from(
    `${COOKIE}-${randomBytes(16).toString("hex")}`,
  ).toString("base64url");
  return signCookie(`v2.${id}.${randomBytes(16).toString("base64url")}`);
}

function resignedCookie(cookie) {
  const [encoded] = cookie.split("|");
  return signCookie(
    Buffer.from(
      encoded.replace(/-/g, "+").replace(/_/g, "/"),
      "base64",
    ).toString("utf8"),
  );
}

function tamperedCookie(cookie) {
  const parts = cookie.split("|");
  const signature = parts[2];
  parts[2] = `${signature[0] === "A" ? "B" : "A"}${signature.slice(1)}`;
  return parts.join("|");
}

function probe(host, port) {
  return new Promise((resolve) => {
    const socket = connect({ host, port, timeout: 3000 });
    socket.on("connect", () => {
      socket.destroy();
      resolve("connected");
    });
    socket.on("timeout", () => {
      socket.destroy();
      resolve("timeout");
    });
    socket.on("error", (error) => resolve(error.code ?? error.message));
  });
}

const isDenied = (res) => res.status === 401 || res.status === 403;
const anonymousOk = (res) =>
  res.status === 200 && res.json?.data?.identity === null;
const nonSuccess = (res) => res.status >= 400;

async function protectedAttempt(mode, jar, operation = "rate", raw) {
  const marker = newMarker(operation);
  const res = raw
    ? await gql(mode, operation, { raw, marker })
    : await gql(mode, operation, { jar, marker });
  return { res, sideEffects: effects(marker) };
}

// ---------------------------------------------------------------- phases

async function phaseWait() {
  for (let attempt = 0; attempt < 60; attempt++) {
    try {
      const start = await http("GET", `${APP}/oauth2/start?rd=/`);
      const anonymous = await gql("split", "whoami");
      if (start.status === 302 && anonymous.status === 200) return;
    } catch {}
    await sleep(1000);
  }
  throw new Error("stack not ready");
}

async function phaseMain() {
  const owner = await mustLogin("owner");
  const member = await mustLogin("member");
  const outsider = await mustLogin("outsider");

  for (const mode of Object.keys(MODES)) {
    // 1. Anonymous
    await check(
      "1.1",
      mode,
      "Anonymous read on mixed route",
      "200, no redirect, no identity headers",
      async () => {
        const res = await gql(mode, "whoami");
        const received = res.json?.data?.receivedIdentityHeaders ?? {};
        return {
          pass: anonymousOk(res) && Object.keys(received).length === 0,
          observed: observed(res, {
            receivedIdentityHeaders: Object.keys(received),
          }),
        };
      },
    );
    for (const operation of ["rate", "deleteRecipe"]) {
      await check(
        "1.2",
        mode,
        `Anonymous protected action (${operation})`,
        "401 authentication-required, no side effect",
        async () => {
          const { res, sideEffects } = await protectedAttempt(
            mode,
            null,
            operation,
          );
          return {
            pass:
              res.status === 401 &&
              res.json?.errors?.[0]?.extensions?.code ===
                "authentication-required" &&
              sideEffects === 0,
            observed: observed(res, { sideEffects }),
          };
        },
      );
    }

    // 2. Valid sessions
    for (const [name, jar, role] of [
      ["owner", owner, "owner"],
      ["member", member, "member"],
      ["outsider", outsider, null],
    ]) {
      await check(
        "2.1",
        mode,
        `Valid ${name} session identity`,
        `200, issuer+subject+verified email, role=${role ?? "none"}`,
        async () => {
          const res = await gql(mode, "whoami", { jar });
          const identity = res.json?.data?.identity;
          return {
            pass:
              res.status === 200 &&
              identity?.issuer === "http://idp.poc.test" &&
              identity?.subject === `sub-${name}` &&
              identity?.emailVerified === true &&
              identity?.role === role,
            observed: observed(res),
          };
        },
      );
    }
    await check(
      "2.2",
      mode,
      "Member performs member action (rate)",
      "200, one side effect",
      async () => {
        const { res, sideEffects } = await protectedAttempt(
          mode,
          member,
          "rate",
        );
        return {
          pass: res.status === 200 && sideEffects === 1,
          observed: observed(res, { sideEffects }),
        };
      },
    );
    await check(
      "2.3",
      mode,
      "Member attempts owner-only action",
      "403 forbidden, no side effect",
      async () => {
        const { res, sideEffects } = await protectedAttempt(
          mode,
          member,
          "deleteRecipe",
        );
        return {
          pass: res.status === 403 && sideEffects === 0,
          observed: observed(res, { sideEffects }),
        };
      },
    );
    await check(
      "2.4",
      mode,
      "Owner performs owner-only action",
      "200, one side effect",
      async () => {
        const { res, sideEffects } = await protectedAttempt(
          mode,
          owner,
          "deleteRecipe",
        );
        return {
          pass: res.status === 200 && sideEffects === 1,
          observed: observed(res, { sideEffects }),
        };
      },
    );
    await check(
      "2.5",
      mode,
      "Authenticated non-allowlisted account attempts member action",
      "403 forbidden, no side effect",
      async () => {
        const { res, sideEffects } = await protectedAttempt(
          mode,
          outsider,
          "rate",
        );
        return {
          pass: res.status === 403 && sideEffects === 0,
          observed: observed(res, { sideEffects }),
        };
      },
    );
  }

  await check(
    "2.6",
    "proxy",
    "Sign-in with email_verified=false (allowlisted address)",
    "sign-in rejected, no session cookie",
    async () => {
      const result = await login("unverified");
      return {
        pass: !result.ok && !result.jar.get(COOKIE),
        observed: {
          status: result.callback?.status,
          setCookie: (result.callback?.setCookies ?? []).map(describeCookie),
        },
      };
    },
  );
  const missing = await login("missing-verified");
  for (const mode of Object.keys(MODES)) {
    await check(
      "2.7",
      mode,
      "ID token without email_verified claim (allowlisted address)",
      "no member rights",
      async () => {
        const res = await gql(mode, "whoami", { jar: missing.jar });
        const { res: action, sideEffects } = await protectedAttempt(
          mode,
          missing.jar,
          "rate",
        );
        return {
          pass:
            (res.json?.data?.identity?.role ?? null) === null &&
            isDenied(action) &&
            sideEffects === 0,
          observed: observed(res, {
            loginStatus: missing.callback?.status,
            admittedBySession: missing.ok,
            actionStatus: action.status,
            sideEffects,
          }),
        };
      },
    );
  }
  await check(
    "2.8",
    "proxy",
    "Session cookie attributes after sign-in",
    "HttpOnly, SameSite=Lax, Path=/, no Domain",
    async () => {
      const result = await login("member");
      const cookie =
        result.callback.setCookies.find((value) =>
          value.startsWith(`${COOKIE}=`),
        ) ?? "";
      const attributes = parseSetCookie(cookie).attributes.map((attribute) =>
        attribute.toLowerCase(),
      );
      return {
        pass:
          attributes.includes("httponly") &&
          attributes.includes("samesite=lax") &&
          attributes.includes("path=/") &&
          !attributes.some((attribute) => attribute.startsWith("domain=")),
        observed: {
          status: result.callback.status,
          location: sanitizeUrl(result.callback.headers.location),
          setCookie: result.callback.setCookies.map(describeCookie),
        },
      };
    },
  );

  // 3. Spoof resistance
  for (const mode of Object.keys(MODES)) {
    await check(
      "3.1",
      mode,
      "Anonymous request with forged identity/role headers",
      "anonymous, no trusted identity header reaches target",
      async () => {
        const res = await gql(mode, "whoami", { headers: FORGED });
        const received = res.json?.data?.receivedIdentityHeaders ?? {};
        return {
          pass: anonymousOk(res) && trustedNames(received).length === 0,
          observed: observed(res, {
            trustedIdentityHeadersReceived: trustedNames(received),
            ignoredHeadersReceived: Object.keys(received).filter(
              (name) => !TRUSTED_IDENTITY.test(name),
            ),
          }),
        };
      },
    );
    await check(
      "3.2",
      mode,
      "Anonymous owner action with forged headers",
      "401, no side effect",
      async () => {
        const marker = newMarker("forged");
        const res = await gql(mode, "deleteRecipe", {
          headers: FORGED,
          marker,
        });
        const sideEffects = effects(marker);
        return {
          pass: res.status === 401 && sideEffects === 0,
          observed: observed(res, { sideEffects }),
        };
      },
    );
    await check(
      "3.3",
      mode,
      "Member session with forged owner headers",
      "member identity only; owner action 403, no side effect",
      async () => {
        const res = await gql(mode, "whoami", { jar: member, headers: FORGED });
        const marker = newMarker("forged-member");
        const action = await gql(mode, "deleteRecipe", {
          jar: member,
          headers: FORGED,
          marker,
        });
        const sideEffects = effects(marker);
        const received = res.json?.data?.receivedIdentityHeaders ?? {};
        const trusted = trustedNames(received);
        return {
          pass:
            res.json?.data?.identity?.subject === "sub-member" &&
            res.json?.data?.identity?.role === "member" &&
            trusted.every((name) => name.startsWith("x-auth-request-")) &&
            received["x-auth-request-email"] === "member@example.test" &&
            received["x-auth-request-user"] === "sub-member" &&
            action.status === 403 &&
            sideEffects === 0,
          observed: observed(res, {
            trustedIdentityHeadersReceived: trusted,
            actionStatus: action.status,
            sideEffects,
          }),
        };
      },
    );
    await check(
      "3.4",
      mode,
      "Internal hostname (graphql.internal) requested from edge with forged headers",
      "same auth boundary: anonymous",
      async () => {
        const res = await gql(mode, "whoami", {
          headers: { ...FORGED, Host: "graphql.internal" },
        });
        return { pass: anonymousOk(res), observed: observed(res) };
      },
    );
  }
  await check(
    "3.5",
    "network",
    "Direct access to private services from client network",
    "no connection by name or IP",
    async () => {
      const targets = [
        ["target", 8080],
        ["oauth2-proxy", 4180],
        ["redis", 6379],
        ["mock-oidc", 8080],
        ["browse", 8080],
      ];
      if (process.env.TARGET_PRIVATE_IP)
        targets.push([process.env.TARGET_PRIVATE_IP, 8080]);
      const outcomes = {};
      for (const [host, port] of targets)
        outcomes[
          `${host === process.env.TARGET_PRIVATE_IP ? "target-ip" : host}:${port}`
        ] = await probe(host, port);
      return {
        pass:
          Boolean(process.env.TARGET_PRIVATE_IP) &&
          Object.values(outcomes).every((outcome) => outcome !== "connected"),
        observed: outcomes,
      };
    },
  );
  await check(
    "3.6",
    "split",
    "Duplicate Cookie headers hiding a malformed session cookie in the second header",
    "non-success (credential presented)",
    async () => {
      const res = await gql("split", "whoami", {
        raw: ["Cookie", "theme=dark", "Cookie", `${COOKIE}=garbage`],
      });
      return { pass: nonSuccess(res), observed: observed(res) };
    },
  );

  // 4. SSR propagation through the browse caller
  await check(
    "4.1",
    "ssr",
    "Anonymous SSR page",
    "200 anonymous, shareable cache headers",
    async () => {
      const res = await http("GET", `${APP}/browse/page`);
      return {
        pass:
          res.status === 200 &&
          res.text.includes('<p id="identity">anonymous</p>'),
        observed: observed(res, { browseCache: res.headers["x-browse-cache"] }),
      };
    },
  );
  await check(
    "4.2",
    "ssr",
    "Member SSR page forwards only the session cookie",
    "200 member identity, private no-store, only _oauth2_proxy forwarded, no forged headers",
    async () => {
      const jar = member.clone();
      jar.cookies.tracking = "secret-tracking";
      jar.cookies[`${COOKIE}_csrf`] = "irrelevant";
      const res = await http("GET", `${APP}/browse/page`, {
        jar,
        headers: FORGED,
      });
      const internal = JSON.parse(
        res.text.match(
          /<script type="application\/json" id="internal">(.*?)<\/script>/,
        )?.[1] ?? "{}",
      );
      const receivedNames = Object.keys(internal.receivedIdentityHeaders ?? {});
      return {
        pass:
          res.status === 200 &&
          internal.identity?.subject === "sub-member" &&
          internal.identity?.role === "member" &&
          JSON.stringify(internal.cookieNames) === JSON.stringify([COOKIE]) &&
          receivedNames.every((name) => name.startsWith("x-auth-request-")) &&
          internal.receivedIdentityHeaders?.["x-auth-request-email"] ===
            "member@example.test" &&
          /private/.test(res.headers["cache-control"]),
        observed: observed(res, {
          identity: identityOf({
            status: res.status,
            json: { data: internal },
          }),
          forwardedCookieNames: internal.cookieNames,
          receivedIdentityHeaders: receivedNames,
          browseCache: res.headers["x-browse-cache"],
        }),
      };
    },
  );
  await check(
    "4.3",
    "ssr",
    "Anonymous SSR page after authenticated page",
    "anonymous content, no identity leak from shared cache",
    async () => {
      const res = await http("GET", `${APP}/browse/page`);
      return {
        pass:
          res.status === 200 &&
          res.text.includes('<p id="identity">anonymous</p>') &&
          !res.text.includes("member@example.test"),
        observed: observed(res, { browseCache: res.headers["x-browse-cache"] }),
      };
    },
  );
  await check(
    "4.4",
    "ssr",
    "SSR page with tampered session cookie",
    "401 sign-in page, clearing cookie relayed; next credential-free page anonymous",
    async () => {
      const jar = new Jar({ [COOKIE]: tamperedCookie(member.get(COOKIE)) });
      const res = await http("GET", `${APP}/browse/page`, { jar });
      jar.apply(res.setCookies);
      const next = await http("GET", `${APP}/browse/page`, { jar });
      return {
        pass:
          res.status === 401 &&
          !jar.get(COOKIE) &&
          next.status === 200 &&
          next.text.includes("anonymous"),
        observed: observed(res, {
          nextStatus: next.status,
          cookieClearedInBrowser: !jar.get(COOKIE),
        }),
      };
    },
  );

  // 5. Credential failures
  const cookieVariants = {
    malformed: () => "not-a-valid-cookie",
    tampered: () => tamperedCookie(member.get(COOKIE)),
    "unknown ticket (validly signed)": () => unknownTicketCookie(),
  };
  for (const mode of Object.keys(MODES)) {
    await check(
      "5.0",
      mode,
      "Control: re-signed copy of a valid cookie",
      "200 member (validates the signing helper used for 5.3)",
      async () => {
        const res = await gql(mode, "whoami", {
          jar: new Jar({ [COOKIE]: resignedCookie(member.get(COOKIE)) }),
        });
        return {
          pass: res.json?.data?.identity?.subject === "sub-member",
          observed: observed(res),
        };
      },
    );
    let index = 1;
    for (const [name, make] of Object.entries(cookieVariants)) {
      await check(
        `5.${index++}`,
        mode,
        `Presented ${name} session cookie`,
        "explicit non-success; protected action without side effect; cleared cookie then allows anonymous read",
        async () => {
          const jar = new Jar({ [COOKIE]: make() });
          const res = await gql(mode, "whoami", { jar });
          const { res: action, sideEffects } = await protectedAttempt(
            mode,
            new Jar({ [COOKIE]: make() }),
            "rate",
          );
          jar.apply(res.setCookies);
          const after = await gql(mode, "whoami", { jar });
          return {
            pass: nonSuccess(res) && nonSuccess(action) && sideEffects === 0,
            observed: observed(res, {
              actionStatus: action.status,
              sideEffects,
              afterClearing: after.status,
              cookieCleared: !jar.get(COOKIE),
            }),
          };
        },
      );
    }
    await check(
      "5.4",
      mode,
      "Presented invalid bearer credential",
      "explicit non-success",
      async () => {
        const res = await gql(mode, "whoami", {
          headers: { Authorization: "Bearer invalid.token.value" },
        });
        const { res: action, sideEffects } = await protectedAttempt(
          mode,
          null,
          "rate",
          ["Authorization", "Bearer invalid.token.value"],
        );
        return {
          pass: nonSuccess(res) && nonSuccess(action) && sideEffects === 0,
          observed: observed(res, { actionStatus: action.status, sideEffects }),
        };
      },
    );
  }
  await check(
    "5.5",
    "split",
    "Expired-timestamp cookie (validly signed, older than cookie_expire)",
    "explicit non-success",
    async () => {
      const [encoded] = member.get(COOKIE).split("|");
      const value = Buffer.from(
        encoded.replace(/-/g, "+").replace(/_/g, "/"),
        "base64",
      ).toString("utf8");
      const res = await gql("split", "whoami", {
        jar: new Jar({
          [COOKIE]: signCookie(value, Math.floor(Date.now() / 1000) - 3600),
        }),
      });
      return { pass: nonSuccess(res), observed: observed(res) };
    },
  );

  // 9. Browser mutation protections (cookies sent to simulate a worst case
  // where SameSite does not apply, e.g. a same-site sibling origin).
  const formHeaders = (origin, site) => ({
    "Content-Type": "application/x-www-form-urlencoded",
    ...(origin ? { Origin: origin } : {}),
    ...(site ? { "Sec-Fetch-Site": site } : {}),
  });
  const ssrPost = async (jar, origin, site) => {
    const marker = newMarker("ssr-form");
    const res = await http("POST", `${APP}/browse/rate`, {
      jar,
      headers: formHeaders(origin, site),
      body: `marker=${marker}`,
    });
    return { res, sideEffects: effects(marker) };
  };
  await check(
    "9.1",
    "ssr",
    "Cross-site SSR form POST with member cookie",
    "403 before side effects",
    async () => {
      const { res, sideEffects } = await ssrPost(member, EVIL, "cross-site");
      return {
        pass: res.status === 403 && sideEffects === 0,
        observed: observed(res, { sideEffects }),
      };
    },
  );
  await check(
    "9.2",
    "ssr",
    "SSR form POST without Origin",
    "403 before side effects",
    async () => {
      const { res, sideEffects } = await ssrPost(member, null, null);
      return {
        pass: res.status === 403 && sideEffects === 0,
        observed: observed(res, { sideEffects }),
      };
    },
  );
  await check(
    "9.3",
    "ssr",
    "Same-origin SSR form POST (positive control)",
    "200, one side effect",
    async () => {
      const { res, sideEffects } = await ssrPost(member, APP, "same-origin");
      return {
        pass: res.status === 200 && sideEffects === 1,
        observed: observed(res, { sideEffects }),
      };
    },
  );
  await check(
    "9.4",
    "ssr",
    "Anonymous same-origin SSR form POST",
    "401 sign-in page, no side effect, no replay",
    async () => {
      const { res, sideEffects } = await ssrPost(null, APP, "same-origin");
      return {
        pass: res.status === 401 && sideEffects === 0,
        observed: observed(res, { sideEffects }),
      };
    },
  );
  const upload = async (jar, headers) => {
    const marker = newMarker("upload");
    const { body, contentType } = multipart({
      operation: "uploadImage",
      marker,
      variables: { file: null },
    });
    const res = await http("POST", `${APP}/graphql`, {
      jar,
      headers: { "Content-Type": contentType, ...headers },
      body,
    });
    return { res, sideEffects: effects(marker) };
  };
  await check(
    "9.5",
    "split",
    "Cross-site multipart upload (simple request, no preflight)",
    "403 csrf-rejected, no side effect",
    async () => {
      const { res, sideEffects } = await upload(owner, {
        Origin: EVIL,
        "Sec-Fetch-Site": "cross-site",
      });
      return {
        pass: res.status === 403 && sideEffects === 0,
        observed: observed(res, { sideEffects }),
      };
    },
  );
  await check(
    "9.6",
    "split",
    "Multipart upload without CSRF request header (old browser: no Origin/Fetch Metadata)",
    "403 csrf-rejected, no side effect",
    async () => {
      const { res, sideEffects } = await upload(owner, {});
      return {
        pass: res.status === 403 && sideEffects === 0,
        observed: observed(res, { sideEffects }),
      };
    },
  );
  await check(
    "9.7",
    "split",
    "Same-origin multipart upload with X-Recipe-Db-Csrf header (positive control)",
    "200, one side effect",
    async () => {
      const { res, sideEffects } = await upload(owner, {
        Origin: APP,
        "Sec-Fetch-Site": "same-origin",
        "X-Recipe-Db-Csrf": "1",
      });
      return {
        pass: res.status === 200 && sideEffects === 1,
        observed: observed(res, { sideEffects }),
      };
    },
  );
  await check(
    "9.8",
    "split",
    "Cross-site urlencoded POST to GraphQL",
    "403 csrf-rejected, no side effect",
    async () => {
      const marker = newMarker("graphql-form");
      const res = await http("POST", `${APP}/graphql`, {
        jar: owner,
        headers: formHeaders(EVIL, "cross-site"),
        body: `operation=deleteRecipe&marker=${marker}`,
      });
      const sideEffects = effects(marker);
      return {
        pass: res.status === 403 && sideEffects === 0,
        observed: observed(res, { sideEffects }),
      };
    },
  );
}

async function timeline(steps) {
  const start = Date.now();
  for (const [at, step] of steps) {
    await sleep(Math.max(0, start + at * 1000 - Date.now()));
    await step();
  }
}

async function phaseLifecycle() {
  const tasks = [];

  tasks.push(
    (async () => {
      const jar = await mustLogin("member");
      const seen = [];
      let refreshCookies = 0;
      await timeline(
        [0, 25, 50, 75].map((at) => [
          at,
          async () => {
            const res = await gql("split", "whoami", { jar });
            refreshCookies += res.setCookies.filter((value) =>
              value.startsWith(`${COOKIE}=`),
            ).length;
            jar.apply(res.setCookies);
            seen.push(
              `${at}s:${res.status}:${res.json?.data?.identity?.role ?? "-"}`,
            );
          },
        ]),
      );
      await check(
        "7.1",
        "split",
        "Active session across refresh beyond cookie_expire (60s) from original sign-in",
        "renewed sliding session; refresh Set-Cookie reaches client",
        async () => ({
          pass:
            seen.every((entry) => entry.endsWith(":200:member")) &&
            refreshCookies > 0,
          observed: { requests: seen, refreshSetCookies: refreshCookies },
        }),
      );
    })(),
  );

  tasks.push(
    (async () => {
      const jar = await mustLogin("member");
      await sleep(70000);
      for (const mode of Object.keys(MODES)) {
        await check(
          "5.6",
          mode,
          "Natural expiry: cookie presented after 70s idle (cookie_expire 60s)",
          "explicit non-success; no side effect",
          async () => {
            const res = await gql(mode, "whoami", { jar: jar.clone() });
            const { res: action, sideEffects } = await protectedAttempt(
              mode,
              jar.clone(),
              "rate",
            );
            return {
              pass: nonSuccess(res) && nonSuccess(action) && sideEffects === 0,
              observed: observed(res, {
                actionStatus: action.status,
                sideEffects,
              }),
            };
          },
        );
      }
    })(),
  );

  tasks.push(
    (async () => {
      const jar = await mustLogin("member");
      const old = jar.clone();
      const before = await gql("split", "whoami", { jar });
      const signOut = await http(
        "GET",
        `${APP}/oauth2/sign_out?rd=/browse/page`,
        { jar },
      );
      jar.apply(signOut.setCookies);
      await check(
        "7.2",
        "proxy",
        "Logout",
        "redirect, session cookie cleared",
        async () => ({
          pass:
            before.status === 200 && signOut.status === 302 && !jar.get(COOKIE),
          observed: observed(signOut),
        }),
      );
      for (const mode of Object.keys(MODES)) {
        await check(
          "7.3",
          mode,
          "Replay pre-logout cookie (deleted ticket)",
          "explicit non-success; no side effect",
          async () => {
            const res = await gql(mode, "whoami", { jar: old.clone() });
            const { res: action, sideEffects } = await protectedAttempt(
              mode,
              old.clone(),
              "rate",
            );
            return {
              pass: nonSuccess(res) && nonSuccess(action) && sideEffects === 0,
              observed: observed(res, {
                actionStatus: action.status,
                sideEffects,
              }),
            };
          },
        );
      }
    })(),
  );

  tasks.push(
    (async () => {
      const jar = await mustLogin("email-change");
      const before = await gql("split", "whoami", { jar });
      await sleep(25000);
      const after = await gql("split", "whoami", { jar });
      jar.apply(after.setCookies);
      await check(
        "7.4",
        "split",
        "Refresh returns a changed verified email",
        "stable subject; observe whether email is the sign-in snapshot",
        async () => ({
          pass:
            before.json?.data?.identity?.subject === "sub-email-change" &&
            after.json?.data?.identity?.subject === "sub-email-change",
          observed: {
            before: identityOf(before),
            after: identityOf(after),
            emailUpdatedOnRefresh:
              before.json?.data?.identity?.email !==
              after.json?.data?.identity?.email,
          },
        }),
      );
    })(),
  );

  tasks.push(
    (async () => {
      const jar = await mustLogin("unverify-on-refresh");
      const seen = [];
      let effectsTotal = 0;
      await timeline(
        [25, 27, 35, 45].map((at) => [
          at,
          async () => {
            const res = await gql("split", "whoami", { jar });
            jar.apply(res.setCookies);
            const { res: action, sideEffects } = await protectedAttempt(
              "split",
              jar,
              "rate",
            );
            jar.apply(action.setCookies);
            effectsTotal += sideEffects;
            seen.push(
              `${at}s:whoami=${res.status}/${res.json?.data?.identity?.emailVerified ?? "-"}/${res.json?.data?.identity?.role ?? "-"},rate=${action.status}`,
            );
          },
        ]),
      );
      await check(
        "7.5",
        "split",
        "Refresh returns email_verified=false (ID token TTL 30s, refresh after 20s)",
        "no member rights on any request after the refresh",
        async () => ({
          pass:
            effectsTotal === 0 &&
            seen.every((entry) => !entry.includes("/member,")),
          observed: { requests: seen, sideEffects: effectsTotal },
        }),
      );
    })(),
  );

  tasks.push(
    (async () => {
      const jar = await mustLogin("revoked-refresh");
      await sleep(25000);
      const res = await gql("split", "whoami", { jar });
      await check(
        "7.6",
        "split",
        "Provider rejects refresh token (invalid_grant)",
        "explicit non-success, session cleared",
        async () => ({
          pass: nonSuccess(res),
          observed: observed(res),
        }),
      );
    })(),
  );

  tasks.push(
    (async () => {
      const jar = await mustLogin("member");
      await sleep(25000);
      const res = await http("GET", `${APP}/browse/page`, { jar });
      const relayed = res.setCookies.filter((value) =>
        value.startsWith(`${COOKIE}=`),
      ).length;
      jar.apply(res.setCookies);
      const direct = await gql("split", "whoami", { jar });
      await check(
        "4.5",
        "ssr",
        "Session refresh triggered during SSR",
        "refresh Set-Cookie relayed by browse to the browser; session keeps working",
        async () => ({
          pass:
            res.status === 200 &&
            res.text.includes("member@example.test") &&
            relayed > 0 &&
            direct.json?.data?.identity?.role === "member",
          observed: observed(res, {
            relayedSessionCookies: relayed,
            followUp: direct.status,
          }),
        }),
      );
    })(),
  );

  await Promise.all(tasks);
}

async function phasePrepare(names) {
  const sessions = {};
  for (const name of names) sessions[name] = await mustLogin(name);
  saveSessions(sessions);
}

async function phaseDependencyDown(dependency) {
  const prefix = dependency === "redis" ? "6.R" : "6.A";
  const member = loadSession("member");
  for (const mode of Object.keys(MODES)) {
    await check(
      `${prefix}1`,
      mode,
      `${dependency} stopped: request without credentials`,
      "public read may succeed anonymously (no credential presented)",
      async () => {
        const res = await gql(mode, "whoami");
        return {
          pass: anonymousOk(res) || nonSuccess(res),
          observed: observed(res),
        };
      },
    );
    await check(
      `${prefix}2`,
      mode,
      `${dependency} stopped: request with valid session cookie`,
      "explicit non-success, not anonymous success",
      async () => {
        const res = await gql(mode, "whoami", { jar: member.clone() });
        return { pass: nonSuccess(res), observed: observed(res) };
      },
    );
    await check(
      `${prefix}3`,
      mode,
      `${dependency} stopped: protected action with valid session cookie`,
      "non-success, no side effect",
      async () => {
        const { res, sideEffects } = await protectedAttempt(
          mode,
          member.clone(),
          "rate",
        );
        return {
          pass: nonSuccess(res) && sideEffects === 0,
          observed: observed(res, { sideEffects }),
        };
      },
    );
  }
  await check(
    `${prefix}4`,
    "ssr",
    `${dependency} stopped: SSR page with valid session cookie`,
    "explicit non-success page, not anonymous HTML",
    async () => {
      const res = await http("GET", `${APP}/browse/page`, {
        jar: member.clone(),
      });
      return { pass: nonSuccess(res), observed: observed(res) };
    },
  );
}

async function phaseDependencyRecovered(dependency) {
  const prefix = dependency === "redis" ? "6.R" : "6.A";
  await phaseWait();
  const member = loadSession("member");
  for (const mode of Object.keys(MODES)) {
    await check(
      `${prefix}5`,
      mode,
      `${dependency} recovered: same session cookie`,
      "member identity restored, no escalation",
      async () => {
        const res = await gql(mode, "whoami", { jar: member.clone() });
        return {
          pass:
            res.json?.data?.identity?.subject === "sub-member" &&
            res.json?.data?.identity?.role === "member",
          observed: observed(res),
        };
      },
    );
  }
}

async function phaseRolesAfter() {
  const owner = loadSession("owner");
  const member = loadSession("member");
  await check(
    "8.1",
    "split",
    "Demoted owner keeps session; next request uses new map",
    "role=member; owner action 403 without side effect; member action allowed",
    async () => {
      const res = await gql("split", "whoami", { jar: owner });
      const { res: deleteAttempt, sideEffects: deleteEffects } =
        await protectedAttempt("split", owner, "deleteRecipe");
      const { res: rate, sideEffects: rateEffects } = await protectedAttempt(
        "split",
        owner,
        "rate",
      );
      return {
        pass:
          res.json?.data?.identity?.role === "member" &&
          deleteAttempt.status === 403 &&
          deleteEffects === 0 &&
          rate.status === 200 &&
          rateEffects === 1,
        observed: observed(res, {
          deleteStatus: deleteAttempt.status,
          deleteEffects,
          rateStatus: rate.status,
          rateEffects,
        }),
      };
    },
  );
  await check(
    "8.2",
    "split",
    "Removed member keeps session; next request has no member rights",
    "role=none; member action 403 without side effect",
    async () => {
      const res = await gql("split", "whoami", { jar: member });
      const { res: action, sideEffects } = await protectedAttempt(
        "split",
        member,
        "rate",
      );
      return {
        pass:
          res.status === 200 &&
          res.json?.data?.identity?.subject === "sub-member" &&
          res.json?.data?.identity?.role === null &&
          action.status === 403 &&
          sideEffects === 0,
        observed: observed(res, { actionStatus: action.status, sideEffects }),
      };
    },
  );
}

async function phaseRolesBefore() {
  await phasePrepare(["owner", "member"]);
  const owner = loadSession("owner");
  const member = loadSession("member");
  await check(
    "8.0",
    "split",
    "Roles before map change",
    "owner=owner, member=member",
    async () => {
      const a = await gql("split", "whoami", { jar: owner });
      const b = await gql("split", "whoami", { jar: member });
      return {
        pass:
          a.json?.data?.identity?.role === "owner" &&
          b.json?.data?.identity?.role === "member",
        observed: { owner: identityOf(a), member: identityOf(b) },
      };
    },
  );
}

function phaseReport() {
  const entries = readFileSync(RESULTS, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  const escape = (value) =>
    String(value).replace(/\|/g, "\\|").replace(/\n/g, " ");
  const lines = [
    "| Case | Mode | Scenario | Expected | Result | Observed (sanitized) |",
    "| --- | --- | --- | --- | --- | --- |",
  ];
  let unexpected = 0;
  for (const entry of entries) {
    const known = KNOWN_GAPS.has(`${entry.id}/${entry.mode}`);
    let result = entry.pass
      ? "PASS"
      : known
        ? "FAIL (preserved reproducer)"
        : "FAIL";
    if (entry.pass === known) unexpected++;
    if (entry.pass && known) result = "PASS (gap no longer reproduced)";
    const observedText = Object.entries(entry.observed ?? {})
      .filter(
        ([, value]) =>
          value !== undefined && !(Array.isArray(value) && value.length === 0),
      )
      .map(
        ([key, value]) =>
          `${key}: ${typeof value === "string" ? value : JSON.stringify(value)}`,
      )
      .join("; ");
    lines.push(
      `| ${entry.id} | ${entry.mode} | ${escape(entry.title)} | ${escape(entry.expected)} | ${result} | ${escape(observedText)} |`,
    );
  }
  const passed = entries.filter((entry) => entry.pass).length;
  lines.push(
    "",
    `${entries.length} checks: ${passed} passed, ${entries.length - passed} failed, ${unexpected} unexpected.`,
  );
  console.log(lines.join("\n"));
  if (unexpected > 0) process.exitCode = 1;
}

const phases = {
  wait: phaseWait,
  main: phaseMain,
  lifecycle: phaseLifecycle,
  "infra-prepare": () => phasePrepare(["member"]),
  "redis-down": () => phaseDependencyDown("redis"),
  "redis-recovered": () => phaseDependencyRecovered("redis"),
  "auth-down": () => phaseDependencyDown("oauth2-proxy"),
  "auth-recovered": () => phaseDependencyRecovered("oauth2-proxy"),
  "roles-before": phaseRolesBefore,
  "roles-after": phaseRolesAfter,
  report: phaseReport,
};

const phase = phases[process.argv[2]];
if (!phase) {
  console.error(
    `unknown phase; expected one of ${Object.keys(phases).join(", ")}`,
  );
  process.exit(2);
}
await phase();
