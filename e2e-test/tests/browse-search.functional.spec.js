import { test, expect, graphql, waitForRecipeIndexed } from "./fixtures.js";

function resultsFragment({
  page = 1,
  found = 1,
  ids = ["result"],
  kind = "search",
  query = "boundary",
} = {}) {
  const message =
    kind === "fallback"
      ? "Suche nicht verfügbar. Alle Rezepte werden angezeigt."
      : kind === "error"
        ? "Rezepte konnten nicht geladen werden."
        : found === 0
          ? "Keine Rezepte gefunden."
          : `${found} Rezepte gefunden.`;
  const next = kind === "search" && page * 24 < found;
  return `<section id="browse-results" data-kind="${kind}" data-page="${page}" data-per-page="24" data-found="${found}" data-query="${query}" data-sort="">
    <p data-browse-status role="status" aria-live="polite">${message}</p>
    <div data-recipe-list>${ids.map((id) => `<a data-recipe-id="${id}" href="/recipe/${id}" hx-boost="true" style="display:block;height:200px">Rezept ${id}</a>`).join("")}</div>
    <a href="/edit/new" data-add-recipe aria-label="Neues Rezept hinzufügen">+</a>
    ${next ? `<nav><a data-load-more href="/?q=${query}&page=${page + 1}">Mehr laden</a></nav><div data-sentinel></div>` : ""}
  </section>`;
}

async function manualSentinel(page) {
  await page.addInitScript(() => {
    const observers = [];
    window.IntersectionObserver = class {
      constructor(callback) {
        this.callback = callback;
        this.targets = new Set();
        observers.push(this);
      }
      observe(target) {
        this.targets.add(target);
      }
      unobserve(target) {
        this.targets.delete(target);
      }
      disconnect() {
        this.targets.clear();
      }
    };
    window.triggerBrowseSentinel = () => {
      for (const observer of observers) {
        observer.callback(
          [...observer.targets].map((target) => ({
            target,
            isIntersecting: true,
          })),
          observer,
        );
      }
    };
  });
}

test("search retains explicit sorting, focus and composition state", async ({
  page,
  demoRecipe,
}) => {
  await page.goto("/");
  const search = page.getByRole("searchbox", { name: "Rezepte suchen" });
  const sort = page.getByLabel("Sortieren nach", { exact: true });
  await expect(search).toBeVisible();
  await expect(sort).toBeVisible();
  await sort.selectOption("rating");
  await expect(page).toHaveURL("/?sort=rating");

  await search.fill(demoRecipe.name);
  await expect(page).toHaveURL(
    `/?q=${encodeURIComponent(demoRecipe.name).replaceAll("%20", "+")}&sort=rating`,
  );
  await expect(search).toBeFocused();
  await expect(
    page.getByRole("link", { name: `Rezept ${demoRecipe.name}`, exact: true }),
  ).toBeVisible();
  await search.evaluate((input) => input.setSelectionRange(3, 8));
  await expect
    .poll(() =>
      search.evaluate((input) => [input.selectionStart, input.selectionEnd]),
    )
    .toEqual([3, 8]);

  await search.evaluate((input) => {
    input.dispatchEvent(
      new CompositionEvent("compositionstart", { bubbles: true }),
    );
    input.value = "Unfertige Eingabe";
    input.dispatchEvent(
      new InputEvent("input", { bubbles: true, isComposing: true }),
    );
  });
  await page.waitForTimeout(400);
  await search.press("Enter");
  expect(new URL(page.url()).searchParams.get("q")).toBe(demoRecipe.name);
  await search.evaluate((input) =>
    input.dispatchEvent(
      new CompositionEvent("compositionend", { bubbles: true }),
    ),
  );
  await search.press("Enter");
  await expect(page).toHaveURL("/?q=Unfertige+Eingabe&sort=rating");
  await expect(
    page.getByText("Keine Rezepte gefunden.", { exact: true }),
  ).toBeVisible();
  await search.fill("");
  await search.press("Enter");
  await expect(page).toHaveURL("/?sort=rating");
  await page.reload();
  await expect(sort).toHaveValue("rating");
  await expect(search).toHaveValue("");
  await expect(
    page.getByRole("link", { name: "Neues Rezept hinzufügen" }),
  ).toHaveCount(1);
});

test("German name keys preserve names and use IDs to break ties", async ({
  page,
  request,
}) => {
  const marker = `sortprobe${crypto.randomUUID().replaceAll("-", "")}`;
  const names = [
    "Zwiebel",
    "Straße",
    "Ölsuppe",
    "Banane",
    "Strasse",
    "Äpfelsuppe",
    "Apfel",
  ];
  const recipes = [];
  try {
    for (const name of names) {
      const { createRecipe } = await graphql(
        request,
        "mutation($value: RecipeInput!) { createRecipe(value: $value) { id name createdAt } }",
        { value: { name, method: marker } },
      );
      recipes.push(createRecipe);
    }
    for (const recipe of recipes)
      await waitForRecipeIndexed(request, recipe.id);
    const tied = recipes
      .filter((recipe) => ["Strasse", "Straße"].includes(recipe.name))
      .sort((left, right) => left.id.localeCompare(right.id))
      .map((recipe) => recipe.name);
    await page.goto(`/?q=${marker}&sort=name-asc`);
    const titles = page.locator("main recipe-tile-component [slot=title]");
    await expect(titles).toHaveText([
      "Apfel",
      "Äpfelsuppe",
      "Banane",
      "Ölsuppe",
      ...tied,
      "Zwiebel",
    ]);
    await page
      .getByLabel("Sortieren nach", { exact: true })
      .selectOption("name-desc");
    await expect(titles).toHaveText([
      "Zwiebel",
      ...tied,
      "Ölsuppe",
      "Banane",
      "Äpfelsuppe",
      "Apfel",
    ]);
    await page
      .getByLabel("Sortieren nach", { exact: true })
      .selectOption("newest");
    await expect(titles).toHaveText([...names].reverse());
  } finally {
    for (const recipe of recipes) {
      await graphql(request, "mutation($id: ID!) { deleteRecipe(id: $id) }", {
        id: recipe.id,
      });
    }
  }
});

test("explicit relevance survives an empty query and reload", async ({
  page,
  demoRecipe,
}) => {
  await page.goto("/?sort=relevance");
  const search = page.getByRole("searchbox");
  const sort = page.getByLabel("Sortieren nach", { exact: true });
  await expect(sort).toHaveValue("relevance");
  await search.fill(demoRecipe.name);
  await search.press("Enter");
  await expect(page).toHaveURL(/q=Playwright.*sort=relevance/);
  await search.fill("   ");
  await search.press("Enter");
  await expect(page).toHaveURL("/?sort=relevance");
  await expect(sort).toHaveValue("relevance");
  await page.reload();
  await expect(search).toHaveValue("");
  await expect(sort).toHaveValue("relevance");
});

test("choosing the automatic default explicitly remains a user choice", async ({
  page,
}) => {
  await page.goto("/");
  const sort = page.getByLabel("Sortieren nach", { exact: true });
  await sort.selectOption("newest");
  await expect(page).toHaveURL("/?sort=newest");
  const search = page.getByRole("searchbox");
  await search.fill("Kartoffelsuppe");
  await search.press("Enter");
  await expect(page).toHaveURL("/?q=Kartoffelsuppe&sort=newest");
  await expect(sort).toHaveValue("newest");
  await search.fill("");
  await search.press("Enter");
  await expect(page).toHaveURL("/?sort=newest");
});

test("search controls fit the content area without horizontal overflow", async ({
  page,
}) => {
  await page.goto("/");
  const search = page.getByRole("searchbox", { name: "Rezepte suchen" });
  await expect(search).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    ),
  ).toBeTruthy();
  if (page.viewportSize().width >= 1024) {
    const input = await search.boundingBox();
    const content = await page.locator("main").boundingBox();
    expect(
      Math.abs(input.x + input.width / 2 - content.x - content.width / 2),
    ).toBeLessThan(2);
    expect(
      await page.locator("[data-browse-grid]").evaluate(
        (grid) => getComputedStyle(grid).gridTemplateColumns.split(/\s+/).length,
      ),
    ).toBe(page.viewportSize().width >= 1280 ? 4 : 3);
    await expect(page.locator("[data-add-recipe]")).toHaveCSS("display", "contents");
  }
});

test("ordinary GET search works without JavaScript", async ({
  browser,
  baseURL,
  demoRecipe,
}) => {
  const context = await browser.newContext({
    javaScriptEnabled: false,
    baseURL,
  });
  try {
    const page = await context.newPage();
    await page.goto("/");
    await page
      .getByRole("searchbox", { name: "Rezepte suchen" })
      .fill(demoRecipe.name);
    await page
      .getByLabel("Sortieren nach", { exact: true })
      .selectOption("name-asc");
    await page
      .getByRole("searchbox", { name: "Rezepte suchen" })
      .press("Enter");
    await expect(page).toHaveURL(/q=Playwright.*sort=name-asc/);
    await expect(
      page.getByRole("link", {
        name: `Rezept ${demoRecipe.name}`,
        exact: true,
      }),
    ).toBeVisible();
  } finally {
    await context.close();
  }
});

test("sentinel and keyboard loading serialize requests, deduplicate and stop at the end", async ({
  page,
}) => {
  await manualSentinel(page);
  const requested = [];
  let releaseSecond;
  const secondPending = new Promise((resolve) => {
    releaseSecond = resolve;
  });
  await page.route("**/browse/results?**", async (route) => {
    const url = new URL(route.request().url());
    const pageNumber = Number(url.searchParams.get("page") || 1);
    requested.push(pageNumber);
    if (pageNumber === 2) await secondPending;
    const ids = Array.from(
      { length: pageNumber === 4 ? 1 : 24 },
      (_, index) => `batch-${(pageNumber - 1) * 24 + index}`,
    );
    if (pageNumber === 2) ids[0] = "batch-0";
    await route.fulfill({
      contentType: "text/html",
      body: resultsFragment({ page: pageNumber, found: 73, ids }),
    });
  });
  await page.goto("/");
  await page.getByRole("searchbox").fill("boundary");
  await page.getByRole("searchbox").press("Enter");
  await expect(page.locator("[data-recipe-id]")).toHaveCount(24);
  await page.getByRole("link", { name: "Mehr laden" }).focus();
  await page.getByRole("link", { name: "Mehr laden" }).press("Enter");
  await expect.poll(() => requested).toEqual([1, 2]);
  await page.evaluate(() => window.triggerBrowseSentinel());
  releaseSecond();
  await expect(page.locator("#browse-results")).toHaveAttribute(
    "data-page",
    "2",
  );
  await expect(page.locator("[data-recipe-id]")).toHaveCount(47);
  await page.evaluate(() => window.triggerBrowseSentinel());
  await expect(page.locator("#browse-results")).toHaveAttribute(
    "data-page",
    "3",
  );
  await expect(page.locator("[data-recipe-id]")).toHaveCount(71);
  await page.evaluate(() => window.triggerBrowseSentinel());
  await expect(page.locator("#browse-results")).toHaveAttribute(
    "data-page",
    "4",
  );
  await expect(page.locator("[data-recipe-id]")).toHaveCount(72);
  await expect(page.getByRole("link", { name: "Mehr laden" })).toHaveCount(0);
  await expect(page.locator("[data-add-recipe]")).toHaveCount(1);
  expect(requested).toEqual([1, 2, 3, 4]);
});

test("an empty hydrated page still advances using found metadata", async ({
  page,
}) => {
  await manualSentinel(page);
  const requested = [];
  await page.route("**/browse/results?**", async (route) => {
    const pageNumber = Number(
      new URL(route.request().url()).searchParams.get("page") || 1,
    );
    requested.push(pageNumber);
    await route.fulfill({
      contentType: "text/html",
      body: resultsFragment({
        page: pageNumber,
        found: 49,
        ids: pageNumber === 2 ? [] : [`page-${pageNumber}`],
      }),
    });
  });
  await page.goto("/");
  await page.getByRole("searchbox").fill("boundary");
  await page.getByRole("searchbox").press("Enter");
  await expect(page.locator("[data-recipe-id]")).toHaveCount(1);
  await page.evaluate(() => window.triggerBrowseSentinel());
  await expect(page.locator("#browse-results")).toHaveAttribute(
    "data-page",
    "2",
  );
  await page.evaluate(() => window.triggerBrowseSentinel());
  await expect(page.locator("[data-recipe-id]")).toHaveCount(2);
  expect(requested).toEqual([1, 2, 3]);
});

for (const kind of ["error", "fallback"]) {
  test(`later-page ${kind} never appends unrelated cards`, async ({ page }) => {
    await manualSentinel(page);
    const requested = [];
    await page.route("**/browse/results?**", async (route) => {
      const pageNumber = Number(
        new URL(route.request().url()).searchParams.get("page") || 1,
      );
      requested.push(pageNumber);
      await route.fulfill({
        status: pageNumber === 2 && kind === "error" ? 502 : 200,
        contentType: "text/html",
        body: resultsFragment({
          page: pageNumber,
          found: 48,
          ids:
            pageNumber === 1
              ? ["filtered"]
              : kind === "fallback"
                ? ["unfiltered"]
                : [],
          kind: pageNumber === 1 ? "search" : kind,
        }),
      });
    });
    await page.goto("/");
    await page.getByRole("searchbox").fill("boundary");
    await page.getByRole("searchbox").press("Enter");
    await expect(page.locator("[data-recipe-id=filtered]")).toBeVisible();
    await page.evaluate(() => window.triggerBrowseSentinel());
    await expect(
      page.getByText(
        kind === "error"
          ? "Rezepte konnten nicht geladen werden."
          : "Suche nicht verfügbar. Alle Rezepte werden angezeigt.",
        { exact: true },
      ),
    ).toBeVisible();
    await expect(page.locator("[data-recipe-id=filtered]")).toHaveCount(
      kind === "error" ? 1 : 0,
    );
    await expect(page.locator("[data-recipe-id=unfiltered]")).toHaveCount(
      kind === "fallback" ? 1 : 0,
    );
    if (kind === "fallback") {
      await expect(page.getByRole("searchbox")).toBeDisabled();
      await expect(
        page.getByLabel("Sortieren nach", { exact: true }),
      ).toBeDisabled();
    }
    await page.evaluate(() => window.triggerBrowseSentinel());
    expect(requested).toEqual([1, 2]);
    await expect(page.locator("[data-add-recipe]")).toHaveCount(1);
  });
}

test("a superseded first-page response cannot replace a newer query", async ({
  page,
}) => {
  await manualSentinel(page);
  let release;
  let oldStarted;
  let oldFinished;
  const started = new Promise((resolve) => {
    oldStarted = resolve;
  });
  const finished = new Promise((resolve) => {
    oldFinished = resolve;
  });
  const pending = new Promise((resolve) => {
    release = resolve;
  });
  await page.route("**/browse/results?**", async (route) => {
    const query = new URL(route.request().url()).searchParams.get("q");
    if (query === "old") {
      oldStarted();
      await pending;
    }
    await route
      .fulfill({
        contentType: "text/html",
        body: resultsFragment({ query, ids: [query] }),
      })
      .catch(() => {});
    if (query === "old") oldFinished();
  });
  await page.goto("/");
  const search = page.getByRole("searchbox");
  await search.fill("old");
  await search.press("Enter");
  await started;
  await search.fill("new");
  await search.press("Enter");
  await expect(page.locator("[data-recipe-id=new]")).toBeVisible();
  release();
  await finished;
  await expect(page.locator("[data-recipe-id]")).toHaveCount(1);
  await expect(page.locator("[data-recipe-id=old]")).toHaveCount(0);
  await expect(search).toBeFocused();
});

for (const cacheSize of [10, 0]) {
  test(`Back restores pages, controls and scroll with history cache size ${cacheSize}`, async ({
    page,
    demoRecipe,
  }) => {
    await manualSentinel(page);
    await page.route("**/browse/results?**", async (route) => {
      const number = Number(
        new URL(route.request().url()).searchParams.get("page") || 1,
      );
      const ids = Array.from(
        { length: 24 },
        (_, index) => `history-${number}-${index}`,
      );
      if (number === 1) ids[0] = demoRecipe.id;
      await route.fulfill({
        contentType: "text/html",
        body: resultsFragment({ page: number, found: 72, ids }),
      });
    });
    await page.goto("/");
    const search = page.getByRole("searchbox");
    await search.fill("boundary");
    await search.press("Enter");
    await expect(page.locator("[data-recipe-id]")).toHaveCount(24);
    await page.evaluate(() => window.triggerBrowseSentinel());
    await expect(page.locator("[data-recipe-id]")).toHaveCount(48);
    await page.evaluate(() => window.triggerBrowseSentinel());
    await expect(page.locator("[data-recipe-id]")).toHaveCount(72);
    await page.evaluate((size) => {
      window.htmx.config.historyCacheSize = size;
      window.scrollTo(0, 700);
    }, cacheSize);
    const scroll = await page.evaluate(() => window.scrollY);
    await page
      .locator(`[data-recipe-id="${demoRecipe.id}"]`)
      .evaluate((link) => link.click());
    await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
    await page.goBack();
    await expect(search).toHaveValue("boundary");
    await expect(page.locator("[data-recipe-id]")).toHaveCount(72);
    await expect(page.locator("#browse-results")).toHaveAttribute(
      "data-page",
      "3",
    );
    await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(scroll);
    await expect(page.locator("[data-add-recipe]")).toHaveCount(1);
    await page.reload();
    await expect(page.locator("#browse-results")).toHaveAttribute(
      "data-page",
      "1",
    );
  });
}

test("a sort change cancels an older append generation", async ({ page }) => {
  await manualSentinel(page);
  let release;
  let appendStarted;
  let appendFinished;
  const pending = new Promise((resolve) => {
    release = resolve;
  });
  const started = new Promise((resolve) => {
    appendStarted = resolve;
  });
  const finished = new Promise((resolve) => {
    appendFinished = resolve;
  });
  await page.route("**/browse/results?**", async (route) => {
    const url = new URL(route.request().url());
    const number = Number(url.searchParams.get("page") || 1);
    if (number === 2) {
      appendStarted();
      await pending;
    }
    const id =
      url.searchParams.get("sort") === "updated" ? "new-sort" : `old-${number}`;
    await route
      .fulfill({
        contentType: "text/html",
        body: resultsFragment({ page: number, found: 48, ids: [id] }),
      })
      .catch(() => {});
    if (number === 2) appendFinished();
  });
  await page.goto("/");
  await page.getByRole("searchbox").fill("boundary");
  await page.getByRole("searchbox").press("Enter");
  await expect(page.locator("[data-recipe-id=old-1]")).toBeVisible();
  await page.evaluate(() => window.triggerBrowseSentinel());
  await started;
  await page
    .getByLabel("Sortieren nach", { exact: true })
    .selectOption("updated");
  await expect(page.locator("[data-recipe-id=new-sort]")).toBeVisible();
  release();
  await finished;
  await expect(page.locator("[data-recipe-id]")).toHaveCount(1);
  await expect(page.locator("#browse-results")).toHaveAttribute(
    "data-page",
    "1",
  );
});

test("typing debounces by 300ms while Enter and sorting submit immediately", async ({
  page,
}) => {
  await manualSentinel(page);
  await page.clock.install({ time: new Date("2026-01-01T00:00:00Z") });
  const queries = [];
  await page.route("**/browse/results?**", async (route) => {
    const url = new URL(route.request().url());
    queries.push([url.searchParams.get("q"), url.searchParams.get("sort")]);
    await route.fulfill({
      contentType: "text/html",
      body: resultsFragment({ query: url.searchParams.get("q") }),
    });
  });
  await page.goto("/");
  await page.clock.pauseAt(new Date("2026-01-01T00:00:01Z"));
  const input = page.getByRole("searchbox");
  await input.fill("boundary");
  await page.clock.runFor(299);
  expect(queries).toEqual([]);
  await page.clock.runFor(1);
  await expect.poll(() => queries).toEqual([["boundary", null]]);
  await input.fill("enter");
  await input.press("Enter");
  await expect.poll(() => queries).toHaveLength(2);
  await page
    .getByLabel("Sortieren nach", { exact: true })
    .selectOption("updated");
  await expect.poll(() => queries).toHaveLength(3);
  expect(queries[2]).toEqual(["enter", "updated"]);
});

for (const status of [502, 503]) {
  test(`online failure ${status} removes previous-query cards without fallback`, async ({
    page,
  }) => {
    await manualSentinel(page);
    await page.route("**/browse/results?**", async (route) => {
      const query = new URL(route.request().url()).searchParams.get("q");
      await route.fulfill({
        status: query === "failure" ? status : 200,
        contentType: "text/html",
        body: resultsFragment({
          query,
          kind: query === "failure" ? "error" : "search",
          ids: query === "failure" ? [] : ["previous-query"],
        }),
      });
    });
    await page.goto("/");
    const input = page.getByRole("searchbox");
    await input.fill("boundary");
    await input.press("Enter");
    await expect(page.locator("[data-recipe-id]")).toHaveCount(1);
    await input.fill("failure");
    await input.press("Enter");
    await expect(
      page.getByText("Rezepte konnten nicht geladen werden.", { exact: true }),
    ).toBeVisible();
    await expect(page.locator("[data-recipe-id]")).toHaveCount(0);
    await expect(input).toBeEnabled();
    await expect(
      page.getByLabel("Sortieren nach", { exact: true }),
    ).toBeEnabled();
    await expect(
      page.getByText("Suche nicht verfügbar. Alle Rezepte werden angezeigt."),
    ).toHaveCount(0);
  });
}

test.describe("unenhanced pagination", () => {
  test.use({ demoRecipeCount: 25, demoRecipeWithImage: false });

  test("ordinary links preserve the query and advance to the next page", async ({
    browser,
    baseURL,
    demoRecipes,
  }) => {
    const context = await browser.newContext({
      javaScriptEnabled: false,
      baseURL,
    });
    try {
      const page = await context.newPage();
      await page.goto(
        `/?q=${encodeURIComponent(demoRecipes[0].name)}&sort=newest`,
      );
      await expect(page.locator("[data-recipe-id]")).toHaveCount(24);
      await expect(page.locator("[data-add-recipe]")).toHaveCount(1);
      await page.getByRole("link", { name: "Mehr laden" }).click();
      await expect(page).toHaveURL(/page=2.*sort=newest/);
      await expect(page.locator("[data-recipe-id]")).toHaveCount(1);
      await expect(page.locator("[data-recipe-id]")).toHaveAttribute(
        "data-recipe-id",
        demoRecipes[0].id,
      );
      await expect(page.getByRole("link", { name: "Mehr laden" })).toHaveCount(
        0,
      );
      await expect(page.locator("[data-add-recipe]")).toHaveCount(1);
    } finally {
      await context.close();
    }
  });
});

test("a failed history reconstruction clears a mismatched snapshot", async ({
  page,
  demoRecipe,
}) => {
  await manualSentinel(page);
  let restoring = false;
  await page.route("**/browse/results?**", async (route) => {
    await route.fulfill({
      status: restoring ? 502 : 200,
      contentType: "text/html",
      body: resultsFragment({
        kind: restoring ? "error" : "search",
        found: restoring ? 0 : 2,
        ids: restoring ? [] : [demoRecipe.id, "stale-snapshot"],
      }),
    });
  });
  await page.goto("/");
  await page.getByRole("searchbox").fill("boundary");
  await page.getByRole("searchbox").press("Enter");
  await expect(page.locator("[data-recipe-id]")).toHaveCount(2);
  await page.locator("#browse-results").evaluate((region) => {
    region.dataset.searchKey = JSON.stringify(["older query", "", false]);
  });
  await page.locator(`[data-recipe-id="${demoRecipe.id}"]`).click();
  await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
  restoring = true;
  await page.goBack();
  await expect(
    page.getByText("Rezepte konnten nicht geladen werden.", { exact: true }),
  ).toBeVisible();
  await expect(page.locator("[data-recipe-id]")).toHaveCount(0);
  await expect(page.locator("#browse-results")).toHaveAttribute(
    "data-kind",
    "error",
  );
  await expect(page.locator("[data-add-recipe]")).toHaveCount(1);
});
