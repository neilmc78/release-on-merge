#!/usr/bin/env bash
# Setup commands are single-quoted and run later through eval, which shellcheck cannot see.
# shellcheck disable=SC2317,SC2329,SC2016
# Tests next-version.sh against throwaway repositories: bash tests/next-version.test.sh
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/next-version.sh"
failures=0

check() { # name, expected output, then commands to set up the repository
  local name=$1 want=$2; shift 2
  local repo; repo=$(mktemp -d)
  (
    cd "$repo"
    git init -q -b main
    git config user.email test@example.invalid; git config user.name test
    "$@"
  )
  local got; got=$(cd "$repo" && "$script" 2>/dev/null)
  rm -rf "$repo"
  if [[ "$got" == "$want" ]]; then echo "ok   $name"; else echo "FAIL $name: got '$got', want '$want'"; failures=$((failures + 1)); fi
}

commit() { git commit -q --allow-empty -m "$1"; }
history() { # tags the upstream way, including ones that must be ignored
  commit one; git tag v0.3.0
  commit two; git tag v0.3.1
  commit three; git tag v.0.2.0; git tag v0.4.0-rc1
}

check "first release"            "v0.0.1 "       commit "Initial"
check "patch by default"         "v0.3.2 v0.3.1" eval 'history; commit "Merge pull request #22 from x/y

Fix History times"'
check "[minor] in the PR title"  "v0.4.0 v0.3.1" eval 'history; commit "Merge pull request #22 from x/y

[minor] Add a new tab"'
check "[major] in the PR title"  "v1.0.0 v0.3.1" eval 'history; commit "Merge pull request #22 from x/y

[major] Rework everything"'
check "versions sort as numbers" "v0.10.1 v0.10.0" eval 'commit a; git tag v0.9.0; commit b; git tag v0.10.0; commit c'
check "already released"         ""              eval 'history; commit four; git tag v0.3.2'
check "already released by a version-file commit" "" eval 'history; commit four; git checkout -q --detach; commit "Release v0.3.2"; git tag v0.3.2; git checkout -q main'
check "an unrelated child commit isn't a release" "v0.3.2 v0.3.1" eval 'history; commit four; git checkout -q --detach; commit "Something else"; git tag v9.9.9-x; git checkout -q main'
# Only the title counts. Repositories that put the PR's description in the
# merge commit must not bump on a keyword that appears in it (PocketLab, v1.0.0).
check "keywords in a squash-style description ignored" "v0.3.2 v0.3.1" eval 'history; commit "$(printf "Release every merge (#12)\n\n\`[minor]\` or \`[major]\` in the PR title bumps that part")"'
check "keywords in a merge commit's description ignored" "v0.3.2 v0.3.1" eval 'history; commit "$(printf "Merge pull request #12 from a/b\n\nRelease every merge\n\nSay [major] for a big change")"'
check "[minor] in a squash-style title counts"       "v0.4.0 v0.3.1" eval 'history; commit "$(printf "[minor] New dashboard (#13)\n\nDetails")"'
RELEASE_MESSAGE="[minor] From the PR title" \
  check "RELEASE_MESSAGE overrides the commit"    "v0.4.0 v0.3.1" eval 'history; commit "plain"'

# --title gives the PR title, without a squash merge's " (#12)".
titled() { local repo; repo=$(mktemp -d); (cd "$repo"; git init -q -b main; git config user.email t@e.invalid; git config user.name t; git commit -q --allow-empty -m "$1") >/dev/null; (cd "$repo" && "$script" --title); rm -rf "$repo"; }
for case in "Fix History times (#21)|Fix History times" $'Merge pull request #5 from a/b\n\nFix History times|Fix History times' $'Fix it (#3)\n\nBody (#4)|Fix it'; do
  got=$(titled "${case%|*}")
  if [[ "$got" == "${case#*|}" ]]; then echo "ok   --title: ${case#*|}"; else echo "FAIL --title: got '$got', want '${case#*|}'"; failures=$((failures + 1)); fi
done

# --released names the release HEAD belongs to.
released() { local repo; repo=$(mktemp -d); (cd "$repo"; git init -q -b main; git config user.email t@e.invalid; git config user.name t; "$@") >/dev/null; (cd "$repo" && "$script" --released); rm -rf "$repo"; }
got=$(released eval 'commit a; git tag v1.2.3')
if [[ "$got" == "v1.2.3" ]]; then echo "ok   --released on a tagged commit"; else echo "FAIL --released on a tagged commit: '$got'"; failures=$((failures + 1)); fi
got=$(released eval 'commit a; git tag v1.2.3; commit b')
if [[ -z "$got" ]]; then echo "ok   --released on an unreleased commit"; else echo "FAIL --released on an unreleased commit: '$got'"; failures=$((failures + 1)); fi

exit $failures
