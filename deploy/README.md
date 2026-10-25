# Hosting Kestrel in Frankfurt

Prepared, not deployed. Two options, both in Frankfurt next to the Supabase database
(`eu-central-1`), both deployed **from this folder on your laptop - no GitHub needed**. Pick
one. From the laptop to Frankfurt a database query costs ~390 ms (two round trips); from a
server in Frankfurt it costs a few milliseconds, so every screen and every assistant tool call
gets faster.

One image runs both services (`deploy/Dockerfile`, `python:3.13-slim`, non-root user):

| Service | `SERVICE` | Runs | Health check |
|---|---|---|---|
| REST tier | `api` (default) | `uvicorn kestrel.api.main:app` on `$PORT` | `GET /health` |
| Agent service | `agent` | `uvicorn kestrel.agent_service:app` on `$PORT` | `GET /health` |

The image holds only `requirements.txt` and `src/`; settings and secrets come from the
environment. `LOG_TO_STDOUT=1` (set in the image) sends the JSON timing logs to standard
output, which both platforms collect - a container has no disk to keep `logs/`.

Build it locally first, if Docker is installed:

```powershell
docker build -f deploy/Dockerfile -t kestrel .
docker run --rm -p 8080:8080 --env-file .env kestrel                    # REST tier
docker run --rm -p 8081:8080 --env-file .env -e SERVICE=agent kestrel   # agent service
```

## Environment variables (names only)

| Variable | REST tier | Agent | Secret? |
|---|---|---|---|
| `DATABASE_URL` | ✓ | – (removed at start-up by design) | yes |
| `GOOGLE_API_KEY` | ✓ (policy embeddings) | ✓ (Gemini) | yes |
| `GEMINI_MODEL`, `GEMINI_THINKING_LEVEL`, `GEMINI_MAX_ATTEMPTS`, `GEMINI_TIMEOUT_S` | – | ✓ | no |
| `EMBEDDING_MODEL`, `POLICY_TAU` | ✓ | – | no |
| `SESSION_SECRET` | ✓ (signs passenger tokens) | – | yes |
| `STAFF_API_KEY` | ✓ | – | yes |
| `AGENT_HISTORY_KEY` | ✓ | ✓ (the same value: saves the assistant's turns) | yes |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | ✓ (checks account sign-in) | – | no (public), but keep with the others |
| `ALLOWED_ORIGINS` | ✓ the website's origin | ✓ the website's origin | no |
| `FASTAPI_BASE_URL` | – | ✓ **the REST tier's public URL** | no |

Copy the values from `.env`; never paste them into a file in the repo. `SESSION_SECRET` must
be set (otherwise every token dies with the process).

---

## Option A - Google Cloud Run, `europe-west3` (Frankfurt)

Once: install the Google Cloud CLI, `gcloud auth login`, choose or create a project with
billing, then:

```powershell
gcloud config set project PROJECT_ID
gcloud config set run/region europe-west3
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com
gcloud artifacts repositories create kestrel --repository-format=docker --location=europe-west3
```

Secrets (Secret Manager), one per value: `kestrel-database-url`, `kestrel-google-api-key`,
`kestrel-session-secret`, `kestrel-staff-key`. Easiest in the Console (Security → Secret
Manager → Create secret, paste the value). From PowerShell, write the value to a temporary file
**without a newline** (piping a string to `gcloud` adds one, and it would become part of the
secret), then delete the file:

```powershell
$v = Read-Host "DATABASE_URL" -AsSecureString
$f = New-TemporaryFile
[IO.File]::WriteAllText($f, [Net.NetworkCredential]::new("", $v).Password)
gcloud secrets create kestrel-database-url --data-file=$f
Remove-Item $f
```

Let Cloud Run read them (the default compute service account):

```powershell
$sa = "$(gcloud projects describe PROJECT_ID --format='value(projectNumber)')-compute@developer.gserviceaccount.com"
foreach ($s in "kestrel-database-url","kestrel-google-api-key","kestrel-session-secret","kestrel-staff-key") {
  gcloud secrets add-iam-policy-binding $s --member="serviceAccount:$sa" --role=roles/secretmanager.secretAccessor
}
```

### Build from the local folder

`gcloud run deploy --source .` builds the `Dockerfile` at the **root** of the folder it
uploads; Kestrel's lives in `deploy/`, so build once with Cloud Build (it also uploads this
folder - `.env`, `.venv`, `logs/` and `.sprint2-tmp/` are left out because gcloud follows
`.gitignore` when there is no `.gcloudignore`) and deploy that image twice:

```powershell
$img = "europe-west3-docker.pkg.dev/PROJECT_ID/kestrel/kestrel:v1"
gcloud builds submit --region=europe-west3 --config=deploy/cloudbuild.yaml --substitutions=_IMAGE=$img .
```

(Equivalent one-liner, if you prefer `--source`: copy `deploy/Dockerfile` to `Dockerfile` at
the repo root, then `gcloud run deploy kestrel-api --source . ...` with the flags below, and
delete the copy afterwards.)

### Deploy the REST tier

```powershell
gcloud run deploy kestrel-api --image=$img --region=europe-west3 `
  --allow-unauthenticated --port=8080 `
  --min-instances=1 --max-instances=2 --no-cpu-throttling --cpu=1 --memory=512Mi `
  --set-env-vars="SERVICE=api,EMBEDDING_MODEL=gemini-embedding-001,POLICY_TAU=0.75,SUPABASE_URL=https://REF.supabase.co,SUPABASE_ANON_KEY=ANON_KEY,ALLOWED_ORIGINS=https://YOUR-SITE" `
  --set-secrets="DATABASE_URL=kestrel-database-url:latest,GOOGLE_API_KEY=kestrel-google-api-key:latest,SESSION_SECRET=kestrel-session-secret:latest,STAFF_API_KEY=kestrel-staff-key:latest,AGENT_HISTORY_KEY=kestrel-agent-history-key:latest" `
  --startup-probe="httpGet.path=/health,periodSeconds=5,failureThreshold=12"
```

Note the URL it prints (`https://kestrel-api-....run.app`).

- `--min-instances=1 --no-cpu-throttling`: one instance stays up with CPU between requests, so
  the database pool stays warm (it is pinged every minute), the policy questions stay
  pre-embedded, and the login throttle's memory is kept. This costs more than scale-to-zero.
- `--max-instances=2`: the Supabase session pooler allows few connections (15 on the free
  plan); each instance keeps 4 open and may open up to 10.

### Deploy the agent service

```powershell
gcloud run deploy kestrel-agent --image=$img --region=europe-west3 `
  --allow-unauthenticated --port=8080 --timeout=120 `
  --min-instances=1 --max-instances=2 --no-cpu-throttling --cpu=1 --memory=512Mi `
  --set-env-vars="SERVICE=agent,FASTAPI_BASE_URL=https://kestrel-api-....run.app,GEMINI_MODEL=gemini-3.6-flash,GEMINI_THINKING_LEVEL=low,GEMINI_MAX_ATTEMPTS=2,GEMINI_TIMEOUT_S=20,ALLOWED_ORIGINS=https://YOUR-SITE" `
  --set-secrets="GOOGLE_API_KEY=kestrel-google-api-key:latest,AGENT_HISTORY_KEY=kestrel-agent-history-key:latest" `
  --startup-probe="httpGet.path=/health,periodSeconds=5,failureThreshold=12"
```

**Streaming.** `POST /api/chat/stream` sends Server-Sent Events; Cloud Run passes streamed
HTTP responses through as they are written (no buffering to configure). `--timeout=120`
covers the longest turn (5 model calls × 20 s is bounded by the agent itself). The agent
closes the stream right after `done` and then saves the two turns to the conversation memory;
`--no-cpu-throttling` gives that save (and the warm model client) CPU after the response has
gone out.

Check: `curl https://kestrel-api-....run.app/health` → `"database":"connected"`, and
`curl https://kestrel-agent-....run.app/health` → the model and the REST tier's URL.

---

## Option B - Fly.io, region `fra` (Frankfurt)

Once: install `flyctl`, `fly auth login`, then from the repo root:

```powershell
fly apps create kestrel-api      # rename in deploy/fly.api.toml if the name is taken
fly apps create kestrel-agent
```

Secrets (Fly encrypts them; `fly secrets set` reads `NAME=VALUE` pairs - type them in a
PowerShell window, not into a file):

```powershell
fly secrets set --app kestrel-api DATABASE_URL=... GOOGLE_API_KEY=... SESSION_SECRET=... STAFF_API_KEY=... AGENT_HISTORY_KEY=... `
  SUPABASE_URL=https://REF.supabase.co SUPABASE_ANON_KEY=... EMBEDDING_MODEL=gemini-embedding-001 POLICY_TAU=0.75 `
  ALLOWED_ORIGINS=https://YOUR-SITE
fly deploy . --config deploy/fly.api.toml
```

Then the agent, with the REST tier's URL (`https://kestrel-api.fly.dev`):

```powershell
fly secrets set --app kestrel-agent GOOGLE_API_KEY=... AGENT_HISTORY_KEY=... FASTAPI_BASE_URL=https://kestrel-api.fly.dev `
  GEMINI_MODEL=gemini-3.6-flash GEMINI_THINKING_LEVEL=low GEMINI_MAX_ATTEMPTS=2 GEMINI_TIMEOUT_S=20 `
  ALLOWED_ORIGINS=https://YOUR-SITE
fly deploy . --config deploy/fly.agent.toml
```

`fly deploy .` uploads this folder as the build context and builds `deploy/Dockerfile` on
Fly's builders, leaving out what `deploy/.dockerignore` lists (`.env*`, `.venv`, `kestrel_client/`,
`logs/`, `.sprint2-tmp/`, `.git`, caches, PDFs). Each `fly.*.toml` sets `primary_region = "fra"`,
`SERVICE`, a `GET /health` check, and keeps one machine running (warm pool, warm model client).
**Streaming:** Fly's proxy passes Server-Sent Events through unbuffered.

Check: `fly status --app kestrel-api`, `curl https://kestrel-api.fly.dev/health`.

---

## Website

The Flutter site is static: build it with the two public URLs and the Supabase values, then
upload the folder anywhere that serves files.

```powershell
cd kestrel_client
flutter build web --wasm --release --no-web-resources-cdn `
  --dart-define=API_BASE=https://kestrel-api-....run.app `
  --dart-define=AGENT_BASE=https://kestrel-agent-....run.app `
  --dart-define=SUPABASE_URL=https://REF.supabase.co `
  --dart-define=SUPABASE_ANON_KEY=ANON_KEY
```

(`.\tasks.ps1 web` does the same for `localhost`; for hosting, pass the two URLs.) Then upload
`kestrel_client/build/web`, for example:

- **Netlify Drop** - open <https://app.netlify.com/drop> and drag the `kestrel_client/build/web` folder
  onto the page.
- **Cloudflare Pages** (direct upload) - `npx wrangler pages deploy kestrel_client/build/web
  --project-name kestrel`.
- **Firebase Hosting** - `firebase init hosting` (public directory `kestrel_client/build/web`, single-page
  app: yes), then `firebase deploy --only hosting`.

The app has no deep links, so no rewrite rules are needed. Then:

1. Put the site's origin (e.g. `https://kestrel.netlify.app`) in `ALLOWED_ORIGINS` on **both**
   services (Cloud Run: `gcloud run services update kestrel-api --update-env-vars ...`; Fly:
   `fly secrets set ALLOWED_ORIGINS=...`). Several origins are comma-separated.
2. Supabase → Authentication → URL Configuration: set **Site URL** to the site and add
   `https://YOUR-SITE/**` to **Redirect URLs**, so Google sign-in returns to it.

## Before the first deploy

- Migrations 000-010 are applied to the Supabase database already; nothing to run.
- `SESSION_SECRET` set, and the same on every REST-tier instance.
- The Gemini key's quota: the free tier allows 20 requests a day per model; a hosted demo
  needs a paid key (or a lower `GEMINI_THINKING_LEVEL` and the quick replies).
