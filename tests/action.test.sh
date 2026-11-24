#!/usr/bin/env bash
# Expected notes are single-quoted on purpose: they contain literal backticks.
# shellcheck disable=SC2016
# Runs action.yml's release step in throwaway repositories, each with a local
# bare "origin" so the tag push is real, and a stand-in gh that records the
# release it was asked to create. Needs python3 with PyYAML.
#   bash tests/action.test.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

mkdir "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Records the release: its title line, then the notes file's contents.
prev=""
for arg; do
  [ "$prev" = --title ] && echo "title: $arg" >> "$GH_LOG"
  [ "$prev" = --notes-file ] && cat "$arg" >> "$GH_LOG"
  prev=$arg
done
EOF
chmod +x "$work/bin/gh"
python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["runs"]["steps"][0]["run"])' "$root/action.yml" > "$work/step.sh"

# new_repo: a repository with plugin/ and web/, an "origin", and one commit.
new_repo() {
  repo="$work/repo-$RANDOM"
  git init -q --bare "$repo.git"
  git init -q -b main "$repo"
  cd "$repo"
  git config user.email test@example.invalid
  git config user.name test
  git config push.negotiate false
  git remote add origin "$repo.git"
  mkdir plugin web
  echo a > plugin/file; echo a > web/file
  git add -A; git commit -q -m "Initial commit"
}

# release COMPONENTS EXTRA: runs the step in the current repository. Set
# VERSION_FILES, TITLE or DRY_RUN on the call to pass those inputs too.
release() {
  : > "$work/output"; : > "$work/gh.log"
  GITHUB_OUTPUT="$work/output" GH_LOG="$work/gh.log" COMPONENTS="$1" EXTRA_NOTES="$2" \
    VERSION_FILES="${VERSION_FILES:-}" TITLE="${TITLE:-}" DRY_RUN="${DRY_RUN:-false}" \
    NEXT_VERSION="$root/next-version.sh" PATH="$work/bin:$PATH" bash "$work/step.sh" > "$work/run.log" 2>&1
}

expect() { # name, actual, expected
  if [ "$2" == "$3" ]; then echo "ok   $1"; else
    printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$1" "$2" "$3"; failures=$((failures + 1)); fi
}
outputs() { tr '\n' ' ' < "$work/output"; }
gh_log() { tr '\n' '|' < "$work/gh.log"; }
remote_tags() { git ls-remote --tags origin | awk '{print $2}' | sed 's#refs/tags/##' | sort -V | tr '\n' ' '; }

new_repo
release "" ""
expect "first release: outputs" "$(outputs)" "released=true tag=v0.0.1 version=0.0.1 previous= "
expect "first release: tag pushed" "$(remote_tags)" "v0.0.1 "
expect "first release: title only" "$(gh_log)" "title: v0.0.1 — Initial commit|"

new_repo
git tag v0.3.1
echo b > web/file; git commit -qam "Change the web app"
git commit -q --allow-empty -m $'Merge pull request #5 from someone/branch\n\nFix History times'
release $'plugin: Silo plugin\n  web : Web app \n\n' '**Docker:** `ghcr.io/owner/image:latest`'
expect "components and notes: outputs" "$(outputs)" "released=true tag=v0.3.2 version=0.3.2 previous=v0.3.1 "
expect "components and notes: release" "$(gh_log)" 'title: v0.3.2 — Fix History times|**Silo plugin:** unchanged since v0.3.1.|**Web app:** updated in this release.||**Docker:** `ghcr.io/owner/image:latest`|'

new_repo
git tag v0.3.1
echo b > plugin/file; git commit -qam "Change the plugin"
git commit -q --allow-empty -m $'Merge pull request #6 from someone/branch\n\n[minor] Add a Calendar tab'
release "plugin: Silo's plugin" ""
expect "[minor] with an apostrophe label" "$(gh_log)" "title: v0.4.0 — Add a Calendar tab|**Silo's plugin:** updated in this release.|"

new_repo
git tag v0.3.1
release "plugin" ""
expect "already released: outputs" "$(outputs)" "released=false tag= version= previous= "
expect "already released: nothing pushed" "$(remote_tags)" ""
expect "already released: no release" "$(gh_log)" ""

new_repo
git commit -q --allow-empty -m second
shallow="$work/shallow"
git clone -q --depth 1 "file://$repo" "$shallow"
cd "$shallow"
if release "" ""; then status=0; else status=$?; fi
expect "shallow checkout refused" "$status $(grep -c 'fetch-depth: 0' "$work/run.log")" "1 1"

new_repo
git tag v1.1.5
echo '{"id":"plugin","version":"0.1.0"}' > manifest.json; git add manifest.json; git commit -qm "Add manifest"
git commit -q --allow-empty -m $'Merge pull request #7 from someone/branch\n\nFix a thing'
merge=$(git rev-parse HEAD)
VERSION_FILES=$'manifest.json\n' release "" ""
expect "version-files: outputs" "$(outputs)" "released=true tag=v1.1.6 version=1.1.6 previous=v1.1.5 "
expect "version-files: tagged commit has the version" "$(git show v1.1.6:manifest.json)" '{
  "id": "plugin",
  "version": "1.1.6"
}'
expect "version-files: tag sits on a Release commit on top of the merge" "$(git log -1 --format='%s %P' v1.1.6)" "Release v1.1.6 $merge"
expect "version-files: main is unchanged" "$(git rev-parse main)" "$merge"
expect "version-files: title is the PR's" "$(gh_log)" "title: v1.1.6 — Fix a thing|"
git checkout -q main
VERSION_FILES=manifest.json release "" ""
expect "version-files: a re-run makes no second release" "$(outputs)$(remote_tags)" "released=false tag= version= previous= v1.1.6 "

new_repo
git tag v0.1.0
git commit -q --allow-empty -m "A change"
if VERSION_FILES=missing.json release "" ""; then status=0; else status=$?; fi
expect "version-files: a missing file fails" "$status $(grep -c "missing.json doesn't exist" "$work/run.log")" "1 1"

new_repo
git tag v0.3.3
git commit -q --allow-empty -m "Work in progress"
DRY_RUN=true release "" ""
expect "dry run: next version, nothing pushed" "$(outputs)$(remote_tags)$(gh_log)" "released=false tag=v0.3.4 version=0.3.4 previous=v0.3.3 "
DRY_RUN=true TITLE="[minor] New dashboard" release "" ""
expect "dry run: a PR title's [minor] counts" "$(outputs)" "released=false tag=v0.4.0 version=0.4.0 previous=v0.3.3 "
git tag v0.3.4
DRY_RUN=true release "" ""
expect "dry run: an already-released commit reports its tag" "$(outputs)" "released=false tag=v0.3.4 version=0.3.4 previous= "

exit $failures
