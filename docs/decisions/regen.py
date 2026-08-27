#!/usr/bin/env python3
"""Regenerates docs/decisions/adr-*.md from refined_requirements.md §2."""
import re, pathlib, sys
root = pathlib.Path(__file__).resolve().parents[2]
src = (root / 'refined_requirements.md').read_text()
rows = sorted(re.findall(r'^\| (D\d+) \| (.+?) \| (.+?) \| (.+?) \|$', src, re.M), key=lambda r: int(r[0][1:]))
out = root / 'docs' / 'decisions'
for f in out.glob('adr-*.md'): f.unlink()
def slug(t):
    t = re.sub(r'\(.*?\)', '', t).strip().lower()
    return re.sub(r'[^a-z0-9]+', '-', t).strip('-')[:48]
index = ['# Architecture decision records', '',
         'One file per decision, imported from `refined_requirements.md` §2 (the source of truth; edit there, regenerate here with `python3 docs/decisions/regen.py`). Status of all: **accepted**.', '',
         '| ADR | Decision |', '|---|---|']
for d, topic, choice, why in rows:
    n = int(d[1:]); fn = f'adr-{n:03d}-{slug(topic)}.md'
    (out / fn).write_text(f"# ADR-{n:03d} ({d}): {topic}\n\n**Status:** accepted · 2026-08-26\n\n## Decision\n\n{choice}\n\n## Rationale\n\n{why}\n\n## Where it lives\n\nSee `refined_requirements.md` ({d}) and the playbook steps that apply it.\n")
    index.append(f'| [ADR-{n:03d}]({fn}) | {topic} |')
(out / 'README.md').write_text('\n'.join(index) + '\n')
print(f'{len(rows)} ADRs written', file=sys.stderr)
