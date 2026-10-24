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
    if command -v termux-clipboard-get >/dev/null 2>&1; then
        termux-clipboard-get
    elif [ "$IS_MACOS" = true ] && command -v pbpaste >/dev/null 2>&1; then
        pbpaste
    elif [ "$IS_WSL" = true ] && command -v powershell.exe >/dev/null 2>&1; then
        # WSL: Use PowerShell to get Windows clipboard
        powershell.exe -NoProfile -Command "Get-Clipboard" | tr -d '\r'
    elif [ -n "$WAYLAND_DISPLAY" ] && command -v wl-paste >/dev/null 2>&1; then
        wl-paste 2>/dev/null
    elif command -v xclip >/dev/null 2>&1; then
        xclip -selection clipboard -o 2>/dev/null
    elif command -v xsel >/dev/null 2>&1; then
        xsel --clipboard --output 2>/dev/null
    elif command -v pbpaste >/dev/null 2>&1; then
        pbpaste
    elif command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "Get-Clipboard" | tr -d '\r'
    fi
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

strip_colors() {
    # Strip real ESC (x1B) sequences
    echo "$1" | sed "s/$(echo -e '\033')\[[0-9;]*[a-zA-Z]//g"
}

get_visual_width() {
    echo -n "$1" | wc -L
}

TERM_WIDTH=$(get_terminal_width)
[ "$TERM_WIDTH" -lt 40 ] && TERM_WIDTH=40
BOX_WIDTH=$((TERM_WIDTH - 2))
INNER_WIDTH=$((BOX_WIDTH - 4))

printf -v H_LINE "%*s" "$((TERM_WIDTH))" ""
H_LINE=${H_LINE// /─}

print_header_box() {
    local title="$1"
    local width=$(get_terminal_width)
    [ -z "$width" ] || [ "$width" -lt 40 ] && width=80
    
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
    local width=$(get_terminal_width)
    [ -z "$width" ] || [ "$width" -lt 40 ] && width=80
    
    if [ "$borderless" == "true" ]; then
        printf " %s\n" "$content"
    else
        local visible_content=$(strip_colors "$content")
        local visible_width=$(get_visual_width "$visible_content")
        local pad_len=$((width - visible_width - 4))
        [ $pad_len -lt 0 ] && pad_len=0
        printf -v PADDING "%*s" "$pad_len" ""
        printf "${C_PURPLE}│${C_RESET} %s%s ${C_PURPLE}│${C_RESET}\n" "$content" "$PADDING"
    fi
}

check_dependencies() {
    local width=$(get_terminal_width)
    [ -z "$width" ] || [ "$width" -lt 40 ] && width=80
    printf -v H_LINE "%*s" "$((width - 2))" ""
    H_LINE=${H_LINE// /─}

    print_header_box "${C_PINK}🔍 Queue System & Dependencies Diagnostic${C_RESET}"

    # 1. Core Runtime Dependencies
    print_boxed_line "${C_BOLD}${C_CYAN}Core Runtime Engine:${C_RESET}"
    local core_missing=()

    # mpv
    if command -v mpv >/dev/null 2>&1; then
        local mpv_ver=$(mpv --version 2>/dev/null | head -n1 | awk '{print $1" "$2}')
        local mpv_path=$(command -v mpv)
        print_boxed_line "  ${C_TEAL}MPV Backend:     ${C_GREEN}Installed ✅${C_RESET} ${C_GRAY}(${mpv_ver} • ${mpv_path})${C_RESET}"
    else
        core_missing+=("mpv")
        print_boxed_line "  ${C_TEAL}MPV Backend:     ${C_PINK}Missing ❌${C_RESET} ${C_GRAY}(Core media player engine)${C_RESET}"
    fi

    # yt-dlp
    local ytdl_cmd=""
    if command -v yt-dlp >/dev/null 2>&1 && yt-dlp --version >/dev/null 2>&1; then
        ytdl_cmd="yt-dlp"
    elif python3 -m yt_dlp --version >/dev/null 2>&1; then
        ytdl_cmd="python3 -m yt_dlp"
    fi

    if [ -n "$ytdl_cmd" ]; then
        local ytdl_ver=$($ytdl_cmd --version 2>/dev/null)
        local ytdl_path=$(command -v yt-dlp 2>/dev/null || echo "python3 module")
        print_boxed_line "  ${C_TEAL}yt-dlp Streamer: ${C_GREEN}Installed ✅${C_RESET} ${C_GRAY}(v${ytdl_ver} • ${ytdl_path})${C_RESET}"
    else
        core_missing+=("yt-dlp")
        print_boxed_line "  ${C_TEAL}yt-dlp Streamer: ${C_PINK}Missing ❌${C_RESET} ${C_GRAY}(Streams YouTube & SoundCloud)${C_RESET}"
    fi

    # JavaScript Runtime (yt-dlp YouTube decryption)
    local js_rt=""
    for js in node deno bun qjs; do
        if command -v "$js" >/dev/null 2>&1; then
            js_rt="$js"
            break
        fi
    done
    if [ -n "$js_rt" ]; then
        local js_ver=$("$js_rt" --version 2>/dev/null || echo "")
        print_boxed_line "  ${C_TEAL}JS Decryptor:    ${C_GREEN}Ready ✅${C_RESET} ${C_GRAY}(${js_rt} ${js_ver} • Anti-bot cipher shield)${C_RESET}"
    else
        print_boxed_line "  ${C_TEAL}JS Decryptor:    ${C_ORANGE}Optional ⚠️${C_RESET} ${C_GRAY}(Install node/deno to bypass YouTube 403 throttles)${C_RESET}"
    fi

    # fzf
    if command -v fzf >/dev/null 2>&1; then
        local fzf_ver=$(fzf --version 2>/dev/null | awk '{print $1}')
        local fzf_path=$(command -v fzf)
        print_boxed_line "  ${C_TEAL}FZF Search TUI:  ${C_GREEN}Installed ✅${C_RESET} ${C_GRAY}(v${fzf_ver} • ${fzf_path})${C_RESET}"
    else
        core_missing+=("fzf")
        print_boxed_line "  ${C_TEAL}FZF Search TUI:  ${C_PINK}Missing ❌${C_RESET} ${C_GRAY}(Interactive queue explorer)${C_RESET}"
    fi

    # jq
    if command -v jq >/dev/null 2>&1; then
        local jq_ver=$(jq --version 2>/dev/null)
        local jq_path=$(command -v jq)
        print_boxed_line "  ${C_TEAL}jq JSON Parser:  ${C_GREEN}Installed ✅${C_RESET} ${C_GRAY}(${jq_ver} • ${jq_path})${C_RESET}"
    else
        core_missing+=("jq")
        print_boxed_line "  ${C_TEAL}jq JSON Parser:  ${C_PINK}Missing ❌${C_RESET} ${C_GRAY}(IPC response processor)${C_RESET}"
    fi

    # netcat
    if command -v nc >/dev/null 2>&1 || command -v ncat >/dev/null 2>&1; then
        local nc_path=$(command -v nc 2>/dev/null || command -v ncat 2>/dev/null)
        print_boxed_line "  ${C_TEAL}Netcat (IPC):    ${C_GREEN}Installed ✅${C_RESET} ${C_GRAY}(${nc_path})${C_RESET}"
    else
        core_missing+=("netcat")
        print_boxed_line "  ${C_TEAL}Netcat (IPC):    ${C_PINK}Missing ❌${C_RESET} ${C_GRAY}(Socket communication bridge)${C_RESET}"
    fi

    # ffmpeg
    if command -v ffmpeg >/dev/null 2>&1; then
        local ff_path=$(command -v ffmpeg)
        print_boxed_line "  ${C_TEAL}FFmpeg Codecs:   ${C_GREEN}Installed ✅${C_RESET} ${C_GRAY}(${ff_path})${C_RESET}"
    else
        print_boxed_line "  ${C_TEAL}FFmpeg Codecs:   ${C_ORANGE}Recommended ⚠️${C_RESET} ${C_GRAY}(Recommended for audio transcoding & downloads)${C_RESET}"
    fi

    echo -e "${C_PURPLE}├${H_LINE}┤${C_RESET}"

    # 2. Platform & Engine Mode Diagnostics
    local cur_mode=$(get_queue_mode)
    if [ "$IS_WSL" = true ]; then
        print_boxed_line "${C_BOLD}${C_CYAN}Windows + WSL2 Environment Diagnostics:${C_RESET}"
        if [ "$cur_mode" == "hybrid" ]; then
            print_boxed_line "  ${C_TEAL}Active Engine:   ${C_ORANGE}Hybrid Boost Mode ⚡ (120+ FPS Direct3D & WASAPI)${C_RESET}"
        else
            print_boxed_line "  ${C_TEAL}Active Engine:   ${C_CYAN}Standalone WSL Mode 🐧 (60 FPS WSLg Compositor)${C_RESET}"
        fi

        # WSLg Direct3D12 check
        if [ -d "/usr/lib/wsl/lib" ]; then
            print_boxed_line "  ${C_TEAL}WSLg Direct3D12: ${C_GREEN}Available ✅${C_RESET} ${C_GRAY}(Mesa D3D12 hardware GPU driver)${C_RESET}"
        else
            print_boxed_line "  ${C_TEAL}WSLg Direct3D12: ${C_ORANGE}Not Detected ⚠️${C_RESET} ${C_GRAY}(WSLg GPU acceleration missing)${C_RESET}"
        fi

        # Hybrid Windows Host checks
        local win_mpv=$(find_windows_mpv)
        if [ -n "$win_mpv" ]; then
            print_boxed_line "  ${C_TEAL}Windows Host MPV:${C_GREEN}Installed ✅${C_RESET} ${C_GRAY}(${win_mpv})${C_RESET}"
        else
            print_boxed_line "  ${C_TEAL}Windows Host MPV:${C_PINK}Not Found ❌${C_RESET} ${C_GRAY}(Run: winget install shinchiro.mpv)${C_RESET}"
        fi

        local win_ytdlp=$(find_windows_ytdlp)
        if [ -n "$win_ytdlp" ]; then
            print_boxed_line "  ${C_TEAL}Windows yt-dlp:  ${C_GREEN}Installed ✅${C_RESET} ${C_GRAY}(${win_ytdlp})${C_RESET}"
        else
            print_boxed_line "  ${C_TEAL}Windows yt-dlp:  ${C_ORANGE}Not Found ⚠️${C_RESET} ${C_GRAY}(Run: winget install yt-dlp.yt-dlp)${C_RESET}"
        fi

        local relay_bin=$(ensure_piperelay_compiled 2>/dev/null)
        if [ -n "$relay_bin" ] && [ -f "$relay_bin" ]; then
            print_boxed_line "  ${C_TEAL}PipeRelay.exe:   ${C_GREEN}Ready ✅${C_RESET} ${C_GRAY}(Sub-millisecond Windows Named Pipe bridge)${C_RESET}"
        else
            print_boxed_line "  ${C_TEAL}PipeRelay.exe:   ${C_PINK}Missing ❌${C_RESET} ${C_GRAY}(Run ./install.sh to auto-compile)${C_RESET}"
        fi

        local win_u_dir=$(get_windows_user_dir)
        if [ -f "$win_u_dir/AppData/Roaming/mpv/scripts/queue_video.lua" ]; then
            print_boxed_line "  ${C_TEAL}Windows Scripts: ${C_GREEN}Synchronized ✅${C_RESET} ${C_GRAY}(%APPDATA%\\mpv\\scripts)${C_RESET}"
        else
            print_boxed_line "  ${C_TEAL}Windows Scripts: ${C_ORANGE}Not Synced ⚠️${C_RESET} ${C_GRAY}(Run ./install.sh to sync)${C_RESET}"
        fi

        if [ -f "$win_u_dir/AppData/Roaming/mpv/input.conf" ]; then
            print_boxed_line "  ${C_TEAL}Windows Keys:    ${C_GREEN}Synchronized ✅${C_RESET} ${C_GRAY}(%APPDATA%\\mpv\\input.conf)${C_RESET}"
        else
            print_boxed_line "  ${C_TEAL}Windows Keys:    ${C_ORANGE}Not Synced ⚠️${C_RESET} ${C_GRAY}(Run ./install.sh to sync)${C_RESET}"
        fi

    elif [ "$IS_ANDROID" = true ]; then
        print_boxed_line "${C_BOLD}${C_CYAN}Android / Termux Mobile Diagnostics:${C_RESET}"
        if [ "$cur_mode" == "hybrid" ]; then
            print_boxed_line "  ${C_TEAL}Active Engine:   ${C_ORANGE}Hybrid Mobile Mode 🤖⚡ (Play Store MPV App)${C_RESET}"
        else
            print_boxed_line "  ${C_TEAL}Active Engine:   ${C_CYAN}Standalone Termux Mode 🐧 (Headless Audio)${C_RESET}"
        fi

        # Termux API
        if command -v termux-battery-status >/dev/null 2>&1 || [ -f "$PREFIX/bin/termux-battery-status" ]; then
            print_boxed_line "  ${C_TEAL}Termux:API:      ${C_GREEN}Installed ✅${C_RESET} ${C_GRAY}(Battery & hardware integration)${C_RESET}"
        else
            print_boxed_line "  ${C_TEAL}Termux:API:      ${C_ORANGE}Missing ⚠️${C_RESET} ${C_GRAY}(Install Termux:API app & pkg install termux-api)${C_RESET}"
        fi

        # Wake-Lock
        if command -v termux-wake-lock >/dev/null 2>&1; then
            print_boxed_line "  ${C_TEAL}CPU Wake-Lock:   ${C_GREEN}Available ✅${C_RESET} ${C_GRAY}(Prevents Android sleep during audio)${C_RESET}"
        else
            print_boxed_line "  ${C_TEAL}CPU Wake-Lock:   ${C_ORANGE}Missing ⚠️${C_RESET}"
        fi

        # Storage
        if [ -d "$HOME/storage/shared" ] || [ -d "/sdcard" ]; then
            print_boxed_line "  ${C_TEAL}Storage Access:  ${C_GREEN}Granted ✅${C_RESET} ${C_GRAY}(Shared storage accessible)${C_RESET}"
        else
            print_boxed_line "  ${C_TEAL}Storage Access:  ${C_PINK}Missing ❌${C_RESET} ${C_GRAY}(Run: termux-setup-storage)${C_RESET}"
        fi

        # Play Store MPV Android App
        local has_mpv_app=false
        if command -v pm >/dev/null 2>&1 && pm list packages 2>/dev/null | grep -q "is.xyz.mpv"; then
            has_mpv_app=true
        elif [ -d "/sdcard/mpv" ] || [ -d "/storage/emulated/0/mpv" ]; then
            has_mpv_app=true
        fi
        if [ "$has_mpv_app" = true ]; then
            print_boxed_line "  ${C_TEAL}MPV Android App: ${C_GREEN}Detected ✅${C_RESET} ${C_GRAY}('is.xyz.mpv' MediaCodec GPU ready)${C_RESET}"
        else
            print_boxed_line "  ${C_TEAL}MPV Android App: ${C_ORANGE}Not Detected ⚠️${C_RESET} ${C_GRAY}(Install from Play Store / F-Droid)${C_RESET}"
        fi

        # Lua Bridge
        if [ -f "/sdcard/mpv/scripts/queue_bridge.lua" ] || [ -f "$HOME/storage/shared/mpv/scripts/queue_bridge.lua" ]; then
            print_boxed_line "  ${C_TEAL}Lua Bridge:      ${C_GREEN}Installed ✅${C_RESET} ${C_GRAY}(/sdcard/mpv/scripts/queue_bridge.lua)${C_RESET}"
        else
            print_boxed_line "  ${C_TEAL}Lua Bridge:      ${C_ORANGE}Not Installed ⚠️${C_RESET} ${C_GRAY}(Run ./install.sh to configure)${C_RESET}"
        fi

    elif [ "$IS_MACOS" = true ]; then
        print_boxed_line "${C_BOLD}${C_CYAN}macOS Native Environment Diagnostics:${C_RESET}"
        local mac_ver=$(sw_vers -productVersion 2>/dev/null || uname -r)
        print_boxed_line "  ${C_TEAL}OS Version:      ${C_GREEN}macOS ${mac_ver} ✅${C_RESET}"
        print_boxed_line "  ${C_TEAL}Audio Pipeline:  ${C_GREEN}Native CoreAudio (ao=coreaudio) ✅${C_RESET}"
        print_boxed_line "  ${C_TEAL}GPU Acceleration:${C_GREEN}Native Cocoa / Metal (Direct 120+ FPS) ✅${C_RESET}"

    elif [ "$IS_LINUX" = true ]; then
        print_boxed_line "${C_BOLD}${C_CYAN}Native Linux Environment Diagnostics:${C_RESET}"
        if [ -n "$WAYLAND_DISPLAY" ]; then
            print_boxed_line "  ${C_TEAL}Display Server:  ${C_GREEN}Wayland (${WAYLAND_DISPLAY}) ✅${C_RESET}"
        elif [ -n "$DISPLAY" ]; then
            print_boxed_line "  ${C_TEAL}Display Server:  ${C_GREEN}X11 (${DISPLAY}) ✅${C_RESET}"
        else
            print_boxed_line "  ${C_TEAL}Display Server:  ${C_GRAY}Headless (Terminal Audio Only) ℹ️${C_RESET}"
        fi

        local audio_srv="ALSA"
        if pactl info 2>/dev/null | grep -qi "pipewire"; then
            audio_srv="PipeWire"
        elif pactl info 2>/dev/null | grep -qi "pulse"; then
            audio_srv="PulseAudio"
        fi
        print_boxed_line "  ${C_TEAL}Audio Backend:   ${C_GREEN}${audio_srv} ✅${C_RESET}"
        print_boxed_line "  ${C_TEAL}GPU Driver:      ${C_GREEN}Kernel Direct DRM (Mesa / NVIDIA) ✅${C_RESET}"
    fi

    printf -v B_LINE "╰%*s╯" "$((width - 2))" ""
    B_LINE=${B_LINE// /─}
    echo -e "${C_PURPLE}${B_LINE}${C_RESET}"

    if [ ${#core_missing[@]} -eq 0 ]; then
        echo -e "${C_GREEN}✨ All core dependencies are healthy and ready to stream!${C_RESET}"
        return 0
    else
        echo -e "${C_PINK}❌ Missing core dependencies: ${core_missing[*]}${C_RESET}"
        echo -e "${C_GRAY}👉 Run: ${C_WHITE}./install.sh${C_GRAY} to automatically install all missing components.${C_RESET}"
        return 1
    fi
}

cmd_update_ytdlp() {
    local width=$(get_terminal_width)
    [ -z "$width" ] || [ "$width" -lt 40 ] && width=80
    
    print_header_box "${C_PINK}🚀 Full System Upgrade — yt-dlp & Queue Engine${C_RESET}"
    
    # 1. Update yt-dlp (Universal across platforms)
    print_boxed_line "${C_BOLD}${C_CYAN}📦 [1/3] Updating yt-dlp Streaming Engine...${C_RESET}"
    local ytdl_updated=false
    
    if command -v pkg >/dev/null 2>&1 && [ -d "/data/data/com.termux" ]; then
        if pip install -U --force-reinstall yt-dlp 2>/dev/null || pip3 install -U --force-reinstall yt-dlp 2>/dev/null; then
            local new_ver=$(yt-dlp --version 2>/dev/null || python3 -m yt_dlp --version 2>/dev/null)
            print_boxed_line "  ${C_GREEN}✅ Termux yt-dlp updated:${C_RESET} ${C_YELLOW}v${new_ver}${C_RESET}"
            ytdl_updated=true
        fi
    fi

    if [ "$ytdl_updated" = false ]; then
        if yt-dlp -U 2>/dev/null; then
            local new_ver=$(yt-dlp --version 2>/dev/null)
            print_boxed_line "  ${C_GREEN}✅ yt-dlp binary updated:${C_RESET} ${C_YELLOW}v${new_ver}${C_RESET}"
            ytdl_updated=true
        elif pip install -U yt-dlp 2>/dev/null || pip3 install -U yt-dlp 2>/dev/null || pip install -U yt-dlp --user 2>/dev/null; then
            local new_ver=$(yt-dlp --version 2>/dev/null || python3 -m yt_dlp --version 2>/dev/null)
            print_boxed_line "  ${C_GREEN}✅ yt-dlp pip package updated:${C_RESET} ${C_YELLOW}v${new_ver}${C_RESET}"
            ytdl_updated=true
        elif mkdir -p "$HOME/.local/bin" && { curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o "$HOME/.local/bin/yt-dlp" 2>/dev/null || wget https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -O "$HOME/.local/bin/yt-dlp" 2>/dev/null; }; then
            chmod +x "$HOME/.local/bin/yt-dlp"
            command -v termux-fix-shebang >/dev/null 2>&1 && termux-fix-shebang "$HOME/.local/bin/yt-dlp" 2>/dev/null
            local new_ver=$("$HOME/.local/bin/yt-dlp" --version 2>/dev/null)
            print_boxed_line "  ${C_GREEN}✅ Standalone yt-dlp binary updated:${C_RESET} ${C_YELLOW}v${new_ver}${C_RESET}"
            ytdl_updated=true
        fi
    fi

    # Update Windows Host yt-dlp if on WSL2
    if [ "$IS_WSL" = true ]; then
        if cmd.exe /c "where winget" </dev/null >/dev/null 2>&1; then
            cmd.exe /c "winget upgrade yt-dlp.yt-dlp --accept-source-agreements --accept-package-agreements" </dev/null >/dev/null 2>&1 || true
        fi
        local win_ytdlp=$(find_windows_ytdlp)
        if [ -n "$win_ytdlp" ]; then
            print_boxed_line "  ${C_GREEN}✅ Windows Host yt-dlp verified:${C_RESET} ${C_YELLOW}${win_ytdlp}${C_RESET}"
        fi
    fi
    [ "$ytdl_updated" = false ] && print_boxed_line "  ${C_ORANGE}⚠️ Could not auto-update yt-dlp. Check network or package manager.${C_RESET}"

    # 2. Update Queue Engine directly into destination directory
    print_boxed_line "${C_BOLD}${C_CYAN}📦 [2/3] Fetching Latest Queue Engine Components from GitHub...${C_RESET}"
    local dest_dir="$HOME/.local/bin/mpv"
    mkdir -p "$dest_dir/q_modules" "$dest_dir/scripts" "$HOME/.config/mpv/scripts"
    
    local files=(
        "q"
        "q_modules/ui.sh"
        "q_modules/utils.sh"
        "q_modules/media.sh"
        "q_modules/queue.sh"
        "q_modules/search.sh"
        "q_modules/batch.sh"
        "q_modules/playlist.sh"
        "q_modules/download.sh"
        "q_modules/hybrid_bridge.py"
        "q_modules/android_stream_bridge.py"
        "scripts/PipeRelay.cs"
        "scripts/PipeRelay.ps1"
        "scripts/queue_video.lua"
        "scripts/queue_android_bridge.lua"
        "install.sh"
        "uninstall.sh"
        "setup.sh"
        "input.conf.example"
        "mpv.conf.example"
    )
    local success=true
    local base_url="https://raw.githubusercontent.com/ravin-ship-it/queue/main"
    
    for f in "${files[@]}"; do
        if curl -sSL -f -H "Cache-Control: no-cache" "${base_url}/${f}" -o "${dest_dir}/${f}.tmp" 2>/dev/null; then
            mv "${dest_dir}/${f}.tmp" "${dest_dir}/${f}"
        else
            success=false
            rm -f "${dest_dir}/${f}.tmp"
        fi
    done

    # 3. Mode-Specific & Host Re-Synchronization
    print_boxed_line "${C_BOLD}${C_CYAN}📦 [3/3] Synchronizing Environment & Engine Profiles...${C_RESET}"

    # Sync scripts and configs to user config
    if [ -f "$dest_dir/scripts/queue_video.lua" ]; then
        cp -f "$dest_dir/scripts/queue_video.lua" "$HOME/.config/mpv/scripts/queue_video.lua" 2>/dev/null || true
    fi
    if [ -f "$dest_dir/input.conf.example" ]; then
        cp -f "$dest_dir/input.conf.example" "$HOME/.config/mpv/input.conf" 2>/dev/null || true
    fi

    # Windows WSL2 Hybrid Sync
    if [ "$IS_WSL" = true ]; then
        local win_u_dir=$(get_windows_user_dir)
        if [ -n "$win_u_dir" ] && [ -d "$win_u_dir" ]; then
            local win_mpv_dir="$win_u_dir/AppData/Roaming/mpv"
            mkdir -p "$win_mpv_dir/scripts" 2>/dev/null
            cp -f "$dest_dir/scripts/queue_video.lua" "$win_mpv_dir/scripts/queue_video.lua" 2>/dev/null || true
            if [ -f "$dest_dir/input.conf.example" ]; then
                cp -f "$dest_dir/input.conf.example" "$win_mpv_dir/input.conf" 2>/dev/null || true
            fi
            # Recompile PipeRelay if needed
            local csc_comp="/mnt/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
            [ ! -f "$csc_comp" ] && csc_comp="/mnt/c/Windows/Microsoft.NET/Framework/v4.0.30319/csc.exe"
            if [ -f "$csc_comp" ] && [ -f "$dest_dir/scripts/PipeRelay.cs" ]; then
                cp -f "$dest_dir/scripts/PipeRelay.cs" "$win_u_dir/PipeRelay.cs" 2>/dev/null
                (cd "$win_u_dir" && "$csc_comp" /out:PipeRelay.exe /target:exe /nologo PipeRelay.cs </dev/null >/dev/null 2>&1)
                rm -f "$win_u_dir/PipeRelay.cs" 2>/dev/null
            fi
            [ -f "$dest_dir/scripts/PipeRelay.ps1" ] && cp -f "$dest_dir/scripts/PipeRelay.ps1" "$win_u_dir/PipeRelay.ps1" 2>/dev/null
            print_boxed_line "  ${C_GREEN}✅ Windows Hybrid Boost Mode host components re-synchronized!${C_RESET}"
        fi
    fi

    # Android Termux Mobile Sync
    if [ "$IS_ANDROID" = true ]; then
        for mpv_dir in "/sdcard/mpv" "/storage/emulated/0/mpv" "$HOME/storage/shared/mpv"; do
            if [ -d "$mpv_dir" ] || mkdir -p "$mpv_dir/scripts" 2>/dev/null; then
                cp -f "$dest_dir/scripts/queue_android_bridge.lua" "$mpv_dir/scripts/queue_bridge.lua" 2>/dev/null || true
                break
            fi
        done
        print_boxed_line "  ${C_GREEN}✅ Android Mobile Hybrid bridge re-synchronized!${C_RESET}"
    fi

    # Always ensure executable permissions and symlinks
    chmod +x "$dest_dir/q" "$dest_dir/q_modules/hybrid_bridge.py" "$dest_dir/q_modules/android_stream_bridge.py" 2>/dev/null || true
    chmod +x "$dest_dir/install.sh" "$dest_dir/uninstall.sh" "$dest_dir/setup.sh" 2>/dev/null || true
    mkdir -p "$HOME/.local/bin"
    ln -sf "$dest_dir/q" "$HOME/.local/bin/q"
    if [ -n "$PREFIX" ] && [ -d "$PREFIX/bin" ] && [ -w "$PREFIX/bin" ]; then
        ln -sf "$dest_dir/q" "$PREFIX/bin/q"
    fi
    if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
        ln -sf "$dest_dir/q" "/usr/local/bin/q" 2>/dev/null || true
    fi

    local new_q_ver
    new_q_ver=$(grep -m1 '^QUEUE_VERSION=' "$dest_dir/q_modules/utils.sh" 2>/dev/null | cut -d'"' -f2)
    [ -z "$new_q_ver" ] && new_q_ver="$QUEUE_VERSION"

    printf -v B_LINE "╰%*s╯" "$((width - 2))" ""
    B_LINE=${B_LINE// /─}
    echo -e "${C_PURPLE}${B_LINE}${C_RESET}"

    if [ "$success" = true ]; then
        echo -e "${C_GREEN}✨ Queue Engine successfully updated to ${C_YELLOW}v${new_q_ver}${C_GREEN} (All modes synced)!${C_RESET}"
    else
        echo -e "${C_ORANGE}⚠️ Failed to fetch some components from GitHub. Check network connection.${C_RESET}"
    fi
}

cmd_uninstall() {
    local uninstaller=""
    local dest_dir="$HOME/.local/bin/mpv"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    if [ -f "$script_dir/uninstall.sh" ]; then
        uninstaller="$script_dir/uninstall.sh"
    elif [ -f "$dest_dir/uninstall.sh" ]; then
        uninstaller="$dest_dir/uninstall.sh"
    fi

    if [ -n "$uninstaller" ]; then
        bash "$uninstaller" "$@"
        return $?
    fi

    echo -e "${C_CYAN}🗑️ Fetching official uninstaller from GitHub...${C_RESET}"
    if command -v curl >/dev/null 2>&1; then
        bash <(curl -fsSL "https://raw.githubusercontent.com/ravin-ship-it/queue/main/uninstall.sh") "$@"
    elif command -v wget >/dev/null 2>&1; then
        bash <(wget -qO- "https://raw.githubusercontent.com/ravin-ship-it/queue/main/uninstall.sh") "$@"
    else
        echo -e "${C_PINK}❌ Error: curl or wget is required to download uninstaller.${C_RESET}"
        return 1
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

show_version() {
    echo -e "${C_CYAN}🎵 Queue (q)${C_RESET} ${C_BOLD}v${QUEUE_VERSION}${C_RESET} ${C_GRAY}— The Ultimate MPV Music Engine${C_RESET}"
}

show_help() {
    print_header_box "${C_CYAN}🎵 MPV Queue Manager Help${C_RESET}"
    print_boxed_line "${C_BOLD}Usage:${C_RESET}"
    print_boxed_line "  q               Interactive Queue (fzf)"
    print_boxed_line "  q <url>         Add URL/File/Spotify track to queue"
    print_boxed_line "  q <query>       Search and select to queue"
    print_boxed_line ""
    print_boxed_line "${C_YELLOW}Commands:${C_RESET}"
    print_boxed_line "  -i [N|url]      Metadata & Track Inspector (Synced Resolution)"
    print_boxed_line "  -vid [sz|N]     Toggle Desktop Video Window ${C_GRAY}(small|med|large|F11)${C_RESET}"
    print_boxed_line "  -res [val]      Set/Check Video Quality ${C_GRAY}(low|mid|high|max|auto)${C_RESET}"
    print_boxed_line "  -speed [val]    Set/Check Playback Speed ${C_GRAY}(0.25-4.0x, reset, +/-0.1)${C_RESET}"
    print_boxed_line "  -lang [code]    Set/Inspect Audio Language & Dubs ${C_GRAY}(en|zh|ja|auto)${C_RESET}"
    if [ "$IS_ANDROID" = true ]; then
        print_boxed_line "  -hybrid [o|off] Toggle Dual-Engine: Standalone (Termux Audio) vs Hybrid (MPV App)"
    else
        print_boxed_line "  -hybrid [o|off] Toggle Dual-Engine: Standalone (60 FPS) vs Hybrid (120+ FPS)"
    fi
    print_boxed_line "  -d / -dl [N|u]  Interactive Downloader Hub (Format & Dir Wizard)"
    print_boxed_line "  -p [N]          Play/Pause or Jump to track N ${C_GRAY}(Supports: 10+5)${C_RESET}"
    print_boxed_line "  -pb [target]    Blind Mode: One-time isolated play ${C_GRAY}(pauses & auto-resumes queue)${C_RESET}"
    print_boxed_line "  -next / -prev   Next/Prev track ${C_GRAY}(Synced Logs)${C_RESET}"
    print_boxed_line "  -stop           Stop (Quit) MPV"
    print_boxed_line "  -v [N]          Volume Control (Show or Set to N)"
    print_boxed_line "  -fx [mode]      Audio FX: on | off | toggle | status"
    print_boxed_line "  -mv <A> <B>     Move track A to B"
    print_boxed_line "  -sw <A> <B>     Swap track A and B"
    print_boxed_line "  -rname <O> <N>  Rename playlist or local file"
    print_boxed_line "  -rm [N|txt]     Remove track ${C_GRAY}(Normal removal, no dislike)${C_RESET}"
    print_boxed_line "  -rmd [N|txt]    Remove & Dislike ${C_GRAY}(or -rm -dis, -rm -d)${C_RESET}"
    print_boxed_line "  -dis [N|txt]    Dislike track ${C_GRAY}(Blacklist without removing)${C_RESET}"
    print_boxed_line "  -disl           Interactive Dislike List Manager ${C_GRAY}(FZF Hub)${C_RESET}"
    print_boxed_line "  -undis [N|txt]  Remove from Dislike List ${C_GRAY}(Whitelist)${C_RESET}"
    print_boxed_line "  -rmr            Remove redundant tracks (dupes)"
    print_boxed_line "  -clean          Remove Private/Deleted videos"
    print_boxed_line "  -l / -lp        Toggle Loop (Track / Playlist)"
    print_boxed_line "  -shuf [list]    Shuffle Mode or actual Queue Entries"
    print_boxed_line "  -clr            Clear entire queue"
    print_boxed_line "  -auto           Toggle Auto-Discovery (24/7 Related Hits)"
    print_boxed_line "  -deps           System & Multi-Engine Dependencies Diagnostic"
    print_boxed_line "  -up             Full Queue & Engine Auto-Updater (yt-dlp + scripts)"
    print_boxed_line "  -install        Verify or reinstall Queue components"
    print_boxed_line "  -uninstall      Uninstall Queue (safely preserves instant reinstaller)"
    print_boxed_line "  -remove-setup   Permanently wipe setup file (after uninstallation)"
    print_boxed_line "  -version / -V   Display version information"
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
    print_boxed_line "  TAB             Select / Mark track ${C_GRAY}(Triggers Action Menu w/ Dislike)${C_RESET}"
    print_boxed_line "  ALT-A           Toggle Selection (Invert All)"
    print_boxed_line "  INSERT          Select All"
    print_boxed_line "  DELETE          Deselect All"
    print_boxed_line "  ENTER           Direct Play ${C_GRAY}(or Action Menu if tracks selected)${C_RESET}"
    print_boxed_line "  CTRL-D          Dislike & Blacklist directly in Search Mode"
    print_boxed_line "  'x' key         Dislike track inside Inspector ${C_GRAY}(q -i)${C_RESET}"
    print_boxed_line "  'v' key         Watch Video Window inside Inspector ${C_GRAY}(q -i)${C_RESET}"
    print_boxed_line ""
    print_boxed_line "${C_YELLOW}Status Indicators:${C_RESET}"
    print_boxed_line "  ><              Shuffle Mode ON"
    print_boxed_line "  ⟳ / ⟳1          Playlist / Single-Track Loop ON"
    print_boxed_line "  Ꭰᗡ              Audio FX (Dolby Equalizer) ON"
    print_boxed_line "  ◖∞◗             Auto-Discovery (Continuous Radio) ON"
    print_boxed_line "  <|V|>           Desktop Video Window Mode ON"
    print_boxed_line ""
    print_boxed_line "${C_YELLOW}Searching:${C_RESET}"
    print_boxed_line "  q yt <q>        Force YouTube search"
    print_boxed_line "  q sc <q>        Force Soundcloud search"
    if [ "$IS_WSL" = true ]; then
        echo -e "${C_GRAY}${H_LINE}${C_RESET}"
        print_boxed_line "${C_GRAY}💡 Tip: Use ${C_WHITE}q -hybrid on${C_GRAY} for 120+ FPS Direct3D & native WASAPI audio!${C_RESET}"
    elif [ "$IS_ANDROID" = true ]; then
        echo -e "${C_GRAY}${H_LINE}${C_RESET}"
        print_boxed_line "${C_GRAY}💡 Tip: Use ${C_WHITE}q -hybrid on${C_GRAY} for Play Store MPV + Android Audio Tunneling!${C_RESET}"
    fi
    printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
    B_LINE=${B_LINE// /─}
    echo -e "${C_GRAY}${B_LINE}${C_RESET}"
}
