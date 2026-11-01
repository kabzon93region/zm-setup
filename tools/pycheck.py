"""Syntax-check the python block embedded in a geomask shell wrapper.

Usage: python tools/pycheck.py assets/geomask-node-scan.sh [...]

The wrappers differ ("exec python3 - <<'PYEOF'", 'exec "$_py" - "$@" <<'PYEOF'', etc.),
so instead of matching the invocation line we split on the heredoc marker itself.
"""
import ast
import re
import sys

MARKERS = ("PYEOF", "PY")


def extract(text):
    for marker in MARKERS:
        open_pat = "<<'%s'" % marker
        if open_pat not in text:
            continue
        body = text.split(open_pat, 1)[1]
        # the heredoc ends at a line containing exactly the marker
        m = re.search(r"(?m)^%s$" % re.escape(marker), body)
        if m:
            return body[: m.start()]
    return None


rc = 0
for p in sys.argv[1:]:
    try:
        src = extract(open(p, encoding="utf-8").read())
    except OSError as e:
        print("%s: cannot read (%s)" % (p, e))
        rc = 1
        continue
    if src is None:
        print("%s: no embedded python block" % p)
        continue
    try:
        ast.parse(src)
        print("%s: python parses OK (%d chars)" % (p, len(src)))
    except SyntaxError as e:
        print("%s: SYNTAX ERROR: %s (line %s)" % (p, e.msg, e.lineno))
        rc = 1
sys.exit(rc)
