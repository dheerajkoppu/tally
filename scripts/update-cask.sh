#!/bin/bash
# Points the Homebrew cask at the latest GitHub release, so `brew install --cask dheerajkoppu/tap/tally` gets it.
#   scripts/update-cask.sh
# Run it after `gh release create`: the version and checksum come from the published release, not the local build.
# TALLY_TAP names another tap repository, for forks.
set -euo pipefail
cd "$(dirname "$0")/.."

TAP="${TALLY_TAP:-dheerajkoppu/homebrew-tap}"
TAG="$(gh release view --json tagName --jq .tagName)"
VERSION="${TAG#v}"
DIGEST="$(gh release view "$TAG" --json assets --jq '.assets[] | select(.name == "Tally.zip") | .digest')"
SHA256="${DIGEST#sha256:}"
if [ "${#SHA256}" -ne 64 ]; then
    echo "Release $TAG has no Tally.zip with a SHA-256 digest." >&2
    exit 1
fi

CHECKOUT="$(mktemp -d -t tally-tap)"
trap 'rm -rf "$CHECKOUT"' EXIT
gh repo clone "$TAP" "$CHECKOUT" -- --quiet --depth 1
sed -i '' -E "s/^  version \".*\"$/  version \"$VERSION\"/; s/^  sha256 \".*\"$/  sha256 \"$SHA256\"/" "$CHECKOUT/Casks/tally.rb"
if git -C "$CHECKOUT" diff --quiet; then
    echo "The cask in $TAP is already at Tally $VERSION."
    exit 0
fi
git -C "$CHECKOUT" commit --quiet --all --message "tally $VERSION"
git -C "$CHECKOUT" push --quiet
echo "Updated the cask in $TAP to Tally $VERSION"
