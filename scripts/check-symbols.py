#!/usr/bin/env python3
"""Checks that every SF Symbol name used in the Swift sources exists on the deployment target (macOS 14.0).

A symbol that is missing at runtime renders as an empty image, silently, so a name added with a newer SDK
(e.g. "powerplug.portrait", macOS 15) would look fine on the developer's Mac and blank on a macOS 14 user's.

Source of truth: the system's CoreGlyphs availability table (symbol → release year → OS versions).
Checked: every plain string literal in the sources that is a known symbol name (covers Image(systemName:),
Label(systemImage:), NSImage(systemSymbolName:) and icon string constants alike), plus every literal passed
directly to one of those calls that is NOT a known symbol at all (a typo).

Usage: python3 scripts/check-symbols.py [--min 14.0] [dir ...]   (default dirs: App Widget Shared Packages)
Exit code 1 when an offender is found.
"""
import argparse, os, plistlib, re, sys

PLIST = '/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist'
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
CALL = re.compile(r'(?:systemName|systemImage|systemSymbolName)\s*:\s*"([^"\\\n]*)"')


def version(v):
    return tuple(int(x) for x in v.split('.'))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--min', default='14.0', help='minimum macOS version (deployment target), default 14.0')
    ap.add_argument('dirs', nargs='*', default=['App', 'Widget', 'Shared', 'Packages'])
    args = ap.parse_args()

    table = plistlib.load(open(PLIST, 'rb'))
    macos = {year: rel['macOS'] for year, rel in table['year_to_release'].items()}
    symbols = table['symbols']
    target = version(args.min)

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    problems, seen = [], set()
    for d in args.dirs:
        for dirpath, dirnames, files in os.walk(os.path.join(root, d)):
            dirnames[:] = [n for n in dirnames if n not in ('.build', 'build', 'DerivedData')]
            for f in files:
                if not f.endswith('.swift'):
                    continue
                path = os.path.join(dirpath, f)
                rel = os.path.relpath(path, root)
                for no, line in enumerate(open(path, encoding='utf-8'), 1):
                    for m in LITERAL.finditer(line):
                        name = m.group(1)
                        if name in symbols:
                            seen.add(name)
                            needs = macos[symbols[name]]
                            if version(needs) > target:
                                problems.append(f'{rel}:{no}: "{name}" needs macOS {needs}')
                    for m in CALL.finditer(line):
                        if m.group(1) not in symbols:
                            problems.append(f'{rel}:{no}: "{m.group(1)}" is not an SF Symbol')

    for p in problems:
        print(p)
    print(f'{len(seen)} symbol names checked against macOS {args.min}: '
          + (f'{len(problems)} problem(s)' if problems else 'all available'), file=sys.stderr)
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
