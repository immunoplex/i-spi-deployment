"""Compare a fresh install's schema with a reference (e.g. production) schema.

Usage: python -I compare_schema.py <fresh_dump.sql> <reference_dump.sql>

Both files are `pg_dump --schema-only --no-owner --no-privileges` output. Every
object of the fresh install is looked up in the reference by (type, schema, name)
and its definition compared after whitespace normalisation. Objects only in the
reference are NOT reported (the fresh install deliberately omits legacy objects;
db/MANIFEST.md lists them). Exit status 1 if any fresh object is missing from the
reference or defined differently.
"""
import re, sys

HEAD = re.compile(r"^--\n-- Name: (.*?); Type: ([A-Z ]+); Schema: ([^;]+); Owner: [^\n]*\n--\n", re.M)


def items(path):
    text = open(path, encoding="utf-8").read()
    marks = list(HEAD.finditer(text))
    out = {}
    for i, m in enumerate(marks):
        body = text[m.end(): marks[i + 1].start() if i + 1 < len(marks) else len(text)]
        body = re.sub(r"--[^\n]*", "", body)
        # pg_dump session lines (SET ..., \restrict/\unrestrict) are not part of the object
        body = "\n".join(l for l in body.splitlines()
                         if not l.startswith(("SET ", "\\", "SELECT pg_catalog.set_config")))
        out[(m.group(2), m.group(3), m.group(1))] = " ".join(body.split())
    return out


fresh, ref = items(sys.argv[1]), items(sys.argv[2])
missing = sorted(k for k in fresh if k not in ref)
differ = sorted(k for k in fresh if k in ref and fresh[k] != ref[k])
print(f"fresh objects: {len(fresh)}; same as reference: {len(fresh) - len(missing) - len(differ)}")
for k in missing:
    print("NOT IN REFERENCE  %s %s.%s" % k)
for k in differ:
    print("DIFFERENT         %s %s.%s" % k)
    if "-v" in sys.argv:
        print("   fresh:", fresh[k][:600]); print("   ref:  ", ref[k][:600])
sys.exit(1 if missing or differ else 0)
