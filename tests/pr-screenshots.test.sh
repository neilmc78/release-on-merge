#!/usr/bin/env bash
# Runs pr-screenshots/action.yml's step against a local bare repository (the
# images branch) and a stand-in gh that keeps one comment per marker, so
# update-versus-create can be checked. Needs python3 with PyYAML.
#   bash tests/pr-screenshots.test.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap '[ "${KEEP:-}" ] || rm -rf "$work"' EXIT
failures=0

mkdir "$work/bin" "$work/comments"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
# GET lists the saved comment for the marker in --jq; POST saves one;
# PATCH replaces one. Every write is logged as "POST <pr>" or "PATCH <id>".
args="$*"
marker=$(grep -o 'pr-screenshots:[A-Za-z0-9_-]*' <<<"$args" | head -1 || true)
body=""; prev=""; for arg; do [ "$prev" = -F ] && body=${arg#body=@}; prev=$arg; done
if [[ "$args" == *"-X POST"* ]]; then
  pr=$(grep -o 'issues/[0-9]*/comments' <<<"$args" | cut -d/ -f2)
  id=$((100 + $(ls "$GH_COMMENTS" | wc -l)))
  set=$(head -1 "$body" | grep -o 'pr-screenshots:[A-Za-z0-9_-]*')
  cp "$body" "$GH_COMMENTS/$pr.$set.$id"
  echo "POST $pr" >> "$GH_LOG"
elif [[ "$args" == *"-X PATCH"* ]]; then
  id=$(grep -o 'comments/[0-9]*' <<<"$args" | cut -d/ -f2)
  file=$(ls "$GH_COMMENTS"/*."$id")
  cp "$body" "$file"
  echo "PATCH $id" >> "$GH_LOG"
else
  pr=$(grep -o 'issues/[0-9]*/comments' <<<"$args" | cut -d/ -f2)
  for file in "$GH_COMMENTS/$pr.$marker".*; do if [ -e "$file" ]; then echo "${file##*.}"; fi; done
fi
exit 0
EOF
chmod +x "$work/bin/gh"
python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["runs"]["steps"][0]["run"])' "$root/pr-screenshots/action.yml" > "$work/step.sh"
git init -q --bare "$work/images.git"

# post PR IMAGES... [SET]: runs the step for pull request PR with those image names.
post() {
  local pr=$1 set=${SET:-screenshots}; shift
  rm -rf "$work/shots"; mkdir "$work/shots"
  for name; do printf 'image %s' "$name" > "$work/shots/$name"; done
  : > "$work/gh.log"; : > "$work/output"
  GITHUB_OUTPUT="$work/output" GH_LOG="$work/gh.log" GH_COMMENTS="$work/comments" PR_SCREENSHOTS_REMOTE="$work/images.git" \
    IMAGE_DIR="$work/shots" BRANCH=screenshots HEADING="UI screenshots" WIDTH=240 SET="$set" PR="$pr" SHA="${SHA:-abcdef1234567}" \
    RUN=42 REPO=owner/repo SERVER=https://github.com GH_TOKEN=x PATH="$work/bin:$PATH" bash "$work/step.sh" > "$work/run.log" 2>&1
}
expect() {
  if [ "$2" == "$3" ]; then echo "ok   $1"; else
    printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$1" "$2" "$3"; failures=$((failures + 1)); fi
}
branch_files() { git --git-dir="$work/images.git" ls-tree -r --name-only screenshots | tr '\n' ' '; }
commits() { git --git-dir="$work/images.git" rev-list --count screenshots; }
comment() { cat "$work/comments/$1".*; }

post 5
expect "no images: nothing pushed or posted" "$(git --git-dir="$work/images.git" branch --list | wc -l) $(wc -c < "$work/gh.log")" "0 0"

post 5 02-detail.png 01-home.png
commit=$(sed -n 's/^commit=//p' "$work/output")
expect "first run: branch has the images" "$(branch_files)" "pr-5/01-home.png pr-5/02-detail.png "
expect "first run: a comment is posted" "$(cat "$work/gh.log")" "POST 5"
expect "first run: comment body" "$(comment "5.pr-screenshots:screenshots")" "<!-- pr-screenshots:screenshots -->
### UI screenshots · run 42 · abcdef1

<img src=\"https://github.com/owner/repo/blob/$commit/pr-5/01-home.png?raw=true\" width=\"240\" alt=\"01-home\" title=\"01-home\">
<img src=\"https://github.com/owner/repo/blob/$commit/pr-5/02-detail.png?raw=true\" width=\"240\" alt=\"02-detail\" title=\"02-detail\">"

post 5 03-settings.png
expect "second run: the comment is updated, not duplicated" "$(cat "$work/gh.log")" "PATCH 100"
expect "second run: old images replaced" "$(branch_files)" "pr-5/03-settings.png "
expect "the branch stays one commit" "$(commits)" "1"

post 6 home.png
expect "another pull request keeps the first's images" "$(branch_files)" "pr-5/03-settings.png pr-6/home.png "
expect "another pull request gets its own comment" "$(cat "$work/gh.log")" "POST 6"

SET=tablet post 5 wide.png
expect "a second set: its own folder" "$(branch_files)" "pr-5-tablet/wide.png pr-5/03-settings.png pr-6/home.png "
expect "a second set: its own comment" "$(cat "$work/gh.log")" "POST 5"

if post "" a.png; then status=0; else status=$?; fi
expect "no pull request number fails" "$status $(grep -c 'No pull request number' "$work/run.log")" "1 1"

exit $failures
