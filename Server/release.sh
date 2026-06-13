#!/usr/bin/env bash
# Build kokoro-server release assets and upload them to a GitHub Release.
#
# Usage:
#   ./release.sh [--dry-run] <tag>
#
#   tag        GitHub release tag to upload to. Created (pointing at main)
#              if it doesn't exist; existing assets are replaced if it does.
#   --dry-run  build and stage assets, but skip tagging and uploading
#
# Prefer non-semver tags (e.g. server-v0.1.0): pure semver tags are offered
# by SwiftPM as package versions, and this package must be consumed by
# branch — see Server/README.md.
set -euo pipefail
cd "$(dirname "$0")"

DRY_RUN=0
TAG=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -*)
      echo "unknown flag: $arg" >&2
      exit 1
      ;;
    *) TAG="$arg" ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "usage: ./release.sh [--dry-run] <tag>" >&2
  exit 1
fi
if [[ "$TAG" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "warning: '$TAG' parses as semver — SwiftPM will offer it as a package version," >&2
  echo "warning: but this package only resolves by branch. Consider 'server-$TAG'." >&2
fi

ARCH=$(uname -m)
if [[ "$ARCH" != "arm64" ]]; then
  echo "MLX requires Apple Silicon; refusing to build on $ARCH" >&2
  exit 1
fi

REPO=$(git remote get-url origin | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')

echo "==> building assets for $TAG (repo: $REPO)"
make metallib
swift build -c release --product KokoroServer \
  -Xlinker -sectcreate -Xlinker __DATA -Xlinker __mlx_metallib \
  -Xlinker .build/release/mlx.metallib

# The published binary must be self-contained: verify the kernels section.
if ! otool -l .build/release/KokoroServer | grep -q __mlx_metallib; then
  echo "embedded metallib section missing from the binary" >&2
  exit 1
fi

# Stable asset name (releases are tag-scoped) so the
# releases/latest/download URL never changes.
NAME="kokoro-server-macos-arm64"
BIN="dist/$NAME"
mkdir -p dist
cp .build/release/KokoroServer "$BIN"
shasum -a 256 "$BIN" | awk '{ print $1 }' > "$BIN.sha256"

echo "==> staged assets:"
ls -lh "$BIN" "$BIN.sha256"
echo "    sha256: $(cat "$BIN.sha256")"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> dry run: skipping upload of $TAG to $REPO"
  exit 0
fi

if gh release view "$TAG" --repo "$REPO" > /dev/null 2>&1; then
  echo "==> uploading to existing release $TAG"
  gh release upload "$TAG" "$BIN" "$BIN.sha256" --clobber --repo "$REPO"
else
  # Creating a release mints the tag — make sure it lands on a published commit.
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "working tree is dirty; commit and push before creating a new release" >&2
    exit 1
  fi
  git fetch -q origin
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    echo "HEAD is not origin/main; push before creating a new release" >&2
    exit 1
  fi
  echo "==> creating release $TAG"
  gh release create "$TAG" "$BIN" "$BIN.sha256" \
    --repo "$REPO" \
    --target main \
    --generate-notes
fi

echo "==> done: https://github.com/$REPO/releases/tag/$TAG"
