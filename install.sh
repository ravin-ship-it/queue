#!/usr/bin/env bash
# Advanced Installer for q - Smart MPV Queue Manager

cd "$(dirname "$0")" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}🚀 Starting Advanced Installation of q...${NC}"

# --- Dependency Resolution Engine ---
install_deps() {
    local deps=("mpv" "yt-dlp" "fzf" "jq")
    local missing=()
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
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
        echo -e "${GREEN}✅ All core dependencies are already installed.${NC}"
        return
    fi
    
    echo -e "${YELLOW}⚠️  Missing dependencies detected: ${missing[*]}${NC}"
    echo -e "${CYAN}🔧 Attempting automatic installation...${NC}"
    
    if command -v pkg >/dev/null 2>&1; then # Termux
        pkg update
        for pkg in "${missing[@]}"; do
            [ "$pkg" == "netcat" ] && pkg="netcat-openbsd"
            pkg install -y "$pkg"
        done
    elif command -v apt-get >/dev/null 2>&1; then # Debian/Ubuntu/Kali
        sudo apt-get update
        for pkg in "${missing[@]}"; do
            [ "$pkg" == "netcat" ] && pkg="netcat-openbsd"
            sudo apt-get install -y "$pkg"
        done
    elif command -v brew >/dev/null 2>&1; then # macOS
        for pkg in "${missing[@]}"; do
            [ "$pkg" == "netcat" ] && continue
            [ "$pkg" == "nodejs" ] && pkg="node"
            brew install "$pkg"
        done
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
DEST_DIR="$HOME/.local/bin/mpv"
mkdir -p "$DEST_DIR"

echo -e "${CYAN}📦 Installing core executables...${NC}"
cp -r q q_modules "$DEST_DIR/"
chmod +x "$DEST_DIR/q"
echo -e "${GREEN}✅ q installed to $DEST_DIR${NC}"

# --- Configuration ---
CONF_DIR="$HOME/.config/mpv"
mkdir -p "$CONF_DIR"
if [ ! -f "$CONF_DIR/mpv.conf" ]; then
    cp mpv.conf.example "$CONF_DIR/mpv.conf"
    echo -e "${GREEN}✅ Installed default mpv.conf${NC}"
else
    echo -e "${YELLOW}ℹ️  ~/.config/mpv/mpv.conf already exists. Keeping yours.${NC}"
fi

# --- YT-DLP Configuration ---
YTDLP_CONF_DIR="$HOME/.config/yt-dlp"
mkdir -p "$YTDLP_CONF_DIR"
if ! grep -q -- "--js-runtimes node" "$YTDLP_CONF_DIR/config" 2>/dev/null; then
    echo -e "${CYAN}🔧 Configuring yt-dlp to use Node.js for YouTube decryption...${NC}"
    echo "--js-runtimes node" >> "$YTDLP_CONF_DIR/config"
    echo -e "${GREEN}✅ yt-dlp configuration updated.${NC}"
fi

# --- Playlists ---
PLAYLIST_DEST="$HOME/.local/share/mpv/playlists"
mkdir -p "$PLAYLIST_DEST"
if [ -d "playlists" ]; then
    cp -rn playlists/* "$PLAYLIST_DEST/" 2>/dev/null || true
    echo -e "${GREEN}✅ Bundled playlists safely integrated into $PLAYLIST_DEST${NC}"
fi

# --- Shell Wrapper & PATH ---
SHELL_RC=""
[[ "$SHELL" == */zsh ]] && SHELL_RC="$HOME/.zshrc"
[[ "$SHELL" == */bash ]] && SHELL_RC="$HOME/.bashrc"
[ -z "$SHELL_RC" ] && [ -f "$HOME/.bashrc" ] && SHELL_RC="$HOME/.bashrc"

if [ -n "$SHELL_RC" ]; then
    # PATH Marker
    if ! grep -q "# --- Q PATH START ---" "$SHELL_RC"; then
        echo -e "\n# --- Q PATH START ---" >> "$SHELL_RC"
        echo "export PATH=\"\$PATH:$DEST_DIR\"" >> "$SHELL_RC"
        echo "# --- Q PATH END ---" >> "$SHELL_RC"
        echo -e "${GREEN}✅ Added $DEST_DIR to PATH in $SHELL_RC${NC}"
    fi

    # MPV Wrapper Marker
    if ! grep -q "function mpv()" "$SHELL_RC" && ! grep -q "# --- Q MPV WRAPPER START ---" "$SHELL_RC"; then
        echo -e "${CYAN}🔧 Injecting mandatory mpv IPC wrapper function...${NC}"
        cat << 'EOF' >> "$SHELL_RC"

# --- Q MPV WRAPPER START ---
function mpv() {
    if command -v termux-wake-lock >/dev/null 2>&1; then termux-wake-lock; fi
    SOCKET="$HOME/.mpv-socket"
    if [ -e "$SOCKET" ]; then rm "$SOCKET"; fi
    command mpv --idle --input-ipc-server="$SOCKET" "$@"
    rm -f "$SOCKET"
    if command -v termux-wake-unlock >/dev/null 2>&1; then termux-wake-unlock; fi
}
if [ -n "$BASH_VERSION" ]; then
    export -f mpv
fi
# --- Q MPV WRAPPER END ---
EOF
        echo -e "${GREEN}✅ Wrapper injected into $SHELL_RC${NC}"
    fi
    echo -e "${CYAN}👉 Note: Run 'source $SHELL_RC' or restart terminal to apply changes.${NC}"
fi

echo -e "${GREEN}✨ Installation flawlessly finished! Type 'q' to start.${NC}"
