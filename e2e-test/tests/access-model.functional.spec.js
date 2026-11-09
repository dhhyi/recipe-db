import { test, expect, graphql } from "./fixtures.js";
import { readFile } from "node:fs/promises";

test.use({ trace: "off", resetApplicationData: false });

async function withRecipe(owner, name, use) {
  const { createRecipe } = await graphql(
    owner.api,
    "mutation($value: RecipeInput!) { createRecipe(value: $value) { id name } }",
    { value: { name } },
  );
  try {
    await use(createRecipe);
  } finally {
    await graphql(owner.api, "mutation($id: ID!) { deleteRecipe(id: $id) }", {
      id: createRecipe.id,
    });
  }
}

async function rating(identity, id, includeVote = true) {
  const data = await graphql(
    identity.api,
    `query($id: ID!) { rating(id: $id) { average count${includeVote ? " myRating" : ""} } }`,
    { id },
  );
  return data.rating;
}

async function rate(identity, id, value) {
  return graphql(
    identity.api,
    "mutation($id: ID!, $rating: Int!) { rate(id: $id, rating: $rating) { average count myRating } }",
    { id, rating: value },
  );
}

async function mcp(identity, id, method, params) {
  const response = await identity.api.post("/mcp", {
    headers: {
      Accept: "application/json, text/event-stream",
      "MCP-Protocol-Version": "2025-03-26",
    },
    data: { jsonrpc: "2.0", id, method, params },
  });
  expect(response.status()).toBe(200);
  const body = await response.text();
  const messages = response
    .headers()
    ["content-type"]?.startsWith("text/event-stream")
    ? body
        .split("\n")
        .filter((line) => line.startsWith("data:"))
        .map((line) => JSON.parse(line.slice(5)))
    : [JSON.parse(body)];
  const message = messages.find((value) => value.id === id);
  expect(message).toBeDefined();
  expect(message.error).toBeUndefined();
  return message.result;
}

test("concurrent browser GraphQL and MCP requests preserve each identity", async ({
  authContexts,
  ownerIdentity,
  baseURL,
}) => {
  const first = await authContexts.memberOne();
  const second = await authContexts.memberTwo();
  const anonymous = await authContexts.anonymous();
  await withRecipe(
    ownerIdentity,
    "Access combined concurrency",
    async ({ id }) => {
      await rate(first, id, 2);
      await rate(second, id, 4);
      const clients = [
        [first, 2],
        [second, 4],
        [anonymous, null],
      ];
      const pages = [];
      try {
        for (const [identity] of clients) {
          const page = await identity.browserContext.newPage();
          pages.push(page);
          await page.goto(`${baseURL}/recipe/${id}`);
          await mcp(identity, 1, "initialize", {
            protocolVersion: "2025-03-26",
            capabilities: {},
            clientInfo: { name: "access-concurrency-regression", version: "1" },
          });
        }
        await Promise.all([
          ...clients.map(async ([identity, vote], index) => {
            const result = await mcp(identity, 2, "tools/call", {
              name: "add_rating",
              arguments: { recipeId: id, rating: vote ?? 5 },
            });
            if (vote === null) {
              expect(result.isError).toBe(true);
              expect(result.content[0].text).toContain(
                "authentication-required",
              );
            } else {
              expect(result.isError ?? false).toBe(false);
              expect(JSON.parse(result.content[0].text)).toMatchObject({
                average: 3,
                count: 2,
              });
            }
            await expect(
              pages[index].locator(`#recipe-rating-${id} rating-component`),
            ).toHaveAttribute("rating", "3");
          }),
          ...clients.map(([identity, vote]) =>
            rating(identity, id, vote !== null),
          ),
          ...pages.map((page) => page.reload()),
        ]);
        for (const [index, [identity, vote]] of clients.entries()) {
          const widget = pages[index].locator(
            `#recipe-rating-${id} rating-component`,
          );
          if (vote === null)
            await expect(widget).not.toHaveAttribute("my-rating");
          else await expect(widget).toHaveAttribute("my-rating", String(vote));
          expect(await rating(identity, id, vote !== null)).toEqual({
            average: 3,
            count: 2,
            ...(vote === null ? {} : { myRating: vote }),
          });
        }
      } finally {
        await Promise.all(pages.map((page) => page.close()));
      }
    },
  );
});

test("concurrent members and repeated votes preserve exact aggregates", async ({
  authContexts,
  ownerIdentity,
}) => {
  const first = await authContexts.memberOne();
  const second = await authContexts.memberTwo();
  const anonymous = await authContexts.anonymous();
  await withRecipe(
    ownerIdentity,
    "Access concurrent ratings",
    async ({ id }) => {
      expect(await rating(first, id)).toEqual({
        average: 0,
        count: 0,
        myRating: null,
      });
      expect((await rating(second, id)).myRating).toBeNull();
      await rate(first, id, 5);
      await rate(first, id, 3);
      expect(await rating(first, id)).toEqual({
        average: 3,
        count: 1,
        myRating: 3,
      });
      expect((await rating(second, id)).myRating).toBeNull();
      await Promise.all([
        ...Array.from({ length: 4 }, () => rate(first, id, 2)),
        ...Array.from({ length: 4 }, () => rate(second, id, 4)),
      ]);
      expect(await rating(first, id)).toEqual({
        average: 3,
        count: 2,
        myRating: 2,
      });
      expect(await rating(second, id)).toEqual({
        average: 3,
        count: 2,
        myRating: 4,
      });
      expect(await rating(anonymous, id, false)).toEqual({
        average: 3,
        count: 2,
      });
    },
  );
});

test("denied own-vote fields preserve public GraphQL data and error paths", async ({
  authContexts,
  ownerIdentity,
}) => {
  const anonymous = await authContexts.anonymous();
  const member = await authContexts.memberOne();
  await withRecipe(
    ownerIdentity,
    "Access partial GraphQL",
    async ({ id, name }) => {
      const response = await anonymous.api.post("/graphql", {
        data: {
          query:
            "query($id: ID!) { publicRecipe: recipe(id: $id) { name aggregate: rating { average count own: myRating } } }",
          variables: { id },
        },
      });

      expect(response.status()).toBe(200);
      const result = await response.json();
      expect(result.data).toEqual({
        publicRecipe: { name, aggregate: { average: 0, count: 0, own: null } },
      });
      expect(result.errors).toHaveLength(1);
      expect(result.errors[0].path).toEqual([
        "publicRecipe",
        "aggregate",
        "own",
      ]);
      expect(result.errors[0].extensions).toMatchObject({
        code: "authentication-required",
        status: 401,
      });
      expect(await rating(member, id)).toEqual({
        average: 0,
        count: 0,
        myRating: null,
      });
    },
  );
});

test("role denials and cross-origin writes leave recipe data unchanged", async ({
  authContexts,
  ownerIdentity,
  baseURL,
}) => {
  const anonymous = await authContexts.anonymous();
  const member = await authContexts.memberOne();
  const image = await readFile(
    new URL("./assets/milchreis.png", import.meta.url),
  );
  await withRecipe(ownerIdentity, "Access write guards", async ({ id }) => {
    const snapshot = () =>
      graphql(
        anonymous.api,
        "query($id: ID!) { recipes { id } recipe(id: $id) { name method ingredients { name } image { url } inspirations { url } tags { id } rating { average count } } }",
        { id },
      );
    const before = await snapshot();
    const mutations = [
      'mutation { createRecipe(value: {name: "Denied access recipe"}) { id } }',
      `mutation { updateRecipe(id: "${id}", value: {name: "Denied", inspirations: ["https://example.test/denied"]}) { id } }`,
      `mutation { deleteRecipe(id: "${id}") }`,
      `mutation { rate(id: "${id}", rating: 1) { count } }`,
    ];
    for (const [identity, code, status] of [
      [anonymous, "authentication-required", 401],
      [member, "forbidden", 403],
    ]) {
      for (const query of identity === member
        ? mutations.slice(0, 3)
        : mutations) {
        const response = await identity.api.post("/graphql", {
          data: { query },
          headers: { Origin: new URL(baseURL).origin },
        });
        const result = await response.json();
        expect(result.errors).toHaveLength(1);
        expect(result.errors[0].extensions).toMatchObject({ code, status });
      }
    }
    const upload = {
      operations: JSON.stringify({
        query:
          "mutation($id: ID!, $file: Upload!) { setImage(recipeId: $id, file: $file) { url } }",
        variables: { id, file: null },
      }),
      map: '{"0":["variables.file"]}',
      0: { name: "test.png", mimeType: "image/png", buffer: image },
    };
    for (const [identity, code, status] of [
      [anonymous, "authentication-required", 401],
      [member, "forbidden", 403],
      [ownerIdentity, "csrf-forbidden", 403],
    ]) {
      const response = await identity.api.post("/graphql", {
        multipart: upload,
        headers: {
          Origin:
            identity === ownerIdentity
              ? "https://attacker.test"
              : new URL(baseURL).origin,
        },
      });
      const result = await response.json();
      expect(result.errors[0].extensions).toMatchObject({ code, status });
    }
    for (const Origin of ["https://attacker.test", "null"]) {
      const response = await ownerIdentity.api.post("/graphql", {
        data: {
          query: `mutation { updateRecipe(id: "${id}", value: {name: "Cross-origin"}) { id } }`,
        },
        headers: { Origin },
      });
      expect((await response.json()).errors[0].extensions).toMatchObject({
        code: "csrf-forbidden",
        status: 403,
      });
    }
    for (const identity of [anonymous, member, ownerIdentity]) {
      const response = await identity.api.post(`/recipe/${id}/rate`, {
        form: { rating: "1" },
        headers: { Origin: "https://attacker.test" },
      });
      expect(response.status()).toBe(403);
    }
    expect(await snapshot()).toEqual(before);

    for (const headers of [{}, { Origin: new URL(baseURL).origin }]) {
      const result = await ownerIdentity.api.post("/graphql", {
        data: {
          query: `mutation { updateRecipe(id: "${id}", value: {method: "Allowed"}) { id } }`,
        },
        headers,
      });
      expect((await result.json()).errors).toBeUndefined();
    }
    const uploaded = await ownerIdentity.api.post("/graphql", {
      multipart: upload,
      headers: { Origin: new URL(baseURL).origin },
    });
    expect((await uploaded.json()).data.setImage.url).toBeTruthy();
    const response = await member.api.post(`/recipe/${id}/rate`, {
      form: { rating: "5" },
      headers: { Origin: new URL(baseURL).origin },
    });
    expect(response.status()).toBe(200);
    expect(await rating(member, id)).toEqual({
      average: 5,
      count: 1,
      myRating: 5,
    });
  });
});

test("direct editor navigation denies anonymous and member management", async ({
  authContexts,
  ownerIdentity,
  baseURL,
}) => {
  await withRecipe(
    ownerIdentity,
    "Access editor navigation",
    async ({ id }) => {
      for (const [identity, heading] of [
        [await authContexts.anonymous(), "Anmeldung erforderlich"],
        [await authContexts.memberOne(), "Keine Berechtigung"],
      ]) {
        const page = await identity.browserContext.newPage();
        try {
          for (const path of [`/edit/${id}`, `/images-edit/${id}`]) {
            await page.goto(`${baseURL}${path}`);
            await expect(
              page.getByRole("heading", { name: heading }),
            ).toBeVisible();
            await expect(
              page.locator("main form, main input[type=file]"),
            ).toHaveCount(0);
            await page.getByRole("link", { name: "Zurück zum Rezept" }).click();
            await expect(page.locator('h1[itemprop="name"]')).toHaveText(
              "Access editor navigation",
            );
          }
        } finally {
          await page.close();
        }
      }
    },
  );
});

test("an invalid credential during save requires explicit recovery without mutation replay", async ({
  authContexts,
  ownerIdentity,
  baseURL,
}) => {
  await withRecipe(ownerIdentity, "Access no replay", async ({ id, name }) => {
    const page = await ownerIdentity.browserContext.newPage();
    let invalid = false;
    let mutations = 0;
    await page.route("**/graphql", async (route) => {
      const request = route.request();
      const query = request.postDataJSON()?.query ?? "";
      if (query.includes("mutation")) mutations += 1;
      if (invalid) {
        const response = await route.fetch({
          headers: {
            ...request.headers(),
            authorization: "Bearer deliberately-invalid",
          },
        });

        await route.fulfill({ response });
      } else {
        await route.fallback();
      }
    });
    page.on("dialog", (dialog) => dialog.accept());
    try {
      await page.goto(`${baseURL}/edit/${id}`);
      const form = page.locator("main form");
      await expect(form).toBeVisible();
      await form.locator('input[name="name"]').fill("Must not be replayed");
      invalid = true;
      await page
        .getByRole("button", { name: "Speichern", exact: true })
        .click();
      await expect(
        page.getByRole("heading", { name: "Anmeldung erforderlich" }),
      ).toBeVisible();
      await expect(form).toHaveCount(0);
      expect(mutations).toBe(1);
      invalid = false;
      await page.getByRole("link", { name: "Zurück zum Rezept" }).click();
      await expect(page.locator('h1[itemprop="name"]')).toHaveText(name);
      await page.goto(`${baseURL}/edit/${id}`);
      await expect(form).toBeVisible();
      await expect(form.locator('input[name="name"]')).toHaveValue(name);
      expect(mutations).toBe(1);
    } finally {
      await page.close();
    }
  });
});

test("an invalid image-upload credential never replays a mutation after recovery", async ({
  ownerIdentity,
  baseURL,
}) => {
  await withRecipe(ownerIdentity, "Access image no replay", async ({ id }) => {
    const page = await ownerIdentity.browserContext.newPage();
    let invalid = false;
    let uploads = 0;
    await page.route("**/graphql", async (route) => {
      const request = route.request();
      if (request.postData()?.includes("setImage")) uploads += 1;
      if (invalid) {
        const response = await route.fetch({
          headers: {
            ...request.headers(),
            authorization: "Bearer deliberately-invalid",
          },
        });
        await route.fulfill({ response });
      } else {
        await route.fallback();
      }
    });
    page.on("dialog", (dialog) => dialog.accept());
    try {
      await page.goto(`${baseURL}/images-edit/${id}`);
      await page
        .locator("#upload-image")
        .setInputFiles(
          new URL("./assets/milchreis.png", import.meta.url).pathname,
        );
      const save = page.getByRole("button", { name: "Speichern", exact: true });
      await expect(save).toBeEnabled();
      invalid = true;
      await save.click();
      await expect(page.getByRole("alert")).toContainText(
        "Anmeldung erforderlich oder abgelaufen",
      );
      expect(uploads).toBe(1);
      invalid = false;
      await page
        .getByRole("link", { name: "Zurück zum Rezept", exact: true })
        .click();
      await expect(page.locator('h1[itemprop="name"]')).toHaveText(
        "Access image no replay",
      );
      const data = await graphql(
        ownerIdentity.api,
        "query($id: ID!) { recipe(id: $id) { image { url } } }",
        { id },
      );
      expect(data.recipe.image).toBeNull();
      expect(uploads).toBe(1);
    } finally {
      await page.close();
    }
  });
});

test("public shells and personal HTMX fragments remain isolated between users", async ({
  authContexts,
  ownerIdentity,
  baseURL,
}) => {
  const first = await authContexts.memberOne();
  const second = await authContexts.memberTwo();
  const anonymous = await authContexts.anonymous();
  await withRecipe(ownerIdentity, "Access cache isolation", async ({ id }) => {
    await rate(first, id, 2);
    await rate(second, id, 4);
    let publicHtml;
    let etag;
    for (const [identity, vote, canEdit] of [
      [ownerIdentity, null, true],
      [first, 2, false],
      [anonymous, null, false],
      [second, 4, false],
    ]) {
      const shell = await identity.api.get(`/recipe/${id}`);
      const html = await shell.text();
      expect(shell.status()).toBe(200);
      expect(html).not.toContain("my-rating=");
      expect(html).not.toContain("Rezept bearbeiten");
      if (publicHtml === undefined) {
        publicHtml = html;
        etag = shell.headers().etag;
        expect(etag).toBeTruthy();
      } else {
        expect(html).toBe(publicHtml);
        expect(shell.headers().etag).toBe(etag);
      }
      const fragment = await identity.api.get(`/recipe/${id}/rating`, {
        headers: { "HX-Request": "true" },
      });
      expect(fragment.headers()["cache-control"]).toBe("no-store");
      const body = await fragment.text();
      if (vote === null) expect(body).not.toContain("my-rating=");
      else expect(body).toContain(`my-rating="${vote}"`);
      const controls = await identity.api.get(`/recipe/${id}/controls`);
      expect(controls.headers()["cache-control"]).toBe("no-store");
      expect((await controls.text()).includes("Rezept bearbeiten")).toBe(
        canEdit,
      );

      const page = await identity.browserContext.newPage();
      try {
        await page.goto(`${baseURL}/recipe/${id}`);
        const widget = page.locator(`#recipe-rating-${id} rating-component`);
        await expect(widget).toHaveAttribute("rating", "3");
        if (vote === null)
          await expect(widget).not.toHaveAttribute("my-rating");
        else await expect(widget).toHaveAttribute("my-rating", String(vote));
        await page
          .getByRole("link", { name: "Zur Startseite", exact: true })
          .click();
        await page.waitForURL(new URL("/", baseURL).href, {
          waitUntil: "load",
        });
        await expect(
          page.getByRole("searchbox", { name: "Rezepte suchen" }),
        ).toBeVisible();
        await page.goBack();
        await expect(page).toHaveURL(`${baseURL}/recipe/${id}`);
        await expect(widget).toHaveAttribute("rating", "3");
        if (vote === null)
          await expect(widget).not.toHaveAttribute("my-rating");
        else await expect(widget).toHaveAttribute("my-rating", String(vote));
        expect(
          await page.evaluate(
            () => localStorage.getItem("htmx-history-cache") ?? "",
          ),
        ).not.toContain("my-rating");
      } finally {
        await page.close();
      }
    }
  });
});
