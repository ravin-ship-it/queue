show_queue() {
    # Wait for socket to be responsive (up to 2 seconds)
    if [ "$MPV_RUNNING" = false ]; then
        for i in {1..10}; do
            if [ -S "$SOCKET" ] && echo '{ "command": ["get_property", "playlist-count"] }' | nc $NC_OPTS -w 1 "$SOCKET" &>/dev/null; then
                MPV_RUNNING=true
                break
            fi
            sleep 0.2
        done
    fi

    if [ "$MPV_RUNNING" = false ]; then
        if [ -t 1 ] && [ "$IN_FZF" != "true" ]; then
            print_header_box "😴💤 MPV isn't running... it must be taking a nap"
        else
            echo "😴💤 MPV isn't running"
        fi
        return 0
    fi

    # Only show the outer box if output is a direct terminal, not FZF and not raw
    if [ -t 1 ] && [ "$IN_FZF" != "true" ]; then
        print_header_box "${C_CYAN}🎵 Current Queue${C_RESET}"
    fi

    # Load cache into memory ONCE at the start
    load_cache_to_memory

    local mpv_raw=$(echo -e '{"command":["get_property","playlist"]}\n{"command":["get_property","pause"]}\n{"command":["get_property","idle-active"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)
    local is_paused=$(echo "$mpv_raw" | jq -s -r 'map(select(.event == null)) | .[1].data // false')
    local is_idle=$(echo "$mpv_raw" | jq -s -r 'map(select(.event == null)) | .[2].data // false')
    local NEEDS_FETCH=false

    # Pre-fetch uploader/duration if possible (optional enhancement)
    echo "$mpv_raw" | jq -s -r 'map(select(.event == null)) | .[0].data | select(type == "array") | to_entries | .[] | 
        "\(.key + 1)\t\(if .value.current then "current" else "other" end)\t\(.value.filename)\t\((.value.title // "") | sub("^https?://[^\\t ]+[\\t ]+"; ""))"' 2>/dev/null | while IFS=$'\t' read -r i state filename mpv_title; do
        
        # 1. Clean Filename (Only for remote URLs)
        CLEAN_FILENAME="$filename"
        if [[ "$filename" =~ ^http ]]; then
            CLEAN_FILENAME="${filename%%\\t*}"
            CLEAN_FILENAME="${CLEAN_FILENAME%%[[:space:]]*}"
        fi

        # 2. Extract Embedded Title (if any - Only for remote URLs)
        EMBEDDED_TITLE=""
        if [[ "$filename" =~ ^http ]]; then
            if [[ "$filename" == *"\\t"* ]]; then
                 EMBEDDED_TITLE="${filename#*\\t}"
            elif [[ "$filename" =~ [[:space:]] ]]; then
                 local suffix="${filename#*[[:space:]]}"
                 if [ "$suffix" != "$filename" ] && [ -n "$suffix" ]; then
                     EMBEDDED_TITLE="$suffix"
                 fi
            fi
        fi

        # 3. Determine Display Title
        DISPLAY_TITLE=""
        if [ -n "$mpv_title" ] && [[ ! "$mpv_title" =~ ^http ]]; then
             DISPLAY_TITLE="$mpv_title"
        elif [ -n "$EMBEDDED_TITLE" ]; then
             DISPLAY_TITLE="$EMBEDDED_TITLE"
        fi

        # 4. Meta Information (Artist/Duration) - Try to find in cache
        local meta_artist=""
        local meta_duration=""
        local cached_row="${CACHE_MEM[$CLEAN_FILENAME]}"
        if [[ "$CLEAN_FILENAME" =~ ^http.* ]] || [[ "$CLEAN_FILENAME" == watch\?v=* ]]; then
            # Fuzzy match by ID if direct lookup fails (for stream URLs)
            if [ -z "$cached_row" ]; then
                local vid_id=""
                local id_regex="[?&]id=([a-zA-Z0-9_-]{11})"
                local pb_regex="videoplayback/id/([a-zA-Z0-9_-]{11})"
                
                if [[ "$CLEAN_FILENAME" =~ v=([a-zA-Z0-9_-]{11}) ]]; then 
                    vid_id="${BASH_REMATCH[1]}"
                elif [[ "$CLEAN_FILENAME" =~ watch\?v=([a-zA-Z0-9_-]{11}) ]]; then
                    vid_id="${BASH_REMATCH[1]}"
                elif [[ "$CLEAN_FILENAME" =~ $id_regex ]]; then
                    vid_id="${BASH_REMATCH[1]}"
                elif [[ "$CLEAN_FILENAME" =~ $pb_regex ]]; then
                    vid_id="${BASH_REMATCH[1]}"
                fi
                
                if [ -n "$vid_id" ] && [ "${#vid_id}" -eq 11 ]; then
                    for key in "${!CACHE_MEM[@]}"; do
                        if [[ "$key" == *"$vid_id"* ]]; then
                            cached_row="${CACHE_MEM[$key]}"
                            break
                        fi
                    done
                fi
            fi

            if [ -n "$cached_row" ]; then
                # Split the cached row (Title \t Artist \t Duration)
                meta_artist=$(echo -e "$cached_row" | awk -F'\t' '{print $2}')
                meta_duration=$(echo -e "$cached_row" | awk -F'\t' '{print $3}')
                
                # Check if literal "\t" is polluting the title (cache corruption from previous printf bug)
                # If title contains "\t", we need to split by literal "\t" instead of real tab
                local raw_title=$(echo "$cached_row" | awk -F'\t' '{print $1}')
                if [[ "$raw_title" == *"\\t"* ]]; then
                     meta_artist="${raw_title#*\\t}"
                     # Artist might have duration after it
                     local possible_dur="${meta_artist#*\\t}"
                     meta_artist="${meta_artist%%\\t*}"
                     meta_duration="$possible_dur"
                     # Sanity check: if duration looks like duration
                     if [[ ! "$meta_duration" =~ [0-9]+:[0-9]+ ]]; then meta_duration=""; fi
                fi

                # If we have a row but it lacks artist info (old format), mark for upgrade
                if [ -z "$meta_artist" ]; then
                     NEEDS_FETCH=true
                fi
            else
                NEEDS_FETCH=true
            fi
        elif [ -n "$cached_row" ]; then
            meta_artist=$(echo -e "$cached_row" | awk -F'\t' '{print $2}')
            meta_duration=$(echo -e "$cached_row" | awk -F'\t' '{print $3}')
        fi

        TITLE_SUFFIX=""
        
        # 5. Fallback / Cache Lookup
        if [ -z "$DISPLAY_TITLE" ] || [ "$DISPLAY_TITLE" == "$CLEAN_FILENAME" ] || [[ "$DISPLAY_TITLE" =~ ^http.* ]]; then
            if [[ "$CLEAN_FILENAME" =~ ^http.* ]]; then
                # Use the row we already fetched if possible
                local cached_title=$(echo "$cached_row" | cut -f1)
                if [ -n "$cached_title" ]; then
                    DISPLAY_TITLE="$cached_title"
                else
                    DISPLAY_TITLE="Loading Metadata..."
                    TITLE_SUFFIX=" ${C_GRAY}(Please wait)${C_RESET}"
                    NEEDS_FETCH=true
                fi
            else
                DISPLAY_TITLE=$(basename -- "$CLEAN_FILENAME")
            fi
        fi

        # FINAL CLEANUP: Ensure DISPLAY_TITLE is stripped of any embedded metadata (literal \t or real tabs)
        DISPLAY_TITLE="${DISPLAY_TITLE%%\\t*}"
        DISPLAY_TITLE="${DISPLAY_TITLE%%$'\t'*}"
        
        # 6. Formatting (Match search result style: Title by Artist [Duration])
        local artist_part=""
        local dur_part=""
        
        [ -n "$meta_artist" ] && [ "$meta_artist" != "null" ] && [ "$meta_artist" != "$CLEAN_FILENAME" ] && artist_part=" ${C_GRAY}by${C_RESET} ${C_LIGHT_PINK}$meta_artist${C_RESET}"
        [ -n "$meta_duration" ] && [ "$meta_duration" != "null" ] && [ "$meta_duration" != "0:00" ] && dur_part=" ${C_ORANGE}[$meta_duration]${C_RESET}"
        
        # Player Indicator (|>/||) and Active Track Highlighting
        local ind="   "
        local title_color="${C_CYAN}"
        local fzf_title_prefix=""
        local fzf_title_suffix=""
        if [ "$state" == "current" ] && [ "$is_idle" != "true" ]; then
            if [ "$is_paused" == "true" ]; then
                ind="${C_PINK}||${C_RESET} "
            else
                ind="${C_PINK}|>${C_RESET} "
            fi
            title_color="${C_PINK}"
            fzf_title_prefix="${C_PINK}"
            fzf_title_suffix="${C_RESET}"
        fi

        if [ -t 1 ] && [ "$IN_FZF" != "true" ]; then
            # Truncate title to fit terminal while keeping artist/duration
            local index_w=${#i}
            local meta_w=$(get_visual_width "$(strip_colors "$artist_part$dur_part")")
            # INNER_WIDTH is (TERM_WIDTH - 6) for borders and padding
            local title_max_w=$((TERM_WIDTH - index_w - meta_w - 13))
            [ "$title_max_w" -lt 15 ] && title_max_w=15
            
            local final_title=$(truncate_text "$DISPLAY_TITLE" "$title_max_w")
            printf -v LINE_CONTENT "%s%s. %s%s%s%s%s" "$ind" "${C_ORANGE}$i${C_RESET}" "$title_color" "$final_title" "${C_RESET}" "$artist_part" "$dur_part"
            print_boxed_line "$LINE_CONTENT"
        else
            # Simple format for FZF or Raw output
            printf "%s%s. %s%s%s%s%s\n" "$ind" "${C_ORANGE}$i${C_RESET}" "$fzf_title_prefix" "$DISPLAY_TITLE" "$fzf_title_suffix" "$artist_part" "$dur_part"
        fi
        
        # Pass NEEDS_FETCH status out of the loop via a temp file or similar if needed, 
        # but since we are piping, variables are lost. 
        # However, we can just trigger the fetcher blindly at the end; the lock protects it.
    done

    # Trigger background fetcher (safe, single instance)
    if [ "$IS_RAW" != "true" ]; then
        fetch_missing_background >/dev/null 2>&1 & disown
        save_current_playlist true >/dev/null 2>&1 & disown
    fi

    if [ -t 1 ] && [ "$IN_FZF" != "true" ]; then
        printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
        B_LINE=${B_LINE// /─}
        echo -e "${C_GRAY}${B_LINE}${C_RESET}"
    fi
}

cmd_dislike() {
    local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)

    if [ "$#" -eq 0 ] || [ -z "$1" ]; then
        # Default: current playing track
        local item_json=$(echo "$track_info" | jq -s -c 'map(select(.event == null)) | .[0].data[] | select(.current) // empty' 2>/dev/null)
        local filename=$(echo "$item_json" | jq -r '.filename // ""')
        local title=$(echo "$item_json" | jq -r '.title // ""')
        if [ -z "$filename" ]; then
            echo -e "${C_PINK}🔇 No track currently playing to dislike.${C_RESET}"
            return 1
        fi
        add_to_auto_blacklist "$filename" "$title"
        echo -e "${C_PINK}👎 Disliked & Blacklisted from Auto Mode:${C_RESET} ${C_CYAN}${title:-$filename}${C_RESET}"
        return 0
    fi

    for target in "$@"; do
        [ -z "$target" ] && continue
        local filename=""
        local title=""
        if [[ "$target" =~ ^[0-9]+$ ]]; then
            local idx=$((target - 1))
            local item_json=$(echo "$track_info" | jq -s -c "map(select(.event == null)) | .[0].data[$idx] // empty" 2>/dev/null)
            filename=$(echo "$item_json" | jq -r '.filename // ""')
            title=$(echo "$item_json" | jq -r '.title // ""')
        elif [[ "$target" =~ ^http ]]; then
            filename="$target"
            title="$target"
        else
            # Search by text in playlist
            local item_json=$(echo "$track_info" | jq -s -c --arg query "$target" '
                map(select(.event == null)) |
                .[0].data[] | 
                select(((.title? // "") | test($query; "i")) or ((.filename? // "") | test($query; "i")))
            ' 2>/dev/null | head -n 1)
            filename=$(echo "$item_json" | jq -r '.filename // ""')
            title=$(echo "$item_json" | jq -r '.title // ""')
        fi

        if [ -n "$filename" ]; then
            add_to_auto_blacklist "$filename" "$title"
            echo -e "${C_PINK}👎 Disliked & Blacklisted from Auto Mode:${C_RESET} ${C_CYAN}${title:-$filename}${C_RESET}"
        else
            echo -e "${C_PINK}🔍🤷 No track matching [${C_ORANGE}${target}${C_PINK}] found to dislike.${C_RESET}"
        fi
    done
}

cmd_remove() {
    local also_dislike=false
    if [ "$1" == "--dislike" ]; then
        also_dislike=true
        shift
    fi

    local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET")
    declare -a INDICES_TO_REMOVE

    if [ "$#" -eq 0 ] || [ -z "$1" ]; then
        # Default: Remove currently playing track
        local current_idx=$(echo "$track_info" | jq -s -r 'map(select(.event == null)) | .[0].data | to_entries[] | select(.value.current) | .key + 1' 2>/dev/null)
        if [ -n "$current_idx" ] && [ "$current_idx" != "null" ]; then
            INDICES_TO_REMOVE+=("$current_idx")
        else
            echo -e "${C_PINK}🔇 Nothing is currently playing to remove${C_RESET}"
            return
        fi
    else
        local count=$(echo "$track_info" | jq -s -r 'map(select(.event == null)) | .[0].data | length // 0' 2>/dev/null); : "${count:=0}"
        for input in "$@"; do
            [ -z "$input" ] && continue
            local index=""
            if [[ "$input" =~ ^[0-9]+$ ]]; then
                if [ "$input" -gt "$count" ] || [ "$input" -lt 1 ]; then
                    echo -e "${C_PINK}🚫 Track ${C_WHITE}[${C_ORANGE}${input}${C_WHITE}] ${C_PINK}does not exist. Max Track ${C_WHITE}[${C_ORANGE}${count}${C_WHITE}]${C_RESET}"
                    continue
                fi
                index="$input"
            else
                # Search by text
                index=$(echo "$track_info" | jq -s -r --arg query "$input" '
                    map(select(.event == null)) |
                    .[0].data | select(type == "array") | 
                    to_entries[] | 
                    select(((.value.title? // "") | test($query; "i")) or ((.value.filename? // "") | test($query; "i"))) | 
                    .key + 1
                ' 2>/dev/null | head -n 1)
                
                if [ -z "$index" ] || [ "$index" == "null" ]; then
                    echo -e "${C_PINK}🔍🤷 No track matching ${C_WHITE}[${C_ORANGE}${input}${C_WHITE}] ${C_PINK}found in queue list${C_RESET}"
                    continue
                fi
            fi
            INDICES_TO_REMOVE+=("$index")
        done
    fi

    # Sort indices descending to avoid shift issues
    if [ ${#INDICES_TO_REMOVE[@]} -gt 0 ]; then
        # Use tr/sort/uniq to get unique sorted descending list
        local sorted_indices=$(printf "%s\n" "${INDICES_TO_REMOVE[@]}" | sort -nu | sort -nr)
        local was_playing_removed=false
        local removed_playing_filename=""
        local removed_playing_title=""
        
        for idx in $sorted_indices; do
            # Extract title for feedback
            local item_json=$(echo "$track_info" | jq -s -c "map(select(.event == null)) | .[0].data[$((idx - 1))] // empty")
            [ -z "$item_json" ] && continue

            local filename=$(echo "$item_json" | jq -r '.filename // ""')
            local mpv_title=$(echo "$item_json" | jq -r '.title // ""')
            local is_current=$(echo "$item_json" | jq -r '.current // false')
            
            if [ "$is_current" == "true" ]; then
                was_playing_removed=true
                removed_playing_filename="$filename"
                removed_playing_title="$mpv_title"
            fi
            
            local formatted_track=$(format_track_log "$idx" "$filename" "$mpv_title")

            echo "{ \"command\": [\"playlist-remove\", $((idx - 1))] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
            if [ "$also_dislike" = true ]; then
                add_to_auto_blacklist "$filename" "$mpv_title"
                echo -e "${C_PINK}👎✖ Removed & Blacklisted ${formatted_track}${C_RESET}"
            else
                echo -e "${C_PINK}✖  Removed ${formatted_track}${C_RESET}"
            fi
        done
        
        # Let mpv settle after removal before querying state
        # Without this delay, socket queries race with mpv's track transition
        sleep 0.5
        
        # Check playback status if we affected the playing track
        if [ "$was_playing_removed" = true ]; then
            # Query mpv state after removal
            local cur_status=$(echo -e '{"command":["get_property","playlist-count"]}\n{"command":["get_property","playlist-pos"]}\n{"command":["get_property","idle-active"]}\n{"command":["get_property","pause"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -j -r '
                map(select(.event == null)) |
                (.[0].data // 0), "\t", (if .[1].data == null then -1 else .[1].data end), "\t", (.[2].data // "false"), "\t", (.[3].data // "false")
            ' 2>/dev/null)
            IFS=$'\t' read -r rem_count rem_pos rem_idle rem_paused <<< "$cur_status"
            
            # If removing the track made MPV idle (e.g. removed last song or queue became empty)
            # AND auto-mode is enabled, discover and queue the next track before logging
            if { [ "$rem_idle" == "true" ] || [ "$rem_pos" -eq -1 ]; } && [ -f "$HOME/.cache/mpv/auto_enabled" ]; then
                echo -ne "${C_GRAY}⏳ Discovering related track...${C_RESET}\r"
                auto_queue_related "$removed_playing_title" "$removed_playing_filename" true
                echo -ne "\033[2K\r"
            elif [ -f "$HOME/.cache/mpv/auto_enabled" ]; then
                # Queue still has tracks and is continuing playback, trigger auto-discovery in background
                ( auto_queue_related "$removed_playing_title" "$removed_playing_filename" ) >/dev/null 2>&1 & disown
            fi

            wait_for_playback_start
            if [ "$rem_paused" == "true" ]; then
                log_now_playing "|| Paused: "
            else
                log_now_playing
            fi
        else
            # Just show what is playing now (no wait needed usually, but safe to check)
            local is_paused=$(echo '{ "command": ["get_property", "pause"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // "false"')
            if [ "$is_paused" == "true" ]; then
                log_now_playing "|| Still Paused: "
            else
                log_now_playing "|> Still Playing: "
            fi
            
            # Background auto-queue check
            ( auto_queue_related "$removed_playing_title" "$removed_playing_filename" ) >/dev/null 2>&1 & disown
        fi
        
        # Delay save to avoid racing with mpv during track transition
        ( sleep 2; save_current_playlist true ) >/dev/null 2>&1 & disown
    fi
}
cmd_move() {
    local from=$1
    local to=$2
    [ -z "$from" ] || [ -z "$to" ] && return

    # Fetch track info for pretty logging
    local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET")
    local count=$(echo "$track_info" | jq -s -r 'map(select(.event == null)) | .[0].data | length // 0' 2>/dev/null); : "${count:=0}"

    if [ "$from" -gt "$count" ] || [ "$from" -lt 1 ]; then
        echo -e "${C_PINK}🚫 Track ${C_WHITE}[${C_ORANGE}${from}${C_WHITE}] ${C_PINK}does not exist. Max Track ${C_WHITE}[${C_ORANGE}${count}${C_WHITE}]${C_RESET}"
        return
    fi

    # Cap 'to' index at bounds
    [ "$to" -gt "$count" ] && to="$count"
    [ "$to" -lt 1 ] && to=1

    local target_idx=$((to - 1))
    # MPV adjustment: if moving forward, target index must be 'to' to land at 'to'
    [ "$from" -lt "$to" ] && target_idx=$to

    local item_json=$(echo "$track_info" | jq -s -c "map(select(.event == null)) | .[0].data[$((from - 1))] // empty")
    local filename=$(echo "$item_json" | jq -r '.filename // ""')
    local mpv_title=$(echo "$item_json" | jq -r '.title // ""')

    local formatted_track=$(format_track_log "$from" "$filename" "$mpv_title")
    # Extract only the content after the index for the move log to keep "From -> To" style clean
    local track_details=$(echo -e "$formatted_track" | sed 's/^[^]]*]//')

    echo "{ \"command\": [\"playlist-move\", $((from - 1)), $target_idx] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
    echo -e "${C_CYAN}🚚 Moved ${C_WHITE}[${C_ORANGE}$from${C_WHITE}] ${C_CYAN}-> ${C_WHITE}[${C_ORANGE}$to${C_WHITE}]${C_RESET}${track_details}"
    save_current_playlist true >/dev/null 2>&1 & disown
}

cmd_swap() {
    local p1=$1
    local p2=$2
    [ -z "$p1" ] || [ -z "$p2" ] && return
    [ "$p1" -eq "$p2" ] && return

    # Validate bounds
    local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET")
    local count=$(echo "$track_info" | jq -s -r 'map(select(.event == null)) | .[0].data | length // 0' 2>/dev/null); : "${count:=0}"

    if [ "$p1" -gt "$count" ] || [ "$p1" -lt 1 ] || [ "$p2" -gt "$count" ] || [ "$p2" -lt 1 ]; then
        echo -e "${C_PINK}🚫 Invalid indices for swap${C_RESET}"
        return
    fi

    # Sort indices (small -> large)
    local s=$p1
    local l=$p2
    if [ "$p1" -gt "$p2" ]; then s=$p2; l=$p1; fi

    # Fetch data for logging
    local item_s=$(echo "$track_info" | jq -s -c "map(select(.event == null)) | .[0].data[$((s-1))]")
    local item_l=$(echo "$track_info" | jq -s -c "map(select(.event == null)) | .[0].data[$((l-1))]")
    
    local f_s=$(echo "$item_s" | jq -r '.filename'); local t_s_raw=$(echo "$item_s" | jq -r '.title // empty')
    local f_l=$(echo "$item_l" | jq -r '.filename'); local t_l_raw=$(echo "$item_l" | jq -r '.title // empty')

    local log_s=$(format_track_log "$s" "$f_s" "$t_s_raw")
    local log_l=$(format_track_log "$l" "$f_l" "$t_l_raw")
    
    local details_s=$(echo -e "$log_s" | sed 's/^[^]]*]//')
    local details_l=$(echo -e "$log_l" | sed 's/^[^]]*]//')

    # Strategy: Move Small to Large, then Large-1 to Small
    # Use quiet mode for cmd_move to avoid confusing logs
    
    # 1. Move S -> L
    cmd_move "$s" "$l" >/dev/null
    echo -e "${C_CYAN}🚚 Moved ${C_WHITE}[${C_ORANGE}$s${C_WHITE}] ${C_CYAN}-> ${C_WHITE}[${C_ORANGE}$l${C_WHITE}]${C_RESET}${details_s}"
    
    sleep 0.1 # Safety delay
    
    # 2. Move L-1 -> S (User thinks L -> S)
    cmd_move "$((l - 1))" "$s" >/dev/null
    echo -e "${C_CYAN}🚚 Moved ${C_WHITE}[${C_ORANGE}$l${C_WHITE}] ${C_CYAN}-> ${C_WHITE}[${C_ORANGE}$s${C_WHITE}]${C_RESET}${details_l}"
    save_current_playlist true >/dev/null 2>&1 & disown
}

cmd_clear() {
    echo '{"command": ["playlist-clear"]}' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
    echo -e "${C_PINK}🧹 Queue cleared.${C_RESET}"
    save_current_playlist true true >/dev/null 2>&1 & disown
}

cmd_shuffle() {
    local mode="$1"
    if [ "$mode" == "list" ] || [ "$mode" == "all" ]; then
        echo '{"command": ["playlist-shuffle"]}' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        echo -e "${C_PINK}🔀 Playlist entries shuffled.${C_RESET}"
        save_current_playlist true >/dev/null 2>&1 & disown
    else
        # Toggle shuffle property
        local current=$(echo '{ "command": ["get_property", "shuffle"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // "false"')
        if [ "$current" == "true" ]; then
            echo '{ "command": ["set_property", "shuffle", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
            echo -e "${C_ORANGE}🔀 Shuffle Mode: ${C_WHITE}OFF${C_RESET}"
        else
            echo '{ "command": ["set_property", "shuffle", true] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
            echo -e "${C_PINK}🔀 Shuffle Mode: ${C_WHITE}ON ${C_RESET}${C_GRAY}(Randomized Playback)${C_RESET}"
        fi
    fi
}

cmd_remove_redundant() {
    local playlist_file="$1"

    if [ -n "$playlist_file" ]; then
        # --- File Mode ---
        if [ ! -f "$playlist_file" ]; then 
            echo -e "${C_PINK}🔍🤷 Playlist file not found: ${C_WHITE}[${C_ORANGE}${playlist_file}${C_WHITE}]${C_RESET}"
            return
        fi
        
        local temp=$(mktemp)
        # Keep first occurrence, preserve order
        awk '!seen[$0]++' "$playlist_file" > "$temp"
        
        local old_count=$(wc -l < "$playlist_file")
        local new_count=$(wc -l < "$temp")
        local removed=$((old_count - new_count))
        
        mv "$temp" "$playlist_file"
        
        if [ "$removed" -gt 0 ]; then
            echo -e "${C_GREEN}✨ Cleaned up ${C_ORANGE}${removed}${C_GREEN} duplicates.${C_RESET}"
            echo -e "${C_TEAL}📊 Status: ${C_CYAN}${new_count}${C_RESET} tracks remaining."
        else
            echo -e "${C_GREEN}✅ No duplicates found.${C_RESET}"
            echo -e "${C_TEAL}📊 Status: ${C_CYAN}${new_count}${C_RESET} tracks."
        fi
    else
        # --- Socket Mode ---
        local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET")
        local indices_to_remove=$(echo "$track_info" | jq -r \
            'select(.data != null and (.data | type == "array")) | [ .data | to_entries[] | {idx: .key, file: .value.filename} ] 
            | group_by(.file) 
            | map(.[1:]) 
            | flatten 
            | map(.idx) 
            | sort 
            | reverse 
            | .[]
        ' 2>/dev/null)

        if [ -z "$indices_to_remove" ]; then
            echo -e "${C_GREEN}✅ No duplicate tracks found.${C_RESET}"
            return
        fi

        local count=$(echo "$indices_to_remove" | wc -l)
        echo -e "${C_PINK}🧹 Removing ${C_ORANGE}$count${C_PINK} duplicate tracks...${C_RESET}"

        for idx in $indices_to_remove;
         do
            echo "{ \"command\": [\"playlist-remove\", $idx] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        done
        
        echo -e "${C_GREEN}✨ Cleaned up $count duplicates.${C_RESET}"
        ( sleep 0.3; save_current_playlist true ) >/dev/null 2>&1 & disown
    fi
}

cmd_clean() {
    local playlist_file="$1"

    # Initialize memory cache once
    load_cache_to_memory

    if [ -n "$playlist_file" ]; then
        # --- File Mode ---
        if [ ! -f "$playlist_file" ]; then 
            echo -e "${C_PINK}🔍🤷 Playlist file not found: ${C_WHITE}[${C_ORANGE}${playlist_file}${C_WHITE}]${C_RESET}"
            return
        fi

        echo -e "${C_PINK}🧹 Scanning playlist for dead tracks (Cache-based)...${C_RESET}"
        local temp=$(mktemp)
        local removed_count=0
        local total_count=0
        
        while IFS= read -r url; do
             [ -z "$url" ] && continue
             ((total_count++))
             
             # Clean URL for lookup
             local clean_url="$url"
             if [[ "$url" =~ ^http ]]; then
                 clean_url="${url%%\\t*}"
                 clean_url="${clean_url%%[[:space:]]*}"
             fi

             local is_dead=false
             local cached_row="${CACHE_MEM[$clean_url]}"
             local cached_title=$(echo -e "$cached_row" | awk -F'\t' '{print $1}')
             local cached_artist=$(echo -e "$cached_row" | awk -F'\t' '{print $2}')

             if [[ "$cached_title" == "[Private video]" ]] || [[ "$cached_title" == "[Deleted video]" ]] || [[ "$cached_title" == "Video unavailable" ]]; then
                 is_dead=true
             elif [[ "$cached_title" == "Loading Metadata..." ]] && [[ "$cached_artist" == "Unknown" ]]; then
                 is_dead=true
             fi
             
             if [ "$is_dead" = true ]; then
                 ((removed_count++))
             else
                 echo "$url" >> "$temp"
             fi
        done < "$playlist_file"
        
        mv "$temp" "$playlist_file"
        
        local alive_count=$((total_count - removed_count))
        echo -e "${C_PINK}✨ Removed ${C_ORANGE}${removed_count}${C_PINK} dead tracks.${C_RESET}"
        echo -e "${C_TEAL}📊 Status: ${C_CYAN}${alive_count}${C_RESET} Alive | ${C_PINK}${removed_count}${C_RESET} Removed"
    else
        # --- Socket Mode ---
        local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET")
        local total_count=$(echo "$track_info" | jq -r '.data | length // 0' 2>/dev/null); : "${total_count:=0}"
        
        if [ "$total_count" -eq 0 ]; then
            echo -e "${C_ORANGE}⚠️ Queue is empty.${C_RESET}"
            return
        fi

        echo -e "${C_PINK}🧹 Scanning for dead or junk tracks...${C_RESET}"
        
        local dead_indices=""
        local i=0
        # Process each track
        while IFS='|' read -r filename mpv_title; do
            local is_junk=false
            
            # 1. Clean filename for cache lookup
            local clean_fname="$filename"
            if [[ "$filename" =~ ^http ]]; then
                clean_fname="${filename%%\\t*}"
                clean_fname="${clean_fname%%$'\t'*}"
                clean_fname="${clean_fname%%[[:space:]]*}"
            fi

            # 2. Check for explicit dead markers in current title
            if [[ "$mpv_title" == "[Private video]" ]] || [[ "$mpv_title" == "[Deleted video]" ]] || [[ "$mpv_title" == "Video unavailable" ]]; then
                is_junk=true
            fi

            # 3. Check for non-media files (Local files only)
            if [ "$is_junk" = false ]; then
                if ! is_media_file "$clean_fname"; then
                    is_junk=true
                fi
            fi

            # 4. Always check Cache (even if title exists, it might be a stale embedded one)
            if [ "$is_junk" = false ]; then
                local cached_row="${CACHE_MEM[$clean_fname]}"
                local cached_title=$(echo -e "$cached_row" | awk -F'\t' '{print $1}')
                local cached_artist=$(echo -e "$cached_row" | awk -F'\t' '{print $2}')

                if [[ "$cached_title" == "[Private video]" ]] || [[ "$cached_title" == "[Deleted video]" ]] || [[ "$cached_title" == "Video unavailable" ]]; then
                    is_junk=true
                elif [[ "$cached_title" == "Loading Metadata..." ]] && [[ "$cached_artist" == "Unknown" ]]; then
                    is_junk=true
                fi
            fi

            if [ "$is_junk" = true ]; then
                dead_indices="${i} ${dead_indices}"
            fi
            ((i++))
        done < <(echo "$track_info" | jq -r '.data[] | "\(.filename)|\(.title // "")"')

        if [ -z "$dead_indices" ]; then
            echo -e "${C_GREEN}✅ No dead or junk tracks found.${C_RESET}"
            echo -e "${C_TEAL}📊 Status: ${C_CYAN}${total_count}${C_RESET} Alive"
            return
        fi

        local removed_count=0
        # Reverse indices to prevent shift issues
        local sorted_dead=$(echo "$dead_indices" | tr ' ' '\n' | sort -nr)
        
        for idx in $sorted_dead;
         do
            echo "{ \"command\": [\"playlist-remove\", $idx] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
            ((removed_count++))
        done
        
        local alive_count=$((total_count - removed_count))
        local unit="tracks"
        [ "$removed_count" -eq 1 ] && unit="track"
        
        echo -e "${C_PINK}✨ Removed ${C_ORANGE}${removed_count}${C_PINK} dead/junk ${unit}.${C_RESET}"
        echo -e "${C_TEAL}📊 Status: ${C_CYAN}${alive_count}${C_RESET} Alive | ${C_PINK}${removed_count}${C_RESET} Removed"
        ( sleep 0.3; save_current_playlist true ) >/dev/null 2>&1 & disown
    fi
}

queue_item_ipc() {
    local url="$1"
    local title="$2"
    local artist="$3"
    local duration="$4"
    
    # Robust URL cleaning (Only for remote URLs)
    local clean_url="$url"
    if [[ "$url" =~ ^http ]]; then
        clean_url="${url%%\\t*}"
        clean_url="${clean_url%%[[:space:]]*}"
        clean_url=$(echo "$clean_url" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    fi
    
    # Get current playlist size to determine new index efficiently
    local count=$(echo '{ "command": ["get_property", "playlist-count"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0')
    local next_index=$((count + 1))

    if [ -n "$title" ] && [ "$title" != "$url" ]; then
        if [ -n "$artist" ] || [ -n "$duration" ]; then
             printf "%s\t%s\t%s\t%s\n" "$clean_url" "$title" "$artist" "$duration" >> "$CACHE_FILE"
             CACHE_MEM["$clean_url"]="${title}"$'\t'"${artist}"$'\t'"${duration}"
        else
             printf "%s\t%s\n" "$clean_url" "$title" >> "$CACHE_FILE"
             CACHE_MEM["$clean_url"]="${title}"
        fi
    fi

    local display_title_log="$title"
    [ -z "$display_title_log" ] && display_title_log=$(basename "$clean_url")

    local formatted_track=$(format_track_log "$next_index" "$clean_url" "$display_title_log")
    echo -e "${C_PINK}✅ Queued ${formatted_track}"

    local json_cmd=$(jq -nc --arg path "$clean_url" '{"command": ["loadfile", $path, "append-play"]}')
    send_ipc "$json_cmd" > /dev/null
    
    # Auto-resume only if MPV was idle at the end of the queue (Play new index)
    check_and_resume "$count"
    
    save_current_playlist true >/dev/null 2>&1 & disown
}

# --- PERSONALIZED AUTO DISCOVERY SUBSYSTEM ---

add_to_auto_blacklist() {
    local target="$1"
    local opt_title="$2"
    local b_id=""
    if [[ "$target" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]]; then
        b_id="${BASH_REMATCH[2]}"
    elif [[ "$target" =~ ^[a-zA-Z0-9_-]{11}$ ]]; then
        b_id="$target"
    fi
    if [ -n "$b_id" ]; then
        local bl_file="$HOME/.cache/mpv/auto_blacklist"
        mkdir -p "$(dirname "$bl_file")" 2>/dev/null
        touch "$bl_file" 2>/dev/null

        # If opt_title is missing, try looking up in titles cache
        if [ -z "$opt_title" ] || [ "$opt_title" == "$target" ] || [ "$opt_title" == "$b_id" ]; then
            opt_title=$(get_cached_title "$target")
            [ -z "$opt_title" ] && opt_title=$(get_cached_title "$b_id")
        fi
        [ -z "$opt_title" ] && opt_title="Disliked Track"

        # Check if already in blacklist
        if ! grep -E -q "^${b_id}([[:blank:]]|$)" "$bl_file" 2>/dev/null; then
            printf "%s\t%s\n" "$b_id" "$opt_title" >> "$bl_file"
        fi
        if [ $((RANDOM % 15)) -eq 0 ] && [ -f "$bl_file" ]; then
            sort -u -k1,1 "$bl_file" | tail -n 500 > "$bl_file.tmp" 2>/dev/null && mv "$bl_file.tmp" "$bl_file"
        fi
    fi
}

remove_from_auto_blacklist() {
    local target="$1"
    local b_id=""
    if [[ "$target" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]]; then
        b_id="${BASH_REMATCH[2]}"
    elif [[ "$target" =~ ^[a-zA-Z0-9_-]{11}$ ]]; then
        b_id="$target"
    else
        b_id="$target"
    fi
    local bl_file="$HOME/.cache/mpv/auto_blacklist"
    if [ -f "$bl_file" ] && [ -n "$b_id" ]; then
        local tmp=$(mktemp)
        grep -E -v "^${b_id}([[:blank:]]|$)" "$bl_file" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$bl_file"
    fi
}

cmd_undislike() {
    local bl_file="$HOME/.cache/mpv/auto_blacklist"
    if [ ! -f "$bl_file" ] || [ ! -s "$bl_file" ]; then
        echo -e "${C_PINK}ℹ️ Dislike list is currently empty.${C_RESET}"
        return 0
    fi

    # If no argument passed:
    if [ "$#" -eq 0 ] || [ -z "$1" ]; then
        local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)
        local item_json=$(echo "$track_info" | jq -s -c 'map(select(.event == null)) | .[0].data[] | select(.current) // empty' 2>/dev/null)
        local filename=$(echo "$item_json" | jq -r '.filename // ""')
        local title=$(echo "$item_json" | jq -r '.title // ""')

        local cur_id=""
        [[ "$filename" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]] && cur_id="${BASH_REMATCH[2]}"

        if [ -n "$cur_id" ] && grep -E -q "^${cur_id}([[:blank:]]|$)" "$bl_file" 2>/dev/null; then
            remove_from_auto_blacklist "$cur_id"
            echo -e "${C_GREEN}✨ Removed from Dislike List & Whitelisted:${C_RESET} ${C_CYAN}${title:-$cur_id}${C_RESET}"
            return 0
        else
            cmd_dislike_list
            return $?
        fi
    fi

    for target in "$@"; do
        [ -z "$target" ] && continue
        local b_id=""
        local b_title=""

        if [[ "$target" =~ ^[0-9]+$ ]]; then
            local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)
            local idx=$((target - 1))
            local item_json=$(echo "$track_info" | jq -s -c "map(select(.event == null)) | .[0].data[$idx] // empty" 2>/dev/null)
            local filename=$(echo "$item_json" | jq -r '.filename // ""')
            b_title=$(echo "$item_json" | jq -r '.title // ""')
            [[ "$filename" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]] && b_id="${BASH_REMATCH[2]}"
        elif [[ "$target" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]]; then
            b_id="${BASH_REMATCH[2]}"
        elif [[ "$target" =~ ^[a-zA-Z0-9_-]{11}$ ]]; then
            b_id="$target"
        else
            local match_line=$(grep -i -F "$target" "$bl_file" 2>/dev/null | head -n 1)
            if [ -n "$match_line" ]; then
                b_id=$(echo "$match_line" | awk -F'\t' '{print $1}')
                b_title=$(echo "$match_line" | awk -F'\t' '{print $2}')
            fi
        fi

        if [ -n "$b_id" ] && grep -E -q "^${b_id}([[:blank:]]|$)" "$bl_file" 2>/dev/null; then
            if [ -z "$b_title" ]; then
                b_title=$(grep -E "^${b_id}([[:blank:]]|$)" "$bl_file" 2>/dev/null | head -n 1 | awk -F'\t' '{print $2}')
            fi
            remove_from_auto_blacklist "$b_id"
            echo -e "${C_GREEN}✨ Removed from Dislike List & Whitelisted:${C_RESET} ${C_CYAN}${b_title:-$b_id}${C_RESET}"
        else
            echo -e "${C_PINK}🔍🤷 Track [${C_ORANGE}${target}${C_PINK}] not found in dislike blacklist.${C_RESET}"
        fi
    done
}

cmd_dislike_list() {
    local bl_file="$HOME/.cache/mpv/auto_blacklist"
    touch "$bl_file" 2>/dev/null

    while true; do
        local items=""
        local count=0
        if [ -s "$bl_file" ]; then
            local i=1
            while IFS=$'\t' read -r bid btitle; do
                [ -z "$bid" ] && continue
                [ -z "$btitle" ] && btitle=$(get_cached_title "$bid")
                [ -z "$btitle" ] && btitle="Track ($bid)"
                items+="${C_ORANGE}${i}.${C_RESET} ${C_CYAN}${btitle}${C_RESET} ${C_GRAY}[${bid}]${C_RESET}"$'\t'"${bid}"$'\t'"${btitle}"$'\n'
                ((i++))
                ((count++))
            done < "$bl_file"
        fi

        local fzf_input=""
        fzf_input+="  ✚  Add Track to Dislike List...\n"
        [ "$count" -gt 0 ] && fzf_input+="  🗑️   Clear Entire Dislike List ($count tracks)\n"
        fzf_input+="$items"

        local header=$(printf "${C_GRAY}${H_LINE}${C_RESET}\n  ${C_PURPLE}👎 Dislike List Manager${C_RESET} ${C_GRAY}(${count} blacklisted tracks)${C_RESET}\n  ${C_GRAY}ENTER: Remove from Dislike List | TAB: Select Multiple | ESC: Exit${C_RESET}")

        local sel=$(echo -ne "$fzf_input" | fzf --multi --ansi --height=100% --layout=reverse --border \
            --header="$header" \
            --delimiter=$'\t' --with-nth=1 \
            --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
            --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
            $FZF_COLOR_OPTS \
            --info=inline-right --prompt="Dislike Manager > ")

        [ -z "$sel" ] && break

        # Case 1: Add Track to Dislike List
        if echo "$sel" | grep -q "Add Track to Dislike List"; then
            local add_action=$(echo -e "  🎵  Currently Playing Track\n  📋  Pick from Current Queue\n  🕒  Pick from Recent History\n  🔍  Search YouTube to Dislike\n  🔗  Enter URL or Video ID manually" | \
                fzf --height=100% --layout=reverse --border --info=inline-right \
                $FZF_COLOR_OPTS \
                --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
                --header="How would you like to add track(s) to the Dislike List?" \
                --prompt="Add Dislike > ")

            [ -z "$add_action" ] && continue

            if echo "$add_action" | grep -q "Currently Playing"; then
                cmd_dislike
            elif echo "$add_action" | grep -q "Current Queue"; then
                local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)
                local q_count=$(echo "$track_info" | jq -s -r 'map(select(.event == null)) | .[0].data | length // 0' 2>/dev/null)
                if [ "$q_count" -eq 0 ]; then
                    echo -e "${C_PINK}ℹ️ Current queue is empty.${C_RESET}"
                else
                    local q_items=""
                    for ((k=0; k<q_count; k++)); do
                        local item_json=$(echo "$track_info" | jq -s -c "map(select(.event == null)) | .[0].data[$k] // empty")
                        local fn=$(echo "$item_json" | jq -r '.filename // ""')
                        local tt=$(echo "$item_json" | jq -r '.title // ""')
                        [ -z "$tt" ] && tt="$fn"
                        q_items+="${C_ORANGE}$((k+1)).${C_RESET} ${C_CYAN}${tt}${C_RESET}"$'\t'"${fn}"$'\t'"${tt}"$'\n'
                    done
                    local q_sel=$(echo -ne "$q_items" | fzf --multi --ansi --height=100% --layout=reverse --border \
                        --delimiter=$'\t' --with-nth=1 \
                        --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
                        $FZF_COLOR_OPTS \
                        --header="Select track(s) from current queue to dislike:" \
                        --prompt="Queue Track > ")
                    if [ -n "$q_sel" ]; then
                        while IFS= read -r q_line; do
                            [ -z "$q_line" ] && continue
                            local q_url=$(echo "$q_line" | awk -F'\t' '{print $2}')
                            local q_tit=$(echo "$q_line" | awk -F'\t' '{print $3}')
                            add_to_auto_blacklist "$q_url" "$q_tit"
                            echo -e "${C_PINK}👎 Disliked & Blacklisted:${C_RESET} ${C_CYAN}${q_tit:-$q_url}${C_RESET}"
                        done <<< "$q_sel"
                    fi
                fi
            elif echo "$add_action" | grep -q "Recent History"; then
                local hist_file="$HOME/.cache/mpv/auto_history"
                if [ ! -s "$hist_file" ]; then
                    echo -e "${C_PINK}ℹ️ Recent history is empty.${C_RESET}"
                else
                    local h_items=""
                    local h_idx=1
                    while IFS= read -r h_id; do
                        [ -z "$h_id" ] && continue
                        local h_tit=$(get_cached_title "$h_id")
                        [ -z "$h_tit" ] && h_tit="History Track ($h_id)"
                        h_items+="${C_ORANGE}${h_idx}.${C_RESET} ${C_CYAN}${h_tit}${C_RESET} ${C_GRAY}[${h_id}]${C_RESET}"$'\t'"${h_id}"$'\t'"${h_tit}"$'\n'
                        ((h_idx++))
                    done < <(tail -n 30 "$hist_file" 2>/dev/null | tac)
                    local h_sel=$(echo -ne "$h_items" | fzf --multi --ansi --height=100% --layout=reverse --border \
                        --delimiter=$'\t' --with-nth=1 \
                        --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
                        $FZF_COLOR_OPTS \
                        --header="Select track(s) from history to dislike:" \
                        --prompt="History Track > ")
                    if [ -n "$h_sel" ]; then
                        while IFS= read -r h_line; do
                            [ -z "$h_line" ] && continue
                            local h_url=$(echo "$h_line" | awk -F'\t' '{print $2}')
                            local h_tit=$(echo "$h_line" | awk -F'\t' '{print $3}')
                            add_to_auto_blacklist "$h_url" "$h_tit"
                            echo -e "${C_PINK}👎 Disliked & Blacklisted:${C_RESET} ${C_CYAN}${h_tit:-$h_url}${C_RESET}"
                        done <<< "$h_sel"
                    fi
                fi
            elif echo "$add_action" | grep -q "Search YouTube"; then
                local s_query=$(get_input "Search YouTube to Dislike" "Search > ")
                if [ -n "$s_query" ]; then
                    echo -e "${C_GRAY}⏳ Searching YouTube for \"$s_query\"...${C_RESET}"
                    local s_tmp=$(mktemp)
                    run_with_timeout 25s yt-dlp --print "%(webpage_url)s\t%(title)s\t%(uploader)s\t%(duration_string)s" --flat-playlist --no-warnings --skip-download --playlist-end 15 "ytsearch15:${s_query}" > "$s_tmp" 2>/dev/null
                    if [ -s "$s_tmp" ]; then
                        local s_items=""
                        local s_idx=1
                        while IFS=$'\t' read -r su st sa sd; do
                            [ -z "$su" ] && continue
                            s_items+="${C_ORANGE}${s_idx}.${C_RESET} ${C_CYAN}${st}${C_RESET} ${C_LIGHT_PINK}by ${sa}${C_RESET} [${sd}]"$'\t'"${su}"$'\t'"${st}"$'\n'
                            ((s_idx++))
                        done < "$s_tmp"
                        local s_sel=$(echo -ne "$s_items" | fzf --multi --ansi --height=100% --layout=reverse --border \
                            --delimiter=$'\t' --with-nth=1 \
                            --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
                            $FZF_COLOR_OPTS \
                            --header="Select track(s) to blacklist from Auto Mode:" \
                            --prompt="Dislike Track > ")
                        if [ -n "$s_sel" ]; then
                            while IFS= read -r s_line; do
                                [ -z "$s_line" ] && continue
                                local s_url=$(echo "$s_line" | awk -F'\t' '{print $2}')
                                local s_tit=$(echo "$s_line" | awk -F'\t' '{print $3}')
                                add_to_auto_blacklist "$s_url" "$s_tit"
                                echo -e "${C_PINK}👎 Disliked & Blacklisted:${C_RESET} ${C_CYAN}${s_tit:-$s_url}${C_RESET}"
                            done <<< "$s_sel"
                        fi
                    else
                        echo -e "${C_PINK}⚠️ No search results found.${C_RESET}"
                    fi
                    rm -f "$s_tmp"
                fi
            elif echo "$add_action" | grep -q "Enter URL"; then
                local manual_url=$(get_input "Enter URL or Video ID to Dislike" "URL/ID > ")
                if [ -n "$manual_url" ]; then
                    add_to_auto_blacklist "$manual_url"
                    echo -e "${C_PINK}👎 Disliked & Blacklisted:${C_RESET} ${C_CYAN}$manual_url${C_RESET}"
                fi
            fi
            sleep 0.8
            continue
        fi

        # Case 2: Clear Entire Dislike List
        if echo "$sel" | grep -q "Clear Entire Dislike List"; then
            local confirm=$(echo -e "  ❌  No, Cancel\n  🗑️   Yes, Clear All Dislikes" | \
                fzf --height=100% --layout=reverse --border --info=inline-right \
                $FZF_COLOR_OPTS \
                --header="Are you sure you want to completely clear the dislike list ($count tracks)?" \
                --prompt="Confirm > ")
            if echo "$confirm" | grep -q "Yes, Clear"; then
                > "$bl_file"
                echo -e "${C_GREEN}✅ Dislike list cleared completely.${C_RESET}"
            fi
            sleep 0.8
            continue
        fi

        # Case 3: User selected one or more tracks to un-dislike
        local removed_count=0
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local target_id=$(echo "$line" | awk -F'\t' '{print $2}')
            local target_title=$(echo "$line" | awk -F'\t' '{print $3}')
            if [ -n "$target_id" ]; then
                remove_from_auto_blacklist "$target_id"
                echo -e "${C_GREEN}✨ Whitelisted & Removed from Dislike List:${C_RESET} ${C_CYAN}${target_title:-$target_id}${C_RESET}"
                ((removed_count++))
            fi
        done <<< "$sel"
        sleep 0.8
    done
}

parse_duration_to_seconds() {
    local d="$1"
    local s=0
    IFS=: read -r -a p <<< "$d"
    if [ ${#p[@]} -eq 2 ]; then
        s=$(( 10#${p[0]} * 60 + 10#${p[1]} ))
    elif [ ${#p[@]} -eq 3 ]; then
        s=$(( 10#${p[0]} * 3600 + 10#${p[1]} * 60 + 10#${p[2]} ))
    fi
    echo "$s"
}

score_candidate_track() {
    local title="$1"
    local uploader="$2"
    local dur="$3"
    local score=10
    local lower_title=$(echo "$title" | tr '[:upper:]' '[:lower:]')
    local lower_uploader=$(echo "$uploader" | tr '[:upper:]' '[:lower:]')

    # Hard Reject: Non-music, Spoken Skits, Reviews, Teasers
    if [[ "$lower_title" =~ (teaser|trailer|reaction|reacts|review|full[[:space:]]+movie|short[[:space:]]+film|interview|behind[[:space:]]+the[[:space:]]+scenes|bts|episode|ep\.|making[[:space:]]+of) ]]; then
        echo -9999
        return
    fi

    # Bonus: Studio Topic upload (+60) - Clean album release from music distributor
    if [[ "$lower_uploader" =~ -[[:space:]]*topic$ ]] || [[ "$lower_title" =~ -[[:space:]]*topic$ ]]; then
        score=$((score + 60))
    fi

    # Bonus: Clean studio audio releases (+40)
    if [[ "$lower_title" =~ (official[[:space:]]+audio|audio[[:space:]]+only|lyric[[:space:]]+video|lyrics|clean[[:space:]]+audio|studio[[:space:]]+version|original[[:space:]]+track) ]]; then
        score=$((score + 40))
    fi

    # Penalty: Official music videos without audio/lyric tags (-15, so studio tracks take precedence)
    if [[ "$lower_title" =~ (official[[:space:]]+music[[:space:]]+video|official[[:space:]]+video) ]] && [[ ! "$lower_title" =~ (audio|lyric) ]]; then
        score=$((score - 15))
    fi

    # Duration scoring:
    if [ -n "$dur" ] && [ "$dur" != "N/A" ] && [ "$dur" != "null" ]; then
        local dur_s=$(parse_duration_to_seconds "$dur")
        if [ "$dur_s" -ge 120 ] && [ "$dur_s" -le 360 ]; then
            score=$((score + 25))
        elif [ "$dur_s" -gt 450 ]; then
            score=$((score - 35))
        elif [ "$dur_s" -lt 80 ] && [ "$dur_s" -gt 0 ]; then
            score=$((score - 50))
        fi
    fi

    echo "$score"
}

auto_queue_related() {
    local input_title="$1"; local input_filename="$2"; local force_fetch="${3:-false}"
    local auto_file="$HOME/.cache/mpv/auto_enabled"
    local debug_log="$HOME/.cache/mpv/auto_debug.log"
    
    [ ! -f "$auto_file" ] && return

    # --- PROTOCOL: Liveness Check ---
    if { [ "$MPV_RUNNING" = false ] || [ ! -S "$SOCKET" ]; } && [ "$force_fetch" != "true" ]; then
        return
    fi

    if ! is_online; then
        echo "[$(date +%T)] [Network] Offline - Skipping auto-discovery fetch." >> "$debug_log"
        return
    fi

    # --- PROTOCOL: Status, Pause & Loop Respect ---
    local raw_status=$(echo -e '{"command":["get_property","playlist-count"]}\n{"command":["get_property","playlist-pos"]}\n{"command":["get_property","idle-active"]}\n{"command":["get_property","loop-playlist"]}\n{"command":["get_property","loop-file"]}\n{"command":["get_property","pause"]}\n{"command":["get_property","eof-reached"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -j -r '
        map(select(.event == null)) |
        (.[0].data // 0), "\t", (if .[1].data == null then -1 else .[1].data end), "\t", (.[2].data // "false"), "\t", (.[3].data // "no"), "\t", (.[4].data // "no"), "\t", (.[5].data // "false"), "\t", (.[6].data // "false")
    ' 2>/dev/null)
    
    if [ -z "$raw_status" ]; then return; fi
    IFS=$'\t' read -r count pos idle loop_p loop_f is_paused is_eof <<< "$raw_status"

    # Never auto-queue while user manually paused (unless at EOF or idle!)
    if [ "$is_paused" == "true" ] && [ "$is_eof" != "true" ] && [ "$idle" != "true" ]; then
        return
    fi

    # PROTOCOL 3: Respect Single Track Loop (Abort discovery if looping file)
    if [ "$loop_f" != "no" ]; then
        echo "[$(date +%T)] [Abort] Track loop active ($loop_f)." >> "$debug_log"
        return
    fi

    if [ "$force_fetch" != "true" ]; then
        # Intelligent Discovery Timing: only trigger when near end
        if [ "$pos" -ne -1 ] && [ "$count" -gt $((pos + 2)) ]; then
            return
        fi
        [ -f "$HOME/.cache/mpv/auto_cooldown" ] && return
    fi

    # Lock to prevent race conditions
    local lock="$HOME/.cache/mpv/auto.lock"
    if ( set -C; : > "$lock" ) 2>/dev/null; then
        trap "rm -f \"$lock\"" EXIT
    else
        [ -n "$(find "$lock" -mmin +2 2>/dev/null)" ] && rm -f "$lock"
        return
    fi

    local history_file="$HOME/.cache/mpv/auto_history"
    local blacklist_file="$HOME/.cache/mpv/auto_blacklist"
    [ ! -f "$history_file" ] && touch "$history_file"
    [ ! -f "$blacklist_file" ] && touch "$blacklist_file"

    # --- PROTOCOL: Personalized Seed Determination ---
    local seed_id=""
    local seed_title="$input_title"

    # 1. If explicit input given:
    if [ -n "$input_filename" ] && [[ "$input_filename" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]]; then
        seed_id="${BASH_REMATCH[2]}"
    fi

    # 2. If no explicit input or queue empty:
    if [ -z "$seed_id" ]; then
        if [ "$count" -gt 0 ]; then
            # Strictly seed from current active queue / currently playing playlist
            local target_idx=0
            if [ "$count" -gt 1 ]; then
                # Prefer the currently playing or most recent tracks in queue to preserve current vibe/genre
                if [ "$pos" -ge 0 ] && [ $((RANDOM % 10)) -lt 8 ]; then
                    target_idx="$pos"
                else
                    # Fallback to a random recent track in the second half of queue
                    local half=$((count / 2))
                    target_idx=$(( (RANDOM % (count - half)) + half ))
                fi
            fi

            local seed_json=$(echo "{\"command\":[\"get_property\", \"playlist/$target_idx\"]}" | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // empty')
            local s_file=$(echo "$seed_json" | jq -r '.filename // ""')
            seed_title=$(echo "$seed_json" | jq -r '.title // ""')
            if [[ "$s_file" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]]; then
                seed_id="${BASH_REMATCH[2]}"
            fi
            echo "[$(date +%T)] [Seed] Current Session Seed: Index $target_idx ($seed_id - ${seed_title:-Unknown})" >> "$debug_log"
        else
            # Queue is completely empty:
            # Continue from the track you last listened to in active history (never touching saved playlists)
            local last_hist_id=$(tail -n 1 "$history_file" 2>/dev/null)
            if [ -n "$last_hist_id" ] && [[ "$last_hist_id" =~ ^[a-zA-Z0-9_-]{11}$ ]]; then
                seed_id="$last_hist_id"
                echo "[$(date +%T)] [Seed] Empty Queue Initialized from Last Listened History: $seed_id" >> "$debug_log"
            fi
        fi
    fi

    # --- 2. Candidate Discovery (Radio & Studio Prioritization) ---
    local fields="%(webpage_url)s"$'\t'"%(title)s"$'\t'"%(uploader)s"$'\t'"%(duration_string)s"
    local candidates=""

    # Strategy A: YouTube Song Radio Mix (RD<ID>) - NOT RDAMVM
    if [ -n "$seed_id" ]; then
        echo "[$(date +%T)] [Discovery] Radio Mix for Seed ID: $seed_id" >> "$debug_log"
        candidates=$(run_with_timeout 25s nice -n 19 yt-dlp --print "$fields" --flat-playlist --no-warnings --skip-download --playlist-end 20 "https://www.youtube.com/watch?v=${seed_id}&list=RD${seed_id}" 2>/dev/null)
    fi

    # Strategy B: Studio Search fallback or augment
    if [ -z "$candidates" ]; then
        local query="popular music"
        if [ -n "$seed_title" ] && [ "$seed_title" != "null" ]; then
            local clean_q=$(echo "$seed_title" | sed -E 's/(\[|\()[^]]*(\]|\))//g' | sed 's/[^a-zA-Z0-9 ]/ /g' | awk '{$1=$1};1')
            query="${clean_q:0:50} audio"
        fi
        echo "[$(date +%T)] [Discovery] Studio Search: $query" >> "$debug_log"
        candidates=$(run_with_timeout 25s nice -n 19 yt-dlp --print "$fields" --no-warnings --skip-download --playlist-end 15 "ytsearch15:${query}" 2>/dev/null)
    fi

    if [ -z "$candidates" ]; then
        touch "$HOME/.cache/mpv/auto_failed"
        touch "$HOME/.cache/mpv/auto_cooldown"
        ( sleep 60; rm -f "$HOME/.cache/mpv/auto_cooldown" ) & disown
        return
    fi

    # --- 3. Deduplication, Blacklist Check & Studio Scoring ---
    local pl_json=$(echo '{"command":["get_property","playlist"]}' | nc $NC_OPTS -w 2 "$SOCKET" 2>/dev/null)
    local cur_ids=$(echo "$pl_json" | jq -r '.data[].filename // empty' 2>/dev/null | grep -oP '(?<=[v=be/])[a-zA-Z0-9_-]{11}' | sort -u)

    declare -a scored_pool
    # scored_pool entries: "SCORE\tURL\tTITLE\tARTIST\tDUR"
    while IFS=$'\t' read -r url t a d; do
        [ -z "$url" ] || [ "$url" == "null" ] && continue
        local c_id=""
        [[ "$url" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]] && c_id="${BASH_REMATCH[2]}"
        [ -z "$c_id" ] && continue

        # Exclusions: seed itself, already in current queue, played recently in history, or in blacklist
        [ -n "$seed_id" ] && [ "$c_id" == "$seed_id" ] && continue
        echo "$cur_ids" | grep -qx -- "$c_id" && continue
        grep -qx -- "$c_id" "$history_file" 2>/dev/null && continue
        grep -E -q "^${c_id}([[:blank:]]|$)" "$blacklist_file" 2>/dev/null && continue

        # Evaluate Candidate Score
        local s=$(score_candidate_track "$t" "$a" "$d")
        if [ "$s" -gt -100 ]; then
            scored_pool+=("$s"$'\t'"$url"$'\t'"$t"$'\t'"$a"$'\t'"$d")
        fi
    done <<< "$candidates"

    # --- 4. Intelligent Selection from Top-Scored Candidates ---
    if [ ${#scored_pool[@]} -gt 0 ]; then
        if ! [ -S "$SOCKET" ]; then return; fi

        # Sort pool by score descending
        mapfile -t sorted_pool < <(printf "%s\n" "${scored_pool[@]}" | sort -t$'\t' -k1 -nr)

        # Pick randomly from the top 3 (or fewer) highest-ranked candidates to balance studio quality & variety
        local max_pick=3
        [ ${#sorted_pool[@]} -lt 3 ] && max_pick=${#sorted_pool[@]}
        local pick_idx=$((RANDOM % max_pick))

        IFS=$'\t' read -r chosen_score chosen_url chosen_t chosen_a chosen_d <<< "${sorted_pool[$pick_idx]}"

        echo "[$(date +%T)] [Success] Queuing (Score: $chosen_score): $chosen_t (by $chosen_a)" >> "$debug_log"
        queue_item_ipc "$chosen_url" "$chosen_t" "$chosen_a" "$chosen_d"

        [[ "$chosen_url" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]] && echo "${BASH_REMATCH[2]}" >> "$history_file"
        tail -n 100 "$history_file" > "$history_file.tmp" && mv "$history_file.tmp" "$history_file"

        touch "$HOME/.cache/mpv/auto_cooldown"
        ( sleep 20; rm -f "$HOME/.cache/mpv/auto_cooldown" ) & disown
    else
        echo "[$(date +%T)] [Warning] No candidates passed quality & blacklist filters." >> "$debug_log"
        touch "$HOME/.cache/mpv/auto_cooldown"
        ( sleep 45; rm -f "$HOME/.cache/mpv/auto_cooldown" ) & disown
    fi
}
