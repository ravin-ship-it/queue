#!/usr/bin/env bash
# ==============================================================================
# Queue (q) - Smart Minimal Bootstrap & Environment-Aware Setup Script
# Works via 1-Line Curl, Wget, or Local Execution:
#   curl -fsSL https://raw.githubusercontent.com/ravin-ship-it/queue/main/setup.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/ravin-ship-it/queue/main/setup.sh | bash -s -- --hybrid
# ==============================================================================

set -e

# Terminal Colors
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
PINK='\033[38;5;198m'
PURPLE='\033[1;38;5;171m'
GRAY='\033[0;90m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

# If running inside full repository clone, delegate directly to local install.sh
if [ -n "$SCRIPT_DIR" ] && [ "$SCRIPT_DIR" != "$HOME/.local/bin/mpv" ] && [ -f "$SCRIPT_DIR/install.sh" ] && [ -d "$SCRIPT_DIR/q_modules" ] && [ -f "$SCRIPT_DIR/q" ]; then
    echo -e "${CYAN}🚀 Local repository detected. Launching local install engine...${NC}"
    exec bash "$SCRIPT_DIR/install.sh" "$@"
fi

# Detect Environment
IS_WSL=false
IS_MACOS=false
IS_ANDROID=false
IS_LINUX=false

if [[ "$OSTYPE" == "darwin"* ]] || [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    IS_MACOS=true
    ENV_NAME="macOS (Darwin)"
elif [ -n "$PREFIX" ] && [[ "$PREFIX" == *"com.termux"* ]]; then
    IS_ANDROID=true
    ENV_NAME="Android (Termux)"
elif grep -qi "microsoft" /proc/version 2>/dev/null || [ -d "/usr/lib/wsl" ] || [ -d "/mnt/wslg" ]; then
    IS_WSL=true
    IS_LINUX=true
    ENV_NAME="Windows WSL2 (WSLg / Hybrid)"
elif [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
    IS_LINUX=true
    ENV_NAME="Native Linux (Wayland / X11)"
else
    ENV_NAME="UNIX / POSIX"
fi

echo -e "${PURPLE}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
echo -e "${PURPLE}│${NC}  ${PINK}🎵 Queue (q) — Smart Minimal Setup & Environment Bootstrap${NC}             ${PURPLE}│${NC}"
echo -e "${PURPLE}│${NC}  ${GRAY}Detected System:${NC} ${CYAN}${ENV_NAME}${NC}"
echo -e "${PURPLE}╰────────────────────────────────────────────────────────────────────────────╯${NC}"

# Download tool check
FETCH_CMD=""
if command -v curl >/dev/null 2>&1; then
    FETCH_CMD="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then
    FETCH_CMD="wget -qO-"
else
    echo -e "${PINK}❌ Neither 'curl' nor 'wget' was found.${NC}"
    echo -e "👉 Please install curl: (e.g. sudo apt install curl / pkg install curl / brew install curl)"
    exit 1
fi

BASE_URL="https://raw.githubusercontent.com/ravin-ship-it/queue/main"

# Create minimal temporary staging area
TMP_STAGE="$(mktemp -d 2>/dev/null || mktemp -d -t 'q_setup.XXXXXX')"
trap 'rm -rf "$TMP_STAGE"' EXIT

echo -e "\n${CYAN}📥 Pulling environment-specific components for ${ENV_NAME}...${NC}"

mkdir -p "$TMP_STAGE/q_modules" "$TMP_STAGE/scripts"

# Core files common to all environments
CORE_FILES=(
    "q"
    "install.sh"
    "uninstall.sh"
    "setup.sh"
    "input.conf.example"
    "mpv.conf.example"
    "q_modules/ui.sh"
    "q_modules/utils.sh"
    "q_modules/queue.sh"
    "q_modules/media.sh"
    "q_modules/search.sh"
    "q_modules/playlist.sh"
    "q_modules/download.sh"
    "q_modules/batch.sh"
    "q_modules/hybrid_bridge.py"
    "scripts/queue_video.lua"
)

# Environment additions
if [ "$IS_WSL" = true ]; then
    CORE_FILES+=(
        "scripts/PipeRelay.cs"
        "scripts/PipeRelay.ps1"
    )
fi

if [ "$IS_ANDROID" = true ]; then
    CORE_FILES+=(
        "scripts/queue_android_bridge.lua"
        "q_modules/android_stream_bridge.py"
    )
fi

for rel_path in "${CORE_FILES[@]}"; do
    mkdir -p "$TMP_STAGE/$(dirname "$rel_path")"
    if $FETCH_CMD "${BASE_URL}/${rel_path}" > "$TMP_STAGE/${rel_path}"; then
        echo -e "  ${GREEN}✓${NC} ${rel_path}"
    else
        echo -e "  ${PINK}✗${NC} Failed to fetch ${rel_path}"
        exit 1
    fi
done

chmod +x "$TMP_STAGE/install.sh" "$TMP_STAGE/uninstall.sh" "$TMP_STAGE/setup.sh" "$TMP_STAGE/q"
chmod +x "$TMP_STAGE/q_modules/hybrid_bridge.py" 2>/dev/null || true
[ -f "$TMP_STAGE/q_modules/android_stream_bridge.py" ] && chmod +x "$TMP_STAGE/q_modules/android_stream_bridge.py" 2>/dev/null || true

echo -e "\n${CYAN}🚀 Launching Queue Installer...${NC}"
cd "$TMP_STAGE"
bash "$TMP_STAGE/install.sh" "$@"

echo -e "\n${GREEN}✨ Smart Setup Complete!${NC}"
echo -e "${GRAY}Queue is permanently installed in ~/.local/bin/mpv with zero repository residue.${NC}"
echo -e "${CYAN}💡 Useful Commands:${NC}"
echo -e "   • Type ${GREEN}q${NC} to start interactive player"
echo -e "   • Run ${GREEN}q -deps${NC} to view full system & multi-engine diagnostics"
echo -e "   • Run ${GREEN}q -up${NC} anytime to auto-update Queue and yt-dlp"
echo -e "   • Run ${GREEN}q -uninstall${NC} anytime to cleanly remove Queue (with instant reinstall preservation)"
echo -e "   • Run ${GREEN}q -remove-setup${NC} to permanently wipe the setup file after uninstallation"
