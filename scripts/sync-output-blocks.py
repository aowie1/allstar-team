#!/usr/bin/env python3
"""Copy the canonical blocks in docs/output-formats.md into every agent that carries them."""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
spec = (root / "docs/output-formats.md").read_text()

TARGETS = {
    "output-contract": sorted((root / "agents").glob("*.md")),
    "review-template": [root / "agents" / f"{n}.md" for n in
                        ("code-reviewer", "alignment-reviewer", "security-specialist", "review-dispatcher")],
}

def block(name, text):
    m = re.search(rf"<!-- {name}:start -->.*?<!-- {name}:end -->", text, re.S)
    return m.group(0) if m else None

changed = 0
for name, files in TARGETS.items():
    canon = block(name, spec)
    if canon is None:
        sys.exit(f"canonical {name} block missing in docs/output-formats.md")
    for f in files:
        s = f.read_text()
        if block(name, s) is None:
            sys.exit(f"{f.relative_to(root)} has no {name} block to replace")
        t = re.sub(rf"<!-- {name}:start -->.*?<!-- {name}:end -->", lambda _: canon, s, flags=re.S)
        if t != s:
            f.write_text(t)
            changed += 1
            print("updated", f.relative_to(root))
print(f"{changed} file(s) changed")
