"""Turn `flutter test --reporter expanded` failures into GitHub annotations.

Used by the CI client job: each failing test's description and the first
lines of its error become an `::error` annotation on the run summary.
"""

import re
import sys

log = open(sys.argv[1], encoding="utf-8", errors="replace").read()
blocks = re.findall(
    r"EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK.*?The test description was:\s*\n\s*(.+?)\n",
    log,
    re.S,
)
errors = re.findall(
    r"EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK[^\n]*\n(.*?)(?:When the exception was thrown|\Z)",
    log,
    re.S,
)
if not errors:
    errors = [log[-1500:]]
for i, err in enumerate(errors[:5]):
    title = blocks[i].strip() if i < len(blocks) else "flutter test"
    msg = err.strip()[:1500].replace("%", "%25").replace("\r", "").replace("\n", "%0A")
    print(f"::error title={title[:120]}::{msg}")
