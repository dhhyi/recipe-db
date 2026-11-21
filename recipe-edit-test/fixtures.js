import { test as base, expect } from "@playwright/test";
import { readFileSync } from "node:fs";
import { isDeepStrictEqual } from "node:util";
import { buildSchema, getOperationAST, parse, print } from "graphql";
import { validateMock } from "./mock-validation.js";

const schema = buildSchema(
  readFileSync(new URL("./recipe-db.graphqls", import.meta.url), "utf8"),
);

export { expect };
export const test = base.extend({
  graphqlMocks: [[], { option: true }],
  identityHtml: [undefined, { option: true }],
  returnDocument: [undefined, { option: true }],
  mockBackend: [
    async (
      { context, baseURL, graphqlMocks, identityHtml, returnDocument },
      use,
    ) => {
      const origin = new URL(baseURL).origin;
      const failures = [];
      const mocks = structuredClone(graphqlMocks);
      for (const mock of mocks) {
        validateMock(schema, mock);
      }
      await context.route("**/*", async (route) => {
        const request = route.request();
        const url = new URL(request.url());
        const reject = async (message) => {
          failures.push(message);
          await route.abort("blockedbyclient");
        };
        if (url.origin !== origin) {
          await reject(`Unexpected external request: ${request.url()}`);
          return;
        }
        if (url.pathname === "/graphql") {
          try {
            if (request.method() !== "POST") {
              throw new Error(`Unexpected GraphQL method: ${request.method()}`);
            }
            const body = request.postDataJSON();
            const document = parse(body.query);
            const operation = getOperationAST(document, body.operationName);
            const mock = mocks.find(
              (candidate) =>
                candidate.operationName === operation?.name?.value &&
                print(parse(candidate.query)) === print(document) &&
                isDeepStrictEqual(candidate.variables, body.variables ?? {}),
            );
            if (!mock) {
              throw new Error(
                `Unexpected GraphQL operation or variables: ${JSON.stringify(body)}`,
              );
            }
            validateMock(schema, mock);
            await route.fulfill({
              contentType: "application/json",
              body: JSON.stringify(mock.response),
            });
          } catch (error) {
            await reject(`GraphQL mock failed: ${error.message}`);
          }
          return;
        }
        if (request.method() === "GET" && url.pathname === "/identity") {
          if (typeof identityHtml !== "string") {
            await reject("Unexpected identity request: no test-specific mock");
            return;
          }
          await route.fulfill({
            contentType: "text/html",
            body: identityHtml,
          });
          return;
        }
        if (
          request.method() === "GET" &&
          (url.pathname.startsWith("/edit/") ||
            url.pathname.startsWith("/design/"))
        ) {
          await route.continue();
          return;
        }
        if (
          request.method() === "GET" &&
          request.isNavigationRequest() &&
          (url.pathname === "/" || url.pathname.startsWith("/recipe/"))
        ) {
          if (typeof returnDocument !== "string") {
            await reject(`Unexpected return navigation: ${url}`);
            return;
          }
          await route.fulfill({
            contentType: "text/html",
            body: returnDocument,
          });
          return;
        }
        await reject(`Unexpected backend request: ${request.method()} ${url}`);
      });
      try {
        await use();
      } finally {
        await context.close();
        expect(failures, "All backend requests must be mocked").toEqual([]);
      }
    },
    { auto: true },
  ],
});
