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
| `token` | `github.token` | Pushes the tag and creates the release; needs `contents: write` |

| Output | Value |
| --- | --- |
| `released` | `true` when a release was made; `false` when the commit already had one |
| `tag` | The new tag, such as `v0.3.2`. Empty when nothing was released |
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

## How versions are worked out

- **Starting point:** the highest `vX.Y.Z` tag. Pre-releases (`v1.0.0-rc1`) and malformed tags (`v.0.2.0`) are ignored, and `v0.10.0` sorts above `v0.9.0`.
- **Bump size:** set by `[major]` or `[minor]` anywhere in the merge commit's message. GitHub puts the pull request's title there for merge commits, and squash merges use it as the first line.
- **Release title:** for a merge commit, its pull request title; otherwise the commit's first line.
- **No duplicates:** a commit that already has a `vX.Y.Z` tag isn't released again, so reruns are safe.

## Limitations

- **Protected tags:** if branch protection or a ruleset stops `github.token` creating `v*` tags, pass a personal access token or GitHub App token as `token`.
- **Rebase merges:** the title comes from the last commit's first line, because rebase merges don't record the pull request.

## Developing this action

- **Tests:** `bash tests/next-version.test.sh` and `bash tests/action.test.sh` (needs Python with PyYAML). CI runs both, plus `actionlint` on the workflows and examples.
- **Releases:** this repository releases itself with itself. After each release, the `v1` tag moves to it, so `@v1` users get fixes. Give a breaking change `[major]` in its title, which starts `v2`.
