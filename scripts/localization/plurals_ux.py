#!/usr/bin/env python3
"""Plural variations (English one/other, Slovak one/few/other) for count strings in Localizable.xcstrings.

Audit 2026-10-06 U10: "1 need you", "1 tasks ready" — every "%lld <noun>" string gets real plural forms.
Idempotent: run again after adding rows. Keeps Xcode's file format (" : ", 2-space indent, no final newline).
Usage: python3 scripts/localization/plurals_ux.py
"""
import json
import os
import re

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
CATALOG = os.path.join(ROOT, 'App', 'Resources', 'Localizable.xcstrings')

# key: (en one, en other, sk one, sk few, sk other)  — None for en means "same as the key".
PLURALS = {
    # Needs you (U1) — always with a unit
    '%lld days need you': ('%lld day needs you', None, '%lld deň čaká na teba', '%lld dni čakajú na teba', '%lld dní čaká na teba'),
    '%lld entries need you': ('%lld entry needs you', None, '%lld záznam čaká na teba', '%lld záznamy čakajú na teba', '%lld záznamov čaká na teba'),
    '%lld worklogs need you': ('%lld worklog needs you', None, '%lld worklog čaká na teba', '%lld worklogy čakajú na teba', '%lld worklogov čaká na teba'),
    '%lld things need you': ('%lld thing needs you', None, '%lld vec čaká na teba', '%lld veci čakajú na teba', '%lld vecí čaká na teba'),
    '%lld need you': ('%lld needs you', None, '%lld čaká na teba', '%lld čakajú na teba', '%lld čaká na teba'),
    '%lld needs you': ('%lld needs you', '%lld need you', '%lld čaká na teba', '%lld čakajú na teba', '%lld čaká na teba'),
    '%lld need a task': ('%lld needs a task', None, '%lld čaká na úlohu', '%lld čakajú na úlohu', '%lld čaká na úlohu'),
    '%lld ready': (None, None, '%lld pripravený', '%lld pripravené', '%lld pripravených'),
    '%lld running': (None, None, '%lld beží', '%lld bežia', '%lld beží'),
    '%lld selected': (None, None, '%lld vybraný', '%lld vybrané', '%lld vybraných'),
    '%lld times': ('%lld time', None, '%lld-krát', '%lld-krát', '%lld-krát'),
    '%lld entries restored': ('%lld entry restored', None, '%lld záznam je späť', '%lld záznamy sú späť', '%lld záznamov je späť'),
    '%lld tasks ready': ('%lld task ready', None, '%lld úloha pripravená', '%lld úlohy pripravené', '%lld úloh pripravených'),
    '%lld worklogs': ('%lld worklog', None, '%lld worklog', '%lld worklogy', '%lld worklogov'),
    '%lld worklogs not in Jira': ('%lld worklog not in Jira', None, '%lld worklog nie je v Jire', '%lld worklogy nie sú v Jire', '%lld worklogov nie je v Jire'),
    '%lld not in Jira': (None, None, '%lld nie je v Jire', '%lld nie sú v Jire', '%lld nie je v Jire'),
    # Existing count strings
    '%lld days': ('%lld day', None, '%lld deň', '%lld dni', '%lld dní'),
    '%lld days not in Jira': ('%lld day not in Jira', None, '%lld deň nie je v Jire', '%lld dni nie sú v Jire', '%lld dní nie je v Jire'),
    '%lld days are not in Jira yet': ('%lld day is not in Jira yet', None, '%lld deň ešte nie je v Jire', '%lld dni ešte nie sú v Jire', '%lld dní ešte nie je v Jire'),
    '%lld entries': ('%lld entry', None, '%lld záznam', '%lld záznamy', '%lld záznamov'),
    '%lld entries without a task stay in tikjot.': ('%lld entry without a task stays in tikjot.', None, '%lld záznam bez úlohy zostáva v tikjote.', '%lld záznamy bez úlohy zostávajú v tikjote.', '%lld záznamov bez úlohy zostáva v tikjote.'),
    '%lld filters': ('%lld filter', None, '%lld filter', '%lld filtre', '%lld filtrov'),
    '%lld planned absences': ('%lld planned absence', None, '%lld plánovaná neprítomnosť', '%lld plánované neprítomnosti', '%lld plánovaných neprítomností'),
    '%lld projects': ('%lld project', None, '%lld projekt', '%lld projekty', '%lld projektov'),
    '%lld projects are ready': ('%lld project is ready', None, '%lld projekt je pripravený', '%lld projekty sú pripravené', '%lld projektov je pripravených'),
    '%lld removed from Jira': (None, None, '%lld odstránený z Jiry', '%lld odstránené z Jiry', '%lld odstránených z Jiry'),
    '%lld snapshots': ('%lld snapshot', None, '%lld snímka', '%lld snímky', '%lld snímok'),
    '%lld tasks not sent': ('%lld task not sent', None, '%lld neodoslaná úloha', '%lld neodoslané úlohy', '%lld neodoslaných úloh'),
    '%lld types': ('%lld type', None, '%lld typ', '%lld typy', '%lld typov'),
    '%lld unchanged already in Jira': (None, None, '%lld nezmenený, už v Jire', '%lld nezmenené, už v Jire', '%lld nezmenených, už v Jire'),
    '%lld worklogs are in Jira.': ('%lld worklog is in Jira.', None, '%lld worklog je v Jire.', '%lld worklogy sú v Jire.', '%lld worklogov je v Jire.'),
    '%lld worklogs changed in Jira and here. Nothing is sent until you choose.': (
        '%lld worklog changed in Jira and here. Nothing is sent until you choose.', None,
        '%lld worklog sa zmenil v Jire aj tu. Nič sa neodošle, kým nerozhodneš.',
        '%lld worklogy sa zmenili v Jire aj tu. Nič sa neodošle, kým nerozhodneš.',
        '%lld worklogov sa zmenilo v Jire aj tu. Nič sa neodošle, kým nerozhodneš.'),
    "%lld worklogs didn't make it to Jira": ("%lld worklog didn't make it to Jira", None,
        '%lld worklog sa nedostal do Jiry', '%lld worklogy sa nedostali do Jiry', '%lld worklogov sa nedostalo do Jiry'),
    "%lld worklogs for this Jira aren't sent yet. Send them first if you want them in Jira.": (
        "%lld worklog for this Jira isn't sent yet. Send it first if you want it in Jira.", None,
        '%lld worklog pre túto Jiru ešte nie je odoslaný. Ak ho chceš mať v Jire, najprv ho odošli.',
        '%lld worklogy pre túto Jiru ešte nie sú odoslané. Ak ich chceš mať v Jire, najprv ich odošli.',
        '%lld worklogov pre túto Jiru ešte nie je odoslaných. Ak ich chceš mať v Jire, najprv ich odošli.'),
    "This Mac has %lld worklogs not in Jira yet. Send them first, or they'll be lost.": (
        "This Mac has %lld worklog not in Jira yet. Send it first, or it'll be lost.", None,
        'Na tomto Macu je %lld worklog, ktorý ešte nie je v Jire. Najprv ho odošli, inak sa stratí.',
        'Na tomto Macu sú %lld worklogy, ktoré ešte nie sú v Jire. Najprv ich odošli, inak sa stratia.',
        'Na tomto Macu je %lld worklogov, ktoré ešte nie sú v Jire. Najprv ich odošli, inak sa stratia.'),
    'Create %lld projects': ('Create %lld project', None, 'Vytvoriť %lld projekt', 'Vytvoriť %lld projekty', 'Vytvoriť %lld projektov'),
    'Delete %lld entries': ('Delete %lld entry', None, 'Zmazať %lld záznam', 'Zmazať %lld záznamy', 'Zmazať %lld záznamov'),
    'Import from %lld tasks': ('Import from %lld task', None, 'Importovať z %lld úlohy', 'Importovať z %lld úloh', 'Importovať z %lld úloh'),
    'Link %lld worklogs': ('Link %lld worklog', None, 'Prepojiť %lld worklog', 'Prepojiť %lld worklogy', 'Prepojiť %lld worklogov'),
    'Restored · %lld newer entries set aside': ('Restored · %lld newer entry set aside', None,
        'Obnovené · %lld novší záznam je odložený bokom', 'Obnovené · %lld novšie záznamy sú odložené bokom', 'Obnovené · %lld novších záznamov je odložených bokom'),
    'Review & send %lld tasks': ('Review & send %lld task', None, 'Odoslať %lld úlohu', 'Odoslať %lld úlohy', 'Odoslať %lld úloh'),
    'Send %lld tasks to Jira': ('Send %lld task to Jira', None, 'Odoslať %lld úlohu do Jiry', 'Odoslať %lld úlohy do Jiry', 'Odoslať %lld úloh do Jiry'),
    'Send %lld worklogs to Jira': ('Send %lld worklog to Jira', None, 'Odoslať %lld worklog do Jiry', 'Odoslať %lld worklogy do Jiry', 'Odoslať %lld worklogov do Jiry'),
    'At the first launch each day · kept for %lld days': ('At the first launch each day · kept for %lld day', None,
        'Pri prvom spustení v daný deň · uchováva sa %lld deň', 'Pri prvom spustení v daný deň · uchovávajú sa %lld dni', 'Pri prvom spustení v daný deň · uchováva sa %lld dní'),
    'On this Mac, last %lld days. Same key as your data.': ('On this Mac, last %lld day. Same key as your data.', None,
        'Na tomto Macu, posledný %lld deň. Rovnaký kľúč ako tvoje dáta.', 'Na tomto Macu, posledné %lld dni. Rovnaký kľúč ako tvoje dáta.', 'Na tomto Macu, posledných %lld dní. Rovnaký kľúč ako tvoje dáta.'),
    # Two-number sentences split into one plural piece each (2026-10-06)
    'of %lld tasks': ('of %lld task', None, 'z %lld úlohy', 'z %lld úloh', 'z %lld úloh'),
    '%lld workdays': ('%lld workday', None, '%lld pracovný deň', '%lld pracovné dni', '%lld pracovných dní'),
    # Month balance tooltip (2026-10-06)
    '%lld holidays off': ('%lld holiday off', None, '%lld sviatok', '%lld sviatky', '%lld sviatkov'),
    "Couldn't take %lld worklogs back — they're still in Jira.": ("Couldn't take %lld worklog back — it's still in Jira.", None,
        'Nepodarilo sa vrátiť %lld worklog — v Jire stále je.', 'Nepodarilo sa vrátiť %lld worklogy — v Jire stále sú.',
        'Nepodarilo sa vrátiť %lld worklogov — v Jire stále sú.'),
    'Utilization · last %lld months': ('Utilization · last %lld month', None,
        'Vyťaženie · posledný %lld mesiac', 'Vyťaženie · posledné %lld mesiace', 'Vyťaženie · posledných %lld mesiacov'),
}


def unit(v):
    return {'stringUnit': {'state': 'translated', 'value': v}}


def sort_key(k):
    # Close to Xcode's (Finder-like) order; Xcode re-sorts the file the next time it touches it.
    return re.sub(r'[^0-9a-z]+', '', k.lower())


def main():
    raw = open(CATALOG, encoding='utf-8').read()
    data = json.loads(raw)
    strings = data['strings']
    for key, (en_one, en_other, sk_one, sk_few, sk_other) in PLURALS.items():
        entry = strings.get(key, {})
        loc = entry.setdefault('localizations', {})
        loc['en'] = {'variations': {'plural': {'one': unit(en_one or key), 'other': unit(en_other or key)}}}
        loc['sk'] = {'variations': {'plural': {'few': unit(sk_few), 'one': unit(sk_one), 'other': unit(sk_other)}}}
        entry['localizations'] = dict(sorted(loc.items()))
        if key not in strings:
            # Insert near its sorted place (keeps the diff small).
            items = list(strings.items())
            pos = next((i for i, (k, _) in enumerate(items) if sort_key(k) > sort_key(key)), len(items))
            items.insert(pos, (key, entry))
            strings = dict(items)
        else:
            strings[key] = entry
    data['strings'] = strings
    out = json.dumps(data, indent=2, separators=(',', ' : '), ensure_ascii=False)
    out = re.sub(r'\n( *)("(?:[^"\\]|\\.)*" : )\{\}', lambda m: '\n' + m.group(1) + m.group(2) + '{\n\n' + m.group(1) + '}', out)
    open(CATALOG, 'w', encoding='utf-8').write(out)
    json.loads(out)
    print(f'{len(PLURALS)} plural strings')


if __name__ == '__main__':
    main()
