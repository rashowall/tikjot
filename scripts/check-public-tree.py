#!/usr/bin/env python3
"""Checks the files that go public for real data from the beta — by ALLOWLIST, so a new real key or Slovak text is
caught even when nobody thought to block it (scripts/check-public.sh only blocks the patterns in .public-guard).

    python3 scripts/check-public-tree.py            the tracked files of the working tree (what the hook checks)
    python3 scripts/check-public-tree.py <dir>      every file under <dir> (an exported public tree)
    python3 scripts/check-public-tree.py --list     every key-like token found, with its count

Rules (code, tests, scripts, release notes, docs; not website/, Vendor/ or binaries):
1. Jira keys: every "KEY-123" and every quoted all-caps word ("KEY", "OPS_DESK") must be in scripts/public-keys.txt
   — the invented demo/test keys and harmless words (GET, UTC, country codes…). A real project key from the beta
   stops the push until it is replaced by an invented one (or, if it is truly harmless, added to the list).
2. Slovak / accented text: only in translations, holidays, licences and Slovak release notes. Elsewhere a line with
   accented letters fails unless the accented word is in ALLOWED_WORDS below — real worklog texts, task and project
   names and people from the beta are usually Slovak.
Real beta data (keys, names, descriptions from diagnostics or screenshots) never goes into code: always invent.
"""
import re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SELF = ("scripts/check-public-tree.py", "scripts/public-keys.txt")
SKIP_DIRS = ("website/", "Vendor/", ".git/", ".build/", "tikjot.xcodeproj/", "dist/", "docs/", "design/")
BINARY = re.compile(r"\.(png|jpe?g|webp|gif|pdf|ttf|otf|woff2?|wav|mp3|m4a|caf|aiff?|icns|car|mov|mp4|zip|dmg)$", re.I)
# Keys are not checked in data that is about the world, not about Jira (law references, holiday ids).
KEY_FREE = ("Packages/TikjotKit/Sources/TikjotHolidays/Resources/",)
ACCENT_OK = ("Packages/TikjotKit/Sources/TikjotHolidays/Resources/", "Packages/TikjotKit/Tests/TikjotHolidaysTests/",
             "scripts/localization/", "App/Resources/Licences/", "THIRD_PARTY_NOTICES.md", "scripts/sk-review.py")
ACCENT_OK_SUFFIX = (".xcstrings", ".sk.md")
ALLOWED_WORDS = {"včera", "Roué", "Účet", "Bézier", "Slovenčina", "Nové", "Opravené", "Česko", "ÄBC"}   # UI words, names, test inputs

KEY = re.compile(r"\b([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*)-\d+\b")
QUOTED = re.compile(r"[\"“„]([A-Z][A-Z0-9_]{1,19})[\"”“]")
ACCENTED = re.compile(r"[À-ÖØ-öø-ɏ]")
WORD = re.compile(r"[\wÀ-ɏ]+")


def files(arg):
    if arg:
        base = Path(arg).resolve()
        return base, sorted(str(p.relative_to(base)) for p in base.rglob("*") if p.is_file())
    out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return ROOT, out.splitlines()


def main():
    args = [a for a in sys.argv[1:] if a != "--list"]
    listing = "--list" in sys.argv
    base, names = files(args[0] if args else None)
    allowed = set()
    for line in (ROOT / "scripts/public-keys.txt").read_text().splitlines():
        line = line.split("#")[0]
        allowed.update(line.split())
    found, problems = {}, []
    for name in names:
        if name.startswith(SKIP_DIRS) or name in SELF or BINARY.search(name):
            continue
        try:
            text = (base / name).read_text(encoding="utf-8")
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
        check_keys = not name.startswith(KEY_FREE)
        check_accents = not (name.startswith(ACCENT_OK) or name.endswith(ACCENT_OK_SUFFIX))
        for n, line in enumerate(text.splitlines(), 1):
            if check_keys:
                for tok in KEY.findall(line) + QUOTED.findall(line):
                    found[tok] = found.get(tok, 0) + 1
                    if tok not in allowed:
                        problems.append(f"{name}:{n}: key-like \"{tok}\" is not in scripts/public-keys.txt — {line.strip()[:120]}")
            if check_accents and ACCENTED.search(line):
                bad = [w for w in WORD.findall(line) if ACCENTED.search(w) and w not in ALLOWED_WORDS]
                if bad:
                    problems.append(f"{name}:{n}: accented text {bad[:3]} outside translations — {line.strip()[:120]}")
    if listing:
        for tok, c in sorted(found.items(), key=lambda x: -x[1]):
            print(f"{c:5} {tok}{'' if tok in allowed else '   ← not allowed'}")
    for p in problems:
        print("✗ " + p)
    if problems:
        print(f"✗ {len(problems)} finding(s): replace real beta data with invented data (or allowlist it if it is harmless).")
        return 1
    print(f"✓ public tree check passed ({len(names)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
