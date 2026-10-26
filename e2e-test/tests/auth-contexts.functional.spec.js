import { createServer } from "node:http";
import { test, expect } from "./fixtures.js";

test.use({ trace: "off" });

async function listen(handler) {
  const server = createServer(handler);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return {
    origin: `http://127.0.0.1:${port}`,
    close: () =>
      new Promise((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      }),
  };
}

test("auth contexts isolate identities and keep bearer tokens on the app origin", async ({
  authContexts,
}) => {
  const externalRequests = [];
  const external = await listen((request, response) => {
    externalRequests.push(
      authContexts.identifyAuthorization(request.headers.authorization),
    );
    response.end("external");
  });
  const appRequests = [];
  const app = await listen((request, response) => {
    if (request.url === "/redirect") {
      response.writeHead(302, { location: `${external.origin}/capture` });
      response.end();
      return;
    }
    appRequests.push({
      identity: authContexts.identifyAuthorization(
        request.headers.authorization,
      ),
      cookie: request.headers.cookie ?? "",
    });
    if (request.url === "/set-cookie") {
      response.setHeader("set-cookie", "server-session=isolated; Path=/");
    }
    response.setHeader("content-type", "text/html");
    response.end("<!doctype html><title>Auth fixture</title>");
  });

  try {
    const anonymous = await authContexts.anonymous(app.origin);
    const memberOne = await authContexts.memberOne(app.origin);
    const memberTwo = await authContexts.memberTwo(app.origin);
    const owner = await authContexts.owner(app.origin);

    for (const [context, identity] of [
      [anonymous, null],
      [memberOne, "memberOne"],
      [memberTwo, "memberTwo"],
      [owner, "owner"],
    ]) {
      const response = await context.api.get(`${app.origin}/capture`);
      expect(response.ok()).toBe(true);
      expect(appRequests.at(-1).identity).toBe(identity);
    }
    await memberOne.api.get(`${app.origin}/set-cookie`);
    await memberOne.api.get(`${app.origin}/capture`);
    expect(appRequests.at(-1).cookie).toContain("server-session=isolated");
    await memberTwo.api.get(`${app.origin}/capture`);
    expect(appRequests.at(-1).cookie).toBe("");

    const redirected = await memberOne.api.get(`${app.origin}/redirect`);
    expect(redirected.status()).toBe(302);
    await memberOne.api.get(`${external.origin}/capture`);
    expect(externalRequests).toEqual([null]);

    await memberOne.browserContext.addCookies([
      { name: "identity", value: "member-one", url: app.origin },
    ]);
    const anonymousPage = await anonymous.browserContext.newPage();
    await anonymousPage.goto(`${app.origin}/capture`);
    expect(appRequests.at(-1).identity).toBe(null);

    const memberOnePage = await memberOne.browserContext.newPage();
    await memberOnePage.goto(`${app.origin}/capture`);
    expect(appRequests.at(-1).identity).toBe("memberOne");
    await memberOnePage.goto(`${app.origin}/redirect`);
    expect(externalRequests).toEqual([null, null]);

    const memberTwoPage = await memberTwo.browserContext.newPage();
    await memberTwoPage.goto(`${app.origin}/capture`);
    expect(appRequests.at(-1).identity).toBe("memberTwo");
    expect(await memberTwoPage.evaluate(() => document.cookie)).toBe("");

    const ownerPage = await owner.browserContext.newPage();
    await ownerPage.goto(`${app.origin}/capture`);
    expect(appRequests.at(-1).identity).toBe("owner");
  } finally {
    await Promise.all([app.close(), external.close()]);
  }
});
