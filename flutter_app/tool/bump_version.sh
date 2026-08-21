#!/usr/bin/env bash
# bump_version.sh — increment the build number (or the semver) in both
# pubspec.yaml and measurement_basis.dart in one step.
#
# Usage:
#   ./tool/bump_version.sh              # bump build number only  (0.1.0+1 → 0.1.0+2)
#   ./tool/bump_version.sh 0.2.0        # set semver AND bump build number (→ 0.2.0+3)
#   ./tool/bump_version.sh 0.2.0 10     # set both explicitly      (→ 0.2.0+10)
#
# Run from the flutter_app/ directory (or the script locates it automatically).

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate the two source-of-truth files
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLUTTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PUBSPEC="$FLUTTER_ROOT/pubspec.yaml"
BASIS="$FLUTTER_ROOT/lib/src/analysis/measurement_basis.dart"

for f in "$PUBSPEC" "$BASIS"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: cannot find $f" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Read the current version
# ---------------------------------------------------------------------------
CURRENT=$(grep -E '^version:' "$PUBSPEC" | sed 's/version: *//')
CURRENT_SEMVER="${CURRENT%%+*}"
CURRENT_BUILD="${CURRENT##*+}"

echo "Current version: $CURRENT  (semver=$CURRENT_SEMVER  build=$CURRENT_BUILD)"

# ---------------------------------------------------------------------------
# Compute the new version
# ---------------------------------------------------------------------------
NEW_SEMVER="${1:-$CURRENT_SEMVER}"
if [[ -n "${2:-}" ]]; then
  NEW_BUILD="$2"
else
  NEW_BUILD=$((CURRENT_BUILD + 1))
fi
NEW_VERSION="$NEW_SEMVER+$NEW_BUILD"

if [[ "$NEW_VERSION" == "$CURRENT" ]]; then
  echo "Nothing to do — version is already $CURRENT."
  exit 0
fi

echo "     New version: $NEW_VERSION  (semver=$NEW_SEMVER  build=$NEW_BUILD)"

# ---------------------------------------------------------------------------
# Write both files
# ---------------------------------------------------------------------------
# pubspec.yaml
sed -i "s/^version: .*/version: $NEW_VERSION/" "$PUBSPEC"

# measurement_basis.dart — the mirrored literal
sed -i "s/^const String appVersion = '.*';/const String appVersion = '$NEW_VERSION';/" "$BASIS"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
PUB_CHECK=$(grep -E '^version:' "$PUBSPEC" | sed 's/version: *//')
BASIS_CHECK=$(grep -oP "(?<=appVersion = ').*(?=')" "$BASIS")

if [[ "$PUB_CHECK" != "$NEW_VERSION" || "$BASIS_CHECK" != "$NEW_VERSION" ]]; then
  echo "ERROR: files out of sync after write!" >&2
  echo "  pubspec.yaml:          $PUB_CHECK" >&2
  echo "  measurement_basis.dart: $BASIS_CHECK" >&2
  exit 1
fi

echo ""
echo "✓ pubspec.yaml           → $PUB_CHECK"
echo "✓ measurement_basis.dart → $BASIS_CHECK"
