<p align="center">
  <img src="NewsDigest/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="120" alt="NewsDigest icon">
</p>

# NewsDigest

**Daily BCS-focused summaries of The Daily Star and Prothom Alo e-papers.**

Reading two full newspapers every day takes hours. NewsDigest reads them for you each morning and keeps only what matters for the Bangladesh Civil Service (BCS) exam. That means Bangladesh affairs, international affairs, the economy, science and tech, and the environment, with key facts and practice MCQs. Everything runs on free tiers.

> **You need your own e-paper subscriptions.** NewsDigest signs in with your account and only reads papers you already pay for. It stores summaries, never the page images.

## How it works

```
GitHub Actions (06:00, 08:00, 10:00 Dhaka time)
  └─ Playwright signs in to each e-paper with your credentials
  └─ downloads today's page images
  └─ Gemini reads each page → BCS-relevant stories, key facts, MCQs
  └─ Groq groups duplicate stories, which are then merged
  └─ saves the digest to Supabase
                     │
                     ▼
        NewsDigest iOS app (SwiftUI)
  Today · Archive · Papers · Settings
```

- **One page at a time.** Each page image goes to Gemini with a BCS-focused prompt. The answer comes back as structured JSON: category, headline, bullets, key facts, relevance (high or medium), and page number.
- **Model fallback.** If the main Gemini model is overloaded or out of quota, the job tries the next one: `gemini-3.8-flash` → `3.7-flash` → `3.5-flash-lite`.
- **Duplicate merging.** A text-only Groq call lists which stories are the same news. The code then merges them, so the model never writes facts itself.
- **Retries.** Later runs only redo papers that aren't done yet. Failures (expired login, CAPTCHA, edition not out yet) are shown as banners in the app.

## The app

| Tab | What it does |
|---|---|
| **Today** | Today's digest. Step to earlier days with ◀ ▶, swipe, or a calendar. Filter by paper, category or high relevance. Tap a story to open that page of the e-paper. Practice MCQs at the bottom. |
| **Archive** | Every past day, grouped by month. Search across all digests. Bookmarked stories for revision. Days you've opened work offline. |
| **Papers** | Both e-papers in an in-app browser that remembers your login. **✨ Summarize** gives an instant digest of the page you're viewing, with follow-up chat. You can also send the page to the ChatGPT or Gemini app. |
| **Settings** | Supabase sign-in, your Gemini key for on-device summaries, and summary language (English / বাংলা / both). |

## Repository layout

```
NewsDigest/                 iOS app (SwiftUI, iOS 17+)
├── Models/                 Paper, digest models
├── Services/               Supabase store, Gemini client, page capture, Keychain
└── Views/                  Today, Archive, Papers/Reader, Summary, Settings
server/                     Daily digest job (Node + TypeScript + Playwright)
├── src/papers/             Daily Star and Prothom Alo scrapers
├── src/gemini.ts           Page summaries with model fallback
├── src/groq.ts             Duplicate grouping (and optional page fallback)
├── src/merge.ts            Merge pages → one digest per paper
└── src/run.ts              Entry point
supabase/schema.sql         Tables + row-level security
.github/workflows/          Scheduled daily job
project.yml                 XcodeGen project definition
```

## Setup

Everything below is free. It takes about 15 minutes.

### 1. Server and daily job

Follow **[server/README.md](server/README.md)**. It covers creating the Supabase project, getting a Gemini API key, adding GitHub secrets, and the first run. In short:

```bash
cd server
npm install
cp .env.example .env                       # fill in your keys and e-paper logins
npm run digest -- --dry --max-pages 2      # local test, writes out/*.json
```

Then add the same values as repository secrets and trigger **Actions → Daily digest → Run workflow**.

### 2. iOS app

```bash
brew install xcodegen
xcodegen generate
open NewsDigest.xcodeproj
```

Run on a simulator or device. Then, in the app's **Settings**:
1. Enter your Supabase **project URL** and **anon/publishable key**. Never use the service key in the app.
2. Sign in with the user you created in Supabase.
3. Optional: add a Gemini API key to use ✨ Summarize in the Papers tab.

## Configuration

| Variable | Where | Purpose |
|---|---|---|
| `GEMINI_API_KEYS` | secret | One or more comma-separated keys, rotated automatically |
| `GROQ_API_KEYS` | secret | Optional. Used to spot duplicate stories |
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | secret | Where digests are saved |
| `DAILYSTAR_EMAIL`, `DAILYSTAR_PASSWORD` | secret | Daily Star e-paper login |
| `PROTHOMALO_EMAIL`, `PROTHOMALO_PASSWORD` | secret | Prothom Alo e-paper login |
| `GEMINI_MODEL`, `GEMINI_FALLBACK_MODELS` | variable | Override the model chain |
| `DIGEST_LANG` | variable | `en`, `bn` or `both` |

## Limitations

- **Summaries can contain mistakes,** especially when only the lighter fallback model is available. Check key facts against the page (tap **Page N**) before memorizing them.
- **Scrapers depend on each site's layout.** If a paper redesigns its reader, the job reports "layout not recognized" and logs the new structure for fixing.
- **CAPTCHAs are never bypassed.** If a site shows one, that day's run stops and the app suggests ✨ Summarize instead.
- **Groq isn't used to read pages by default.** Its image model misreads small Bangla print and was seen inventing headlines. Enable it with `GROQ_FALLBACK=true` only if you accept that risk.

## Disclaimer

For personal study only. NewsDigest is not affiliated with The Daily Star or Prothom Alo. Respect their terms of service, and don't redistribute their content or the generated digests.
