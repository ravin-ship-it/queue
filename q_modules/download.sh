#!/usr/bin/env bash
# ==============================================================================
# 📥 Q Interactive Downloader Module
# ==============================================================================

cmd_download() {
    local target="$1"
    local clean_url=""
    local title=""
    local artist=""

    # 1. Resolve Target
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        # Index in active queue
        local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)
        local idx=$((target - 1))
        local item_json=$(echo "$track_info" | jq -s -c "map(select(.event == null)) | .[0].data[$idx] // empty" 2>/dev/null)
        clean_url=$(echo "$item_json" | jq -r '.filename // ""')
        title=$(echo "$item_json" | jq -r '.title // ""')
    elif [[ "$target" =~ ^http ]]; then
        clean_url="$target"
    elif [ -n "$target" ] && [ -f "$target" ]; then
        echo -e "${C_PINK}ℹ️  Track is already a local file:${C_RESET} ${C_CYAN}$target${C_RESET}"
        return 0
    elif [ -n "$target" ]; then
        # Search query given directly to download
        echo -e "${C_CYAN}🔍 Searching for \"$target\" to download...${C_RESET}"
        perform_search "$target" "ytsearch25"
        if [ $? -eq 0 ] && [ ${#PLAYLIST_URLS[@]} -gt 0 ]; then
            for url in "${PLAYLIST_URLS[@]}"; do
                interactive_download_wizard "$url"
            done
            return 0
        else
            return 1
        fi
    else
        # No target given -> Default to current playing track
        local current_path=$(echo '{ "command": ["get_property", "path"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // empty')
        if [ -z "$current_path" ] || [ "$current_path" == "null" ]; then
            echo -e "${C_ORANGE}⚠️ Nothing is currently playing.${C_RESET}"
            echo -e "${C_PINK}Usage:${C_RESET} ${C_CYAN}q -d <index | URL | query>${C_RESET}"
            return 1
        fi
        if [ -f "$current_path" ]; then
            echo -e "${C_PINK}ℹ️  Currently playing track is already a local file:${C_RESET} ${C_CYAN}$current_path${C_RESET}"
            return 0
        fi
        clean_url="$current_path"
    fi

    # Clean URL parameters
    if [[ "$clean_url" =~ ^http ]]; then
        clean_url="${clean_url%%\\t*}"
        clean_url="${clean_url%%$'\t'*}"
        clean_url="${clean_url%%[[:space:]]*}"
        clean_url=$(echo "$clean_url" | sed -E 's/([?&])(si|t|pp|feature)=[^&]*&?/\1/g; s/[?&]$//; s/\?&/?/')
    fi

    if [ -z "$clean_url" ]; then
        echo -e "${C_PINK}❌ Invalid or empty media URL for download.${C_RESET}"
        return 1
    fi

    interactive_download_wizard "$clean_url" "$title" "$artist"
}

interactive_download_wizard() {
    local url="$1"
    local force_title="$2"
    local force_artist="$3"

    echo -e "${C_PINK}🎵 Fetching available media streams for download...${C_RESET}"
    
    local COOKIES_FILE="$HOME/.config/mpv/cookies.txt"
    local opts=("--dump-json" "--no-warnings" "--skip-download" "--ignore-errors")
    [ -f "$COOKIES_FILE" ] && opts+=("--cookies" "$COOKIES_FILE")

    local json_dump
    json_dump=$(run_with_timeout 30s yt-dlp "${opts[@]}" -- "$url" 2>/dev/null)

    local title=$(echo "$json_dump" | jq -r '.title // ""' 2>/dev/null)
    [ -z "$title" ] && title="${force_title:-$url}"
    local uploader=$(echo "$json_dump" | jq -r '.uploader // .artist // "Unknown"' 2>/dev/null)
    local duration=$(echo "$json_dump" | jq -r '.duration_string // "N/A"' 2>/dev/null)
    local max_height=$(echo "$json_dump" | jq -r '.height // 0' 2>/dev/null)
    local vcodec=$(echo "$json_dump" | jq -r '.vcodec // ""' 2>/dev/null)
    local fps=$(echo "$json_dump" | jq -r '.fps // ""' 2>/dev/null)
    [[ ! "$max_height" =~ ^[0-9]+$ ]] && max_height=0

    local fps_tag=""
    [ -n "$fps" ] && [ "$fps" != "null" ] && [ "$fps" -gt 30 ] 2>/dev/null && fps_tag=" (${fps}fps)"

    print_header_box "${C_PINK}📥 Interactive Download Hub${C_RESET}"
    print_boxed_line "${C_TEAL}Title:    ${C_CYAN}${title:0:$((INNER_WIDTH-12))}${C_RESET}"
    print_boxed_line "${C_TEAL}Artist:   ${C_LIGHT_PINK}${uploader}${C_RESET}"
    print_boxed_line "${C_TEAL}Duration: ${C_ORANGE}${duration}${C_RESET}"
    print_boxed_line "${C_TEAL}Source:   ${C_VIOLET}${url:0:$((INNER_WIDTH-12))}${C_RESET}"
    printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
    B_LINE=${B_LINE// /─}
    echo -e "${C_PURPLE}${B_LINE}${C_RESET}"

    # --- STEP 1: Format Quality Selection ---
    local menu_items=""
    
    # Video Section (If video streams available)
    if [[ "$vcodec" != "none" ]] && [ "$max_height" -gt 0 ]; then
        menu_items+="🎬 [Video] 🌟 Best Available Quality (Auto MP4/MKV)\n"
        if [ "$max_height" -ge 2160 ]; then
            menu_items+="🎬 [Video] 4K Ultra HD (2160p${fps_tag} -> MP4)\n"
        fi
        if [ "$max_height" -ge 1440 ]; then
            menu_items+="🎬 [Video] 2K Quad HD (1440p${fps_tag} -> MP4)\n"
        fi
        if [ "$max_height" -ge 1080 ]; then
            menu_items+="🎬 [Video] Full HD (1080p${fps_tag} -> MP4)\n"
        fi
        if [ "$max_height" -ge 720 ]; then
            menu_items+="🎬 [Video] HD Ready (720p${fps_tag} -> MP4)\n"
        fi
        menu_items+="🎬 [Video] Data Saver (480p / 360p -> MP4)\n"
    fi

    # Audio Section (Always available)
    menu_items+="🎵 [Audio] 🪷 FLAC (Lossless Studio Master)\n"
    menu_items+="🎵 [Audio] 🎧 MP3 320 kbps (High Quality)\n"
    menu_items+="🎵 [Audio] ⚡ OPUS (Original Bitstream - Zero Re-encode)\n"
    menu_items+="🎵 [Audio] 🍎 M4A / AAC (Universal Mobile Standard)\n"
    menu_items+="🎵 [Audio] 🌊 WAV (Uncompressed Master PCM)\n"
    menu_items+="🔬 [Advanced] ⚙️ Inspect Raw Streams (yt-dlp -F)"

    local format_choice=""
    if command -v fzf >/dev/null 2>&1; then
        format_choice=$(echo -ne "$menu_items" | fzf --height=100% --layout=reverse --border \
            $FZF_COLOR_OPTS \
            --header="Select Download Format / Quality for: ${title:0:40}..." \
            --prompt="Format > ")
    else
        echo -e "${C_YELLOW}Select Format / Quality:${C_RESET}"
        local i=1
        local -A MAP_CHOICE
        while IFS= read -r item; do
            [ -z "$item" ] && continue
            echo -e "  ${C_ORANGE}$i)${C_RESET} $item"
            MAP_CHOICE[$i]="$item"
            ((i++))
        done <<< "$menu_items"
        echo -ne "${C_PINK}Enter choice [1-$((i-1))] (or 'c' to cancel) > ${C_RESET}"
        read -r num_choice
        [[ "$num_choice" =~ ^[0-9]+$ ]] && format_choice="${MAP_CHOICE[$num_choice]}"
    fi

    if [ -z "$format_choice" ]; then
        echo -e "${C_PINK}👋 Download cancelled.${C_RESET}"
        return 0
    fi

    # --- STEP 2: Destination Directory Selection ---
    local default_music="$HOME/Music"
    local default_video="$HOME/Videos"
    # Detect Termux Storage
    if [ -d "$HOME/storage/shared/Music" ]; then default_music="$HOME/storage/shared/Music"; fi
    if [ -d "$HOME/storage/shared/Movies" ]; then default_video="$HOME/storage/shared/Movies"; fi
    if [ -d "$HOME/storage/shared/Download" ]; then :; fi

    local dir_items=""
    dir_items+="📁 Current Directory (${PWD})\n"
    if [[ "$format_choice" =~ \[Audio\] ]]; then
        dir_items+="🎵 Music Directory (${default_music})\n"
    else
        dir_items+="🎬 Videos Directory (${default_video})\n"
    fi
    if [ -d "$HOME/Downloads" ]; then dir_items+="📥 Downloads Directory (${HOME}/Downloads)\n"; fi
    if [ -d "$HOME/storage/shared/Download" ]; then dir_items+="📥 Shared Downloads (${HOME}/storage/shared/Download)\n"; fi
    dir_items+="✏️ Custom Directory..."

    local dir_choice=""
    if command -v fzf >/dev/null 2>&1; then
        dir_choice=$(echo -ne "$dir_items" | fzf --height=100% --layout=reverse --border \
            $FZF_COLOR_OPTS \
            --header="Where would you like to save this download?" \
            --prompt="Destination > ")
    else
        echo -e "\n${C_YELLOW}Select Destination Folder:${C_RESET}"
        local i=1
        local -A MAP_DIR
        while IFS= read -r item; do
            [ -z "$item" ] && continue
            echo -e "  ${C_ORANGE}$i)${C_RESET} $item"
            MAP_DIR[$i]="$item"
            ((i++))
        done <<< "$dir_items"
        echo -ne "${C_PINK}Enter choice [1-$((i-1))] (or 'c' to cancel) > ${C_RESET}"
        read -r num_dir
        [[ "$num_dir" =~ ^[0-9]+$ ]] && dir_choice="${MAP_DIR[$num_dir]}"
    fi

    if [ -z "$dir_choice" ]; then
        echo -e "${C_PINK}👋 Download cancelled.${C_RESET}"
        return 0
    fi

    local target_dir="$PWD"
    if [[ "$dir_choice" =~ Current ]]; then
        target_dir="$PWD"
    elif [[ "$dir_choice" =~ Music ]]; then
        target_dir="$default_music"
    elif [[ "$dir_choice" =~ Videos ]]; then
        target_dir="$default_video"
    elif [[ "$dir_choice" =~ Downloads ]] || [[ "$dir_choice" =~ "Shared Downloads" ]]; then
        if [[ "$dir_choice" =~ "Shared Downloads" ]]; then
            target_dir="$HOME/storage/shared/Download"
        else
            target_dir="$HOME/Downloads"
        fi
    elif [[ "$dir_choice" =~ Custom ]]; then
        if command -v fzf >/dev/null 2>&1; then
            target_dir=$(get_input "Enter Custom Directory Path" "Path > ")
        else
            echo -ne "${C_PINK}Enter custom directory path > ${C_RESET}"
            read -r target_dir
        fi
    fi

    # Expand tilde and create directory if needed
    target_dir="${target_dir/#\~/$HOME}"
    [ -z "$target_dir" ] && target_dir="$PWD"
    mkdir -p "$target_dir" 2>/dev/null

    if [ ! -d "$target_dir" ] || [ ! -w "$target_dir" ]; then
        echo -e "${C_PINK}❌ Directory '${target_dir}' is not writable. Falling back to current directory.${C_RESET}"
        target_dir="$PWD"
    fi

    # --- STEP 3: Dispatch Download Execution ---
    execute_download "$url" "$format_choice" "$target_dir"
}

execute_download() {
    local url="$1"
    local choice="$2"
    local dest_dir="$3"

    echo -e "${C_PURPLE}${T_LINE}${C_RESET}"
    echo -e "${C_CYAN}🚀 Starting Download...${C_RESET}"
    echo -e "${C_TEAL}📂 Target Directory:${C_RESET} ${C_WHITE}${dest_dir}${C_RESET}"
    echo -e "${C_TEAL}🎯 Preset:${C_RESET} ${C_YELLOW}${choice}${C_RESET}"
    echo -e "${C_PURPLE}${B_LINE}${C_RESET}"

    local YTDL_CMD=("yt-dlp")
    if ! yt-dlp --version >/dev/null 2>&1; then
        if python3 -m yt_dlp --version >/dev/null 2>&1; then
            YTDL_CMD=("python3" "-m" "yt_dlp")
        fi
    fi

    local dl_args=("--embed-metadata" "--embed-thumbnail" "-P" "$dest_dir" "-o" "%(title)s [%(id)s].%(ext)s")
    local COOKIES_FILE="$HOME/.config/mpv/cookies.txt"
    [ -f "$COOKIES_FILE" ] && dl_args+=("--cookies" "$COOKIES_FILE")

    if [[ "$choice" =~ "Inspect Raw Streams" ]]; then
        # Advanced interactive stream inspection
        echo -e "${C_CYAN}📊 Available Raw Streams for this video:${C_RESET}\n"
        "${YTDL_CMD[@]}" -F -- "$url"
        echo ""
        echo -ne "${C_PINK}Enter custom format code (e.g. '137+140' or '251') > ${C_RESET}"
        read -r custom_f
        if [ -n "$custom_f" ]; then
            "${YTDL_CMD[@]}" "${dl_args[@]}" -f "$custom_f" -- "$url"
        fi
    elif [[ "$choice" =~ "FLAC" ]]; then
        "${YTDL_CMD[@]}" "${dl_args[@]}" -x --audio-format flac -- "$url"
    elif [[ "$choice" =~ "MP3" ]]; then
        "${YTDL_CMD[@]}" "${dl_args[@]}" -x --audio-format mp3 --audio-quality 0 -- "$url"
    elif [[ "$choice" =~ "OPUS" ]]; then
        "${YTDL_CMD[@]}" "${dl_args[@]}" -x --audio-format opus -- "$url"
    elif [[ "$choice" =~ "M4A" ]]; then
        "${YTDL_CMD[@]}" "${dl_args[@]}" -x --audio-format m4a -- "$url"
    elif [[ "$choice" =~ "WAV" ]]; then
        # WAV doesn't support embedded thumbnails
        local wav_args=("--embed-metadata" "-P" "$dest_dir" "-o" "%(title)s [%(id)s].%(ext)s" -x --audio-format wav)
        [ -f "$COOKIES_FILE" ] && wav_args+=("--cookies" "$COOKIES_FILE")
        "${YTDL_CMD[@]}" "${wav_args[@]}" -- "$url"
    elif [[ "$choice" =~ "4K Ultra" ]]; then
        "${YTDL_CMD[@]}" "${dl_args[@]}" -f "bv*[height<=2160]+ba/b" --merge-output-format mp4 -- "$url"
    elif [[ "$choice" =~ "2K Quad" ]]; then
        "${YTDL_CMD[@]}" "${dl_args[@]}" -f "bv*[height<=1440]+ba/b" --merge-output-format mp4 -- "$url"
    elif [[ "$choice" =~ "Full HD" ]]; then
        "${YTDL_CMD[@]}" "${dl_args[@]}" -f "bv*[height<=1080]+ba/b" --merge-output-format mp4 -- "$url"
    elif [[ "$choice" =~ "HD Ready" ]]; then
        "${YTDL_CMD[@]}" "${dl_args[@]}" -f "bv*[height<=720]+ba/b" --merge-output-format mp4 -- "$url"
    elif [[ "$choice" =~ "Data Saver" ]]; then
        "${YTDL_CMD[@]}" "${dl_args[@]}" -f "bv*[height<=480]+ba/b" --merge-output-format mp4 -- "$url"
    else
        # Default Best Quality
        "${YTDL_CMD[@]}" "${dl_args[@]}" -f "bv*+ba/b" --merge-output-format mp4 -- "$url"
    fi

    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo -e "\n${C_GREEN}✨ Download Finished Successfully!${C_RESET}"
        echo -e "${C_TEAL}📂 Saved into:${C_RESET} ${C_WHITE}${dest_dir}${C_RESET}"
    else
        echo -e "\n${C_PINK}⚠️ Download ended with code ${exit_code}.${C_RESET}"
    fi
}
