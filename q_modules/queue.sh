show_queue() {
    # Wait for socket to be responsive (up to 2 seconds)
    if [ "$MPV_RUNNING" = false ]; then
        for i in {1..10}; do
            if [ -S "$HOME/.mpv-socket" ] && echo '{ "command": ["get_property", "playlist-count"] }' | nc -U -w 1 "$HOME/.mpv-socket" &>/dev/null; then
                MPV_RUNNING=true
                break
            fi
            sleep 0.2
        done
    fi

    if [ "$MPV_RUNNING" = false ]; then
        if [ -t 1 ]; then
            print_header_box "😴💤 MPV isn't running... it must be taking a nap"
        else
            echo "😴💤 MPV isn't running"
        fi
        exit 0
    fi

    # Only show the outer box if output is a TTY (direct terminal)
    if [ -t 1 ]; then
        print_header_box "${C_CYAN}🎵 Current Queue${C_RESET}"
    fi

    # Load cache into memory ONCE at the start
    load_cache_to_memory

    PLAYLIST_JSON=$(echo "{ \"command\": [\"get_property\", \"playlist\"] }" | nc -U -w 1 "$HOME/.mpv-socket")
    local NEEDS_FETCH=false

    # Pre-fetch uploader/duration if possible (optional enhancement)
    echo "$PLAYLIST_JSON" | jq -r '.data | to_entries | .[] | 
        "\(.key + 1)\t\(if .value.current then "|>" else "  " end)\t\(.value.filename)\t\((.value.title // "") | sub("^https?://[^\\t ]+[\\t ]+"; ""))"' | while IFS=$'\t' read -r i state filename mpv_title; do
        
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
        if [[ "$CLEAN_FILENAME" =~ ^http.* ]] || [[ "$CLEAN_FILENAME" == watch\?v=* ]]; then
            # Instant memory lookup
            local cached_row="${CACHE_MEM[$CLEAN_FILENAME]}"
            
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
        # This fixes the glitch where "Title\tArtist" is displayed + "by Artist" appended
        DISPLAY_TITLE="${DISPLAY_TITLE%%\\t*}"
        DISPLAY_TITLE="${DISPLAY_TITLE%%$'\t'*}"
        
        # 6. Formatting (Match search result style: Title by Artist [Duration])
        local artist_part=""
        local dur_part=""
        
        [ -n "$meta_artist" ] && [ "$meta_artist" != "null" ] && [ "$meta_artist" != "$CLEAN_FILENAME" ] && artist_part=" ${C_GRAY}by${C_RESET} ${C_LIGHT_PINK}$meta_artist${C_RESET}"
        [ -n "$meta_duration" ] && [ "$meta_duration" != "null" ] && [ "$meta_duration" != "0:00" ] && dur_part=" ${C_ORANGE}[$meta_duration]${C_RESET}"
        
        # Index and State
        local prefix="${C_ORANGE}${i}.${C_RESET} "
        [ "$state" == "|>" ] && prefix="${C_PINK}${i}. ${C_RESET}"

        if [ -t 1 ]; then
            # Truncate title to fit terminal while keeping artist/duration
            local index_w=${#i}
            local meta_w=$(get_visual_width "$(strip_colors "$artist_part$dur_part")")
            # INNER_WIDTH is (TERM_WIDTH - 6) for borders and padding
            local title_max_w=$((TERM_WIDTH - index_w - meta_w - 10))
            [ "$title_max_w" -lt 15 ] && title_max_w=15
            
            local final_title=$(truncate_text "$DISPLAY_TITLE" "$title_max_w")
            # Use %s for all parts to keep ANSI codes as literals (\033...) until the final print_boxed_line (%b)
            # This prevents premature interpretation or double-escaping issues.
            printf -v LINE_CONTENT "%s%s%s%s%s%s" "$prefix" "${C_CYAN}" "$final_title" "${C_RESET}" "$artist_part" "$dur_part"
            print_boxed_line "$LINE_CONTENT"
        else
            # Simple format for FZF or Raw output
            printf "%s %s%s%s\n" "$i." "$DISPLAY_TITLE" "$artist_part" "$dur_part"
        fi
        
        # Pass NEEDS_FETCH status out of the loop via a temp file or similar if needed, 
        # but since we are piping, variables are lost. 
        # However, we can just trigger the fetcher blindly at the end; the lock protects it.
    done

    # Trigger background fetcher (safe, single instance)
    fetch_missing_background >/dev/null 2>&1 & disown
    save_current_playlist true >/dev/null 2>&1 & disown

    if [ -t 1 ]; then
        printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
        B_LINE=${B_LINE// /─}
        echo -e "${C_GRAY}${B_LINE}${C_RESET}"
    fi
}

cmd_remove() {
    local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc -U -w 1 "$HOME/.mpv-socket")
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

            echo "{ \"command\": [\"playlist-remove\", $((idx - 1))] }" | nc -U -w 1 "$HOME/.mpv-socket" > /dev/null
            echo -e "${C_PINK}✖  Removed ${formatted_track}"
        done
        
        # Check playback status if we affected the playing track
        if [ "$was_playing_removed" = true ]; then
            local is_paused=$(echo '{ "command": ["get_property", "pause"] }' | nc -U -w 1 "$HOME/.mpv-socket" 2>/dev/null | jq -r '.data // "false"')
            wait_for_playback_start
            if [ "$is_paused" == "true" ]; then
                log_now_playing "|| Paused: "
            else
                log_now_playing
            fi
        else
            # Just show what is playing now (no wait needed usually, but safe to check)
            local is_paused=$(echo '{ "command": ["get_property", "pause"] }' | nc -U -w 1 "$HOME/.mpv-socket" 2>/dev/null | jq -r '.data // "false"')
            if [ "$is_paused" == "true" ]; then
                log_now_playing "|| Still Paused: "
            else
                log_now_playing "|> Still Playing: "
            fi
        fi

        # Proactive auto-queue check after removal (maybe we removed the last tracks?)
        # Pass removed playing track meta to maintain discovery vibe
        ( auto_queue_related "$removed_playing_title" "$removed_playing_filename" ) >/dev/null 2>&1 & disown
        
        save_current_playlist true >/dev/null 2>&1 & disown
    fi
}
cmd_move() {
    local from=$1
    local to=$2
    [ -z "$from" ] || [ -z "$to" ] && return

    # Fetch track info for pretty logging
    local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc -U -w 1 "$HOME/.mpv-socket")
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

    echo "{ \"command\": [\"playlist-move\", $((from - 1)), $target_idx] }" | nc -U -w 1 "$HOME/.mpv-socket" > /dev/null
    echo -e "${C_CYAN}🚚 Moved ${C_WHITE}[${C_ORANGE}$from${C_WHITE}] ${C_CYAN}-> ${C_WHITE}[${C_ORANGE}$to${C_WHITE}]${C_RESET}${track_details}"
    save_current_playlist true >/dev/null 2>&1 & disown
}

cmd_swap() {
    local p1=$1
    local p2=$2
    [ -z "$p1" ] || [ -z "$p2" ] && return
    [ "$p1" -eq "$p2" ] && return

    # Validate bounds
    local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc -U -w 1 "$HOME/.mpv-socket")
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
    echo '{"command": ["playlist-clear"]}' | nc -U -w 1 "$HOME/.mpv-socket" > /dev/null
    echo -e "${C_PINK}🧹 Queue cleared.${C_RESET}"
    save_current_playlist true >/dev/null 2>&1 & disown
}

cmd_shuffle() {
    local mode="$1"
    if [ "$mode" == "list" ] || [ "$mode" == "all" ]; then
        echo '{"command": ["playlist-shuffle"]}' | nc -U -w 1 "$HOME/.mpv-socket" > /dev/null
        echo -e "${C_PINK}🔀 Playlist entries shuffled.${C_RESET}"
        save_current_playlist true >/dev/null 2>&1 & disown
    else
        # Toggle shuffle property
        local current=$(echo '{ "command": ["get_property", "shuffle"] }' | nc -U -w 1 "$HOME/.mpv-socket" 2>/dev/null | jq -r '.data // "false"')
        if [ "$current" == "true" ]; then
            echo '{ "command": ["set_property", "shuffle", false] }' | nc -U -w 1 "$HOME/.mpv-socket" > /dev/null
            echo -e "${C_ORANGE}🔀 Shuffle Mode: ${C_WHITE}OFF${C_RESET}"
        else
            echo '{ "command": ["set_property", "shuffle", true] }' | nc -U -w 1 "$HOME/.mpv-socket" > /dev/null
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
        local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc -U -w 1 "$HOME/.mpv-socket")
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
            echo "{ \"command\": [\"playlist-remove\", $idx] }" | nc -U -w 1 "$HOME/.mpv-socket" > /dev/null
        done
        
        echo -e "${C_GREEN}✨ Cleaned up $count duplicates.${C_RESET}"
        save_current_playlist true >/dev/null 2>&1 & disown
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
        local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc -U -w 1 "$HOME/.mpv-socket")
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
            echo "{ \"command\": [\"playlist-remove\", $idx] }" | nc -U -w 1 "$HOME/.mpv-socket" > /dev/null
            ((removed_count++))
        done
        
        local alive_count=$((total_count - removed_count))
        local unit="tracks"
        [ "$removed_count" -eq 1 ] && unit="track"
        
        echo -e "${C_PINK}✨ Removed ${C_ORANGE}${removed_count}${C_PINK} dead/junk ${unit}.${C_RESET}"
        echo -e "${C_TEAL}📊 Status: ${C_CYAN}${alive_count}${C_RESET} Alive | ${C_PINK}${removed_count}${C_RESET} Removed"
        save_current_playlist true >/dev/null 2>&1 & disown
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
    local count=$(echo '{ "command": ["get_property", "playlist-count"] }' | nc -U -w 1 "$HOME/.mpv-socket" 2>/dev/null | jq -r '.data // 0')
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
    
    # Auto-resume if MPV was idle at the end of the queue (Play new index)
    check_and_resume "$count"
    
    # Force unpause just in case check_and_resume missed the idle state window
    echo '{ "command": ["set_property", "pause", false] }' | nc -U -w 1 "$HOME/.mpv-socket" > /dev/null
    save_current_playlist true >/dev/null 2>&1 & disown
}

# --- AUTO MODE LOGIC (24/7 Zero-Gap Discovery) ---

auto_queue_related() {
    local input_title="$1"; local input_filename="$2"; local force_fetch="${3:-false}"
    local auto_file="$HOME/.cache/mpv/auto_enabled"
    local debug_log="$HOME/.cache/mpv/auto_debug.log"
    
    [ ! -f "$auto_file" ] && return

    # --- PROTOCOL: Liveness Check ---
    if [ "$MPV_RUNNING" = false ] && [ "$force_fetch" != "true" ]; then
        return
    fi

    # --- PROTOCOL: Status & Loop Respect ---
    local raw_status=$(echo -e '{"command":["get_property","playlist-count"]}\n{"command":["get_property","playlist-pos"]}\n{"command":["get_property","idle-active"]}\n{"command":["get_property","loop-playlist"]}\n{"command":["get_property","loop-file"]}' | nc -U -w 1 "$HOME/.mpv-socket" 2>/dev/null | jq -s -j -r '
        map(select(.event == null)) |
        (.[0].data // 0), "\t", (if .[1].data == null then -1 else .[1].data end), "\t", (.[2].data // "false"), "\t", (.[3].data // "no"), "\t", (.[4].data // "no")
    ' 2>/dev/null)
    
    if [ -z "$raw_status" ]; then return; fi
    IFS=$'\t' read -r count pos idle loop_p loop_f <<< "$raw_status"

    # PROTOCOL 3: Respect Single Track Loop (Abort discovery if looping file)
    if [ "$loop_f" != "no" ]; then
        echo "[$(date +%T)] [Abort] Track loop active ($loop_f)." >> "$debug_log"
        return
    fi

    if [ "$force_fetch" != "true" ]; then
        # PROTOCOL 2 & 4: Intelligent Discovery Timing
        # Only fetch if we have < 2 songs remaining in the "Discovery Buffer"
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

    # --- PROTOCOL 5 & 6: Seed & Priority Determination (Seed Diversity) ---
    local history_file="$HOME/.cache/mpv/auto_history"
    [ ! -f "$history_file" ] && touch "$history_file"

    # Priority 1: Use Provided Input (Explicit seed from removal or manual trigger)
    # Priority 2: Random Seed from Queue (Diversity Mode)
    if [ -z "$input_filename" ] && [ "$count" -gt 0 ]; then
        # Pick a random index from the entire queue
        # We give a 70% chance to the "recent" half of the queue to maintain some flow
        # but 30% chance to anything in the queue for true discovery.
        local target_idx=0
        if [ "$count" -gt 1 ]; then
            if [ $((RANDOM % 10)) -lt 7 ]; then
                # Recent half (roughly)
                local half=$((count / 2))
                target_idx=$(( (RANDOM % (count - half)) + half ))
            else
                # Any track
                target_idx=$(( RANDOM % count ))
            fi
        fi
        
        local seed_json=$(echo "{\"command\":[\"get_property\", \"playlist/$target_idx\"]}" | nc -U -w 1 "$HOME/.mpv-socket" 2>/dev/null | jq -r '.data // empty')
        input_filename=$(echo "$seed_json" | jq -r '.filename // ""')
        input_title=$(echo "$seed_json" | jq -r '.title // ""')
        echo "[$(date +%T)] [Seed] Diversity Pick: Index $target_idx (${input_title:-Unknown})" >> "$debug_log"
    fi
    
    # Priority 3: Default Discovery (Empty Queue)
    local is_default_search=false
    if [ -z "$input_filename" ] || [[ "$input_filename" =~ (😴💤|null) ]]; then
        is_default_search=true
        echo "[$(date +%T)] [Seed] Queue Empty. Shifting to Default Priority (Popular Songs)." >> "$debug_log"
    fi

    local seed_id=""
    if [[ "$input_filename" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]]; then
        seed_id="${BASH_REMATCH[2]}"
    fi

    # --- 2. Candidate Discovery (Protocol 5: Related to Artist/Genre/Popularity) ---
    local fields="%(webpage_url)s"$'\t'"%(title)s"$'\t'"%(uploader)s"$'\t'"%(duration_string)s"
    local candidates=""

    if [ "$is_default_search" = false ] && [ -n "$seed_id" ]; then
        echo "[$(date +%T)] [Discovery] Mix for Seed ID: $seed_id" >> "$debug_log"
        candidates=$(run_with_timeout 25s yt-dlp --yes-playlist --print "$fields" --flat-playlist --no-warnings --skip-download --playlist-end 15 "https://www.youtube.com/watch?v=${seed_id}&list=RDAMVM${seed_id}" 2>/dev/null)
    fi

    if [ -z "$candidates" ]; then
        local query="popular music"
        [ "$is_default_search" = false ] && query="related to ${input_title:-music}"
        echo "[$(date +%T)] [Discovery] Search for: $query" >> "$debug_log"
        candidates=$(run_with_timeout 25s yt-dlp --print "$fields" --no-warnings --skip-download --playlist-end 15 "ytmsearch15:${query}" 2>/dev/null)
    fi
    
    if [ -z "$candidates" ]; then
        touch "$HOME/.cache/mpv/auto_failed"
        return
    fi

    # --- 3. Deduplication ---
    local pl_json=$(echo '{"command":["get_property","playlist"]}' | nc -U -w 2 "$HOME/.mpv-socket" 2>/dev/null)
    local cur_ids=$(echo "$pl_json" | jq -r '.data[].filename' | grep -oP '(?<=[v=be/])[a-zA-Z0-9_-]{11}' | sort -u)

    declare -a pool_u; declare -a pool_t; declare -a pool_a; declare -a pool_d
    while IFS=$'\t' read -r url t a d; do
        [ -z "$url" ] || [ "$url" == "null" ] && continue
        local c_id=""
        [[ "$url" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]] && c_id="${BASH_REMATCH[2]}"
        
        [ -n "$seed_id" ] && [ "$c_id" == "$seed_id" ] && continue
        [ -n "$c_id" ] && echo "$cur_ids" | grep -qx "$c_id" && continue
        grep -qx "$c_id" "$history_file" 2>/dev/null && continue
        
        pool_u+=("$url"); pool_t+=("$t"); pool_a+=("$a"); pool_d+=("$d")
    done <<< "$candidates"

    # --- 4. Queue Selection (Protocol 1 & 6: Respect User Preference) ---
    if [ ${#pool_u[@]} -gt 0 ]; then
        # Double-check socket before final action
        if ! [ -S "$HOME/.mpv-socket" ]; then return; fi
        
        local r=$((RANDOM % ${#pool_u[@]})); [ "$r" -gt 5 ] && r=$((RANDOM % 5))
        
        echo "[$(date +%T)] [Success] Queuing: ${pool_t[$r]}" >> "$debug_log"
        queue_item_ipc "${pool_u[$r]}" "${pool_t[$r]}" "${pool_a[$r]}" "${pool_d[$r]}"
        
        [[ "${pool_u[$r]}" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]] && echo "${BASH_REMATCH[2]}" >> "$history_file"
        tail -n 100 "$history_file" > "$history_file.tmp" && mv "$history_file.tmp" "$history_file"
        
        touch "$HOME/.cache/mpv/auto_cooldown"
        ( sleep 15; rm -f "$HOME/.cache/mpv/auto_cooldown" ) & disown
    fi
}
