# Contributing to tikjot

tikjot is maintained by one person in their free time. There are no promises or timelines — but every report is read.

## Bugs, ideas, questions
- **Bugs:** open an issue with the bug template (macOS version, Jira Cloud or Data Center, what happened). A
  diagnostics file helps: Settings › General › Export diagnostics — it contains no descriptions, URLs or tokens.
- **Ideas and questions:** GitHub Discussions, not issues.
- **Security problems:** privately, see [SECURITY.md](SECURITY.md).

## tikjot stays simple
tikjot does one job — track your day and turn it into Jira worklogs you review before sending — with as few settings
and reminders as possible. That's why many good ideas won't make it in. It's nothing personal: a "no" usually means
"it would make tikjot harder to use for everyone else". Forks are welcome (under their own name, see
[TRADEMARKS.md](TRADEMARKS.md)).

## Code contributions

tikjot is licensed under the GPL v3.0. By submitting a contribution (a pull request, patch or any other code), you
agree that:

1. your contribution is your own work, or you have the right to submit it;
2. it is licensed under the GPL v3.0, like the rest of tikjot; and
3. you also grant Martin Suster, the maintainer of tikjot, a perpetual, worldwide, non-exclusive, royalty-free license to
   use, modify and distribute your contribution under other license terms as well — so tikjot can, for example, be
   offered in the Mac App Store, whose terms are not compatible with the GPL. tikjot itself stays free and open source.

Please sign off your commits (`git commit -s`) to confirm this.

Before a pull request: `scripts/build.sh test-unit` and `cd Packages/TikjotKit && swift test --force-resolved-versions` should pass (the flag keeps `Package.resolved` as Xcode writes it — it also pins the app's Sparkle).
Never test against a real Jira you don't own — the test suite uses the built-in mock Jira.

## Maintainer: before pushing
Enable the push guard once per clone: `git config core.hooksPath .githooks`. It runs `scripts/check-public.sh` on what you push
(GitHub noreply e-mails only, no `docs/` or `design/`, no private patterns from your local `.public-guard`) and `scripts/check-public-tree.py` on the files: every Jira key
must be on the invented list in `scripts/public-keys.txt`, and accented (Slovak) text belongs only in translations. Test
and demo data are always invented — never copy keys, names or texts from a real Jira or a bug report.
