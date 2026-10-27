import { request as apiRequest } from "@playwright/test";

const API_METHODS = ["delete", "fetch", "get", "head", "patch", "post", "put"];

export async function createAuthIdentity(browser, identity, token, appOrigin) {
  const origin = new URL(appOrigin).origin;
  const browserContext = await browser.newContext();
  await browserContext.route("**/*", async (route) => {
    const headers = Object.fromEntries(
      Object.entries(route.request().headers()).filter(
        ([name]) => name.toLowerCase() !== "authorization",
      ),
    );
    headers.authorization = undefined;
    if (new URL(route.request().url()).origin === origin && token) {
      headers.authorization = "Bearer " + token;
    }
    const response = await route.fetch({ headers, maxRedirects: 0 });
    await route.fulfill({ response });
  });

  const apiContext = await apiRequest.newContext({
    baseURL: origin,
    maxRedirects: 0,
  });
  const api = Object.fromEntries(
    API_METHODS.map((method) => [
      method,
      (url, options = {}) => {
        const headers = new Headers(options.headers);
        headers.delete("authorization");
        if (new URL(url, origin).origin === origin && token) {
          headers.set("authorization", "Bearer " + token);
        }
        return apiContext[method](url, {
          ...options,
          headers: Object.fromEntries(headers),
          maxRedirects: 0,
        });
      },
    ]),
  );

  return {
    identity,
    api,
    browserContext,
    async close() {
      await Promise.all([apiContext.dispose(), browserContext.close()]);
    },
  };
}
