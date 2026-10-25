

.DEFAULT_GOAL := help
.PHONY: help setup lock lint fmt test test-all smoke data reset api agent-api agent ingest evaluate loadtest hooks clean

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
	$(PY) scripts/data/reset_demo.py --if-stale
	pytest -v

smoke:  ## Verify the DB connection and the stored procedure end to end
	$(PY) scripts/evaluation/smoke_test.py

data:  ## Regenerate the synthetic dataset (7 days, seeded)
	$(PY) scripts/data/generate_dataset.py --truncate --days 7 --seed 42

reset:  ## Reset the demo data: schedule re-anchored to now, disruption recreated
	$(PY) scripts/data/reset_demo.py

api:  ## Run the REST tier with reload
	uvicorn kestrel.api.main:app --reload

agent-api:  ## Run the agent service (chat endpoint for the Flutter client) on :8001
	uvicorn kestrel.agent_service:app --port 8001 --reload

ingest:  ## Chunk, embed and load the policy corpus (data/policy/sources)
	$(PY) scripts/data/ingest_policies.py

evaluate:  ## Retrieval evaluation and tau calibration (data/eval/policy_questions.csv)
	$(PY) scripts/evaluation/evaluate_retrieval.py

loadtest:  ## Concurrent rebooking test, rolled back (NFR-01, NFR-02)
	$(PY) scripts/evaluation/load_test.py --passengers 12

agent:  ## Run the agent for a disrupted passenger (needs `make api` running)
	$(PY) scripts/dev/agent_demo.py

hooks:  ## Install the pre-commit hooks
	pre-commit install
	pre-commit run --all-files

clean:  ## Remove caches
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
	rm -rf .pytest_cache .ruff_cache src/*.egg-info
