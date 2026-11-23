#!/usr/bin/env python3
"""Print what an agent changed in a repo-managed skill and keep a copy.

    skill_diff.py <baseline_dir> <agent_dir> <agent> <rel> <keep_dir> [--only-new]

Compares the agent's live copy with the copy installed at the last deploy.
Prints a unified diff as [skill-diff] lines and copies the agent's version to
<keep_dir>/<agent>/. With --only-new (the daily check), prints and keeps only
when the agent copy changed since the last time it was reported.
"""
import hashlib
import difflib, pathlib, shutil, sys, time
repo, live, agent, rel, keep = (pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4], pathlib.Path(sys.argv[5]))
only_new = "--only-new" in sys.argv[6:]
h = hashlib.sha256()
for p in sorted(x for x in live.rglob("*") if x.is_file()):
    h.update(str(p.relative_to(live)).encode()); h.update(p.read_bytes())
digest = h.hexdigest()
marker = keep / agent / f".reported-{rel.replace('/', '__')}"
if only_new and marker.is_file() and marker.read_text().strip() == digest:
    sys.exit(0)
files = sorted({p.relative_to(repo) for p in repo.rglob("*") if p.is_file()} |
               {p.relative_to(live) for p in live.rglob("*") if p.is_file()})
changed = False
for f in files:
    a, b = repo / f, live / f
    if a.is_file() and b.is_file() and a.read_bytes() == b.read_bytes():
        continue
    if not changed:
        print(f"[skill-diff] {agent}: agent edits to {rel} (as installed -> agent copy):")
        changed = True
    if not b.is_file():
        print(f"[skill-diff] {agent}: deleted {f}")
        continue
    if not a.is_file():
        print(f"[skill-diff] {agent}: added {f} ({b.stat().st_size} bytes)")
    try:
        old = a.read_text(errors="replace").splitlines() if a.is_file() else []
        new = b.read_text(errors="replace").splitlines()
    except Exception:
        print(f"[skill-diff] {agent}: {f} changed (binary)")
        continue
    for line in difflib.unified_diff(old, new, f"installed/{f}", f"{agent}/{f}", n=1, lineterm=""):
        print(f"[skill-diff] {agent}: {line}")
if changed:
    dest = keep / agent / f"{rel.replace('/', '__')}-{time.strftime('%Y%m%d-%H%M%S')}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(live, dest, dirs_exist_ok=True)
    print(f"[skill-diff] {agent}: agent copy kept at {dest}")
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(digest)
