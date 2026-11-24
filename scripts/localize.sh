#!/bin/bash
# Round-trip Slovak translations: export strings → fill from scripts/localization/sk_*.py → import into String Catalogs.
# Prints strings that still need a translation.
set -e
cd "$(dirname "$0")/.."
xcodegen generate --quiet
rm -rf .build/loc
xcodebuild -exportLocalizations -project tikjot.xcodeproj -localizationPath .build/loc -exportLanguage sk >/dev/null 2>&1
python3 - <<'PY'
import re, html, glob, importlib.util
SK = {}
for f in sorted(glob.glob('scripts/localization/sk_*.py')):
    spec = importlib.util.spec_from_file_location('m', f); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    for k, v in vars(m).items():
        if not k.startswith('__') and isinstance(v, dict): SK.update(v)
p = '.build/loc/sk.xcloc/Localized Contents/sk.xliff'
x = open(p).read()
missing = []
def rep(m):
    b = m.group(0)
    sm = re.search(r'<source>(.*?)</source>', b, re.S)
    if not sm: return b
    src = html.unescape(sm.group(1))
    t = SK.get(src)
    if t is None:
        missing.append(src); return b
    te = html.escape(t, quote=False)
    if '<target' in b:
        return re.sub(r'<target[^>]*>.*?</target>|<target[^>]*/>', f'<target state="translated">{te}</target>', b, flags=re.S)
    return b.replace('</source>', f'</source>\n        <target state="translated">{te}</target>', 1)
open(p, 'w').write(re.sub(r'<trans-unit\b.*?</trans-unit>', rep, x, flags=re.S))
for s in sorted(set(missing)): print('MISSING:', repr(s))
PY
xcodebuild -importLocalizations -project tikjot.xcodeproj -localizationPath .build/loc/sk.xcloc >/dev/null 2>&1
# The importer puts the widget's catalogs under App/Resources/Other Resources — keep them with the widget.
if [ -d "App/Resources/Other Resources" ]; then mv "App/Resources/Other Resources/"*.xcstrings Widget/Resources/; rmdir "App/Resources/Other Resources"; fi
echo "localization done"
