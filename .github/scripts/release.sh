#!/usr/bin/env bash
# Publish / refresh the GitHub Release for the version in ./VERSION.
#
#   * No release for vX.Y yet           -> create tag + release (auto notes),
#                                          attach the 4 installer files.
#   * Release exists, installers differ -> replace the attached files with the
#                                          committed ones and move the tag to
#                                          this commit (so the source archive
#                                          matches too).
#   * Release exists, installers same   -> do nothing.
#
# Needs: git, gh (preinstalled on GitHub runners), GH_TOKEN with contents:write.
set -euo pipefail

VERSION_FILE="${VERSION_FILE:-VERSION}"
SHA="${GITHUB_SHA:-$(git rev-parse HEAD)}"
ASSETS=(
  install-local-search.sh
  install-local-search.bat
  full-dev-rig/local-search-rig.sh
  full-dev-rig/local-search-rig.bat
)

die() { echo "::error::$*" >&2; exit 1; }

[ -f "$VERSION_FILE" ] || die "$VERSION_FILE not found"
# Accept "1.4" or "v1.4", ignore whitespace / CRLF.
version="$(tr -d ' \t\r\n' < "$VERSION_FILE")"
version="${version#v}"
case "$version" in
  ""|*[!0-9.]*|.*|*.|*..*) die "$VERSION_FILE must hold a version like 1.4 (got '$version')" ;;
esac
tag="v$version"

for f in "${ASSETS[@]}"; do [ -f "$f" ] || die "missing installer file: $f"; done

if ! gh release view "$tag" >/dev/null 2>&1; then
  echo "No release for $tag yet -> creating it."
  gh release create "$tag" "${ASSETS[@]}" \
    --title "$tag" --target "$SHA" --generate-notes
  echo "Created release $tag."
  exit 0
fi

echo "Release $tag exists -> checking whether the installers changed."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
gh release download "$tag" --dir "$tmp" >/dev/null 2>&1 || true   # no assets yet is fine

changed=0
for f in "${ASSETS[@]}"; do
  if ! cmp -s "$f" "$tmp/$(basename "$f")"; then
    echo "  differs / missing on release: $(basename "$f")"
    changed=1
  fi
done

if [ "$changed" -eq 0 ]; then
  echo "Release $tag already has identical installers. Nothing to do."
  exit 0
fi

gh release upload "$tag" "${ASSETS[@]}" --clobber
echo "Replaced installers on release $tag."

# Keep the tag (and so the release's source archive) in step with the code.
if [ "$(git rev-parse "refs/tags/$tag^{commit}" 2>/dev/null || true)" != "$SHA" ]; then
  git tag -f "$tag" "$SHA"
  git push -f origin "refs/tags/$tag"
  echo "Moved tag $tag to ${SHA:0:7}."
fi
