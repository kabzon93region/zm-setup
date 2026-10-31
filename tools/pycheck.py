import ast, re, sys

p = sys.argv[1]
t = open(p, encoding='utf-8').read()
m = re.search(r"exec python3 - <<'PYEOF'\n(.*?)\nPYEOF", t, re.S) or \
    re.search(r"python3 - <<'PY'\n(.*?)\nPY\n", t, re.S)
if not m:
    print('%s: python block not found' % p); sys.exit(1)
try:
    ast.parse(m.group(1))
    print('%s: python parses OK (%d chars)' % (p, len(m.group(1))))
except SyntaxError as e:
    print('%s: SYNTAX ERROR %s at line %s' % (p, e.msg, e.lineno)); sys.exit(1)
