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

switch ($Target) {
    "setup"    { Invoke-Setup }
    "lock"     { & $Py -m pip freeze | Out-File -Encoding utf8 requirements.lock.txt
                 Write-Host "requirements.lock.txt written" }
    "lint"     { & $Py -m ruff check . }
    "fmt"      { & $Py -m ruff check . --fix; & $Py -m ruff format . }
    "test"     { & $Py -m pytest -v tests/unit }
    "test-all" { & $Py scripts/reset_demo.py --if-stale; & $Py -m pytest -v }
    "smoke"    { & $Py scripts/smoke_test.py }
    "data"     { & $Py scripts/dataset_generator.py --truncate --days 7 --seed 42 }
    "reset"    { & $Py scripts/reset_demo.py }
    "api"      { & $Py -m uvicorn kestrel.api.main:app --reload }
    "agent-api" { & $Py -m uvicorn kestrel.agent_service:app --port 8001 --reload }
    "up"       { Start-Process powershell -ArgumentList "-NoExit", "-Command", "& '$Py' -m uvicorn kestrel.api.main:app --reload"
                 Start-Process powershell -ArgumentList "-NoExit", "-Command", "& '$Py' -m uvicorn kestrel.agent_service:app --port 8001 --reload"
                 Write-Host "REST tier on :8000, agent service on :8001 (two new windows)" }
    "ingest"   { & $Py scripts/ingest_policies.py }
    "evaluate" { & $Py scripts/evaluate_retrieval.py }
    "loadtest" { & $Py scripts/load_test.py --passengers 12 }
    "agent"    { & $Py scripts/agent_demo.py }
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
            @("up",       "Start the REST tier and the agent service together"),
            @("ingest",   "Chunk, embed and load the policy corpus"),
            @("evaluate", "Retrieval evaluation and tau calibration"),
            @("loadtest", "Concurrent rebooking test (rolled back)"),
            @("agent",    "Run the agent for a disrupted passenger"),
            @("hooks",    "Install pre-commit hooks"),
            @("clean",    "Remove caches")
        ) | ForEach-Object { "  {0,-10} {1}" -f $_[0], $_[1] }
    }
}
