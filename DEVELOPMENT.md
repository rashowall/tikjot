# Developing tikjot

How to build, test and release tikjot. For what the app does, see the [README](README.md).

## Requirements

- macOS 14 Sonoma or later
- Xcode 16+ (built with Xcode 26), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build & run

```sh
xcodegen generate          # creates tikjot.xcodeproj from project.yml
open tikjot.xcodeproj      # or: scripts/build.sh
```

Set your own team in `project.yml` (`DEVELOPMENT_TEAM`) if you build it yourself.

Try it without Jira or your own data: `scripts/run-demo.sh` launches **demo mode** (in-memory data + a mock Jira).
`scripts/run-demo.sh -demoNow "2026-10-01 16:42"` reproduces the moment used in the design.

## Tests

```sh
cd Packages/TikjotKit && swift test --force-resolved-versions     # domain, holidays, persistence, Jira client, sync engine, suggestions
scripts/build.sh test                   # app tests: unit + snapshot (hosted in the app) and UI tests (XCUITest)
scripts/build.sh test-unit              # … only unit + snapshot tests
scripts/build.sh test-ui                # … only UI tests
```

## UI & snapshot tests

Everything runs in **demo mode** (in-memory data + mock Jira, never your data or a real Jira) on a frozen clock
(`-demoNow "2026-10-01 16:42" -freezeClock`), in English (`en_GB` formats), time zone Europe/Bratislava.

- **UI tests** (`UITests/`, target `tikjotUITests`) drive the real app: Day timeline, day navigation, sections,
  add entry, add/remove a vacation day, Review & send to the mock Jira, Settings tabs, onboarding, and the popover
  (opened by the app itself with `-openPopover` — XCUITest can't click a menu-bar extra reliably). Elements are found
  by accessibility identifiers (`screen.day`, `period.next`, `day.entry`, `review.send`, …). They need a logged-in
  GUI session; the first run may ask to allow UI automation (System Settings › Privacy & Security). They don't run on CI.
- **Snapshot tests** (`AppTests/SnapshotTests.swift`, in-house helper `AppTests/Snapshot.swift`) render Day, Day
  (empty weekend), Week, Month, Unsent, Statistics, the popover, Settings › Work time and onboarding step 1, light and
  dark, at 1× and compare them with `AppTests/__Snapshots__/*.png` (per-channel tolerance 12/255, up to 0.2 % of pixels
  may differ). On a mismatch the run prints where `*-actual.png` and `*-diff.png` are
  (`/private/tmp/tikjot-captures/snapshots/failures`).
- **Re-record** after an intended UI change: `SNAPSHOT_RECORD=1 scripts/build.sh test-unit`, then review the changed
  PNGs (`git diff --stat AppTests/__Snapshots__`) and commit them. A missing reference is recorded automatically
  (that test fails once; the next run passes). References are rendered on macOS 26 — on another macOS version re-record
  first. CI skips snapshots (`SNAPSHOT_SKIP=1`).

## Project layout

| Path | What |
|---|---|
| `App/` | macOS app: menu bar + popover, main window (Day, Week, Month, Unsent, Statistics, Projects), settings, onboarding |
| `Widget/` | WidgetKit extension (reads a snapshot from the App Group; never opens the database) |
| `Shared/` | Code shared by the app and the widget |
| `Packages/TikjotKit` | `TikjotDomain` (pure rules), `TikjotHolidays`, `TikjotPersistence` (GRDB + SQLCipher), `JiraKit` (Cloud v3 / DC v2 + mock server), `SyncEngine`, `TikjotSuggestions` |
| `Vendor/GRDB` | GRDB.swift 7 (MIT) with the SQLCipher build enabled |
| `scripts/` | build, demo, capture (screenshots), localization round-trip, release (`release.sh`) |

The website (tikjot.com) and the design files are not part of this repository. `scripts/dmg/background.html` (the DMG
window background, rendered once into `background.png`) expects the website fonts next to it; the PNG is committed.

## Localization

UI strings live in String Catalogs. Slovak translations are kept in `scripts/localization/sk_*.py`;
`scripts/localize.sh` exports all strings, fills the translations and imports them back (it prints any missing ones).

## Releasing

Releases are Developer ID signed, notarized DMGs on GitHub Releases; the app updates itself with
[Sparkle](https://sparkle-project.org) (Release builds only — once a day it reads the appcast, sends nothing about
you or your Mac, and installs only when you confirm).

One-time setup on the release Mac:

- A **Developer ID Application** certificate for the team in `project.yml` (`DEVELOPMENT_TEAM`). Release builds sign
  with it (manual signing, hardened runtime, secure timestamp, no `get-task-allow`); Debug keeps Apple Development.
- Notarization credentials as a keychain profile:
  `xcrun notarytool store-credentials tikjot-notary --apple-id <apple id> --team-id <team>` (app-specific password).
- The Sparkle EdDSA key in the login Keychain (account `tikjot`): run Sparkle's `generate_keys --account tikjot`
  (`.build/xcode-release/SourcePackages/artifacts/sparkle/Sparkle/bin/`) and put the public key into
  `TIKJOT_SPARKLE_PUBLIC_KEY` in `project.yml`. Back the private key up (`generate_keys --account tikjot -x <file>`,
  keep it offline) — without it no installed copy can be updated.
- The feed URL is the build setting `TIKJOT_FEED_URL` in `project.yml`
  (`…/releases/latest/download/appcast.xml` of the public repo).

Each release:

1. Write the release notes — both files are required, the script stops before building without them:
   - `release-notes/<version>.md` (English) and `release-notes/<version>.sk.md` (Slovak, informal "ty");
   - short and for users, no jargon: a one-line summary, then `## New` / `## Fixed` (Slovak `## Nové` /
     `## Opravené`) with `- ` bullets. `**bold**`, `*italic*` and `[links](https://…)` work; `<!-- comments -->`
     are dropped; a heading without bullets stops the release (fill it or delete it).
2. Build:

   ```sh
   scripts/release.sh 0.9.1      # bump version + build number, archive, export (Developer ID), notarize + staple the app,
                                 # DMG (app + Applications link), sign, notarize + staple it, Sparkle appcast.xml,
                                 # release notes into the appcast
   ```

Everything lands in `dist/<version>/` (gitignored): `tikjot-<version>.dmg`, `appcast.xml` (built on top of the
previous release's appcast), `release-notes.md` and the notarization logs. In the appcast every item that has notes
in `release-notes/` gets them as small HTML (`scripts/release-notes.py`) in `<description xml:lang="en">` and
`<description xml:lang="sk">` — Sparkle's update window shows the one matching the user's language, else English.
Only the descriptions are added; the enclosure and its EdDSA signature (which signs the DMG) are left as written.
`python3 scripts/release-notes.py html release-notes/<version>.md` previews the HTML.

The script uploads nothing; then:

1. Commit `project.yml` (the version bump) and the release notes.
2. Create the GitHub release `v<version>` with `dist/<version>/release-notes.md` as its text and attach the DMG and
   `appcast.xml` — the latest release must carry the appcast, because the app reads
   `releases/latest/download/appcast.xml`. The script prints the `gh release create … --notes-file …` command.

Re-running for the same version is safe (same build number, everything rebuilt). Bump `Sparkle` in `project.yml`
deliberately (pinned to an exact version).

