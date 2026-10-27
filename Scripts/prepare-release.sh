#!/bin/bash
# Explicitly overlap trusted master archive preparation with its push CI gates.
# This dispatch creates no tag and publishes no release.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?Usage: Scripts/prepare-release.sh VERSION}"
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo 'Commit the candidate first.' >&2; exit 1; }
sha="$(git rev-parse HEAD)"
remote_sha="$(git ls-remote origin refs/heads/master | cut -f1)"
[ "$sha" = "$remote_sha" ] || { echo 'Candidate must be the pushed master commit.' >&2; exit 1; }
python3 Scripts/release-preflight.py --candidate --version "$version"
gh workflow run release.yml --ref master --raw-field "version=$version"
# UI Tests no longer runs on every master push. The merged pull request's full
# run covers a candidate with its exact tree; otherwise validate this commit.
export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
if python3 Scripts/ci/release-candidate.py ui-covered; then
  printf 'Archive preparation dispatched for %s. Wait for it, and the Build, Lint and XcodeGen push runs, before tagging.\n' "$sha"
else
  gh workflow run ui-tests.yml --ref master --raw-field "candidate_sha=$sha"
  printf 'Archive preparation and UI Tests dispatched for %s. Wait for both, and the Build, Lint and XcodeGen push runs, before tagging.\n' "$sha"
fi
