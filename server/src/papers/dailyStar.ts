import type { Browser, BrowserContext, Page } from "playwright";
import { LoginError, NotPublishedError, type PageImage } from "../types.js";
import { assertNoChallenge, dhakaDate, downloadPages, readPageImageTags } from "./common.js";

const LOGIN_URL = "https://profile.thedailystar.net/login?redirect_to=https://epaper.thedailystar.net/Login/LandingPage";
// Same reader markup as Prothom Alo (ASP.NET e-paper platform). Fallback: any large page image.
const PAGE_IMG = "img.img_jpg";

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
    links: [...document.querySelectorAll("a[href]")]
      .map((a) => `${(a.textContent ?? "").trim().slice(0, 40)} -> ${a.getAttribute("href")}`)
      .filter((l) => !/facebook|twitter|youtube|instagram|linkedin|mailto:|tel:/i.test(l))
      .slice(0, 40),
    images: [...document.images]
      .filter((i) => i.naturalWidth > 200)
      .slice(0, 10)
      .map((i) => ({ src: i.src.slice(0, 160), w: i.naturalWidth, h: i.naturalHeight, cls: i.className, attrs: [...i.attributes].map((a) => a.name).join(",") })),
    iframes: [...document.querySelectorAll("iframe")].map((f) => f.src.slice(0, 160)).slice(0, 5),
    canvases: [...document.querySelectorAll("canvas")].map((c) => `${c.width}x${c.height} #${c.id} .${c.className}`).slice(0, 5),
  }));
  console.log("  --- Daily Star layout (for fixing the scraper) ---");
  console.log(JSON.stringify(info, null, 1));
}

export async function captureDailyStar(browser: Browser): Promise<PageImage[]> {
  const context = await browser.newContext({ viewport: { width: 1280, height: 1600 } });
  try {
    const page = await signIn(context);
    const { y, m, d } = dhakaDate();

    // After login we land on the e-paper's landing page; let it settle.
    await page.waitForLoadState("networkidle", { timeout: 30_000 }).catch(() => undefined);
    await assertNoChallenge(page);
    const found = await page.waitForSelector(PAGE_IMG, { timeout: 30_000 }).catch(() => null);
    if (!found) {
      await logLayout(page);
      throw new Error(`Daily Star reader layout not recognized at ${page.url()}. The selector in dailyStar.ts needs updating.`);
    }

    const tags = await readPageImageTags(page, PAGE_IMG);
    if (!tags.some((t) => t.urls.some((u) => u.includes(`/${y}/${m}/${d}/`)))) {
      throw new NotPublishedError(`Daily Star edition for ${y}-${m}-${d} is not up yet`);
    }
    const { pages } = await downloadPages(context, tags, page.url());
    if (pages.length === 0) throw new LoginError("Daily Star page images could not be downloaded (subscription/login?)");
    return pages;
  } finally {
    await context.close();
  }
}
