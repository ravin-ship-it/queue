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
    local opts=("--js-runtimes" "node" "--extractor-args" "youtube:player_client=android,web" "--dump-json" "--no-warnings" "--skip-download" "--ignore-errors" "--flat-playlist")
    [ -n "$COOKIES_FILE" ] && [ -f "$COOKIES_FILE" ] && opts+=("--cookies" "$COOKIES_FILE")
    local json_dump=$(run_with_timeout 30s yt-dlp "${opts[@]}" -- "$clean_url" 2>/dev/null)
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
        echo -e "${C_PURPLE}├${H_LINE:2}┤${C_RESET}"
        print_boxed_line "${C_TEAL}${view_label:0:10} ${C_WHITE}${views}${C_RESET}"
        print_boxed_line "${C_TEAL}Likes:    ${C_WHITE}${likes}${C_RESET}"
        print_boxed_line "${C_TEAL}Uploaded: ${C_WHITE}${date}${C_RESET}"
        
        if [ "$is_current" == "true" ]; then
            local is_paused=$(echo '{ "command": ["get_property", "pause"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // false')
            if [ "$is_paused" == "true" ]; then
                print_boxed_line "${C_TEAL}Status:   ${C_YELLOW}⏸ Paused${C_RESET} (${queue_display})"
            else
                print_boxed_line "${C_TEAL}Status:   ${C_PURPLE}▶ Playing${C_RESET} (${queue_display})"
            fi
        else
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
            echo -ne "${C_PINK}>>> Press 'd' to download, 'x' to dislike, 'v' for video, or ENTER to return: ${C_RESET}"
            read -r -n 1 user_key < /dev/tty 2>/dev/null || read -r -n 1 user_key
            echo ""
            if [[ "$user_key" =~ ^[dD]$ ]]; then
                cmd_download "$clean_url"
            elif [[ "$user_key" =~ ^[xX]$ ]]; then
                cmd_dislike "$clean_url"
            elif [[ "$user_key" =~ ^[vV]$ ]]; then
                cmd_video_toggle "$index"
            fi
        fi
    fi
    fi
}

wait_for_playback_start() {
    # Wait for playback start (Buffering)
    echo -ne "${C_GRAY}⏳ Buffering...${C_RESET}\r"
    for w in {1..80}; do
        local raw=$(echo -e '{"command":["get_property","playlist-count"]}\n{"command":["get_property","idle-active"]}\n{"command":["get_property","time-pos"]}\n{"command":["get_property","playlist-pos"]}\n{"command":["get_property","pause"]}' | nc $NC_OPTS -w 0.5 "$SOCKET" 2>/dev/null | jq -s -j -r 'map(select(.event == null)) | (.[0].data // 0), "\t", (.[1].data // "false"), "\t", (.[2].data // ""), "\t", (if .[3].data == null then -1 else .[3].data end), "\t", (.[4].data // "false")')
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
        local raw_mpv_dur=$(echo '{"command":["get_property","duration"]}' | nc $NC_OPTS -w 0.5 "$SOCKET" 2>/dev/null | jq -r '.data // empty')
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
    
    echo -e "${C_WHITE}[${C_ORANGE}${idx}${C_WHITE}] ${C_CYAN}${display_title}${C_RESET}${artist_part}${dur_part}"
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
        local raw=$(echo -e '{"command":["get_property","playlist-count"]}\n{"command":["get_property","playlist-pos"]}\n{"command":["get_property","media-title"]}\n{"command":["get_property","playlist"]}\n{"command":["get_property","idle-active"]}\n{"command":["get_property","pause"]}\n{"command":["get_property","metadata"]}\n{"command":["get_property","duration"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -j -r '
            map(select(.event == null)) |
            (.[0].data // 0), "\t",
            (if .[1].data == null then -1 else .[1].data end), "\t",
            (.[2].data // ""), "\t",
            (if .[1].data != null and .[3].data != null then .[3].data[.[1].data].filename else "" end), "\t",
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
    
    if [ "$playing" == "true" ]; then
        local is_paused=$(echo '{ "command": ["get_property", "pause"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // false')
        if [ "$is_paused" == "true" ]; then
            print_boxed_line "${C_TEAL}Status:      ${C_YELLOW}⏸ Paused${C_RESET}"
        else
            print_boxed_line "${C_TEAL}Status:      ${C_PURPLE}▶ Playing${C_RESET}"
        fi
    else
        print_boxed_line "${C_TEAL}Status:      ${C_GRAY}Queued${C_RESET}"
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
    fi
    printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
    B_LINE=${B_LINE// /─}
    echo -e "${C_GRAY}${B_LINE}${C_RESET}"
}

cmd_next() {
    if [ "$MPV_RUNNING" = false ]; then echo -e "${C_PINK}😴💤 MPV isn't running... it must be taking a nap${C_RESET}"; return; fi
    echo '{ "command": ["playlist-next"] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null

    # Proactive auto-queue check after moving next
    ( auto_queue_related ) >/dev/null 2>&1 & disown

    wait_for_playback_start
    log_now_playing
}

cmd_prev() {
    if [ "$MPV_RUNNING" = false ]; then echo -e "${C_PINK}😴💤 MPV isn't running... it must be taking a nap${C_RESET}"; return; fi
    echo '{ "command": ["playlist-prev"] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null

    # Proactive auto-queue check after moving back (maybe we are now at the end?)
    ( auto_queue_related ) >/dev/null 2>&1 & disown

    wait_for_playback_start
    log_now_playing
}
cmd_stop() {
    # Force save state before quitting
    save_current_playlist true
    
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
    if [ -f "$HOME/.cache/mpv/video_window.pid" ]; then
        local v_pid=$(cat "$HOME/.cache/mpv/video_window.pid" 2>/dev/null)
        [ -n "$v_pid" ] && kill "$v_pid" >/dev/null 2>&1
        rm -f "$HOME/.cache/mpv/video_window.pid" "$HOME/.cache/mpv/video_window.sock"
    fi

    # 4. Cleanup any remaining mpv instances
    pkill -u "$(whoami)" -f "mpv --idle" >/dev/null 2>&1
    
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

    local raw
    raw=$(echo -e '{"command":["get_property","vo"]}\n{"command":["get_property","vid"]}' | nc ${NC_OPTS:--U} -w 1 "$SOCKET" 2>/dev/null)
    [ -z "$raw" ] && return 1

    local vo_name vid_val
    vo_name=$(echo "$raw" | jq -s -r 'map(select(.event == null)) | .[0].data[0].name // "null"' 2>/dev/null)
    vid_val=$(echo "$raw" | jq -s -r 'map(select(.event == null)) | .[1].data // false' 2>/dev/null)

    if [ "$vo_name" != "null" ] && [ -n "$vo_name" ] && [ "$vid_val" != "false" ] && [ "$vid_val" != "no" ]; then
        return 0
    fi
    return 1
}

cmd_video_toggle() {
    local target_idx="$1"

    # --- TOGGLE OFF: If video window is currently open and no target specified ---
    if is_video_window_open && [ -z "$target_idx" ]; then
        echo -e "${C_CYAN}📺 Hiding desktop video window...${C_RESET}"
        echo -e '{"command":["set_property","vid","no"]}\n{"command":["set_property","vo","null"]}\n{"command":["set_property","force-window","no"]}' | nc ${NC_OPTS:--U} -w 1 "$SOCKET" >/dev/null 2>&1
        echo -e "🎧 ${C_PINK}Returned to background audio mode (video hidden)${C_RESET}"
        return 0
    fi

    # Ensure display environment (WSLg handles DISPLAY=:0 / WAYLAND_DISPLAY=wayland-0 natively)
    if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
        if [ -d "/mnt/wslg" ] || [ -S "/tmp/.X11-unix/X0" ]; then
            export DISPLAY=":0"
            export WAYLAND_DISPLAY="wayland-0"
        else
            echo -e "${C_PINK}🚫 No graphical display found. Desktop video requires an active display (X11 / Wayland / WSLg).${C_RESET}"
            return 1
        fi
    fi

    # Enable host GPU acceleration via Microsoft D3D12 in WSL2
    export GALLIUM_DRIVER="${GALLIUM_DRIVER:-d3d12}"
    if [ -d "/usr/lib/wsl/lib" ] && [[ ":$LD_LIBRARY_PATH:" != *":/usr/lib/wsl/lib:"* ]]; then
        export LD_LIBRARY_PATH="/usr/lib/wsl/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi

    # Fix tiny cursor on Windows 11 high-DPI displays in WSLg
    export XCURSOR_THEME="${XCURSOR_THEME:-Adwaita}"
    export XCURSOR_SIZE="${XCURSOR_SIZE:-36}"
    if [ -n "$DISPLAY" ] && command -v xrdb >/dev/null 2>&1; then
        if [ -f "$HOME/.Xresources" ]; then
            xrdb -merge "$HOME/.Xresources" 2>/dev/null
        else
            echo -e "Xcursor.theme: $XCURSOR_THEME\nXcursor.size: $XCURSOR_SIZE" | xrdb -merge 2>/dev/null
        fi
    fi

    ensure_mpv_running

    if [ "$MPV_RUNNING" = false ] || [ ! -S "$SOCKET" ]; then
        echo -e "${C_PINK}🔇 MPV player is not active.${C_RESET}"
        return 1
    fi

    # Determine VO & GPU context:
    # Direct Wayland EGL with D3D12 GPU hardware acceleration provides tear-free 60fps/144Hz fluidity.
    # Fallback cleanly to X11 if no Wayland compositor is running.
    local vo_opt="gpu"
    local gpu_ctx="wayland,auto"
    if [ -z "$WAYLAND_DISPLAY" ]; then
        gpu_ctx="x11egl,x11vk,auto"
        vo_opt="gpu,x11"
    fi

    # Ensure MPV input configuration & keybindings are active
    if [ -f "$HOME/.config/mpv/input.conf" ]; then
        echo "{\"command\":[\"load-input-conf\",\"$HOME/.config/mpv/input.conf\"]}" | nc ${NC_OPTS:--U} -w 1 "$SOCKET" >/dev/null 2>&1
    fi
    echo '{"command":["keybind","F11","cycle fullscreen"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","f","cycle fullscreen"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","CLOSE_WIN","set vid no ; set vo null ; set force-window no"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","q","set vid no ; set vo null ; set force-window no"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","Ctrl+s","cycle shuffle"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","r","playlist-shuffle"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1

    # In-Window Scaling & Sizing Hotkeys
    echo '{"command":["keybind","w","cycle_values window-scale 0.35 0.5 0.75 1.0 ; show-text \"Window Scale: ${window-scale}\" 1500"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","W","cycle_values window-scale 1.0 0.75 0.5 0.35 ; show-text \"Window Scale: ${window-scale}\" 1500"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","+","add window-scale 0.05 ; show-text \"Window Scale: ${window-scale}\" 1500"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","=","add window-scale 0.05 ; show-text \"Window Scale: ${window-scale}\" 1500"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","-","add window-scale -0.05 ; show-text \"Window Scale: ${window-scale}\" 1500"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","_","add window-scale -0.05 ; show-text \"Window Scale: ${window-scale}\" 1500"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","Ctrl+WHEEL_UP","add window-scale 0.05 ; show-text \"Window Scale: ${window-scale}\" 1500"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","Ctrl+WHEEL_DOWN","add window-scale -0.05 ; show-text \"Window Scale: ${window-scale}\" 1500"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1

    echo '{"command":["keybind","1","set ytdl-format \"bestvideo[height<=720][fps>=50][format_note!*=Premium]+bestaudio/bestvideo[height<=720][format_note!*=Premium]+bestaudio/best[height<=720]\" ; playlist-play-index current ; show-text \"Quality: 720p HD (60fps)\" 2500"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","2","set ytdl-format \"bestvideo[height<=1080][fps>=50][format_note!*=Premium]+bestaudio/bestvideo[height<=1080][format_note!*=Premium]+bestaudio/best\" ; playlist-play-index current ; show-text \"Quality: 1080p Full HD (60fps)\" 2500"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","3","set ytdl-format \"bestvideo[height<=1440][fps>=50][format_note!*=Premium]+bestaudio/bestvideo[height<=1440][format_note!*=Premium]+bestaudio/best\" ; playlist-play-index current ; show-text \"Quality: 1440p 2K QHD (60fps)\" 2500"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo '{"command":["keybind","4","set ytdl-format \"bestvideo[format_note!*=Premium]+bestaudio/best\" ; playlist-play-index current ; show-text \"Quality: Max / 4K UHD\" 2500"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1

    local target_autofit="50%x50%"
    local target_scale="0.5"
    local target_fs="false"

    # If target index, size preset, or URL is passed
    if [ -n "$target_idx" ]; then
        if [[ "$target_idx" =~ ^http.* ]]; then
            # Direct URL passed: queue and play it
            echo "{\"command\":[\"loadfile\",\"$target_idx\",\"replace\"]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
        elif [[ "$target_idx" =~ ^[0-9]+$ ]]; then
            # Specific track index requested
            local pl_count
            pl_count=$(echo '{"command":["get_property","playlist-count"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // 0')
            if [ "$target_idx" -lt 1 ] || [ "$target_idx" -gt "$pl_count" ]; then
                echo -e "${C_PINK}🚫 Track [${C_ORANGE}${target_idx}${C_PINK}] does not exist. Max tracks: ${C_WHITE}[${C_ORANGE}${pl_count}${C_WHITE}]${C_RESET}"
                return 1
            fi
            echo "{\"command\":[\"set_property\",\"playlist-pos\",$((target_idx - 1))]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
        elif [[ "$target_idx" =~ ^(small|sm|35|med|medium|50|large|lg|75|full|fs|100)$ ]]; then
            case "$target_idx" in
                small|sm|35) target_autofit="35%x35%"; target_scale="0.35" ;;
                med|medium|50) target_autofit="50%x50%"; target_scale="0.50" ;;
                large|lg|75) target_autofit="75%x75%"; target_scale="0.75" ;;
                full|fs|100) target_fs="true" ;;
            esac
        fi
    fi

    # Smart video format: 60 FPS prioritized, crisp Full HD / 2K, never blurry, never locked behind Premium
    local smart_fmt="bestvideo[height<=1440][fps>=50][format_note!*=Premium]+bestaudio/bestvideo[height<=1080][fps>=50][format_note!*=Premium]+bestaudio/bestvideo[height<=1440][format_note!*=Premium]+bestaudio/bestvideo[height<=1080][format_note!*=Premium]+bestaudio/bestvideo[fps>=50][format_note!*=Premium]+bestaudio/bestvideo[format_note!*=Premium]+bestaudio/best"
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
    # 9. swapchain-depth=3 -> Triple buffering absorbs presentation latency variance in Wayland/WSLg
    # 10. video-sync=audio -> Locks to audio clock, avoiding WSLg RDP virtual VSync miscalculations
    # 11. gpu-context=$gpu_ctx & vo=$vo_opt -> Native Wayland EGL with Direct3D 12 acceleration
    # 12. video=auto & vid=auto -> Demux & render video stream
    # 13. force-window=yes -> Keep window persistent across playlist transitions
    # 14. pause=false -> Resume/continue playback
    echo -e "{\"command\":[\"set_property\",\"autofit\",\"$target_autofit\"]}\n{\"command\":[\"set_property\",\"window-scale\",$target_scale]}\n{\"command\":[\"set_property\",\"geometry\",\"50%:50%\"]}\n{\"command\":[\"set_property\",\"auto-window-resize\",false]}\n{\"command\":[\"set_property\",\"keepaspect-window\",false]}\n{\"command\":[\"apply-profile\",\"fast\"]}\n{\"command\":[\"set_property\",\"hwdec\",\"auto-safe\"]}\n{\"command\":[\"set_property\",\"opengl-pbo\",true]}\n{\"command\":[\"set_property\",\"swapchain-depth\",3]}\n{\"command\":[\"set_property\",\"video-sync\",\"audio\"]}\n{\"command\":[\"set_property\",\"gpu-context\",\"$gpu_ctx\"]}\n{\"command\":[\"set_property\",\"vo\",\"$vo_opt\"]}\n{\"command\":[\"set_property\",\"video\",\"auto\"]}\n{\"command\":[\"set_property\",\"vid\",\"auto\"]}\n{\"command\":[\"set_property\",\"fullscreen\",$target_fs]}\n{\"command\":[\"set_property\",\"force-window\",\"yes\"]}\n{\"command\":[\"set_property\",\"pause\",false]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1

    # Fetch track title and format notification
    local title
    title=$(echo '{"command":["get_property","media-title"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // "Queue Video"')
    echo -e "📺 ${C_PINK}Desktop Video Window Active:${C_RESET} ${C_CYAN}${title}${C_RESET}"
    echo -e "${C_GRAY}💡 Resizable window. Press ${C_WHITE}w${C_GRAY} (cycle small/med/large), ${C_WHITE}+${C_GRAY}/${C_WHITE}-${C_GRAY} scale, ${C_WHITE}F11${C_GRAY} fullscreen, ${C_WHITE}1${C_GRAY}-${C_WHITE}4${C_GRAY} quality, ${C_WHITE}q${C_GRAY} return to audio.${C_RESET}"
}

cmd_resolution() {
    local target="$1"
    target=$(echo "$target" | tr '[:upper:]' '[:lower:]')

    ensure_mpv_running
    if [ "$MPV_RUNNING" = false ] || [ ! -S "$SOCKET" ]; then
        echo -e "${C_PINK}🔇 MPV player is not active.${C_RESET}"
        return 1
    fi

    local ytdl_fmt=""
    local label=""

    case "$target" in
        720|720p|hd)
            ytdl_fmt="bestvideo[height<=720][fps>=50][format_note!*=Premium]+bestaudio/bestvideo[height<=720][format_note!*=Premium]+bestaudio/best[height<=720]"
            label="720p HD (60 FPS fluid / bandwidth saver)"
            ;;
        1080|1080p|fhd)
            ytdl_fmt="bestvideo[height<=1080][fps>=50][format_note!*=Premium]+bestaudio/bestvideo[height<=1080][format_note!*=Premium]+bestaudio/best"
            label="1080p Full HD (60 FPS crisp)"
            ;;
        1440|1440p|2k|qhd)
            ytdl_fmt="bestvideo[height<=1440][fps>=50][format_note!*=Premium]+bestaudio/bestvideo[height<=1440][format_note!*=Premium]+bestaudio/best"
            label="1440p 2K QHD (60 FPS ultra-crisp)"
            ;;
        2160|2160p|4k|uhd|max)
            ytdl_fmt="bestvideo[format_note!*=Premium]+bestaudio/best"
            label="Max / 4K UHD (Uncapped highest quality)"
            ;;
        auto|smart|"")
            if [ -z "$target" ]; then
                local cur_w cur_h cur_fps cur_codec
                local res_info
                res_info=$(echo -e '{"command":["get_property","video-params"]}\n{"command":["get_property","track-list"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)
                cur_w=$(echo "$res_info" | jq -s -r 'map(select(.event == null)) | .[0].data.w // "N/A"' 2>/dev/null)
                cur_h=$(echo "$res_info" | jq -s -r 'map(select(.event == null)) | .[0].data.h // "N/A"' 2>/dev/null)
                cur_fps=$(echo "$res_info" | jq -s -r 'map(select(.event == null)) | (.[1].data[]? | select(.type=="video" and .selected==true) | .["demux-fps"]) // "N/A"' 2>/dev/null)
                cur_codec=$(echo "$res_info" | jq -s -r 'map(select(.event == null)) | (.[1].data[]? | select(.type=="video" and .selected==true) | .codec) // "N/A"' 2>/dev/null)
                [[ "$cur_fps" =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf -v cur_fps "%.0f" "$cur_fps"

                if [ "$cur_w" == "N/A" ] || [ -z "$cur_w" ]; then
                    local current_fmt
                    current_fmt=$(echo '{"command":["get_property","ytdl-format"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // "Default"')
                    echo -e "${C_CYAN}📺 Video Stream:${C_RESET} ${C_GRAY}Idle (No video actively rendering)${C_RESET}"
                    echo -e "   ${C_PINK}Active Quality Profile:${C_RESET} ${C_WHITE}${current_fmt:0:60}...${C_RESET}"
                else
                    echo -e "${C_CYAN}📺 Active Video Quality:${C_RESET} ${C_WHITE}${cur_w}x${cur_h}${C_RESET} @ ${C_PINK}${cur_fps} FPS${C_RESET} (${C_GRAY}codec: ${cur_codec}${C_RESET})"
                fi
                echo -e "${C_GRAY}💡 Quick Switch: 'q -res 720' | 'q -res 1080' | 'q -res 1440' | 'q -res 4k' | 'q -res auto'${C_RESET}"
                echo -e "${C_GRAY}   Or inside video window press keys: ${C_WHITE}1${C_GRAY} (720p) | ${C_WHITE}2${C_GRAY} (1080p60) | ${C_WHITE}3${C_GRAY} (2K) | ${C_WHITE}4${C_GRAY} (4K)${C_RESET}"
                return 0
            fi
            ytdl_fmt="bestvideo[height<=1440][fps>=50][format_note!*=Premium]+bestaudio/bestvideo[height<=1080][fps>=50][format_note!*=Premium]+bestaudio/bestvideo[height<=1440][format_note!*=Premium]+bestaudio/bestvideo[height<=1080][format_note!*=Premium]+bestaudio/bestvideo[fps>=50][format_note!*=Premium]+bestaudio/bestvideo[format_note!*=Premium]+bestaudio/best"
            label="Auto / Smart 60FPS (Adapts to internet, max 1440p60, never blurry)"
            ;;
        *)
            echo -e "${C_PINK}❓ Unknown resolution: '$target'. Use: 720, 1080, 1440, 4k, or auto.${C_RESET}"
            return 1
            ;;
    esac

    # Apply ytdl-format to MPV
    echo "{\"command\":[\"set_property\",\"ytdl-format\",\"$ytdl_fmt\"]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1

    # Reload current track to apply new stream format while keeping position
    echo '{"command":["playlist-play-index","current"]}' | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1
    echo "{\"command\":[\"show-text\",\"Quality: $label\",2500]}" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1

    echo -e "${C_CYAN}📺 Video Quality set to:${C_RESET} ${C_PINK}${label}${C_RESET}"
    echo -e "${C_GRAY}   Reloaded stream with high-framerate matching.${C_RESET}"
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
        
        # Stabilization: Wait for playlist to populate (max 3s)
        for i in {1..15}; do
             local cnt=$(echo '{"command":["get_property","playlist-count"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0' 2>/dev/null)
             if [[ "$cnt" =~ ^[0-9]+$ ]] && [ "$cnt" -gt 0 ]; then break; fi
             sleep 0.2
        done

        # Restore saved properties (shuffle, loop, pos)
        restore_state_properties
        
        # Determine start index (Saved position or first)
        local start_idx=$(jq -r '.pos // 0' "$HOME/.cache/mpv/state.json" 2>/dev/null)
        [[ ! "$start_idx" =~ ^[0-9]+$ ]] && start_idx=0

        # Force Playback Start
        echo "{ \"command\": [\"playlist-play-index\", $start_idx] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
        echo '{ "command": ["set_property", "pause", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1

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
            echo '{ "command": ["set_property", "pause", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
            wait_for_playback_start
            log_now_playing "|> Restored & Playing: "
        else
            # Single atomic IPC query to get pause, idle-active, eof-reached, playlist-pos, playlist-count
            local state_raw=$(echo -e '{"command":["get_property","pause"]}\n{"command":["get_property","idle-active"]}\n{"command":["get_property","eof-reached"]}\n{"command":["get_property","playlist-pos"]}\n{"command":["get_property","playlist-count"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -j -r 'map(select(.event == null)) | (.[0].data // false), "\t", (.[1].data // false), "\t", (.[2].data // false), "\t", (if .[3].data == null then -1 else .[3].data end), "\t", (.[4].data // 0)')
            IFS=$'\t' read -r cur_pause is_idle is_eof cur_pos cur_count <<< "$state_raw"

            if [[ ! "$cur_count" =~ ^[0-9]+$ ]] || [ "$cur_count" -le 0 ]; then
                if [ -f "$LAST_PLAYLIST_FILE" ] && [ -s "$LAST_PLAYLIST_FILE" ]; then
                    echo -e "${C_PINK}🚀 Loading saved playlist into MPV...${C_RESET}"
                    echo "{\"command\": [\"loadlist\", \"$LAST_PLAYLIST_FILE\", \"replace\"]}" | nc $NC_OPTS -w 2 "$SOCKET" > /dev/null 2>&1
                    sleep 0.3
                    restore_state_properties
                    local start_idx=$(jq -r '.pos // 0' "$HOME/.cache/mpv/state.json" 2>/dev/null)
                    [[ ! "$start_idx" =~ ^[0-9]+$ ]] && start_idx=0
                    echo "{\"command\": [\"playlist-play-index\", $start_idx]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                    echo '{ "command": ["set_property", "pause", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                    wait_for_playback_start
                    log_now_playing "|> Restored & Playing: "
                    return
                fi
                echo -e "${C_ORANGE}⚠️ Queue is empty.${C_RESET}"
                return
            fi

            if [ "$is_eof" == "true" ] || [ "$is_idle" == "true" ] || [ "$cur_pos" -lt 0 ]; then
                # Replay current track or start if at EOF / idle
                local start_idx=0
                [ "$cur_pos" -ge 0 ] 2>/dev/null && start_idx="$cur_pos"
                echo "{\"command\": [\"playlist-play-index\", $start_idx]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                echo '{ "command": ["seek", 0, "absolute"] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                echo '{ "command": ["set_property", "pause", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                wait_for_playback_start
                log_now_playing "|> Playing: "
            elif [ "$cur_pause" == "true" ]; then
                # Unpause
                echo '{ "command": ["set_property", "pause", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                
                # Check if stream timed out during long pause (e.g. 50 mins idle/EOF)
                sleep 0.2
                local check_idle=$(echo '{"command":["get_property","idle-active"]}' | nc $NC_OPTS -w 0.5 "$SOCKET" 2>/dev/null | jq -r '.data // false')
                if [ "$check_idle" == "true" ] && [ "$cur_pos" -ge 0 ] 2>/dev/null; then
                    # Stream connection dropped/expired! Force reload current track index with fresh token
                    echo "{\"command\":[\"playlist-play-index\",$cur_pos]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                    echo '{ "command": ["seek", 0, "absolute"] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                    echo '{ "command": ["set_property", "pause", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
                fi
                wait_for_playback_start
                log_now_playing "|> Playing: "
            else
                # Pause
                echo '{ "command": ["set_property", "pause", true] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
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
    local count=$(echo '{"command":["get_property","playlist-count"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0' 2>/dev/null)
    if [[ ! "$count" =~ ^[0-9]+$ ]] || [ "$index" -lt 1 ] || [ "$index" -gt "$count" ]; then
        [[ ! "$count" =~ ^[0-9]+$ ]] && count="0"
        # Use local ESC-safe colors for the log
        local E=$(printf "\033")
        local O="${E}[38;5;215m"; local W="${E}[1;37m"; local P="${E}[38;5;198m"; local R="${E}[0m"
        echo -e "${P}🚫 Track ${W}[${O}${index}${W}] ${P}does not exist. Max Track ${W}[${O}${count}${W}]${R}"
        return
    fi

    # Set pos AND force unpause and reset seek to 0 (Separate commands for maximum compatibility)
    echo "{\"command\":[\"playlist-play-index\",$((index - 1))]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
    echo "{\"command\":[\"seek\",0,\"absolute\"]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
    echo "{\"command\":[\"set_property\",\"pause\",false]}" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
    
    wait_for_playback_start
    log_now_playing "|> Playing: "

}
