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
swift build -c release --product KokoroServer

# Asset name embeds the tag, minus a redundant server prefix
# (tag server-v0.1.0 -> kokoro-server-v0.1.0-macos-arm64).
BASE="${TAG#kokoro-server-}"
BASE="${BASE#server-}"
NAME="kokoro-server-${BASE//\//-}-macos-arm64"
STAGE="dist/$NAME"
TARBALL="dist/$NAME.tar.gz"
rm -rf "$STAGE" "$TARBALL"
mkdir -p "$STAGE"
cp .build/release/KokoroServer "$STAGE/kokoro-server"
cp .build/release/mlx.metallib "$STAGE/mlx.metallib"
cp README.md "$STAGE/README.md"
tar -czf "$TARBALL" -C dist "$NAME"
shasum -a 256 "$TARBALL" | awk '{ print $1 }' > "$TARBALL.sha256"

echo "==> staged assets:"
ls -lh "$TARBALL" "$TARBALL.sha256"
echo "    sha256: $(cat "$TARBALL.sha256")"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> dry run: skipping upload of $TAG to $REPO"
  exit 0
fi

if gh release view "$TAG" --repo "$REPO" > /dev/null 2>&1; then
  echo "==> uploading to existing release $TAG"
  gh release upload "$TAG" "$TARBALL" "$TARBALL.sha256" --clobber --repo "$REPO"
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
  gh release create "$TAG" "$TARBALL" "$TARBALL.sha256" \
    --repo "$REPO" \
    --target main \
    --generate-notes
fi

echo "==> done: https://github.com/$REPO/releases/tag/$TAG"
