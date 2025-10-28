#!/usr/bin/env bash
# Home OS - Build and Run Script
# Automates building the kernel and running it in QEMU

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$(dirname "$KERNEL_DIR")")"

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Home OS - Kernel Build & Run Tool   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

# Parse arguments
BUILD_MODE="debug"
RUN_MODE="qemu"
CLEAN=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --release)
            BUILD_MODE="release"
            shift
            ;;
        --release-safe)
            BUILD_MODE="release-safe"
            shift
            ;;
        --kvm)
            RUN_MODE="qemu-kvm"
            shift
            ;;
        --debug)
            RUN_MODE="qemu-debug"
            shift
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --release       Build in release mode (optimized)"
            echo "  --release-safe  Build in release-safe mode (optimized with safety)"
            echo "  --kvm           Run with KVM acceleration"
            echo "  --debug         Run with GDB support (starts paused)"
            echo "  --clean         Clean build artifacts before building"
            echo "  --help          Show this help message"
            echo ""
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check for required tools
echo -e "${BLUE}Checking dependencies...${NC}"

check_tool() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${RED}✗ $1 not found${NC}"
        echo -e "${YELLOW}Please install $1 to continue${NC}"
        return 1
    else
        echo -e "${GREEN}✓ $1${NC}"
        return 0
    fi
}

ALL_TOOLS_PRESENT=1
check_tool zig || ALL_TOOLS_PRESENT=0
check_tool grub-mkrescue || ALL_TOOLS_PRESENT=0
check_tool qemu-system-x86_64 || ALL_TOOLS_PRESENT=0

if [ $ALL_TOOLS_PRESENT -eq 0 ]; then
    echo ""
    echo -e "${RED}Missing required tools. Cannot continue.${NC}"
    exit 1
fi

echo ""

# Clean if requested
if [ $CLEAN -eq 1 ]; then
    echo -e "${YELLOW}Cleaning build artifacts...${NC}"
    cd "$KERNEL_DIR"
    zig build clean 2>/dev/null || true
    echo -e "${GREEN}✓ Clean complete${NC}"
    echo ""
fi

# Build kernel
echo -e "${BLUE}Building kernel (mode: $BUILD_MODE)...${NC}"
cd "$KERNEL_DIR"

BUILD_CMD="zig build"
if [ "$BUILD_MODE" == "release" ]; then
    BUILD_CMD="$BUILD_CMD -Doptimize=ReleaseFast"
elif [ "$BUILD_MODE" == "release-safe" ]; then
    BUILD_CMD="$BUILD_CMD -Doptimize=ReleaseSafe"
else
    BUILD_CMD="$BUILD_CMD -Doptimize=Debug"
fi

if ! $BUILD_CMD; then
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Kernel built successfully${NC}"
echo ""

# Create bootable ISO
echo -e "${BLUE}Creating bootable ISO...${NC}"
if ! zig build iso; then
    echo -e "${RED}✗ ISO creation failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ ISO created successfully${NC}"
echo ""

# Display kernel information
echo -e "${BLUE}Kernel Information:${NC}"
zig build info 2>/dev/null || true
echo ""

# Run in QEMU
echo -e "${BLUE}Starting QEMU ($RUN_MODE)...${NC}"

if [ "$RUN_MODE" == "qemu-debug" ]; then
    echo -e "${YELLOW}Kernel will start paused. Connect GDB to localhost:1234${NC}"
    echo -e "${YELLOW}In another terminal, run:${NC}"
    echo -e "${YELLOW}  gdb zig-out/bin/home-kernel.elf${NC}"
    echo -e "${YELLOW}  (gdb) target remote localhost:1234${NC}"
    echo -e "${YELLOW}  (gdb) continue${NC}"
    echo ""
fi

zig build "$RUN_MODE" || {
    echo -e "${RED}✗ QEMU failed to start${NC}"
    exit 1
}
