#!/usr/bin/env bash
# Advanced Uninstaller for q - Interactive Component Checklist

cd "$(dirname "$0")" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}🗑️  Starting Advanced Cleanup Checklist for q...${NC}"

# Non-interactive mode flag
AUTO_YES=false
if [ "$1" = "-y" ] || [ "$1" = "--force" ] || [ "$1" = "--auto" ]; then
    AUTO_YES=true
    echo -e "${YELLOW}Running in non-interactive mode. All components will be removed automatically.${NC}\n"
else
    echo -e "You will be prompted to confirm removal for each component. Pass -y to skip prompts.\n"
fi

# --- Platform Detection ---
IS_WSL=false
if grep -qi "microsoft" /proc/version 2>/dev/null || [ -d "/usr/lib/wsl" ] || [ -d "/mnt/wslg" ]; then
    IS_WSL=true
fi

# Stop Q and MPV if running
if command -v q >/dev/null 2>&1; then
    q -stop >/dev/null 2>&1
fi

if [ "$IS_WSL" = true ]; then
    taskkill.exe /F /IM mpv.exe 2>/dev/null || true
    taskkill.exe /F /IM mpv.com 2>/dev/null || true
    taskkill.exe /F /IM PipeRelay.exe 2>/dev/null || true
fi
pkill -f "hybrid_bridge.py" 2>/dev/null || true

rm -f "$HOME/.mpv-socket"

# Helper for interactive checklist
prompt_remove() {
    local target="$1"
    local desc="$2"
    local is_dir="$3"
    
    if [ "$is_dir" = "true" ] && [ -d "$target" ] || [ "$is_dir" = "false" ] && [ -f "$target" ]; then
        echo -e "${YELLOW}Found: ${desc}${NC} (${target})"
        
        if [ "$AUTO_YES" = "true" ]; then
            choice="y"
        else
            read -r -n 1 -p "Remove this component? [y/N] > " choice
            echo ""
        fi
        
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
prompt_remove "$HOME/.local/bin/q" "Symlink (~/.local/bin/q)" "false"
if [ -n "$PREFIX" ] && [ -d "$PREFIX/bin" ]; then
    prompt_remove "$PREFIX/bin/q" "Symlink ($PREFIX/bin/q)" "false"
fi
prompt_remove "/usr/local/bin/q" "Symlink (/usr/local/bin/q)" "false"
prompt_remove "$HOME/.local/bin/mpv/q" "Core Executable" "false"
prompt_remove "$HOME/.local/bin/mpv/q_modules" "Core Modules" "true"

# Data
prompt_remove "$HOME/.cache/mpv" "Cache & State Data" "true"
prompt_remove "$HOME/.local/share/mpv/playlists" "Saved Playlists" "true"

# Configs
prompt_remove "$HOME/.config/mpv/mpv.conf" "MPV Configuration File" "false"
prompt_remove "$HOME/.config/mpv/mpv.conf.bak" "MPV Backup Config" "false"
prompt_remove "$HOME/.config/mpv/cookies.txt" "YouTube-DL Cookies" "false"
prompt_remove "$HOME/.config/mpv/queue_mode" "Queue Engine Choice (queue_mode)" "false"

# Windows Host Components (WSL2)
if [ "$IS_WSL" = true ]; then
    echo -e "${CYAN}--- Windows Host Components (WSL2) ---${NC}"
    win_prof=$(cmd.exe /c "echo %USERPROFILE%" </dev/null 2>/dev/null | tail -n 1 | tr -d '\r\n')
    win_dir=""
    [ -n "$win_prof" ] && win_dir=$(wslpath -u "$win_prof" 2>/dev/null)
    if [ -z "$win_dir" ] || [ ! -d "$win_dir" ]; then
        for u in /mnt/c/Users/*; do
            base=$(basename "$u")
            if [ "$base" != "Public" ] && [ "$base" != "Default" ] && [ "$base" != "All Users" ] && [ "$base" != "Default User" ] && [ -d "$u" ]; then
                win_dir="$u"
                break
            fi
        done
    fi
    [ -z "$win_dir" ] && win_dir="/mnt/c/Users/HP"

    prompt_remove "$win_dir/PipeRelay.exe" "Windows Pipe Relay Bridge (PipeRelay.exe)" "false"
    prompt_remove "$win_dir/yt-dlp.exe" "Windows yt-dlp binary (yt-dlp.exe)" "false"

    if [ -f "/mnt/c/Program Files/MPV Player/mpv.exe" ] || [ -f "/mnt/c/Program Files/MPV Player/mpv.com" ]; then
        echo -e "${YELLOW}Found: Native Windows MPV Player${NC} (C:\\Program Files\\MPV Player)"
        if [ "$AUTO_YES" = "true" ]; then
            win_mpv_choice="n"
        else
            read -r -n 1 -p "Uninstall Native Windows MPV via winget? [y/N] > " win_mpv_choice
            echo ""
        fi
        if [[ "$win_mpv_choice" =~ ^[Yy]$ ]]; then
            echo -e "${CYAN}🗑️  Uninstalling Windows MPV via winget...${NC}"
            cmd.exe /c "winget uninstall --id shinchiro.mpv -e" </dev/null || true
            echo -e "${GREEN}✅ Uninstalled Windows MPV${NC}\n"
        else
            echo -e "${CYAN}⏭️  Kept Native Windows MPV${NC}\n"
        fi
    fi
fi

# YT-DLP config cleanup
YTDLP_CONF="$HOME/.config/yt-dlp/config"
if [ -f "$YTDLP_CONF" ]; then
    if grep -q "\-\-js-runtimes node" "$YTDLP_CONF"; then
        echo -e "${YELLOW}Found yt-dlp js-runtime node config in $YTDLP_CONF${NC}"
        if [ "$AUTO_YES" = "true" ]; then choice="y"; else read -r -n 1 -p "Remove the yt-dlp config injection? [y/N] > " choice; echo ""; fi
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            sed -i '/--js-runtimes node/d' "$YTDLP_CONF"
            echo -e "${GREEN}✅ Cleaned up yt-dlp config${NC}\n"
        fi
    fi
fi

# Shell Config Cleanup
echo -e "${CYAN}--- Shell Configuration Cleanup ---${NC}"
for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$RC" ]; then
        # Check PATH Marker
        if grep -q "# --- Q PATH START ---" "$RC"; then
            echo -e "${YELLOW}Found Q PATH entry in $RC${NC}"
            if [ "$AUTO_YES" = "true" ]; then choice="y"; else read -r -n 1 -p "Remove the PATH entry? [y/N] > " choice; echo ""; fi
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                sed -i '/# --- Q PATH START ---/,/# --- Q PATH END ---/d' "$RC"
                echo -e "${GREEN}✅ Cleaned up PATH in $RC${NC}\n"
            fi
        fi
        
        # Check Wrapper Marker
        if grep -q "# --- Q MPV WRAPPER START ---" "$RC"; then
            echo -e "${YELLOW}Found Q MPV wrapper function in $RC${NC}"
            if [ "$AUTO_YES" = "true" ]; then choice="y"; else read -r -n 1 -p "Remove the wrapper function? [y/N] > " choice; echo ""; fi
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                sed -i '/# --- Q MPV WRAPPER START ---/,/# --- Q MPV WRAPPER END ---/d' "$RC"
                echo -e "${GREEN}✅ Removed mpv() wrapper from $RC${NC}\n"
            fi
        fi
    fi
done

# Clean up empty bin dir
[ -d "$HOME/.local/bin/mpv" ] && rmdir "$HOME/.local/bin/mpv" 2>/dev/null

echo -e "${GREEN}✨ Checklist complete! Run this uninstaller anytime to clean up remaining items!${NC}"
