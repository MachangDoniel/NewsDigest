import type { Browser, BrowserContext, Page } from "playwright";
import { LoginError, NotPublishedError, type PageImage } from "../types.js";
import { assertNoChallenge, dhakaDate, downloadPages, type TagList } from "./common.js";

const LOGIN_URL = "https://profile.thedailystar.net/login?redirect_to=https://epaper.thedailystar.net/Login/LandingPage";
/**
 * After login the reader opens at /DhakaEdition?... with a thumbnail strip of every page:
 *   <img id="page440418" pageid="440418" src=".../TDS/2026/09/26/Bangladesh/MAI/5_01/3c077f31_01_tn.jpg">
 * The readable page image is the same path with _mr.jpg instead of _tn.jpg.
 */
const THUMB = 'img[id^="page"][pageid]';

async function signIn(context: BrowserContext): Promise<Page> {
  const email = process.env.DAILYSTAR_EMAIL;
  const password = process.env.DAILYSTAR_PASSWORD;
  if (!email || !password) throw new LoginError("DAILYSTAR_EMAIL / DAILYSTAR_PASSWORD are not set");

  const page = await context.newPage();
  await page.goto(LOGIN_URL, { waitUntil: "domcontentloaded" });
  await assertNoChallenge(page);
  await page.fill('input[placeholder="Email"]', email);
  await page.fill('input[type="password"]', password);
  await Promise.all([
    page.waitForURL((u) => !u.hostname.startsWith("profile."), { timeout: 45_000 }).catch(() => undefined),
    page.getByRole("button", { name: /sign in/i }).first().click(),
  ]);
  await assertNoChallenge(page);
  if (new URL(page.url()).hostname.startsWith("profile.")) {
    throw new LoginError("Daily Star login failed. Check DAILYSTAR_EMAIL / DAILYSTAR_PASSWORD");
  }
  return page;
}

/** Prints the page structure to the job log so the scraper can be fixed when the site changes. */
async function logLayout(page: Page) {
  const info = await page.evaluate(() => ({
    url: location.href,
    title: document.title,
    pageidEls: [...document.querySelectorAll("[pageid],[pgid],[page_id]")]
      .slice(0, 12)
      .map((e) => `${e.tagName} ${[...e.attributes].map((a) => `${a.name}=${a.value.slice(0, 90)}`).join(" ")}`),
    images: [...document.images]
      .filter((i) => i.naturalWidth > 200)
      .slice(0, 8)
      .map((i) => `${i.naturalWidth}x${i.naturalHeight} ${i.src.slice(0, 160)}`),
  }));
  console.log("  --- Daily Star layout (for fixing the scraper) ---");
  console.log(JSON.stringify(info, null, 1));
}

export async function captureDailyStar(browser: Browser): Promise<PageImage[]> {
  const context = await browser.newContext({ viewport: { width: 1280, height: 1600 } });
  try {
    const page = await signIn(context);
    const { y, m, d } = dhakaDate();

    await page.waitForLoadState("networkidle", { timeout: 30_000 }).catch(() => undefined);
    await assertNoChallenge(page);
    if (!(await page.waitForSelector(THUMB, { timeout: 30_000 }).catch(() => null))) {
      await logLayout(page);
      throw new Error(`Daily Star reader layout not recognized at ${page.url()}. The selector in dailyStar.ts needs updating.`);
    }

    const tags: TagList = await page.$$eval(THUMB, (imgs) =>
      imgs.map((img, i) => {
        const src = img.getAttribute("src") ?? "";
        const pageid = img.getAttribute("pageid") ?? String(i);
        const pageNo = Number(src.match(/_(\d+)_tn\.jpg/)?.[1] ?? i + 1);
        const option = document.querySelector(`#ddl_Pages option[value="${pageid}"]`);
        return {
          urls: [src.replace(/_tn\.jpg/, "_mr.jpg")],
          pageNo,
          sequence: i + 1,
          name: option?.textContent?.replace(/^\s*\d+\s*[:.-]?\s*/, "").trim() || `Page ${pageNo}`,
          id: pageid,
        };
      }),
    );

    if (!tags.some((t) => t.urls.some((u) => u.includes(`/${y}/${m}/${d}/`)))) {
      throw new NotPublishedError(`Daily Star edition for ${y}-${m}-${d} is not up yet`);
    }
    const { pages, failed } = await downloadPages(context, tags, page.url());
    if (pages.length === 0 || failed.length > tags.length / 2) {
      throw new LoginError("Daily Star page images could not be downloaded (subscription/login?)");
    }
    return pages;
  } finally {
    await context.close();
  }
}
