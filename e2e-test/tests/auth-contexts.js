import { request as apiRequest } from "@playwright/test";

const API_METHODS = ["delete", "fetch", "get", "head", "patch", "post", "put"];

export async function createAuthIdentity(
  browser,
  identity,
  token,
  appOrigin,
  contextOptions = {},
) {
  const origin = new URL(appOrigin).origin;
  const browserContext = await browser.newContext(contextOptions);
  await browserContext.route("**/*", async (route) => {
    const requestUrl = new URL(route.request().url());
    if (
      requestUrl.origin === origin &&
      requestUrl.pathname.startsWith("/design/")
    ) {
      const headers = Object.fromEntries(
        Object.entries(route.request().headers()).filter(
          ([name]) =>
            name.toLowerCase() !== "authorization" &&
            name.toLowerCase() !== "cookie",
        ),
      );
      let assetUrl = requestUrl;
      let response = await route.fetch({ headers, maxRedirects: 0 });
      for (
        let redirects = 0;
        redirects < 5 && [301, 302, 303, 307, 308].includes(response.status());
        redirects++
      ) {
        const location = response.headers()["location"];
        if (!location) break;
        const nextUrl = new URL(location, assetUrl);
        if (nextUrl.origin !== origin) break;
        assetUrl = nextUrl;
        response = await route.fetch({
          url: assetUrl.href,
          headers,
          maxRedirects: 0,
        });
      }
      await route.fulfill({ response });
      return;
    }

    const headers = Object.fromEntries(
      Object.entries(route.request().headers()).filter(
        ([name]) => name.toLowerCase() !== "authorization",
      ),
    );
    headers.authorization = undefined;
    if (requestUrl.origin === origin && token) {
      headers.authorization = "Bearer " + token;
    }
    const response = await route.fetch({ headers, maxRedirects: 0 });
    await route.fulfill({ response });
  });

  const apiContext = await apiRequest.newContext({
    baseURL: origin,
    maxRedirects: 0,
  });
  let closed = false;
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
    authorizationHeader: token ? "Bearer " + token : undefined,
    api,
    browserContext,
    async close() {
      if (closed) return;
      closed = true;
      await browserContext.unrouteAll({ behavior: "ignoreErrors" });
      await Promise.all([apiContext.dispose(), browserContext.close()]);
    },
  };
}
