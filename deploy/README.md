# Deploying Kestrel (free tier: Render + Cloudflare Pages)

Kestrel runs online at no cost:

| Part | Where | Address |
|---|---|---|
| REST tier (`kestrel.api.main`) | Render, free web service, **Frankfurt** | `https://kestrel-myd3.onrender.com` |
| Assistant (`kestrel.agent_service`) | Render, free web service, **Frankfurt** | `https://kestrel-agent.onrender.com` |
| Kestrel Web (Flutter release build) | Cloudflare Pages, Direct Upload | `https://kestrel-web-a20.pages.dev` |
| Database, auth | Supabase, `eu-central-1` (Frankfurt) — unchanged | — |
| Model | Gemini API, free tier — unchanged | — |

Both services run in Frankfurt next to the database, so a query costs milliseconds instead of the ~390 ms
it costs from the laptop in Nairobi. The addresses above are the live ones; Render adds a suffix (`-myd3`)
and Cloudflare Pages one (`-a20`) when the plain name is taken, so a redeploy under new names changes them.

**Free-tier behaviour to know (and to state in the report):**
- A Render free service **sleeps after 15 minutes without traffic**; the next request wakes it in about a
  minute. Open the site a few minutes before a demo or a test session.
- Render gives 750 free instance hours a month per account (sleeping time does not count) and a monthly
  bandwidth allowance; both are far above what demos and testing use.
- The Supabase free project pauses after about a week without activity.
- Gemini's free tier allows about 20 assistant requests a day; quick replies use none.

One image runs both services (`deploy/Dockerfile`, `python:3.13-slim`, non-root user). It contains only
`requirements.txt` and `src/`; every setting comes from the environment. Render sets `$PORT`; the image
listens on it.

## Environment variables (names only — values come from your `.env`)

| Variable | REST tier | Assistant | Secret? |
|---|---|---|---|
| `SERVICE` | `api` | `agent` | no |
| `DATABASE_URL` | ✓ | – (the assistant never touches the database) | yes |
| `GOOGLE_API_KEY` | ✓ (policy embeddings) | ✓ (Gemini) | yes |
| `GEMINI_MODEL`, `GEMINI_THINKING_LEVEL`, `GEMINI_MAX_ATTEMPTS`, `GEMINI_TIMEOUT_S` | – | ✓ | no |
| `EMBEDDING_MODEL`, `POLICY_TAU` (= `0.66`) | ✓ | – | no |
| `SESSION_SECRET` | ✓ | – | yes |
| `STAFF_API_KEY` | ✓ | – | yes |
| `AGENT_HISTORY_KEY` | ✓ | ✓ — **the same value in both** | yes |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | ✓ | – | public, keep with the others |
| `ALLOWED_ORIGINS` | the site's address | the site's address | no |
| `FASTAPI_BASE_URL` | – | the REST tier's Render address | no |

Type the values into Render's dashboard. Never put them in a file in the repository.
`SESSION_SECRET` and `AGENT_HISTORY_KEY` must be fixed values (generate each once, e.g.
`[Convert]::ToBase64String((1..32 | % { Get-Random -Max 256 }))`), otherwise tokens and saved assistant
turns stop working whenever a service restarts.

---

## 1. The REST tier on Render

1. Render dashboard → **New** → **Web Service** → connect GitHub → choose `Bill-Ritchie88/kestrel`.
2. Settings:
   - **Name:** `kestrel-api` · **Region:** Frankfurt (EU Central) · **Branch:** `main`
   - **Runtime / Language:** Docker · **Dockerfile path:** `deploy/Dockerfile` · **Docker build context:** `.`
   - **Instance type:** Free
   - **Health check path:** `/health`
3. **Environment:** add the REST-tier variables from the table, with `SERVICE=api`. For `ALLOWED_ORIGINS`
   use a placeholder for now (`http://localhost:8080`); it is set to the site's address in step 4.
4. **Create Web Service.** The first build takes several minutes. Check
   `https://kestrel-myd3.onrender.com/health` → it reports the service and the database as online.

## 2. The assistant on Render

Same as step 1, with:
- **Name:** `kestrel-agent`
- Variables: the assistant's set from the table, `SERVICE=agent`, and
  `FASTAPI_BASE_URL=https://kestrel-myd3.onrender.com` (no trailing slash).
- Check `https://kestrel-agent.onrender.com/health`.

Both services redeploy automatically when `main` changes on GitHub.

## 3. Kestrel Web on Cloudflare Pages

1. Build the site on the laptop, pointing it at the two Render services (from the repo root):

   ```powershell
   cd kestrel_client
   flutter build web --wasm --release --no-web-resources-cdn `
     --dart-define=API_BASE=https://kestrel-myd3.onrender.com `
     --dart-define=AGENT_BASE=https://kestrel-agent.onrender.com `
     --dart-define=SUPABASE_URL=<value from .env> `
     --dart-define=SUPABASE_ANON_KEY=<value from .env>
   cd ..
   ```

   The anon key is public by design; it ends up in the site either way.

2. Cloudflare dashboard → **Workers & Pages** → **Create** → **Pages** → **Upload assets** (Direct Upload).
   Project name `kestrel-web` → upload the folder `kestrel_client\build\web` → **Deploy**.
   The site is live at `https://kestrel-web-a20.pages.dev`. To update it later: rebuild, then
   **Create new deployment** in the same project.

## 4. Connect the pieces

1. Render → `kestrel-api` and `kestrel-agent` → Environment → `ALLOWED_ORIGINS=https://kestrel-web-a20.pages.dev`
   (add `,http://localhost:8080` to keep local testing working) → **Save**; each service restarts.
2. Supabase → **Authentication** → **URL Configuration**: add `https://kestrel-web-a20.pages.dev` to
   **Redirect URLs** (Google sign-in returns there). Keep the localhost entries.
3. Test every screen on the live site, on a laptop and on a phone: guest sign-in, trip, assistant
   (one quick reply, one typed question), flights, confirm and rebook, vouchers, help, staff desk;
   Google and email-code sign-in.

## 5. Backup for live sessions: Cloudflare Tunnel from the laptop

If Render is asleep, slow or over a limit during a demo, run the back end on the laptop and expose it through
Cloudflare. No account settings change, and the laptop must stay on.

1. Start the services: `.\tasks.ps1 start`.
2. In two more PowerShell windows:

   ```powershell
   cloudflared tunnel --url http://localhost:8000    # prints https://<random>.trycloudflare.com  (REST tier)
   cloudflared tunnel --url http://localhost:8001    # prints another address                    (assistant)
   ```

3. Build the site with those two addresses as `API_BASE` and `AGENT_BASE` (step 3.1), then upload it to the
   same Pages project as a **branch deployment** named `backup`. Its address stays the same every time:
   `https://backup.kestrel-web-a20.pages.dev`.
4. Add `https://backup.kestrel-web-a20.pages.dev` to `ALLOWED_ORIGINS` in the laptop's `.env` (once), restart the
   services, and open the backup address.

The two `trycloudflare.com` addresses change every time the tunnels start, so step 3 is repeated each time.

## 6. If something goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| The site loads but every call fails | `ALLOWED_ORIGINS` doesn't match the site's address exactly | Step 4.1; no trailing slash |
| First request takes about a minute | Render was asleep | Expected; open the site early |
| Assistant says it can't reach the booking service | `FASTAPI_BASE_URL` wrong, or the REST tier asleep | Check step 2; open `/health` on both |
| Assistant replies but "forgets" earlier turns | `AGENT_HISTORY_KEY` differs between the services | Same value in both |
| Google sign-in returns to an error | Pages address missing from Supabase Redirect URLs | Step 4.2 |
| "Usage limit" message from the assistant | Gemini free quota used up for the day | Quick replies still work; the quota resets at midnight Pacific time (about 10:00 in Nairobi) |
