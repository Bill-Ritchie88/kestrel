"""
Configuration loading.

Every module that reads the environment imports this first, so .env is loaded
exactly once and before any module-level os.getenv() runs. auth.py reads
SESSION_SECRET at import time, which is why the load cannot be left to main.py.

Variables already set in the process environment win over .env, so CI and the
test suite can inject their own values.
"""

from pathlib import Path

from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parents[2]
ENV_PATH = PROJECT_ROOT / ".env"

load_dotenv(dotenv_path=ENV_PATH)
