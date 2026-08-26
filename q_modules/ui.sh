# ANSI Colors (Using ANSI-C quoting for real escape characters)
C_RESET=$'\e[0m'
C_GRAY=$'\e[0;90m'
C_CYAN=$'\e[1;36m'
C_GREEN=$'\e[1;32m'
C_YELLOW=$'\e[1;33m'
C_ORANGE=$'\e[38;5;215m' # Light Orange
C_PINK=$'\e[38;5;198m'
C_LIGHT_PINK=$'\e[38;5;211m'
C_PURPLE=$'\e[1;38;5;171m' # Vibrant Purple
C_VIOLET=$'\e[38;5;129m'   # Violet
C_TEAL=$'\e[1;38;5;37m'    # Teal
C_WHITE=$'\e[1;37m'
C_BOLD=$'\e[1m'

# Unified FZF theme matching terminal color variables
FZF_COLOR_OPTS="--color=fg:#00ffff,hl:#ff1493,fg+:#00ffff,hl+:#ff1493,pointer:#ff1493,marker:#ff1493,border:#8700ff,header:#d75fff,prompt:#008787"

get_clipboard() {
    if command -v termux-clipboard-get >/dev/null; then
        termux-clipboard-get
    elif command -v powershell.exe >/dev/null; then
        # WSL: Use PowerShell to get Windows clipboard
        powershell.exe -NoProfile -Command "Get-Clipboard" | tr -d '\r'
    elif command -v xclip >/dev/null; then
        xclip -selection clipboard -o 2>/dev/null
    elif command -v pbpaste >/dev/null; then
        pbpaste
    fi
}

check_dependencies() {
    local missing=()
    command -v mpv >/dev/null || missing+=("mpv")
    if ! command -v yt-dlp >/dev/null || ! yt-dlp --version >/dev/null 2>&1; then
        if ! python3 -m yt_dlp --version >/dev/null 2>&1; then
            missing+=("yt-dlp (broken/missing)")
        fi
    fi
    command -v fzf >/dev/null || missing+=("fzf")
    command -v jq >/dev/null || missing+=("jq")
    command -v nc >/dev/null || missing+=("netcat")
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${C_PINK}❌ Missing or Broken Dependencies:${C_RESET} ${missing[*]}"
        
        if command -v pkg >/dev/null && [ -d "/data/data/com.termux" ]; then
            echo -e "${C_GRAY}Fix/Install on Termux with:${C_RESET}"
            echo -e "  ${C_CYAN}pkg install -y python python-pip && pip install -U --force-reinstall yt-dlp${C_RESET}"
        else
            echo -e "${C_GRAY}Install on Linux/WSL with:${C_RESET}"
            echo -e "  ${C_CYAN}sudo apt update && sudo apt install mpv fzf jq netcat-openbsd ffmpeg${C_RESET}"
            echo -e "  ${C_CYAN}pip install -U yt-dlp || sudo wget https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -O /usr/local/bin/yt-dlp${C_RESET}"
            echo -e "  ${C_CYAN}sudo chmod a+rx /usr/local/bin/yt-dlp${C_RESET}"
        fi
        return 1
    fi
    echo -e "${C_GREEN}✅ All core dependencies are installed and functioning:${C_RESET} ${C_CYAN}mpv, yt-dlp, fzf, jq, netcat${C_RESET}"
    return 0
}

cmd_update_ytdlp() {
    echo -e "${C_CYAN}──────────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e "${C_PINK}🚀 Updating yt-dlp & Queue Engine...${C_RESET}"
    echo -e "${C_CYAN}──────────────────────────────────────────────────────────────────────────────${C_RESET}"
    
    # 1. Update yt-dlp
    echo -e "${C_CYAN}📦 [1/2] Updating yt-dlp...${C_RESET}"
    local ytdl_updated=false
    
    if command -v pkg >/dev/null 2>&1 && [ -d "/data/data/com.termux" ]; then
        # Termux environment: prioritize pip with force-reinstall to prevent broken site-packages
        if pip install -U --force-reinstall yt-dlp 2>/dev/null || pip3 install -U --force-reinstall yt-dlp 2>/dev/null; then
            local new_ver=$(yt-dlp --version 2>/dev/null || python3 -m yt_dlp --version 2>/dev/null)
            echo -e "${C_GREEN}✅ yt-dlp updated for Termux: ${C_YELLOW}${new_ver}${C_RESET}"
            ytdl_updated=true
        fi
    fi

    if [ "$ytdl_updated" = false ]; then
        if yt-dlp -U 2>/dev/null; then
            local new_ver=$(yt-dlp --version 2>/dev/null)
            echo -e "${C_GREEN}✅ yt-dlp is up to date: ${C_YELLOW}${new_ver}${C_RESET}"
            ytdl_updated=true
        elif pip install -U yt-dlp 2>/dev/null || pip3 install -U yt-dlp 2>/dev/null || pip install -U yt-dlp --user 2>/dev/null; then
            local new_ver=$(yt-dlp --version 2>/dev/null || python3 -m yt_dlp --version 2>/dev/null)
            echo -e "${C_GREEN}✅ yt-dlp updated via pip: ${C_YELLOW}${new_ver}${C_RESET}"
            ytdl_updated=true
        elif mkdir -p "$HOME/.local/bin" && { curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o "$HOME/.local/bin/yt-dlp" 2>/dev/null || wget https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -O "$HOME/.local/bin/yt-dlp" 2>/dev/null; }; then
            chmod +x "$HOME/.local/bin/yt-dlp"
            command -v termux-fix-shebang >/dev/null 2>&1 && termux-fix-shebang "$HOME/.local/bin/yt-dlp" 2>/dev/null
            local new_ver=$("$HOME/.local/bin/yt-dlp" --version 2>/dev/null)
            echo -e "${C_GREEN}✅ yt-dlp updated to latest official version: ${C_YELLOW}${new_ver}${C_RESET}"
            ytdl_updated=true
        fi
    fi
    [ "$ytdl_updated" = false ] && echo -e "${C_ORANGE}⚠️ Could not auto-update yt-dlp.${C_RESET}"

    # 2. Update Queue Engine directly into ~/.local/bin/mpv/
    echo -e "${C_CYAN}📦 [2/2] Updating Queue Engine from GitHub...${C_RESET}"
    local dest_dir="$HOME/.local/bin/mpv"
    mkdir -p "$dest_dir/q_modules"
    
    local files=("q" "q_modules/ui.sh" "q_modules/utils.sh" "q_modules/media.sh" "q_modules/queue.sh" "q_modules/search.sh" "q_modules/batch.sh" "q_modules/playlist.sh")
    local success=true
    local base_url="https://raw.githubusercontent.com/ravin-ship-it/queue/main"
    
    for f in "${files[@]}"; do
        if curl -sSL -f "${base_url}/${f}" -o "${dest_dir}/${f}.tmp" 2>/dev/null; then
            mv "${dest_dir}/${f}.tmp" "${dest_dir}/${f}"
        else
            success=false
            rm -f "${dest_dir}/${f}.tmp"
        fi
    done
    
    if [ "$success" = true ]; then
        chmod +x "$dest_dir/q"
        mkdir -p "$HOME/.local/bin"
        ln -sf "$dest_dir/q" "$HOME/.local/bin/q"
        echo -e "${C_GREEN}✅ Queue Engine successfully updated to latest version!${C_RESET}"
    else
        echo -e "${C_ORANGE}⚠️ Failed to fetch Queue updates from GitHub. Check your connection.${C_RESET}"
    fi
    echo -e "${C_CYAN}──────────────────────────────────────────────────────────────────────────────${C_RESET}"
}

get_terminal_width() {
    local w="${COLUMNS:-}"
    if [[ "$w" =~ ^[0-9]+$ ]] && [ "$w" -ge 20 ]; then
        echo "$w"
        return
    fi
    w=$(tput cols 2>/dev/null)
    [[ ! "$w" =~ ^[0-9]+$ ]] && w="${COLUMNS:-80}"
    [ "$w" -lt 20 ] 2>/dev/null && w=80
    echo "$w"
}

TERM_WIDTH=$(get_terminal_width)
[ "$TERM_WIDTH" -lt 40 ] && TERM_WIDTH=40
BOX_WIDTH=$((TERM_WIDTH - 2))
INNER_WIDTH=$((BOX_WIDTH - 4)) 

# Create Horizontal Lines
printf -v H_LINE "%*s" "$((TERM_WIDTH))" ""
H_LINE=${H_LINE// /─}

strip_colors() {
    # Strip real ESC (x1B) sequences
    echo "$1" | sed "s/$(echo -e '\033')\[[0-9;]*[a-zA-Z]//g"
}

get_visual_width() {
    echo -n "$1" | wc -L
}

print_header_box() {
    local title="$1"
    local width=$TERM_WIDTH
    [ -z "$width" ] && width=80
    
    printf -v T_LINE "╭%*s╮" "$((width - 2))" ""
    T_LINE=${T_LINE// /─}
    printf -v M_LINE "├%*s┤" "$((width - 2))" ""
    M_LINE=${M_LINE// /─}
    
    echo -e "${C_PURPLE}${T_LINE}${C_RESET}"
    local visible_text=$(strip_colors "$title")
    local visible_width=$(get_visual_width "$visible_text")
    local pad_len=$((width - visible_width - 4))
    [ $pad_len -lt 0 ] && pad_len=0
    printf -v PADDING "%*s" "$pad_len" ""
    echo -e "${C_PURPLE}│${C_RESET} ${title}${PADDING} ${C_PURPLE}│${C_RESET}"
    echo -e "${C_PURPLE}${M_LINE}${C_RESET}"
}

print_boxed_line() {
    local content="$1"
    local borderless="${2:-false}"
    
    if [ "$borderless" == "true" ]; then
        printf " %b\n" "$content"
    else
        local visible_content=$(strip_colors "$content")
        local visible_width=$(get_visual_width "$visible_content")
        local pad_len=$((TERM_WIDTH - visible_width - 4))
        [ $pad_len -lt 0 ] && pad_len=0
        printf -v PADDING "%*s" "$pad_len" ""
        printf "${C_PURPLE}│${C_RESET} %b%s ${C_PURPLE}│${C_RESET}\n" "$content" "$PADDING"
    fi
}

truncate_text() {
    local text="$1"
    local max_len="$2"
    local width=$(get_visual_width "$text")
    if [ "$width" -gt "$max_len" ]; then
        local truncated="$text"
        while [ $(get_visual_width "${truncated}...") -gt "$max_len" ] && [ ${#truncated} -gt 0 ]; do
            truncated="${truncated:0:-1}"
        done
        echo "${truncated}..."
    else
        echo "$text"
    fi
}

get_input() {
    local header="$1"
    local prompt="${2:-Name > }"
    local tmp=$(mktemp)
    # Use fzf as a polished input box. 
    # IMPORTANT: We redirect stdin from /dev/tty for the interactive part 
    # while providing /dev/null for the item list.
    fzf --header "  $header" --prompt "  $prompt" \
        --height=5 --layout=reverse --border --info=hidden \
        $FZF_COLOR_OPTS \
        --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
        --print-query < /dev/null > "$tmp" < /dev/tty
    
    local exit_code=$?
    # fzf returns 1 if no match is selected (always true here), 
    # but 130 if cancelled (ESC). 0 or 1 means query captured.
    if [ "$exit_code" -eq 0 ] || [ "$exit_code" -eq 1 ]; then
        head -n1 "$tmp"
    else
        echo ""
    fi
    rm -f "$tmp"
    # Small breather for terminal restoration
    sleep 0.1
}

show_help() {
    print_header_box "${C_CYAN}🎵 MPV Queue Manager Help${C_RESET}"
    print_boxed_line "${C_BOLD}Usage:${C_RESET}"
    print_boxed_line "  q               Interactive Queue (fzf)"
    print_boxed_line "  q <url>         Add URL/File to queue"
    print_boxed_line "  q <query>       Search and select to queue"
    print_boxed_line ""
    print_boxed_line "${C_YELLOW}Commands:${C_RESET}"
    print_boxed_line "  -i [N|url]      Metadata & Download Info (Synced Resolution)"
    print_boxed_line "  -p [N]          Play/Pause or Jump to track N ${C_GRAY}(Supports: 10+5)${C_RESET}"
    print_boxed_line "  -next / -prev   Next/Prev track ${C_GRAY}(Synced Logs)${C_RESET}"
    print_boxed_line "  -stop           Stop (Quit) MPV"
    print_boxed_line "  -v [N]          Volume Control (Show or Set to N)"
    print_boxed_line "  -fx [mode]      Audio FX: on | off | toggle | status"
    print_boxed_line "  -mv <A> <B>     Move track A to B"
    print_boxed_line "  -sw <A> <B>     Swap track A and B"
    print_boxed_line "  -rname <O> <N>  Rename playlist or local file"
    print_boxed_line "  -rm [N|txt]     Remove track ${C_GRAY}(Defaults to Current)${C_RESET}"
    print_boxed_line "  -rmr            Remove redundant tracks (dupes)"
    print_boxed_line "  -clean          Remove Private/Deleted videos"
    print_boxed_line "  -l / -lp        Toggle Loop (Track / Playlist)"
    print_boxed_line "  -shuf [list]    Shuffle Mode or actual Queue Entries"
    print_boxed_line "  -clr            Clear entire queue"
    print_boxed_line "  -auto           Toggle Auto-Discovery (24/7 Related Hits)"
    print_boxed_line "  -deps           Check dependencies (WSL/Android)"
    print_boxed_line "  -up             Update yt-dlp"
    print_boxed_line "  -raw            Raw Queue output (for scripts)"
    print_boxed_line ""
    print_boxed_line "${C_YELLOW}Custom Playlists:${C_RESET}"
    print_boxed_line "  -pl-save <N>    Save current queue as <N>"
    print_boxed_line "  -pl-load [N]    Load playlist(s) ${C_GRAY}(FZF Menu if empty)${C_RESET}"
    print_boxed_line "  -pl-list        List saved playlists (Interactive Explorer)"
    print_boxed_line "  -pl-raw [N]     List playlists or contents (Raw)"
    print_boxed_line "  -pl-rm <N>      Delete playlist <N>"
    print_boxed_line "  -pl-clean <N>   Remove dead tracks from playlist <N>"
    print_boxed_line "  -pl-rmr <N>     Remove duplicates from playlist <N>"
    print_boxed_line "  -to <N>         Dir. search results to playlist <N>"
    print_boxed_line ""
    print_boxed_line "${C_YELLOW}Interactive (FZF) Controls:${C_RESET}"
    print_boxed_line "  TAB             Select / Mark track ${C_GRAY}(Triggers Action Menu)${C_RESET}"
    print_boxed_line "  ALT-A           Toggle Selection (Invert All)"
    print_boxed_line "  INSERT          Select All"
    print_boxed_line "  DELETE          Deselect All"
    print_boxed_line "  ENTER           Direct Play ${C_GRAY}(or Action Menu if tracks selected)${C_RESET}"
    print_boxed_line ""
    print_boxed_line "${C_YELLOW}Searching:${C_RESET}"
    print_boxed_line "  q yt <q>        Force YouTube search"
    print_boxed_line "  q sc <q>        Force Soundcloud search"
    printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
    B_LINE=${B_LINE// /─}
    echo -e "${C_GRAY}${B_LINE}${C_RESET}"
}
