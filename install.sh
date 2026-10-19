#!/usr/bin/env bash
# Advanced Installer for q - Smart MPV Queue Manager

cd "$(dirname "$0")" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Platform Detection ---
IS_WSL=false
IS_MACOS=false
IS_LINUX=false
IS_ANDROID=false

if [[ "$OSTYPE" == "darwin"* ]] || [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    IS_MACOS=true
elif [ -n "$PREFIX" ] && [[ "$PREFIX" == *"com.termux"* ]]; then
    IS_ANDROID=true
elif grep -qi "microsoft" /proc/version 2>/dev/null || [ -d "/usr/lib/wsl" ] || [ -d "/mnt/wslg" ]; then
    IS_WSL=true
    IS_LINUX=true
elif [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
    IS_LINUX=true
fi

echo -e "${CYAN}🚀 Starting Advanced Installation of q...${NC}"

# --- Dependency Resolution Engine ---
install_deps() {
    local deps=("mpv" "yt-dlp" "fzf" "jq")
    local missing=()
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        elif [ "$cmd" == "yt-dlp" ] && ! yt-dlp --version >/dev/null 2>&1; then
            # Binary exists but crashes on execution (e.g. Termux Python package mismatch)
            missing+=("yt-dlp")
        fi
    done
    
    if ! command -v nc >/dev/null 2>&1; then
        missing+=("netcat")
    fi

    # Check for JS Runtime (Required by yt-dlp for YouTube Decryption)
    local has_js=false
    for js in node deno bun qjs; do
        if command -v "$js" >/dev/null 2>&1; then
            has_js=true
            break
        fi
    done
    
    if [ "$has_js" = false ]; then
        missing+=("nodejs")
    fi

    if [ ${#missing[@]} -eq 0 ]; then
        echo -e "${GREEN}✅ All core dependencies are already installed and working.${NC}"
        return
    fi
    
    echo -e "${YELLOW}⚠️  Missing or broken dependencies detected: ${missing[*]}${NC}"
    echo -e "${CYAN}🔧 Attempting automatic installation...${NC}"
    
    if command -v pkg >/dev/null 2>&1; then # Termux
        pkg update
        pkg install -y coreutils ca-certificates openssl-tool python python-pip termux-api
        for pkg in "${missing[@]}"; do
            [ "$pkg" == "netcat" ] && pkg="netcat-openbsd"
            [ "$pkg" == "yt-dlp" ] && continue # Handled via pip below
            pkg install -y "$pkg"
        done
        # Termux apt package for yt-dlp is often broken with Python 3.14; always install/heal via pip
        echo -e "${CYAN}🔧 Installing/Healing yt-dlp via pip for Termux Python...${NC}"
        pip install -U --force-reinstall yt-dlp || pkg install -y yt-dlp || true

        # Create bulletproof yt-dlp binary wrapper for MPV ytdl-hook and Termux shell
        mkdir -p "$HOME/.local/bin"
        cat << 'EOF' > "$HOME/.local/bin/yt-dlp"
#!/usr/bin/env sh
exec python3 -m yt_dlp "$@"
EOF
        chmod +x "$HOME/.local/bin/yt-dlp"
        if [ -n "$PREFIX" ] && [ -d "$PREFIX/bin" ] && [ -w "$PREFIX/bin" ]; then
            cp -f "$HOME/.local/bin/yt-dlp" "$PREFIX/bin/yt-dlp" 2>/dev/null || true
            chmod +x "$PREFIX/bin/yt-dlp" 2>/dev/null || true
        fi

        # Check Termux Android storage permission
        if [ ! -d "$HOME/storage" ] && command -v termux-setup-storage >/dev/null 2>&1; then
            echo -e "${YELLOW}📱 Initializing Termux storage access...${NC}"
            termux-setup-storage </dev/null >/dev/null 2>&1 || true
        fi
    elif command -v apt-get >/dev/null 2>&1; then # Debian/Ubuntu/Kali/WSL
        sudo apt-get update
        for pkg in "${missing[@]}"; do
            [ "$pkg" == "netcat" ] && pkg="netcat-openbsd"
            sudo apt-get install -y "$pkg"
        done
    elif [ "$IS_MACOS" = true ] || command -v brew >/dev/null 2>&1; then # macOS
        # Ensure brew is in PATH if installed in standard locations
        if ! command -v brew >/dev/null 2>&1; then
            if [ -x "/opt/homebrew/bin/brew" ]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [ -x "/usr/local/bin/brew" ]; then
                eval "$(/usr/local/bin/brew shellenv)"
            fi
        fi

        if command -v brew >/dev/null 2>&1; then
            for pkg in "${missing[@]}"; do
                [ "$pkg" == "netcat" ] && continue # macOS has built-in BSD nc
                [ "$pkg" == "nodejs" ] && pkg="node"
                brew install "$pkg"
            done
        else
            echo -e "${RED}❌ Homebrew (brew) is required to install missing dependencies on macOS.${NC}"
            echo -e "${CYAN}👉 Please install Homebrew from https://brew.sh or manually install: ${missing[*]}${NC}"
            exit 1
        fi
    elif command -v pacman >/dev/null 2>&1; then # Arch
        for pkg in "${missing[@]}"; do
            [ "$pkg" == "netcat" ] && pkg="gnu-netcat"
            sudo pacman -S --noconfirm "$pkg"
        done
    elif command -v dnf >/dev/null 2>&1; then # Fedora
        for pkg in "${missing[@]}"; do
            [ "$pkg" == "netcat" ] && pkg="nc"
            sudo dnf install -y "$pkg"
        done
    else
        echo -e "${RED}❌ Could not detect package manager. Please manually install: ${missing[*]}${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ Dependencies installed successfully.${NC}"
}

install_deps

# --- Core Files Installation ---
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/.local/bin/mpv"
mkdir -p "$DEST_DIR"
mkdir -p "$HOME/.local/bin"

echo -e "${CYAN}📦 Installing Queue engine into $DEST_DIR...${NC}"
# Clean existing symlinks/files in destination before copying permanent files
rm -rf "$DEST_DIR/q" "$DEST_DIR/q_modules" "$DEST_DIR/scripts"
cp -r "$REPO_DIR/q" "$REPO_DIR/q_modules" "$REPO_DIR/scripts" "$DEST_DIR/"
chmod +x "$DEST_DIR/q"

# Link to user and system bin paths for instant zero-restart availability
ln -sf "$DEST_DIR/q" "$HOME/.local/bin/q"

# Termux immediate PATH integration (accessible instantly without 'source ~/.bashrc' or 'exec bash')
if [ -n "$PREFIX" ] && [ -d "$PREFIX/bin" ] && [ -w "$PREFIX/bin" ]; then
    ln -sf "$DEST_DIR/q" "$PREFIX/bin/q"
fi

# Standard Linux/macOS global path if writable
if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
    ln -sf "$DEST_DIR/q" "/usr/local/bin/q" 2>/dev/null || true
fi

echo -e "${GREEN}✅ Queue installed permanently to $DEST_DIR (symlinked to PATH)${NC}"
echo -e "${GRAY}   👉 Self-Contained: You can delete the cloned folder anytime without breaking q!${NC}"
echo -e "${GRAY}   👉 Auto-Updates: Run 'q -up' anytime from any directory to update Queue & yt-dlp.${NC}"

# --- Configuration ---
CONF_DIR="$HOME/.config/mpv"
mkdir -p "$CONF_DIR"
if [ -f "$CONF_DIR/mpv.conf" ]; then
    cp "$CONF_DIR/mpv.conf" "$CONF_DIR/mpv.conf.bak"
    echo -e "${YELLOW}ℹ️  Backed up existing mpv.conf to mpv.conf.bak${NC}"
fi
cp mpv.conf.example "$CONF_DIR/mpv.conf"
echo -e "${GREEN}✅ Installed fresh mpv.conf${NC}"

# --- MPV Input Keybindings ---
if [ -f "input.conf.example" ]; then
    if [ -f "$CONF_DIR/input.conf" ]; then
        cp "$CONF_DIR/input.conf" "$CONF_DIR/input.conf.bak"
    fi
    cp input.conf.example "$CONF_DIR/input.conf"
    echo -e "${GREEN}✅ Installed fresh input.conf (quality & window-scale hotkeys)${NC}"
fi

# --- MPV Helper Scripts ---
if [ -d "scripts" ]; then
    mkdir -p "$CONF_DIR/scripts"
    cp -rf scripts/* "$CONF_DIR/scripts/"
    echo -e "${GREEN}✅ Installed helper scripts to $CONF_DIR/scripts/${NC}"
fi

# --- High-DPI Cursor Scaling (WSLg / Linux) ---
if [ "$IS_MACOS" = false ] && [ "$IS_ANDROID" = false ]; then
    cursor_size="24"
    [ "$IS_WSL" = true ] && cursor_size="36"

    mkdir -p "$HOME/.icons/default"
    cat << EOF > "$HOME/.icons/default/index.theme"
[Icon Theme]
Name=Default
Comment=Default Cursor Theme
Inherits=Adwaita
Size=$cursor_size
EOF
    cat << EOF > "$HOME/.Xresources"
Xcursor.theme: Adwaita
Xcursor.size: $cursor_size
EOF
    if [ -n "$DISPLAY" ] && command -v xrdb >/dev/null 2>&1; then
        xrdb -merge "$HOME/.Xresources" 2>/dev/null || true
    fi
    echo -e "${GREEN}✅ Cursor scaling configured (size $cursor_size)${NC}"
fi

# --- YT-DLP Configuration ---
YTDLP_CONF_DIR="$HOME/.config/yt-dlp"
mkdir -p "$YTDLP_CONF_DIR"
cat << 'EOF' > "$YTDLP_CONF_DIR/config"
--js-runtimes node
--no-warnings
EOF
if [ -f "$YTDLP_CONF_DIR/cookies.txt" ]; then
    echo "--cookies ~/.config/yt-dlp/cookies.txt" >> "$YTDLP_CONF_DIR/config"
fi
echo -e "${GREEN}✅ yt-dlp configuration updated.${NC}"

# --- Playlists ---
PLAYLIST_DEST="$HOME/.local/share/mpv/playlists"
mkdir -p "$PLAYLIST_DEST"
if [ -d "playlists" ]; then
    cp -rn playlists/* "$PLAYLIST_DEST/" 2>/dev/null || true
    echo -e "${GREEN}✅ Bundled playlists safely integrated into $PLAYLIST_DEST${NC}"
fi

# --- Dual-Engine Architecture (Windows + WSL2 Optimization) ---
if [ "$IS_WSL" = true ]; then
    echo -e "\n${CYAN}⚡ Windows + WSL2 Dual-Engine Configuration...${NC}"
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
    win_user=""
    [ -n "$win_dir" ] && win_user=$(basename "$win_dir")

    # 1. Compile Native PipeRelay.exe via Windows .NET compiler
    win_relay="$win_dir/PipeRelay.exe"
    csc_compiler="/mnt/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
    [ ! -f "$csc_compiler" ] && csc_compiler="/mnt/c/Windows/Microsoft.NET/Framework/v4.0.30319/csc.exe"

    if [ -f "$csc_compiler" ]; then
        if [ ! -f "$win_relay" ]; then
            echo -e "${CYAN}🔨 Compiling native zero-dependency PipeRelay.exe for sub-millisecond IPC...${NC}"
            cp "$REPO_DIR/scripts/PipeRelay.cs" "$win_dir/PipeRelay.cs" 2>/dev/null
            (cd "$win_dir" && "$csc_compiler" /out:PipeRelay.exe /target:exe /nologo PipeRelay.cs </dev/null >/dev/null 2>&1)
            rm -f "$win_dir/PipeRelay.cs" 2>/dev/null
        fi
        [ -f "$win_relay" ] && echo -e "${GREEN}✅ PipeRelay.exe ready at $win_relay${NC}"
    fi

    # 2. Check for Native Windows MPV
    has_win_mpv=false
    if [ -f "/mnt/c/Program Files/MPV Player/mpv.com" ] || [ -f "/mnt/c/Program Files/MPV Player/mpv.exe" ] || command -v mpv.exe >/dev/null 2>&1; then
        has_win_mpv=true
    fi

    # Check for Windows yt-dlp
    winget_ytdlp="$win_dir/AppData/Local/Microsoft/WinGet/Packages/yt-dlp.yt-dlp_Microsoft.Winget.Source_8wekyb3d8bbwe/yt-dlp.exe"
    if [ -f "$winget_ytdlp" ] && [ ! -f "$win_dir/yt-dlp.exe" ]; then
        cp "$winget_ytdlp" "$win_dir/yt-dlp.exe" 2>/dev/null || true
    fi

    echo -e "\n${YELLOW}💡 PERFORMANCE TIP FOR WINDOWS + WSL2:${NC}"
    echo -e "   Queue offers two rendering builds:"
    echo -e "   1. ${GREEN}Standalone WSL Mode (Default):${NC} 60 FPS capped via WSLg Mesa D3D12. Zero Windows configuration."
    echo -e "   2. ${YELLOW}Hybrid Boost Mode:${NC} Uncapped ${GREEN}120+ FPS 4K/8K${NC} Direct3D 11/12 with native host WASAPI audio!"

    if [ "$has_win_mpv" = true ]; then
        echo -e "${GREEN}✅ Native Windows MPV detected on host!${NC}"
        echo -e "   👉 You can toggle between engines anytime with: ${CYAN}q -hybrid on${NC} or ${CYAN}q -hybrid off${NC}"
    else
        echo -e "${YELLOW}ℹ️  Native Windows MPV is not yet installed on Windows host.${NC}"
        echo -e "   Standalone Mode is active and ready to play up to 60 FPS in WSLg."
        
        if cmd.exe /c "where winget" </dev/null >/dev/null 2>&1; then
            echo -e "   Would you like to auto-install Windows MPV & yt-dlp now for 120+ FPS Hybrid Boost? [y/N]"
            read -r -t 15 -n 1 -p "   > " install_win_choice || install_win_choice="n"
            echo ""
            if [[ "$install_win_choice" =~ ^[Yy]$ ]]; then
                echo -e "${CYAN}🚀 Installing Windows MPV via winget...${NC}"
                cmd.exe /c "winget install --id shinchiro.mpv -e" </dev/null || true
                echo -e "${CYAN}🚀 Installing Windows yt-dlp via winget...${NC}"
                cmd.exe /c "winget install --id yt-dlp.yt-dlp -e" </dev/null || true
                if [ -f "$winget_ytdlp" ]; then
                    cp "$winget_ytdlp" "$win_dir/yt-dlp.exe" 2>/dev/null || true
                fi
                echo -e "${GREEN}✅ Windows MPV installed! You can run 'q -hybrid on' anytime to switch!${NC}"
            else
                echo -e "${CYAN}⏭️  Skipped Windows MPV installation. Standalone WSL Mode is active.${NC}"
                echo -e "${GRAY}   (To install manually later, run in Windows PowerShell: winget install shinchiro.mpv)${NC}"
            fi
        fi
    fi

    # Sync yt-dlp anti-bot configuration, cookies, and MPV config for Windows host
    win_user="${win_dir##*/}"
    win_ytdlp_dir="$win_dir/AppData/Roaming/yt-dlp"
    mkdir -p "$win_ytdlp_dir" 2>/dev/null

    cookie_src=""
    if [ -f "$HOME/.config/yt-dlp/cookies.txt" ]; then
        cookie_src="$HOME/.config/yt-dlp/cookies.txt"
    elif [ -f "$HOME/.cache/yt-dlp/cookies.txt" ]; then
        cookie_src="$HOME/.cache/yt-dlp/cookies.txt"
    elif [ -f "$HOME/.config/mpv/cookies.txt" ]; then
        cookie_src="$HOME/.config/mpv/cookies.txt"
    fi

    win_cookies_txt="$win_ytdlp_dir/cookies.txt"
    if [ -n "$cookie_src" ] && [ ! -f "$win_cookies_txt" ]; then
        cp "$cookie_src" "$win_cookies_txt" 2>/dev/null
    fi

    win_conf="$win_ytdlp_dir/config"
    if [ ! -f "$win_conf" ]; then
        cat <<EOF > "$win_conf"
--extractor-args "youtube:player_client=visionos,android,web"
--no-warnings
EOF
        if [ -f "$win_cookies_txt" ]; then
            echo "--cookies \"C:\\Users\\$win_user\\AppData\\Roaming\\yt-dlp\\cookies.txt\"" >> "$win_conf"
        fi
    fi

    if [ ! -f "$win_dir/yt-dlp.conf" ] && [ -f "$win_conf" ]; then
        cp "$win_conf" "$win_dir/yt-dlp.conf" 2>/dev/null
    fi

    win_mpv_dir="$win_dir/AppData/Roaming/mpv"
    mkdir -p "$win_mpv_dir" 2>/dev/null
    if [ ! -f "$win_mpv_dir/mpv.conf" ] && [ -f "$SCRIPT_DIR/mpv.conf.example" ]; then
        cp "$SCRIPT_DIR/mpv.conf.example" "$win_mpv_dir/mpv.conf" 2>/dev/null
    fi
fi

# --- Cross-Platform sed In-Place Deletion Helper ---
cross_sed_delete() {
    local pattern="$1"
    local file="$2"
    if [ "$IS_MACOS" = true ]; then
        sed -i '' "$pattern" "$file" 2>/dev/null || true
    else
        sed -i "$pattern" "$file" 2>/dev/null || true
    fi
}

# --- Shell Wrapper & PATH ---
SHELL_RC=""
[[ "$SHELL" == */zsh ]] && SHELL_RC="$HOME/.zshrc"
[[ "$SHELL" == */bash ]] && SHELL_RC="$HOME/.bashrc"
[ -z "$SHELL_RC" ] && [ -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.zshrc"
[ -z "$SHELL_RC" ] && SHELL_RC="$HOME/.bashrc"

if [ -n "$SHELL_RC" ]; then
    # Ensure the RC file exists before editing
    [ ! -f "$SHELL_RC" ] && touch "$SHELL_RC"

    # Remove previous Q PATH blocks cleanly
    cross_sed_delete '/# --- Q PATH START ---/,/# --- Q PATH END ---/d' "$SHELL_RC"

    # Inject Platform-Specific PATH & Environment
    echo -e "\n# --- Q PATH START ---" >> "$SHELL_RC"
    if [ "$IS_MACOS" = true ]; then
        echo "export PATH=\"/opt/homebrew/bin:/usr/local/bin:\$PATH:\$HOME/.local/bin:$DEST_DIR\"" >> "$SHELL_RC"
        echo "# --- Q PATH END ---" >> "$SHELL_RC"
        echo -e "${GREEN}✅ Added macOS Homebrew paths, $DEST_DIR, and ~/.local/bin to $SHELL_RC${NC}"
    elif [ "$IS_WSL" = true ]; then
        echo "export PATH=\"\$PATH:\$HOME/.local/bin:$DEST_DIR\"" >> "$SHELL_RC"
        echo "export XCURSOR_THEME=\"\${XCURSOR_THEME:-Adwaita}\"" >> "$SHELL_RC"
        echo "export XCURSOR_SIZE=\"\${XCURSOR_SIZE:-36}\"" >> "$SHELL_RC"
        echo "export GALLIUM_DRIVER=\"\${GALLIUM_DRIVER:-d3d12}\"" >> "$SHELL_RC"
        echo "if [ -d \"/usr/lib/wsl/lib\" ] && [[ \":\$LD_LIBRARY_PATH:\" != *\":/usr/lib/wsl/lib:\"* ]]; then" >> "$SHELL_RC"
        echo "    export LD_LIBRARY_PATH=\"/usr/lib/wsl/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\"" >> "$SHELL_RC"
        echo "fi" >> "$SHELL_RC"
        echo "# --- Q PATH END ---" >> "$SHELL_RC"
        echo -e "${GREEN}✅ Added $DEST_DIR, ~/.local/bin, and WSL2 D3D12 acceleration settings to $SHELL_RC${NC}"
    else
        # Native Linux (Wayland / X11)
        echo "export PATH=\"\$PATH:\$HOME/.local/bin:$DEST_DIR\"" >> "$SHELL_RC"
        echo "export XCURSOR_THEME=\"\${XCURSOR_THEME:-Adwaita}\"" >> "$SHELL_RC"
        echo "export XCURSOR_SIZE=\"\${XCURSOR_SIZE:-24}\"" >> "$SHELL_RC"
        echo "# --- Q PATH END ---" >> "$SHELL_RC"
        echo -e "${GREEN}✅ Added $DEST_DIR and ~/.local/bin to $SHELL_RC (Native Linux Mesa acceleration)${NC}"
    fi

    # Remove previous MPV wrapper blocks cleanly
    cross_sed_delete '/# --- Q MPV WRAPPER START ---/,/# --- Q MPV WRAPPER END ---/d' "$SHELL_RC"

    echo -e "${CYAN}🔧 Injecting mandatory mpv IPC wrapper function...${NC}"
    cat << 'EOF' >> "$SHELL_RC"

# --- Q MPV WRAPPER START ---
function mpv() {
    SOCKET="$HOME/.mpv-socket"
    if [ -e "$SOCKET" ]; then rm "$SOCKET"; fi
    command mpv --idle --input-ipc-server="$SOCKET" "$@"
    rm -f "$SOCKET"
}
if [ -n "$BASH_VERSION" ]; then
    export -f mpv
fi
# --- Q MPV WRAPPER END ---
EOF
    echo -e "${GREEN}✅ Wrapper injected into $SHELL_RC${NC}"
    echo -e "${CYAN}👉 Note: Run 'source $SHELL_RC' or restart terminal to apply changes.${NC}"
fi

echo -e "${GREEN}✨ Installation flawlessly finished! Type 'q' to start.${NC}"
