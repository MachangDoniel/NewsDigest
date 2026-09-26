import type { BrowserContext } from "playwright";
import type { PageImage, Story } from "../types.js";

/**
 * Both e-papers run on the same reader platform, which serves each story's text:
 *   GET {base}/Home/getingRectangleObject?pageid=…  → story boxes on a page (ObjectType 2 = story, with OrgId)
 *   GET {base}/User/ShowArticleView?OrgId=…         → StoryContent[{Headlines, Body}], LinkPicture[{caption}]
 * Using the real text avoids misreading small print (e.g. Bangla digits) from page images.
 * Requests go through the signed-in browser context, i.e. your subscription.
 */

const stripHtml = (html: string) =>
  html
    .replace(/<\/(p|div|br)>|<br\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, " ")
    .replace(/\n\s*\n+/g, "\n")
    .trim();

async function getJson(context: BrowserContext, url: string, referer: string): Promise<any> {
  const res = await context.request.get(url, { headers: { Referer: referer, "X-Requested-With": "XMLHttpRequest" }, failOnStatusCode: false });
  if (!res.ok()) return null;
  try {
    return JSON.parse(await res.text());
  } catch {
    return null;
  }
}

/** Runs `fn` over `items` with limited parallelism, to stay polite to the site. */
async function mapLimit<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        const i = next++;
        out[i] = await fn(items[i]);
      }
    }),
  );
  return out;
}

async function storiesForPage(context: BrowserContext, base: string, pageId: string, referer: string): Promise<(Story & { linkedStoryId: string })[]> {
  const rects = await getJson(context, `${base}/Home/getingRectangleObject?pageid=${pageId}`, referer);
  if (!Array.isArray(rects)) return [];
  const orgIds = [...new Set(rects.filter((r) => r.ObjectType === 2 && r.OrgId).map((r) => String(r.OrgId)))];
  const stories = await mapLimit(orgIds, 4, async (orgId) => {
    const a = await getJson(context, `${base}/User/ShowArticleView?OrgId=${orgId}`, referer);
    const content = Array.isArray(a?.StoryContent) ? a.StoryContent : [];
    const headline = stripHtml(content.flatMap((c: any) => c.Headlines ?? []).join(" ")).trim();
    const body = stripHtml(content.map((c: any) => c.Body ?? "").join("\n"));
    const captions = (a?.LinkPicture ?? []).map((p: any) => String(p.caption ?? "").trim()).filter(Boolean);
    if (!headline && body.length < 80) return null;
    return { storyId: String(a?.storyid ?? orgId), linkedStoryId: String(a?.LinkedStoryId ?? 0), headline, body, captions };
  });
  return stories.filter((s): s is Story & { linkedStoryId: string } => !!s);
}

/**
 * Attaches article text to each page. A story continued on another page ("continued on page 6")
 * is joined onto its first part, so it's only summarized once.
 */
export async function attachStories(context: BrowserContext, base: string, pages: PageImage[], referer: string) {
  const perPage = await mapLimit(pages, 2, (p) => storiesForPage(context, base, p.pageId, referer));
  const byId = new Map(perPage.flat().map((s) => [s.storyId, s]));
  const continuation = new Set<string>();
  for (const s of byId.values()) {
    const cont = byId.get(s.linkedStoryId);
    if (cont && cont !== s && !continuation.has(s.storyId)) {
      s.body += "\n" + cont.body;
      continuation.add(cont.storyId);
    }
  }
  pages.forEach((p, i) => {
    p.stories = perPage[i]
      .filter((s) => !continuation.has(s.storyId))
      .map(({ linkedStoryId: _, ...s }) => s);
  });
  const total = pages.reduce((n, p) => n + (p.stories?.length ?? 0), 0);
  console.log(`  article text: ${total} stories on ${pages.filter((p) => p.stories?.length).length}/${pages.length} pages`);
}
