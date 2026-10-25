"""
Fail the build if a secret has been committed.

Targeted at the specific incident this repository already had: a .env
containing a live Supabase password reached the remote twice because the
.gitignore was saved as UTF-16 and Git could not read it. Both conditions are
checked here, so the same mistake cannot pass CI a third time.

    python scripts/ci/check_secrets.py

Exit code 0 clean, 1 if anything is found.
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Resolved to an absolute path so the scan cannot be hijacked by a "git"
# earlier on PATH (ruff S607).
GIT = shutil.which("git") or sys.exit("[ERROR] git is not on PATH.")

# Patterns that must never appear in a tracked file.
PATTERNS = {
    "database URL with an inline password": re.compile(
        r"postgres(?:ql)?://[^\s:/@\"']+:(?!\[|PASSWORD|YOUR)[^\s:/@\"']+@"
    ),
    "Google API key": re.compile(r"AIza[0-9A-Za-z_\-]{35}"),
    "private key block": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
}

# Files allowed to contain placeholder-shaped connection strings.
ALLOWLIST = {".env.example", "check_secrets.py", "README.md"}

TEXT_SUFFIXES = {
    ".py",
    ".sql",
    ".md",
    ".txt",
    ".yml",
    ".yaml",
    ".json",
    ".toml",
    ".ini",
    ".cfg",
    ".env",
    ".example",
    ".ipynb",
    ".sh",
    ".ps1",
    "",
}


def tracked_files() -> list[str]:
    out = subprocess.run(  # noqa: S603 - fixed argv, no user input
        [GIT, "ls-files"], cwd=REPO_ROOT, capture_output=True, text=True, check=True
    )
    return out.stdout.splitlines()


def main() -> int:
    findings: list[str] = []
    files = tracked_files()

    # 1. No .env may be tracked at all.
    for path in files:
        name = Path(path).name
        if name == ".env" or (name.startswith(".env.") and name != ".env.example"):
            findings.append(f"{path}: an environment file is tracked by Git")

    # 2. No .gitignore may be UTF-16 - Git silently ignores nothing if it is.
    for path in files:
        if Path(path).name != ".gitignore":
            continue
        raw = (REPO_ROOT / path).read_bytes()[:4]
        if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
            findings.append(
                f"{path}: saved as UTF-16. Git cannot read it, so none of its "
                f"rules apply. Re-save as UTF-8."
            )

    # 3. No tracked file may carry a credential.
    for path in files:
        p = REPO_ROOT / path
        if Path(path).name in ALLOWLIST or p.suffix.lower() not in TEXT_SUFFIXES:
            continue
        try:
            content = p.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for label, pattern in PATTERNS.items():
            if pattern.search(content):
                findings.append(f"{path}: contains a {label}")

    if findings:
        print("Secret scan FAILED:\n")
        for f in findings:
            print(f"  - {f}")
        print("\nRemove the secret, rotate the credential, then commit again.")
        return 1

    print(f"Secret scan clean ({len(files)} tracked files).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
