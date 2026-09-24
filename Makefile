# Project Kestrel - task runner.
#
# Every repeated command in the project lives here so it is written down once
# and is identical on the workstation and in CI. Windows users without make can
# use the PowerShell equivalent: .\tasks.ps1 <target>
#
#   make help

.DEFAULT_GOAL := help
.PHONY: help setup lock lint fmt test test-all smoke data reset api agent hooks clean

PY ?= python

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	 | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup:  ## Create the virtual environment and install everything
	$(PY) -m venv .venv
	.venv/bin/pip install --upgrade pip
	.venv/bin/pip install -r requirements.txt -r requirements-dev.txt
	@echo "Now: cp .env.example .env and fill it in"

lock:  ## Pin exact versions into requirements.lock.txt (fills Table 5.2)
	$(PY) -m pip freeze > requirements.lock.txt
	@echo "requirements.lock.txt written"

lint:  ## Static analysis
	ruff check .

fmt:  ## Auto-fix formatting and import order
	ruff check . --fix
	ruff format .

test:  ## Unit tests only (no database needed)
	pytest -v

test-all:  ## Unit + integration tests (needs DATABASE_URL)
	pytest -v -m "integration or not integration"

smoke:  ## Verify the DB connection and the stored procedure end to end
	$(PY) database.py

data:  ## Regenerate the synthetic dataset (7 days, seeded)
	$(PY) scripts/dataset_generator.py --truncate --days 7 --seed 42

reset:  ## Print the reset SQL to paste into the Supabase editor
	@cat sql/Reset_demo_state.sql

api:  ## Run the REST tier with reload
	uvicorn main:app --reload

agent:  ## Run the agent tier against the running API
	$(PY) agent.py

hooks:  ## Install the pre-commit hooks
	pre-commit install
	pre-commit run --all-files

clean:  ## Remove caches
	rm -rf __pycache__ .pytest_cache .ruff_cache tests/__pycache__
