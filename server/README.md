# NewsDigest server

Every morning a GitHub Actions job does the following:
1. Signs in to both e-papers with their own email + password forms.
2. Downloads today's page images.
3. Asks Gemini for a BCS-focused summary of each page.
4. Saves the summaries to Supabase.

The NewsDigest iOS app reads them from there. Everything runs on free tiers. Page images are never stored; only the summaries are.

## One-time setup (~15 minutes)

### 1. Supabase
1. Create a project at supabase.com (free).
2. Go to **SQL Editor**, paste `../supabase/schema.sql`, and click **Run**.
3. Go to **Authentication → Users → Add user**. Enter your email and a password. This is what you'll use to sign in to the app.
4. Go to **Authentication → Sign In / Providers** and turn **off** "Allow new users to sign up".
5. From **Project Settings → API**, copy three values:
   - Project URL
   - `anon` key (for the app)
   - `service_role` key (for the server only; never put it in the app)

### 2. Gemini
Create a free API key at aistudio.google.com.

### 3. GitHub secrets
Push this repo to GitHub (a private repo is fine), then run from the repo root:
```bash
gh secret set GEMINI_API_KEYS   # one key, or several comma-separated
gh secret set GROQ_API_KEYS     # optional; spots duplicate stories (and page fallback if GROQ_FALLBACK=true)
gh secret set SUPABASE_URL
gh secret set SUPABASE_SERVICE_ROLE_KEY
gh secret set DAILYSTAR_EMAIL
gh secret set DAILYSTAR_PASSWORD
gh secret set PROTHOMALO_EMAIL
gh secret set PROTHOMALO_PASSWORD
```
Each command prompts you for the value, so nothing ends up in your shell history.

Optional repository **variables** (not secrets):
- `GEMINI_MODEL` (default `gemini-3.8-flash`)
- `GEMINI_FALLBACK_MODELS` (default `gemini-3.7-flash,gemini-3.5-flash-lite`), tried when the main model is overloaded
- `GROQ_FALLBACK` (default off). Groq's image model misreads small Bangla print and invents headlines
- `DIGEST_LANG`: `en`, `bn` or `both`

### 4. First run
Go to GitHub → **Actions → Daily digest → Run workflow**. After that it runs automatically at 06:00, 08:00 and 10:00 Dhaka time. The later runs only retry papers that aren't done yet.

## Local testing
```bash
cp .env.example .env                                   # fill in values
npm run digest -- --dry --paper prothomalo --max-pages 2   # writes out/*.json, no Supabase
npm run digest                                         # full run, saves to Supabase
npm run digest -- --force                              # redo today even if it exists
```

## When something breaks
The app shows a banner, driven by the `run_status` table.

| Banner | Fix |
|---|---|
| Prothom Alo login expired | Check `PROTHOMALO_EMAIL` / `PROTHOMALO_PASSWORD` |
| Daily Star login expired | Check `DAILYSTAR_EMAIL` / `DAILYSTAR_PASSWORD` |
| Verification check (CAPTCHA) | The job never tries to get around these. Use ✨ Summarize in the app's Papers tab that day. |
| Reader layout not recognized | The site changed its HTML. Update the selector in `src/papers/*.ts` |
