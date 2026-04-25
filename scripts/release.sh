#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"

if [ -z "$VERSION" ]; then
  echo "Usage: ./scripts/release.sh <version>"
  echo "Example: ./scripts/release.sh 0.0.1"
  exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be semver format (e.g. 0.0.1), got '$VERSION'"
  exit 1
fi

TAG="v${VERSION}"

if git tag -l "$TAG" | grep -q "$TAG"; then
  echo "Error: tag $TAG already exists"
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Error: working tree has uncommitted changes, please commit or stash first"
  exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
  echo "Warning: you are on branch '$BRANCH', not 'main'"
  read -p "Continue anyway? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

echo "--- Updating version to $VERSION ---"

sed -i '' "s/\"version\": \"[0-9.]*\"/\"version\": \"$VERSION\"/" package.json
sed -i '' "s/\"version\": \"[0-9.]*\"/\"version\": \"$VERSION\"/" src-tauri/tauri.conf.json
sed -i '' "s/^version = \"[0-9.]*\"/version = \"$VERSION\"/" src-tauri/Cargo.toml

echo "package.json:        $(grep '"version"' package.json)"
echo "tauri.conf.json:     $(grep '"version"' src-tauri/tauri.conf.json)"
echo "Cargo.toml:          $(grep '^version' src-tauri/Cargo.toml)"

echo ""
echo "--- Committing ---"
git add package.json src-tauri/tauri.conf.json src-tauri/Cargo.toml
git commit -m "chore: release $TAG"

echo "--- Creating tag $TAG ---"
git tag -a "$TAG" -m "release $TAG"

echo ""
echo "--- Done ---"
echo "To push and trigger CI build:"
echo "  git push origin main && git push origin $TAG"
