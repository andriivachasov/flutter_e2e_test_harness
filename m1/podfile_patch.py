#!/usr/bin/env python3
"""Adds the RunnerUITests target block to ios/Podfile. Idempotent."""
import pathlib, re, sys

path = pathlib.Path(sys.argv[1])
src = path.read_text()
if "RunnerUITests" in src:
    print("podfile: already patched")
    sys.exit(0)

block = "  target 'RunnerUITests' do\n    inherit! :complete\n  end\n"
# Insert inside the Runner target: right after the RunnerTests sub-target
# block if present, else right before the Runner target's closing `end`.
m = re.search(
    r"(  target 'RunnerTests' do\n(?:.*?\n)*?  end\n)", src)
if m:
    out = src[: m.end(1)] + block + src[m.end(1) :]
else:
    m = re.search(r"(target 'Runner' do\n(?:.*?\n)*?)^end$", src, re.M)
    if not m:
        print("podfile: ERROR — could not locate Runner target block")
        sys.exit(1)
    out = src[: m.end(1)] + block + src[m.end(1) :]
path.write_text(out)
print("podfile: patched")
