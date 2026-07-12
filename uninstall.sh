#!/usr/bin/env bash
# Advanced Uninstaller for q - Interactive Component Checklist

cd "$(dirname "$0")" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}🗑️  Starting Advanced Cleanup Checklist for q...${NC}"
echo -e "You will be prompted to confirm removal for each component.\n"

# Stop Q if running
if command -v q >/dev/null 2>&1; then
    q -stop >/dev/null 2>&1
fi

rm -f "$HOME/.mpv-socket"

# Helper for interactive checklist
prompt_remove() {
    local target="$1"
    local desc="$2"
    local is_dir="$3"
    
    if [ "$is_dir" = "true" ] && [ -d "$target" ] || [ "$is_dir" = "false" ] && [ -f "$target" ]; then
        echo -e "${YELLOW}Found: ${desc}${NC} (${target})"
        read -r -n 1 -p "Remove this component? [y/N] > " choice
        echo ""
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            rm -rf "$target"
            echo -e "${GREEN}✅ Removed $target${NC}\n"
        else
            echo -e "${CYAN}⏭️  Kept $target${NC}\n"
        fi
    fi
}

echo -e "${CYAN}--- File Components ---${NC}"

# Core
prompt_remove "$HOME/.local/bin/mpv/q" "Core Executable" "false"
prompt_remove "$HOME/.local/bin/mpv/q_modules" "Core Modules" "true"

# Data
prompt_remove "$HOME/.cache/mpv" "Cache & State Data" "true"
prompt_remove "$HOME/.local/share/mpv/playlists" "Saved Playlists" "true"

# Configs
prompt_remove "$HOME/.config/mpv/mpv.conf" "MPV Configuration File" "false"
prompt_remove "$HOME/.config/mpv/cookies.txt" "YouTube-DL Cookies" "false"

# Shell Config Cleanup
echo -e "${CYAN}--- Shell Configuration Cleanup ---${NC}"
for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$RC" ]; then
        # Check PATH Marker
        if grep -q "# --- Q PATH START ---" "$RC"; then
            echo -e "${YELLOW}Found Q PATH entry in $RC${NC}"
            read -r -n 1 -p "Remove the PATH entry? [y/N] > " choice
            echo ""
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                sed "\|# --- Q PATH START ---|,\|# --- Q PATH END ---|d" "$RC" > "$RC.tmp" && mv "$RC.tmp" "$RC"
                echo -e "${GREEN}✅ Cleaned up PATH in $RC${NC}\n"
            fi
        fi
        
        # Check Wrapper Marker
        if grep -q "# --- Q MPV WRAPPER START ---" "$RC"; then
            echo -e "${YELLOW}Found Q MPV wrapper function in $RC${NC}"
            read -r -n 1 -p "Remove the wrapper function? [y/N] > " choice
            echo ""
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                sed "\|# --- Q MPV WRAPPER START ---|,\|# --- Q MPV WRAPPER END ---|d" "$RC" > "$RC.tmp" && mv "$RC.tmp" "$RC"
                echo -e "${GREEN}✅ Removed mpv() wrapper from $RC${NC}\n"
            fi
        fi
    fi
done

# Clean up empty bin dir
[ -d "$HOME/.local/bin/mpv" ] && rmdir "$HOME/.local/bin/mpv" 2>/dev/null

echo -e "${GREEN}✨ Checklist complete! Run this uninstaller anytime to clean up remaining items!${NC}"
