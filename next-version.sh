#!/usr/bin/env bash
# Prints the next release tag and the previous one, as "NEXT PREVIOUS", for
# the commit at HEAD. PREVIOUS is empty for a repository's first release.
#
# The next release bumps the patch number of the highest vX.Y.Z tag. A
# "[minor]" or "[major]" in the release message bumps that part instead. The
# message is HEAD's commit message (GitHub puts the pull request's title
# there when it merges), or RELEASE_MESSAGE when that is set, as it is for a
# pull request that hasn't been merged yet.
# Pre-release tags (v1.0.0-rc1) and malformed ones (v.0.2.0) are ignored.
#
# Prints nothing when HEAD is already released, so re-running a release does
# not make a second one. "next-version.sh --released" prints the tag HEAD was
# released as instead, or nothing.
set -euo pipefail

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

message=${RELEASE_MESSAGE:-$(git log -1 --format=%B HEAD)}
if [[ "$message" == *"[major]"* ]]; then
  major=$((major + 1)) minor=0 patch=0
elif [[ "$message" == *"[minor]"* ]]; then
  minor=$((minor + 1)) patch=0
else
  patch=$((patch + 1))
fi

echo "v${major}.${minor}.${patch} ${previous}"
