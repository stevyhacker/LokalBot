#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
version="${1:?Usage: Scripts/release/prepare-release.sh VERSION}"
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo 'Commit the candidate first.' >&2; exit 1; }
sha="$(git rev-parse HEAD)"
remote_sha="$(git ls-remote origin refs/heads/master | cut -f1)"
export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
python3 Scripts/ci/release-candidate.py candidate
python3 Scripts/release/release-preflight.py --candidate --version "$version"
if [ "$sha" != "$remote_sha" ]; then
  python3 Scripts/ci/release-candidate.py ui-covered || {
    echo 'No UI run covers this commit, and master has moved, so one cannot be dispatched for it. Land a new candidate.' >&2
    exit 1
  }
  printf 'Master has moved past %s, so archive preparation cannot run on it, and the tag run will build the archive itself. Wait for the Build, Lint and XcodeGen push runs before tagging.\n' "$sha"
  exit 0
fi
gh workflow run release.yml --ref master --raw-field "version=$version"
if python3 Scripts/ci/release-candidate.py ui-covered; then
  printf 'Archive preparation dispatched for %s. Wait for it, and the Build, Lint and XcodeGen push runs, before tagging.\n' "$sha"
else
  gh workflow run ui-tests.yml --ref master --raw-field "candidate_sha=$sha"
  printf 'Archive preparation and UI Tests dispatched for %s. Wait for both, and the Build, Lint and XcodeGen push runs, before tagging.\n' "$sha"
fi
