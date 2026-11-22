import { test as base, expect } from "@playwright/test";
import { readFileSync } from "node:fs";
import { isDeepStrictEqual } from "node:util";
import { buildSchema, getOperationAST, parse, print } from "graphql";
import { createMockGates } from "./mock-gates.js";
import { takeMockResponse, validateMock } from "./mock-validation.js";

const schema = buildSchema(
  readFileSync(new URL("./recipe-db.graphqls", import.meta.url), "utf8"),
);

export { expect };
export const test = base.extend({
  graphqlMocks: [[], { option: true }],
  imageMocks: [{}, { option: true }],
  identityHtml: [undefined, { option: true }],
  returnDocument: [undefined, { option: true }],
  // Gates are keyed by the operation's first root field, e.g. "reorderImages".
  graphqlGates: async ({}, use) => {
    await use(createMockGates());
  },
  mockBackend: [
    async (
      {
        context,
        baseURL,
        graphqlMocks,
        graphqlGates,
        imageMocks,
        identityHtml,
        returnDocument,
      },
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
            if (request.method() !== "POST" && request.method() !== "GET") {
              throw new Error(`Unexpected GraphQL method: ${request.method()}`);
            }
            let body;
            if (request.method() === "GET") {
              body = {
                query: url.searchParams.get("query"),
                operationName: url.searchParams.get("operationName"),
                variables: JSON.parse(
                  url.searchParams.get("variables") || "{}",
                ),
              };
            } else if (
              request
                .headers()
                ["content-type"]?.startsWith("multipart/form-data")
            ) {
              const form = await new Response(request.postDataBuffer(), {
                headers: { "content-type": request.headers()["content-type"] },
              }).formData();
              body = JSON.parse(form.get("operations"));
              const map = JSON.parse(form.get("map"));
              const file = form.get("0");
              if (
                !isDeepStrictEqual(map, { 0: ["variables.file"] }) ||
                !(file instanceof File) ||
                body.variables?.file !== null ||
                !isDeepStrictEqual([...form.keys()].sort(), [
                  "0",
                  "map",
                  "operations",
                ])
              ) {
                throw new Error("Invalid image upload multipart request");
              }
              body.variables.file = {
                name: file.name,
                type: file.type,
                size: file.size,
              };
            } else {
              body = request.postDataJSON();
            }
            const document = parse(body.query);
            const operation = getOperationAST(document, body.operationName);
            const mock = mocks.find(
              (candidate) =>
                (candidate.operationName ?? null) ===
                  (operation?.name?.value ?? null) &&
                print(parse(candidate.query)) === print(document) &&
                isDeepStrictEqual(candidate.variables, body.variables ?? {}),
            );
            if (!mock) {
              throw new Error(
                `Unexpected GraphQL operation or variables: ${JSON.stringify(body)}`,
              );
            }
            const response = takeMockResponse(mock);
            await graphqlGates.run(
              operation.selectionSet.selections[0].name.value,
              async () => {
                try {
                  await route.fulfill({
                    contentType: "application/json",
                    body: JSON.stringify(response),
                  });
                } catch (error) {
                  await reject(`GraphQL mock failed: ${error.message}`);
                }
              },
            );
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
          Object.hasOwn(imageMocks, url.pathname)
        ) {
          await route.fulfill(imageMocks[url.pathname]);
          return;
        }
        if (
          request.method() === "GET" &&
          (url.pathname.startsWith("/images-edit/") ||
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
        try {
          await graphqlGates.releaseAll();
        } finally {
          await context.close();
        }
        expect(failures, "All backend requests must be mocked").toEqual([]);
      }
    },
    { auto: true },
  ],
});
