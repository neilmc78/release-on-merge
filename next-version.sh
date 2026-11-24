#!/usr/bin/env bash
# Prints the next release tag and the previous one, as "NEXT PREVIOUS", for
# the commit at HEAD. PREVIOUS is empty for a repository's first release.
#
# The next release bumps the patch number of the highest vX.Y.Z tag. A
# "[minor]" or "[major]" in the release title bumps that part instead. Only
# the title counts, never a pull request's description that GitHub may also
# put in the merge commit. "next-version.sh --title" prints the title: the
# pull request's title from HEAD's merge commit, or the first line of
# RELEASE_MESSAGE when that is set, as it is for a pull request that hasn't
# been merged yet.
# Pre-release tags (v1.0.0-rc1) and malformed ones (v.0.2.0) are ignored.
#
# Prints nothing when HEAD is already released, so re-running a release does
# not make a second one. "next-version.sh --released" prints the tag HEAD was
# released as instead, or nothing.
set -euo pipefail

# release_title prints the pull request's title: the first non-empty line
# after "Merge pull request ..." in a merge commit, otherwise the first line
# (squash merges, and merge commits titled from the pull request), without a
# trailing " (#123)".
release_title() {
  local message title
  if [[ -n "${RELEASE_MESSAGE:-}" ]]; then
    message=$RELEASE_MESSAGE
  else
    message=$(git log -1 --format=%B HEAD)
  fi
  title=$(printf '%s\n' "$message" | awk 'NR == 1 && /^Merge pull request/ { merge = 1; next } merge && NF { print; exit } !merge { print; exit }')
  printf '%s\n' "$title" | sed -E 's/[[:space:]]+\(#[0-9]+\)$//'
}

release_tags() { git tag --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; }

# released_as prints the tag HEAD was released as. That is a tag on HEAD
# itself, or one on a "Release vX.Y.Z" commit made directly on top of HEAD to
# stamp version files (see action.yml's version-files).
released_as() {
  local head tag
  tag=$(git tag --points-at HEAD | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
  if [[ -n "$tag" ]]; then echo "$tag"; return; fi
  head=$(git rev-parse HEAD)
  for tag in $(release_tags | sort -rV | head -20); do
    if [[ "$(git rev-parse -q --verify "$tag^{commit}^1" 2>/dev/null)" == "$head" ]] &&
      [[ "$(git log -1 --format=%s "$tag")" == "Release $tag" ]]; then
      echo "$tag"
      return
    fi
  done
}

if [[ "${1:-}" == "--title" ]]; then
  release_title
  exit 0
fi

released=$(released_as)
if [[ "${1:-}" == "--released" ]]; then
  echo "$released"
  exit 0
fi
if [[ -n "$released" ]]; then
  echo "HEAD is already released as $released" >&2
  exit 0
fi

previous=$(release_tags | sort -V | tail -1)
if [[ -z "$previous" ]]; then
  major=0 minor=0 patch=0
else
  IFS=. read -r major minor patch <<< "${previous#v}"
fi

title=$(release_title)
if [[ "$title" == *"[major]"* ]]; then
  major=$((major + 1)) minor=0 patch=0
elif [[ "$title" == *"[minor]"* ]]; then
  minor=$((minor + 1)) patch=0
else
  patch=$((patch + 1))
fi

echo "v${major}.${minor}.${patch} ${previous}"
