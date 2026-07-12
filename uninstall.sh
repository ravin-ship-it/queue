#!/bin/bash
# Uninstaller for q - Advanced MPV Queue Manager

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}🗑️  Uninstalling q...${NC}"

# 1. Stop MPV if running
if command -v q >/dev/null; then
    q -stop >/dev/null 2>&1
fi

# 2. Remove Binary and Modules
DEST_DIR="$HOME/.local/bin/mpv"
if [ -d "$DEST_DIR" ]; then
    rm -f "$DEST_DIR/q"
    rm -rf "$DEST_DIR/q_modules"
    # Only remove the directory if it's empty
    rmdir "$DEST_DIR" 2>/dev/null
    echo -e "${GREEN}✅ Removed q and modules from $DEST_DIR${NC}"
fi

# 3. Remove Cache and State
if [ -d "$HOME/.cache/mpv" ]; then
    rm -rf "$HOME/.cache/mpv"
    echo -e "${GREEN}✅ Removed cache and state files${NC}"
fi

# 4. Remove Playlists (Optional/Keep them?)
echo -e "${YELLOW}❓ Do you want to remove your saved playlists in ~/.local/share/mpv/playlists? (y/n)${NC}"
read -r -n 1 -p "> " choice
echo ""
if [[ "$choice" == "y" ]]; then
    rm -rf "$HOME/.local/share/mpv/playlists"
    echo -e "${GREEN}✅ Removed playlists${NC}"
else
    echo -e "${CYAN}ℹ️  Skipped playlist removal.${NC}"
fi

# 5. Handle mpv.conf (Warning only)
if [ -f "$HOME/.config/mpv/mpv.conf" ]; then
    echo -e "${YELLOW}⚠️  I did NOT remove ~/.config/mpv/mpv.conf to avoid breaking your other mpv setups.${NC}"
    echo -e "   Remove it manually if you no longer need it."
fi

# 6. Cleanup IPC Socket
rm -f "$HOME/.mpv-socket"

# 7. Cleanup PATH from Shell RCs
for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$RC" ]; then
        if grep -q "export PATH=\".*:$DEST_DIR\"" "$RC"; then
            # Portable sed removal (works on GNU and BSD/macOS)
            sed "\|export PATH=\".*:$DEST_DIR\"|d" "$RC" > "$RC.tmp" && mv "$RC.tmp" "$RC"
            echo -e "${GREEN}✅ Cleaned up PATH in $RC${NC}"
        fi
    fi
done

# 8. Cleanup MPV Wrapper Warning
echo -e "${YELLOW}⚠️  Note: If the installer added an 'mpv()' wrapper function to your ~/.bashrc or ~/.zshrc,${NC}"
echo -e "   ${YELLOW}you may want to manually remove it if you plan to use mpv outside of q.${NC}"

echo -e "${GREEN}✨ q has been successfully uninstalled.${NC}"
