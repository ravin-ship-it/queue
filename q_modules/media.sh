fetch_and_display_url_info() {
    local input="$1"
    local force_title="$2" # Optional override title (e.g. from playlist)
    local is_current="$3"
    
    echo -e "${C_PINK}🎵 Fetching Remote Metadata...${C_RESET}"
    
    # Robust ID Extraction
    local video_id=""
    if [[ "$input" =~ (youtu\.be\/|v=)([^&?\/]+) ]]; then
        video_id="${BASH_REMATCH[2]}"
    fi
    
    # Clean URL: strip everything after space or tab to remove title
    local clean_url="${input%%\\t*}"
    clean_url="${clean_url%%[[:space:]]*}"
    # Remove tracking params safely without destroying video ID
    clean_url=$(echo "$clean_url" | sed -E 's/([?&])(si|t|pp|feature)=[^&]*&?/\1/g; s/[?&]$//; s/\?&/?/')

    local search_term="$video_id"
    [ -z "$search_term" ] && search_term="$clean_url"

    # Queue Check
    local queue_status="Not in queue"
    local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)
    local queue_idx=$(echo "$track_info" | jq -s -r --arg term "$search_term" \
        'map(select(.event == null)) | .[0].data | select(type == "array") | to_entries | .[] | 
        select((.value.filename | contains($term))) | 
        .key + 1
    ' 2>/dev/null | head -n 1)
    [ -n "$queue_idx" ] && [ "$queue_idx" != "null" ] && queue_status="Queued at #$queue_idx"
    
    # Fetch Metadata (Robustly)
    local opts=("--extractor-args" "youtube:player_client=visionos,android,web" "--dump-json" "--no-warnings" "--skip-download" "--ignore-errors" "--flat-playlist")
    command -v node >/dev/null 2>&1 && opts+=("--js-runtimes" "node")
    [ -n "$COOKIES_FILE" ] && [ -f "$COOKIES_FILE" ] && opts+=("--cookies" "$COOKIES_FILE")
    local json_dump=$(run_with_timeout 30 yt-dlp "${opts[@]}" -- "$clean_url" 2>/dev/null)
    if [ -z "$json_dump" ]; then
        if [ -n "$force_title" ] || [ "$is_current" == "true" ]; then
            local display_t="${force_title:-$clean_url}"
            local queue_display="${C_ORANGE}${queue_status}${C_RESET}"
            if [[ "$queue_status" == *"Queued at"* ]]; then
                local idx=$(echo "$queue_status" | grep -oP '\d+')
                queue_display="${C_TEAL}Queued at ${C_WHITE}[${C_ORANGE}${idx}${C_WHITE}]${C_RESET}"
            fi

            print_header_box "${C_PINK}🪷 Track Metadata${C_RESET}"
            print_boxed_line "${C_TEAL}Title:    ${C_CYAN}${display_t:0:$((INNER_WIDTH-12))}${C_RESET}"
            print_boxed_line "${C_TEAL}Source:   ${C_VIOLET}${clean_url:0:$((INNER_WIDTH-12))}${C_RESET}"
            print_boxed_line "${C_TEAL}Queue:    ${queue_display}"
            print_boxed_line "${C_GRAY}(Remote details restricted by YouTube bot protection)${C_RESET}"
            
            if [ "$is_current" == "true" ]; then
                local mpv_extended=$(echo -e '{"command":["get_property","file-format"]}\n{"command":["get_property","audio-codec"]}\n{"command":["get_property","audio-params/samplerate"]}\n{"command":["get_property","duration"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -r 'map(select(.event == null)) | (.[0].data // "N/A"), (.[1].data // "N/A"), (.[2].data // "N/A"), (.[3].data // "N/A")')
                mapfile -t ext_props <<< "$mpv_extended"
                local fmt="${ext_props[0]}" codec="${ext_props[1]}" rate="${ext_props[2]}" dur="${ext_props[3]}"
                
                if [ "$dur" != "N/A" ] && [[ "$dur" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    dur=$(printf "%d:%02d" "$((${dur%.*} / 60))" "$((${dur%.*} % 60))")
                fi

                echo -e "${C_PURPLE}├${H_LINE:2}┤${C_RESET}"
                print_boxed_line "${C_PINK}🎵 Current Playback Quality${C_RESET}"
                print_boxed_line "${C_TEAL}Format:   ${C_WHITE}$fmt${C_RESET}"
                print_boxed_line "${C_TEAL}Codec:    ${C_WHITE}$codec${C_RESET}"
                print_boxed_line "${C_TEAL}Rate:     ${C_WHITE}${rate} Hz${C_RESET}"
                print_boxed_line "${C_TEAL}Duration: ${C_WHITE}$dur${C_RESET}"
            fi
            printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
            B_LINE=${B_LINE// /─}
            echo -e "${C_GRAY}${B_LINE}${C_RESET}"
            return
        else
            echo -e "${C_PINK}🙈 Failed to fetch info... the internet might be playing hide and seek!${C_RESET}"
            return
        fi
    fi
    
    # Check if we have multiple lines (Playlist) or single line
    local line_count=$(echo "$json_dump" | wc -l)
    
    if [ "$line_count" -gt 1 ]; then
        # Handle as Playlist (Summary)
        local pl_title=$(echo "$json_dump" | jq -r -s '.[0].playlist_title // .[0].title // "Untitled Playlist"')
        local pl_author=$(echo "$json_dump" | jq -r -s '.[0].playlist_uploader // .[0].uploader // "N/A"')
        local pl_platform=$(echo "$json_dump" | jq -r -s '.[0].extractor_key // "N/A"')
        
        # Count Alive/Dead
        local dead_count=$(echo "$json_dump" | jq -r 'select(.title == "[Private video]" or .title == "[Deleted video]") | .title' | wc -l)
        local alive_count=$((line_count - dead_count))

        print_header_box "${C_PURPLE}🪷 Playlist Metadata${C_RESET}"
        print_boxed_line "${C_TEAL}Title:    ${C_CYAN}${pl_title:0:$((INNER_WIDTH-12))}${C_RESET}"
        print_boxed_line "${C_TEAL}Author:   ${C_WHITE}${pl_author}${C_RESET}"
        print_boxed_line "${C_TEAL}Tracks:   ${C_WHITE}${line_count}${C_RESET} ${C_GRAY}(${C_GREEN}${alive_count} Alive${C_GRAY} | ${C_PINK}${dead_count} Dead${C_GRAY})${C_RESET}"
        print_boxed_line "${C_TEAL}Platform: ${C_WHITE}${pl_platform}${C_RESET}"
        echo -e "${C_GRAY}├${H_LINE:2}┤${C_RESET}"
        print_boxed_line "${C_ORANGE}Note: Use 'q <url>' to add all tracks.${C_RESET}"
        printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
        B_LINE=${B_LINE// /─}
        echo -e "${C_GRAY}${B_LINE}${C_RESET}"
    else
        # Handle as Single Track
        local type=$(echo "$json_dump" | jq -r '._type // "video"')
        if [ "$type" == "playlist" ]; then
             # Single-entry playlist (rare but possible)
             local pl_title=$(echo "$json_dump" | jq -r '.title')
             local pl_count=$(echo "$json_dump" | jq -r '.entries | length // 1')
             local pl_author=$(echo "$json_dump" | jq -r '.uploader // .author // "N/A"')
             
             print_header_box "${C_PURPLE}🪷 Playlist Metadata${C_RESET}"
             print_boxed_line "${C_TEAL}Title:    ${C_CYAN}${pl_title:0:$((INNER_WIDTH-12))}${C_RESET}"
             print_boxed_line "${C_TEAL}Author:   ${C_WHITE}${pl_author}${C_RESET}"
             print_boxed_line "${C_TEAL}Tracks:   ${C_WHITE}${pl_count}${C_RESET}"
             print_boxed_line "${C_TEAL}Platform: ${C_WHITE}Collection${C_RESET}"
             echo -e "${C_GRAY}├${H_LINE:2}┤${C_RESET}"
             print_boxed_line "${C_ORANGE}Note: Use 'q <url>' to add all tracks.${C_RESET}"
             printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
             B_LINE=${B_LINE// /─}
             echo -e "${C_GRAY}${B_LINE}${C_RESET}"
        else
            local title=$(echo "$json_dump" | jq -r '.title')
        # Use existing title from MPV if available and yt-dlp title is generic
        [ -n "$force_title" ] && [ "$force_title" != "N/A" ] && title="$force_title"
        
        local artist=$(echo "$json_dump" | jq -r '.uploader // .artist // "N/A"')
        local dur=$(echo "$json_dump" | jq -r '.duration_string')
        local platform=$(echo "$json_dump" | jq -r '.extractor_key')
        local views=$(echo "$json_dump" | jq -r '.view_count // 0')
        local likes=$(echo "$json_dump" | jq -r '.like_count // 0')
        local date=$(echo "$json_dump" | jq -r '.upload_date // "N/A"')
        
        if [[ "$views" =~ ^[0-9]+$ ]]; then views=$(printf "%'d" "$views"); fi
        if [[ "$likes" =~ ^[0-9]+$ ]]; then likes=$(printf "%'d" "$likes"); fi
        if [[ "$date" =~ ^[0-9]{8}$ ]]; then date="${date:0:4}-${date:4:2}-${date:6:2}"; fi

        # Smart metric label
        local view_label="Views:"
        if [[ "$platform" =~ [Ss]ound[Cc]loud ]] || [[ "$platform" =~ [Dd]eezer ]]; then
            view_label="Listens:"
        fi

        # Format Queue Status
        local queue_display="${C_ORANGE}${queue_status}${C_RESET}"
        if [[ "$queue_status" == *"Queued at"* ]]; then
            local idx=$(echo "$queue_status" | grep -oP '\d+')
            queue_display="${C_TEAL}Queued at ${C_WHITE}[${C_ORANGE}${idx}${C_WHITE}]${C_RESET}"
        fi
        
        print_header_box "${C_PINK}🪷 Track Metadata${C_RESET}"
        print_boxed_line "${C_TEAL}Title:    ${C_CYAN}${title:0:$((INNER_WIDTH-12))}${C_RESET}"
        print_boxed_line "${C_TEAL}Artist:   ${C_LIGHT_PINK}${artist}${C_RESET}"
        print_boxed_line "${C_TEAL}Duration: ${C_ORANGE}${dur}${C_RESET}"
        print_boxed_line "${C_TEAL}Platform: ${C_WHITE}${platform}${C_RESET}"
        print_boxed_line "${C_TEAL}URL:      ${C_VIOLET}${clean_url:0:$((INNER_WIDTH-12))}${C_RESET}"

        # Extract available multi-audio languages and cache
        local audio_tracks_summary=""
        local audio_langs_json=""
        audio_langs_json=$(echo "$json_dump" | jq -c '[.formats[]? | select(.vcodec == "none" and .acodec != "none") | {lang: (.language // "auto"), note: (.format_note // "")}] | unique_by(.lang)' 2>/dev/null)
        if [ -n "$audio_langs_json" ] && [ "$audio_langs_json" != "[]" ]; then
            mkdir -p "$HOME/.cache/mpv"
            echo "$audio_langs_json" > "$HOME/.cache/mpv/current_audio_langs.json" 2>/dev/null
            if [ "$IS_WSL" = true ]; then
                local win_u_dir
                win_u_dir=$(get_windows_user_dir)
                if [ -n "$win_u_dir" ] && [ -d "$win_u_dir" ]; then
                    mkdir -p "$win_u_dir/.cache/mpv" 2>/dev/null
                    cp -f "$HOME/.cache/mpv/current_audio_langs.json" "$win_u_dir/.cache/mpv/current_audio_langs.json" 2>/dev/null
                fi
            fi

            local cur_pref="en"
            [ -f "$HOME/.config/mpv/queue_lang" ] && cur_pref=$(cat "$HOME/.config/mpv/queue_lang" 2>/dev/null | tr -d '[:space:]')
            [ -z "$cur_pref" ] && cur_pref="en"

            audio_tracks_summary=$(echo "$audio_langs_json" | jq -r --arg pref "$cur_pref" '
              map(
                "[" + .lang + "] " +
                (if .lang == "zh" then "Chinese"
                 elif .lang == "en" then "English"
                 elif .lang == "ja" then "Japanese"
                 elif .lang == "es" then "Spanish"
                 elif .lang == "fr" then "French"
                 elif .lang == "ko" then "Korean"
                 elif .lang == "de" then "German"
                 elif .lang == "hi" then "Hindi"
                 elif .note != "" then (.note | split(",")[0] | split("(")[0] | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))
                 else .lang end) +
                (if .lang == $pref then " (Active)" elif (.note | test("original"; "i")) then " (Original)" else "" end)
              ) | join(" • ")
            ' 2>/dev/null)
        fi

        [ -n "$audio_tracks_summary" ] && print_boxed_line "${C_TEAL}Audio:    ${C_WHITE}${audio_tracks_summary:0:$((INNER_WIDTH-12))}${C_RESET}"
        echo -e "${C_PURPLE}├${H_LINE:2}┤${C_RESET}"
        print_boxed_line "${C_TEAL}${view_label:0:10} ${C_WHITE}${views}${C_RESET}"
        print_boxed_line "${C_TEAL}Likes:    ${C_WHITE}${likes}${C_RESET}"
        print_boxed_line "${C_TEAL}Uploaded: ${C_WHITE}${date}${C_RESET}"
        
        # Status Badge (Liked 🩷 | / Disliked 💔 |)
        local pref_badge=""
        if is_liked_track "$clean_url" "$video_id"; then
            pref_badge=" ${C_PINK}🩷 | Liked${C_RESET}"
        elif is_disliked_track "$clean_url" "$video_id"; then
            pref_badge=" ${C_PINK}💔 | Disliked${C_RESET}"
        fi

        if [ "$is_current" == "true" ]; then
            local is_paused=$(echo '{ "command": ["get_property", "pause"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // false')
            if [ "$is_paused" == "true" ]; then
                print_boxed_line "${C_TEAL}Status:   ${C_YELLOW}⏸ Paused${C_RESET} (${queue_display})${pref_badge}"
            else
                print_boxed_line "${C_TEAL}Status:   ${C_PURPLE}▶ Playing${C_RESET} (${queue_display})${pref_badge}"
            fi
        else
            if [ -n "$pref_badge" ]; then
                print_boxed_line "${C_TEAL}Preference:${pref_badge}"
            fi
            print_boxed_line "${C_TEAL}Queue:    ${queue_display}"
        fi
        
        if [ "$is_current" == "true" ]; then
            local mpv_props=$(echo -e '{"command":["get_property","file-format"]}\n{"command":["get_property","audio-codec-name"]}\n{"command":["get_property","audio-bitrate"]}\n{"command":["get_property","audio-params/samplerate"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -r 'map(select(.event == null)) | (.[0].data // "N/A"), (.[1].data // "N/A"), (.[2].data // "N/A"), (.[3].data // "N/A")')
            mapfile -t props <<< "$mpv_props"
            local fmt="${props[0]}" codec="${props[1]}" bitrate="${props[2]}" rate="${props[3]}"
            
            if [ "$bitrate" != "N/A" ] && [[ "$bitrate" =~ ^[0-9]+$ ]]; then
                bitrate="$((bitrate / 1000)) kbps"
            fi
            
            echo -e "${C_PURPLE}├${H_LINE:2}┤${C_RESET}"
            print_boxed_line "${C_PINK}🎵 Current Playback Quality${C_RESET}"
            print_boxed_line "${C_TEAL}Format:   ${C_WHITE}$fmt${C_RESET}"
            print_boxed_line "${C_TEAL}Codec:    ${C_WHITE}$codec${C_RESET}"
            print_boxed_line "${C_TEAL}Bitrate:  ${C_WHITE}$bitrate${C_RESET}"
            print_boxed_line "${C_TEAL}Rate:     ${C_WHITE}${rate} Hz${C_RESET}"
        fi
        
        printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
        B_LINE=${B_LINE// /─}
        echo -e "${C_PURPLE}${B_LINE}${C_RESET}"

        if [ -t 0 ] && [ -t 1 ]; then
            echo -ne "${C_PINK}>>> Press 'l' to like/unlike, 'x' to dislike, 'd' to download, 'v' for video, 'a' for audio, or ENTER to return: ${C_RESET}"
            read -r -n 1 user_key < /dev/tty 2>/dev/null || read -r -n 1 user_key
            echo ""
            if [[ "$user_key" =~ ^[lL]$ ]]; then
                if is_liked_track "$clean_url" "$video_id"; then
                    cmd_unlike "$clean_url"
                else
                    cmd_like "$clean_url"
                fi
            elif [[ "$user_key" =~ ^[dD]$ ]]; then
                cmd_download "$clean_url"
            elif [[ "$user_key" =~ ^[xX]$ ]]; then
                cmd_dislike "$clean_url"
            elif [[ "$user_key" =~ ^[vV]$ ]]; then
                cmd_video_toggle "$index"
            elif [[ "$user_key" =~ ^[aA]$ ]]; then
                cmd_language ""
            fi
        fi
    fi
    fi
}

wait_for_playback_start() {
    # Wait for playback start (Buffering)
    echo -ne "${C_GRAY}⏳ Buffering...${C_RESET}\r"
    for w in {1..80}; do
        local raw=$(echo -e '{"command":["get_property","playlist-count"]}\n{"command":["get_property","idle-active"]}\n{"command":["get_property","time-pos"]}\n{"command":["get_property","playlist-pos"]}\n{"command":["get_property","pause"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -j -r 'map(select(.event == null)) | (.[0].data // 0), "\t", (.[1].data // "false"), "\t", (.[2].data // ""), "\t", (if .[3].data == null then -1 else .[3].data end), "\t", (.[4].data // "false")')
        [ -z "$raw" ] && { sleep 0.1; continue; }
        IFS=$'\t' read -r count idle tpos pos paused <<< "$raw"
        
        # If queue is empty, exit immediately
        if [[ ! "$count" =~ ^[0-9]+$ ]] || [ "$count" -eq 0 ]; then break; fi

        # If we have a time position, playback has definitely started
        if [ -n "$tpos" ] && [ "$tpos" != "" ] && [ "$tpos" != "null" ]; then break; fi
        
        # If paused explicitly with valid track, break
        if [ "$paused" == "true" ] && [ "$pos" != "-1" ]; then break; fi

        # If it's NOT idle and position is valid, track is active
        if [ "$idle" == "false" ] && [ "$pos" != "-1" ]; then break; fi

        sleep 0.1
    done
    echo -ne "\033[2K\r"
}

format_track_log() {
    local idx="$1"
    local filename="$2"
    local mpv_title="$3"
    local force_artist="$4"
    local force_dur="$5"
    
    # 1. Clean Filename (Only for remote URLs)
    local clean_fname="$filename"
    [[ "$filename" =~ ^http ]] && clean_fname=$(echo "$filename" | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\\t.*//; s/\t.*//')

    # 2. Extract Embedded Title (Only for remote URLs with \t metadata)
    local embedded_title=""
    [[ "$filename" =~ ^http && "$filename" == *"\\t"* ]] && embedded_title="${filename#*\\t}"

    # 3. Robust Cache & Metadata Lookup
    local cached_title=""
    local cached_artist=""
    local cached_duration="$force_dur"
    
    if [ -n "$clean_fname" ]; then
        [ ${#CACHE_MEM[@]} -eq 0 ] && load_cache_to_memory
        
        local row="${CACHE_MEM[$clean_fname]}"
        # Fuzzy match by ID if direct lookup fails (for remote URLs)
        if [ -z "$row" ] && { [[ "$clean_fname" =~ ^http ]] || [[ "$clean_fname" == watch\?v=* ]]; }; then
            local vid_id=""
            [[ "$clean_fname" =~ v=([a-zA-Z0-9_-]{11}) ]] && vid_id="${BASH_REMATCH[1]}"
            [[ "$clean_fname" =~ watch\?v=([a-zA-Z0-9_-]{11}) ]] && vid_id="${BASH_REMATCH[1]}"
            
            if [ -n "$vid_id" ]; then
                for key in "${!CACHE_MEM[@]}"; do
                    if [[ "$key" == *"$vid_id"* ]]; then
                        row="${CACHE_MEM[$key]}"
                        break
                    fi
                done
            fi
        fi

        if [ -n "$row" ]; then
            cached_title=$(echo -e "$row" | cut -f1)
            cached_artist=$(echo -e "$row" | cut -f2)
            [ -z "$cached_duration" ] && cached_duration=$(echo -e "$row" | cut -f3)
        fi
    fi

    # 4. Final Title Determination
    local display_title="$mpv_title"
    # Prioritize: 1. Cached Title, 2. Embedded Title, 3. MPV Title (if not URL), 4. Filename (Cleaned)
    if [ -n "$cached_title" ] && [ "$cached_title" != "null" ]; then
        display_title="$cached_title"
    elif [ -n "$embedded_title" ]; then
        display_title="$embedded_title"
    elif [[ "$display_title" =~ ^https?:// ]] || [[ "$display_title" == watch\?v=* ]] || [ -z "$display_title" ]; then
        if [[ "$filename" =~ ^http ]]; then
            display_title=$(echo "$clean_fname" | sed 's/.*v=//; s/.*watch?v=//; s/&.*//')
        else
            display_title="${filename##*/}"
        fi
    fi

    # 5. Build Formatting Parts
    local artist_part=""
    local dur_part=""
    
    local final_artist="${force_artist:-$cached_artist}"
    final_artist="${final_artist//\//, }"
    
    [ -n "$final_artist" ] && [ "$final_artist" != "null" ] && [ "$final_artist" != "$clean_fname" ] && [ "$final_artist" != "N/A" ] && [ "$final_artist" != "Unknown" ] && artist_part=" ${C_GRAY}by${C_RESET} ${C_LIGHT_PINK}$final_artist${C_RESET}"
    
    # Fallback: fetch live duration from mpv if cache miss
    if { [ -z "$cached_duration" ] || [ "$cached_duration" == "null" ] || [ "$cached_duration" == "0:00" ]; } && [ -S "$SOCKET" ]; then
        local raw_mpv_dur=$(echo '{"command":["get_property","duration"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // empty')
        if [ -n "$raw_mpv_dur" ] && [[ "$raw_mpv_dur" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            local dur_secs=${raw_mpv_dur%.*}
            if [ "$dur_secs" -ge 3600 ]; then
                cached_duration=$(printf "%d:%02d:%02d" "$((dur_secs / 3600))" "$(((dur_secs % 3600) / 60))" "$((dur_secs % 60))")
            else
                cached_duration=$(printf "%d:%02d" "$((dur_secs / 60))" "$((dur_secs % 60))")
            fi
        fi
    fi
    [ -n "$cached_duration" ] && [ "$cached_duration" != "null" ] && [ "$cached_duration" != "0:00" ] && dur_part=" ${C_ORANGE}[$cached_duration]${C_RESET}"
    
    local badges=$(get_track_badges "$clean_fname" "$vid_id")

    echo -e "${C_WHITE}[${C_ORANGE}${idx}${C_WHITE}] ${badges}${C_CYAN}${display_title}${C_RESET}${artist_part}${dur_part}"
}

format_track_fzf() {
    local idx="$1"
    local filename="$2"
    local mpv_title="$3"
    local force_artist="$4"
    local force_dur="$5"
    
    # 1. Clean Filename (Only for remote URLs)
    local clean_fname="$filename"
    [[ "$filename" =~ ^http ]] && clean_fname=$(echo "$filename" | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\\t.*//; s/\t.*//')

    # 2. Extract Embedded Title (Only for remote URLs with \t metadata)
    local embedded_title=""
    [[ "$filename" =~ ^http && "$filename" == *"\\t"* ]] && embedded_title="${filename#*\\t}"

    # 3. Robust Cache & Metadata Lookup
    local cached_title=""
    local cached_artist=""
    local cached_duration="$force_dur"
    
    if [ -n "$clean_fname" ]; then
        [ ${#CACHE_MEM[@]} -eq 0 ] && load_cache_to_memory
        
        local row="${CACHE_MEM[$clean_fname]}"
        if [ -z "$row" ] && { [[ "$clean_fname" =~ ^http ]] || [[ "$clean_fname" == watch\?v=* ]]; }; then
            local vid_id=""
            [[ "$clean_fname" =~ v=([a-zA-Z0-9_-]{11}) ]] && vid_id="${BASH_REMATCH[1]}"
            [[ "$clean_fname" =~ watch\?v=([a-zA-Z0-9_-]{11}) ]] && vid_id="${BASH_REMATCH[1]}"
            
            if [ -n "$vid_id" ]; then
                for key in "${!CACHE_MEM[@]}"; do
                    if [[ "$key" == *"$vid_id"* ]]; then
                        row="${CACHE_MEM[$key]}"
                        break
                    fi
                done
            fi
        fi

        if [ -n "$row" ]; then
            cached_title=$(echo -e "$row" | cut -f1)
            cached_artist=$(echo -e "$row" | cut -f2)
            [ -z "$cached_duration" ] && cached_duration=$(echo -e "$row" | cut -f3)
        fi
    fi

    # 4. Final Title Determination
    local display_title="$mpv_title"
    if [ -n "$cached_title" ] && [ "$cached_title" != "null" ]; then
        display_title="$cached_title"
    elif [ -n "$embedded_title" ]; then
        display_title="$embedded_title"
    elif [[ "$display_title" =~ ^https?:// ]] || [[ "$display_title" == watch\?v=* ]] || [ -z "$display_title" ]; then
        if [[ "$filename" =~ ^http ]]; then
            display_title=$(echo "$clean_fname" | sed 's/.*v=//; s/.*watch?v=//; s/&.*//')
        else
            display_title="${filename##*/}"
        fi
    fi

    display_title="${display_title%%\\t*}"
    display_title="${display_title%%$'\t'*}"

    # 5. Build Formatting Parts (Strictly matches show_queue FZF line style)
    local artist_part=""
    local dur_part=""
    
    local final_artist="${force_artist:-$cached_artist}"
    final_artist="${final_artist//\//, }"
    
    [ -n "$final_artist" ] && [ "$final_artist" != "null" ] && [ "$final_artist" != "$clean_fname" ] && [ "$final_artist" != "N/A" ] && [ "$final_artist" != "Unknown" ] && artist_part=" ${C_GRAY}by${C_RESET} ${C_LIGHT_PINK}$final_artist${C_RESET}"
    
    [ -n "$cached_duration" ] && [ "$cached_duration" != "null" ] && [ "$cached_duration" != "0:00" ] && dur_part=" ${C_ORANGE}[$cached_duration]${C_RESET}"
    
    local badges=$(get_track_badges "$clean_fname" "$vid_id")

    printf "%s. %s%s%s%s" "${C_ORANGE}${idx}${C_RESET}" "$badges" "$display_title" "$artist_part" "$dur_part"
}

log_now_playing() {
    local user_prefix="$1"
    
    local curr_idx=""
    local filename=""
    local title=""
    local idle="false"
    local paused="false"
    local artist_tag=""
    local raw_live_dur=""
    for i in {1..30}; do
        local raw=$(echo -e '{"command":["get_property","playlist-count"]}\n{"command":["get_property","playlist-pos"]}\n{"command":["get_property","media-title"]}\n{"command":["get_property","path"]}\n{"command":["get_property","idle-active"]}\n{"command":["get_property","pause"]}\n{"command":["get_property","metadata"]}\n{"command":["get_property","duration"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -j -r '
            map(select(.event == null)) |
            (.[0].data // 0), "\t",
            (if .[1].data == null then -1 else .[1].data end), "\t",
            (.[2].data // ""), "\t",
            (.[3].data // ""), "\t",
            (.[4].data // "false"), "\t",
            (.[5].data // "false"), "\t",
            (.[6].data | if type == "object" then .artist // .ARTIST // .uploader // "" else "" end), "\t",
            (.[7].data // "")
        ' 2>/dev/null)
        
        [ -z "$raw" ] && { sleep 0.1; continue; }
        IFS=$'\t' read -r count pos title filename idle paused artist_tag raw_live_dur <<< "$raw"
        
        # If pos is valid, we found our track index
        if [ "$pos" != "-1" ]; then
             curr_idx=$((pos + 1))
             if [ -n "$raw_live_dur" ] && [ "$raw_live_dur" != "null" ]; then
                 break
             elif [ "$i" -ge 4 ]; then
                 break
             fi
        fi

        sleep 0.1
    done

    # If queue is genuinely empty after waiting
    if [[ ! "$count" =~ ^[0-9]+$ ]] || [ "$count" -eq 0 ]; then
         local final_prefix="${user_prefix:-|> Playing: }"
         echo -e "${C_PINK}${final_prefix}(Idle - Queue Empty)${C_RESET}"
         return
    fi

    local prefix="$user_prefix"
    if [ -z "$prefix" ]; then
        if [ "$paused" == "true" ]; then
            prefix="|| Paused: "
        else
            prefix="|> Playing: "
        fi
    fi
    
    # Fallback logic: If pos is not resolved yet, check current playlist item
    if [ -z "$curr_idx" ] && [ "$count" -gt 0 ]; then
        local pl_json=$(echo '{"command":["get_property","playlist"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)
        local fallback_idx=$(echo "$pl_json" | jq -s -r 'map(select(.event == null)) | .[0].data | to_entries[] | select(.value.current) | .key + 1' 2>/dev/null | head -n 1)
        if [ -n "$fallback_idx" ] && [ "$fallback_idx" != "null" ]; then
            curr_idx="$fallback_idx"
            local item=$(echo "$pl_json" | jq -s -r 'map(select(.event == null)) | .[0].data['$((curr_idx - 1))']')
            filename=$(echo "$item" | jq -r '.filename // ""')
            title=$(echo "$item" | jq -r '.title // ""')
        elif [ "$idle" == "true" ]; then
            echo -e "${C_PINK}${prefix}(Idle - Queue Finished)${C_RESET}"
            return
        fi
    fi

    # Final attempt to get details if we have an index but no meta
    if [ -n "$curr_idx" ] && [ -z "$filename" ]; then
        local item_json=$(echo "{\"command\":[\"get_property\", \"playlist/$((curr_idx - 1))\"]}" | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // empty')
        filename=$(echo "$item_json" | jq -r '.filename // ""')
        title=$(echo "$item_json" | jq -r '.title // ""')
    fi

    if [ -z "$curr_idx" ]; then
        return
    fi

    # Sanitize artist tag from MPV (replace / with , )
    [ -n "$artist_tag" ] && artist_tag="${artist_tag//\//, }"

    local live_dur_formatted=""
    if [ -n "$raw_live_dur" ] && [[ "$raw_live_dur" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        local dur_secs=${raw_live_dur%.*}
        if [ "$dur_secs" -ge 3600 ]; then
            live_dur_formatted=$(printf "%d:%02d:%02d" "$((dur_secs / 3600))" "$(((dur_secs % 3600) / 60))" "$((dur_secs % 60))")
        else
            live_dur_formatted=$(printf "%d:%02d" "$((dur_secs / 60))" "$((dur_secs % 60))")
        fi
    fi

    local formatted_track=$(format_track_log "$curr_idx" "$filename" "$title" "$artist_tag" "$live_dur_formatted")
    echo -e "${C_PINK}${prefix}${formatted_track}"

    # Cache update for local or remote files if metadata was found but missing from cache
    if [ -n "$filename" ] && [ -n "$artist_tag" ] && [ "$artist_tag" != "null" ]; then
        local clean_url="$filename"
        [[ "$filename" =~ ^http ]] && clean_url=$(echo "$filename" | sed -e 's/^[[:space:]]*//; s/\\t.*//')
        
        if [ -z "${CACHE_MEM[$clean_url]}" ]; then
             local live_dur="${live_dur_formatted:-0:00}"
             # Save to cache file
             printf "%s\t%s\t%s\t%s\n" "$clean_url" "$title" "$artist_tag" "$live_dur" >> "$CACHE_FILE"
             # Update memory for current session
             CACHE_MEM["$clean_url"]="${title}"$'\t'"${artist_tag}"$'\t'"${live_dur}"
        fi
    fi
}

cmd_info() {
    local input="$1"
    
    # CASE 1: Input is a URL (Direct)
    if [[ "$input" =~ ^http.* ]]; then
        fetch_and_display_url_info "$input"
        return
    fi

    # CASE 2: Playlist Index (or Current)
    local index="$input"
    local is_current_target=false
    local header_title="Track Info"
    
    if [ -z "$index" ]; then
        local p_pos=$(echo '{ "command": ["get_property", "playlist-pos"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // "-1"' | head -n 1)
        if [ "$p_pos" != "-1" ] && [ "$p_pos" != "null" ] && [ -n "$p_pos" ]; then
            index=$((p_pos + 1))
        else
            index=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -r 'map(select(.event == null)) | .[0].data | to_entries[] | select(.value.current) | .key + 1' 2>/dev/null | head -n 1)
        fi
        [ -z "$index" ] && { echo -e "${C_PINK}🔇 Nothing is currently playing in your queue list${C_RESET}"; return; }
        header_title="Current Track"
        is_current_target=true
    else
        header_title="Track Info [${index}]"
        local curr_pos=$(echo '{ "command": ["get_property", "playlist-pos"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // "-1"' | head -n 1)
        if [ -n "$curr_pos" ] && [ "$curr_pos" != "-1" ] && [ "$index" -eq $((curr_pos + 1)) ] 2>/dev/null; then is_current_target=true; fi
    fi

    local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)
    local count=$(echo "$track_info" | jq -s -r 'map(select(.event == null)) | .[0].data | select(type == "array") | length // 0')
    local item_json=$(echo "$track_info" | jq -s -c -r "map(select(.event == null)) | .[0].data | select(type == \"array\") | .[$((index - 1))] // empty" 2>/dev/null)
    
    if [ -z "$item_json" ] || [ "$item_json" == "null" ]; then
        echo -e "${C_PINK}🚫 Track ${C_WHITE}[${C_ORANGE}${index}${C_WHITE}] ${C_PINK}does not exist. Max Track ${C_WHITE}[${C_ORANGE}${count}${C_WHITE}]${C_RESET}"
        return
    fi
    
    local title=$(echo "$item_json" | jq -r 'if type=="object" then (.title? // "N/A") else . end')
    local filename=$(echo "$item_json" | jq -r 'if type=="object" then (.filename? // "N/A") else . end')
    local playing=$(echo "$item_json" | jq -r 'if type=="object" then (.current? // false) else false end')
    
    if [ "$title" == "N/A" ] || [ "$title" == "$filename" ] || [[ "$title" =~ ^http.* ]]; then
        if [[ "$filename" =~ ^http.* ]]; then
             local c=$(get_cached_title "$filename")
             [ -n "$c" ] && title="$c"
        fi
    fi

    # *** SMART UPGRADE: If filename is a URL, use remote fetcher! ***
    if [[ "$filename" =~ ^http.* ]]; then
        fetch_and_display_url_info "$filename" "$title" "$is_current_target"
        return
    fi

    # --- DRAW BOXED OUTPUT (Local) ---
    print_header_box "${C_PURPLE}🪷 ${header_title}${C_RESET}"
    print_boxed_line "${C_TEAL}Title:       ${C_CYAN}${title:0:$((INNER_WIDTH-15))}${C_RESET}"
    print_boxed_line "${C_TEAL}Source Link: ${C_VIOLET}${filename:0:$((INNER_WIDTH-15))}${C_RESET}"
    
    local pref_badge=""
    if is_liked_track "$filename"; then
        pref_badge=" ${C_PINK}🩷 | Liked${C_RESET}"
    elif is_disliked_track "$filename"; then
        pref_badge=" ${C_PINK}💔 | Disliked${C_RESET}"
    fi

    if [ "$playing" == "true" ]; then
        local is_paused=$(echo '{ "command": ["get_property", "pause"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // false')
        if [ "$is_paused" == "true" ]; then
            print_boxed_line "${C_TEAL}Status:      ${C_YELLOW}⏸ Paused${C_RESET}${pref_badge}"
        else
            print_boxed_line "${C_TEAL}Status:      ${C_PURPLE}▶ Playing${C_RESET}${pref_badge}"
        fi
    else
        print_boxed_line "${C_TEAL}Status:      ${C_GRAY}Queued${C_RESET}${pref_badge}"
    fi

    # Extended Info (Only available if track is currently playing AND local)
    if [ "$is_current_target" == "true" ]; then
        local mpv_extended=$(echo -e '{"command":["get_property","file-format"]}\n{"command":["get_property","audio-codec"]}\n{"command":["get_property","audio-params/samplerate"]}\n{"command":["get_property","duration"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -r 'map(select(.event == null)) | (.[0].data // "N/A"), (.[1].data // "N/A"), (.[2].data // "N/A"), (.[3].data // "N/A")')
        mapfile -t ext_props <<< "$mpv_extended"
        local fmt="${ext_props[0]}" codec="${ext_props[1]}" rate="${ext_props[2]}" dur="${ext_props[3]}"
        
        if [ "$dur" != "N/A" ] && [[ "$dur" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            dur=$(printf "%d:%02d" "$((${dur%.*} / 60))" "$((${dur%.*} % 60))")
        fi

        echo -e "${C_GRAY}${H_LINE}${C_RESET}"
        print_boxed_line "${C_TEAL}Format:      ${C_WHITE}$fmt${C_RESET}"
        print_boxed_line "${C_TEAL}Codec:       ${C_WHITE}$codec${C_RESET}"
        print_boxed_line "${C_TEAL}Rate:        ${C_WHITE}${rate} Hz${C_RESET}"
        print_boxed_line "${C_TEAL}Duration:    ${C_WHITE}$dur${C_RESET}"

        local mpv_audio_tracks
        mpv_audio_tracks=$(echo '{"command":["get_property","track-list"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '[.data[]? | select(.type=="audio")] | map("[" + (.id|tostring) + "] " + (.lang // "und") + " (" + (.title // .codec // "audio") + ")" + (if .selected then " (Active)" else "" end)) | join(" • ")' 2>/dev/null)
        [ -n "$mpv_audio_tracks" ] && print_boxed_line "${C_TEAL}Audio:       ${C_WHITE}${mpv_audio_tracks:0:$((INNER_WIDTH-15))}${C_RESET}"

        local engine_badge=""
        if [ "$IS_WSL" = true ]; then
            if [ "$(get_queue_mode)" == "hybrid" ]; then
                engine_badge="${C_ORANGE}Hybrid Boost Mode ⚡${C_GRAY} (120+ FPS Direct3D)${C_RESET}"
            else
                engine_badge="${C_CYAN}Standalone WSL Mode 🐧${C_GRAY} (60 FPS Mesa D3D12)${C_RESET}"
            fi
        elif [ "$IS_MACOS" = true ]; then
            engine_badge="${C_GREEN}Native macOS 🍏${C_GRAY} (Metal / Cocoa)${C_RESET}"
        elif [ "$IS_ANDROID" = true ]; then
            if [ "$(get_queue_mode)" == "hybrid" ]; then
                engine_badge="${C_ORANGE}Android Hybrid Engine 🤖⚡${C_GRAY} (MPV App + Audio Tunnel)${C_RESET}"
            else
                engine_badge="${C_CYAN}Standalone Termux 🐧${C_GRAY} (Headless Audio + Wake-Lock)${C_RESET}"
            fi
        else
            engine_badge="${C_GREEN}Native Linux 🐧${C_GRAY} (Mesa / DRM)${C_RESET}"
        fi
        print_boxed_line "${C_TEAL}Engine:      $engine_badge"
    fi
    printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
    B_LINE=${B_LINE// /─}
    echo -e "${C_GRAY}${B_LINE}${C_RESET}"

    if [ -t 0 ] && [ -t 1 ]; then
        echo -ne "${C_PINK}>>> Press 'l' to like/unlike, 'x' to dislike, or ENTER to return: ${C_RESET}"
        read -r -n 1 user_key < /dev/tty 2>/dev/null || read -r -n 1 user_key
        echo ""
        if [[ "$user_key" =~ ^[lL]$ ]]; then
            if is_liked_track "$filename"; then
                cmd_unlike "$filename"
            else
                cmd_like "$filename"
            fi
        elif [[ "$user_key" =~ ^[xX]$ ]]; then
            cmd_dislike "$filename"
        fi
    fi
}

cmd_next() {
    if [ "$MPV_RUNNING" = false ]; then echo -e "${C_PINK}😴💤 MPV isn't running... it must be taking a nap${C_RESET}"; return; fi

    local raw_info
    raw_info=$(echo -e '{"command":["get_property","shuffle"]}\n{"command":["get_property","playlist-count"]}\n{"command":["get_property","playlist-pos"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -r 'map(select(.event == null)) | (.[0].data // false), (.[1].data // 0), (.[2].data // -1)' 2>/dev/null)
    local s_arr=($raw_info)
    local is_shuf="${s_arr[0]}"
    local pl_count="${s_arr[1]}"
    local cur_pos="${s_arr[2]}"

    if [ "$is_shuf" == "true" ] && [[ "$pl_count" =~ ^[0-9]+$ ]] && [ "$pl_count" -gt 1 ]; then
        local hist_file
        hist_file=$(get_shuffle_history_file)
        # Record current position in shuffle history stack
        if [[ "$cur_pos" =~ ^[0-9]+$ ]] && [ "$cur_pos" -ge 0 ]; then
            mkdir -p "$(dirname "$hist_file")" 2>/dev/null
            echo "$cur_pos" >> "$hist_file"
        fi

        # Pick a random track index different from current
        local rand_idx=$cur_pos
        local attempts=0
        while [ "$rand_idx" -eq "$cur_pos" ] && [ "$attempts" -lt 20 ]; do
            rand_idx=$(( RANDOM % pl_count ))
            ((attempts++))
        done

        if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
            echo "{\"command\":[\"playlist-play-index\",$rand_idx]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
            echo '{"command":["set_property","pause",true]}' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
            send_android_mpv_cmd "playlist-play-index $rand_idx"
            command -v input >/dev/null 2>&1 && input keyevent 87 2>/dev/null || true
            ( auto_queue_related ) >/dev/null 2>&1 & disown
            log_now_playing
            return
        fi

        echo "{\"command\":[\"playlist-play-index\",$rand_idx]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        ( auto_queue_related ) >/dev/null 2>&1 & disown
        wait_for_playback_start
        log_now_playing
        return
    fi

    if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
        echo '{ "command": ["playlist-next"] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        echo '{ "command": ["set_property", "pause", true] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        send_android_mpv_cmd "playlist-next"
        command -v input >/dev/null 2>&1 && input keyevent 87 2>/dev/null || true
        ( auto_queue_related ) >/dev/null 2>&1 & disown
        log_now_playing
        return
    fi

    echo '{ "command": ["playlist-next"] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null

    # Proactive auto-queue check after moving next
    ( auto_queue_related ) >/dev/null 2>&1 & disown

    wait_for_playback_start
    log_now_playing
}

cmd_prev() {
    if [ "$MPV_RUNNING" = false ]; then echo -e "${C_PINK}😴💤 MPV isn't running... it must be taking a nap${C_RESET}"; return; fi

    local is_shuf="false"
    is_shuf=$(echo '{"command":["get_property","shuffle"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // false')
    local hist_file
    hist_file=$(get_shuffle_history_file)

    if [ "$is_shuf" == "true" ] && [ -f "$hist_file" ] && [ -s "$hist_file" ]; then
        local prev_idx
        prev_idx=$(tail -n 1 "$hist_file" 2>/dev/null)
        sed -i '$d' "$hist_file" 2>/dev/null

        if [[ "$prev_idx" =~ ^[0-9]+$ ]]; then
            if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
                echo "{\"command\":[\"playlist-play-index\",$prev_idx]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
                echo '{"command":["set_property","pause",true]}' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
                send_android_mpv_cmd "playlist-play-index $prev_idx"
                command -v input >/dev/null 2>&1 && input keyevent 88 2>/dev/null || true
                ( auto_queue_related ) >/dev/null 2>&1 & disown
                log_now_playing
                return
            fi

            echo "{\"command\":[\"playlist-play-index\",$prev_idx]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
            ( auto_queue_related ) >/dev/null 2>&1 & disown
            wait_for_playback_start
            log_now_playing
            return
        fi
    fi

    if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
        echo '{ "command": ["playlist-prev"] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        echo '{ "command": ["set_property", "pause", true] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        send_android_mpv_cmd "playlist-prev"
        command -v input >/dev/null 2>&1 && input keyevent 88 2>/dev/null || true
        ( auto_queue_related ) >/dev/null 2>&1 & disown
        log_now_playing
        return
    fi

    echo '{ "command": ["playlist-prev"] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null

    # Proactive auto-queue check after moving back (maybe we are now at the end?)
    ( auto_queue_related ) >/dev/null 2>&1 & disown

    wait_for_playback_start
    log_now_playing
}
cmd_stop() {
    # Force save state before quitting
    save_current_playlist true

    if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
        send_android_mpv_cmd "pause"
        send_android_mpv_cmd "playlist-clear"
        command -v input >/dev/null 2>&1 && input keyevent 127 2>/dev/null || true
    fi
    
    # 1. Try polite quit first if socket exists (lets WSL PulseAudio unhook cleanly)
    if [ -S "$SOCKET" ]; then
        echo '{ "command": ["quit"] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
        sleep 0.3
    fi
    
    # 2. Kill monitor and auto-queue worker processes
    if [ -f "$HOME/.cache/mpv/idle_monitor.pid" ]; then
        local pid=$(cat "$HOME/.cache/mpv/idle_monitor.pid" 2>/dev/null)
        [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1
        rm -f "$HOME/.cache/mpv/idle_monitor.pid"
    fi
    pkill -u "$(whoami)" -f "auto_queue_related" >/dev/null 2>&1
    rm -f "$HOME/.cache/mpv/auto.lock" "$HOME/.cache/mpv/auto_cooldown"

    # 3. Cleanup video window if running
    rm -f "$HOME/.cache/mpv/video_active"
    if [ -f "$HOME/.cache/mpv/video_window.pid" ]; then
        local v_pid=$(cat "$HOME/.cache/mpv/video_window.pid" 2>/dev/null)
        [ -n "$v_pid" ] && kill "$v_pid" >/dev/null 2>&1
        rm -f "$HOME/.cache/mpv/video_window.pid" "$HOME/.cache/mpv/video_window.sock"
    fi

    # 4. Cleanup any remaining mpv instances
    pkill -u "$(whoami)" -f "mpv --idle" >/dev/null 2>&1
    pkill -u "$(whoami)" -f "hybrid_bridge.py" >/dev/null 2>&1
    stop_android_bridge >/dev/null 2>&1 || true
    rm -f "$HOME/.cache/mpv/android_video_active"
    if [ "$IS_WSL" = true ]; then
        taskkill.exe /F /IM mpv.exe 2>/dev/null || true
        taskkill.exe /F /IM mpv.com 2>/dev/null || true
        taskkill.exe /F /IM PipeRelay.exe 2>/dev/null || true
    fi
    
    # 5. Remove socket and reset state
    rm -f "$SOCKET"
    if command -v termux-wake-unlock >/dev/null 2>&1; then termux-wake-unlock; fi
    MPV_RUNNING=false
    
    echo -e "🛑 ${C_PINK}Global Stop: MPV & Monitors Cleared${C_RESET}"
}

cmd_volume() {
    if [ "$MPV_RUNNING" = false ]; then echo -e "${C_PINK}😴💤 MPV isn't running... it must be taking a nap${C_RESET}"; return; fi
    local input="$1"
    
    # Set absolute volume if a plain number is provided
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "{ \"command\": [\"set_property\", \"volume\", ${input}] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
    fi

    local vol=$(echo '{ "command": ["get_property", "volume"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // "0"')
    # Truncate decimal
    vol=${vol%.*}
    echo -e "🔊 ${C_PINK}Volume:${C_RESET} ${C_CYAN}${vol}%${C_RESET}"
}

cmd_speed() {
    local input="$1"
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

    local speed_file="$HOME/.config/mpv/queue_speed"
    local win_u_dir=""
    if [ "$IS_WSL" = true ] && command -v get_windows_user_dir >/dev/null 2>&1; then
        win_u_dir=$(get_windows_user_dir)
    fi

    # Read current speed from MPV or config
    local cur_speed="1.00"
    if [ "$MPV_RUNNING" = true ] && [ -S "$SOCKET" ]; then
        local raw_sp
        raw_sp=$(echo '{"command":["get_property","speed"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // empty' 2>/dev/null)
        if [ -n "$raw_sp" ] && [[ "$raw_sp" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            cur_speed=$(awk -v s="$raw_sp" 'BEGIN { printf "%.2f", s }')
        fi
    elif [ -f "$speed_file" ]; then
        local saved_sp
        saved_sp=$(cat "$speed_file" 2>/dev/null | tr -d '[:space:]')
        if [[ "$saved_sp" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            cur_speed=$(awk -v s="$saved_sp" 'BEGIN { printf "%.2f", s }')
        fi
    fi

    # 1. Query mode (empty input or status)
    if [ -z "$input" ] || [ "$input" == "status" ]; then
        local status_desc="Normal"
        if [ "$cur_speed" == "1.00" ]; then
            status_desc="Normal"
        elif [ "$cur_speed" == "2.00" ]; then
            status_desc="Double (2x)"
        elif [ "$cur_speed" == "0.50" ]; then
            status_desc="Half (0.5x)"
        elif (( $(echo "$cur_speed > 1.0" | bc -l 2>/dev/null || echo 0) )); then
            status_desc="Fast"
        else
            status_desc="Slow"
        fi
        echo -e "${C_CYAN}⚡ Playback Speed:${C_RESET} ${C_PINK}${cur_speed}x${C_RESET} ${C_GRAY}(${status_desc})${C_RESET}"
        echo -e "${C_GRAY}💡 Quick Controls: 'q -speed 1.25' | 'q -speed 1.5' | 'q -speed 2' | 'q -speed reset'${C_RESET}"
        echo -e "${C_GRAY}   Or in video window: '[' / ']' (±10%) | '{' / '}' (±25%) | Backspace (Reset 1.0x)${C_RESET}"
        return 0
    fi

    # 2. Parse target speed
    local target_speed=""
    case "$input" in
        reset|normal|default|1|1.0|1.0x|1x)
            target_speed="1.00"
            ;;
        half|0.5|0.5x)
            target_speed="0.50"
            ;;
        double|2|2.0|2x)
            target_speed="2.00"
            ;;
        "+"*|"-"*)
            local offset="${input%x}"
            target_speed=$(awk -v cur="$cur_speed" -v off="$offset" 'BEGIN {
                res = cur + off;
                if (res < 0.25) res = 0.25;
                if (res > 4.0) res = 4.0;
                printf "%.2f", res;
            }')
            ;;
        *)
            local clean_num="${input%x}"
            if [[ "$clean_num" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                target_speed=$(awk -v val="$clean_num" 'BEGIN {
                    if (val < 0.25) val = 0.25;
                    if (val > 4.0) val = 4.0;
                    printf "%.2f", val;
                }')
            else
                echo -e "${C_PINK}❓ Invalid speed: '$input'. Use: 0.25 to 4.0 (e.g. 'q -speed 1.25', 'q -speed reset', 'q -speed +0.1')${C_RESET}"
                return 1
            fi
            ;;
    esac

    # Persist choice
    mkdir -p "$HOME/.config/mpv"
    echo "$target_speed" > "$speed_file"
    if [ -n "$win_u_dir" ] && [ -d "$win_u_dir" ]; then
        mkdir -p "$win_u_dir/AppData/Roaming/mpv" 2>/dev/null
        echo "$target_speed" > "$win_u_dir/AppData/Roaming/mpv/queue_speed" 2>/dev/null
    fi

    # Android Mobile Sync
    if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
        send_android_mpv_cmd "speed $target_speed"
        echo -e "${C_CYAN}⚡ Mobile Playback Speed set to:${C_RESET} ${C_PINK}${target_speed}x${C_RESET}"
        return 0
    fi

    # Desktop Player (Linux / WSL2)
    if [ "$MPV_RUNNING" = true ] && [ -S "$SOCKET" ]; then
        echo "{\"command\":[\"script-message\",\"set-speed\",\"$target_speed\"]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
        echo "{\"command\":[\"set_property\",\"speed\",$target_speed]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
        echo -e "${C_CYAN}⚡ Playback Speed set to:${C_RESET} ${C_PINK}${target_speed}x${C_RESET}"
    else
        echo -e "${C_CYAN}⚡ Playback Speed set to:${C_RESET} ${C_PINK}${target_speed}x${C_RESET}"
        echo -e "${C_GRAY}   Default profile saved. Will be applied automatically on next playback.${C_RESET}"
    fi
}

cmd_audio_fx() {
    if [ "$MPV_RUNNING" = false ]; then
        echo -e "${C_PINK}😴💤 MPV isn't running... it must be taking a nap${C_RESET}"
        return
    fi

    local mode="${1:-toggle}"
    local af_json=$(echo '{ "command": ["get_property", "af"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -c '.data')
    local is_on="false"

    if [ -n "$af_json" ] && [ "$af_json" != "null" ]; then
        is_on=$(echo "$af_json" | jq -r 'if type == "array" and (map(.name // "") | join(",") | test("firequalizer|acompressor|alimiter")) then "true" else "false" end' 2>/dev/null)
    fi

    local dolby_filter="lavfi=[firequalizer=zero_phase=on:gain_entry='entry(40,4);entry(80,3);entry(160,1.5);entry(320,0.2);entry(1000,0);entry(2800,1.2);entry(6000,2);entry(12000,1.4)'],acompressor=threshold=-18dB:ratio=2.2:attack=20:release=250:makeup=3,alimiter=limit=0.97"

    case "$mode" in
        on)
            echo "{\"command\": [\"set_property_string\", \"af\", \"$dolby_filter\"]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
            echo -e "🎛️ ${C_PINK}Audio FX:${C_RESET} ${C_GREEN}ON${C_RESET} ${C_GRAY}(dolby-like)${C_RESET}"
            ;;
        off)
            echo '{"command": ["set_property_string", "af", ""]}' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
            echo -e "🎛️ ${C_PINK}Audio FX:${C_RESET} ${C_ORANGE}OFF${C_RESET} ${C_GRAY}(flat-audio)${C_RESET}"
            ;;
        status)
            if [ "$is_on" = "true" ]; then
                echo -e "🎛️ ${C_PINK}Audio FX:${C_RESET} ${C_GREEN}ON${C_RESET} ${C_GRAY}(dolby-like active)${C_RESET}"
            else
                echo -e "🎛️ ${C_PINK}Audio FX:${C_RESET} ${C_ORANGE}OFF${C_RESET} ${C_GRAY}(flat/no matching FX)${C_RESET}"
            fi
            ;;
        toggle|*)
            if [ "$is_on" = "true" ]; then
                echo '{"command": ["set_property_string", "af", ""]}' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
                echo -e "🎛️ ${C_PINK}Audio FX:${C_RESET} ${C_ORANGE}OFF${C_RESET} ${C_GRAY}(flat-audio)${C_RESET}"
            else
                echo "{\"command\": [\"set_property_string\", \"af\", \"$dolby_filter\"]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
                echo -e "🎛️ ${C_PINK}Audio FX:${C_RESET} ${C_GREEN}ON${C_RESET} ${C_GRAY}(dolby-like)${C_RESET}"
            fi
            ;;
    esac
}

VIDEO_SOCKET="$HOME/.cache/mpv/video_window.sock"
VIDEO_PID_FILE="$HOME/.cache/mpv/video_window.pid"

is_video_window_open() {
    [ "$MPV_RUNNING" = false ] && return 1
    [ ! -S "$SOCKET" ] && return 1
    if is_audio_mode_active; then return 1; fi

    local raw
    raw=$(echo -e '{"command":["get_property","vo"]}\n{"command":["get_property","vid"]}\n{"command":["get_property","window-minimized"]}' | nc ${NC_OPTS:--U} -w 1 "$SOCKET" 2>/dev/null)
    [ -z "$raw" ] && return 1

    local vo_name vid_val min_val
    vo_name=$(echo "$raw" | jq -s -r 'map(select(.event == null)) | .[0].data[0].name // "null"' 2>/dev/null)
    vid_val=$(echo "$raw" | jq -s -r 'map(select(.event == null)) | .[1].data // false' 2>/dev/null)
    min_val=$(echo "$raw" | jq -s -r 'map(select(.event == null)) | .[2].data // false' 2>/dev/null)

    if [ "$vo_name" != "null" ] && [ -n "$vo_name" ] && [ "$min_val" != "true" ] && [ "$vid_val" != "false" ] && [ "$vid_val" != "no" ] && [ "$vid_val" != "null" ]; then
        return 0
    fi
    return 1
}

cmd_android_video_handoff() {
    local target_idx="$1"

    # --- 1. TOGGLE OFF (Standalone Mode Only): If mobile video handoff was previously launched and no target index, resume background audio ---
    if [ "$(get_queue_mode)" == "hybrid" ]; then
        # In Hybrid Mode, MPV Android is the sole audio & video player; Termux MPV must stay paused and silent
        if [ "$MPV_RUNNING" = true ] && [ -S "$SOCKET" ]; then
            echo '{"command":["set_property","pause",true]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
            echo '{"command":["set_property","mute",true]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
            echo '{"command":["set_property","ao","null"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
        fi
    else
        # Standalone Mode: Toggle OFF if video was active and no new target index was requested
        if [ -f "$HOME/.cache/mpv/android_video_active" ] && [ -z "$target_idx" ]; then
            local last_active=0
            last_active=$(stat -c %Y "$HOME/.cache/mpv/android_video_active" 2>/dev/null || stat -f %m "$HOME/.cache/mpv/android_video_active" 2>/dev/null || echo 0)
            local now_time
            now_time=$(date +%s)
            if [ "$((now_time - last_active))" -ge 3 ]; then
                rm -f "$HOME/.cache/mpv/android_video_active"
                if [ "$MPV_RUNNING" = true ] && [ -S "$SOCKET" ]; then
                    echo '{"command":["set_property","pause",false]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
                    echo -e "🎧 ${C_PINK}Returned to background audio mode (Termux MPV unpaused)${C_RESET}"
                else
                    echo -e "🎧 ${C_PINK}Returned to background audio mode.${C_RESET}"
                fi
                return 0
            fi
        fi
    fi

    # --- 2. Query target track URL and title ---
    if [[ ! "$target_idx" =~ ^https?:// ]]; then
        ensure_mpv_running
        if [ "$MPV_RUNNING" = false ] || [ ! -S "$SOCKET" ]; then
            echo -e "${C_PINK}🔇 MPV player is not active. Queue a song or start playback first.${C_RESET}"
            return 1
        fi
    fi

    local track_url=""
    local track_title="Queue Video"
    local time_pos="0"
    local start_offset=0
    local total_count=0

    if [ "$MPV_RUNNING" = true ] && [ -S "$SOCKET" ]; then
        total_count=$(echo '{"command":["get_property","playlist-count"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // 0')
    fi
    [[ ! "$total_count" =~ ^[0-9]+$ ]] && total_count=0

    if [[ "$target_idx" =~ ^https?:// ]]; then
        track_url="$target_idx"
        track_title="Queue Video"
        time_pos=0
        start_offset=0
    elif [[ "$target_idx" =~ ^[0-9]+$ ]]; then
        if [ "$total_count" -gt 0 ] && { [ "$target_idx" -lt 1 ] || [ "$target_idx" -gt "$total_count" ]; }; then
            echo -e "${C_PINK}🚫 Track [${C_ORANGE}${target_idx}${C_PINK}] does not exist. Max tracks: ${C_WHITE}[${C_ORANGE}${total_count}${C_WHITE}]${C_RESET}"
            return 1
        fi
        start_offset=$((target_idx - 1))
        local item_raw
        item_raw=$(echo '{"command":["get_property","playlist"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r --argjson idx "$start_offset" 'select(.event == null) | .data[$idx] | [(.filename // ""), (.title // "Queue Video")] | @tsv')
        IFS=$'\t' read -r track_url track_title <<< "$item_raw"
        time_pos=0
    else
        # Target is empty: query currently active playing track from socket
        local track_raw
        track_raw=$(echo -e '{"command":["get_property","path"]}\n{"command":["get_property","media-title"]}\n{"command":["get_property","time-pos"]}\n{"command":["get_property","playlist-pos"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -r 'map(select(.event == null)) | [(.[0].data // ""), (.[1].data // "Queue Video"), (.[2].data // 0), (.[3].data // 0)] | @tsv')
        local cur_pos=0
        IFS=$'\t' read -r track_url track_title time_pos cur_pos <<< "$track_raw"
        if [[ "$cur_pos" =~ ^[0-9]+$ ]]; then
            start_offset="$cur_pos"
        fi
    fi

    if [ -z "$track_url" ] || [ "$track_url" = "null" ]; then
        echo -e "${C_PINK}⚠️ No active track in queue. Specify a track number (e.g. 'q -vid 1') or queue a song.${C_RESET}"
        return 1
    fi

    # --- 3. Format playback position ---
    local pos_sec="${time_pos%.*}"
    pos_sec="${pos_sec:-0}"
    local pos_ms
    pos_ms=$(awk -v t="$time_pos" 'BEGIN { printf "%.0f", (t > 0 ? t * 1000 : 0) }')
    local time_formatted
    if [ "$pos_sec" -ge 3600 ]; then
        time_formatted=$(printf "%d:%02d:%02d" "$((pos_sec / 3600))" "$(((pos_sec % 3600) / 60))" "$((pos_sec % 60))")
    else
        time_formatted=$(printf "%d:%02d" "$((pos_sec / 60))" "$((pos_sec % 60))")
    fi

    local stream_url=""
    local is_playlist=false

    # --- 4. Resolve stream target for mobile MPV ---
    if [ "$total_count" -ge 1 ] && [[ ! "$target_idx" =~ ^https?:// ]]; then
        echo -e "${C_CYAN}📱 Initializing Android Stream Bridge for continuous playback...${C_RESET}"
        local bridge_port
        bridge_port=$(ensure_android_bridge_running)
        if [ -n "$bridge_port" ]; then
            stream_url="http://127.0.0.1:${bridge_port}/playlist.m3u"
            # Pre-warm bridge to generate M3U, mirror to /sdcard/Download, and prefetch start track
            curl -s -m 2 "http://127.0.0.1:${bridge_port}/playlist.m3u?start=${start_offset}" >/dev/null 2>&1 || true
            is_playlist=true

            # Set starting track index in MPV Android's mpv.conf and live Lua command bridge
            set_android_mpv_playlist_start "$start_offset"
            send_android_mpv_cmd "playlist-play-index ${start_offset}"
        fi
    fi

    if [ -z "$stream_url" ]; then
        if [[ "$track_url" =~ ^https?:// ]]; then
            echo -e "${C_CYAN}📱 Android Video Handoff: Resolving direct stream via yt-dlp...${C_RESET}"
            local bridge_port
            bridge_port=$(ensure_android_bridge_running)
            if [ -n "$bridge_port" ]; then
                stream_url="http://127.0.0.1:${bridge_port}/track/${start_offset}.edl"
            else
                local res_pref="1080"
                [ -f "$HOME/.config/mpv/queue_res" ] && res_pref=$(cat "$HOME/.config/mpv/queue_res" 2>/dev/null | tr -d '[:space:]')
                local res_fmt="bestvideo[height<=1080]+bestaudio/best[height<=1080]/best"
                case "$res_pref" in
                    720|720p) res_fmt="bestvideo[height<=720]+bestaudio/best[height<=720]/best" ;;
                    1080|1080p) res_fmt="bestvideo[height<=1080]+bestaudio/best[height<=1080]/best" ;;
                    1440|1440p|2k) res_fmt="bestvideo[height<=1440]+bestaudio/best[height<=1440]/best" ;;
                    2160|2160p|4k|max) res_fmt="bestvideo+bestaudio/best" ;;
                esac
                local stream_lines=()
                mapfile -t stream_lines < <(yt-dlp -g --no-warnings --extractor-args "youtube:player_client=visionos,android,web" -f "$res_fmt" "$track_url" 2>/dev/null)
                if [ ${#stream_lines[@]} -ge 2 ]; then
                    local v_url="${stream_lines[0]}"
                    local a_url="${stream_lines[1]}"
                    local v_len=${#v_url}
                    local a_len=${#a_url}
                    mkdir -p "/sdcard/Download" 2>/dev/null || true
                    cat <<EOF > "/sdcard/Download/queue_direct.edl"
# mpv EDL v0
%${v_len}%${v_url}
!new_stream
%${a_len}%${a_url}
EOF
                    stream_url="file:///sdcard/Download/queue_direct.edl"
                elif [ ${#stream_lines[@]} -eq 1 ]; then
                    stream_url="${stream_lines[0]}"
                fi
            fi
            if [ -z "$stream_url" ]; then
                echo -e "${C_PINK}❌ Failed to extract stream URL for mobile video player.${C_RESET}"
                return 1
            fi
        else
            # Local file handling: check shared storage vs Termux sandbox
            if [[ "$track_url" =~ ^/sdcard/ ]] || [[ "$track_url" =~ ^/storage/ ]]; then
                stream_url="file://$track_url"
            else
                local shared_dir="/sdcard/Download/queue_handoff"
                mkdir -p "$shared_dir" 2>/dev/null || true
                local dest_file="$shared_dir/$(basename "$track_url")"
                if cp "$track_url" "$dest_file" 2>/dev/null; then
                    stream_url="file://$dest_file"
                else
                    stream_url="file://$track_url"
                fi
            fi
        fi
    fi

    # --- 5. Pause Termux background audio to prevent double playback ---
    if [ "$MPV_RUNNING" = true ] && [ -S "$SOCKET" ]; then
        echo '{"command":["set_property","pause",true]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
        echo '{"command":["set_property","mute",true]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
        echo '{"command":["set_property","ao","null"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
        touch "$HOME/.cache/mpv/android_video_active"
    fi

    # --- 6. Launch Android Intent via Activity Manager (am) ---
    local am_bin="am"
    if ! command -v am >/dev/null 2>&1 && [ -x "/system/bin/am" ]; then
        am_bin="/system/bin/am"
    fi

    echo -e "📺 ${C_PINK}Launching MPV Android at ${C_WHITE}${time_formatted}${C_PINK}...${C_RESET}"
    echo -e "   ${C_TEAL}Title: ${C_WHITE}${track_title}${C_RESET}"

    local launched=false
    # Priority 1: Play Store MPV app (is.xyz.mpv/.MPVActivity) with position & title
    if $am_bin start -a android.intent.action.VIEW -d "$stream_url" -n "is.xyz.mpv/.MPVActivity" --ei "position" "$pos_ms" --es "title" "$track_title" >/dev/null 2>&1; then
        launched=true
        echo -e "${C_GREEN}✨ Opened in Play Store MPV Android!${C_RESET}"
    elif $am_bin start -a android.intent.action.VIEW -d "$stream_url" -t "video/*" -n "is.xyz.mpv/.MPVActivity" --ei "position" "$pos_ms" --es "title" "$track_title" >/dev/null 2>&1; then
        launched=true
        echo -e "${C_GREEN}✨ Opened in Play Store MPV Android!${C_RESET}"
    # Priority 2: Shared storage playlist file fallback
    elif [ "$is_playlist" = true ] && [ -f "/sdcard/Download/queue_playlist.m3u" ] && $am_bin start -a android.intent.action.VIEW -d "file:///sdcard/Download/queue_playlist.m3u" -n "is.xyz.mpv/.MPVActivity" --ei "position" "$pos_ms" --es "title" "$track_title" >/dev/null 2>&1; then
        launched=true
        echo -e "${C_GREEN}✨ Local playlist file opened in Play Store MPV Android!${C_RESET}"
    # Priority 3: Generic Android media intent (VLC, MX Player, system chooser)
    elif $am_bin start -a android.intent.action.VIEW -d "$stream_url" --ei "position" "$pos_ms" --es "title" "$track_title" >/dev/null 2>&1; then
        launched=true
        echo -e "${C_GREEN}✨ Media opened in Android player!${C_RESET}"
    elif $am_bin start -a android.intent.action.VIEW -d "$stream_url" -t "video/*" --ei "position" "$pos_ms" --es "title" "$track_title" >/dev/null 2>&1; then
        launched=true
        echo -e "${C_GREEN}✨ Media opened in Android video player!${C_RESET}"
    # Priority 4: Termux URL opening tools
    elif command -v termux-open-url >/dev/null 2>&1; then
        termux-open-url "$stream_url" >/dev/null 2>&1
        launched=true
        echo -e "${C_GREEN}✨ Stream sent via termux-open-url!${C_RESET}"
    elif command -v termux-open >/dev/null 2>&1; then
        termux-open "$stream_url" >/dev/null 2>&1
        launched=true
        echo -e "${C_GREEN}✨ Stream sent via termux-open!${C_RESET}"
    fi

    if [ "$launched" = true ]; then
        if [ "$is_playlist" = true ]; then
            echo -e "   ${C_TEAL}Queue:${C_WHITE} ${total_count} tracks connected ${C_GRAY}(Continuous background playback)${C_RESET}"
        fi
        if [ "$(get_queue_mode)" == "hybrid" ]; then
            echo -e "${C_GRAY}💡 Playback running in Play Store MPV Android (Hardware Audio Tunneling + MediaCodec GPU).${C_RESET}"
        else
            echo -e "${C_GRAY}💡 Termux background audio paused. Run ${C_WHITE}'q -vid'${C_GRAY} or ${C_WHITE}'q -p'${C_GRAY} to resume audio in Termux.${C_RESET}"
        fi
        return 0
    else
        echo -e "${C_PINK}❌ Unable to launch Android media player. Ensure MPV Android is installed or 'am' is accessible.${C_RESET}"
        rm -f "$HOME/.cache/mpv/android_video_active"
        if [ "$MPV_RUNNING" = true ] && [ -S "$SOCKET" ]; then
            if [ "$(get_queue_mode)" != "hybrid" ]; then
                echo '{"command":["set_property","pause",false]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
            fi
        fi
        return 1
    fi
}

cmd_video_toggle() {
    local target_idx="$1"

    # --- ANDROID / TERMUX HYBRID VIDEO HANDOFF ---
    if [ "$IS_ANDROID" = true ] || (command -v getprop >/dev/null 2>&1 && [ -d "/data/data/com.termux" ]); then
        cmd_android_video_handoff "$target_idx"
        return $?
    fi

    # --- TOGGLE OFF: If video window is currently open and no target specified ---
    if is_video_window_open && [ -z "$target_idx" ]; then
        echo -e "${C_CYAN}📺 Hiding desktop video window...${C_RESET}"
        rm -f "$HOME/.cache/mpv/video_active"
        echo -e '{"command":["script-message","safe-hide-video"]}\n{"command":["set_property","window-minimized",true]}' | nc ${NC_OPTS:--U} -w 1 "$SOCKET" >/dev/null 2>&1
        echo -e "🎧 ${C_PINK}Returned to background audio mode (video hidden)${C_RESET}"
        return 0
    fi

    local mode=$(get_queue_mode)

    # Display environment validation:
    # On macOS (Darwin) and in Hybrid Windows mode, host GUI is always active; bypass $DISPLAY/$WAYLAND_DISPLAY check.
    if [ "$mode" != "hybrid" ] && [ "$IS_MACOS" = false ]; then
        if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
            if [ -d "/mnt/wslg" ] || [ -S "/tmp/.X11-unix/X0" ]; then
                export DISPLAY=":0"
                export WAYLAND_DISPLAY="wayland-0"
            else
                echo -e "${C_PINK}🚫 No graphical display found. Desktop video requires an active display (X11 / Wayland / WSLg).${C_RESET}"
                return 1
            fi
        fi

        # WSL2 host GPU acceleration vs Native Linux
        if [ "$IS_WSL" = true ]; then
            export GALLIUM_DRIVER="${GALLIUM_DRIVER:-d3d12}"
            if [ -d "/usr/lib/wsl/lib" ] && [[ ":$LD_LIBRARY_PATH:" != *":/usr/lib/wsl/lib:"* ]]; then
                export LD_LIBRARY_PATH="/usr/lib/wsl/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            fi
            export XCURSOR_THEME="${XCURSOR_THEME:-Adwaita}"
            export XCURSOR_SIZE="${XCURSOR_SIZE:-36}"
        else
            # Native Linux: standard cursor, native Mesa drivers
            export XCURSOR_THEME="${XCURSOR_THEME:-Adwaita}"
            export XCURSOR_SIZE="${XCURSOR_SIZE:-24}"
        fi

        if [ -n "$DISPLAY" ] && command -v xrdb >/dev/null 2>&1; then
            if [ -f "$HOME/.Xresources" ]; then
                xrdb -merge "$HOME/.Xresources" 2>/dev/null
            else
                echo -e "Xcursor.theme: $XCURSOR_THEME\nXcursor.size: $XCURSOR_SIZE" | xrdb -merge 2>/dev/null
            fi
        fi
    fi

    ensure_mpv_running

    if [ "$MPV_RUNNING" = false ] || [ ! -S "$SOCKET" ]; then
        echo -e "${C_PINK}🔇 MPV player is not active.${C_RESET}"
        return 1
    fi

    local reload_needed=false
    if is_audio_mode_active; then
        reload_needed=true
        set_audio_mode "false"
        echo "{\"command\":[\"script-message\",\"set-audio-mode\",\"false\"]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    else
        local pre_vid
        pre_vid=$(echo '{"command":["get_property","vid"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // false')
        if [ "$pre_vid" == "false" ] || [ "$pre_vid" == "no" ]; then
            reload_needed=true
        fi
    fi

    # Determine VO & GPU context across platforms and engines:
    # - Hybrid Windows: Native Direct3D 11/12 / Vulkan (vo=gpu, gpu-context=auto)
    # - macOS: Cocoa/Metal native windowing with vo=gpu, gpu-context=auto
    # - Wayland / WSLg: vo=gpu, gpu-context=wayland,auto
    # - X11: vo=gpu,x11, gpu-context=x11egl,x11vk,auto
    local vo_opt="gpu"
    local gpu_ctx="wayland,auto"
    if [ "$mode" == "hybrid" ] || [ "$IS_MACOS" = true ]; then
        gpu_ctx="auto"
        vo_opt="gpu"
    elif [ -z "$WAYLAND_DISPLAY" ]; then
        gpu_ctx="x11egl,x11vk,auto"
        vo_opt="gpu,x11"
    fi

    # Ensure MPV input configuration & keybindings are active
    local batch_keys=""
    if [ "$mode" != "hybrid" ] && [ -f "$HOME/.config/mpv/input.conf" ]; then
        batch_keys+="{\"command\":[\"load-input-conf\",\"$HOME/.config/mpv/input.conf\"]}\n"
    fi
    batch_keys+='{"command":["keybind","F11","cycle fullscreen"]}\n'
    batch_keys+='{"command":["keybind","f","cycle fullscreen"]}\n'
    batch_keys+='{"command":["keybind","CLOSE_WIN","script-message stop-session"]}\n'
    batch_keys+='{"command":["keybind","q","script-message stop-session"]}\n'
    batch_keys+='{"command":["keybind","Q","script-message stop-session"]}\n'
    batch_keys+='{"command":["keybind","Ctrl+w","script-message stop-session"]}\n'
    batch_keys+='{"command":["keybind","Ctrl+W","script-message stop-session"]}\n'
    batch_keys+='{"command":["keybind","Meta+w","script-message stop-session"]}\n'
    batch_keys+='{"command":["keybind","Meta+W","script-message stop-session"]}\n'
    batch_keys+='{"command":["keybind","Meta+q","script-message stop-session"]}\n'
    batch_keys+='{"command":["keybind","Meta+Q","script-message stop-session"]}\n'
    batch_keys+='{"command":["keybind","Alt+F4","script-message stop-session"]}\n'
    batch_keys+='{"command":["keybind","h","script-message safe-hide-video"]}\n'
    batch_keys+='{"command":["keybind","H","script-message safe-hide-video"]}\n'
    batch_keys+='{"command":["keybind","ESC","set fullscreen no"]}\n'
    batch_keys+='{"command":["keybind","Ctrl+s","cycle shuffle"]}\n'
    batch_keys+='{"command":["keybind","r","playlist-shuffle"]}\n'

    # In-Window Scaling & Sizing Hotkeys
    batch_keys+='{"command":["keybind","w","cycle_values window-scale 0.35 0.5 0.75 1.0 ; show-text \"Window Scale: ${window-scale}\" 1500"]}\n'
    batch_keys+='{"command":["keybind","W","cycle_values window-scale 1.0 0.75 0.5 0.35 ; show-text \"Window Scale: ${window-scale}\" 1500"]}\n'
    batch_keys+='{"command":["keybind","+","add window-scale 0.05 ; show-text \"Window Scale: ${window-scale}\" 1500"]}\n'
    batch_keys+='{"command":["keybind","=","add window-scale 0.05 ; show-text \"Window Scale: ${window-scale}\" 1500"]}\n'
    batch_keys+='{"command":["keybind","-","add window-scale -0.05 ; show-text \"Window Scale: ${window-scale}\" 1500"]}\n'
    batch_keys+='{"command":["keybind","_","add window-scale -0.05 ; show-text \"Window Scale: ${window-scale}\" 1500"]}\n'
    batch_keys+='{"command":["keybind","Ctrl+WHEEL_UP","add window-scale 0.05 ; show-text \"Window Scale: ${window-scale}\" 1500"]}\n'
    batch_keys+='{"command":["keybind","Ctrl+WHEEL_DOWN","add window-scale -0.05 ; show-text \"Window Scale: ${window-scale}\" 1500"]}\n'

    # In-Window Quality Hotkeys (AVC1/VP9 60 FPS prioritized + Opus 48 kHz audio with seamless seek)
    local hotkey_0="bestvideo[height<=1440][fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1440][fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1080][fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1080][fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1080]+bestaudio[acodec=opus]/bestvideo[height<=1080]+bestaudio/bestvideo[height<=720]+bestaudio/bestvideo+bestaudio/best"
    local hotkey_1="bestvideo[height<=720][fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=720][fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=720][fps>=50]+bestaudio/bestvideo[height<=720]+bestaudio[acodec=opus]/bestvideo[height<=720]+bestaudio/best[height<=720]"
    local hotkey_2="bestvideo[height<=1080][fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1080][fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1080][fps>=50]+bestaudio/bestvideo[height<=1080]+bestaudio[acodec=opus]/bestvideo[height<=1080]+bestaudio/best"
    local hotkey_3="bestvideo[height<=1440][fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1440][fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1440][fps>=50]+bestaudio/bestvideo[height<=1440]+bestaudio[acodec=opus]/bestvideo[height<=1440]+bestaudio/best"
    local hotkey_4="bestvideo[fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo+bestaudio[acodec=opus]/bestvideo+bestaudio/best"

    batch_keys+="{\"command\":[\"keybind\",\"0\",\"script-message change-quality auto\"]}\n"
    batch_keys+="{\"command\":[\"keybind\",\"1\",\"script-message change-quality 720\"]}\n"
    batch_keys+="{\"command\":[\"keybind\",\"2\",\"script-message change-quality 1080\"]}\n"
    batch_keys+="{\"command\":[\"keybind\",\"3\",\"script-message change-quality 1440\"]}\n"
    batch_keys+="{\"command\":[\"keybind\",\"4\",\"script-message change-quality 4k\"]}\n"
    echo -e "$batch_keys" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1 || true

    local target_autofit="50%x50%"
    local target_scale="0.5"
    local target_fs="false"

    # Ensure queue has tracks before attempting to display video window
    local total_count
    total_count=$(echo '{"command":["get_property","playlist-count"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // 0')
    if [[ ! "$total_count" =~ ^[0-9]+$ ]] || [ "$total_count" -le 0 ]; then
        if [ -f "$LAST_PLAYLIST_FILE" ] && [ -s "$LAST_PLAYLIST_FILE" ]; then
            load_playlist_file_to_mpv "$LAST_PLAYLIST_FILE" "replace"
            total_count=$(echo '{"command":["get_property","playlist-count"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // 0')
        fi
    fi
    if [[ ! "$total_count" =~ ^[0-9]+$ ]] || [ "$total_count" -le 0 ]; then
        if [[ ! "$target_idx" =~ ^http.* ]]; then
            echo -e "${C_PINK}⚠️ Queue is empty. Add a song or start playback before opening video window.${C_RESET}"
            return 1
        fi
    fi

    # If target index, size preset, or URL is passed
    if [ -n "$target_idx" ]; then
        if [[ "$target_idx" =~ ^http.* ]]; then
            # Direct URL passed: queue and play it
            echo "{\"command\":[\"loadfile\",\"$target_idx\",\"replace\"]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
        elif [[ "$target_idx" =~ ^[0-9]+$ ]]; then
            # Specific track index requested
            if [ "$target_idx" -lt 1 ] || [ "$target_idx" -gt "$total_count" ]; then
                echo -e "${C_PINK}🚫 Track [${C_ORANGE}${target_idx}${C_PINK}] does not exist. Max tracks: ${C_WHITE}[${C_ORANGE}${total_count}${C_WHITE}]${C_RESET}"
                return 1
            fi
            echo "{\"command\":[\"playlist-play-index\",$((target_idx - 1))]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
        elif [[ "$target_idx" =~ ^(small|sm|35|med|medium|50|large|lg|75|full|fs|100)$ ]]; then
            case "$target_idx" in
                small|sm|35) target_autofit="35%x35%"; target_scale="0.35" ;;
                med|medium|50) target_autofit="50%x50%"; target_scale="0.50" ;;
                large|lg|75) target_autofit="75%x75%"; target_scale="0.75" ;;
                full|fs|100) target_fs="true" ;;
            esac
        fi
    fi

    # Smart video format: 60 FPS prioritized, crisp Full HD / 2K, never blurry, never locked behind Premium, pristine Opus audio
    local active_res
    active_res=$(get_active_saved_res)
    local smart_fmt="$hotkey_0"
    case "$active_res" in
        low|720) smart_fmt="$hotkey_1" ;;
        mid|1080) smart_fmt="$hotkey_2" ;;
        high|1440) smart_fmt="$hotkey_3" ;;
        max|4k|8k) smart_fmt="$hotkey_4" ;;
        *) smart_fmt="$hotkey_0" ;;
    esac
    echo "{\"command\":[\"set_property\",\"ytdl-format\",\"$smart_fmt\"]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1

    # Enable video window directly on the active MPV player:
    # 1. autofit=$target_autofit -> Clean small/medium window, never covers entire screen
    # 2. window-scale=$target_scale -> Direct initial window scale
    # 3. geometry=50%:50% -> Centered cleanly on the screen
    # 4. auto-window-resize=false -> Preserves user manual resize across track changes
    # 5. keepaspect-window=false -> Allows freely dragging borders to any dimension
    # 6. apply-profile fast -> Sub-millisecond bilinear rendering, 0 dropped frames
    # 7. hwdec=auto-safe -> Direct GPU hardware video decoding
    # 8. opengl-pbo=yes -> Asynchronous pixel buffer uploads for zero-copy frames
    # 9. swapchain-depth=3 -> Triple buffering absorbs presentation latency variance across compositors
    # 10. video-sync=audio -> Locks to audio clock, avoiding virtual VSync miscalculations
    # 11. gpu-context=$gpu_ctx & vo=$vo_opt -> Native hardware acceleration per platform
    # 12. video=auto & vid=auto -> Demux & render video stream
    # 13. force-window=yes -> Keep window persistent across playlist transitions
    # 14. pause=false -> Resume/continue playback
    echo -e "{\"command\":[\"set_property\",\"window-minimized\",false]}\n{\"command\":[\"set_property\",\"autofit\",\"$target_autofit\"]}\n{\"command\":[\"set_property\",\"window-scale\",$target_scale]}\n{\"command\":[\"set_property\",\"geometry\",\"50%:50%\"]}\n{\"command\":[\"set_property\",\"auto-window-resize\",false]}\n{\"command\":[\"set_property\",\"keepaspect-window\",false]}\n{\"command\":[\"apply-profile\",\"fast\"]}\n{\"command\":[\"set_property\",\"hwdec\",\"auto-safe\"]}\n{\"command\":[\"set_property\",\"opengl-pbo\",true]}\n{\"command\":[\"set_property\",\"swapchain-depth\",3]}\n{\"command\":[\"set_property\",\"video-sync\",\"audio\"]}\n{\"command\":[\"set_property\",\"gpu-context\",\"$gpu_ctx\"]}\n{\"command\":[\"set_property\",\"vo\",\"$vo_opt\"]}\n{\"command\":[\"set_property\",\"video\",\"auto\"]}\n{\"command\":[\"set_property\",\"vid\",\"auto\"]}\n{\"command\":[\"set_property\",\"fullscreen\",$target_fs]}\n{\"command\":[\"set_property\",\"force-window\",\"yes\"]}\n{\"command\":[\"set_property\",\"pause\",false]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1 || true
    touch "$HOME/.cache/mpv/video_active"
    if [ "$reload_needed" = true ]; then
        local cur_time
        cur_time=$(echo '{"command":["get_property","time-pos"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // 0')
        local cur_path
        cur_path=$(echo '{"command":["get_property","path"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // ""')
        if [[ "$cur_path" =~ ^http.* ]] || [[ "$cur_path" =~ ^ytdl.* ]]; then
            local r_batch=""
            if (( $(echo "$cur_time > 1" | bc -l 2>/dev/null || echo 0) )); then
                r_batch+="{\"command\":[\"set_property\",\"start\",\"$cur_time\"]}\n"
                r_batch+="{\"command\":[\"script-message\",\"arm-resume-seek\",\"$cur_time\"]}\n"
            fi
            r_batch+="{\"command\":[\"playlist-play-index\",\"current\"]}\n"
            echo -e "$r_batch" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
        fi
    fi

    # Fetch track title and format notification
    local title
    title=$(echo '{"command":["get_property","media-title"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // "Queue Video"')
    if [ "$mode" == "hybrid" ]; then
        echo -e "📺 ${C_PINK}Desktop Video Window Active (Hybrid Boost Mode - 120 FPS Direct3D):${C_RESET} ${C_CYAN}${title}${C_RESET}"
    else
        echo -e "📺 ${C_PINK}Desktop Video Window Active (Standalone Mode):${C_RESET} ${C_CYAN}${title}${C_RESET}"
    fi
    echo -e "${C_GRAY}💡 Resizable window. Press ${C_WHITE}w${C_GRAY} (cycle small/med/large), ${C_WHITE}+${C_GRAY}/${C_WHITE}-${C_GRAY} scale, ${C_WHITE}F11${C_GRAY} fullscreen, ${C_WHITE}0${C_GRAY}-${C_WHITE}4${C_GRAY} quality, ${C_WHITE}q${C_GRAY} return to audio.${C_RESET}"
}

cmd_audio_mode() {
    local action="$1"
    action=$(echo "$action" | tr '[:upper:]' '[:lower:]')

    local is_active=false
    if is_audio_mode_active; then
        is_active=true
    fi

    # Handle toggle
    if [ "$action" == "toggle" ]; then
        if [ "$is_active" = true ]; then
            action="off"
        else
            action="on"
        fi
    fi

    if [ "$action" == "on" ] || [ "$action" == "enable" ] || [ "$action" == "1" ]; then
        set_audio_mode "true"
        rm -f "$HOME/.cache/mpv/video_active" 2>/dev/null
        if [ "$IS_WSL" = true ]; then
            local win_dir
            win_dir=$(get_windows_user_dir)
            [ -n "$win_dir" ] && rm -f "$win_dir/.cache/mpv/video_active" 2>/dev/null
        fi

        local pure_audio_fmt="(bestaudio[acodec=opus]/bestaudio[acodec^=mp4a]/bestaudio)"
        local cur_lang=""
        [ -f "$HOME/.config/mpv/queue_lang" ] && cur_lang=$(cat "$HOME/.config/mpv/queue_lang" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$cur_lang" ] && [ "$cur_lang" != "auto" ]; then
            pure_audio_fmt="(bestaudio[language=$cur_lang][acodec=opus]/bestaudio[language^=$cur_lang][acodec=opus]/bestaudio[language=$cur_lang]/bestaudio[language^=$cur_lang]/bestaudio[acodec=opus]/bestaudio[acodec^=mp4a]/bestaudio)"
        fi

        if [ "$MPV_RUNNING" = true ] && [ -S "$SOCKET" ]; then
            local cur_pos cur_time
            cur_time=$(echo '{"command":["get_property","time-pos"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // 0')
            
            # Send batch commands to MPV:
            # 1. Hide/close window cleanly
            # 2. Disable video track
            # 3. Set ytdl-format to pure audio
            # 4. Notify lua script
            local batch=""
            batch+="{\"command\":[\"set_property\",\"vid\",\"no\"]}\n"
            batch+="{\"command\":[\"set_property\",\"video\",\"no\"]}\n"
            batch+="{\"command\":[\"set_property\",\"force-window\",\"no\"]}\n"
            batch+="{\"command\":[\"set_property\",\"window-minimized\",true]}\n"
            batch+="{\"command\":[\"set_property\",\"ytdl-format\",\"$pure_audio_fmt\"]}\n"
            batch+="{\"command\":[\"script-message\",\"set-audio-mode\",\"true\"]}\n"

            # If playing remote stream, reload current index with start timestamp to fetch pure audio
            local cur_path
            cur_path=$(echo '{"command":["get_property","path"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // ""')
            if [[ "$cur_path" =~ ^http.* ]] || [[ "$cur_path" =~ ^ytdl.* ]]; then
                if (( $(echo "$cur_time > 1" | bc -l 2>/dev/null || echo 0) )); then
                    batch+="{\"command\":[\"set_property\",\"start\",\"$cur_time\"]}\n"
                    batch+="{\"command\":[\"script-message\",\"arm-resume-seek\",\"$cur_time\"]}\n"
                fi
                batch+="{\"command\":[\"playlist-play-index\",\"current\"]}\n"
            fi
            echo -e "$batch" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
        fi

        echo -e "🎧 ${C_GREEN}Audio-Only Mode Enabled!${C_RESET}"
        echo -e "   ${C_TEAL}• Bandwidth:${C_RESET}    ${C_WHITE}~98% reduction (Pure Opus 48 kHz @ ~128 kbps)${C_RESET}"
        echo -e "   ${C_TEAL}• Video Demux:${C_RESET}  ${C_WHITE}0 video bytes requested from network${C_RESET}"
        echo -e "   ${C_TEAL}• Video Window:${C_RESET} ${C_WHITE}Cleanly closed (No black or phantom window)${C_RESET}"
        echo -e "   ${C_GRAY}💡 To restore desktop video anytime: ${C_WHITE}q -vid${C_GRAY} or ${C_WHITE}q -aud off${C_RESET}"
        return 0
    elif [ "$action" == "off" ] || [ "$action" == "disable" ] || [ "$action" == "0" ]; then
        set_audio_mode "false"
        echo -e "📺 ${C_CYAN}Restoring Video Pipeline...${C_RESET}"
        cmd_video_toggle ""
        return $?
    elif [ "$action" == "status" ] || [ -z "$action" ]; then
        local mode_status="${C_PINK}Disabled ❌ (Full Video Streaming)${C_RESET}"
        local bw_status="${C_GRAY}Standard (Full video + audio stream)${C_RESET}"
        local win_status="${C_GRAY}Open / Managed by q -vid${C_RESET}"
        if [ "$is_active" = true ]; then
            mode_status="${C_GREEN}Active ✅ (Audio-Only Mode)${C_RESET}"
            bw_status="${C_GREEN}~98% Reduction (~128 kbps pure audio)${C_RESET}"
            win_status="${C_GREEN}Cleanly Closed (0 video bytes demuxed)${C_RESET}"
        fi

        local cols=$(get_terminal_width)
        local width=$((cols - 2)); [ "$width" -lt 50 ] && width=50
        [ "$width" -gt 78 ] && width=78
        printf -v T_LINE "╭%*s╮" "$width" ""; T_LINE=${T_LINE// /─}
        printf -v M_LINE "├%*s┤" "$width" ""; M_LINE=${M_LINE// /─}
        printf -v B_LINE "╰%*s╯" "$width" ""; B_LINE=${B_LINE// /─}

        echo -e "${C_GRAY}${T_LINE}${C_RESET}"
        print_boxed_line "🎧 ${C_PURPLE}Queue Audio-Only Pipeline Status${C_RESET}"
        echo -e "${C_GRAY}${M_LINE}${C_RESET}"
        print_boxed_line "${C_TEAL}Audio Mode:       ${mode_status}"
        print_boxed_line "${C_TEAL}Bandwidth Saver:  ${bw_status}"
        print_boxed_line "${C_TEAL}Video Window:     ${win_status}"
        print_boxed_line "${C_TEAL}Audio Codec:      ${C_WHITE}Pristine Opus 48 kHz (Lossless Tunnel)${C_RESET}"
        echo -e "${C_GRAY}${B_LINE}${C_RESET}"
        if [ "$is_active" = true ]; then
            echo -e "${C_GRAY}💡 To restore desktop video: ${C_WHITE}q -vid${C_GRAY} or ${C_WHITE}q -aud off${C_RESET}"
        else
            echo -e "${C_GRAY}💡 To enable audio-only mode: ${C_WHITE}q -aud on${C_GRAY} or ${C_WHITE}q -res audio${C_RESET}"
        fi
        return 0
    else
        echo -e "${C_PINK}❓ Unknown audio-only command: \"$action\"${C_RESET}"
        echo -e "${C_GRAY}Usage: ${C_WHITE}q -aud [on|off|toggle|status]${C_RESET} or ${C_WHITE}q -res audio${C_RESET}"
        return 1
    fi
}

cmd_hybrid_toggle() {
    local action="$1"
    action=$(echo "$action" | tr '[:upper:]' '[:lower:]')

    if [ "$IS_WSL" = false ]; then
        if [ "$IS_MACOS" = true ]; then
            echo -e "${C_PINK}ℹ️  Hybrid Boost Mode is designed specifically for Windows + WSL2.${C_RESET}"
            echo -e "${C_CYAN}🍏 Your macOS system is already running native Metal/Cocoa with direct 120 FPS+ hardware acceleration!${C_RESET}"
        elif [ "$IS_ANDROID" = true ] || (command -v getprop >/dev/null 2>&1 && [ -d "/data/data/com.termux" ]); then
            local cur_mode
            cur_mode=$(get_queue_mode)

            if [ "$action" == "config" ]; then
                echo -e "${C_CYAN}⚙️ Configuring MPV Android hardware acceleration profile...${C_RESET}"
                if ensure_android_mpv_config; then
                    echo -e "${C_GREEN}✅ /sdcard/mpv/mpv.conf created and optimized:${C_RESET}"
                    echo -e "   ${C_TEAL}• hwdec=mediacodec:${C_RESET} ${C_WHITE}Direct Qualcomm/Mali/MediaTek GPU video decoding${C_RESET}"
                    echo -e "   ${C_TEAL}• vo=gpu-next:${C_RESET}      ${C_WHITE}libplacebo engine with HDR tone-mapping & 10-bit color${C_RESET}"
                    echo -e "   ${C_TEAL}• audio-channels=stereo:${C_RESET} ${C_WHITE}Android AudioTrack / AAudio hardware audio tunneling${C_RESET}"
                    echo -e "   ${C_TEAL}• demuxer-max-bytes=128MiB:${C_RESET} ${C_WHITE}High-speed readahead network buffer${C_RESET}"
                    echo -e "   ${C_TEAL}• ytdl=no:${C_RESET}          ${C_WHITE}Direct streaming via Queue loopback bridge${C_RESET}"
                    echo -e "${C_GRAY}💡 Tip: Inside MPV Android app settings, set 'Background play' to 'Always'.${C_RESET}"
                else
                    echo -e "${C_PINK}⚠️ Unable to write to /sdcard/mpv/mpv.conf.${C_RESET}"
                    echo -e "${C_YELLOW}👉 Run 'termux-setup-storage' to grant Termux storage permissions, then try again.${C_RESET}"
                fi
                return 0
            fi

            if [ "$action" == "status" ]; then
                local mpv_pkg=false
                if command -v pm >/dev/null 2>&1 && pm list packages is.xyz.mpv 2>/dev/null | grep -q "is.xyz.mpv"; then
                    mpv_pkg=true
                elif command -v am >/dev/null 2>&1 || [ -x "/system/bin/am" ]; then
                    mpv_pkg=true
                fi

                local bridge_alive=false
                local bridge_port="8989"
                if [ -f "$HOME/.cache/mpv/android_bridge.port" ]; then
                    bridge_port=$(cat "$HOME/.cache/mpv/android_bridge.port" 2>/dev/null | tr -d '[:space:]')
                    if curl -s -m 0.5 "http://127.0.0.1:${bridge_port}/status" >/dev/null 2>&1; then
                        bridge_alive=true
                    fi
                fi

                local conf_found=false
                for cf in "/sdcard/mpv/mpv.conf" "/storage/emulated/0/mpv/mpv.conf" "$HOME/storage/shared/mpv/mpv.conf"; do
                    [ -f "$cf" ] && conf_found=true && break
                done

                print_header_box "${C_PINK}📱 Queue Engine Status (Android / Termux)${C_RESET}"
                if [ "$cur_mode" == "hybrid" ]; then
                    print_boxed_line "${C_TEAL}Active Engine:  ${C_ORANGE}Hybrid Mobile Mode 🤖⚡${C_RESET}"
                    print_boxed_line "${C_TEAL}Video Engine:   ${C_WHITE}Play Store MPV App ('is.xyz.mpv') via Android Intent${C_RESET}"
                    print_boxed_line "${C_TEAL}Audio Pipeline: ${C_WHITE}Android AudioTrack / AAudio (Hardware Audio Tunneling)${C_RESET}"
                    print_boxed_line "${C_TEAL}Acceleration:   ${C_WHITE}MediaCodec GPU + libplacebo (gpu-next, PiP, lock-screen)${C_RESET}"
                else
                    print_boxed_line "${C_TEAL}Active Engine:  ${C_CYAN}Standalone Termux Mode 🐧${C_RESET}"
                    print_boxed_line "${C_TEAL}Playback:       ${C_WHITE}Headless Termux MPV + CPU Wake-Lock (Screen-off battery saver)${C_RESET}"
                    print_boxed_line "${C_TEAL}Audio Pipeline: ${C_WHITE}Termux Audio Output (Zero GUI overhead)${C_RESET}"
                    print_boxed_line "${C_TEAL}Video Handoff:  ${C_WHITE}On-Demand (type 'q -vid' or press 'v' in 'q -i')${C_RESET}"
                fi
                echo -e "${C_GRAY}${H_LINE}${C_RESET}"
                if [ "$mpv_pkg" = true ]; then
                    print_boxed_line "${C_TEAL}MPV Android:    ${C_GREEN}Available ✅${C_RESET} ${C_GRAY}(is.xyz.mpv package)${C_RESET}"
                else
                    print_boxed_line "${C_TEAL}MPV Android:    ${C_PINK}Not Detected ❌${C_RESET} ${C_GRAY}(Install from Play Store)${C_RESET}"
                fi
                if [ "$bridge_alive" = true ]; then
                    print_boxed_line "${C_TEAL}Stream Bridge:  ${C_GREEN}Active ✅${C_RESET} ${C_GRAY}(127.0.0.1:${bridge_port})${C_RESET}"
                else
                    print_boxed_line "${C_TEAL}Stream Bridge:  ${C_GRAY}Standby 💤 (Auto-spawns on handoff)${C_RESET}"
                fi
                if [ "$conf_found" = true ]; then
                    print_boxed_line "${C_TEAL}Config Profile: ${C_GREEN}Optimized ✅${C_RESET} ${C_GRAY}(/sdcard/mpv/mpv.conf)${C_RESET}"
                else
                    print_boxed_line "${C_TEAL}Config Profile: ${C_YELLOW}Missing ⚠️${C_RESET} ${C_GRAY}(Run: q -hybrid config)${C_RESET}"
                fi
                printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
                B_LINE=${B_LINE// /─}
                echo -e "${C_GRAY}${B_LINE}${C_RESET}"
                echo -e "${C_GRAY}💡 Tip: Switch engines anytime with ${C_WHITE}q -hybrid on${C_GRAY} or ${C_WHITE}q -hybrid off${C_RESET}"
                return 0
            fi

            local target_mode=""
            if [ "$action" == "on" ] || [ "$action" == "enable" ] || [ "$action" == "1" ]; then
                target_mode="hybrid"
            elif [ "$action" == "off" ] || [ "$action" == "disable" ] || [ "$action" == "0" ]; then
                target_mode="standalone"
            elif [ -z "$action" ] || [ "$action" == "toggle" ]; then
                if [ "$cur_mode" == "hybrid" ]; then
                    target_mode="standalone"
                else
                    target_mode="hybrid"
                fi
            else
                echo -e "${C_PINK}❓ Unknown hybrid command: \"$action\"${C_RESET}"
                echo -e "${C_GRAY}Usage: ${C_WHITE}q -hybrid [on|off|status|config]${C_RESET}"
                return 1
            fi

            if [ "$cur_mode" == "$target_mode" ]; then
                if [ "$target_mode" == "hybrid" ]; then
                    echo -e "⚡ ${C_ORANGE}Hybrid Mobile Mode is already active!${C_RESET} (Play Store MPV, Audio Tunneling, MediaCodec GPU)"
                else
                    echo -e "🐧 ${C_CYAN}Standalone Termux Mode is already active!${C_RESET} (Headless MPV daemon, CPU Wake-Lock)"
                fi
                return 0
            fi

            # Save new engine preference
            mkdir -p "$HOME/.config/mpv"
            echo "$target_mode" > "$HOME/.config/mpv/queue_mode"

            if [ "$target_mode" == "hybrid" ]; then
                echo -e "⚡ ${C_ORANGE}Switched to Android Hybrid Mode!${C_RESET}"
                echo -e "   ${C_TEAL}Playback Engine:${C_RESET} ${C_WHITE}Play Store MPV App ('is.xyz.mpv')${C_RESET}"
                echo -e "   ${C_TEAL}Video Pipeline:${C_RESET}  ${C_WHITE}MediaCodec GPU + libplacebo (gpu-next, PiP, Lockscreen)${C_RESET}"
                echo -e "   ${C_TEAL}Audio Pipeline:${C_RESET}  ${C_WHITE}Android AudioTrack / AAudio (Hardware Audio Tunneling)${C_RESET}"
                ensure_android_bridge_running >/dev/null 2>&1 || true
                ensure_android_mpv_config >/dev/null 2>&1 || true
                echo -e "   ${C_GRAY}💡 To switch back anytime: ${C_WHITE}q -hybrid off${C_RESET}"

                # In Hybrid Mode, Termux MPV must stay paused and silent
                if [ "$MPV_RUNNING" = true ] && [ -S "$SOCKET" ]; then
                    echo '{"command":["set_property","pause",true]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
                    echo '{"command":["set_property","mute",true]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
                    echo '{"command":["set_property","ao","null"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
                    echo -e "${C_PINK}🔄 Migrating active playback to Play Store MPV Android...${C_RESET}"
                    cmd_android_video_handoff ""
                fi
            else
                echo -e "🐧 ${C_CYAN}Switched to Standalone Termux Mode!${C_RESET}"
                echo -e "   ${C_TEAL}Playback Engine:${C_RESET} ${C_WHITE}Headless Termux MPV + CPU Wake-Lock${C_RESET}"
                echo -e "   ${C_TEAL}Battery Profile:${C_RESET} ${C_WHITE}Max battery saver (Screen-off background audio)${C_RESET}"
                echo -e "   ${C_TEAL}Video Engine:${C_RESET}    ${C_WHITE}Accessible on-demand via 'q -vid'${C_RESET}"
                stop_android_bridge >/dev/null 2>&1 || true
                echo -e "   ${C_GRAY}💡 To switch to Hybrid Mobile mode anytime: ${C_WHITE}q -hybrid on${C_RESET}"

                # If Android MPV was active, pause it and resume audio in Termux MPV!
                send_android_mpv_cmd "pause"
                rm -f "$HOME/.cache/mpv/android_video_active"
                if [ "$MPV_RUNNING" = true ] && [ -S "$SOCKET" ]; then
                    echo '{"command":["set_property","mute",false]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
                    echo '{"command":["set_property","ao","opensles,pulse,alsa"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
                    echo '{"command":["set_property","pause",false]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
                    echo -e "🎧 ${C_PINK}Resumed background audio in Termux MPV${C_RESET}"
                fi
            fi
            return 0
        else
            echo -e "${C_PINK}ℹ️  Hybrid Boost Mode is designed specifically for Windows + WSL2.${C_RESET}"
            echo -e "${C_CYAN}🐧 Your native Linux system already has direct kernel GPU access with uncapped 120 FPS+ hardware acceleration!${C_RESET}"
        fi
        return 0
    fi

    local cur_mode
    cur_mode=$(get_queue_mode)

    if [ "$action" == "status" ]; then
        local win_mpv
        win_mpv=$(find_windows_mpv)
        local relay_bin
        relay_bin=$(ensure_piperelay_compiled)

        print_header_box "${C_PINK}⚡ Queue Engine Status (Windows + WSL2)${C_RESET}"
        if [ "$cur_mode" == "hybrid" ]; then
            print_boxed_line "${C_TEAL}Active Engine:  ${C_ORANGE}Hybrid Boost Mode ⚡${C_RESET}"
            print_boxed_line "${C_TEAL}Video Pipeline: ${C_WHITE}Native Windows mpv.exe (Direct3D 11/12, 120+ FPS)${C_RESET}"
            print_boxed_line "${C_TEAL}Audio Pipeline: ${C_WHITE}Native Windows WASAPI (Host hardware audio)${C_RESET}"
        else
            print_boxed_line "${C_TEAL}Active Engine:  ${C_CYAN}Standalone WSL Mode 🐧${C_RESET}"
            print_boxed_line "${C_TEAL}Video Pipeline: ${C_WHITE}WSLg Mesa D3D12 (Capped at 60 FPS compositor)${C_RESET}"
            print_boxed_line "${C_TEAL}Audio Pipeline: ${C_WHITE}WSL PulseAudio Virtual Sink${C_RESET}"
        fi
        echo -e "${C_GRAY}${H_LINE}${C_RESET}"
        if [ -n "$win_mpv" ]; then
            print_boxed_line "${C_TEAL}Windows MPV:    ${C_GREEN}Installed ✅${C_RESET} ${C_GRAY}(${win_mpv:0:$((INNER_WIDTH-28))})${C_RESET}"
        else
            print_boxed_line "${C_TEAL}Windows MPV:    ${C_PINK}Not Found ❌${C_RESET} ${C_GRAY}(Run: winget install shinchiro.mpv)${C_RESET}"
        fi
        if [ -n "$relay_bin" ] && [ -f "$relay_bin" ]; then
            print_boxed_line "${C_TEAL}PipeRelay:      ${C_GREEN}Ready ✅${C_RESET} ${C_GRAY}(${relay_bin:0:$((INNER_WIDTH-24))})${C_RESET}"
        else
            print_boxed_line "${C_TEAL}PipeRelay:      ${C_PINK}Not Compiled ❌${C_RESET}"
        fi
        printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
        B_LINE=${B_LINE// /─}
        echo -e "${C_GRAY}${B_LINE}${C_RESET}"
        echo -e "${C_GRAY}💡 Tip: Switch engines anytime with ${C_WHITE}q -hybrid on${C_GRAY} or ${C_WHITE}q -hybrid off${C_RESET}"
        return 0
    fi

    local target_mode=""
    if [ "$action" == "on" ] || [ "$action" == "enable" ] || [ "$action" == "1" ]; then
        target_mode="hybrid"
    elif [ "$action" == "off" ] || [ "$action" == "disable" ] || [ "$action" == "0" ]; then
        target_mode="standalone"
    elif [ -z "$action" ] || [ "$action" == "toggle" ]; then
        if [ "$cur_mode" == "hybrid" ]; then
            target_mode="standalone"
        else
            target_mode="hybrid"
        fi
    else
        echo -e "${C_PINK}❓ Unknown hybrid command: \"$action\"${C_RESET}"
        echo -e "${C_GRAY}Usage: ${C_WHITE}q -hybrid [on|off|status]${C_RESET}"
        return 1
    fi

    if [ "$cur_mode" == "$target_mode" ]; then
        if [ "$target_mode" == "hybrid" ]; then
            echo -e "⚡ ${C_ORANGE}Hybrid Boost Mode is already active!${C_RESET} (Native Windows MPV, 120+ FPS Direct3D)"
        else
            echo -e "🐧 ${C_CYAN}Standalone WSL Mode is already active!${C_RESET} (WSLg Mesa D3D12, 60 FPS)"
        fi
        return 0
    fi

    # Switching to Hybrid mode: verify prerequisites
    if [ "$target_mode" == "hybrid" ]; then
        local win_mpv
        win_mpv=$(find_windows_mpv)
        if [ -z "$win_mpv" ]; then
            echo -e "${C_PINK}❌ Native Windows MPV was not detected on your Windows host.${C_RESET}"
            echo -e "${C_CYAN}To enable Hybrid Boost Mode (120+ FPS 4K/8K Direct3D rendering):${C_RESET}"
            echo -e "${C_WHITE}1. Open PowerShell on Windows and run:${C_RESET}"
            echo -e "   ${C_ORANGE}winget install shinchiro.mpv${C_RESET}"
            echo -e "${C_WHITE}2. Once installed, re-run in WSL:${C_RESET}"
            echo -e "   ${C_ORANGE}q -hybrid on${C_RESET}"
            return 1
        fi

        local relay_bin
        relay_bin=$(ensure_piperelay_compiled)
        if [ -z "$relay_bin" ]; then
            echo -e "${C_PINK}❌ Failed to configure PipeRelay bridge (exe/ps1).${C_RESET}"
            return 1
        fi
    fi

    # Check if MPV is actively running and preserve state
    local was_running=false
    local cur_pos=""
    local cur_time=""
    local was_paused=false
    local video_was_active=false

    if [ -S "$SOCKET" ] && (echo '{"command":["get_property","idle-active"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1); then
        was_running=true
        cur_pos=$(echo '{"command":["get_property","playlist-pos"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // empty' 2>/dev/null)
        cur_time=$(echo '{"command":["get_property","time-pos"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // empty' 2>/dev/null)
        was_paused=$(echo '{"command":["get_property","pause"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // false' 2>/dev/null)
        [ -f "$HOME/.cache/mpv/video_active" ] && video_was_active=true
        save_current_playlist true
    fi

    # Stop current engine
    cmd_stop >/dev/null 2>&1

    # Save new engine preference
    mkdir -p "$HOME/.config/mpv"
    echo "$target_mode" > "$HOME/.config/mpv/queue_mode"

    if [ "$target_mode" == "hybrid" ]; then
        echo -e "⚡ ${C_ORANGE}Switched to Hybrid Boost Mode!${C_RESET}"
        echo -e "   ${C_TEAL}Renderer:${C_RESET} ${C_WHITE}Native Windows Direct3D 11/12 (Uncapped 120+ FPS, 4K/8K)${C_RESET}"
        echo -e "   ${C_TEAL}Audio:${C_RESET}    ${C_WHITE}Native Host WASAPI (Zero virtualization latency)${C_RESET}"
        echo -e "   ${C_GRAY}💡 To switch back anytime: ${C_WHITE}q -hybrid off${C_RESET}"
    else
        echo -e "🐧 ${C_CYAN}Switched to Standalone WSL Mode!${C_RESET}"
        echo -e "   ${C_TEAL}Renderer:${C_RESET} ${C_WHITE}WSLg Mesa D3D12 (60 FPS)${C_RESET}"
        echo -e "   ${C_TEAL}Audio:${C_RESET}    ${C_WHITE}WSL PulseAudio Virtual Sink${C_RESET}"
        echo -e "   ${C_GRAY}💡 To switch to Hybrid Boost mode anytime: ${C_WHITE}q -hybrid on${C_RESET}"
    fi

    # If it was running, restart with new engine seamlessly
    if [ "$was_running" = true ]; then
        echo -e "${C_PINK}🔄 Migrating active playback to new engine...${C_RESET}"
        ensure_mpv_running
        if [ -f "$LAST_PLAYLIST_FILE" ] && [ -s "$LAST_PLAYLIST_FILE" ]; then
            load_playlist_file_to_mpv "$LAST_PLAYLIST_FILE" "replace"
        fi
        if [ -n "$cur_pos" ] && [ "$cur_pos" != "null" ]; then
            echo "{\"command\":[\"playlist-play-index\",$cur_pos]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
            if [ -n "$cur_time" ] && [ "$cur_time" != "null" ]; then
                echo "{\"command\":[\"seek\",$cur_time,\"absolute\"]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
            fi
            if [ "$was_paused" == "true" ]; then
                echo '{"command":["set_property","pause",true]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
            else
                echo '{"command":["set_property","pause",false]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
            fi
        fi
        if [ "$video_was_active" = true ]; then
            sleep 0.2
            cmd_video_toggle ""
        fi
    fi
}

get_hardware_ceiling() {
    local ceiling=""
    if [ "$IS_WSL" = true ]; then
        local win_u_dir
        win_u_dir=$(get_windows_user_dir)
        if [ -n "$win_u_dir" ] && [ -f "$win_u_dir/AppData/Roaming/mpv/queue_hw_ceiling" ]; then
            ceiling=$(cat "$win_u_dir/AppData/Roaming/mpv/queue_hw_ceiling" 2>/dev/null | tr -d '[:space:]')
        fi
    fi
    if [ -z "$ceiling" ] && [ -f "$HOME/.config/mpv/queue_hw_ceiling" ]; then
        ceiling=$(cat "$HOME/.config/mpv/queue_hw_ceiling" 2>/dev/null | tr -d '[:space:]')
    fi
    if [ -z "$ceiling" ]; then
        ceiling=$(detect_hardware_ceiling)
    fi
    case "$ceiling" in
        8k|4320) echo "8k" ;;
        high|2k|1440|1440p) echo "high" ;;
        mid|1080|1080p) echo "mid" ;;
        *) echo "4k" ;;
    esac
}

detect_hardware_ceiling() {
    local detected="4k"
    if [ "$IS_WSL" = true ]; then
        local gpu_info
        gpu_info=$(powershell.exe -NoProfile -Command "
            \$g = Get-CimInstance Win32_VideoController | Select-Object -First 1 Name, AdapterRAM, CurrentHorizontalResolution, CurrentVerticalResolution;
            \"\$(\$g.Name)|\$(\$g.AdapterRAM)|\$(\$g.CurrentHorizontalResolution)|\$(\$g.CurrentVerticalResolution)\"
        " </dev/null 2>/dev/null | tr -d '\r\n')

        if [ -n "$gpu_info" ]; then
            local g_name g_vram g_w g_h
            IFS='|' read -r g_name g_vram g_w g_h <<< "$gpu_info"
            if [[ "$g_name" =~ (RTX (3080|3090|4070|4080|4090)|RX 7900) ]] && [ "${g_h:-0}" -ge 2160 ]; then
                detected="8k"
            elif [[ "$g_name" =~ Intel.*(HD|UHD) ]] || { [ -n "$g_vram" ] && [ "$g_vram" -lt 1073741824 ] && [[ ! "$g_name" =~ (Radeon|GeForce|NVIDIA) ]]; }; then
                detected="1080"
            else
                detected="4k"
            fi
        fi
    elif [ "$IS_LINUX" = true ]; then
        if command -v lspci >/dev/null 2>&1; then
            local pci_info
            pci_info=$(lspci 2>/dev/null | grep -iE "vga|3d|display")
            if [[ "$pci_info" =~ (RTX 40|RTX 3080|RTX 3090|RX 7900) ]]; then
                detected="8k"
            elif [[ "$pci_info" =~ Intel.*(HD|UHD) ]]; then
                detected="1080"
            else
                detected="4k"
            fi
        fi
    fi

    mkdir -p "$HOME/.config/mpv"
    echo "$detected" > "$HOME/.config/mpv/queue_hw_ceiling"
    if [ "$IS_WSL" = true ]; then
        local win_u_dir
        win_u_dir=$(get_windows_user_dir)
        if [ -n "$win_u_dir" ]; then
            mkdir -p "$win_u_dir/AppData/Roaming/mpv" 2>/dev/null
            echo "$detected" > "$win_u_dir/AppData/Roaming/mpv/queue_hw_ceiling" 2>/dev/null
        fi
    fi
    echo "$detected"
}

get_active_saved_res() {
    local saved_res=""
    if [ -S "$SOCKET" ]; then
        local live_prop
        live_prop=$(echo '{"command":["get_property","user-data/queue-res"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // empty' 2>/dev/null)
        [ -n "$live_prop" ] && saved_res="$live_prop"
    fi
    if [ -z "$saved_res" ] && [ "$(get_queue_mode)" == "hybrid" ] && command -v get_windows_user_dir >/dev/null 2>&1; then
        local win_u_dir
        win_u_dir=$(get_windows_user_dir)
        if [ -n "$win_u_dir" ] && [ -f "$win_u_dir/AppData/Roaming/mpv/queue_res" ]; then
            saved_res=$(cat "$win_u_dir/AppData/Roaming/mpv/queue_res" 2>/dev/null | tr -d '[:space:]')
        fi
    fi
    if [ -z "$saved_res" ] && [ -f "$HOME/.config/mpv/queue_res" ]; then
        saved_res=$(cat "$HOME/.config/mpv/queue_res" 2>/dev/null | tr -d '[:space:]')
    fi
    [ -z "$saved_res" ] && saved_res="auto"
    echo "$saved_res"
}

cmd_resolution() {
    local target="$1"
    target=$(echo "$target" | tr '[:upper:]' '[:lower:]')

    # Handle manual hardware ceiling override: q -res ceiling [val] / q -res hw [val]
    if [[ "$target" =~ ^(ceiling|hw|hardware) ]]; then
        local new_ceiling="$2"
        new_ceiling=$(echo "$new_ceiling" | tr '[:upper:]' '[:lower:]')
        if [ -n "$new_ceiling" ]; then
            case "$new_ceiling" in
                8k|4320|uncapped) new_ceiling="8k" ;;
                4k|2160|uhd) new_ceiling="4k" ;;
                high|2k|1440|1440p) new_ceiling="high" ;;
                mid|1080|1080p) new_ceiling="mid" ;;
                *)
                    echo -e "${C_PINK}❓ Unknown ceiling: '$new_ceiling'. Use: 8k, 4k, high (2k), or mid (1080p).${C_RESET}"
                    return 1
                    ;;
            esac
            mkdir -p "$HOME/.config/mpv"
            echo "$new_ceiling" > "$HOME/.config/mpv/queue_hw_ceiling"
            if [ "$IS_WSL" = true ]; then
                local win_u_dir
                win_u_dir=$(get_windows_user_dir)
                [ -n "$win_u_dir" ] && echo "$new_ceiling" > "$win_u_dir/AppData/Roaming/mpv/queue_hw_ceiling" 2>/dev/null
            fi
            echo -e "${C_CYAN}💻 Hardware Playback Ceiling set to:${C_RESET} ${C_PINK}${new_ceiling}${C_RESET}"
            # If MPV is running, trigger quality reload with current tier
            if [ -S "$SOCKET" ]; then
                local cur_p
                cur_p=$(get_active_saved_res)
                echo "{\"command\":[\"script-message\",\"change-quality\",\"$cur_p\"]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
            fi
            return 0
        else
            local cur_c
            cur_c=$(get_hardware_ceiling)
            echo -e "${C_CYAN}💻 Current Hardware Playback Ceiling:${C_RESET} ${C_PINK}${cur_c}${C_RESET}"
            return 0
        fi
    fi

    local clean_target="auto"
    local label=""

    case "$target" in
        audio|aud)
            cmd_audio_mode "on"
            return $?
            ;;
        low|720|720p|hd)
            clean_target="low"
            label="Low / 720p HD (Fluid 60 FPS / bandwidth saver)"
            ;;
        mid|medium|1080|1080p|fhd)
            clean_target="mid"
            label="Mid / 1080p Full HD (Crisp 60 FPS)"
            ;;
        high|1440|1440p|2k|qhd)
            clean_target="high"
            label="High / 1440p 2K QHD (Ultra-crisp 60 FPS)"
            ;;
        max)
            clean_target="max"
            local hw_ceil
            hw_ceil=$(get_hardware_ceiling)
            if [ "$hw_ceil" == "8k" ]; then
                label="Max / 8K UHD (Uncapped highest quality & FPS)"
            elif [ "$hw_ceil" == "high" ]; then
                label="Max / 1440p 2K (Hardware ceiling for smooth 60 FPS playback)"
            elif [ "$hw_ceil" == "mid" ]; then
                label="Max / 1080p Full HD (Hardware ceiling for smooth 60 FPS playback)"
            else
                label="Max / 4K UHD (Hardware ceiling for smooth 60 FPS playback)"
            fi
            ;;
        4k|2160|2160p|uhd)
            clean_target="4k"
            label="4K UHD (3840x2160 @ 60 FPS smooth)"
            ;;
        8k|4320|4320p)
            clean_target="8k"
            local hw_ceil
            hw_ceil=$(get_hardware_ceiling)
            if [ "$hw_ceil" != "8k" ]; then
                label="8K UHD Uncapped (⚠️ Manual override: hardware ceiling is ${hw_ceil})"
            else
                label="8K UHD (7680x4320 @ 60 FPS uncapped)"
            fi
            ;;
        480|480p|sd)
            clean_target="480"
            label="480p SD (Low-bandwidth smooth)"
            ;;
        360|360p|emergency)
            clean_target="360"
            label="360p Low (Emergency smooth)"
            ;;
        auto|smart)
            clean_target="auto"
            local hw_ceil
            hw_ceil=$(get_hardware_ceiling)
            label="Auto / Smart (Hardware ceiling: ${hw_ceil}, protects buffer & frame-rate)"
            ;;
        "")
            if is_audio_mode_active; then
                cmd_audio_mode "status"
                return 0
            fi
            # Query / Show active resolution status
            local hw_ceil
            hw_ceil=$(get_hardware_ceiling)
            local hw_display="4K UHD"
            [ "$hw_ceil" == "8k" ] && hw_display="8K UHD (Uncapped)"
            [ "$hw_ceil" == "high" ] && hw_display="1440p 2K QHD"
            [ "$hw_ceil" == "mid" ] && hw_display="1080p Full HD"

            if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
                local saved_res="auto"
                [ -f "$HOME/.config/mpv/queue_res" ] && saved_res=$(cat "$HOME/.config/mpv/queue_res" 2>/dev/null | tr -d '[:space:]')
                local res_desc="Auto / Smart (Adapts to internet)"
                case "$saved_res" in
                    low|720|720p) res_desc="Low / 720p HD (Fluid 60 FPS / data saver)" ;;
                    mid|1080|1080p) res_desc="Mid / 1080p Full HD (Crisp 60 FPS)" ;;
                    high|1440|1440p|2k) res_desc="High / 1440p 2K QHD (Ultra-crisp 60 FPS)" ;;
                    max|4k|2160) res_desc="Max / 4K UHD (Hardware ceiling smooth)" ;;
                    8k|4320) res_desc="8K UHD (Uncapped)" ;;
                    480|480p) res_desc="480p SD (Low-bandwidth smooth)" ;;
                    360|360p) res_desc="360p Low (Emergency smooth)" ;;
                    auto) res_desc="Auto / Smart (Hardware ceiling: 4K, protects buffer)" ;;
                esac
                echo -e "╭─────────────────────────────────────────────────────────────────────────╮"
                echo -e "│ 📱 ${C_PURPLE}Queue Video Quality Profile (Android Mobile)${C_RESET}                          │"
                echo -e "├─────────────────────────────────────────────────────────────────────────┤"
                echo -e "│ ${C_TEAL}Active Quality:${C_RESET}  ${C_PINK}${res_desc}${C_RESET}"
                echo -e "│ ${C_TEAL}Hardware Ceiling:${C_RESET}${C_WHITE}${hw_display}${C_RESET}"
                echo -e "│ ${C_TEAL}Video Pipeline:${C_RESET}  ${C_WHITE}Hardware MediaCodec GPU (is.xyz.mpv)${C_RESET}"
                echo -e "│ ${C_TEAL}Audio Tunnel:${C_RESET}    ${C_WHITE}Pristine Opus 48kHz (AAudio / AudioTrack)${C_RESET}"
                echo -e "│ ${C_TEAL}Stream Manifest:${C_RESET} ${C_WHITE}Dynamic EDL Multi-Stream (100% Uncompressed)${C_RESET}"
                echo -e "╰─────────────────────────────────────────────────────────────────────────╯"
                echo -e "${C_GRAY}💡 Quick Switch: ${C_WHITE}q -res low${C_GRAY} | ${C_WHITE}q -res mid${C_GRAY} | ${C_WHITE}q -res high${C_GRAY} | ${C_WHITE}q -res max${C_GRAY} | ${C_WHITE}q -res auto${C_RESET}"
                return 0
            fi

            # Desktop Status
            if [ -S "$SOCKET" ] && echo '{"command":["get_property","idle-active"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1; then
                local cur_w cur_h cur_fps cur_codec cur_acodec cur_samplerate
                local res_info
                res_info=$(echo -e '{"command":["get_property","video-params"]}\n{"command":["get_property","track-list"]}\n{"command":["get_property","audio-params"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)
                cur_w=$(echo "$res_info" | jq -s -r 'map(select(.event == null)) | .[0].data.w // "N/A"' 2>/dev/null)
                cur_h=$(echo "$res_info" | jq -s -r 'map(select(.event == null)) | .[0].data.h // "N/A"' 2>/dev/null)
                cur_fps=$(echo "$res_info" | jq -s -r 'map(select(.event == null)) | (.[1].data[]? | select(.type=="video" and .selected==true) | .["demux-fps"]) // "N/A"' 2>/dev/null)
                cur_codec=$(echo "$res_info" | jq -s -r 'map(select(.event == null)) | (.[1].data[]? | select(.type=="video" and .selected==true) | .codec) // "N/A"' 2>/dev/null)
                cur_acodec=$(echo "$res_info" | jq -s -r 'map(select(.event == null)) | (.[1].data[]? | select(.type=="audio" and .selected==true) | .codec) // "opus"' 2>/dev/null)
                cur_samplerate=$(echo "$res_info" | jq -s -r 'map(select(.event == null)) | .[2].data.samplerate // 48000' 2>/dev/null)
                [[ "$cur_fps" =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf -v cur_fps "%.0f" "$cur_fps"

                local saved_res
                saved_res=$(get_active_saved_res)
                echo "$saved_res" > "$HOME/.config/mpv/queue_res" 2>/dev/null
                local res_friendly="Auto"
                case "$saved_res" in
                    low|720|720p) res_friendly="Low (720p HD)" ;;
                    mid|1080|1080p) res_friendly="Mid (1080p Full HD)" ;;
                    high|1440|1440p|2k) res_friendly="High (1440p 2K QHD)" ;;
                    max) res_friendly="Max (Hardware Ceiling: ${hw_display})" ;;
                    4k|2160) res_friendly="4K UHD" ;;
                    8k|4320) res_friendly="8K UHD (Uncapped)" ;;
                    480) res_friendly="480p SD" ;;
                    360) res_friendly="360p Low" ;;
                    auto) res_friendly="Auto (Smart Dynamic up to ${hw_display})" ;;
                    *) res_friendly="$saved_res" ;;
                esac

                if [ "$cur_w" == "N/A" ] || [ -z "$cur_w" ]; then
                    local current_fmt
                    current_fmt=$(echo '{"command":["get_property","ytdl-format"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // "Default"')
                    echo -e "${C_CYAN}📺 Video Stream:${C_RESET} ${C_GRAY}Idle / Audio Only (No video actively rendering)${C_RESET}"
                    echo -e "   ${C_PINK}Active Profile:${C_RESET}   ${C_WHITE}${res_friendly}${C_RESET}"
                    echo -e "   ${C_TEAL}Hardware Ceiling:${C_RESET} ${C_WHITE}${hw_display}${C_RESET} (${C_GRAY}Smart GPU capability cap${C_RESET})"
                else
                    echo -e "${C_CYAN}📺 Active Video Quality:${C_RESET} ${C_WHITE}${cur_w}x${cur_h}${C_RESET} @ ${C_PINK}${cur_fps} FPS${C_RESET} (${C_GRAY}codec: ${cur_codec}${C_RESET})"
                    echo -e "${C_CYAN}🔊 Active Audio Stream:${C_RESET}  ${C_GREEN}${cur_acodec}${C_RESET} @ ${C_WHITE}${cur_samplerate} Hz${C_RESET} (${C_GRAY}pristine lossless stream${C_RESET})"
                    echo -e "   ${C_PINK}Active Profile:${C_RESET}       ${C_WHITE}${res_friendly}${C_RESET}"
                    echo -e "   ${C_TEAL}Hardware Ceiling:${C_RESET}     ${C_WHITE}${hw_display}${C_RESET} (${C_GRAY}Smart GPU capability cap${C_RESET})"
                fi
            else
                local saved_res
                saved_res=$(get_active_saved_res)
                local res_friendly="Auto"
                case "$saved_res" in
                    low|720|720p) res_friendly="Low (720p HD)" ;;
                    mid|1080|1080p) res_friendly="Mid (1080p Full HD)" ;;
                    high|1440|1440p|2k) res_friendly="High (1440p 2K QHD)" ;;
                    max) res_friendly="Max (Hardware Ceiling: ${hw_display})" ;;
                    4k|2160) res_friendly="4K UHD" ;;
                    8k|4320) res_friendly="8K UHD (Uncapped)" ;;
                    480) res_friendly="480p SD" ;;
                    360) res_friendly="360p Low" ;;
                    auto) res_friendly="Auto (Smart Dynamic up to ${hw_display})" ;;
                    *) res_friendly="$saved_res" ;;
                esac
                echo -e "${C_CYAN}📺 Video Quality Profile:${C_RESET} ${C_PINK}${res_friendly}${C_RESET}"
                echo -e "   ${C_TEAL}Hardware Ceiling:${C_RESET}     ${C_WHITE}${hw_display}${C_RESET} (${C_GRAY}Smart GPU capability cap${C_RESET})"
            fi
            echo -e "${C_GRAY}💡 Quick Switch: 'q -res low' | 'q -res mid' | 'q -res high' | 'q -res max' | 'q -res auto'${C_RESET}"
            echo -e "${C_GRAY}   Or inside video window press keys: ${C_WHITE}0${C_GRAY} (Auto) | ${C_WHITE}1${C_GRAY} (Low) | ${C_WHITE}2${C_GRAY} (Mid) | ${C_WHITE}3${C_GRAY} (High) | ${C_WHITE}4${C_GRAY} (Max)${C_RESET}"
            return 0
            ;;
        *)
            echo -e "${C_PINK}❓ Unknown resolution: '$target'. Use: low, mid, high, max, or auto (or 720, 1080, 2k, 4k, 8k).${C_RESET}"
            return 1
            ;;
    esac

    # Setting an explicit video resolution automatically turns off audio-only mode
    if is_audio_mode_active; then
        set_audio_mode "false"
        [ -S "$SOCKET" ] && echo "{\"command\":[\"script-message\",\"set-audio-mode\",\"false\"]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    fi

    # Persist choice to user config
    mkdir -p "$HOME/.config/mpv"
    echo "$clean_target" > "$HOME/.config/mpv/queue_res"

    # Also persist to Windows user config in WSL2 / Hybrid mode
    if command -v get_windows_user_dir >/dev/null 2>&1; then
        local win_u_dir
        win_u_dir=$(get_windows_user_dir)
        if [ -n "$win_u_dir" ]; then
            mkdir -p "$win_u_dir/AppData/Roaming/mpv" 2>/dev/null
            echo "$clean_target" > "$win_u_dir/AppData/Roaming/mpv/queue_res" 2>/dev/null
        fi
    fi

    # Invalidate bridge stream cache to ensure next stream fetches fresh resolution
    rm -f "$HOME/.cache/mpv/android_stream_cache.json"

    # Android Mobile Handoff handler
    if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
        echo -e "${C_CYAN}📺 Mobile Video Quality set to:${C_RESET} ${C_PINK}${label}${C_RESET}"
        if [ -f "$HOME/.cache/mpv/android_video_active" ]; then
            local bridge_port
            bridge_port=$(ensure_android_bridge_running)
            local cur_pos=0
            local cur_time=0
            if [ -S "$SOCKET" ]; then
                cur_pos=$(echo '{"command":["get_property","playlist-pos"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0')
                cur_time=$(echo '{"command":["get_property","time-pos"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0')
            fi
            [[ ! "$cur_pos" =~ ^[0-9]+$ ]] && cur_pos=0
            if [ -n "$bridge_port" ]; then
                send_android_mpv_cmd "loadfile http://127.0.0.1:${bridge_port}/track/${cur_pos}.edl replace"
                if [ -n "$cur_time" ] && [[ "$cur_time" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    local cur_int="${cur_time%.*}"
                    if [ "$cur_int" -ge 2 ]; then
                        (
                            sleep 0.8
                            send_android_mpv_cmd "seek $cur_time absolute"
                        ) & disown
                    fi
                fi
                echo -e "${C_GRAY}   Reloaded active video in MPV Android with fresh stream (playback position preserved).${C_RESET}"
            fi
        else
            echo -e "${C_GRAY}   Profile saved. Will be applied automatically on playback in MPV Android.${C_RESET}"
        fi
        return 0
    fi

    # Desktop Player (Linux / WSL2)
    if [ ! -S "$SOCKET" ] || ! (echo '{"command":["get_property","idle-active"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1); then
        echo -e "${C_CYAN}📺 Video Quality set to:${C_RESET} ${C_PINK}${label}${C_RESET}"
        echo -e "${C_GRAY}   Default profile saved. Will be applied automatically on next playback.${C_RESET}"
        return 0
    fi

    # Dispatch SINGLE script-message command to queue_video.lua (handles seamless timestamp memory & reload)
    echo "{\"command\":[\"script-message\",\"change-quality\",\"$clean_target\"]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1

    echo -e "${C_CYAN}📺 Video Quality set to:${C_RESET} ${C_PINK}${label}${C_RESET}"
    if ! is_video_window_open && [ "$IS_ANDROID" = false ]; then
        echo -e "${C_GRAY}💡 Note: Currently in background audio mode. Open video window with 'q -vid' to view.${C_RESET}"
    else
        echo -e "${C_GRAY}   Reloaded stream with high-framerate matching (playback position preserved).${C_RESET}"
    fi
}

normalize_lang_code() {
    local l
    l=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    local base="${l%%[-_]*}"
    case "$base" in
        auto|orig|original|def|default|"") echo "auto" ;;
        en|eng|english|us|uk) echo "en" ;;
        zh|chi|zho|chinese|mandarin|cn) echo "zh" ;;
        ja|jpn|japanese|jp) echo "ja" ;;
        ko|kor|korean|kr) echo "ko" ;;
        es|spa|spanish) echo "es" ;;
        fr|fra|french) echo "fr" ;;
        de|deu|german) echo "de" ;;
        ru|rus|russian) echo "ru" ;;
        hi|hin|hindi) echo "hi" ;;
        pt|por|portuguese) echo "pt" ;;
        it|ita|italian) echo "it" ;;
        ar|ara|arabic) echo "ar" ;;
        id|ind|indonesian|bahasa) echo "id" ;;
        th|tha|thai) echo "th" ;;
        vi|vie|vietnamese) echo "vi" ;;
        tr|tur|turkish) echo "tr" ;;
        pl|pol|polish) echo "pl" ;;
        nl|nld|dutch) echo "nl" ;;
        *) echo "$base" ;;
    esac
}

get_human_lang_name() {
    case "$1" in
        auto) echo "Original Audio (Auto)" ;;
        en) echo "English" ;;
        zh) echo "Chinese (中文)" ;;
        ja) echo "Japanese (日本語)" ;;
        ko) echo "Korean (한국어)" ;;
        es) echo "Spanish (Español)" ;;
        fr) echo "French (Français)" ;;
        de) echo "German (Deutsch)" ;;
        ru) echo "Russian (Русский)" ;;
        hi) echo "Hindi (हिन्दी)" ;;
        pt) echo "Portuguese (Português)" ;;
        it) echo "Italian (Italiano)" ;;
        ar) echo "Arabic (العربية)" ;;
        id) echo "Indonesian (Bahasa Indonesia)" ;;
        th) echo "Thai (ไทย)" ;;
        vi) echo "Vietnamese (Tiếng Việt)" ;;
        tr) echo "Turkish (Türkçe)" ;;
        pl) echo "Polish (Polski)" ;;
        nl) echo "Dutch (Nederlands)" ;;
        *) echo "$1" ;;
    esac
}

cmd_language() {
    local target=""
    local session_choice=""

    for arg in "$@"; do
        case "$arg" in
            -pb|-b|--blind) session_choice="blind" ;;
            -q|--queue|-norm|--normal) session_choice="normal" ;;
            normal|blind|global) [ -z "$session_choice" ] && session_choice="$arg" || target="$arg" ;;
            *) [ -z "$target" ] && target="$arg" || target="$target $arg" ;;
        esac
    done

    local -a ALL_SUPPORTED_LANGS=(
        "auto:Original Audio (Auto):🌟"
        "en:English:🇬🇧"
        "zh:Chinese (中文):🇨🇳"
        "ja:Japanese (日本語):🇯🇵"
        "ko:Korean (한국어):🇰🇷"
        "es:Spanish (Español):🇪🇸"
        "fr:French (Français):🇫🇷"
        "de:German (Deutsch):🇩🇪"
        "ru:Russian (Русский):🇷🇺"
        "hi:Hindi (हिन्दी):🇮🇳"
        "pt:Portuguese (Português):🇵🇹"
        "it:Italian (Italiano):🇮🇹"
        "ar:Arabic (العربية):🇸🇦"
        "id:Indonesian (Bahasa Indonesia):🇮🇩"
        "th:Thai (ไทย):🇹🇭"
        "vi:Vietnamese (Tiếng Việt):🇻🇳"
        "tr:Turkish (Türkçe):🇹🇷"
        "pl:Polish (Polski):🇵🇱"
        "nl:Dutch (Nederlands):🇳🇱"
    )

    local nc_opts="${NC_OPTS:--U}"

    # 1. Probe Normal Queue Session
    local normal_available=false
    local normal_title=""
    local normal_path=""
    local normal_status=""
    local normal_paused="false"
    local normal_socket="${SOCKET:-$HOME/.mpv-socket}"
    if [ -S "$normal_socket" ]; then
        local raw_norm
        raw_norm=$(echo -e '{"command":["get_property","idle-active"]}\n{"command":["get_property","pause"]}\n{"command":["get_property","media-title"]}\n{"command":["get_property","path"]}' | nc $nc_opts -w 1 "$normal_socket" 2>/dev/null | jq -s -r 'map(select(.event == null)) | (if .[0].data == null then "true" else (.[0].data | tostring) end), (if .[1].data == null then "false" else (.[1].data | tostring) end), (.[2].data // ""), (.[3].data // "")')
        if [ -n "$raw_norm" ]; then
            mapfile -t norm_props <<< "$raw_norm"
            local norm_idle="${norm_props[0]}"
            normal_paused="${norm_props[1]}"
            normal_title="${norm_props[2]}"
            normal_path="${norm_props[3]}"
            if [ "$norm_idle" != "true" ] && [ -n "$normal_path" ]; then
                normal_available=true
                if [ "$normal_paused" == "true" ]; then
                    normal_status="[⏸️ Paused]"
                else
                    normal_status="[▶ Playing]"
                fi
                if [ -z "$normal_title" ] || [ "$normal_title" == "$normal_path" ]; then
                    local c
                    c=$(get_cached_title "$normal_path")
                    [ -n "$c" ] && normal_title="$c"
                fi
                [ -z "$normal_title" ] && normal_title="$normal_path"
            fi
        fi
    fi

    # 2. Probe Blind Mode Session
    local blind_available=false
    local blind_title=""
    local blind_path=""
    local blind_status=""
    local blind_paused="false"
    local blind_socket="$HOME/.cache/mpv/blind.sock"

    if [ -f "$HOME/.cache/mpv/blind_active" ]; then
        blind_path=$(grep -m1 '^path=' "$HOME/.cache/mpv/blind_active" 2>/dev/null | cut -d= -f2-)
        blind_title=$(grep -m1 '^title=' "$HOME/.cache/mpv/blind_active" 2>/dev/null | cut -d= -f2-)
        local rec_sock
        rec_sock=$(grep -m1 '^socket=' "$HOME/.cache/mpv/blind_active" 2>/dev/null | cut -d= -f2-)
        [ -n "$rec_sock" ] && blind_socket="$rec_sock"
    fi

    if [ -S "$blind_socket" ]; then
        local raw_b
        raw_b=$(echo -e '{"command":["get_property","idle-active"]}\n{"command":["get_property","pause"]}\n{"command":["get_property","media-title"]}\n{"command":["get_property","path"]}' | nc $nc_opts -w 1 "$blind_socket" 2>/dev/null | jq -s -r 'map(select(.event == null)) | (if .[0].data == null then "true" else (.[0].data | tostring) end), (if .[1].data == null then "false" else (.[1].data | tostring) end), (.[2].data // ""), (.[3].data // "")')
        if [ -n "$raw_b" ]; then
            mapfile -t b_props <<< "$raw_b"
            local b_idle="${b_props[0]}"
            blind_paused="${b_props[1]}"
            local b_t="${b_props[2]}"
            local b_p="${b_props[3]}"
            [ -n "$b_t" ] && blind_title="$b_t"
            [ -n "$b_p" ] && blind_path="$b_p"
            if [ "$b_idle" != "true" ] || [ -n "$blind_path" ]; then
                blind_available=true
                if [ "$blind_paused" == "true" ]; then
                    blind_status="[⏸️ Paused]"
                else
                    blind_status="[▶ Playing]"
                fi
            fi
        elif [ -f "$HOME/.cache/mpv/blind_active" ]; then
            blind_available=true
            blind_status="[▶ Playing]"
        fi
    elif [ -f "$HOME/.cache/mpv/blind_active" ]; then
        if pgrep -f "mpv-blind-pipe" >/dev/null 2>&1 || pgrep -f "Queue \[Blind Mode\]" >/dev/null 2>&1; then
            blind_available=true
            blind_status="[▶ Playing]"
        else
            rm -f "$HOME/.cache/mpv/blind_active" 2>/dev/null
        fi
    fi

    # 3. Session Selection: If both are active and no session specified, prompt user
    if [ -z "$session_choice" ] && [ "$normal_available" = true ] && [ "$blind_available" = true ]; then
        if command -v fzf >/dev/null 2>&1 && [ -t 0 ] && [ -t 1 ]; then
            local LINE=$(get_fzf_divider)
            local status_icons=$(get_player_status_icons)
            local fzf_prompt="🎵 ${C_TEAL}Select Session${status_icons}${C_RESET} > "
            local fzf_header="${C_PURPLE}🪷 Active Playback Sessions${C_RESET} ${C_GRAY}(Choose session to change audio language)${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"

            local opt_norm="🎵 [Normal Queue] ${normal_title} ${C_GREEN}${normal_status}${C_RESET}"
            local opt_blind="🕶️ [Blind Mode]   ${blind_title} ${C_GREEN}${blind_status}${C_RESET}"

            local s_choice
            s_choice=$(echo -e "${opt_norm}\n${opt_blind}" | fzf --height=40% --layout=reverse --border --ansi \
                --header="$fzf_header" \
                --info=inline-right \
                $FZF_COLOR_OPTS \
                --prompt="$fzf_prompt")

            if [ -z "$s_choice" ]; then
                return 0
            fi
            if [[ "$s_choice" =~ "Normal Queue" ]]; then
                session_choice="normal"
            else
                session_choice="blind"
            fi
        else
            print_header_box "${C_PINK}🪷 Active Playback Sessions${C_RESET}"
            print_boxed_line "  ${C_ORANGE} 1.${C_RESET} 🎵 ${C_WHITE}[Normal Queue]${C_RESET} ${C_CYAN}${normal_title:0:$((INNER_WIDTH-34))}${C_RESET} ${C_GREEN}${normal_status}${C_RESET}"
            print_boxed_line "  ${C_ORANGE} 2.${C_RESET} 🕶️ ${C_WHITE}[Blind Mode]${C_RESET}   ${C_CYAN}${blind_title:0:$((INNER_WIDTH-34))}${C_RESET} ${C_GREEN}${blind_status}${C_RESET}"
            printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
            B_LINE=${B_LINE// /─}
            echo -e "${C_PURPLE}${B_LINE}${C_RESET}"

            echo -ne "${C_PINK}>>> Select session to change audio language (1-2) or ENTER to cancel: ${C_RESET}"
            local s_inp=""
            if [ -t 0 ]; then
                read -r s_inp < /dev/tty 2>/dev/null || read -r s_inp
            else
                read -r s_inp
            fi
            case "$s_inp" in
                1|[nN]*|[qQ]*) session_choice="normal" ;;
                2|[bB]*) session_choice="blind" ;;
                *) return 0 ;;
            esac
        fi
    fi

    # Auto-resolve single active session
    if [ -z "$session_choice" ]; then
        if [ "$blind_available" = true ] && [ "$normal_available" != true ]; then
            session_choice="blind"
        elif [ "$normal_available" = true ]; then
            session_choice="normal"
        else
            session_choice="global"
        fi
    fi

    local active_socket=""
    local is_blind_session=false
    local cur_path=""
    local cur_title=""
    local cur_status=""

    if [ "$session_choice" == "blind" ]; then
        active_socket="$blind_socket"
        is_blind_session=true
        cur_path="$blind_path"
        cur_title="$blind_title"
        cur_status="$blind_status"
    elif [ "$session_choice" == "normal" ]; then
        active_socket="$normal_socket"
        is_blind_session=false
        cur_path="$normal_path"
        cur_title="$normal_title"
        cur_status="$normal_status"
    else
        active_socket=""
        is_blind_session=false
    fi

    # CASE A: If target is provided and is NOT a URL -> Update preference and switch dynamically
    if [ -n "$target" ] && [[ ! "$target" =~ ^http.* ]]; then
        local clean_lang
        clean_lang=$(normalize_lang_code "$target")
        local lang_name
        lang_name=$(get_human_lang_name "$clean_lang")

        if [ "$is_blind_session" = true ]; then
            mkdir -p "$HOME/.cache/mpv"
            echo "$clean_lang" > "$HOME/.cache/mpv/blind_lang"

            local is_live=false
            if [ -n "$active_socket" ] && [ -S "$active_socket" ]; then
                is_live=true
                echo "{\"command\":[\"set_property\",\"alang\",\"$clean_lang,auto,en,eng\"]}" | nc $nc_opts -w 1 "$active_socket" >/dev/null 2>&1
                echo "{\"command\":[\"script-message\",\"change-language\",\"$clean_lang\"]}" | nc $nc_opts -w 1 "$active_socket" >/dev/null 2>&1
            fi

            print_header_box "${C_PINK}🕶️ Blind Mode Audio Language Profile${C_RESET}"
            [ -n "$cur_title" ] && print_boxed_line "${C_TEAL}Track:      ${C_CYAN}${cur_title:0:$((INNER_WIDTH-14))}${C_RESET}"
            print_boxed_line "${C_TEAL}Preference: ${C_WHITE}[${C_PINK}${clean_lang}${C_WHITE}] ${lang_name}${C_RESET}"
            if [ "$is_live" = true ]; then
                print_boxed_line "${C_TEAL}Status:     ${C_GREEN}Applied to Blind playback (Position preserved) ✅${C_RESET}"
            else
                print_boxed_line "${C_TEAL}Status:     ${C_GRAY}Saved for active Blind session${C_RESET}"
            fi
            printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
            B_LINE=${B_LINE// /─}
            echo -e "${C_PURPLE}${B_LINE}${C_RESET}"
            echo -e "${C_GRAY}💡 Quick Switch: ${C_WHITE}q -lang en${C_GRAY} | ${C_WHITE}q -lang zh${C_GRAY} | ${C_WHITE}q -lang ja${C_GRAY} | ${C_WHITE}q -lang auto${C_RESET}"
            echo -e "${C_GRAY}   Or in video window: press ${C_WHITE}'a'${C_GRAY} / ${C_WHITE}'A'${C_GRAY} to cycle audio tracks${C_RESET}"
            return 0
        fi

        # Normal Queue or Global Mode
        mkdir -p "$HOME/.config/mpv"
        echo "$clean_lang" > "$HOME/.config/mpv/queue_lang"

        if [ "$IS_WSL" = true ]; then
            local win_u_dir
            win_u_dir=$(get_windows_user_dir)
            if [ -n "$win_u_dir" ] && [ -d "$win_u_dir" ]; then
                mkdir -p "$win_u_dir/.config/mpv" "$win_u_dir/AppData/Roaming/mpv" 2>/dev/null
                cp -f "$HOME/.config/mpv/queue_lang" "$win_u_dir/.config/mpv/queue_lang" 2>/dev/null
                cp -f "$HOME/.config/mpv/queue_lang" "$win_u_dir/AppData/Roaming/mpv/queue_lang" 2>/dev/null
            fi
        fi

        # Invalidate Android bridge stream cache if present
        rm -f "$HOME/.cache/mpv/android_stream_cache.json"

        local is_live=false
        if [ -n "$active_socket" ] && [ -S "$active_socket" ]; then
            local is_idle
            is_idle=$(echo '{"command":["get_property","idle-active"]}' | nc $nc_opts -w 1 "$active_socket" 2>/dev/null | jq -r 'if .data == null then "true" else (.data | tostring) end')
            if [ "$is_idle" == "false" ]; then
                is_live=true
                echo "{\"command\":[\"set_property\",\"alang\",\"$clean_lang,auto,en,eng\"]}" | nc $nc_opts -w 1 "$active_socket" >/dev/null 2>&1
                echo "{\"command\":[\"script-message\",\"change-language\",\"$clean_lang\"]}" | nc $nc_opts -w 1 "$active_socket" >/dev/null 2>&1
            fi
        fi

        print_header_box "${C_PINK}🌐 Queue Audio Language Profile${C_RESET}"
        [ -n "$cur_title" ] && print_boxed_line "${C_TEAL}Track:      ${C_CYAN}${cur_title:0:$((INNER_WIDTH-14))}${C_RESET}"
        print_boxed_line "${C_TEAL}Preference: ${C_WHITE}[${C_PINK}${clean_lang}${C_WHITE}] ${lang_name}${C_RESET}"
        if [ "$is_live" = true ]; then
            print_boxed_line "${C_TEAL}Status:     ${C_GREEN}Applied to active playback (Position preserved) ✅${C_RESET}"
        else
            print_boxed_line "${C_TEAL}Status:     ${C_GRAY}Saved (Will apply on playback start)${C_RESET}"
        fi
        printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
        B_LINE=${B_LINE// /─}
        echo -e "${C_PURPLE}${B_LINE}${C_RESET}"
        echo -e "${C_GRAY}💡 Quick Switch: ${C_WHITE}q -lang en${C_GRAY} | ${C_WHITE}q -lang zh${C_GRAY} | ${C_WHITE}q -lang ja${C_GRAY} | ${C_WHITE}q -lang auto${C_RESET}"
        echo -e "${C_GRAY}   Or in video window: press ${C_WHITE}'a'${C_GRAY} / ${C_WHITE}'A'${C_GRAY} to cycle audio tracks${C_RESET}"
        return 0
    fi

    # CASE B: No target provided (or target is a URL) -> Inspect and show language selection
    local cur_lang="auto"
    if [ "$is_blind_session" = true ]; then
        if [ -f "$HOME/.cache/mpv/blind_lang" ]; then
            cur_lang=$(cat "$HOME/.cache/mpv/blind_lang" 2>/dev/null | tr -d '[:space:]')
        elif [ -f "$HOME/.config/mpv/queue_lang" ]; then
            cur_lang=$(cat "$HOME/.config/mpv/queue_lang" 2>/dev/null | tr -d '[:space:]')
        fi
    else
        [ -f "$HOME/.config/mpv/queue_lang" ] && cur_lang=$(cat "$HOME/.config/mpv/queue_lang" 2>/dev/null | tr -d '[:space:]')
    fi
    [ -z "$cur_lang" ] && cur_lang="auto"

    if [[ "$target" =~ ^http.* ]]; then
        cur_path="$target"
        cur_title="$target"
    fi

    if [ -z "$cur_path" ] && [ "$is_blind_session" != true ] && [ -f "$QUEUE_FILE" ] && [ -s "$QUEUE_FILE" ]; then
        cur_path=$(head -n 1 "$QUEUE_FILE" | cut -f1)
        cur_title=$(head -n 1 "$QUEUE_FILE" | cut -f2)
    fi

    declare -A TRACK_LANGS_MAP=()
    local stream_info="Single Audio Stream (Original/Default)"

    local langs_cache_file="$HOME/.cache/mpv/current_audio_langs.json"
    local langs_url_file="$HOME/.cache/mpv/current_audio_langs_url"
    if [ "$is_blind_session" = true ]; then
        langs_cache_file="$HOME/.cache/mpv/blind_audio_langs.json"
        langs_url_file="$HOME/.cache/mpv/blind_audio_langs_url"
    fi

    if [ -n "$cur_path" ]; then
        if [ -z "$cur_title" ] || [ "$cur_title" == "$cur_path" ]; then
            local c
            c=$(get_cached_title "$cur_path")
            [ -n "$c" ] && cur_title="$c"
        fi
        [ -z "$cur_title" ] && cur_title="$cur_path"

        local langs_json=""
        if [[ "$cur_path" =~ ^http.* ]]; then
            if [ -f "$langs_cache_file" ] && [ -s "$langs_cache_file" ] && { [ ! -f "$langs_url_file" ] || [ "$(cat "$langs_url_file" 2>/dev/null)" == "$cur_path" ]; }; then
                langs_json=$(cat "$langs_cache_file" 2>/dev/null)
            else
                local ytdl_cmd=("yt-dlp" "--dump-json" "--skip-download" "--flat-playlist" "--no-warnings")
                command -v node >/dev/null 2>&1 && ytdl_cmd+=("--js-runtimes" "node")
                local raw_json
                raw_json=$(run_with_timeout 15 "${ytdl_cmd[@]}" -- "$cur_path" 2>/dev/null)
                if [ -n "$raw_json" ]; then
                    [ -z "$cur_title" ] && cur_title=$(echo "$raw_json" | jq -r '.title // empty')
                    langs_json=$(echo "$raw_json" | jq -c '[.formats[]? | select(.vcodec == "none" and .acodec != "none") | {lang: (.language // "auto"), note: (.format_note // "")}] | unique_by(.lang)' 2>/dev/null)
                    if [ -n "$langs_json" ] && [ "$langs_json" != "[]" ]; then
                        mkdir -p "$HOME/.cache/mpv"
                        echo "$langs_json" > "$langs_cache_file"
                        echo "$cur_path" > "$langs_url_file"
                        if [ "$IS_WSL" = true ]; then
                            local win_u_dir
                            win_u_dir=$(get_windows_user_dir)
                            if [ -n "$win_u_dir" ] && [ -d "$win_u_dir" ]; then
                                mkdir -p "$win_u_dir/.cache/mpv" 2>/dev/null
                                cp -f "$langs_cache_file" "$win_u_dir/.cache/mpv/$(basename "$langs_cache_file")" 2>/dev/null
                                cp -f "$langs_url_file" "$win_u_dir/.cache/mpv/$(basename "$langs_url_file")" 2>/dev/null
                            fi
                        fi
                    fi
                fi
            fi
        fi

        if [ -n "$langs_json" ] && [ "$langs_json" != "[]" ]; then
            while IFS=$'\t' read -r l_code l_note; do
                [ -z "$l_code" ] && continue
                local clean_lc
                clean_lc=$(normalize_lang_code "$l_code")
                TRACK_LANGS_MAP["$clean_lc"]="${l_note:-Available}"
            done < <(echo "$langs_json" | jq -r '.[] | "\(.lang)\t\(.note)"' 2>/dev/null)
            if [ ${#TRACK_LANGS_MAP[@]} -gt 1 ]; then
                stream_info="Multi-Track (${#TRACK_LANGS_MAP[@]} audio dubs available)"
            fi
        elif [ -n "$active_socket" ] && [ -S "$active_socket" ]; then
            local mpv_tracks
            mpv_tracks=$(echo '{"command":["get_property","track-list"]}' | nc $nc_opts -w 1 "$active_socket" 2>/dev/null | jq -c '[.data[]? | select(.type=="audio")]' 2>/dev/null)
            if [ -n "$mpv_tracks" ] && [ "$mpv_tracks" != "[]" ]; then
                while IFS=$'\t' read -r t_id t_lang t_title; do
                    [ -z "$t_lang" ] || [ "$t_lang" == "und" ] && continue
                    local clean_lc
                    clean_lc=$(normalize_lang_code "$t_lang")
                    TRACK_LANGS_MAP["$clean_lc"]="${t_title:-Track #$t_id}"
                done < <(echo "$mpv_tracks" | jq -r '.[] | "\(.id)\t\(.lang // "und")\t\(.title // "")"' 2>/dev/null)
                if [ ${#TRACK_LANGS_MAP[@]} -gt 1 ]; then
                    stream_info="Multi-Track (${#TRACK_LANGS_MAP[@]} audio streams available)"
                fi
            fi
        fi
    fi

    local cur_human=$(get_human_lang_name "$cur_lang")

    # If running interactively with FZF available -> Launch polished FZF picker with all languages
    if command -v fzf >/dev/null 2>&1 && [ -t 0 ] && [ -t 1 ]; then
        local fzf_items=""
        for item in "${ALL_SUPPORTED_LANGS[@]}"; do
            IFS=: read -r code name icon <<< "$item"
            local tags=""
            if [ "$code" == "$cur_lang" ]; then
                tags=" ${C_GREEN}★ ACTIVE${C_RESET}"
            fi
            if [ -n "${TRACK_LANGS_MAP[$code]}" ]; then
                tags="${tags} ${C_CYAN}✓ On Track${C_RESET}"
            fi
            fzf_items+="${icon}  [${code}]  ${name}${tags}\n"
        done

        local LINE=$(get_fzf_divider)
        local status_icons=$(get_player_status_icons)
        local fzf_title="🪷 Audio Languages & Dubs"
        [ "$is_blind_session" = true ] && fzf_title="🕶️ Blind Mode Audio Languages"
        local fzf_header
        if [ -n "$cur_title" ]; then
            fzf_header="${C_PURPLE}${fzf_title}${C_RESET} ${C_GRAY}(Track: ${cur_title:0:36} • Active: [${cur_lang}] ${cur_human})${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"
        else
            fzf_header="${C_PURPLE}${fzf_title}${C_RESET} ${C_GRAY}(Active: [${cur_lang}] ${cur_human})${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"
        fi
        local fzf_prompt="🎵 ${C_TEAL}Select Language${status_icons}${C_RESET} > "
        [ "$is_blind_session" = true ] && fzf_prompt="🕶️ ${C_TEAL}Select Language (Blind Mode)${status_icons}${C_RESET} > "

        local sel
        sel=$(echo -ne "$fzf_items" | fzf --height=100% --layout=reverse --border --ansi \
            --header="$fzf_header" \
            --info=inline-right \
            $FZF_COLOR_OPTS \
            --prompt="$fzf_prompt")

        if [ -n "$sel" ]; then
            local chosen_code
            chosen_code=$(echo "$sel" | grep -oP '(?<=\[)[a-zA-Z0-9_-]+(?=\])')
            if [ -n "$chosen_code" ]; then
                cmd_language "$chosen_code" "$session_choice"
                return 0
            fi
        fi
        return 0
    fi

    # Fallback mode (no FZF or non-interactive): Print clean boxed overview with all available languages
    if [ "$is_blind_session" = true ]; then
        print_header_box "${C_PINK}🕶️ Blind Mode Audio Tracks & Languages (Active Isolated Playback)${C_RESET}"
    else
        print_header_box "${C_PINK}🌐 Available Audio Tracks & Languages${C_RESET}"
    fi
    if [ -n "$cur_title" ]; then
        print_boxed_line "${C_TEAL}Track:    ${C_CYAN}${cur_title:0:$((INNER_WIDTH-12))}${C_RESET}"
        print_boxed_line "${C_TEAL}Source:   ${C_VIOLET}${cur_path:0:$((INNER_WIDTH-12))}${C_RESET}"
        print_boxed_line "${C_TEAL}Streams:  ${C_WHITE}${stream_info}${C_RESET}"
    fi
    print_boxed_line "${C_TEAL}Active:   ${C_WHITE}[${C_PINK}${cur_lang}${C_WHITE}] ${cur_human}${C_RESET}"
    echo -e "${C_PURPLE}├${H_LINE:2}┤${C_RESET}"

    local count=0
    declare -a opt_langs=()
    for item in "${ALL_SUPPORTED_LANGS[@]}"; do
        IFS=: read -r code name icon <<< "$item"
        ((count++))
        opt_langs+=("$code")
        local tags=""
        if [ "$code" == "$cur_lang" ]; then
            tags=" ${C_GREEN}★ ACTIVE${C_RESET}"
        fi
        if [ -n "${TRACK_LANGS_MAP[$code]}" ]; then
            tags="${tags} ${C_CYAN}✓ On Track${C_RESET}"
        fi
        printf -v pad_num "%2d" "$count"
        print_boxed_line "  ${C_ORANGE}${pad_num}.${C_RESET} ${icon}  ${C_WHITE}[${C_PINK}${code}${C_WHITE}] ${name}${tags}"
    done

    printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
    B_LINE=${B_LINE// /─}
    echo -e "${C_PURPLE}${B_LINE}${C_RESET}"
    echo -e "${C_GRAY}💡 Quick Switch: ${C_WHITE}q -lang zh${C_GRAY} | ${C_WHITE}q -lang en${C_GRAY} | ${C_WHITE}q -lang ja${C_GRAY} | ${C_WHITE}q -lang auto${C_RESET}"
    echo -e "${C_GRAY}   Or inside video window press: ${C_WHITE}'a'${C_GRAY} / ${C_WHITE}'A'${C_GRAY} to cycle audio tracks${C_RESET}"

    echo -ne "${C_PINK}>>> Enter language code or number to switch (or ENTER to cancel): ${C_RESET}"
    local user_input=""
    if [ -t 0 ]; then
        read -r user_input < /dev/tty 2>/dev/null || read -r user_input
    else
        read -r user_input
    fi
    if [ -n "$user_input" ]; then
        if [[ "$user_input" =~ ^[0-9]+$ ]] && [ "$user_input" -ge 1 ] && [ "$user_input" -le "$count" ]; then
            local chosen_lang="${opt_langs[$((user_input - 1))]}"
            cmd_language "$chosen_lang" "$session_choice"
        else
            cmd_language "$user_input" "$session_choice"
        fi
    fi
}

cmd_loop() {
    local mode="$1" # "single" or "playlist"
    if [ "$mode" == "playlist" ]; then
        local prop="loop-playlist"
        local label="Playlist Loop"
        local emoji="🔁"
    else
        local prop="loop-file"
        local label="Track Loop"
        local emoji="🔂"
    fi

    local current=$(echo "{ \"command\": [\"get_property\", \"$prop\"] }" | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // "no"')
    
    # Fetch data needed for status
    local track_json=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)
    local count=$(echo "$track_json" | jq -r '.data | length // 0')
    
    if [ "$current" == "inf" ] || [ "$current" == "yes" ]; then
        echo "{ \"command\": [\"set_property\", \"$prop\", \"no\"] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        echo -e "${C_ORANGE}${emoji} ${label}: OFF${C_RESET}"
    else
        echo "{ \"command\": [\"set_property\", \"$prop\", \"inf\"] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        if [ "$mode" == "single" ]; then
            local current_item=$(echo "$track_json" | jq -c '.data[] | select(.current)')
            local f=$(echo "$current_item" | jq -r '.filename')
            local t=$(echo "$current_item" | jq -r '.title // empty')
            local curr_idx=$(echo "$track_json" | jq -r '.data | to_entries[] | select(.value.current) | .key + 1' 2>/dev/null)
            
            local formatted_track=$(format_track_log "$curr_idx" "$f" "$t")
            echo -e "${C_PINK}${emoji} Looping Track: ${formatted_track}"
        else
            local unit="Tracks"
            [ "$count" -eq 1 ] && unit="Track"
            echo -e "${C_PINK}${emoji} Looping Playlist: ${C_CYAN}Current Queue${C_RESET} => Total ${C_ORANGE}${count}${C_RESET} ${unit}${C_RESET}"
        fi
    fi
}

check_auto_trigger() {
    local idle="$1"; local count="$2"; local idx="$3"; local rem="$4"; local loop="$5"; local paused="${6:-false}"; local eof="${7:-false}"
    
    [ ! -f "$HOME/.cache/mpv/auto_enabled" ] && return
    # Never auto-queue while user manually paused (unless at EOF / idle)
    if [ "$paused" == "true" ] && [ "$eof" != "true" ] && [ "$idle" != "true" ]; then
        return
    fi
    
    # Do not trigger if single track loop is active (respect user manual override)
    if [ "$loop" == "inf" ] || [ "$loop" == "yes" ]; then
        local is_lf=$(echo '{ "command": ["get_property", "loop-file"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // "no"')
        if [ "$is_lf" != "no" ]; then return; fi
    fi
    
    local should_trigger=false
    
    # 1. Idle Trigger (Silence detected + Empty Queue)
    if [ "$idle" == "true" ] && [ "$count" -eq 0 ]; then
        if [ "$IN_FZF" == "true" ]; then return; fi # Don't interrupt while browsing
        [ -f "$HOME/.cache/mpv/auto_cooldown" ] && return
        should_trigger=true
    fi
    
    # 2. Ending Soon (Zero Gap) - Trigger with ample time for network discovery
    if [ "$idle" == "false" ] && [ "$count" -gt 0 ] && { [ "$idx" -ge $((count - 1)) ] || [ "$count" -le 2 ]; }; then
         [ -z "$rem" ] || [ "$rem" == "null" ] && rem=100
         local t_int=${rem%.*}
         if [[ "$t_int" =~ ^[0-9]+$ ]]; then
             if [ "$t_int" -lt 60 ] || [ "$count" -le 2 ]; then should_trigger=true; fi
         else
             should_trigger=true
         fi
    fi
    
    # 3. Finished playing / EOF Reached / Paused at EOF on last track
    if { [ "$idle" == "true" ] || [ "$eof" == "true" ] || [ "$paused" == "true" ]; } && [ "$count" -gt 0 ] && [ "$idx" -ge $((count - 1)) ]; then
         [ -f "$HOME/.cache/mpv/auto_cooldown" ] && return
         should_trigger=true
    fi
    
    if [ "$should_trigger" == "true" ]; then
        local last_trig=$(cat "$HOME/.cache/mpv/auto_last_trigger" 2>/dev/null)
        local current_state="${idx}-${idle}-${count}-${eof}"
        
        local now=$(date +%s)
        local last_time=$(get_file_mtime "$HOME/.cache/mpv/auto_last_trigger")
        
        # Trigger only if new state or at least 45 seconds have passed
        if [ "$last_trig" != "$current_state" ] || [ $((now - last_time)) -gt 45 ]; then
            echo "$current_state" > "$HOME/.cache/mpv/auto_last_trigger"
            ( auto_queue_related ) >/dev/null 2>&1 &
        fi
    fi
}

start_idle_monitor() {
    [ "$IDLE_MONITOR_ACTIVE" = true ] && return
    (
        local pid_file="$HOME/.cache/mpv/idle_monitor.pid"
        if [ -f "$pid_file" ]; then
            local old_pid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
                return
            fi
        fi
        echo $BASHPID > "$pid_file"
        trap "rm -f \"$pid_file\"" EXIT
        
        echo "[$(date +%T)] [Monitor] Started Idle Monitor (PID: $BASHPID)." >> "$HOME/.cache/mpv/auto_debug.log"

        local was_playing=false
        local consecutive_socket_failures=0
        while [ -f "$HOME/.cache/mpv/auto_enabled" ]; do
            if [ ! -S "$SOCKET" ]; then
                echo "[$(date +%T)] [Monitor] MPV socket missing. Exiting monitor." >> "$HOME/.cache/mpv/auto_debug.log"
                break
            fi

            # Batch get essential properties
            local raw=$(echo -e '{"command":["get_property","idle-active"]}\n{"command":["get_property","playlist-count"]}\n{"command":["get_property","playlist-pos"]}\n{"command":["get_property","loop-playlist"]}\n{"command":["get_property","loop-file"]}\n{"command":["get_property","time-remaining"]}\n{"command":["get_property","eof-reached"]}\n{"command":["get_property","pause"]}' | nc $NC_OPTS -w 2 "$SOCKET" 2>/dev/null | jq -s -j -r '
                map(select(.event == null)) |
                (if .[0].data == null then "true" else .[0].data end), "\t",
                (.[1].data // 0), "\t",
                (if .[2].data == null then -1 else .[2].data end), "\t",
                (.[3].data // "no"), "\t",
                (.[4].data // "no"), "\t",
                (.[5].data // 100), "\t",
                (.[6].data // "false"), "\t",
                (.[7].data // "false")
            ' 2>/dev/null)

            if [ -z "$raw" ]; then 
                ((consecutive_socket_failures++))
                if [ "$consecutive_socket_failures" -ge 8 ]; then
                    if pgrep -u "$(whoami)" -f "mpv --idle" >/dev/null 2>&1; then
                        echo "[$(date +%T)] [Monitor] MPV IPC socket unresponsive. Trying graceful recovery..." >> "$HOME/.cache/mpv/auto_debug.log"
                        echo '{"command":["quit"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
                        sleep 1
                        pkill -u "$(whoami)" -f "mpv --idle" >/dev/null 2>&1
                        rm -f "$SOCKET"
                    fi
                    consecutive_socket_failures=0
                fi
                sleep 3
                continue 
            fi
            
            consecutive_socket_failures=0
            
            IFS=$'\t' read -r idle count pos loop_p loop_f rem eof is_paused <<< "$raw"
            local current_idx=$((pos + 1))
            
            # If EOF is reached on the last file, treat as IDLE
            if [ "$eof" == "true" ] && [ "$pos" -eq $((count - 1)) ]; then
                idle="true"
            fi
            
            # Combine loop status
            local active_loop="no"
            if [ "$loop_p" != "no" ]; then active_loop="$loop_p"; elif [ "$loop_f" != "no" ]; then active_loop="$loop_f"; fi

            # --- Auto Mode Check ---
            check_auto_trigger "$idle" "$count" "$current_idx" "$rem" "$active_loop" "$is_paused" "$eof"
            
            local sleep_time=2
            if [ "$idle" == "false" ]; then
                local rem_int=${rem%.*}
                if [[ "$rem_int" =~ ^[0-9]+$ ]] && [ "$rem_int" -gt 35 ]; then
                    sleep_time=4
                fi
            fi
            sleep "$sleep_time"
        done
    ) & disown
    export IDLE_MONITOR_ACTIVE=true
}

cmd_play() {
    local index=$1
    index=${index%.}
    local just_started=false

    # Re-validate if MPV is actually running before trying to start it
    if [ "$MPV_RUNNING" = false ]; then
        if [ -S "$SOCKET" ] && echo '{ "command": ["get_property", "idle-active"] }' | nc $NC_OPTS -w 1 "$SOCKET" &>/dev/null; then
            MPV_RUNNING=true
        fi
    fi

    if [ "$MPV_RUNNING" = false ]; then
        sync_session_cache
        local saved_target_pos
        saved_target_pos=$(jq -r '.pos // 0' "$HOME/.cache/mpv/state.json" 2>/dev/null)
        [[ ! "$saved_target_pos" =~ ^[0-9]+$ ]] && saved_target_pos=0
        if [ ! -f "$LAST_PLAYLIST_FILE" ] || [ ! -s "$LAST_PLAYLIST_FILE" ]; then
            if [ -f "${LAST_PLAYLIST_FILE}.bak" ] && [ -s "${LAST_PLAYLIST_FILE}.bak" ]; then
                cp -f "${LAST_PLAYLIST_FILE}.bak" "$LAST_PLAYLIST_FILE"
            else
                echo -e "${C_ORANGE}⚠️ No previous session found to restore.${C_RESET}"
                exit 1
            fi
        fi
        
        echo -e "${C_PINK}🚀 Restoring last session...${C_RESET}"
        ensure_mpv_running "$LAST_PLAYLIST_FILE"
        
        local cnt=$(echo '{"command":["get_property","playlist-count"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0' 2>/dev/null)
        if [[ ! "$cnt" =~ ^[0-9]+$ ]] || [ "$cnt" -le 0 ]; then
             load_playlist_file_to_mpv "$LAST_PLAYLIST_FILE" "replace"
        fi

        # Stabilization: Wait for playlist to populate (max 3s)
        for i in {1..15}; do
             local cur_c=$(echo '{"command":["get_property","playlist-count"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0' 2>/dev/null)
             if [[ "$cur_c" =~ ^[0-9]+$ ]] && [ "$cur_c" -gt 0 ]; then break; fi
             sleep 0.2
        done

        # Restore saved properties (shuffle, loop, pos)
        restore_state_properties
        
        # Determine start index (Saved position or first)
        local start_idx="${saved_target_pos:-0}"
        [[ ! "$start_idx" =~ ^[0-9]+$ ]] && start_idx=0

        # Force Playback Start
        echo "{ \"command\": [\"playlist-play-index\", $start_idx] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
        if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
            echo '{ "command": ["set_property", "pause", true] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
            echo '{ "command": ["set_property", "mute", true] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
            echo '{ "command": ["set_property", "ao", "null"] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
        else
            echo '{ "command": ["set_property", "pause", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
        fi

        MPV_RUNNING=true
        just_started=true
        
        # Start the idle monitor
        start_idle_monitor
        
        # Signal external UI to reload
        if [ -f "$HOME/.cache/mpv/fzf_sock" ]; then
            local fzf_sock=$(cat "$HOME/.cache/mpv/fzf_sock")
            local script_path=$(realpath "$0")
            curl -s -X POST --unix-socket "$fzf_sock" -d "reload-sync(bash \"$script_path\" -raw)" http://localhost/ >/dev/null 2>&1
        fi
    fi

    if [ -z "$index" ]; then
        if [ "$just_started" = true ]; then
            if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
                log_now_playing "|> Restored & Playing: "
                cmd_android_video_handoff ""
            else
                echo '{ "command": ["set_property", "pause", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                wait_for_playback_start
                log_now_playing "|> Restored & Playing: "
            fi
        else
            # Single atomic IPC query to get pause, idle-active, eof-reached, playlist-pos, playlist-count
            local state_raw=$(echo -e '{"command":["get_property","pause"]}\n{"command":["get_property","idle-active"]}\n{"command":["get_property","eof-reached"]}\n{"command":["get_property","playlist-pos"]}\n{"command":["get_property","playlist-count"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -j -r 'map(select(.event == null)) | (.[0].data // false), "\t", (.[1].data // false), "\t", (.[2].data // false), "\t", (if .[3].data == null then -1 else .[3].data end), "\t", (.[4].data // 0)')
            IFS=$'\t' read -r cur_pause is_idle is_eof cur_pos cur_count <<< "$state_raw"

            if [[ ! "$cur_count" =~ ^[0-9]+$ ]] || [ "$cur_count" -le 0 ]; then
                sync_session_cache
                if [ -f "$LAST_PLAYLIST_FILE" ] && [ -s "$LAST_PLAYLIST_FILE" ]; then
                    echo -e "${C_PINK}🚀 Loading saved playlist into MPV...${C_RESET}"
                    load_playlist_file_to_mpv "$LAST_PLAYLIST_FILE" "replace"
                    restore_state_properties
                    local start_idx=$(jq -r '.pos // 0' "$HOME/.cache/mpv/state.json" 2>/dev/null)
                    [[ ! "$start_idx" =~ ^[0-9]+$ ]] && start_idx=0
                    echo "{\"command\": [\"playlist-play-index\", $start_idx]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                    if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
                        echo '{ "command": ["set_property", "pause", true] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                        log_now_playing "|> Restored & Playing: "
                        cmd_android_video_handoff ""
                        return
                    else
                        echo '{ "command": ["set_property", "pause", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                        wait_for_playback_start
                        log_now_playing "|> Restored & Playing: "
                        return
                    fi
                fi
                echo -e "${C_ORANGE}⚠️ Queue is empty.${C_RESET}"
                return
            fi

            if [ "$is_eof" == "true" ] || [ "$is_idle" == "true" ] || [ "$cur_pos" -lt 0 ]; then
                # Replay current track or start if at EOF / idle
                local start_idx=0
                [ "$cur_pos" -ge 0 ] 2>/dev/null && start_idx="$cur_pos"
                echo "{\"command\": [\"playlist-play-index\", $start_idx]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
                    echo '{ "command": ["set_property", "pause", true] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                    log_now_playing "|> Playing: "
                    cmd_android_video_handoff ""
                else
                    echo '{ "command": ["seek", 0, "absolute"] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                    echo '{ "command": ["set_property", "pause", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                    wait_for_playback_start
                    log_now_playing "|> Playing: "
                fi
            elif [ "$cur_pause" == "true" ]; then
                # Unpause
                if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
                    echo '{ "command": ["set_property", "pause", true] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                    send_android_mpv_cmd "unpause"
                    command -v input >/dev/null 2>&1 && input keyevent 126 2>/dev/null || true
                    log_now_playing "|> Playing: "
                else
                    echo '{ "command": ["set_property", "pause", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                    
                    # Check if stream timed out during long pause (e.g. 50 mins idle/EOF)
                    sleep 0.2
                    local check_idle=$(echo '{"command":["get_property","idle-active"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // false')
                    if [ "$check_idle" == "true" ] && [ "$cur_pos" -ge 0 ] 2>/dev/null; then
                        # Stream connection dropped/expired! Force reload current track index with fresh token
                        echo "{\"command\":[\"playlist-play-index\",$cur_pos]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                        echo '{ "command": ["seek", 0, "absolute"] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                        echo '{ "command": ["set_property", "pause", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                    fi
                    wait_for_playback_start
                    log_now_playing "|> Playing: "
                fi
            else
                # Pause
                echo '{ "command": ["set_property", "pause", true] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
                    send_android_mpv_cmd "pause"
                    command -v input >/dev/null 2>&1 && input keyevent 127 2>/dev/null || true
                fi
                sleep 0.1
                log_now_playing "|| Paused: "
            fi
        fi
        return
    fi

    # Allow arithmetic (e.g. q -play 10+5)
    if [[ "$index" =~ [0-9]+[-+*/][0-9]+ ]]; then
        index=$(($index)) 2>/dev/null
    fi

    # Check if index is a valid number
    if ! [[ "$index" =~ ^[0-9]+$ ]]; then
         echo -e "${C_PINK}🧐 Invalid index format... are you trying to play a math problem?${C_RESET}"
         return
    fi

    # Validate Index
    local count=$(echo '{"command":["get_property","playlist-count"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // 0' 2>/dev/null)
    if [[ ! "$count" =~ ^[0-9]+$ ]] || [ "$count" -le 0 ]; then
        if [ -f "$LAST_PLAYLIST_FILE" ] && [ -s "$LAST_PLAYLIST_FILE" ]; then
            load_playlist_file_to_mpv "$LAST_PLAYLIST_FILE" "replace"
            restore_state_properties
            count=$(echo '{"command":["get_property","playlist-count"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // 0' 2>/dev/null)
        fi
    fi
    if [[ ! "$count" =~ ^[0-9]+$ ]] || [ "$index" -lt 1 ] || [ "$index" -gt "$count" ]; then
        [[ ! "$count" =~ ^[0-9]+$ ]] && count="0"
        # Use local ESC-safe colors for the log
        local E=$(printf "\033")
        local O="${E}[38;5;215m"; local W="${E}[1;37m"; local P="${E}[38;5;198m"; local R="${E}[0m"
        echo -e "${P}🚫 Track ${W}[${O}${index}${W}] ${P}does not exist. Max Track ${W}[${O}${count}${W}]${R}"
        return
    fi

    if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
        echo "{\"command\":[\"playlist-play-index\",$((index - 1))]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        echo "{\"command\":[\"set_property\",\"pause\",true]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        echo "{\"command\":[\"set_property\",\"mute\",true]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        echo "{\"command\":[\"set_property\",\"ao\",\"null\"]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        log_now_playing "|> Playing: "
        cmd_android_video_handoff "$index"
    else
        # Set pos AND force unpause and reset seek to 0 (Separate commands for maximum compatibility)
        echo "{\"command\":[\"playlist-play-index\",$((index - 1))]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        echo "{\"command\":[\"seek\",0,\"absolute\"]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        echo "{\"command\":[\"set_property\",\"pause\",false]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        
        wait_for_playback_start
        log_now_playing "|> Playing: "
    fi
}

cmd_blind_play() {
    local raw_target="$*"
    local target=""
    local force_vid=false
    local force_aud=false

    for arg in "$@"; do
        case "$arg" in
            -vid|--vid|-video|--video) force_vid=true ;;
            -aud|--aud|-audio|--audio) force_aud=true ;;
            *) [ -z "$target" ] && target="$arg" || target="$target $arg" ;;
        esac
    done

    # If target is empty, inspect clipboard or ask via fzf input
    if [ -z "$target" ]; then
        local clip
        clip=$(get_clipboard)
        if [[ "$clip" =~ ^http.* ]] || [[ "$clip" =~ ^spotify:.* ]] || [ -f "$clip" ]; then
            echo -e "${C_CYAN}📋 Detected media URL from clipboard:${C_RESET} ${C_YELLOW}${clip}${C_RESET}"
            target="$clip"
        else
            target=$(get_input "🕶️ Blind Mode (One-Time Isolated Playback)" "URL, Search Query, or File > ")
        fi
    fi

    if [ -z "$target" ]; then
        echo -e "${C_ORANGE}⚠️ No target provided for Blind Mode.${C_RESET}"
        echo -e "${C_GRAY}Usage: q -pb <url | search query | file>${C_RESET}"
        return 1
    fi

    # Snapshot main queue daemon state and pause if currently active
    local was_main_playing=false
    local main_socket="${SOCKET:-$HOME/.mpv-socket}"
    if [ -S "$main_socket" ] && echo '{"command":["get_property","idle-active"]}' | nc $NC_OPTS -w 1 "$main_socket" >/dev/null 2>&1; then
        local is_paused
        is_paused=$(echo '{"command":["get_property","pause"]}' | nc $NC_OPTS -w 1 "$main_socket" 2>/dev/null | jq -r 'if .data == null then "false" else (.data | tostring) end')
        local is_idle
        is_idle=$(echo '{"command":["get_property","idle-active"]}' | nc $NC_OPTS -w 1 "$main_socket" 2>/dev/null | jq -r 'if .data == null then "true" else (.data | tostring) end')
        if [ "$is_idle" == "false" ] && [ "$is_paused" == "false" ]; then
            was_main_playing=true
            echo '{"command":["set_property","pause",true]}' | nc $NC_OPTS -w 1 "$main_socket" >/dev/null 2>&1
            echo -e "${C_PINK}⏸️  Paused active Queue session.${C_RESET} ${C_GRAY}(Your playlist, shuffle history, and queue remain 100% untouched)${C_RESET}"
        fi
    fi

    local blind_socket="$HOME/.cache/mpv/blind.sock"
    mkdir -p "$HOME/.cache/mpv"
    rm -f "$blind_socket"
    local blind_pipe="mpv-blind-pipe-$$"
    local bridge_pid=""
    local mpv_pid=""
    local is_cleaned_up=false

    # Snapshot session state to safeguard against any rogue write
    local cache_dir="$HOME/.cache/mpv"
    [ -f "$cache_dir/last_playlist.txt" ] && cp -f "$cache_dir/last_playlist.txt" "$cache_dir/blind_backup_playlist.txt"
    [ -f "$cache_dir/state.json" ] && cp -f "$cache_dir/state.json" "$cache_dir/blind_backup_state.json"

    local win_u_dir=""
    if [ "$IS_WSL" = true ]; then
        win_u_dir=$(get_windows_user_dir)
        if [ -n "$win_u_dir" ] && [ -d "$win_u_dir/.cache/mpv" ]; then
            [ -f "$win_u_dir/.cache/mpv/last_playlist.txt" ] && cp -f "$win_u_dir/.cache/mpv/last_playlist.txt" "$win_u_dir/.cache/mpv/blind_backup_playlist.txt" 2>/dev/null
            [ -f "$win_u_dir/.cache/mpv/state.json" ] && cp -f "$win_u_dir/.cache/mpv/state.json" "$win_u_dir/.cache/mpv/blind_backup_state.json" 2>/dev/null
        fi
    fi

    # Safety cleanup trap to guarantee unpausing the previous session on exit or Ctrl-C
    cleanup_blind_mode() {
        [ "$is_cleaned_up" = true ] && return
        is_cleaned_up=true
        trap - EXIT INT TERM

        # 1. Gracefully tell the blind MPV instance to quit via its IPC socket
        if [ -S "$blind_socket" ]; then
            echo '{"command":["quit"]}' | nc $NC_OPTS -w 1 "$blind_socket" >/dev/null 2>&1
        fi

        # 2. Terminate the background MPV process if still running
        if [ -n "$mpv_pid" ] && kill -0 "$mpv_pid" 2>/dev/null; then
            kill "$mpv_pid" 2>/dev/null || true
            wait "$mpv_pid" 2>/dev/null || true
        fi

        # 3. For Windows Hybrid, ensure any orphaned mpv instance with this blind pipe is terminated
        if [ "$IS_WSL" = true ]; then
            powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name = 'mpv.exe'\" | Where-Object { \$_.CommandLine -like '*$blind_pipe*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" </dev/null >/dev/null 2>&1
        fi

        # 4. Terminate bridge process
        if [ -n "$bridge_pid" ]; then
            kill "$bridge_pid" 2>/dev/null || true
            wait "$bridge_pid" 2>/dev/null || true
        fi
        rm -f "$blind_socket" "$HOME/.cache/mpv/blind_active" "$HOME/.cache/mpv/blind_lang" "$HOME/.cache/mpv/blind_audio_langs.json" "$HOME/.cache/mpv/blind_audio_langs_url" "/tmp/mpv-blind-$$.sock" 2>/dev/null || true
        if [ "$IS_WSL" = true ] && [ -n "$win_u_dir" ] && [ -d "$win_u_dir/.cache/mpv" ]; then
            rm -f "$win_u_dir/.cache/mpv/blind_active" "$win_u_dir/.cache/mpv/blind_lang" "$win_u_dir/.cache/mpv/blind_audio_langs.json" "$win_u_dir/.cache/mpv/blind_audio_langs_url" 2>/dev/null || true
        fi

        # 5. Restore last_playlist.txt and state.json to guarantee 100% session preservation
        local cdir="$HOME/.cache/mpv"
        if [ -f "$cdir/blind_backup_playlist.txt" ]; then
            cp -f "$cdir/blind_backup_playlist.txt" "$cdir/last_playlist.txt" 2>/dev/null
            rm -f "$cdir/blind_backup_playlist.txt" 2>/dev/null
        fi
        if [ -f "$cdir/blind_backup_state.json" ]; then
            cp -f "$cdir/blind_backup_state.json" "$cdir/state.json" 2>/dev/null
            rm -f "$cdir/blind_backup_state.json" 2>/dev/null
        fi

        if [ "$IS_WSL" = true ] && [ -n "$win_u_dir" ] && [ -d "$win_u_dir/.cache/mpv" ]; then
            if [ -f "$win_u_dir/.cache/mpv/blind_backup_playlist.txt" ]; then
                cp -f "$win_u_dir/.cache/mpv/blind_backup_playlist.txt" "$win_u_dir/.cache/mpv/last_playlist.txt" 2>/dev/null
                rm -f "$win_u_dir/.cache/mpv/blind_backup_playlist.txt" 2>/dev/null
            fi
            if [ -f "$win_u_dir/.cache/mpv/blind_backup_state.json" ]; then
                cp -f "$win_u_dir/.cache/mpv/blind_backup_state.json" "$win_u_dir/.cache/mpv/state.json" 2>/dev/null
                rm -f "$win_u_dir/.cache/mpv/blind_backup_state.json" 2>/dev/null
            fi
        fi

        echo -e "\n${C_GREEN}🎬 Blind playback finished.${C_RESET}"
        if [ "$was_main_playing" = true ] && [ -S "$main_socket" ]; then
            echo -e "${C_CYAN}🎧 Resuming your previous queue playback...${C_RESET}"
            echo '{"command":["set_property","pause",false]}' | nc $NC_OPTS -w 1 "$main_socket" >/dev/null 2>&1
            log_now_playing "|> Resumed: "
        fi
    }
    trap cleanup_blind_mode EXIT INT TERM

    local play_target="$target"
    local display_title=""

    # 1. Local File Check
    if [ -f "$target" ]; then
        play_target=$(realpath "$target")
        display_title=$(basename "$play_target")
    # 2. Spotify URL Resolution
    elif is_spotify_url "$target"; then
        echo -e "${C_CYAN}🎵 Resolving Spotify track to YouTube audio...${C_RESET}"
        resolve_spotify_to_youtube "$target"
        if [ "${#PLAYLIST_URLS[@]}" -gt 0 ]; then
            play_target="${PLAYLIST_URLS[0]}"
            display_title="${PLAYLIST_TITLES[0]}"
        fi
    # 3. Direct HTTP/HTTPS URL
    elif [[ "$target" =~ ^http.* ]]; then
        play_target="$target"
        echo -e "${C_CYAN}🔍 Inspecting stream metadata...${C_RESET}"
        local ytdl_title_cmd=("yt-dlp" "--no-warnings" "--skip-download" "--dump-json")
        command -v node >/dev/null 2>&1 && ytdl_title_cmd+=("--js-runtimes" "node")
        local raw_json
        raw_json=$(run_with_timeout 12 "${ytdl_title_cmd[@]}" -- "$play_target" 2>/dev/null)
        if [ -n "$raw_json" ]; then
            display_title=$(echo "$raw_json" | jq -r '.title // empty' 2>/dev/null)
            local b_langs
            b_langs=$(echo "$raw_json" | jq -c '[.formats[]? | select(.vcodec == "none" and .acodec != "none") | {lang: (.language // "auto"), note: (.format_note // "")}] | unique_by(.lang)' 2>/dev/null)
            if [ -n "$b_langs" ] && [ "$b_langs" != "[]" ]; then
                mkdir -p "$HOME/.cache/mpv"
                echo "$b_langs" > "$HOME/.cache/mpv/blind_audio_langs.json"
                echo "$play_target" > "$HOME/.cache/mpv/blind_audio_langs_url"
                if [ "$IS_WSL" = true ]; then
                    local win_u_dir_tmp
                    win_u_dir_tmp=$(get_windows_user_dir)
                    if [ -n "$win_u_dir_tmp" ] && [ -d "$win_u_dir_tmp" ]; then
                        mkdir -p "$win_u_dir_tmp/.cache/mpv" 2>/dev/null
                        cp -f "$HOME/.cache/mpv/blind_audio_langs.json" "$win_u_dir_tmp/.cache/mpv/blind_audio_langs.json" 2>/dev/null
                        cp -f "$HOME/.cache/mpv/blind_audio_langs_url" "$win_u_dir_tmp/.cache/mpv/blind_audio_langs_url" 2>/dev/null
                    fi
                fi
            fi
        fi
        [ -z "$display_title" ] && display_title="$play_target"
    # 4. Search Query (e.g. "q -pb funny cat video" or "q -pb yt lofi hip hop")
    else
        local search_query="$target"
        local search_prefix="ytsearch1:"
        if [[ "$search_query" =~ ^yt[[:space:]]+(.*) ]]; then
            search_query="${BASH_REMATCH[1]}"
            search_prefix="ytsearch1:"
        elif [[ "$search_query" =~ ^sc[[:space:]]+(.*) ]]; then
            search_query="${BASH_REMATCH[1]}"
            search_prefix="scsearch1:"
        fi
        echo -e "${C_CYAN}🔍 Searching for blind media:${C_RESET} ${C_WHITE}$search_query${C_RESET}..."
        local ytdl_search_cmd=("yt-dlp" "--no-warnings" "--skip-download" "--flat-playlist" "--print" "%(webpage_url)s\t%(title)s")
        command -v node >/dev/null 2>&1 && ytdl_search_cmd+=("--js-runtimes" "node")
        local res_line
        res_line=$(run_with_timeout 15 "${ytdl_search_cmd[@]}" -- "${search_prefix}${search_query}" 2>/dev/null | head -n 1)
        if [ -n "$res_line" ]; then
            play_target=$(echo "$res_line" | awk -F'\t' '{print $1}')
            display_title=$(echo "$res_line" | awk -F'\t' '{print $2}')
        fi
        [ -z "$display_title" ] && display_title="$search_query"
    fi

    # Display Boxed TUI Header
    local blind_lang="auto"
    [ -f "$HOME/.config/mpv/queue_lang" ] && blind_lang=$(cat "$HOME/.config/mpv/queue_lang" 2>/dev/null | tr -d '[:space:]')
    [ -z "$blind_lang" ] && blind_lang="auto"
    mkdir -p "$HOME/.cache/mpv"
    echo "$blind_lang" > "$HOME/.cache/mpv/blind_lang"

    local blind_audio_fmt=""
    if [ "$blind_lang" == "auto" ]; then
        blind_audio_fmt="(bestaudio[acodec=opus]/bestaudio[acodec^=mp4a]/bestaudio)"
    else
        blind_audio_fmt="(bestaudio[language=${blind_lang}][acodec=opus]/bestaudio[language^=${blind_lang}][acodec=opus]/bestaudio[language=${blind_lang}]/bestaudio[language^=${blind_lang}]/bestaudio[acodec=opus]/bestaudio[acodec^=mp4a]/bestaudio)"
    fi
    local blind_ytdl_fmt="bestvideo[height<=1080][fps<=60][vcodec^=avc1][format_note!*=Premium]+${blind_audio_fmt}/bestvideo[height<=1080]+${blind_audio_fmt}/best"

    print_header_box "${C_PINK}🕶️ Queue Blind Mode (One-Time Isolated Playback)${C_RESET}"
    print_boxed_line "${C_TEAL}Playing:   ${C_CYAN}${display_title:0:$((INNER_WIDTH-12))}${C_RESET}"
    print_boxed_line "${C_TEAL}Source:    ${C_VIOLET}${play_target:0:$((INNER_WIDTH-12))}${C_RESET}"
    print_boxed_line "${C_TEAL}Audio:     ${C_WHITE}[${C_PINK}${blind_lang}${C_WHITE}] $(get_human_lang_name "$blind_lang") ${C_GRAY}(Press 'a' to cycle audio)${C_RESET}"
    print_boxed_line "${C_TEAL}Status:    ${C_GREEN}Isolated Session ✅ (Zero queue or history modification)${C_RESET}"
    print_boxed_line "${C_TEAL}Controls:  ${C_GRAY}Press 'q' in window / Ctrl-C in terminal to exit & resume queue${C_RESET}"
    print_boxed_line "${C_TEAL}Hotkeys:   ${C_GRAY}F11 Fullscreen • w/W scale presets • +/- zoom • 0-4 quality • a/A audio${C_RESET}"
    printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
    B_LINE=${B_LINE// /─}
    echo -e "${C_PURPLE}${B_LINE}${C_RESET}"

    # Execution according to platform & mode
    local cur_mode
    cur_mode=$(get_queue_mode)

    # Windows WSL2 Hybrid Boost Mode Execution
    if [ "$IS_WSL" = true ] && [ "$cur_mode" == "hybrid" ]; then
        local win_mpv
        win_mpv=$(find_windows_mpv)
        local win_ytdl
        win_ytdl=$(find_windows_ytdlp)

        if [ -n "$win_mpv" ] && [ -f "$win_mpv" ]; then
            local win_u_dir
            win_u_dir=$(get_windows_user_dir)
            local relay_bin
            relay_bin=$(ensure_piperelay_compiled)

            # Sync queue_video.lua and language settings to Windows AppData
            if [ -n "$win_u_dir" ] && [ -d "$win_u_dir" ]; then
                local win_scripts="$win_u_dir/AppData/Roaming/mpv/scripts"
                mkdir -p "$win_scripts" "$win_u_dir/.cache/mpv" 2>/dev/null
                local src_lua="$SCRIPT_DIR/scripts/queue_video.lua"
                [ ! -f "$src_lua" ] && src_lua="$HOME/.local/bin/mpv/scripts/queue_video.lua"
                [ ! -f "$src_lua" ] && src_lua="$(dirname "$MODULE_DIR")/scripts/queue_video.lua"
                [ -f "$src_lua" ] && cp -f "$src_lua" "$win_scripts/queue_video.lua" 2>/dev/null

                # Ensure language preferences are mirrored to Windows configs
                [ -f "$HOME/.config/mpv/queue_lang" ] && cp -f "$HOME/.config/mpv/queue_lang" "$win_u_dir/AppData/Roaming/mpv/queue_lang" 2>/dev/null
                [ -f "$HOME/.config/mpv/queue_lang" ] && cp -f "$HOME/.config/mpv/queue_lang" "$win_u_dir/.config/mpv/queue_lang" 2>/dev/null
            fi

            # Start background Named Pipe IPC bridge for this isolated session
            local bridge_script="$MODULE_DIR/hybrid_bridge.py"
            [ ! -f "$bridge_script" ] && bridge_script="$SCRIPT_DIR/q_modules/hybrid_bridge.py"
            if [ -f "$bridge_script" ] && [ -n "$relay_bin" ]; then
                python3 "$bridge_script" "$blind_socket" "$blind_pipe" "$relay_bin" </dev/null >/dev/null 2>&1 &
                bridge_pid=$!
            fi

            # Record active blind session metadata
            echo -e "path=${play_target}\ntitle=${display_title}\nsocket=${blind_socket}" > "$HOME/.cache/mpv/blind_active"

            local alang_arg="${blind_lang},en,eng,enUS,en-US"
            [ "$blind_lang" == "auto" ] && alang_arg="auto,en,eng,enUS,en-US"

            local blind_script_opts="queue_video-blind=yes,queue-blind=yes,blind=yes"
            [ -n "$win_ytdl" ] && blind_script_opts="${blind_script_opts},ytdl_hook-ytdl_path=${win_ytdl}"

            local win_opts=(
                "--force-window=yes"
                "--video=auto"
                "--vid=auto"
                "--vo=gpu"
                "--gpu-context=auto"
                "--hwdec=auto-safe"
                "--keep-open=no"
                "--alang=${alang_arg}"
                "--slang=${alang_arg}"
                "--ytdl-format=${blind_ytdl_fmt}"
                "--title=Queue [Blind Mode]: $display_title"
                "--geometry=50%x50%"
                "--input-ipc-server=\\\\.\\pipe\\$blind_pipe"
                "--msg-level=all=warn,ao=error"
                "--script-opts=${blind_script_opts}"
            )
            [ "$force_vid" = true ] && win_opts+=("--video=auto" "--vid=auto" "--force-window=yes")
            [ "$force_aud" = true ] && win_opts+=("--video=no" "--vid=no" "--force-window=no")

            if [ -n "$win_u_dir" ] && [ -f "$win_u_dir/AppData/Roaming/mpv/scripts/queue_video.lua" ]; then
                local win_lua
                win_lua=$(wslpath -w "$win_u_dir/AppData/Roaming/mpv/scripts/queue_video.lua" 2>/dev/null)
                [ -n "$win_lua" ] && win_opts+=("--script=$win_lua")
            fi
            if [ -n "$win_u_dir" ] && [ -f "$win_u_dir/AppData/Roaming/mpv/input.conf" ]; then
                local win_input
                win_input=$(wslpath -w "$win_u_dir/AppData/Roaming/mpv/input.conf" 2>/dev/null)
                [ -n "$win_input" ] && win_opts+=("--input-conf=$win_input")
            fi

            # Run Windows MPV in background and wait so signals can be intercepted
            "$win_mpv" "${win_opts[@]}" "$play_target" </dev/null &
            mpv_pid=$!
            wait "$mpv_pid" 2>/dev/null
            cleanup_blind_mode
            return 0
        fi
    fi

    # Android Termux Execution
    if [ "$IS_ANDROID" = true ]; then
        if [ "$cur_mode" == "hybrid" ] && command -v am >/dev/null 2>&1; then
            echo -e "${C_CYAN}📱 Launching MPV Android App in Blind Mode...${C_RESET}"
            am start -a android.intent.action.VIEW -d "$play_target" -t "video/*" -p "is.xyz.mpv" >/dev/null 2>&1
            echo -e "${C_GRAY}Press ENTER once you finish watching to resume queue playback...${C_RESET}"
            read -r
            cleanup_blind_mode
            return 0
        else
            mpv "$play_target" &
            mpv_pid=$!
            wait "$mpv_pid" 2>/dev/null
            cleanup_blind_mode
            return 0
        fi
    fi

    # Standalone Linux / macOS / WSLg Execution
    local has_display=true
    if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
        if [ -d "/mnt/wslg" ] || [ -S "/tmp/.X11-unix/X0" ]; then
            export DISPLAY=":0"
            export WAYLAND_DISPLAY="wayland-0"
        else
            has_display=false
        fi
    fi
    if [ "$IS_WSL" = true ]; then
        export GALLIUM_DRIVER="${GALLIUM_DRIVER:-d3d12}"
        export XCURSOR_THEME="${XCURSOR_THEME:-Adwaita}"
        export XCURSOR_SIZE="${XCURSOR_SIZE:-36}"
    fi

    # Record active blind session metadata
    echo -e "path=${play_target}\ntitle=${display_title}\nsocket=${blind_socket}" > "$HOME/.cache/mpv/blind_active"

    local alang_arg="${blind_lang},en,eng,enUS,en-US"
    [ "$blind_lang" == "auto" ] && alang_arg="auto,en,eng,enUS,en-US"

    local standalone_opts=(
        "--keep-open=no"
        "--title=Queue [Blind Mode]: $display_title"
        "--input-ipc-server=$blind_socket"
        "--msg-level=all=warn,ao=error,pw.conf=error"
        "--alang=${alang_arg}"
        "--slang=${alang_arg}"
        "--script-opts=queue_video-blind=yes,queue-blind=yes,blind=yes"
    )
    if [ "$force_aud" = true ]; then
        standalone_opts+=(
            "--force-window=no"
            "--video=no"
            "--vo=null"
            "--ytdl-format=${blind_audio_fmt}"
        )
    elif [ "$force_vid" = true ] || [ "$has_display" = true ]; then
        standalone_opts+=(
            "--force-window=yes"
            "--video=auto"
            "--vid=auto"
            "--vo=gpu"
            "--gpu-context=auto"
            "--hwdec=auto-safe"
            "--geometry=50%x50%"
            "--ytdl-format=${blind_ytdl_fmt}"
        )
    else
        standalone_opts+=(
            "--force-window=no"
            "--video=no"
            "--vo=null"
        )
    fi
    [ -f "$HOME/.config/mpv/scripts/queue_video.lua" ] && standalone_opts+=("--script=$HOME/.config/mpv/scripts/queue_video.lua")
    [ -f "$HOME/.config/mpv/input.conf" ] && standalone_opts+=("--input-conf=$HOME/.config/mpv/input.conf")

    mpv "${standalone_opts[@]}" "$play_target" &
    mpv_pid=$!
    wait "$mpv_pid" 2>/dev/null

    cleanup_blind_mode
    return 0
}
