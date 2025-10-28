#!/usr/bin/env bash
# Version Sync Script for Home
# Synchronizes version numbers across all package ion.toml files

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the root directory
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_TOML="${ROOT_DIR}/ion.toml"

echo -e "${BLUE}Home Version Sync Script${NC}"
echo "========================"
echo ""

# Check if root ion.toml exists
if [[ ! -f "$ROOT_TOML" ]]; then
    echo -e "${RED}Error: Root ion.toml not found at ${ROOT_TOML}${NC}"
    exit 1
fi

# Extract version from root ion.toml
ROOT_VERSION=$(grep '^version = ' "$ROOT_TOML" | head -1 | sed 's/version = "\(.*\)"/\1/')

if [[ -z "$ROOT_VERSION" ]]; then
    echo -e "${RED}Error: Could not extract version from root ion.toml${NC}"
    exit 1
fi

echo -e "${GREEN}Root version:${NC} ${ROOT_VERSION}"
echo ""

# Find all package ion.toml files
PACKAGE_TOMLS=$(find "$ROOT_DIR/packages" -name "ion.toml" -type f 2>/dev/null)
PACKAGE_COUNT=$(echo "$PACKAGE_TOMLS" | wc -l | tr -d ' ')

if [[ $PACKAGE_COUNT -eq 0 ]]; then
    echo -e "${YELLOW}Warning: No package ion.toml files found${NC}"
    exit 0
fi

echo -e "${BLUE}Found ${PACKAGE_COUNT} package(s) to sync${NC}"
echo ""

# Track statistics
UPDATED=0
SKIPPED=0
ERRORS=0

# Process each package
for toml_file in $ROOT_DIR/packages/*/ion.toml; do
    if [[ ! -f "$toml_file" ]]; then
        continue
    fi

    # Extract package name
    PACKAGE_NAME=$(grep '^name = ' "$toml_file" | head -1 | sed 's/name = "\(.*\)"/\1/')

    # Extract current version
    CURRENT_VERSION=$(grep '^version = ' "$toml_file" | head -1 | sed 's/version = "\(.*\)"/\1/')

    if [[ -z "$CURRENT_VERSION" ]]; then
        echo -e "  ${RED}✗${NC} ${PACKAGE_NAME}: Could not extract version"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # Check if version needs updating
    if [[ "$CURRENT_VERSION" == "$ROOT_VERSION" ]]; then
        echo -e "  ${GREEN}✓${NC} ${PACKAGE_NAME}: Already at ${ROOT_VERSION}"
        SKIPPED=$((SKIPPED + 1))
    else
        # Update version using sed
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS requires empty string for -i
            sed -i '' "s/^version = \".*\"/version = \"${ROOT_VERSION}\"/" "$toml_file"
        else
            # Linux sed
            sed -i "s/^version = \".*\"/version = \"${ROOT_VERSION}\"/" "$toml_file"
        fi

        # Verify update
        NEW_VERSION=$(grep '^version = ' "$toml_file" | head -1 | sed 's/version = "\(.*\)"/\1/')

        if [[ "$NEW_VERSION" == "$ROOT_VERSION" ]]; then
            echo -e "  ${YELLOW}↑${NC} ${PACKAGE_NAME}: ${CURRENT_VERSION} → ${ROOT_VERSION}"
            UPDATED=$((UPDATED + 1))
        else
            echo -e "  ${RED}✗${NC} ${PACKAGE_NAME}: Update failed"
            ERRORS=$((ERRORS + 1))
        fi
    fi
done

echo ""
echo "========================"
echo -e "${BLUE}Summary:${NC}"
echo -e "  ${GREEN}Updated:${NC}  ${UPDATED}"
echo -e "  ${GREEN}Skipped:${NC}  ${SKIPPED}"
if [[ $ERRORS -gt 0 ]]; then
    echo -e "  ${RED}Errors:${NC}   ${ERRORS}"
    exit 1
fi

echo ""
echo -e "${GREEN}✓ All packages synced to version ${ROOT_VERSION}${NC}"
