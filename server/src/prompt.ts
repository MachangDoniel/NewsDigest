import { CATEGORIES } from "./types.js";

export type DigestLang = "en" | "bn" | "both";

const LANG_RULE: Record<DigestLang, string> = {
  en: "Write everything in clear, simple English, even when the page is in Bangla.",
  bn: "Write everything (headlines, bullets, key facts, MCQs) in Bangla (বাংলা), exactly as a Bangla newspaper would. Keep proper names in their usual Bangla spelling.",
  both: "Write the headline in English followed by the Bangla headline in brackets; write bullets and facts in English.",
};

export function pagePrompt(opts: { paper: string; pageName: string; pageNo: number; lang: DigestLang }): string {
  return `You are a study assistant for a candidate preparing for the Bangladesh Civil Service (BCS) exam.

Below is page ${opts.pageNo} ("${opts.pageName}") of today's ${opts.paper} e-paper, as an image.

Extract ONLY news that could matter for the BCS preliminary/written exam or the viva:
- Bangladesh affairs: government decisions, laws, ordinances, constitution, elections, appointments, projects (with cost/length/location), policies, reports and statistics.
- International affairs: treaties, summits, organizations (UN, ASEAN, SAARC, BIMSTEC, WTO...), conflicts, elections, heads of state/government.
- Economy: budget, GDP, inflation, remittance, reserves, exports, banking, trade deals.
- Science & tech, environment/climate, health, and notable sports records.
- Rankings and indices (and Bangladesh's position), "firsts", records, awards, days/themes, and deaths of notable people.

Skip: advertisements, gossip, entertainment, crime stories without policy significance, opinion pieces with no new facts, horoscopes, and classifieds.

For each relevant story:
- headline: short and factual.
- bullets: 2-3 bullets on what happened and why it matters.
- keyFacts: exact names, numbers, dates, places, and organizations, i.e. things an MCQ could ask about.
- bcsRelevance: "high" if very likely examinable, otherwise "medium".
- page: ${opts.pageNo}.
- Use one of these categories: ${CATEGORIES.join(", ")}.

Also write up to 3 MCQs with 4 options each, based on this page's facts. The answer must exactly equal one of the options.

If nothing on the page is relevant, return empty arrays. Do not invent facts that are not on the page.
${LANG_RULE[opts.lang]}`;
}
