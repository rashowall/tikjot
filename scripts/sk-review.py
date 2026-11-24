#!/usr/bin/env python3
"""Builds docs/review/tikjot-slovencina-review.xlsx: every UI string (EN → SK) with the screen it lives on,
plus columns for a proposed fix. Usage: python3 scripts/sk-review.py"""
import json, re, glob, os
from collections import defaultdict
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment
from openpyxl.worksheet.datavalidation import DataValidation

d = json.load(open('App/Resources/Localizable.xcstrings'))['strings']
AREA = [('Popover/', 'Popover'), ('Onboarding/', 'Onboarding'), ('Settings/', 'Settings'), ('Widget/', 'Widget'),
        ('NotificationService', 'Notifications'), ('Main/Day', 'Main · Day'), ('Main/Week', 'Main · Week'),
        ('Main/Month', 'Main · Month'), ('Main/Unsent', 'Main · Unsent'), ('Main/Statistics', 'Main · Statistics'),
        ('Main/Projects', 'Main · Projects'), ('Main/Review', 'Main · Review & send'), ('Main/Send', 'Main · Review & send'),
        ('Main/CommandBar', 'Main · Command bar & shortcuts'), ('Main/Friday', 'Main · Friday recap'), ('Main/Export', 'Export'),
        ('Main/', 'Main window'), ('Shared/Absence', 'Absence sheet'), ('Shared/', 'Shared parts'), ('MenuBar', 'Menu bar'),
        ('', 'App messages')]
norm = lambda s: re.sub(r'%(\d\$)?(lld|ld|d|@|f|\.\d+f)', '§', s)
lit = re.compile(r'(?:localized:\s*|Text\(|Button\(|Label\(|Toggle\(|\.help\()"((?:[^"\\]|\\.)*)"')
uses = defaultdict(set)
for p in glob.glob('App/Sources/**/*.swift', recursive=True) + glob.glob('Widget/Sources/**/*.swift', recursive=True):
    area = next(v for k, v in AREA if k in p)
    for m in lit.finditer(open(p).read()):
        s = re.sub(r'\\\((?:[^()]|\([^()]*\))*\)', '§', m.group(1)).replace('\\"', '"').replace('\\n', '\n')
        uses[s].add((area, os.path.basename(p)[:-6]))

rows = []
for k, v in d.items():
    if v.get('shouldTranslate') is False or not k.strip():
        continue
    loc = v.get('localizations', {})
    sk = loc.get('sk', {}).get('stringUnit', {}).get('value')
    if sk is None:
        var = loc.get('sk', {}).get('variations')
        sk = json.dumps(var, ensure_ascii=False) if var else ''
    u = uses.get(norm(k), set())
    areas = sorted({a for a, _ in u}) or ['(system / generated)']
    files = sorted({f for _, f in u})
    rows.append((' · '.join(areas) if len(areas) <= 3 else 'many screens', ', '.join(files[:4]), k, sk))
rows.sort(key=lambda r: (r[0] == 'many screens', r[0], r[1], r[2].lower()))

wb = Workbook(); ws = wb.active; ws.title = 'Slovenčina'
ws.append(['#', 'Obrazovka', 'Súbor', 'English', 'Slovensky (teraz)', 'Návrh opravy', 'OK?', 'Poznámka', 'Kľúč (needitovať)'])
for i, r in enumerate(rows, 1):
    ws.append([i, r[0], r[1], r[2], r[3], '', '', '', r[2]])
for c in ws[1]:
    c.font = Font(bold=True, color='FFFFFF'); c.fill = PatternFill('solid', fgColor='4B36D6')
for col, w in zip('ABCDEFGHI', [6, 26, 22, 50, 50, 40, 7, 30, 30]):
    ws.column_dimensions[col].width = w
for row in ws.iter_rows(min_row=2):
    for c in row: c.alignment = Alignment(wrap_text=True, vertical='top')
    row[5].fill = PatternFill('solid', fgColor='FFF7E0')
    row[8].font = Font(color='999999', size=9)
dv = DataValidation(type='list', formula1='"✓,✗"', allow_blank=True); ws.add_data_validation(dv); dv.add(f'G2:G{len(rows)+1}')
ws.freeze_panes = 'D2'; ws.auto_filter.ref = f'A1:I{len(rows)+1}'
info = wb.create_sheet('Ako na to')
for line in ['Kontrola slovenských textov tikjot', '',
             '1. Najlepšie: prechádzaj appku v slovenčine (Settings › General › Language › Slovenčina) a sem zapisuj, čo ťa udrie do očí.',
             '2. Zlý text → lepší napíš do „Návrh opravy“. Dobrý → môžeš dať ✓ do „OK?“ (nepovinné).',
             '3. %@, %lld, %1$@ sú miesta pre číslo alebo názov — v preklade musia zostať (poradie sa dá meniť cez %1$@ / %2$@).',
             '4. Stĺpec „Kľúč“ needituj — podľa neho opravy zapracujem.',
             '5. Filter v hlavičke, napr. Obrazovka = Popover.', '',
             'Terminológia appky: worklog, fond (pracovný fond), saldo, Poslať do Jiry, neprítomnosť, úloha (task), projekt.',
             'Hotovú tabuľku ulož a daj vedieť — opravy zapracujem naraz.']:
    info.append([line])
info.column_dimensions['A'].width = 120; info['A1'].font = Font(bold=True, size=14)
os.makedirs('docs/review', exist_ok=True)
out = 'docs/review/tikjot-slovencina-review.xlsx'; wb.save(out)
from collections import Counter
print(out, len(rows)); print(Counter(r[0] for r in rows).most_common(30))
