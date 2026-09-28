# Commands

Copy each command, paste it into **Terminal** (or the Terminal tab in Claude), and press **Return**.
Run one command at a time and wait for it to finish before running the next.

- [Deploy](#deploy): send server changes live (Edge Function, database, secrets)
- [Run the digest](#run-the-digest): build today's digest yourself
- [App](#app): rebuild the Xcode project
- [Git](#git): save and share your changes

---

## Deploy

Do this whenever `supabase/functions/summarize/index.ts` changes (for example after a new feature
like "Run digest now" or the Gemini voice). Until you deploy, the app keeps using the old server code.

Your Supabase project ID is **`utjluiipjiznedsglqsm`** (it's in the Supabase dashboard URL too).

### One-time setup

You only do these once per Mac.

**1. Install Homebrew** (skip if `brew --version` already prints a version number):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

It asks for your Mac password (nothing shows while you type; that's normal). At the end it may print
two or three "Next steps" commands. Run those too, then close and reopen Terminal.

**2. Install the Supabase tool:**

```bash
brew install supabase/tap/supabase
```

Check it worked. This should print a version number like `2.x.x`:

```bash
supabase --version
```

**3. Log in to Supabase:**

```bash
supabase login
```

Your browser opens. Approve it, then come back to Terminal. It says `You are now logged in`.

### Deploy the Edge Function

Every time the function changes, run this one command:

```bash
cd ~/Projects/NewsDigest && supabase functions deploy summarize --project-ref utjluiipjiznedsglqsm --no-verify-jwt
```

When it works, the last line says:

```
Deployed Functions on project utjluiipjiznedsglqsm: summarize
```

Why `--no-verify-jwt`: the function checks that you're signed in by itself. This flag only turns off
Supabase's extra gate, which can wrongly refuse the app's requests on projects using the new
publishable keys. Only signed-in users of your project can still use it.

### Secrets for the Edge Function

Secrets are private values (like API keys) the function reads. You can add them in the dashboard
(**Edge Functions → Secrets**) or with a command. Replace the part in quotes with your own value.
No redeploy is needed after changing a secret.

| Secret | What it's for |
|---|---|
| `GEMINI_API_KEYS` | ✨ Summarize and Ask (comma-separated keys) |
| `GROQ_API_KEYS` | Optional backup for summaries |
| `GEMINI_TTS_KEYS` | Gemini read-aloud voice. Keys from a **separate** Google AI Studio project |
| `GEMINI_TTS_VOICE` | Optional. Voice name, default `Kore` (others: `Puck`, `Charon`, `Aoede`) |
| `GH_DISPATCH_TOKEN` | "Run digest now" button. GitHub fine-grained token, **Actions: Read and write** on this repo |
| `GH_REPO` | "Run digest now" button. Set to `MachangDoniel/NewsDigest` |

Example: set the Gemini voice to Puck:

```bash
supabase secrets set GEMINI_TTS_VOICE="Puck" --project-ref utjluiipjiznedsglqsm
```

See which secrets are set (it shows names, not the values):

```bash
supabase secrets list --project-ref utjluiipjiznedsglqsm
```

### Database changes

When `supabase/schema.sql` changes, open **Supabase → SQL Editor**, paste the new part, and press
**Run**. Running the whole file again is safe too; it skips what already exists.

The `speech` storage bucket (for saved read-aloud audio) is already created.

### GitHub side (the hourly digest)

The hourly schedule and the "Run digest now" button only work from the **`main`** branch. After a
feature branch is merged into `main` on GitHub, there's nothing to deploy: GitHub picks up the
workflow by itself.

### If something goes wrong

| You see | Do this |
|---|---|
| `WARNING: Docker is not running` | Nothing. Safe to ignore. Docker is only for running Supabase on your own Mac; without it, Supabase packages the function on its servers instead. If the last line says `Deployed Functions…`, it worked. |
| `command not found: brew` | Do step 1 again, and run the "Next steps" it prints. Reopen Terminal. |
| `command not found: supabase` | Run step 2 again. |
| `Access token not provided` or `Unauthorized` | Run `supabase login` again. |
| `No such file or directory` | You're in the wrong folder. The deploy command starts with `cd ~/Projects/NewsDigest`, so run it exactly as written. |
| The app still reads with Apple's voice | Deploy again, then check `GEMINI_TTS_KEYS` in `supabase secrets list`. Open the read-aloud panel; the grey note explains why. |

No Homebrew? Put `npx` in front instead (needs Node, which this project already uses):

```bash
npx supabase login
```

```bash
cd ~/Projects/NewsDigest && npx supabase functions deploy summarize --project-ref utjluiipjiznedsglqsm --no-verify-jwt
```

---

## Run the digest

Easiest: in the app, tap **Run digest now** on the Today tab, or on GitHub go to
**Actions → Daily digest → Run workflow**.

On this Mac (uses `server/.env`), first install once:

```bash
cd ~/Projects/NewsDigest/server && npm install && npx playwright install chromium
```

Build today's digest (skips papers already done):

```bash
cd ~/Projects/NewsDigest/server && npm run digest
```

Only one paper, and redo it even if it's already done:

```bash
cd ~/Projects/NewsDigest/server && npm run digest -- --paper prothomalo --force
```

Check whether today's digests exist:

```bash
cd ~/Projects/NewsDigest/server && npm run check-done
```

Delete saved read-aloud audio older than 3 days (the workflow also does this every hour):

```bash
cd ~/Projects/NewsDigest/server && npm run cleanup-speech
```

---

## App

After `project.yml` changes (or files are added), regenerate the Xcode project, then build in Xcode:

```bash
cd ~/Projects/NewsDigest && xcodegen
```

```bash
open ~/Projects/NewsDigest/NewsDigest.xcodeproj
```

---

## Git

See what changed:

```bash
cd ~/Projects/NewsDigest && git status
```

Get the latest from GitHub:

```bash
cd ~/Projects/NewsDigest && git pull
```

Which branch you're on:

```bash
cd ~/Projects/NewsDigest && git branch --show-current
```
