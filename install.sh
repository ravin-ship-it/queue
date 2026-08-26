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
        pkg install -y coreutils ca-certificates openssl-tool python python-pip
        for pkg in "${missing[@]}"; do
            [ "$pkg" == "netcat" ] && pkg="netcat-openbsd"
            [ "$pkg" == "yt-dlp" ] && continue # Handled via pip below
            pkg install -y "$pkg"
        done
        # Termux apt package for yt-dlp is often broken with Python 3.14; always install/heal via pip
        echo -e "${CYAN}🔧 Installing/Healing yt-dlp via pip for Termux Python...${NC}"
        pip install -U --force-reinstall yt-dlp || pkg install -y yt-dlp || true
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
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/.local/bin/mpv"
mkdir -p "$DEST_DIR"
mkdir -p "$HOME/.local/bin"

echo -e "${CYAN}📦 Installing Queue engine into $DEST_DIR...${NC}"
# Clean existing symlinks/files in destination before copying permanent files
rm -rf "$DEST_DIR/q" "$DEST_DIR/q_modules"
cp -r "$REPO_DIR/q" "$REPO_DIR/q_modules" "$DEST_DIR/"
chmod +x "$DEST_DIR/q"

# Link ~/.local/bin/q to the permanent destination
ln -sf "$DEST_DIR/q" "$HOME/.local/bin/q"

echo -e "${GREEN}✅ Queue installed permanently to $DEST_DIR (symlinked to ~/.local/bin/q)${NC}"
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

# --- YT-DLP Configuration ---
YTDLP_CONF_DIR="$HOME/.config/yt-dlp"
mkdir -p "$YTDLP_CONF_DIR"
cat << 'EOF' > "$YTDLP_CONF_DIR/config"
--js-runtimes node
--extractor-args "youtube:player_client=android,web"
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

# --- Shell Wrapper & PATH ---
SHELL_RC=""
[[ "$SHELL" == */zsh ]] && SHELL_RC="$HOME/.zshrc"
[[ "$SHELL" == */bash ]] && SHELL_RC="$HOME/.bashrc"
[ -z "$SHELL_RC" ] && [ -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.zshrc"
[ -z "$SHELL_RC" ] && SHELL_RC="$HOME/.bashrc"

if [ -n "$SHELL_RC" ]; then
    # Ensure the RC file exists before grepping
    [ ! -f "$SHELL_RC" ] && touch "$SHELL_RC"

    # PATH Marker
    if ! grep -q "# --- Q PATH START ---" "$SHELL_RC" 2>/dev/null; then
        echo -e "\n# --- Q PATH START ---" >> "$SHELL_RC"
        echo "export PATH=\"\$PATH:\$HOME/.local/bin:$DEST_DIR\"" >> "$SHELL_RC"
        echo "# --- Q PATH END ---" >> "$SHELL_RC"
        echo -e "${GREEN}✅ Added $DEST_DIR and ~/.local/bin to PATH in $SHELL_RC${NC}"
    fi

    # MPV Wrapper Marker
    if grep -q "# --- Q MPV WRAPPER START ---" "$SHELL_RC" 2>/dev/null; then
        sed -i '/# --- Q MPV WRAPPER START ---/,/# --- Q MPV WRAPPER END ---/d' "$SHELL_RC"
    fi
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
