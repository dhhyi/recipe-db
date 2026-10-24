import { test, expect, graphql, waitForRecipeIndexed } from "./fixtures.js";
import { allowDesignAssets } from "./browse-error.helpers.js";

function resultsFragment({
  page = 1,
  found = 1,
  ids = ["result"],
  kind = "search",
  query = "boundary",
  sort = "",
  append = false,
  seen = [],
} = {}) {
  const next = kind === "search" && page * 24 < found;
  const count = `${found} ${found === 1 ? "Rezept" : "Rezepte"}`;
  const message =
    kind === "fallback"
      ? "Suche nicht verfügbar. Alle Rezepte werden angezeigt."
      : kind === "error"
        ? "Rezepte konnten nicht geladen werden."
        : append && !next
          ? `${count} gefunden. Alle Rezepte geladen.`
          : found === 0
            ? "Keine Rezepte gefunden."
            : `${count} gefunden.`;
  const nextURL = `/?page=${page + 1}&q=${query}${sort ? `&sort=${sort}` : ""}`;
  const metadata = `<p id="browse-metadata" ${append ? 'hx-swap-oob="outerHTML"' : ""} data-kind="${kind}" data-page="${page}" data-per-page="24" data-found="${found}" data-query="${query}" data-sort="${sort}" data-browse-status role="status" aria-live="polite">${message}</p>`;
  const values = JSON.stringify({ seen: [...new Set([...seen, ...ids])] });
  const cards = [...new Set(ids)]
    .filter((id) => !append || !seen.includes(id))
    .map(
      (id) =>
        `<a data-recipe-id="${id}" href="/recipe/${id}" hx-boost="true" style="display:block;height:200px">Rezept ${id}</a>`,
    )
    .join("");
  const pagination = next
    ? `<div id="browse-pagination"><nav><a data-load-more data-sentinel href="${nextURL}" hx-get="${nextURL}" hx-vals='${values}' hx-trigger="intersect once, click" hx-target="#browse-pagination" hx-swap="outerHTML show:none" hx-sync="#browse-form:abort">Mehr laden</a></nav></div>`
    : "";
  if (append) return metadata + cards + pagination;
  return `<section id="browse-results">
    ${metadata}
    <div data-recipe-list>${cards}${pagination}</div>
    <a href="/edit/new" data-add-recipe aria-label="Neues Rezept hinzufügen">+</a>
  </section>`;
}

// Keep the real server-rendered form and HTMX attributes in mocked boundary
// responses. Only hit data is synthetic; request/swap/history behavior is real HTMX.
async function fulfillBrowse(route, options = {}) {
  const response = await route.fetch(
    options.kind === "fallback"
      ? { headers: { ...route.request().headers(), "hx-request": "false" } }
      : {},
  );
  const url = new URL(route.request().url());
  const query = url.searchParams.get("q") || "";
  const sort = url.searchParams.get("sort") || "";
  const number = Number(url.searchParams.get("page") || 1);
  const kind = options.kind || "search";
  const append =
    kind === "search" &&
    route.request().headers()["hx-target"] === "browse-pagination";
  const seen = url.searchParams.getAll("seen");
  const found = options.found ?? 1;
  const heading =
    kind === "search" && query
      ? `${found} ${found === 1 ? "Rezept" : "Rezepte"} für '${query}'`
      : "Alle Rezepte";
  const headingHTML = `<h1 id="browse-heading" hx-swap-oob="outerHTML">${heading}</h1>`;
  const title =
    kind === "error"
      ? "Rezepte konnten nicht geladen werden | RezeptDB"
      : `${heading} | RezeptDB`;
  let body = (await response.text())
    .replace(
      /<section id="browse-results"[\s\S]*?<\/section>/,
      resultsFragment({ page: number, query, sort, ...options }),
    )
    .replace(/<title>[\s\S]*?<\/title>/, `<title>${title}</title>`)
    .replace(
      /(<h1 id="browse-heading"[^>]*>)[\s\S]*?<\/h1>/,
      `$1${heading}</h1>`,
    );
  if (append)
    body = `<title>${title}</title>${headingHTML}${resultsFragment({
      page: number,
      query,
      sort,
      ...options,
      append,
      seen,
    })}`;
  if (kind === "fallback")
    body = `<title>${title}</title>${body.match(/<main>([\s\S]*)<\/main>/)[1]}`
      .replaceAll('name="q"', 'disabled name="q"')
      .replaceAll('name="sort"', 'disabled name="sort"')
      .replaceAll('type="submit"', 'disabled type="submit"');
  if (!sort) url.searchParams.delete("sort");
  url.searchParams.delete("seen");
  if (number === 1) url.searchParams.delete("page");
  url.searchParams.sort();
  await route.fulfill({
    status: 200,
    contentType: "text/html",
    headers: {
      "HX-Replace-Url": url.pathname + url.search,
      ...(kind === "fallback" ? { "HX-Retarget": "#browse-content" } : {}),
    },
    body,
  });
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

async function triggerSentinel(page) {
  await expect(page.locator(".htmx-settling")).toHaveCount(0);
  await page.evaluate(() => window.triggerBrowseSentinel());
}

test("banner resets search without losing the header or form", async ({
  page,
}) => {
  await page.goto("/?q=banner-reset&sort=rating");
  const banner = page.locator("header-component a[href='/']");
  await expect(banner).toBeVisible();
  const response = page.waitForResponse(
    (response) =>
      new URL(response.url()).pathname === "/" &&
      response.request().headers()["hx-boosted"] === "true",
  );
  await banner.click();
  expect((await response).ok()).toBeTruthy();
  await expect(page).toHaveURL("/");
  await expect(banner).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Alle Rezepte" }),
  ).toBeVisible();
  await expect(
    page.getByRole("searchbox", { name: "Rezepte suchen" }),
  ).toHaveValue("");
  await expect(page.getByLabel("Sortieren nach", { exact: true })).toHaveValue(
    "",
  );
  await expect(page.locator("#browse-results")).toBeVisible();
});

test("search retains explicit sorting, focus and composition state", async ({
  page,
  demoRecipe,
}) => {
  await waitForRecipeIndexed(page.request, demoRecipe.id);
  const sentQueries = [];
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (url.pathname === "/" && request.headers()["hx-request"] === "true")
      sentQueries.push(url.searchParams.get("q"));
  });
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
  await expect(page).toHaveTitle(
    `1 Rezept für '${demoRecipe.name}' | RezeptDB`,
  );
  await expect(
    page.getByRole("link", { name: `Rezept ${demoRecipe.name}`, exact: true }),
  ).toBeVisible();
  await search.evaluate((input) => input.setSelectionRange(3, 8));
  await expect
    .poll(() =>
      search.evaluate((input) => [input.selectionStart, input.selectionEnd]),
    )
    .toEqual([3, 8]);

  // An already scheduled debounce must not submit an unfinished composition.
  const beforeComposition = sentQueries.length;
  await search.fill("pending");
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
  expect(sentQueries).toHaveLength(beforeComposition);
  await search.press("Enter");
  expect(new URL(page.url()).searchParams.get("q")).toBe(demoRecipe.name);
  expect(sentQueries).toHaveLength(beforeComposition);
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
  await page.waitForTimeout(400);
  expect(sentQueries.slice(beforeComposition)).toEqual(["Unfertige Eingabe"]);
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

test("automatic sorting, titles and headings follow the current query", async ({
  page,
  demoRecipe,
}) => {
  await waitForRecipeIndexed(page.request, demoRecipe.id);
  await page.goto("/");
  const sort = page.getByLabel("Sortieren nach", { exact: true });
  const search = page.getByRole("searchbox");
  await expect(sort.locator("option:checked")).toHaveText(
    "Automatisch: Neueste zuerst",
  );
  await expect(page).toHaveTitle("Alle Rezepte | RezeptDB");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "Alle Rezepte",
  );
  await search.fill(demoRecipe.name);
  await expect(page.locator("#browse-metadata")).toHaveAttribute(
    "data-query",
    demoRecipe.name,
  );
  await expect(sort.locator("option:checked")).toHaveText(
    "Automatisch: Relevanz",
  );
  await expect(page).toHaveTitle(
    `1 Rezept für '${demoRecipe.name}' | RezeptDB`,
  );
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    `1 Rezept für '${demoRecipe.name}'`,
  );
  await expect(page.locator("#browse-metadata")).toHaveText(
    "1 Rezept gefunden.",
  );
  await page.reload();
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    `1 Rezept für '${demoRecipe.name}'`,
  );
  await search.fill("");
  await search.press("Enter");
  await expect(page).toHaveURL("/");
  await expect(sort.locator("option:checked")).toHaveText(
    "Automatisch: Neueste zuerst",
  );
  await expect(page).toHaveTitle("Alle Rezepte | RezeptDB");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "Alle Rezepte",
  );
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
  for (const name of names) {
    const { createRecipe } = await graphql(
      request,
      "mutation($value: RecipeInput!) { createRecipe(value: $value) { id name createdAt } }",
      { value: { name, method: marker } },
    );
    recipes.push(createRecipe);
  }
  for (const recipe of recipes) await waitForRecipeIndexed(request, recipe.id);
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
});

test("explicit relevance survives an empty query and reload", async ({
  page,
  demoRecipe,
}) => {
  await waitForRecipeIndexed(page.request, demoRecipe.id);
  await page.goto("/?sort=relevance");
  const search = page.getByRole("searchbox");
  const sort = page.getByLabel("Sortieren nach", { exact: true });
  await expect(sort).toHaveValue("relevance");
  await search.fill(demoRecipe.name);
  await search.press("Enter");
  await expect(page).toHaveURL(/q=E2E.*sort=relevance/);
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
    const searchControls = await page.getByRole("search").boundingBox();
    const sort = await page.getByLabel("Sortieren nach", { exact: true });
    const sortControls = await sort.boundingBox();
    const content = await page.locator("main").boundingBox();
    expect(Math.abs(searchControls.x - content.x)).toBeLessThan(2);
    expect(
      Math.abs(sortControls.x + sortControls.width - content.x - content.width),
    ).toBeLessThan(2);
    expect(
      await page
        .locator("[data-browse-grid]")
        .evaluate(
          (grid) =>
            getComputedStyle(grid).gridTemplateColumns.split(/\s+/).length,
        ),
    ).toBe(page.viewportSize().width >= 1280 ? 4 : 3);
    await expect(page.locator("[data-add-recipe]")).toHaveCSS(
      "display",
      "contents",
    );
  }
});

test("ordinary GET search works without JavaScript", async ({
  browser,
  baseURL,
  request,
  demoRecipe,
}) => {
  await waitForRecipeIndexed(request, demoRecipe.id);
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
    await expect(page).toHaveURL(/q=E2E.*sort=name-asc/);
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
  await page.route(/\/\?[^#]*\bq=/, async (route) => {
    const url = new URL(route.request().url());
    const pageNumber = Number(url.searchParams.get("page") || 1);
    requested.push(pageNumber);
    if (pageNumber === 2) await secondPending;
    const ids = Array.from(
      { length: Math.min(pageNumber * 24, 73) },
      (_, index) => `batch-${index}`,
    ).filter((_, index) => index !== 24);
    await fulfillBrowse(route, { page: pageNumber, found: 73, ids });
  });
  await page.goto("/");
  await page.getByRole("searchbox").fill("boundary");
  await page.getByRole("searchbox").press("Enter");
  await expect(page.locator("[data-recipe-id]")).toHaveCount(24);
  await page.locator("[data-recipe-id=batch-0]").evaluate((card) => {
    card.dataset.originalNode = "true";
  });
  await page.getByRole("link", { name: "Mehr laden" }).focus();
  await page.getByRole("link", { name: "Mehr laden" }).press("Enter");
  await expect.poll(() => requested).toEqual([1, 2]);
  await triggerSentinel(page);
  releaseSecond();
  await expect(page.locator("#browse-metadata")).toHaveAttribute(
    "data-page",
    "2",
  );
  await expect(page.locator("[data-recipe-id]")).toHaveCount(47);
  await expect(page.locator("[data-recipe-id=batch-0]")).toHaveAttribute(
    "data-original-node",
    "true",
  );
  await triggerSentinel(page);
  await expect(page.locator("#browse-metadata")).toHaveAttribute(
    "data-page",
    "3",
  );
  await expect(page.locator("[data-recipe-id]")).toHaveCount(71);
  await triggerSentinel(page);
  await expect(page.locator("#browse-metadata")).toHaveAttribute(
    "data-page",
    "4",
  );
  await expect(page.locator("[data-recipe-id]")).toHaveCount(72);
  await expect(page.getByRole("status")).toHaveText(
    "73 Rezepte gefunden. Alle Rezepte geladen.",
  );
  await expect(page.getByRole("link", { name: "Mehr laden" })).toHaveCount(0);
  await expect(page.locator("[data-add-recipe]")).toHaveCount(1);
  expect(requested).toEqual([1, 2, 3, 4]);
});

test("an empty hydrated page still advances using found metadata", async ({
  page,
}) => {
  await manualSentinel(page);
  const requested = [];
  await page.route(/\/\?[^#]*\bq=/, async (route) => {
    const pageNumber = Number(
      new URL(route.request().url()).searchParams.get("page") || 1,
    );
    requested.push(pageNumber);
    await fulfillBrowse(route, {
      page: pageNumber,
      found: 49,
      ids: pageNumber === 3 ? ["page-1", "page-3"] : ["page-1"],
    });
  });
  await page.goto("/");
  await page.getByRole("searchbox").fill("boundary");
  await page.getByRole("searchbox").press("Enter");
  await expect(page.locator("[data-recipe-id]")).toHaveCount(1);
  await triggerSentinel(page);
  await expect(page.locator("#browse-metadata")).toHaveAttribute(
    "data-page",
    "2",
  );
  await triggerSentinel(page);
  await expect(page.locator("[data-recipe-id]")).toHaveCount(2);
  expect(requested).toEqual([1, 2, 3]);
});

for (const kind of ["error", "fallback"]) {
  test(`later-page ${kind} never appends unrelated cards`, async ({ page }) => {
    await manualSentinel(page);
    const requested = [];
    await page.route(/\/\?[^#]*\bq=/, async (route) => {
      const pageNumber = Number(
        new URL(route.request().url()).searchParams.get("page") || 1,
      );
      requested.push(pageNumber);
      if (pageNumber === 2 && kind === "error") {
        await route.fulfill({
          contentType: "text/html",
          headers: {
            "HX-Retarget": "#browse-pagination",
            "HX-Reswap": "outerHTML",
          },
          body: '<nav id="browse-pagination"><p role="status">Weitere Rezepte konnten nicht geladen werden.</p><a data-load-more href="/?page=2&q=boundary">Erneut versuchen</a></nav>',
        });
        return;
      }
      await fulfillBrowse(route, {
        page: pageNumber,
        found: 48,
        ids:
          pageNumber === 1
            ? ["filtered"]
            : kind === "fallback"
              ? ["unfiltered"]
              : [],
        kind: pageNumber === 1 ? "search" : kind,
      });
    });
    await page.goto("/");
    await page.getByRole("searchbox").fill("boundary");
    await page.getByRole("searchbox").press("Enter");
    await expect(page.locator("[data-recipe-id=filtered]")).toBeVisible();
    await triggerSentinel(page);
    await expect(
      page.getByText(
        kind === "error"
          ? "Weitere Rezepte konnten nicht geladen werden."
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
      await expect(page).toHaveTitle("Alle Rezepte | RezeptDB");
    } else {
      await expect(page).toHaveTitle("48 Rezepte für 'boundary' | RezeptDB");
    }
    await triggerSentinel(page);
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
  await page.route(/\/\?[^#]*\bq=/, async (route) => {
    const query = new URL(route.request().url()).searchParams.get("q");
    if (query === "old") {
      oldStarted();
      await pending;
    }
    await fulfillBrowse(route, { query, ids: [query] }).catch(() => {});
    if (query === "old") oldFinished();
  });
  await page.goto("/");
  const search = page.getByRole("searchbox");
  await search.fill("old");
  await search.press("Enter");
  await started;
  await search.fill("new");
  release();
  await finished;
  await expect(page.locator("[data-recipe-id=old]")).toHaveCount(0);
  await expect(page.locator("[data-recipe-id=new]")).toBeVisible();
  await expect(page.locator("[data-recipe-id]")).toHaveCount(1);
  await expect(page.locator("[data-recipe-id=old]")).toHaveCount(0);
  await expect(search).toBeFocused();
});

for (const cacheSize of [10, 0]) {
  test(`Back reconstructs loaded depth and controls with history cache size ${cacheSize}`, async ({
    page,
    demoRecipe,
  }) => {
    await manualSentinel(page);
    await page.route(/\/\?[^#]*\bq=/, async (route) => {
      const number = Number(
        new URL(route.request().url()).searchParams.get("page") || 1,
      );
      const ids = Array.from(
        { length: number * 24 },
        (_, index) => `history-${index}`,
      );
      ids[0] = demoRecipe.id;
      await fulfillBrowse(route, { page: number, found: 72, ids });
    });
    await page.goto("/");
    const search = page.getByRole("searchbox");
    await search.fill("boundary");
    await search.press("Enter");
    await expect(page.locator("[data-recipe-id]")).toHaveCount(24);
    await triggerSentinel(page);
    await expect(page.locator("[data-recipe-id]")).toHaveCount(48);
    await triggerSentinel(page);
    await expect(page.locator("[data-recipe-id]")).toHaveCount(72);
    await page.evaluate((size) => {
      window.htmx.config.historyCacheSize = size;
      window.scrollTo(0, 700);
    }, cacheSize);
    await page
      .locator(`[data-recipe-id="${demoRecipe.id}"]`)
      .evaluate((link) => link.click());
    await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
    await page.goBack();
    await expect(search).toHaveValue("boundary");
    await expect(page.locator("[data-recipe-id]")).toHaveCount(72);
    await expect(page.locator("#browse-metadata")).toHaveAttribute(
      "data-page",
      "3",
    );
    // Cache-miss navigation restores the complete listing from the server;
    // scroll positioning is left to HTMX/browser navigation, not a controller.
    await expect(search).toBeVisible();
    await expect(page.locator("[data-add-recipe]")).toHaveCount(1);
    await page.reload();
    await expect(page.locator("#browse-metadata")).toHaveAttribute(
      "data-page",
      "3",
    );
  });
}

for (const action of ["sort", "query"]) {
  test(`a ${action} change cancels an older append generation`, async ({
    page,
  }) => {
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
    await page.route(/\/\?[^#]*\bq=/, async (route) => {
      const url = new URL(route.request().url());
      const number = Number(url.searchParams.get("page") || 1);
      if (number === 2) {
        appendStarted();
        await pending;
      }
      const id =
        url.searchParams.get("sort") === "updated" ||
        url.searchParams.get("q") === "new"
          ? "new-state"
          : `old-${number}`;
      await fulfillBrowse(route, { page: number, found: 48, ids: [id] }).catch(
        () => {},
      );
      if (number === 2) appendFinished();
    });
    await page.goto("/");
    await page.getByRole("searchbox").fill("boundary");
    await page.getByRole("searchbox").press("Enter");
    await expect(page.locator("[data-recipe-id=old-1]")).toBeVisible();
    await triggerSentinel(page);
    await started;
    if (action === "sort")
      await page
        .getByLabel("Sortieren nach", { exact: true })
        .selectOption("updated");
    else await page.getByRole("searchbox").fill("new");
    release();
    await finished;
    await expect(page.locator("[data-recipe-id=old-2]")).toHaveCount(0);
    await expect(page.locator("[data-recipe-id=new-state]")).toBeVisible();
    await expect(page.locator("[data-recipe-id]")).toHaveCount(1);
    await expect(page.locator("#browse-metadata")).toHaveAttribute(
      "data-page",
      "1",
    );
  });
}

test("returning to the same query cannot revive its older response", async ({
  page,
}) => {
  await manualSentinel(page);
  let release;
  let oldStarted;
  let oldFinished;
  let oldRequests = 0;
  const pending = new Promise((resolve) => {
    release = resolve;
  });
  const started = new Promise((resolve) => {
    oldStarted = resolve;
  });
  const finished = new Promise((resolve) => {
    oldFinished = resolve;
  });
  await page.route(/\/\?[^#]*\bq=/, async (route) => {
    const query = new URL(route.request().url()).searchParams.get("q");
    const stale = query === "old" && ++oldRequests === 1;
    if (stale) {
      oldStarted();
      await pending;
    }
    await fulfillBrowse(route, {
      query,
      found: stale ? 99 : 1,
      ids: [stale ? "stale" : query],
    }).catch(() => {});
    if (stale) oldFinished();
  });
  await page.goto("/");
  const input = page.getByRole("searchbox");
  await input.fill("old");
  await input.press("Enter");
  await started;
  await input.fill("new");
  await expect(page.locator("[data-recipe-id=new]")).toBeVisible();
  await input.fill("old");
  await input.press("Enter");
  await expect(page.locator("[data-recipe-id=old]")).toBeVisible();
  release();
  await finished;
  await expect(page.locator("[data-recipe-id=stale]")).toHaveCount(0);
  await expect(page.locator("[data-recipe-id]")).toHaveCount(1);
  await expect(page).toHaveTitle("1 Rezept für 'old' | RezeptDB");
});

test("typing debounces by 300ms while Enter and sorting submit immediately", async ({
  page,
}) => {
  await manualSentinel(page);
  await page.clock.install({ time: new Date("2026-01-01T00:00:00Z") });
  const queries = [];
  await page.route(/\/\?[^#]*\bq=/, async (route) => {
    const url = new URL(route.request().url());
    queries.push([
      url.searchParams.get("q"),
      url.searchParams.get("sort") || null,
    ]);
    await fulfillBrowse(route, { query: url.searchParams.get("q") }).catch(
      () => {},
    );
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
  await expect(page.locator("#browse-metadata")).toHaveAttribute(
    "data-sort",
    "updated",
  );
  await input.blur();
  await page.clock.runFor(400);
  expect(queries).toHaveLength(3);
});

test("rendered online failure removes previous-query cards without fallback", async ({
  page,
}) => {
  await manualSentinel(page);
  await page.route(/\/\?[^#]*\bq=/, async (route) => {
    const query = new URL(route.request().url()).searchParams.get("q");
    await fulfillBrowse(route, {
      query,
      kind: query === "failure" ? "error" : "search",
      ids: query === "failure" ? [] : ["previous-query"],
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

for (const failure of ["network", "502"]) {
  const fail = (route) =>
    failure === "network"
      ? route.abort("failed")
      : route.fulfill({
          status: 502,
          contentType: "text/plain",
          body: "Bad Gateway",
        });

  test(`first-page ${failure} failure clears stale cards and reports failure`, async ({
    page,
  }) => {
    await manualSentinel(page);
    await page.route(/\/\?[^#]*\bq=/, async (route) => {
      if (new URL(route.request().url()).searchParams.get("q") === "failure")
        await fail(route);
      else await fulfillBrowse(route, { ids: ["previous-query"] });
    });
    await page.goto("/");
    const input = page.getByRole("searchbox");
    await input.fill("boundary");
    await input.press("Enter");
    await expect(page.locator("[data-recipe-id]")).toHaveCount(1);
    await input.fill("failure");
    await input.press("Enter");
    await expect(page.getByRole("status")).toHaveText(
      "Rezepte konnten nicht geladen werden.",
    );
    await expect(page.locator("[data-recipe-id]")).toHaveCount(0);
    await expect(page.locator("[data-add-recipe]")).toHaveCount(1);
    await expect(page.locator("#browse-metadata")).toHaveAttribute(
      "data-kind",
      "error",
    );
    await expect(page).toHaveTitle(
      "Rezepte konnten nicht geladen werden | RezeptDB",
    );
    await expect(input).toBeFocused();
  });

  test(`append ${failure} failure retains cards/title, stops auto-loading and permits retry`, async ({
    page,
  }) => {
    await manualSentinel(page);
    const requested = [];
    let failed = false;
    await page.route(/\/\?[^#]*\bq=/, async (route) => {
      const number = Number(
        new URL(route.request().url()).searchParams.get("page") || 1,
      );
      requested.push(number);
      if (number === 2 && !failed) {
        failed = true;
        await fail(route);
      } else
        await fulfillBrowse(route, {
          page: number,
          found: 48,
          ids: number === 1 ? ["filtered"] : ["filtered", "next"],
        });
    });
    await page.goto("/");
    await page.getByRole("searchbox").fill("boundary");
    await page.getByRole("searchbox").press("Enter");
    await expect(page.locator("[data-recipe-id=filtered]")).toBeVisible();
    await triggerSentinel(page);
    await expect(page.getByRole("status")).toHaveText(
      "Weitere Rezepte konnten nicht geladen werden.",
    );
    await expect(page.locator("[data-recipe-id=filtered]")).toHaveCount(1);
    await expect(page).toHaveTitle("48 Rezepte für 'boundary' | RezeptDB");
    await expect(page.locator("[data-add-recipe]")).toHaveCount(1);
    await triggerSentinel(page);
    expect(requested).toEqual([1, 2]);
    await page.getByRole("link", { name: "Erneut versuchen" }).click();
    await expect(page.locator("#browse-metadata")).toHaveAttribute(
      "data-page",
      "2",
    );
    await expect(page.locator("[data-recipe-id]")).toHaveCount(2);
    expect(requested).toEqual([1, 2, 2]);
  });
}

test.describe("pagination with and without JavaScript", () => {
  test("HTMX inserts the next server page without replacing earlier tiles", async ({
    page,
    searchRecipes,
  }) => {
    await manualSentinel(page);
    await page.goto(`/?q=${encodeURIComponent("E2E Suchrezept")}&sort=newest`);
    await expect(page.locator("[data-recipe-id]")).toHaveCount(24);
    const pagination = page.getByRole("navigation", {
      name: "Weitere Rezepte",
    });
    await expect(pagination).toHaveCSS("grid-column", "1 / -1");
    await expect(pagination).toHaveCSS("order", "1");
    const first = page.locator("[data-recipe-id]").first();
    const firstID = await first.getAttribute("data-recipe-id");
    await first.evaluate((card) => {
      card.dataset.originalNode = "true";
    });
    await triggerSentinel(page);
    await expect(page.locator("#browse-metadata")).toHaveAttribute(
      "data-page",
      "2",
    );
    await expect(page.locator("[data-recipe-id]")).toHaveCount(25);
    await expect(page.getByRole("status")).toHaveText(
      "25 Rezepte gefunden. Alle Rezepte geladen.",
    );
    await expect(page.locator(`[data-recipe-id="${firstID}"]`)).toHaveAttribute(
      "data-original-node",
      "true",
    );
    await expect(page.locator("[data-add-recipe]")).toHaveCount(1);
    await expect(page.getByRole("link", { name: "Mehr laden" })).toHaveCount(0);
    await expect(page).toHaveURL(/page=2.*sort=newest/);
    expect(new URL(page.url()).searchParams.has("seen")).toBe(false);
    await page.reload();
    await expect(page.locator("[data-recipe-id]")).toHaveCount(25);
    await expect(page.locator("#browse-metadata")).toHaveAttribute(
      "data-page",
      "2",
    );
  });

  test("ordinary links preserve the query and advance to the next page", async ({
    browser,
    baseURL,
    searchRecipes,
  }) => {
    const context = await browser.newContext({
      javaScriptEnabled: false,
      baseURL,
    });
    try {
      const page = await context.newPage();
      await page.goto(
        `/?q=${encodeURIComponent("E2E Suchrezept")}&sort=newest`,
      );
      await expect(page.locator("[data-recipe-id]")).toHaveCount(24);
      await expect(page.locator("[data-add-recipe]")).toHaveCount(1);
      await page.getByRole("link", { name: "Mehr laden" }).click();
      await expect(page).toHaveURL(/page=2.*sort=newest/);
      await expect(page.locator("[data-recipe-id]")).toHaveCount(25);
      await expect(page.locator("[data-recipe-id]").last()).toHaveAttribute(
        "data-recipe-id",
        searchRecipes[0].id,
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

test("a failed history cache miss renders a truthful error page", async ({
  page,
  demoRecipe,
  request,
}) => {
  await waitForRecipeIndexed(request, demoRecipe.id);
  await allowDesignAssets(page);
  await manualSentinel(page);
  let restoring = false;
  await page.route(/\/\?[^#]*\bq=/, async (route) => {
    await fulfillBrowse(route, {
      kind: restoring ? "error" : "search",
      found: restoring ? 0 : 2,
      ids: restoring ? [] : [demoRecipe.id, "stale-snapshot"],
    });
  });
  await page.goto("/?q=boundary");
  await expect(page.locator("[data-recipe-id]")).toHaveCount(2);
  await page.evaluate(() => {
    window.htmx.config.historyCacheSize = 0;
  });
  await page.route(`**/recipe/${demoRecipe.id}`, (route) =>
    route.fulfill({
      status: 200,
      contentType: "text/html; charset=utf-8",
      body: '<!doctype html><html lang="de"><head><title>Rezept | RezeptDB</title></head><body><header-component></header-component><main><h1>Rezept</h1></main></body></html>',
    }),
  );
  await page.locator(`[data-recipe-id="${demoRecipe.id}"]`).click();
  await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
  restoring = true;
  await page.goBack();
  await expect(
    page.getByText("Rezepte konnten nicht geladen werden.", { exact: true }),
  ).toBeVisible();
  await expect(page.locator("[data-recipe-id]")).toHaveCount(0);
  await expect(page.locator("#browse-metadata")).toHaveAttribute(
    "data-kind",
    "error",
  );
  await expect(page.locator("[data-add-recipe]")).toHaveCount(1);
  await expect(page).toHaveTitle(
    "Rezepte konnten nicht geladen werden | RezeptDB",
  );
});
