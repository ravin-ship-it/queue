#!/usr/bin/env bash
# Installer for q - Advanced MPV Queue Manager

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}🚀 Installing q...${NC}"

# 1. Create local bin directory
DEST_DIR="$HOME/.local/bin/mpv"
mkdir -p "$DEST_DIR"

# 2. Copy core files
cp -r q q_modules "$DEST_DIR/"
chmod +x "$DEST_DIR/q"

# 3. Handle mpv.conf
CONF_DIR="$HOME/.config/mpv"
mkdir -p "$CONF_DIR"
if [ ! -f "$CONF_DIR/mpv.conf" ]; then
    cp mpv.conf.example "$CONF_DIR/mpv.conf"
    echo -e "${GREEN}✅ Installed default mpv.conf${NC}"
else
    echo -e "${RED}⚠️  ~/.config/mpv/mpv.conf already exists. Skipping...${NC}"
fi

# 4. Copy bundled playlists
PLAYLIST_DEST="$HOME/.local/share/mpv/playlists"
mkdir -p "$PLAYLIST_DEST"
if [ -d "playlists" ]; then
    echo -e "${CYAN}🎵 Installing bundled playlists...${NC}"
    # Use -n (no clobber) so we don't overwrite user's existing playlists if they reinstall
    cp -rn playlists/* "$PLAYLIST_DEST/" 2>/dev/null || true
    echo -e "${GREEN}✅ Playlists installed to $PLAYLIST_DEST${NC}"
fi

# 5. Reminder for cookies
echo -e "${CYAN}🍪 Tip: For reliable YouTube playback, export your cookies to:${NC}"
echo -e "   \033[1m~/.config/mpv/cookies.txt${NC}"

# 6. Update PATH and MPV Wrapper
SHELL_RC=""
[[ "$SHELL" == */zsh ]] && SHELL_RC="$HOME/.zshrc"
[[ "$SHELL" == */bash ]] && SHELL_RC="$HOME/.bashrc"
# Fallback if SHELL is not set or weird
[ -z "$SHELL_RC" ] && [ -f "$HOME/.bashrc" ] && SHELL_RC="$HOME/.bashrc"

if [ -n "$SHELL_RC" ]; then
    # Add PATH if necessary
    if [[ ":$PATH:" != *":$DEST_DIR:"* ]] && ! grep -q "PATH.*$DEST_DIR" "$SHELL_RC"; then
        echo -e "\nexport PATH=\"\$PATH:$DEST_DIR\"" >> "$SHELL_RC"
        echo -e "${GREEN}✅ Added $DEST_DIR to PATH in $SHELL_RC${NC}"
    fi

    # Add MPV Wrapper if necessary
    if ! grep -q "function mpv()" "$SHELL_RC"; then
        echo -e "${CYAN}🔧 Adding mandatory mpv wrapper function to $SHELL_RC...${NC}"
        cat << 'EOF' >> "$SHELL_RC"

# MPV Wrapper for 'q' command IPC
function mpv() {
    SOCKET="$HOME/.mpv-socket"
    if [ -e "$SOCKET" ]; then rm "$SOCKET"; fi
    command mpv --idle --input-ipc-server="$SOCKET" "$@"
    rm -f "$SOCKET"
}
if [ -n "$BASH_VERSION" ]; then
    export -f mpv
fi
EOF
        echo -e "${GREEN}✅ Added mpv wrapper to $SHELL_RC${NC}"
    fi

    echo -e "${CYAN}👉 Run 'source $SHELL_RC' or restart your terminal to apply changes.${NC}"
fi

echo -e "${GREEN}✨ Installation complete! Type 'q' to start.${NC}"
