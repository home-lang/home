#!/bin/bash
set -e

# Home Compiler - macOS DMG Builder
# A reusable script for building distributable DMG packages for Home applications
# Usage: ./build-macos-dmg.sh <source.home> <app-name> [version]

show_usage() {
    cat << EOF
🏠 Home Compiler - macOS DMG Builder

Usage: $0 <source.home> <app-name> [version] [options]

Arguments:
    source.home     Path to the main Home source file
    app-name        Name of the application (e.g., "MyApp")
    version         Version number (default: 1.0.0)

Options:
    --assets <dir>         Directory containing assets to bundle
    --resources <dirs>     Comma-separated list of resource directories
    --bundle-id <id>       Bundle identifier (default: com.homelang.<app-name>)
    --category <cat>       App category (default: public.app-category.developer-tools)
    --min-os <version>     Minimum macOS version (default: 10.15)
    --compiler <path>      Path to Home compiler (default: auto-detect)
    --output <path>        Output DMG path (default: ./<app-name>-<version>.dmg)
    --icon <path>          Path to .icns icon file
    --no-sign              Skip code signing
    --sign-id <id>         Code signing identity
    --help                 Show this help message

Examples:
    # Basic usage
    $0 main.home "MyApp" "1.0.0"

    # With assets and resources
    $0 game.home "Generals" "1.0.0" --assets assets --resources "audio,graphics,data"

    # With custom bundle ID and icon
    $0 app.home "MyApp" "2.0.0" --bundle-id com.mycompany.app --icon icon.icns

    # Game with large assets
    $0 generals.home "Generals" "1.0.0" \\
        --assets assets \\
        --resources "audio,graphics,game" \\
        --bundle-id com.ea.generals \\
        --category public.app-category.strategy-games

Environment Variables:
    HOME_COMPILER          Path to Home compiler binary
    DMG_BACKGROUND_IMAGE   Custom DMG background image

EOF
    exit 0
}

# Parse arguments
SOURCE_FILE=""
APP_NAME=""
VERSION="1.0.0"
ASSETS_DIR=""
RESOURCES_DIRS=""
BUNDLE_ID=""
APP_CATEGORY="public.app-category.developer-tools"
MIN_MACOS="10.15"
HOME_COMPILER="${HOME_COMPILER:-}"
OUTPUT_DMG=""
ICON_FILE=""
SIGN_APP=true
SIGN_IDENTITY=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_usage
            ;;
        --assets)
            ASSETS_DIR="$2"
            shift 2
            ;;
        --resources)
            RESOURCES_DIRS="$2"
            shift 2
            ;;
        --bundle-id)
            BUNDLE_ID="$2"
            shift 2
            ;;
        --category)
            APP_CATEGORY="$2"
            shift 2
            ;;
        --min-os)
            MIN_MACOS="$2"
            shift 2
            ;;
        --compiler)
            HOME_COMPILER="$2"
            shift 2
            ;;
        --output)
            OUTPUT_DMG="$2"
            shift 2
            ;;
        --icon)
            ICON_FILE="$2"
            shift 2
            ;;
        --no-sign)
            SIGN_APP=false
            shift
            ;;
        --sign-id)
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        -*)
            echo "❌ Unknown option: $1"
            show_usage
            ;;
        *)
            if [ -z "$SOURCE_FILE" ]; then
                SOURCE_FILE="$1"
            elif [ -z "$APP_NAME" ]; then
                APP_NAME="$1"
            elif [ -z "$VERSION" ] || [ "$VERSION" = "1.0.0" ]; then
                VERSION="$1"
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ -z "$SOURCE_FILE" ] || [ -z "$APP_NAME" ]; then
    echo "❌ Error: Missing required arguments"
    echo ""
    show_usage
fi

if [ ! -f "$SOURCE_FILE" ]; then
    echo "❌ Error: Source file not found: $SOURCE_FILE"
    exit 1
fi

# Auto-detect Home compiler if not specified
if [ -z "$HOME_COMPILER" ]; then
    # Try common locations
    for location in \
        "$(dirname "$0")/../zig-out/bin/home" \
        "/Users/$USER/Code/home/zig-out/bin/home" \
        "$(which home)" \
        "./zig-out/bin/home"
    do
        if [ -f "$location" ]; then
            HOME_COMPILER="$location"
            break
        fi
    done
fi

if [ -z "$HOME_COMPILER" ] || [ ! -f "$HOME_COMPILER" ]; then
    echo "❌ Error: Home compiler not found"
    echo "   Please specify with --compiler or set HOME_COMPILER environment variable"
    exit 1
fi

# Set default bundle ID if not specified
if [ -z "$BUNDLE_ID" ]; then
    BUNDLE_ID="com.homelang.$(echo "$APP_NAME" | tr '[:upper:] ' '[:lower:]-')"
fi

# Set default output DMG if not specified
if [ -z "$OUTPUT_DMG" ]; then
    OUTPUT_DMG="${APP_NAME}-${VERSION}.dmg"
fi

# Configuration
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_DIR="${BUILD_DIR}/dmg"

echo "🏠 Home Compiler - macOS DMG Builder"
echo "===================================="
echo ""
echo "Configuration:"
echo "  Source:      $SOURCE_FILE"
echo "  App Name:    $APP_NAME"
echo "  Version:     $VERSION"
echo "  Bundle ID:   $BUNDLE_ID"
echo "  Compiler:    $HOME_COMPILER"
echo "  Output DMG:  $OUTPUT_DMG"
if [ -n "$ASSETS_DIR" ]; then
    echo "  Assets:      $ASSETS_DIR"
fi
if [ -n "$RESOURCES_DIRS" ]; then
    echo "  Resources:   $RESOURCES_DIRS"
fi
echo ""

# Clean previous builds
echo "🧹 Cleaning previous builds..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$DMG_DIR"

# Compile the application
echo "🔨 Compiling $APP_NAME..."
"$HOME_COMPILER" build "$SOURCE_FILE" -o "${BUILD_DIR}/${APP_NAME}"
chmod +x "${BUILD_DIR}/${APP_NAME}"

# Create macOS app bundle structure
echo "📦 Creating macOS app bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"

# Copy executable
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Copy icon if provided
if [ -n "$ICON_FILE" ] && [ -f "$ICON_FILE" ]; then
    echo "🎨 Adding application icon..."
    cp "$ICON_FILE" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

# Copy assets if provided
if [ -n "$ASSETS_DIR" ] && [ -d "$ASSETS_DIR" ]; then
    echo "📂 Copying assets directory..."
    ASSETS_SIZE=$(du -sh "$ASSETS_DIR" | cut -f1)
    echo "   Assets size: $ASSETS_SIZE"
    cp -R "$ASSETS_DIR" "${APP_BUNDLE}/Contents/Resources/"
fi

# Copy additional resources
if [ -n "$RESOURCES_DIRS" ]; then
    IFS=',' read -ra DIRS <<< "$RESOURCES_DIRS"
    for dir in "${DIRS[@]}"; do
        dir=$(echo "$dir" | xargs)  # Trim whitespace
        if [ -d "$dir" ]; then
            echo "📂 Copying resource directory: $dir"
            cp -R "$dir" "${APP_BUNDLE}/Contents/Resources/"
        else
            echo "⚠️  Warning: Resource directory not found: $dir"
        fi
    done
fi

# Create Info.plist
echo "📝 Creating Info.plist..."
ICON_KEY=""
if [ -n "$ICON_FILE" ]; then
    ICON_KEY="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
fi

cat > "${APP_BUNDLE}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>NSHumanReadableCopyright</key>
    <string>Built with Home Programming Language</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>${APP_CATEGORY}</string>
${ICON_KEY}
</dict>
</plist>
EOF

# Create PkgInfo
echo "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# Code signing
if [ "$SIGN_APP" = true ]; then
    if [ -n "$SIGN_IDENTITY" ]; then
        echo "🔐 Signing application..."
        codesign --force --deep --sign "$SIGN_IDENTITY" "${APP_BUNDLE}"
    else
        # Try to sign with ad-hoc signature
        echo "🔐 Adding ad-hoc signature..."
        codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || echo "⚠️  Warning: Could not sign app bundle"
    fi
fi

# Copy app bundle to DMG staging directory
cp -R "${APP_BUNDLE}" "${DMG_DIR}/"

# Create a symbolic link to /Applications in the DMG
ln -s /Applications "${DMG_DIR}/Applications"

# Create README for the DMG
cat > "${DMG_DIR}/README.txt" << EOF
${APP_NAME} v${VERSION}
========================================

Installation:
1. Drag "${APP_NAME}.app" to the Applications folder
2. Launch ${APP_NAME} from your Applications folder
3. Enjoy!

About:
This application was built with the Home programming language.
Home: The speed of Zig. The safety of Rust. The joy of TypeScript.

Learn more: https://github.com/home-lang

Built: $(date)
Compiler: Home $(${HOME_COMPILER} --version 2>/dev/null || echo "latest")
EOF

# Get the size of the content
echo "📏 Calculating DMG size..."
DMG_SIZE=$(du -sm "${DMG_DIR}" | cut -f1)
DMG_SIZE=$((DMG_SIZE + 100))  # Add 100MB buffer

# Create temporary DMG
echo "💿 Creating DMG image (${DMG_SIZE}MB)..."
TEMP_DMG="${BUILD_DIR}/$(basename "$OUTPUT_DMG" .dmg)-temp.dmg"

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_DIR}" \
    -ov \
    -format UDRW \
    -size ${DMG_SIZE}m \
    "$TEMP_DMG"

# Mount the temporary DMG
echo "🔧 Mounting DMG for customization..."
MOUNT_DIR="/Volumes/${APP_NAME}"
hdiutil attach "$TEMP_DMG" -mountpoint "$MOUNT_DIR"

# Set DMG window properties
echo "🎨 Customizing DMG appearance..."
sleep 2

# Use AppleScript to set window properties
osascript << EOF || true
tell application "Finder"
    tell disk "${APP_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 700, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set position of item "${APP_NAME}.app" of container window to {150, 200}
        set position of item "Applications" of container window to {450, 200}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
EOF

sync
sleep 2

# Unmount the temporary DMG
echo "💾 Finalizing DMG..."
hdiutil detach "$MOUNT_DIR" || true
sleep 2

# Convert to compressed, read-only DMG
hdiutil convert "$TEMP_DMG" \
    -format UDZO \
    -o "$OUTPUT_DMG" \
    -ov

# Clean up
rm -f "$TEMP_DMG"

# Get final DMG size
DMG_FILE_SIZE=$(du -h "$OUTPUT_DMG" | cut -f1)
DMG_FILE_PATH=$(realpath "$OUTPUT_DMG")

echo ""
echo "✅ Build complete!"
echo "===================================="
echo "📦 DMG:          $DMG_FILE_PATH"
echo "📊 Size:         $DMG_FILE_SIZE"
echo "🏗️  App Bundle:   ${APP_BUNDLE}"
echo ""
echo "Next steps:"
echo "  • Test:       open '$OUTPUT_DMG'"
echo "  • Distribute: Share '$OUTPUT_DMG' with users"
echo "  • Verify:     spctl -a -v '${APP_BUNDLE}'"
echo ""
echo "Users can install by dragging ${APP_NAME}.app to Applications!"
