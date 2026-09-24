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
    .venv\Scripts\python.exe -m pip install -r requirements.txt -r requirements-dev.txt
    Write-Host "Now: copy .env.example to .env and fill it in" -ForegroundColor Yellow
}

switch ($Target) {
    "setup"    { Invoke-Setup }
    "lock"     { & $Py -m pip freeze | Out-File -Encoding utf8 requirements.lock.txt
                 Write-Host "requirements.lock.txt written" }
    "lint"     { & $Py -m ruff check . }
    "fmt"      { & $Py -m ruff check . --fix; & $Py -m ruff format . }
    "test"     { & $Py -m pytest -v }
    "test-all" { & $Py -m pytest -v -m "integration or not integration" }
    "smoke"    { & $Py database.py }
    "data"     { & $Py scripts/dataset_generator.py --truncate --days 7 --seed 42 }
    "reset"    { Get-Content sql/Reset_demo_state.sql }
    "api"      { & $Py -m uvicorn main:app --reload }
    "agent"    { & $Py agent.py }
    "hooks"    { & $Py -m pre_commit install; & $Py -m pre_commit run --all-files }
    "clean"    { Remove-Item -Recurse -Force __pycache__, .pytest_cache, .ruff_cache,
                              tests\__pycache__ -ErrorAction SilentlyContinue }
    default {
        Write-Host "Project Kestrel tasks:`n"
        @(
            @("setup",    "Create .venv and install dependencies"),
            @("lock",     "Pin exact versions into requirements.lock.txt"),
            @("lint",     "Static analysis"),
            @("fmt",      "Auto-fix formatting and import order"),
            @("test",     "Unit tests only (no database needed)"),
            @("test-all", "Unit + integration tests (needs DATABASE_URL)"),
            @("smoke",    "Verify DB connection and stored procedure"),
            @("data",     "Regenerate the synthetic dataset"),
            @("reset",    "Print the demo reset SQL"),
            @("api",      "Run the REST tier with reload"),
            @("agent",    "Run the agent tier"),
            @("hooks",    "Install pre-commit hooks"),
            @("clean",    "Remove caches")
        ) | ForEach-Object { "  {0,-10} {1}" -f $_[0], $_[1] }
    }
}
