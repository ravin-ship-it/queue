#!/usr/bin/env bash
# Advanced Uninstaller for q - Interactive Component Checklist

cd "$(dirname "$0")" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}🗑️  Starting Advanced Cleanup Checklist for q...${NC}"

# Parse flags
AUTO_YES=false
PURGE_SETUP=false
for arg in "$@"; do
    case "$arg" in
        -y|--force|--auto) AUTO_YES=true ;;
        --purge|--wipe-all|-p) PURGE_SETUP=true ;;
    esac
done

if [ "$AUTO_YES" = true ]; then
    echo -e "${YELLOW}Running in non-interactive mode. All Queue engine components will be removed automatically.${NC}"
    if [ "$PURGE_SETUP" = true ]; then
        echo -e "${RED}Purge flag detected: Setup file will also be permanently deleted.${NC}\n"
    else
        echo -e "${GREEN}Safe Mode: Setup file will be preserved for instant 'q install' reinstallation.${NC}\n"
    fi
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
if [ -w "/usr/local/bin" ] && [ -L "/usr/local/bin/q" ]; then
    prompt_remove "/usr/local/bin/q" "Global Symlink (/usr/local/bin/q)" "false"
fi
prompt_remove "$HOME/.local/bin/mpv/q" "Core Executable" "false"
prompt_remove "$HOME/.local/bin/mpv/q_modules" "Core Modules" "true"
prompt_remove "$HOME/.local/bin/mpv/scripts" "Core Helper Scripts" "true"

# Data
prompt_remove "$HOME/.cache/mpv" "Cache & State Data" "true"
prompt_remove "$HOME/.local/share/mpv/playlists" "Saved Playlists" "true"

# Configs
prompt_remove "$HOME/.config/mpv/mpv.conf" "MPV Configuration File" "false"
prompt_remove "$HOME/.config/mpv/mpv.conf.bak" "MPV Backup Config" "false"
prompt_remove "$HOME/.config/mpv/input.conf" "MPV Input Configuration" "false"
prompt_remove "$HOME/.config/mpv/input.conf.bak" "MPV Input Backup Config" "false"
prompt_remove "$HOME/.config/mpv/scripts" "MPV Helper Scripts (~/.config/mpv/scripts)" "true"
prompt_remove "$HOME/.config/mpv/cookies.txt" "YouTube-DL Cookies" "false"
prompt_remove "$HOME/.config/mpv/queue_mode" "Queue Engine Choice (queue_mode)" "false"
prompt_remove "$HOME/.config/mpv/queue_lang" "Queue Audio Language Profile (queue_lang)" "false"

# Windows Host Components (WSL2)
if [ "$IS_WSL" = true ]; then
    echo -e "${CYAN}--- Windows Host Components (WSL2) ---${NC}"
    win_prof=$(cmd.exe /c "echo %USERPROFILE%" </dev/null 2>/dev/null | tail -n 1 | tr -d '\r\n')
    win_dir=""
    [ -n "$win_prof" ] && win_dir=$(wslpath -u "$win_prof" 2>/dev/null)
    if [ -z "$win_dir" ] || [ ! -d "$win_dir" ]; then
        ps_prof=$(powershell.exe -NoProfile -Command "[System.Environment]::GetFolderPath('UserProfile')" </dev/null 2>/dev/null | tr -d '\r\n')
        [ -n "$ps_prof" ] && win_dir=$(wslpath -u "$ps_prof" 2>/dev/null)
    fi
    if [ -z "$win_dir" ] || [ ! -d "$win_dir" ]; then
        for u in /mnt/c/Users/*; do
            base=$(basename "$u")
            if [ "$base" != "Public" ] && [ "$base" != "Default" ] && [ "$base" != "All Users" ] && [ "$base" != "Default User" ] && [ -d "$u" ]; then
                win_dir="$u"
                break
            fi
        done
    fi
    if [ -z "$win_dir" ] || [ ! -d "$win_dir" ]; then
        [ -n "$USER" ] && [ -d "/mnt/c/Users/$USER" ] && win_dir="/mnt/c/Users/$USER"
    fi

    if [ -n "$win_dir" ]; then
        prompt_remove "$win_dir/PipeRelay.exe" "Windows Pipe Relay Bridge (PipeRelay.exe)" "false"
        prompt_remove "$win_dir/PipeRelay.ps1" "Windows Pipe Relay Script (PipeRelay.ps1)" "false"
        prompt_remove "$win_dir/yt-dlp.exe" "Windows yt-dlp binary (yt-dlp.exe)" "false"
        prompt_remove "$win_dir/yt-dlp.conf" "Windows yt-dlp configuration (yt-dlp.conf)" "false"
        prompt_remove "$win_dir/AppData/Roaming/mpv/scripts/queue_video.lua" "Windows MPV Helper Script (queue_video.lua)" "false"
        prompt_remove "$win_dir/AppData/Roaming/mpv/input.conf" "Windows MPV Input Config (input.conf)" "false"
        prompt_remove "$win_dir/AppData/Roaming/mpv/queue_lang" "Windows Audio Language Profile" "false"
        prompt_remove "$win_dir/AppData/Roaming/yt-dlp/config" "Windows yt-dlp Roaming Config" "false"
        prompt_remove "$win_dir/.cache/mpv" "Windows Host MPV Cache & Shuffle History" "true"
    fi

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

# Android / Termux Host Components
if [ -n "$PREFIX" ] && [[ "$PREFIX" == *"com.termux"* ]] || [ -d "/sdcard/mpv" ] || [ -d "$HOME/storage/shared/mpv" ]; then
    echo -e "${CYAN}--- Android / Termux Mobile Components ---${NC}"
    for mpv_dir in "/sdcard/mpv" "/storage/emulated/0/mpv" "$HOME/storage/shared/mpv"; do
        if [ -d "$mpv_dir" ]; then
            prompt_remove "$mpv_dir/scripts/queue_bridge.lua" "Android MPV Lua Command Bridge" "false"
            prompt_remove "$mpv_dir/queue_cmd.txt" "Android MPV Command Relay Buffer" "false"
            if [ -f "$mpv_dir/mpv.conf" ] && grep -q "queue_bridge.lua" "$mpv_dir/mpv.conf" 2>/dev/null; then
                echo -e "${YELLOW}Found Queue bridge script reference in $mpv_dir/mpv.conf${NC}"
                if [ "$AUTO_YES" = "true" ]; then choice="y"; else read -r -n 1 -p "Remove the Queue bridge injection from mpv.conf? [y/N] > " choice; echo ""; fi
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    sed -i '/queue_bridge\.lua/d' "$mpv_dir/mpv.conf" 2>/dev/null || true
                    echo -e "${GREEN}✅ Cleaned up $mpv_dir/mpv.conf${NC}\n"
                fi
            fi
            break
        fi
    done
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
        # Check Wrapper Marker (always remove mpv wrapper when queue engine is uninstalled)
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

# --- Setup File & Reinstaller Lifecycle ---
echo -e "${CYAN}--- Quick-Reinstall & Setup File Lifecycle ---${NC}"
SETUP_FILE="$HOME/.local/bin/mpv/setup.sh"
KEEP_SETUP=true

if [ "$PURGE_SETUP" = true ]; then
    KEEP_SETUP=false
    echo -e "${RED}Purge flag active: Setup file and dormant stub will be permanently deleted.${NC}"
elif [ -f "$SETUP_FILE" ]; then
    if [ "$AUTO_YES" = true ]; then
        KEEP_SETUP=true
        echo -e "${GREEN}Safe Mode Active: Preserving lightweight setup file (${SETUP_FILE})${NC}"
        echo -e "${GRAY}   👉 You can reinstall Queue anytime by running: ${CYAN}q install${NC}"
    else
        echo -e "${YELLOW}Found Queue lightweight setup file: ${SETUP_FILE}${NC}"
        echo -e "Keeping this file allows you to instantly reinstall Queue anytime with: ${GREEN}q install${NC}"
        read -r -n 1 -p "Do you want to keep the setup file for instant reinstallation? [Y/n] > " keep_choice
        echo ""
        if [[ "$keep_choice" =~ ^[Nn]$ ]]; then
            KEEP_SETUP=false
        else
            KEEP_SETUP=true
        fi
    fi
else
    KEEP_SETUP=false
fi

if [ "$KEEP_SETUP" = true ]; then
    echo -e "${CYAN}🔧 Installing lightweight dormant reinstaller stub (~/.local/bin/q)...${NC}"
    mkdir -p "$HOME/.local/bin"
    cat << 'EOF' > "$HOME/.local/bin/q"
#!/usr/bin/env bash
# Queue (q) - Minimal Dormant Reinstaller Stub

SETUP_FILE="$HOME/.local/bin/mpv/setup.sh"

case "$1" in
    install|-install|--install|setup|-setup|--setup)
        echo -e "\033[1;36m🚀 Reinstalling Queue Engine...\033[0m"
        shift
        if [ -f "$SETUP_FILE" ]; then
            exec bash "$SETUP_FILE" "$@"
        else
            echo -e "\033[1;33mℹ️ Local setup file not found. Fetching from GitHub...\033[0m"
            exec bash <(curl -fsSL https://raw.githubusercontent.com/ravin-ship-it/queue/main/setup.sh) "$@"
        fi
        ;;
    remove-setup|-remove-setup|--remove-setup|clean-setup)
        echo -e "\033[1;36m🗑️ Removing dormant Queue setup file and launcher stub...\033[0m"
        rm -rf "$HOME/.local/bin/mpv" "$HOME/.local/bin/q"
        [ -n "$PREFIX" ] && rm -f "$PREFIX/bin/q" 2>/dev/null || true
        for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
            if [ -f "$RC" ]; then
                sed -i '/# --- Q PATH START ---/,/# --- Q PATH END ---/d' "$RC" 2>/dev/null || true
                sed -i '/# --- Q MPV WRAPPER START ---/,/# --- Q MPV WRAPPER END ---/d' "$RC" 2>/dev/null || true
            fi
        done
        echo -e "\033[1;32m✅ Queue setup file and launcher completely removed from system.\033[0m"
        exit 0
        ;;
    -h|--help|help)
        echo -e "\033[1;38;5;171m╭──────────────────────────────────────────────────────────╮\033[0m"
        echo -e "\033[1;38;5;171m│\033[0m  \033[38;5;198m🎵 Queue (Dormant Setup Stub)\033[0m                           \033[1;38;5;171m│\033[0m"
        echo -e "\033[1;38;5;171m├──────────────────────────────────────────────────────────┤\033[0m"
        echo -e "\033[1;38;5;171m│\033[0m  Queue is currently uninstalled.                         \033[1;38;5;171m│\033[0m"
        echo -e "\033[1;38;5;171m│\033[0m  \033[1;36mAvailable Commands:\033[0m                                     \033[1;38;5;171m│\033[0m"
        echo -e "\033[1;38;5;171m│\033[0m    \033[1;32mq install\033[0m          Reinstall Queue instantly           \033[1;38;5;171m│\033[0m"
        echo -e "\033[1;38;5;171m│\033[0m    \033[1;32mq install --hybrid\033[0m Reinstall in Hybrid Boost Mode      \033[1;38;5;171m│\033[0m"
        echo -e "\033[1;38;5;171m│\033[0m    \033[1;33mq -remove-setup\033[0m    Permanently wipe setup file & stub  \033[1;38;5;171m│\033[0m"
        echo -e "\033[1;38;5;171m╰──────────────────────────────────────────────────────────╯\033[0m"
        exit 0
        ;;
    *)
        echo -e "\033[1;38;5;171m╭──────────────────────────────────────────────────────────╮\033[0m"
        echo -e "\033[1;38;5;171m│\033[0m  \033[38;5;198m🎵 Queue is currently not installed on this system.\033[0m     \033[1;38;5;171m│\033[0m"
        echo -e "\033[1;38;5;171m├──────────────────────────────────────────────────────────┤\033[0m"
        echo -e "\033[1;38;5;171m│\033[0m  \033[1;36mQuick Actions:\033[0m                                          \033[1;38;5;171m│\033[0m"
        echo -e "\033[1;38;5;171m│\033[0m    • Run \033[1;32mq install\033[0m (or \033[1;32mq -install\033[0m) to reinstall instantly \033[1;38;5;171m│\033[0m"
        echo -e "\033[1;38;5;171m│\033[0m    • Run \033[1;33mq -remove-setup\033[0m to permanently purge all files  \033[1;38;5;171m│\033[0m"
        echo -e "\033[1;38;5;171m╰──────────────────────────────────────────────────────────╯\033[0m"
        exit 1
        ;;
esac
EOF
    chmod +x "$HOME/.local/bin/q"
    if [ -n "$PREFIX" ] && [ -d "$PREFIX/bin" ] && [ -w "$PREFIX/bin" ]; then
        cp -f "$HOME/.local/bin/q" "$PREFIX/bin/q" 2>/dev/null || true
    fi
    echo -e "${GREEN}✅ Dormant launcher stub ready!${NC}"
    echo -e "${CYAN}💡 Useful Next Steps:${NC}"
    echo -e "   • To reinstall Queue anytime: run ${GREEN}q install${NC} (or ${GREEN}q -install${NC})"
    echo -e "   • To permanently delete the setup file: run ${YELLOW}q -remove-setup${NC}"
else
    echo -e "${YELLOW}🗑️ Purging setup file and launcher completely...${NC}"
    rm -rf "$HOME/.local/bin/mpv"
    rm -f "$HOME/.local/bin/q"
    [ -n "$PREFIX" ] && rm -f "$PREFIX/bin/q" 2>/dev/null || true
    if [ -w "/usr/local/bin" ]; then rm -f "/usr/local/bin/q" 2>/dev/null || true; fi
    for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$RC" ]; then
            sed -i '/# --- Q PATH START ---/,/# --- Q PATH END ---/d' "$RC" 2>/dev/null || true
        fi
    done
    echo -e "${GREEN}✅ All Queue files, setup scripts, and shell PATH modifications have been completely wiped.${NC}"
fi

echo -e "\n${GREEN}✨ Uninstallation complete!${NC}"
