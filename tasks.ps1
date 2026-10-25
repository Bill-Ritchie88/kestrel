<#
    Project Kestrel - task runner for Windows PowerShell.

    The same targets as the Makefile, for a workstation without make.

        .\tasks.ps1 help
        .\tasks.ps1 setup
        .\tasks.ps1 test
#>

param([Parameter(Position = 0)][string]$Target = "help")

$ErrorActionPreference = "Stop"
$Py = if (Test-Path ".venv\Scripts\python.exe") { ".venv\Scripts\python.exe" } else { "python" }

function Invoke-Setup {
    python -m venv .venv
    .venv\Scripts\python.exe -m pip install --upgrade pip
    .venv\Scripts\python.exe -m pip install -r requirements-dev.txt -e .
    Write-Host "Now: copy .env.example to .env and fill it in" -ForegroundColor Yellow
}

function Stop-KestrelServices {
    # uvicorn --reload on Windows runs launcher -> reloader -> worker, and the
    # worker inherits the listening socket. Stopping only the process that owns
    # the port leaves the worker serving requests with the old code and .env,
    # so stop each service's whole tree, plus workers already orphaned that way.
    $all = @(Get-CimInstance Win32_Process)
    $alive = @{}; foreach ($p in $all) { $alive[[int]$p.ProcessId] = $true }

    $roots = @($all | Where-Object { $_.CommandLine -match 'uvicorn kestrel\.(api\.main|agent_service):app' } |
               ForEach-Object { [int]$_.ProcessId })
    $roots += @(Get-NetTCPConnection -LocalPort 8000, 8001 -State Listen -ErrorAction SilentlyContinue |
                ForEach-Object { [int]$_.OwningProcess })

    $doomed = @{}
    $queue = [System.Collections.Generic.Queue[int]]::new()
    foreach ($id in $roots) { if (-not $doomed[$id]) { $doomed[$id] = $true; $queue.Enqueue($id) } }
    while ($queue.Count) {
        $id = $queue.Dequeue()
        foreach ($c in $all | Where-Object { [int]$_.ParentProcessId -eq $id }) {
            if (-not $doomed[[int]$c.ProcessId]) { $doomed[[int]$c.ProcessId] = $true; $queue.Enqueue([int]$c.ProcessId) }
        }
    }

    # Orphans: multiprocessing workers of this venv's base interpreter whose parent
    # is gone. Matched on the command line, which starts with the pyvenv.cfg home
    # (for a Store Python, ExecutablePath is the real package path instead).
    $home_ = (Get-Content .venv\pyvenv.cfg -ErrorAction SilentlyContinue | Where-Object { $_ -match '^home\s*=' }) -replace '^home\s*=\s*', ''
    if ($home_) {
        $prefix = '"' + $home_.Trim().TrimEnd('\') + '\'
        foreach ($p in $all | Where-Object { $_.CommandLine -match 'spawn_main\(parent_pid=' -and
                                              $_.CommandLine.StartsWith($prefix, 'OrdinalIgnoreCase') -and
                                              -not $alive[[int]$_.ParentProcessId] }) {
            $doomed[[int]$p.ProcessId] = $true
        }
    }

    foreach ($id in $doomed.Keys) {
        if ($alive[$id]) {
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
            Write-Host "Stopped process $id"
        }
    }
    if (-not $doomed.Count) { Write-Host "No Kestrel services running" }
}

function Invoke-Web {
    # The release build for demos: compiled and minified, CanvasKit and fonts
    # served from this machine (--no-web-resources-cdn), nothing fetched from
    # Google at start-up. `flutter run` stays for development.
    #
    # --wasm: Chrome and Edge run the WebAssembly build (skwasm renderer);
    # other browsers get the JavaScript build from the same folder. Measured
    # in headless Chrome 155 on the demo laptop, the WebAssembly build reached
    # its first frame in a median 0.85 s on a first visit (JS: 1.65 s) and
    # 0.29 s on a repeat visit (JS: 0.59 s), and every screen worked.
    #
    # Supabase settings are read from .env and passed to the build without
    # being printed. The anon key is public by design; it ends up in the
    # compiled site either way.
    $envVars = @{}
    if (Test-Path .env) {
        foreach ($line in Get-Content .env) {
            if ($line -match '^\s*(SUPABASE_URL|SUPABASE_ANON_KEY|ALLOWED_ORIGINS)\s*=\s*"?([^"#]*)"?\s*$') {
                $envVars[$Matches[1]] = $Matches[2].Trim()
            }
        }
    }
    $defines = @()
    if ($envVars["SUPABASE_URL"] -and $envVars["SUPABASE_ANON_KEY"]) {
        $defines += "--dart-define=SUPABASE_URL=$($envVars['SUPABASE_URL'])"
        $defines += "--dart-define=SUPABASE_ANON_KEY=$($envVars['SUPABASE_ANON_KEY'])"
        Write-Host "Google and email sign-in: on (Supabase settings from .env)"
    } else {
        Write-Host "Google and email sign-in: off (SUPABASE_URL / SUPABASE_ANON_KEY not set in .env)" -ForegroundColor Yellow
    }
    if (-not ($envVars["ALLOWED_ORIGINS"] -match 'http://localhost:8080')) {
        Write-Host "Add http://localhost:8080 to ALLOWED_ORIGINS in .env, then restart the services (.\tasks.ps1 up)" -ForegroundColor Yellow
    }

    Push-Location client
    try {
        flutter build web --wasm --release --no-web-resources-cdn @defines
        if ($LASTEXITCODE -ne 0) { throw "flutter build web failed" }
    } finally {
        Pop-Location
    }
    & $Py scripts/dev/serve_web.py --port 8080
}

function Invoke-Android {
    # Runs the app on the Android emulator (start one first in Android Studio:
    # Device Manager -> play). The emulator reaches this PC's services at
    # 10.0.2.2:8000 and :8001 (AppConfig), so start them first: .\tasks.ps1 start
    # Supabase settings come from .env, as for the website, without being printed.
    $defines = @()
    if (Test-Path .env) {
        $vals = @{}
        foreach ($line in Get-Content .env) {
            if ($line -match '^\s*(SUPABASE_URL|SUPABASE_ANON_KEY)\s*=\s*"?([^"#]*)"?\s*$') {
                $vals[$Matches[1]] = $Matches[2].Trim()
            }
        }
        if ($vals["SUPABASE_URL"] -and $vals["SUPABASE_ANON_KEY"]) {
            $defines += "--dart-define=SUPABASE_URL=$($vals['SUPABASE_URL'])"
            $defines += "--dart-define=SUPABASE_ANON_KEY=$($vals['SUPABASE_ANON_KEY'])"
            Write-Host "Google and email sign-in: on (Supabase settings from .env)"
        }
    }
    # Windows PowerShell 5.1: join the JSON lines first, and enumerate the array from a variable.
    $devices = flutter devices --machine | Out-String | ConvertFrom-Json
    $device = ($devices | Where-Object { $_.targetPlatform -like "android*" } | Select-Object -First 1).id
    if (-not $device) { throw "No Android emulator running. Start one in Android Studio (Device Manager), then try again." }
    Push-Location client
    try {
        flutter run -d $device @defines
    } finally {
        Pop-Location
    }
}

switch ($Target) {
    "setup"    { Invoke-Setup }
    "lock"     { & $Py -m pip freeze | Out-File -Encoding utf8 requirements.lock.txt
                 Write-Host "requirements.lock.txt written" }
    "lint"     { & $Py -m ruff check . }
    "fmt"      { & $Py -m ruff check . --fix; & $Py -m ruff format . }
    "test"     { & $Py -m pytest -v tests/unit }
    "test-all" { & $Py scripts/data/reset_demo.py --if-stale; & $Py -m pytest -v }
    "smoke"    { & $Py scripts/evaluation/smoke_test.py }
    "data"     { & $Py scripts/data/generate_dataset.py --truncate --days 7 --seed 42 }
    "reset"    { & $Py scripts/data/reset_demo.py }
    "api"      { & $Py -m uvicorn kestrel.api.main:app --reload }
    "agent-api" { & $Py -m uvicorn kestrel.agent_service:app --port 8001 --reload }
    "web"      { Invoke-Web }
    "android"  { Invoke-Android }
    "down"     { Stop-KestrelServices }
    { $_ -in "up", "start" } { Stop-KestrelServices
                 # Both services need the same AGENT_HISTORY_KEY (assistant turns are
                 # saved only with it). Not in .env: one for this run, inherited by both.
                 if (-not (Select-String -Path .env -Pattern '^\s*AGENT_HISTORY_KEY\s*=\s*\S' -Quiet -ErrorAction SilentlyContinue)) {
                     $bytes = New-Object byte[] 32
                     [System.Security.Cryptography.RNGCryptoServiceProvider]::new().GetBytes($bytes)
                     $env:AGENT_HISTORY_KEY = [Convert]::ToBase64String($bytes)
                 }
                 Start-Process powershell -ArgumentList "-NoExit", "-Command", "& '$Py' -m uvicorn kestrel.api.main:app --reload"
                 Start-Process powershell -ArgumentList "-NoExit", "-Command", "& '$Py' -m uvicorn kestrel.agent_service:app --port 8001 --reload"
                 Write-Host "REST tier on :8000, agent service on :8001 (two new windows)" }
    "ingest"   { & $Py scripts/data/ingest_policies.py }
    "evaluate" { & $Py scripts/evaluation/evaluate_retrieval.py }
    "loadtest" { & $Py scripts/evaluation/load_test.py --passengers 12 }
    "agent"    { & $Py scripts/dev/agent_demo.py }
    "hooks"    { & $Py -m pre_commit install; & $Py -m pre_commit run --all-files }
    "clean"    { Get-ChildItem -Recurse -Directory -Filter __pycache__ | Remove-Item -Recurse -Force
                 Remove-Item -Recurse -Force .pytest_cache, .ruff_cache, src\*.egg-info -ErrorAction SilentlyContinue }
    default {
        Write-Host "Project Kestrel tasks:`n"
        @(
            @("setup",    "Create .venv and install dependencies"),
            @("lock",     "Pin exact versions into requirements.lock.txt"),
            @("lint",     "Static analysis"),
            @("fmt",      "Auto-fix formatting and import order"),
            @("test",     "Unit tests only (no database needed)"),
            @("test-all", "Unit + integration tests (resets stale demo data)"),
            @("smoke",    "Verify DB connection and stored procedure"),
            @("data",     "Regenerate the synthetic dataset"),
            @("reset",    "Reset the demo data to now"),
            @("api",      "Run the REST tier with reload"),
            @("agent-api","Run the agent service (Flutter chat) on :8001"),
            @("web",      "Release build of the website, served on http://localhost:8080"),
            @("android",  "Run the app on the running Android emulator (start the services first)"),
            @("start",    "Start (or restart) the REST tier and the agent service together"),
            @("up",       "Same as start"),
            @("down",     "Stop both services, including orphaned reload workers"),
            @("ingest",   "Chunk, embed and load the policy corpus"),
            @("evaluate", "Retrieval evaluation and tau calibration"),
            @("loadtest", "Concurrent rebooking test (rolled back)"),
            @("agent",    "Run the agent for a disrupted passenger"),
            @("hooks",    "Install pre-commit hooks"),
            @("clean",    "Remove caches")
        ) | ForEach-Object { "  {0,-10} {1}" -f $_[0], $_[1] }
    }
}
