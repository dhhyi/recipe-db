import { DOMParser } from "https://deno.land/x/deno_dom@v0.1.38/deno-dom-wasm.ts";
import {
  pathParse,
  Req,
  Res,
  Router,
  WebApp,
} from "https://deno.land/x/denorest@v4.2/mod.ts";
import { Database } from "https://deno.land/x/aloedb@0.9.0/mod.ts";
import { dirname } from "https://deno.land/std@0.196.0/path/mod.ts";

interface PageMetaData {
  url: string;
  favicon: string | null;
  title: string | null;
  description: string | null;
  canonical: string | null;
}

function initDatabase() {
  const location = Deno.env.get("DATA_LOCATION");
  let dbFile: string;
  if (location) {
    if (location.endsWith(".json")) {
      dbFile = location;
    } else {
      dbFile = `${location}/db.json`;
    }
    const folder = dirname(dbFile);

    Deno.mkdirSync(folder, { recursive: true });
  } else {
    dbFile = "./db.json";
  }
  console.log("Database location:", dbFile);

  return new Database<PageMetaData>(dbFile);
}

async function getPageMetaData(url: URL): Promise<PageMetaData> {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`HTTP error! status: ${response.status}`);
  } else if (
    !response.headers.has("content-type") ||
    !response.headers.get("content-type")!.includes("text/html")
  ) {
    throw new Error("Response is not HTML");
  } else if (response.status >= 400) {
    throw new Error(`HTTP error! status: ${response.status}`);
  } else {
    const html = await response.text();
    const doc = new DOMParser().parseFromString(html, "text/html");
    if (!doc) {
      throw new Error("Failed to parse document");
    }
    let favicon = doc.querySelector("link[rel='icon']")?.getAttribute("href");
    if (favicon && !favicon.startsWith("http")) {
      favicon = new URL(favicon, url).href;
    } else {
      const defaultFavicon = new URL("/favicon.ico", url.origin).href;
      const defaultFaviconResponse = await fetch(defaultFavicon);
      if (defaultFaviconResponse.ok) {
        favicon = defaultFavicon;
      } else {
        favicon = null;
      }
    }
    const title = doc.querySelector("title")?.textContent || null;
    const description = doc
      .querySelector("meta[name='description']")
      ?.getAttribute("content") || null;
    const canonical = doc.querySelector("link[rel='canonical']")?.getAttribute(
      "href",
    ) || null;
    return { favicon, title, description, canonical, url: url.href };
  }
}

if (import.meta.main) {
  const app = new WebApp();
  const router = new Router();
  const db = initDatabase();

  router.get("/link-extract", async (req: Req, res: Res) => {
    const parsed = pathParse(req);
    const urlQuery = parsed.query?.url;

    if (!urlQuery) {
      res.reply = "Please provide a url query parameter";
      res.status = 400;
      return;
    }

    try {
      const decodedUrl = decodeURIComponent(urlQuery);
      console.log("URL\t", decodedUrl);
      const url = new URL(decodedUrl);
      let meta = await db.findOne({ url: url.href });
      if (meta) {
        console.log("CACHED\t", meta.canonical);
      } else {
        meta = await getPageMetaData(url);
        await db.insertOne(meta);
        if (meta.canonical && meta.canonical !== meta.url) {
          await db.insertOne({ ...meta, url: meta.canonical });
        }
        console.log("FETCHED\t", meta.canonical);
      }

      res.headers["Content-Type"] = "application/json";
      res.reply = JSON.stringify(meta);
    } catch (error) {
      console.log("ERROR\t", error.message);
      if (error.message.startsWith("Invalid URL")) {
        res.reply = "Please provide a valid url query parameter";
        res.status = 400;
        return;
      } else {
        res.reply = error.message;
        res.status = 500;
      }
    }
  });

  app.set(router);
  app.listen(8081);
}
