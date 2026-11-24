# Release on merge

A GitHub Action that turns every merge to `main` into a release. It tags the merge with the next version, then creates a GitHub release titled with the pull request's title, with generated notes. Your own jobs then build and attach whatever the release ships: binaries, images, plugins.

```
v0.3.2 — Fix History times

Silo plugin: unchanged since v0.3.1.
Docker: ghcr.io/owner/image:latest

What's Changed
* Fix History times by @owner in #21
```

No one types a tag. The version goes up by one patch number per merge. Put **`[minor]`** or **`[major]`** in a pull request's title to bump that part instead; the keyword is removed from the release title.

## Quick start

1. Copy [`examples/release-binaries-only.yml`](examples/release-binaries-only.yml) to `.github/workflows/release.yml` and change its build step.
2. Merge it, then run **Actions → Release → Run workflow** once to check the setup.

For a repository that already has separate build workflows, such as binaries plus a container image, start from [`examples/release-go-docker.yml`](examples/release-go-docker.yml) instead.

## Inputs and outputs

| Input | Default | What it does |
| --- | --- | --- |
| `components` | none | Lines of `path: Label`. For each, the notes say whether that path changed since the previous release. Useful when users install a part separately, such as a plugin, so they know whether to update it. |
| `extra-notes` | none | Markdown added to the top of the notes, such as a `docker pull` line |
| `version-files` | none | JSON files, one per line, whose top-level `version` is set to the new version, such as a plugin's `manifest.json`. See [Version files](#version-files). |
| `title` | the merged PR's title | The release title, and the text searched for `[minor]` or `[major]`. Pass the PR's title for a dry run on an open PR. |
| `dry-run` | `false` | `true` works out the version and changes nothing. See [Preview builds](#preview-builds). |
| `token` | `github.token` | Pushes the tag and creates the release; needs `contents: write` |

| Output | Value |
| --- | --- |
| `released` | `true` when a release was made; `false` when the commit already had one |
| `tag` | The new tag, such as `v0.3.2`. Empty when nothing was released. In a dry run, the tag the commit would get, or already has |
| `version` | The tag without its `v`, such as `0.3.2` |
| `previous` | The previous release's tag. Empty for the first release |

## Setup checklist

The full list a person or an agent needs to add this to a repository:

1. **Release workflow.** Add `.github/workflows/release.yml` from one of the examples. It needs:
   - **Triggers:** `push` to `main`, plus `workflow_dispatch` so releases can be run by hand.
   - **`paths-ignore`** for changes that shouldn't make a release, such as `**.md`, `docs/**` and `.github/**`.
   - **Permissions:** `contents: write`, plus `packages: write` if it publishes images.
   - **Concurrency:** `concurrency: { group: release, cancel-in-progress: false }`, so two quick merges are numbered one after the other.
2. **Full history.** Check out with `fetch-depth: 0` before the action. With a shallow checkout the earlier tags are invisible, so the action stops with an error.
3. **Builds run from the release workflow, after the action.** Gate them on `needs.<job>.outputs.tag != ''` (or `released == 'true'`), and check out the tag before building. A tag pushed with the workflow's own token **does not start other workflows**, so a separate workflow listening for `push: tags` never runs. Either build in the same workflow, as in `release-binaries-only.yml`, or make the existing build workflows callable (below).
4. **Version anything that embeds one.** If a build bakes a version into its output, such as a manifest or `-ldflags`, set it from the tag (`${TAG#v}`) so the shipped file reports the release's version.
5. **Starting version.** A repository with no `vX.Y.Z` tags starts at `v0.0.1`. To start elsewhere, push a baseline tag on the current `main` first, for example `git tag v0.9.0 && git push origin v0.9.0`, so the next merge becomes `v0.9.1`. Or use `[minor]` or `[major]` in the first pull request's title.
6. **Check it.** Run **Actions → Release → Run workflow** on `main`. It should make one release with your builds attached. A second run on the same commit does nothing.

### Turn a build workflow into a callable one

Add a `workflow_call` trigger with a `tag` input, and build from that tag. Keep the existing triggers so manual runs and hand-pushed tags still work:

```yaml
on:
  push:
    tags: ["v*"]
  workflow_call:
    inputs:
      tag:
        type: string
        required: true

jobs:
  build:
    runs-on: ubuntu-latest
    env:
      TAG: ${{ inputs.tag || github.ref_name }}
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ env.TAG }}
```

When it's called, `github.ref` is `main`, not the tag, so take versions from `TAG`. For a container image, for example:

```yaml
      - uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository_owner }}/my-image
          flavor: latest=false
          tags: |
            type=raw,value=latest,enable=${{ !contains(env.TAG, '-') }}
            type=semver,pattern={{version}},value=${{ env.TAG }}
            type=semver,pattern={{major}}.{{minor}},value=${{ env.TAG }}
```

## Version files

Some builds read their version from a file in the repository rather than from the tag, such as a plugin catalog reading `manifest.json` at the release. List those files in `version-files`. The action then:

1. sets each file's top-level `version` field to the new version;
2. commits that on top of the merge, as `Release vX.Y.Z`;
3. tags that commit, not the merge.

`main` itself isn't changed. The commit is only reachable through the tag. Later steps in the same job are left on the tagged commit, and builds that check out the tag get the stamped files.

```yaml
      - id: release
        uses: neilmc78/release-on-merge@v1
        with:
          version-files: manifest.json
```

Re-running on the same merge is still safe: the action recognises its own `Release vX.Y.Z` commit and doesn't release again.

## Preview builds

To give a pull request's build the version it will become, such as `0.3.4-dev.17`, run the action as a dry run. It needs no write permissions.

```yaml
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: next
        uses: neilmc78/release-on-merge@v1
        with:
          dry-run: true
          title: ${{ github.event.pull_request.title }}   # so [minor] or [major] in it counts
      - run: ./build --version "${{ steps.next.outputs.version }}-dev.${{ github.run_number }}"
```

On a commit that's already released, a dry run reports that release's tag.

## PR screenshots

A second action in this repository, `neilmc78/release-on-merge/pr-screenshots@v1`, shows a pull request's screenshots inline in one comment that's updated on every run. GitHub can't attach images to comments through its API, so the images are pushed to a branch (`screenshots` by default) and linked from the comment. The branch is rewritten as one commit holding the latest images for each pull request, so it doesn't grow.

Run it in its own job, after the job that makes the screenshots, and give it only the image files. It never checks out or runs the pull request's code, so that job can safely have write permissions:

```yaml
  screenshots:
    needs: build
    if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    concurrency: screenshots-branch   # one writer at a time
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: screenshots
          path: shots
      - uses: neilmc78/release-on-merge/pr-screenshots@v1
        with:
          path: shots
```

| Input | Default | What it does |
| --- | --- | --- |
| `path` | (required) | Directory with the images (`.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`). Nothing is posted when it's empty. |
| `branch` | `screenshots` | Branch the images are published to |
| `heading` | `UI screenshots` | Comment heading; the run number and commit are added |
| `width` | `240` | Image width in the comment, in pixels |
| `id` | `screenshots` | Names the set, so a pull request can have several comments, such as `phone` and `tablet` |
| `pull-request`, `sha` | from the event | For use outside `pull_request` events |

Pull requests from forks get no write token, so skip the job for them, as in the `if:` above.

## How versions are worked out

- **Starting point:** the highest `vX.Y.Z` tag. Pre-releases (`v1.0.0-rc1`) and malformed tags (`v.0.2.0`) are ignored, and `v0.10.0` sorts above `v0.9.0`.
- **Bump size:** set by `[major]` or `[minor]` anywhere in the merge commit's message. GitHub puts the pull request's title there for merge commits, and squash merges use it as the first line.
- **Release title:** for a merge commit, its pull request title; otherwise the commit's first line.
- **No duplicates:** a commit that already has a `vX.Y.Z` tag isn't released again, so reruns are safe.

## Limitations

- **Protected tags:** if branch protection or a ruleset stops `github.token` creating `v*` tags, pass a personal access token or GitHub App token as `token`.
- **Rebase merges:** the title comes from the last commit's first line, because rebase merges don't record the pull request.

## Developing this action

- **Tests:** `bash tests/next-version.test.sh`, `bash tests/action.test.sh` and `bash tests/pr-screenshots.test.sh` (the last two need Python with PyYAML). CI runs them, shellchecks the scripts and both actions' steps, and runs `actionlint` on the workflows and examples.
- **Releases:** this repository releases itself with itself. After each release, the `v1` tag moves to it, so `@v1` users get fixes. Give a breaking change `[major]` in its title, which starts `v2`.
