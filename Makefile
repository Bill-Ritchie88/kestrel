

.DEFAULT_GOAL := help
.PHONY: help setup lock lint fmt test test-all smoke data reset api agent hooks clean

PY ?= python

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	 | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup:  ## Create the virtual environment and install everything
	$(PY) -m venv .venv
	.venv/bin/pip install --upgrade pip
	.venv/bin/pip install -r requirements-dev.txt -e .
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
	pytest -v tests/unit

test-all:  ## Unit + integration tests (needs DATABASE_URL; resets stale demo data)
	$(PY) scripts/reset_demo.py --if-stale
	pytest -v

smoke:  ## Verify the DB connection and the stored procedure end to end
	$(PY) scripts/smoke_test.py

data:  ## Regenerate the synthetic dataset (7 days, seeded)
	$(PY) scripts/dataset_generator.py --truncate --days 7 --seed 42

reset:  ## Reset the demo data: schedule re-anchored to now, disruption recreated
	$(PY) scripts/reset_demo.py

api:  ## Run the REST tier with reload
	uvicorn kestrel.api.main:app --reload

agent:  ## Run the agent for a disrupted passenger (needs `make api` running)
	$(PY) scripts/agent_demo.py

hooks:  ## Install the pre-commit hooks
	pre-commit install
	pre-commit run --all-files

clean:  ## Remove caches
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
	rm -rf .pytest_cache .ruff_cache src/*.egg-info
