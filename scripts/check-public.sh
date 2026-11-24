#!/bin/bash
# Guards what goes into the (public) repo. Used by .githooks/pre-push; run by hand: scripts/check-public.sh <rev-range>
#   scripts/check-public.sh origin/main..HEAD     check commits about to be pushed
#   scripts/check-public.sh --all                 check the whole history
# Fails when a commit has an author/committer e-mail other than a GitHub noreply address, touches a private
# path (docs/, design/, *.pen, .deploy.env, .public-guard), or adds a line matching a private pattern.
# Private patterns (company names, internal hosts, personal e-mails …) live in .public-guard — one extended regex per
# line, case-insensitive, NOT in git (so the patterns themselves stay private).
set -o pipefail
cd "$(dirname "$0")/.."
RANGE=${1:?usage: check-public.sh <rev-range> | --all}
[ "$RANGE" = "--all" ] && RANGE=$(git rev-list --max-parents=0 HEAD | tail -1)^..HEAD 2>/dev/null
[ "$1" = "--all" ] && RANGE=HEAD
FAIL=0
fail() { echo "✗ $*"; FAIL=1; }

# 1. E-mails: GitHub noreply only (web-UI merges are committed by noreply@github.com).
while IFS='|' read -r h ae ce; do
  [[ "$ae" == *@users.noreply.github.com ]] || fail "$h author e-mail $ae is not a GitHub noreply address"
  [[ "$ce" == *@users.noreply.github.com || "$ce" == noreply@github.com ]] || fail "$h committer e-mail $ce is not a GitHub noreply address"
done < <(git log --format='%h|%ae|%ce' $RANGE)

# 2. Private paths.
while read -r f; do
  case "$f" in docs/*|design/*|*.pen|*/.deploy.env|.deploy.env|.public-guard) fail "private file in history: $f";; esac
done < <(git log --format= --name-only $RANGE | sort -u)

# 3. Private patterns in added lines (and commit messages).
if [ -f .public-guard ]; then
  PAT=$(grep -v '^\s*#' .public-guard | grep -v '^\s*$')
  if [ -n "$PAT" ]; then
    HITS=$( { git log -p --format='%h %B' $RANGE | grep -E '^\+[^+]|^[0-9a-f]{7,} ' ; } | grep -i -n -E -f <(echo "$PAT") | head -20)
    [ -n "$HITS" ] && { fail "private pattern found (see .public-guard):"; echo "$HITS" | cut -c1-160; }
  fi
else
  echo "! no .public-guard file — private-pattern check skipped"
fi

[ $FAIL = 0 ] && echo "✓ public check passed ($RANGE)"
exit $FAIL
