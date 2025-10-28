#!/usr/bin/env bash
# Version Validation Script for Home
# Checks that all package versions match the root version

set -euo pipefail

# Get the root directory
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_TOML="${ROOT_DIR}/ion.toml"

# Extract version from root ion.toml
ROOT_VERSION=$(grep '^version = ' "$ROOT_TOML" | head -1 | sed 's/version = "\(.*\)"/\1/')

echo "Root version: ${ROOT_VERSION}"
echo ""

# Find all package ion.toml files and check versions
MISMATCHED=0
TOTAL=0

for toml_file in "$ROOT_DIR"/packages/*/ion.toml; do
    if [[ ! -f "$toml_file" ]]; then
        continue
    fi

    TOTAL=$((TOTAL + 1))

    # Extract package name and version
    PACKAGE_NAME=$(grep '^name = ' "$toml_file" | head -1 | sed 's/name = "\(.*\)"/\1/')
    PACKAGE_VERSION=$(grep '^version = ' "$toml_file" | head -1 | sed 's/version = "\(.*\)"/\1/')

    if [[ "$PACKAGE_VERSION" != "$ROOT_VERSION" ]]; then
        echo "MISMATCH: ${PACKAGE_NAME} is at ${PACKAGE_VERSION}, expected ${ROOT_VERSION}"
        MISMATCHED=$((MISMATCHED + 1))
    fi
done

echo "Checked ${TOTAL} packages"

if [[ $MISMATCHED -gt 0 ]]; then
    echo "ERROR: ${MISMATCHED} package(s) have mismatched versions"
    exit 1
else
    echo "SUCCESS: All packages are at version ${ROOT_VERSION}"
    exit 0
fi
