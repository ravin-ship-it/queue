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
    load_auto_tracks_to_memory
    load_liked_tracks_to_memory
    load_disliked_tracks_to_memory

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
        
        # Track Status Badges (🩷 | Liked, 💔 | Disliked, Ⓐ | Auto-Discovered)
        local badges=$(get_track_badges "$CLEAN_FILENAME" "$vid_id")

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
            # Truncate title to fit terminal while keeping artist/duration and badges
            local index_w=${#i}
            local meta_w=$(get_visual_width "$(strip_colors "$artist_part$dur_part$badges")")
            # INNER_WIDTH is (TERM_WIDTH - 6) for borders and padding
            local title_max_w=$((TERM_WIDTH - index_w - meta_w - 13))
            [ "$title_max_w" -lt 15 ] && title_max_w=15
            
            local final_title=$(truncate_text "$DISPLAY_TITLE" "$title_max_w")
            printf -v LINE_CONTENT "%s%s. %s%s%s%s%s%s" "$ind" "${C_ORANGE}$i${C_RESET}" "$badges" "$title_color" "$final_title" "${C_RESET}" "$artist_part" "$dur_part"
            print_boxed_line "$LINE_CONTENT"
        else
            # Simple format for FZF or Raw output
            printf "%s%s. %s%s%s%s%s%s\n" "$ind" "${C_ORANGE}$i${C_RESET}" "$badges" "$fzf_title_prefix" "$DISPLAY_TITLE" "$fzf_title_suffix" "$artist_part" "$dur_part"
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

cmd_like() {
    local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)

    if [ "$#" -eq 0 ] || [ -z "$1" ]; then
        # Default: current playing track
        local item_json=$(echo "$track_info" | jq -s -c 'map(select(.event == null)) | .[0].data[] | select(.current) // empty' 2>/dev/null)
        local filename=$(echo "$item_json" | jq -r '.filename // ""')
        local title=$(echo "$item_json" | jq -r '.title // ""')
        if [ -z "$filename" ]; then
            echo -e "${C_PINK}🔇 No track currently playing to like.${C_RESET}"
            return 1
        fi
        mark_track_liked "$filename" "$title"
        echo -e "${C_PINK}🩷 Liked & Saved to Liked Songs:${C_RESET} ${C_CYAN}${title:-$filename}${C_RESET}"
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
            mark_track_liked "$filename" "$title"
            echo -e "${C_PINK}🩷 Liked & Saved to Liked Songs:${C_RESET} ${C_CYAN}${title:-$filename}${C_RESET}"
        else
            local cached_title=$(get_cached_title "$target")
            if [ -n "$cached_title" ]; then
                mark_track_liked "$target" "$cached_title"
                echo -e "${C_PINK}🩷 Liked & Saved to Liked Songs:${C_RESET} ${C_CYAN}${cached_title}${C_RESET}"
            else
                echo -e "${C_PINK}🔍🤷 No track matching [${C_ORANGE}${target}${C_PINK}] found to like.${C_RESET}"
            fi
        fi
    done
}

cmd_unlike() {
    local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)

    if [ "$#" -eq 0 ] || [ -z "$1" ]; then
        local item_json=$(echo "$track_info" | jq -s -c 'map(select(.event == null)) | .[0].data[] | select(.current) // empty' 2>/dev/null)
        local filename=$(echo "$item_json" | jq -r '.filename // ""')
        local title=$(echo "$item_json" | jq -r '.title // ""')
        if [ -n "$filename" ] && is_liked_track "$filename"; then
            unmark_track_liked "$filename"
            echo -e "${C_GRAY}🤍 Removed from Liked Songs:${C_RESET} ${C_CYAN}${title:-$filename}${C_RESET}"
            return 0
        elif [ -n "$filename" ] && is_disliked_track "$filename"; then
            unmark_track_disliked "$filename"
            echo -e "${C_GREEN}🤍 Removed from Dislike List & Whitelisted:${C_RESET} ${C_CYAN}${title:-$filename}${C_RESET}"
            return 0
        else
            cmd_liked_list
            return $?
        fi
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
            filename="$target"
            title="$target"
        fi

        if [ -n "$filename" ]; then
            local was_liked=false
            local was_disliked=false
            is_liked_track "$filename" && was_liked=true
            is_disliked_track "$filename" && was_disliked=true

            unmark_track_liked "$filename"
            unmark_track_disliked "$filename"

            if [ "$was_liked" = true ]; then
                echo -e "${C_GRAY}🤍 Removed from Liked Songs:${C_RESET} ${C_CYAN}${title:-$filename}${C_RESET}"
            elif [ "$was_disliked" = true ]; then
                echo -e "${C_GREEN}🤍 Removed from Dislike List & Whitelisted:${C_RESET} ${C_CYAN}${title:-$filename}${C_RESET}"
            else
                echo -e "${C_GRAY}🤍 Cleared reaction for:${C_RESET} ${C_CYAN}${title:-$filename}${C_RESET}"
            fi
        fi
    done
}

cmd_liked_list() {
    mkdir -p "$(dirname "$LIKED_PLAYLIST_FILE")" 2>/dev/null
    touch "$LIKED_PLAYLIST_FILE" "$LIKED_TRACKS_FILE" 2>/dev/null
    load_liked_tracks_to_memory

    if [ ! -t 0 ]; then
        if [ -s "$LIKED_PLAYLIST_FILE" ]; then
            echo -e "${C_PURPLE}🪷 Liked Songs Playlist:${C_RESET}"
            local i=1
            while IFS= read -r url; do
                [ -z "$url" ] && continue
                local clean="$url"
                [[ "$url" =~ ^http ]] && clean=$(echo "$url" | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\\t.*//; s/\t.*//')
                local tit=$(get_cached_title "$clean")
                [ -z "$tit" ] && tit=$(basename "$clean")
                echo -e "  ${C_ORANGE}${i}.${C_RESET} 🩷 | ${C_CYAN}${tit}${C_RESET}"
                ((i++))
            done < "$LIKED_PLAYLIST_FILE"
        else
            echo -e "${C_GRAY}ℹ️ Liked songs playlist is currently empty.${C_RESET}"
        fi
        return 0
    fi

    while true; do
        local items=""
        local count=0
        if [ -f "$LIKED_PLAYLIST_FILE" ] && [ -s "$LIKED_PLAYLIST_FILE" ]; then
            local i=1
            while IFS= read -r url; do
                [ -z "$url" ] && continue
                local clean="$url"
                [[ "$url" =~ ^http ]] && clean=$(echo "$url" | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\\t.*//; s/\t.*//')
                local tit=$(get_cached_title "$clean")
                [ -z "$tit" ] && tit=$(basename "$clean")
                local art=$(get_cached_artist "$clean")
                local dur=$(get_cached_duration "$clean")
                local art_part=""
                local dur_part=""
                [ -n "$art" ] && [ "$art" != "null" ] && art_part=" ${C_GRAY}by${C_RESET} ${C_LIGHT_PINK}${art}${C_RESET}"
                [ -n "$dur" ] && [ "$dur" != "null" ] && [ "$dur" != "0:00" ] && dur_part=" ${C_ORANGE}[${dur}]${C_RESET}"
                items+="${C_ORANGE}${i}${C_RESET}. 🩷 | ${C_CYAN}${tit}${C_RESET}${art_part}${dur_part}"$'\t'"${clean}"$'\t'"${tit}"$'\n'
                ((i++))
                ((count++))
            done < "$LIKED_PLAYLIST_FILE"
        fi

        local fzf_input=""
        [ "$count" -gt 0 ] && fzf_input+="  ▶️   Play All Liked Songs (New Queue)\n"
        [ "$count" -gt 0 ] && fzf_input+="  🔀  Shuffle Play All Liked Songs\n"
        [ "$count" -gt 0 ] && fzf_input+="  ➕  Append All Liked Songs to Active Queue\n"
        fzf_input+="  ✚  Add Track to Liked Songs...\n"
        [ "$count" -gt 0 ] && fzf_input+="  🗑️   Clear Entire Liked Songs Playlist ($count tracks)\n"
        fzf_input+="$items"

        local LINE=$(get_fzf_divider)
        local status_icons=$(get_player_status_icons)
        local header="${C_PURPLE}🪷 Liked Songs Hub${C_RESET} ${C_GRAY}(${count} tracks • ENTER: Action, TAB: Multi)${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"
        local l_prompt="🎵 ${C_TEAL}Liked Songs${status_icons}${C_RESET} > "

        local sel=$(echo -ne "$fzf_input" | fzf --multi --ansi --height=100% --layout=reverse --border \
            --header="$header" \
            --delimiter=$'\t' --with-nth=1 \
            --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
            --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
            $FZF_COLOR_OPTS \
            --info=inline-right --prompt="$l_prompt")

        [ -z "$sel" ] && break

        # Case: Play All Liked Songs
        if echo "$sel" | grep -q "Play All Liked Songs"; then
            cmd_playlist_load "Liked" "Replace (New Queue)"
            break
        fi

        # Case: Shuffle Play All
        if echo "$sel" | grep -q "Shuffle Play All"; then
            cmd_playlist_load "Liked" "Shuffle & Replace"
            break
        fi

        # Case: Append All Liked Songs
        if echo "$sel" | grep -q "Append All Liked"; then
            cmd_playlist_load "Liked" "Append to Current Queue"
            break
        fi

        # Case: Clear Entire Liked Songs Playlist
        if echo "$sel" | grep -q "Clear Entire Liked"; then
            > "$LIKED_PLAYLIST_FILE"
            > "$LIKED_TRACKS_FILE"
            LIKED_TRACKS_MEM=()
            echo -e "${C_GREEN}🧹 Liked Songs playlist cleared.${C_RESET}"
            continue
        fi

        # Case: Add Track to Liked Songs
        if echo "$sel" | grep -q "Add Track to Liked Songs"; then
            local LINE=$(get_fzf_divider)
            local add_header="${C_PURPLE}🪷 How would you like to add track(s) to Liked Songs?${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"
            local add_prompt="🎵 ${C_TEAL}Add Liked${C_RESET} > "
            local add_action=$(echo -e "  🎵  Currently Playing Track\n  📋  Pick from Current Queue\n  🕒  Pick from Recent History\n  🔍  Search YouTube to Like\n  🔗  Enter URL or Video ID manually" | \
                fzf --height=100% --layout=reverse --border --info=inline-right \
                $FZF_COLOR_OPTS \
                --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
                --header="$add_header" \
                --prompt="$add_prompt")

            [ -z "$add_action" ] && continue

            if echo "$add_action" | grep -q "Currently Playing"; then
                cmd_like
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
                        local b_tag=$(get_track_badges "$fn")
                        q_items+="${C_ORANGE}$((k+1))${C_RESET}. ${b_tag}${C_CYAN}${tt}${C_RESET}"$'\t'"${fn}"$'\t'"${tt}"$'\n'
                    done
                    local LINE=$(get_fzf_divider)
                    local q_header="${C_PURPLE}🪷 Select Track(s) from Current Queue to Like${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"
                    local q_prompt="🎵 ${C_TEAL}Queue Like${C_RESET} > "
                    local q_sel=$(echo -ne "$q_items" | fzf --multi --ansi --height=100% --layout=reverse --border \
                        --delimiter=$'\t' --with-nth=1 \
                        --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
                        $FZF_COLOR_OPTS \
                        --header="$q_header" \
                        --prompt="$q_prompt")
                    if [ -n "$q_sel" ]; then
                        while IFS= read -r q_line; do
                            [ -z "$q_line" ] && continue
                            local q_url=$(echo "$q_line" | awk -F'\t' '{print $2}')
                            cmd_like "$q_url"
                        done <<< "$q_sel"
                    fi
                fi
            elif echo "$add_action" | grep -q "Recent History"; then
                local hist_file="$HOME/.cache/mpv/auto_history"
                if [ ! -s "$hist_file" ]; then
                    echo -e "${C_PINK}ℹ️ Recent history is currently empty.${C_RESET}"
                else
                    local h_items=""
                    local h_idx=1
                    while IFS= read -r h_id; do
                        [ -z "$h_id" ] && continue
                        local h_tit=$(get_cached_title "$h_id")
                        [ -z "$h_tit" ] && h_tit=$(get_cached_title "https://www.youtube.com/watch?v=$h_id")
                        [ -z "$h_tit" ] && h_tit="Track ($h_id)"
                        h_items+="${C_ORANGE}${h_idx}${C_RESET}. ${C_CYAN}${h_tit}${C_RESET} ${C_GRAY}[${h_id}]${C_RESET}"$'\t'"https://www.youtube.com/watch?v=${h_id}"$'\t'"${h_tit}"$'\n'
                        ((h_idx++))
                    done < <(tail -n 30 "$hist_file" | tac)
                    local LINE=$(get_fzf_divider)
                    local h_header="${C_PURPLE}🪷 Select Track(s) from Recent History to Like${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"
                    local h_prompt="🎵 ${C_TEAL}History Like${C_RESET} > "
                    local h_sel=$(echo -ne "$h_items" | fzf --multi --ansi --height=100% --layout=reverse --border \
                        --delimiter=$'\t' --with-nth=1 \
                        --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
                        $FZF_COLOR_OPTS \
                        --header="$h_header" \
                        --prompt="$h_prompt")
                    if [ -n "$h_sel" ]; then
                        while IFS= read -r h_line; do
                            [ -z "$h_line" ] && continue
                            local h_url=$(echo "$h_line" | awk -F'\t' '{print $2}')
                            cmd_like "$h_url"
                        done <<< "$h_sel"
                    fi
                fi
            elif echo "$add_action" | grep -q "Search YouTube"; then
                local s_query=$(prompt_input "Enter search query to like: " "Search")
                if [ -n "$s_query" ]; then
                    local s_tmp=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/q_like_$$.tmp")
                    ytdl_search_opts=("--extractor-args" "youtube:player_client=visionos,android,web" "--flat-playlist" "--print" "%(title)s\t%(webpage_url)s\t%(duration_string)s\t%(uploader)s" "--no-warnings" "--skip-download")
                    command -v node >/dev/null 2>&1 && ytdl_search_opts+=("--js-runtimes" "node")
                    run_with_timeout 25 yt-dlp "${ytdl_search_opts[@]}" "ytsearch15:${s_query}" > "$s_tmp" 2>/dev/null
                    if [ -s "$s_tmp" ]; then
                        local s_items=""
                        local s_idx=1
                        while IFS=$'\t' read -r stitle surl sdur sart; do
                            [ -z "$surl" ] && continue
                            s_items+="${C_ORANGE}${s_idx}${C_RESET}. ${C_CYAN}${stitle}${C_RESET} ${C_GRAY}by${C_RESET} ${C_LIGHT_PINK}${sart}${C_RESET}"$'\t'"${surl}"$'\t'"${stitle}"$'\n'
                            ((s_idx++))
                        done < "$s_tmp"
                        rm -f "$s_tmp"
                        local LINE=$(get_fzf_divider)
                        local s_header="${C_PURPLE}🪷 Select Track(s) to Like${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"
                        local s_prompt="🎵 ${C_TEAL}Search Like${C_RESET} > "
                        local s_sel=$(echo -ne "$s_items" | fzf --multi --ansi --height=100% --layout=reverse --border \
                            --delimiter=$'\t' --with-nth=1 \
                            --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
                            $FZF_COLOR_OPTS \
                            --header="$s_header" \
                            --prompt="$s_prompt")
                        if [ -n "$s_sel" ]; then
                            while IFS= read -r s_line; do
                                [ -z "$s_line" ] && continue
                                local chosen_url=$(echo "$s_line" | awk -F'\t' '{print $2}')
                                cmd_like "$chosen_url"
                            done <<< "$s_sel"
                        fi
                    else
                        echo -e "${C_PINK}⚠️ No results found for \"$s_query\".${C_RESET}"
                        rm -f "$s_tmp"
                    fi
                fi
            elif echo "$add_action" | grep -q "Enter URL"; then
                local u_target=$(prompt_input "Enter Video URL or ID: " "URL/ID")
                [ -n "$u_target" ] && cmd_like "$u_target"
            fi
            continue
        fi

        # Case: User selected one or more tracks from the list
        local sel_count=$(echo "$sel" | wc -l)
        local LINE=$(get_fzf_divider)
        local act_header="${C_PURPLE}🪷 Action for ${C_CYAN}${sel_count}${C_PURPLE} Liked Track(s)${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"
        local act_prompt="🎵 ${C_TEAL}Action${status_icons}${C_RESET} > "
        local track_action=$(echo -e "  |>  Play Selected\n  ➕  Append to Active Queue\n  🤍  Unlike / Remove from Liked Songs\n  📥  Download Track(s)" | \
            fzf --height=100% --layout=reverse --border --info=inline-right \
            $FZF_COLOR_OPTS \
            --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
            --header="$act_header" \
            --prompt="$act_prompt")

        [ -z "$track_action" ] && continue

        if echo "$track_action" | grep -q "Play Selected"; then
            declare -a t_urls
            while IFS= read -r row; do
                local u=$(echo "$row" | awk -F'\t' '{print $2}')
                [ -n "$u" ] && t_urls+=("$u")
            done <<< "$sel"
            if [ ${#t_urls[@]} -gt 0 ]; then
                PLAYLIST_URLS=("${t_urls[@]}")
                DO_NEW_QUEUE=true
                execute_batch
                break
            fi
        elif echo "$track_action" | grep -q "Append to Active Queue"; then
            while IFS= read -r row; do
                local u=$(echo "$row" | awk -F'\t' '{print $2}')
                local t=$(echo "$row" | awk -F'\t' '{print $3}')
                if [ -n "$u" ]; then
                    queue_item_ipc "$u" "$t" "" ""
                fi
            done <<< "$sel"
            echo -e "${C_GREEN}✅ Appended ${sel_count} liked track(s) to queue.${C_RESET}"
            break
        elif echo "$track_action" | grep -q "Unlike"; then
            while IFS= read -r row; do
                local u=$(echo "$row" | awk -F'\t' '{print $2}')
                [ -n "$u" ] && unmark_track_liked "$u"
            done <<< "$sel"
            echo -e "${C_GREEN}🤍 Removed ${sel_count} track(s) from Liked Songs.${C_RESET}"
            continue
        elif echo "$track_action" | grep -q "Download"; then
            while IFS= read -r row; do
                local u=$(echo "$row" | awk -F'\t' '{print $2}')
                [ -n "$u" ] && cmd_download "$u"
            done <<< "$sel"
            break
        fi
    done
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
        mark_track_disliked "$filename" "$title"
        echo -e "${C_PINK}💔 Disliked & Blacklisted from Auto Mode:${C_RESET} ${C_CYAN}${title:-$filename}${C_RESET}"
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
            mark_track_disliked "$filename" "$title"
            echo -e "${C_PINK}💔 Disliked & Blacklisted from Auto Mode:${C_RESET} ${C_CYAN}${title:-$filename}${C_RESET}"
        else
            local cached_title=$(get_cached_title "$target")
            if [ -n "$cached_title" ]; then
                mark_track_disliked "$target" "$cached_title"
                echo -e "${C_PINK}💔 Disliked & Blacklisted from Auto Mode:${C_RESET} ${C_CYAN}${cached_title}${C_RESET}"
            else
                echo -e "${C_PINK}🔍🤷 No track matching [${C_ORANGE}${target}${C_PINK}] found to dislike.${C_RESET}"
            fi
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

            local rem_v_id=""
            [[ "$filename" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]] && rem_v_id="${BASH_REMATCH[2]}"
            if [ -n "$rem_v_id" ]; then
                echo "$rem_v_id" >> "$HOME/.cache/mpv/auto_removed_recent"
                tail -n 30 "$HOME/.cache/mpv/auto_removed_recent" > "$HOME/.cache/mpv/auto_removed_recent.tmp" 2>/dev/null && mv "$HOME/.cache/mpv/auto_removed_recent.tmp" "$HOME/.cache/mpv/auto_removed_recent"
            fi

            echo "{ \"command\": [\"playlist-remove\", $((idx - 1))] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
            if [ "$also_dislike" = true ]; then
                mark_track_disliked "$filename" "$mpv_title"
                echo -e "${C_PINK}💔✖ Removed & Blacklisted ${formatted_track}${C_RESET}"
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
            # AND auto-mode is enabled, discover and queue the next track with a FRESH rotated seed
            if { [ "$rem_idle" == "true" ] || [ "$rem_pos" -eq -1 ]; } && [ -f "$HOME/.cache/mpv/auto_enabled" ]; then
                echo -ne "${C_GRAY}⏳ Discovering related track...${C_RESET}\r"
                auto_queue_related "" "" true
                echo -ne "\033[2K\r"
            elif [ -f "$HOME/.cache/mpv/auto_enabled" ]; then
                # Queue still has tracks and is continuing playback, trigger auto-discovery with fresh seed
                ( auto_queue_related ) >/dev/null 2>&1 & disown
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
            
            # Background auto-queue check with fresh seed
            ( auto_queue_related ) >/dev/null 2>&1 & disown
        fi
        
        # Delay save to avoid racing with mpv during track transition
        ( sleep 2; save_current_playlist true ) >/dev/null 2>&1 & disown
    fi
}
cmd_move() {
    local from=$1
    local to=$2
    if [ -z "$from" ] || [ -z "$to" ]; then
        echo -e "${C_PINK}⚠️ Usage: ${C_WHITE}q -mv <from> <to>${C_RESET}"
        return
    fi

    # Fetch track info for pretty logging
    local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET")
    local count=$(echo "$track_info" | jq -s -r 'map(select(.event == null)) | .[0].data | length // 0' 2>/dev/null); : "${count:=0}"

    if [ "$count" -eq 0 ]; then
        echo -e "${C_ORANGE}⚠️ Queue is empty.${C_RESET}"
        return
    fi

    if ! [[ "$from" =~ ^[0-9]+$ ]] || ! [[ "$to" =~ ^[0-9]+$ ]]; then
        echo -e "${C_PINK}🚫 Indices must be numbers. Max Track ${C_WHITE}[${C_ORANGE}${count}${C_WHITE}]${C_RESET}"
        return
    fi

    if [ "$from" -gt "$count" ] || [ "$from" -lt 1 ]; then
        echo -e "${C_PINK}🚫 Track ${C_WHITE}[${C_ORANGE}${from}${C_WHITE}] ${C_PINK}does not exist. Max Track ${C_WHITE}[${C_ORANGE}${count}${C_WHITE}]${C_RESET}"
        return
    fi

    # Cap 'to' index at bounds
    [ "$to" -gt "$count" ] && to="$count"
    [ "$to" -lt 1 ] && to=1

    if [ "$from" -eq "$to" ]; then
        echo -e "${C_PINK}⚠️ Track ${C_WHITE}[${C_ORANGE}${from}${C_WHITE}] ${C_PINK}is already at destination ${C_WHITE}[${C_ORANGE}${to}${C_WHITE}]${C_PINK}.${C_RESET}"
        return
    fi

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
    if [ -z "$p1" ] || [ -z "$p2" ]; then
        echo -e "${C_PINK}⚠️ Usage: ${C_WHITE}q -sw <index1> <index2>${C_RESET}"
        return
    fi

    # Validate bounds
    local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET")
    local count=$(echo "$track_info" | jq -s -r 'map(select(.event == null)) | .[0].data | length // 0' 2>/dev/null); : "${count:=0}"

    if [ "$count" -eq 0 ]; then
        echo -e "${C_ORANGE}⚠️ Queue is empty.${C_RESET}"
        return
    fi

    if ! [[ "$p1" =~ ^[0-9]+$ ]] || ! [[ "$p2" =~ ^[0-9]+$ ]]; then
        echo -e "${C_PINK}🚫 Indices must be numbers. Max Track ${C_WHITE}[${C_ORANGE}${count}${C_WHITE}]${C_RESET}"
        return
    fi

    if [ "$p1" -eq "$p2" ]; then
        echo -e "${C_PINK}⚠️ Indices are identical ${C_WHITE}[${C_ORANGE}${p1}${C_WHITE}]${C_PINK}. Nothing to swap.${C_RESET}"
        return
    fi

    local p1_invalid=false
    local p2_invalid=false
    if [ "$p1" -gt "$count" ] || [ "$p1" -lt 1 ]; then p1_invalid=true; fi
    if [ "$p2" -gt "$count" ] || [ "$p2" -lt 1 ]; then p2_invalid=true; fi

    if [ "$p1_invalid" = true ] && [ "$p2_invalid" = true ]; then
        echo -e "${C_PINK}🚫 Tracks ${C_WHITE}[${C_ORANGE}${p1}${C_WHITE}]${C_PINK} and ${C_WHITE}[${C_ORANGE}${p2}${C_WHITE}] ${C_PINK}do not exist. Max Track ${C_WHITE}[${C_ORANGE}${count}${C_WHITE}]${C_RESET}"
        return
    elif [ "$p1_invalid" = true ]; then
        echo -e "${C_PINK}🚫 Track ${C_WHITE}[${C_ORANGE}${p1}${C_WHITE}] ${C_PINK}does not exist. Max Track ${C_WHITE}[${C_ORANGE}${count}${C_WHITE}]${C_RESET}"
        return
    elif [ "$p2_invalid" = true ]; then
        echo -e "${C_PINK}🚫 Track ${C_WHITE}[${C_ORANGE}${p2}${C_WHITE}] ${C_PINK}does not exist. Max Track ${C_WHITE}[${C_ORANGE}${count}${C_WHITE}]${C_RESET}"
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
    clear_auto_tracks
    echo '{"command": ["playlist-clear"]}' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
    echo -e "${C_PINK}🧹 Queue cleared.${C_RESET}"
    save_current_playlist true true >/dev/null 2>&1 & disown
}

cmd_shuffle() {
    if [ "$MPV_RUNNING" = false ]; then echo -e "${C_PINK}😴💤 MPV isn't running... it must be taking a nap${C_RESET}"; return; fi
    local mode="$1"
    if [ "$mode" == "list" ] || [ "$mode" == "all" ]; then
        echo '{"command": ["playlist-shuffle"]}' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
        echo -e "${C_PINK}🔀 Playlist entries shuffled.${C_RESET}"
        save_current_playlist true >/dev/null 2>&1 & disown
    else
        # Toggle shuffle property
        local current=$(echo '{ "command": ["get_property", "shuffle"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // "false"')
        local hist_file
        hist_file=$(get_shuffle_history_file)
        if [ "$current" == "true" ]; then
            echo '{ "command": ["set_property", "shuffle", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
            rm -f "$hist_file" "$HOME/.cache/mpv/shuffle_history" 2>/dev/null
            if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
                send_android_mpv_cmd "shuffle false"
            fi
            echo -e "${C_ORANGE}🔀 Shuffle Mode: ${C_WHITE}OFF${C_RESET}"
        else
            echo '{ "command": ["set_property", "shuffle", true] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null
            mkdir -p "$(dirname "$hist_file")" 2>/dev/null
            : > "$hist_file"
            : > "$HOME/.cache/mpv/shuffle_history" 2>/dev/null
            if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
                send_android_mpv_cmd "shuffle true"
            fi
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
    
    # Mark as auto-added track (tagged with Ⓐ)
    mark_track_auto "$clean_url"
    
    # Get current playlist size to determine new index efficiently
    local count=$(echo '{ "command": ["get_property", "playlist-count"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // 0')
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

    local target_path=$(format_path_for_mpv "$clean_url")
    local json_cmd=$(jq -nc --arg path "$target_path" '{"command": ["loadfile", $path, "append-play"]}')
    send_ipc "$json_cmd" > /dev/null

    if [ "$IS_ANDROID" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
        local bridge_port
        bridge_port=$(ensure_android_bridge_running)
        if [ -n "$bridge_port" ]; then
            send_android_mpv_cmd "loadfile http://127.0.0.1:${bridge_port}/track/${count} append"
            curl -s -m 1 "http://127.0.0.1:${bridge_port}/playlist.m3u" >/dev/null 2>&1 & disown
        fi
    fi
    
    # Auto-resume only if MPV was idle at the end of the queue (Play new index)
    check_and_resume "$count"
    
    save_current_playlist true >/dev/null 2>&1 & disown
}

# --- PERSONALIZED AUTO DISCOVERY SUBSYSTEM ---

add_to_auto_blacklist() {
    local target="$1"
    local opt_title="$2"
    mark_track_disliked "$target" "$opt_title"
}

remove_from_auto_blacklist() {
    local target="$1"
    unmark_track_disliked "$target"
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
        [ -z "$cur_id" ] && cur_id="$filename"

        if [ -n "$cur_id" ] && grep -E -q "^${cur_id}([[:blank:]]|$)" "$bl_file" 2>/dev/null; then
            remove_from_auto_blacklist "$cur_id"
            [ -n "$filename" ] && remove_from_auto_blacklist "$filename"
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
        local filename=""

        if [[ "$target" =~ ^[0-9]+$ ]]; then
            local track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)
            local idx=$((target - 1))
            local item_json=$(echo "$track_info" | jq -s -c "map(select(.event == null)) | .[0].data[$idx] // empty" 2>/dev/null)
            filename=$(echo "$item_json" | jq -r '.filename // ""')
            b_title=$(echo "$item_json" | jq -r '.title // ""')
            [[ "$filename" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]] && b_id="${BASH_REMATCH[2]}"
            [ -z "$b_id" ] && b_id="$filename"
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
            [ -n "$filename" ] && remove_from_auto_blacklist "$filename"
            echo -e "${C_GREEN}✨ Removed from Dislike List & Whitelisted:${C_RESET} ${C_CYAN}${b_title:-$b_id}${C_RESET}"
        else
            echo -e "${C_PINK}🔍🤷 Track [${C_ORANGE}${target}${C_PINK}] not found in dislike blacklist.${C_RESET}"
        fi
    done
}

cmd_dislike_list() {
    local bl_file="$HOME/.cache/mpv/auto_blacklist"
    touch "$bl_file" 2>/dev/null

    if [ ! -t 0 ]; then
        if [ -s "$bl_file" ]; then
            echo -e "${C_PURPLE}🪷 Disliked Tracks Blacklist:${C_RESET}"
            local i=1
            while IFS=$'\t' read -r bid btitle; do
                [ -z "$bid" ] && continue
                [ -z "$btitle" ] && btitle=$(get_cached_title "$bid")
                [ -z "$btitle" ] && btitle="Track ($bid)"
                echo -e "  ${C_ORANGE}${i}.${C_RESET} ${C_CYAN}${btitle}${C_RESET} ${C_GRAY}[${bid}]${C_RESET}"
                ((i++))
            done < "$bl_file"
        else
            echo -e "${C_GRAY}ℹ️ Dislike blacklist is empty.${C_RESET}"
        fi
        return 0
    fi

    while true; do
        local items=""
        local count=0
        if [ -s "$bl_file" ]; then
            local i=1
            while IFS=$'\t' read -r bid btitle; do
                [ -z "$bid" ] && continue
                [ -z "$btitle" ] && btitle=$(get_cached_title "$bid")
                [ -z "$btitle" ] && btitle="Track ($bid)"
                items+="${C_ORANGE}${i}${C_RESET}. ${C_CYAN}${btitle}${C_RESET} ${C_GRAY}[${bid}]${C_RESET}"$'\t'"${bid}"$'\t'"${btitle}"$'\n'
                ((i++))
                ((count++))
            done < "$bl_file"
        fi

        local fzf_input=""
        fzf_input+="  ✚  Add Track to Dislike List...\n"
        [ "$count" -gt 0 ] && fzf_input+="  🗑️   Clear Entire Dislike List ($count tracks)\n"
        fzf_input+="$items"

        local LINE=$(get_fzf_divider)
        local status_icons=$(get_player_status_icons)
        local header="${C_PURPLE}🪷 Dislike List Manager${C_RESET} ${C_GRAY}(${count} tracks • ENTER: Remove, TAB: Multi)${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"
        local d_prompt="🎵 ${C_TEAL}Dislike Manager${status_icons}${C_RESET} > "

        local sel=$(echo -ne "$fzf_input" | fzf --multi --ansi --height=100% --layout=reverse --border \
            --header="$header" \
            --delimiter=$'\t' --with-nth=1 \
            --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
            --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
            $FZF_COLOR_OPTS \
            --info=inline-right --prompt="$d_prompt")

        [ -z "$sel" ] && break

        # Case 1: Add Track to Dislike List
        if echo "$sel" | grep -q "Add Track to Dislike List"; then
            local LINE=$(get_fzf_divider)
            local add_header="${C_PURPLE}🪷 How would you like to add track(s) to Dislike List?${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"
            local add_prompt="🎵 ${C_TEAL}Add Dislike${C_RESET} > "
            local add_action=$(echo -e "  🎵  Currently Playing Track\n  📋  Pick from Current Queue\n  🕒  Pick from Recent History\n  🔍  Search YouTube to Dislike\n  🔗  Enter URL or Video ID manually" | \
                fzf --height=100% --layout=reverse --border --info=inline-right \
                $FZF_COLOR_OPTS \
                --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
                --header="$add_header" \
                --prompt="$add_prompt")

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
                        q_items+="${C_ORANGE}$((k+1))${C_RESET}. ${C_CYAN}${tt}${C_RESET}"$'\t'"${fn}"$'\t'"${tt}"$'\n'
                    done
                    local LINE=$(get_fzf_divider)
                    local q_header="${C_PURPLE}🪷 Select Track(s) from Current Queue to Dislike${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"
                    local q_prompt="🎵 ${C_TEAL}Queue Dislike${C_RESET} > "
                    local q_sel=$(echo -ne "$q_items" | fzf --multi --ansi --height=100% --layout=reverse --border \
                        --delimiter=$'\t' --with-nth=1 \
                        --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
                        $FZF_COLOR_OPTS \
                        --header="$q_header" \
                        --prompt="$q_prompt")
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
                        h_items+="${C_ORANGE}${h_idx}${C_RESET}. ${C_CYAN}${h_tit}${C_RESET} ${C_GRAY}[${h_id}]${C_RESET}"$'\t'"${h_id}"$'\t'"${h_tit}"$'\n'
                        ((h_idx++))
                    done < <(tail -n 30 "$hist_file" 2>/dev/null | tac)
                    local LINE=$(get_fzf_divider)
                    local h_header="${C_PURPLE}🪷 Select Track(s) from History to Dislike${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"
                    local h_prompt="🎵 ${C_TEAL}History Dislike${C_RESET} > "
                    local h_sel=$(echo -ne "$h_items" | fzf --multi --ansi --height=100% --layout=reverse --border \
                        --delimiter=$'\t' --with-nth=1 \
                        --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
                        $FZF_COLOR_OPTS \
                        --header="$h_header" \
                        --prompt="$h_prompt")
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
                    local s_tmp=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/q_dislike_$$.tmp")
                    run_with_timeout 25 yt-dlp --extractor-args "youtube:player_client=visionos,android,web" --print "%(webpage_url)s\t%(title)s\t%(uploader)s\t%(duration_string)s" --flat-playlist --no-warnings --skip-download --playlist-end 15 "ytsearch15:${s_query}" > "$s_tmp" 2>/dev/null
                    if [ -s "$s_tmp" ]; then
                        local s_items=""
                        local s_idx=1
                        while IFS=$'\t' read -r su st sa sd; do
                            [ -z "$su" ] && continue
                            s_items+="${C_ORANGE}${s_idx}${C_RESET}. ${st} ${C_GRAY}by${C_RESET} ${C_LIGHT_PINK}${sa}${C_RESET} ${C_ORANGE}[${sd}]${C_RESET}"$'\t'"${su}"$'\t'"${st}"$'\n'
                            ((s_idx++))
                        done < "$s_tmp"
                        local LINE=$(get_fzf_divider)
                        local s_header="${C_PURPLE}🪷 Search Results to Dislike [\"${s_query}\"]${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"
                        local s_prompt="🎵 ${C_TEAL}Search Dislike${C_RESET} > "
                        local s_sel=$(echo -ne "$s_items" | fzf --multi --ansi --height=100% --layout=reverse --border \
                            --delimiter=$'\t' --with-nth=1 \
                            --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
                            $FZF_COLOR_OPTS \
                            --header="$s_header" \
                            --prompt="$s_prompt")
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
            local LINE=$(get_fzf_divider)
            local clr_header="${C_PURPLE}🪷 Clear Entire Dislike List (${count} tracks)?${C_RESET}${NL}${C_GRAY}${LINE}${C_RESET}"
            local clr_prompt="🎵 ${C_TEAL}Confirm Clear${C_RESET} > "
            local confirm=$(echo -e "  ❌  No, Cancel\n  🗑️   Yes, Clear All Dislikes" | \
                fzf --height=100% --layout=reverse --border --info=inline-right \
                $FZF_COLOR_OPTS \
                --header="$clr_header" \
                --prompt="$clr_prompt")
            if echo "$confirm" | grep -q "Yes, Clear"; then
                > "$bl_file"
                DISLIKED_TRACKS_MEM=()
                mirror_to_windows_cache "$bl_file" "auto_blacklist"
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

normalize_artist() {
    local uploader="$1"
    local title="$2"
    local art="$uploader"

    # If uploader is a generic topic channel or vevo/official, extract artist from title if available
    if [[ "$uploader" =~ -[[:space:]]*topic$ ]] || [[ "$uploader" =~ (vevo|records|official)$ ]] || [ -z "$uploader" ] || [ "$uploader" == "null" ]; then
        if [[ "$title" == *" - "* ]]; then
            local cand="${title%% - *}"
            cand=$(echo "$cand" | sed -E 's/^\[[^]]+\][[:space:]]*//; s/^\([^)]+\)[[:space:]]*//')
            [ -n "$cand" ] && art="$cand"
        fi
    fi

    art=$(echo "$art" | tr '[:upper:]' '[:lower:]' | sed -E 's/-[[:space:]]*topic$//; s/[[:space:]]+official$//; s/[[:space:]]+vevo$//; s/[[:space:]]+records$//; s/[[:space:]]+music$//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    echo "$art"
}

normalize_song_title() {
    local t="$1"
    [[ "$t" == *" - "* ]] && t="${t#* - }"
    t=$(echo "$t" | sed -E 's/(\[|\()[^]]*(\]|\))//g' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]/ /g' | awk '{$1=$1};1')
    echo "${t:0:30}"
}

ensure_taste_profile_cached() {
    local taste_file="$HOME/.cache/mpv/auto_taste.cache"
    local now=$(date +%s)
    local last_mtime=$(get_file_mtime "$taste_file")

    # Regenerate if older than 2 hours or missing
    if [ ! -f "$taste_file" ] || [ $((now - last_mtime)) -gt 7200 ]; then
        mkdir -p "$HOME/.cache/mpv"
        python3 -c '
import os, glob, re

playlist_dir = os.path.expanduser("~/.local/share/mpv/playlists")
titles_file = os.path.expanduser("~/.cache/mpv/titles.txt")
taste_file = os.path.expanduser("~/.cache/mpv/auto_taste.cache")

title_cache = {}
if os.path.isfile(titles_file):
    with open(titles_file, "r", errors="ignore") as f:
        for line in f:
            parts = line.strip().split("\t")
            if len(parts) >= 2:
                title_cache[parts[0]] = parts[1]

artists = set()
for p in glob.glob(os.path.join(playlist_dir, "*.txt")):
    with open(p, "r", errors="ignore") as f:
        for line in f:
            url = line.strip()
            title = title_cache.get(url, "")
            if not title:
                continue
            if " - " in title:
                art = title.split(" - ")[0].strip()
                art = re.sub(r"^\[[^]]+\]\s*", "", art)
                art = re.sub(r"^\([^)]+\)\s*", "", art)
                art = re.sub(r"(?i)-[ ]*topic$", "", art)
                art = art.strip().lower()
                if len(art) >= 2 and len(art) <= 40:
                    artists.add(art)

with open(taste_file, "w") as f:
    for a in sorted(artists):
        f.write(a + "\n")
' 2>/dev/null
    fi
}

score_candidate_track() {
    local title="$1"
    local uploader="$2"
    local dur="$3"
    local seed_artist="$4"
    local recent_artists_file="$5"
    local cur_titles_file="$6"
    local taste_file="$7"

    local score=10
    local lower_title=$(echo "$title" | tr '[:upper:]' '[:lower:]')
    local lower_uploader=$(echo "$uploader" | tr '[:upper:]' '[:lower:]')
    local cand_art=$(normalize_artist "$uploader" "$title")
    local base_title=$(normalize_song_title "$title")

    # Hard Reject: Non-music, Spoken Skits, Reviews, Teasers, Reactions
    if [[ "$lower_title" =~ (teaser|trailer|reaction|reacts|review|full[[:space:]]+movie|short[[:space:]]+film|interview|behind[[:space:]]+the[[:space:]]+scenes|bts|episode|ep\.|making[[:space:]]+of) ]]; then
        echo -9999
        return
    fi

    # Duplicate song/cover detection: Reject if identical song title is already in queue
    if [ -n "$base_title" ] && [ ${#base_title} -ge 5 ]; then
        if [ -f "$cur_titles_file" ] && grep -Fqi "$base_title" "$cur_titles_file" 2>/dev/null; then
            echo -9999
            return
        fi
    fi

    # Bonus: Clean Studio Topic upload (+40) - Clean distributor master
    if [[ "$lower_uploader" =~ -[[:space:]]*topic$ ]] || [[ "$lower_title" =~ -[[:space:]]*topic$ ]]; then
        score=$((score + 40))
    fi

    # Bonus: Clean studio audio releases (+35)
    if [[ "$lower_title" =~ (official[[:space:]]+audio|audio[[:space:]]+only|lyric[[:space:]]+video|lyrics|clean[[:space:]]+audio|studio[[:space:]]+version|original[[:space:]]+track) ]]; then
        score=$((score + 35))
    fi

    # Penalty: Music videos without audio/lyric tags (-15)
    if [[ "$lower_title" =~ (official[[:space:]]+music[[:space:]]+video|official[[:space:]]+video) ]] && [[ ! "$lower_title" =~ (audio|lyric) ]]; then
        score=$((score - 15))
    fi

    # --- Artist Diversity & Echo-Chamber Breaker ---
    if [ -n "$cand_art" ] && [ -f "$recent_artists_file" ]; then
        local last_artist=$(tail -n 1 "$recent_artists_file" 2>/dev/null)
        # 1. Consecutive artist penalty: Never back-to-back same artist
        if [ -n "$last_artist" ] && [ "$cand_art" == "$last_artist" ]; then
            score=$((score - 120))
        fi

        # 2. Recent artist fatigue: appeared in last 3 tracks
        local fatigue_count=$(tail -n 3 "$recent_artists_file" 2>/dev/null | grep -Fxc "$cand_art")
        if [ "$fatigue_count" -ge 1 ]; then
            score=$((score - (fatigue_count * 50)))
        fi

        # 3. Seed artist diversity: if candidate is by the seed artist, apply mild penalty to favor related artists
        if [ -n "$seed_artist" ] && [ "$cand_art" == "$seed_artist" ]; then
            score=$((score - 35))
        fi
    fi

    # --- User Taste Profile Affinity ---
    if [ -f "$taste_file" ]; then
        # Check if candidate artist is in user taste profile
        if [ -n "$cand_art" ] && grep -Fqxi "$cand_art" "$taste_file" 2>/dev/null; then
            score=$((score + 45))
        fi

        # Check signature genre keywords
        if [[ "$lower_title" =~ (nightcore|remix|slowed|reverb|cover|lofi|vocaloid|rock|arabic|acoustic|mashup|anime|r&b) ]]; then
            score=$((score + 30))
        fi
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
        # Intelligent Discovery Timing: trigger when 1-2 tracks left
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
    local seed_history_file="$HOME/.cache/mpv/auto_seed_history"
    local removed_file="$HOME/.cache/mpv/auto_removed_recent"
    local recent_artists_file="$HOME/.cache/mpv/auto_recent_artists"
    local taste_file="$HOME/.cache/mpv/auto_taste.cache"

    touch "$history_file" "$blacklist_file" "$seed_history_file" "$removed_file" "$recent_artists_file" 2>/dev/null
    ensure_taste_profile_cached

    # --- PROTOCOL: Dynamic Seed Determination & Rotation ---
    local seed_id=""
    local seed_title=""
    local pl_json=""

    # Retrieve current playlist from MPV
    if [ "$count" -gt 0 ] && [ -S "$SOCKET" ]; then
        pl_json=$(echo '{"command":["get_property","playlist"]}' | nc $NC_OPTS -w 2 "$SOCKET" 2>/dev/null)
    fi

    # Never use a removed or blacklisted track as seed!
    if [ -n "$input_filename" ] && [[ "$input_filename" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]]; then
        local test_id="${BASH_REMATCH[2]}"
        if ! grep -qx -- "$test_id" "$removed_file" 2>/dev/null && ! grep -E -q "^${test_id}([[:blank:]]|$)" "$blacklist_file" 2>/dev/null; then
            seed_id="$test_id"
            seed_title="$input_title"
        fi
    fi

    # Dynamic seed rotation from current queue
    if [ -z "$seed_id" ] && [ -n "$pl_json" ]; then
        local q_tracks_raw
        q_tracks_raw=$(echo "$pl_json" | jq -s -r 'map(select(.event == null)) | .[0].data | to_entries[] | "\(.key)\t\(.value.filename // "")\t\(.value.title // "")"' 2>/dev/null)

        declare -a eligible_seeds=()
        while IFS=$'\t' read -r q_idx q_file q_title; do
            [ -z "$q_file" ] && continue
            local v_id=""
            [[ "$q_file" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]] && v_id="${BASH_REMATCH[2]}"
            [ -z "$v_id" ] && continue

            # Exclude if blacklisted or recently removed
            grep -E -q "^${v_id}([[:blank:]]|$)" "$blacklist_file" 2>/dev/null && continue
            grep -qx -- "$v_id" "$removed_file" 2>/dev/null && continue

            # Check if used recently as seed
            if ! grep -qx -- "$v_id" "$seed_history_file" 2>/dev/null; then
                eligible_seeds+=("$v_id"$'\t'"$q_title")
            fi
        done <<< "$q_tracks_raw"

        # If all tracks in queue have been used as seeds, cycle by dropping older seed history
        if [ ${#eligible_seeds[@]} -eq 0 ]; then
            local recent_two=$(tail -n 2 "$seed_history_file" 2>/dev/null)
            while IFS=$'\t' read -r q_idx q_file q_title; do
                [ -z "$q_file" ] && continue
                local v_id=""
                [[ "$q_file" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]] && v_id="${BASH_REMATCH[2]}"
                [ -z "$v_id" ] && continue
                grep -E -q "^${v_id}([[:blank:]]|$)" "$blacklist_file" 2>/dev/null && continue
                grep -qx -- "$v_id" "$removed_file" 2>/dev/null && continue
                if ! echo "$recent_two" | grep -qx -- "$v_id"; then
                    eligible_seeds+=("$v_id"$'\t'"$q_title")
                fi
            done <<< "$q_tracks_raw"
        fi

        if [ ${#eligible_seeds[@]} -gt 0 ]; then
            local pick_idx=$((RANDOM % ${#eligible_seeds[@]}))
            IFS=$'\t' read -r seed_id seed_title <<< "${eligible_seeds[$pick_idx]}"
            echo "[$(date +%T)] [Seed] Rotated Seed: $seed_id ($seed_title)" >> "$debug_log"
        elif [ "$pos" -ge 0 ]; then
            local s_item=$(echo "$pl_json" | jq -s -r 'map(select(.event == null)) | .[0].data['$pos'] // empty' 2>/dev/null)
            local s_file=$(echo "$s_item" | jq -r '.filename // ""')
            seed_title=$(echo "$s_item" | jq -r '.title // ""')
            [[ "$s_file" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]] && seed_id="${BASH_REMATCH[2]}"
        fi
    fi

    # Empty Queue Fallback: Resurrect with a random track from user playlists!
    if [ -z "$seed_id" ]; then
        local pl_tracks=()
        if [ -d "$PLAYLIST_DIR" ]; then
            mapfile -t pl_tracks < <(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.txt" -exec cat {} + 2>/dev/null | grep -E '^http' | sort -u)
        fi
        if [ ${#pl_tracks[@]} -gt 0 ]; then
            local rand_pl_track="${pl_tracks[$((RANDOM % ${#pl_tracks[@]}))]}"
            [[ "$rand_pl_track" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]] && seed_id="${BASH_REMATCH[2]}"
            seed_title=$(get_cached_title "$rand_pl_track")
            echo "[$(date +%T)] [Seed] Empty Queue Initialized from User Playlists: $seed_id" >> "$debug_log"
        else
            seed_id=$(tail -n 1 "$history_file" 2>/dev/null)
            echo "[$(date +%T)] [Seed] Empty Queue Initialized from History: $seed_id" >> "$debug_log"
        fi
    fi

    # Record Seed in Rotation History
    if [ -n "$seed_id" ]; then
        echo "$seed_id" >> "$seed_history_file"
        tail -n 15 "$seed_history_file" > "$seed_history_file.tmp" 2>/dev/null && mv "$seed_history_file.tmp" "$seed_history_file"
    fi

    local seed_artist=$(normalize_artist "" "$seed_title")

    # --- 2. Candidate Discovery (Radio & Studio Prioritization) ---
    local fields="%(webpage_url)s"$'\t'"%(title)s"$'\t'"%(uploader)s"$'\t'"%(duration_string)s"
    local candidates=""

    local nice_cmd=()
    command -v nice >/dev/null 2>&1 && nice_cmd=("nice" "-n" "19")
    local ytdl_disc_opts=("--extractor-args" "youtube:player_client=visionos,android,web" "--no-warnings" "--skip-download")
    command -v node >/dev/null 2>&1 && ytdl_disc_opts+=("--js-runtimes" "node")
    [ -n "$COOKIES_FILE" ] && [ -f "$COOKIES_FILE" ] && ytdl_disc_opts+=("--cookies" "$COOKIES_FILE")

    # Strategy A: YouTube Song Radio Mix (RD<ID>)
    if [ -n "$seed_id" ]; then
        echo "[$(date +%T)] [Discovery] Radio Mix for Seed ID: $seed_id (Anchor Artist: ${seed_artist:-Unknown})" >> "$debug_log"
        candidates=$(run_with_timeout 25 "${nice_cmd[@]}" yt-dlp "${ytdl_disc_opts[@]}" --print "$fields" --flat-playlist --playlist-end 20 "https://www.youtube.com/watch?v=${seed_id}&list=RD${seed_id}" 2>/dev/null)
    fi

    # Strategy B: Studio Search fallback or augment
    if [ -z "$candidates" ]; then
        local query="popular music"
        if [ -n "$seed_title" ] && [ "$seed_title" != "null" ]; then
            local clean_q=$(echo "$seed_title" | sed -E 's/(\[|\()[^]]*(\]|\))//g' | sed 's/[^a-zA-Z0-9 ]/ /g' | awk '{$1=$1};1')
            query="${clean_q:0:50} audio"
        fi
        echo "[$(date +%T)] [Discovery] Studio Search: $query" >> "$debug_log"
        candidates=$(run_with_timeout 25 "${nice_cmd[@]}" yt-dlp "${ytdl_disc_opts[@]}" --print "$fields" --playlist-end 15 "ytsearch15:${query}" 2>/dev/null)
    fi

    if [ -z "$candidates" ]; then
        touch "$HOME/.cache/mpv/auto_failed"
        touch "$HOME/.cache/mpv/auto_cooldown"
        ( sleep 60; rm -f "$HOME/.cache/mpv/auto_cooldown" ) & disown
        return
    fi

    # --- 3. Deduplication, Blacklist Check & Studio Scoring ---
    local cur_ids=""
    local cur_titles_file=$(mktemp)
    if [ -n "$pl_json" ]; then
        cur_ids=$(echo "$pl_json" | jq -r '.data[].filename // empty' 2>/dev/null | grep -oP '(?<=[v=be/])[a-zA-Z0-9_-]{11}' | sort -u)
        echo "$pl_json" | jq -r '.data[].title // empty' 2>/dev/null | while IFS= read -r qt; do
            [ -n "$qt" ] && normalize_song_title "$qt" >> "$cur_titles_file"
        done
    fi

    declare -a scored_pool
    # scored_pool entries: "SCORE\tURL\tTITLE\tARTIST\tDUR"
    while IFS=$'\t' read -r url t a d; do
        [ -z "$url" ] || [ "$url" == "null" ] && continue
        local c_id=""
        [[ "$url" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]] && c_id="${BASH_REMATCH[2]}"
        [ -z "$c_id" ] && continue

        # Exclusions: seed itself, already in current queue, recently removed, played recently in history, or in blacklist
        [ -n "$seed_id" ] && [ "$c_id" == "$seed_id" ] && continue
        echo "$cur_ids" | grep -qx -- "$c_id" 2>/dev/null && continue
        grep -qx -- "$c_id" "$removed_file" 2>/dev/null && continue
        grep -qx -- "$c_id" "$history_file" 2>/dev/null && continue
        grep -E -q "^${c_id}([[:blank:]]|$)" "$blacklist_file" 2>/dev/null && continue

        # Evaluate Candidate Score with Anti-Echo Chamber & Diversity Scoring
        local s=$(score_candidate_track "$t" "$a" "$d" "$seed_artist" "$recent_artists_file" "$cur_titles_file" "$taste_file")
        if [ "$s" -gt -100 ]; then
            scored_pool+=("$s"$'\t'"$url"$'\t'"$t"$'\t'"$a"$'\t'"$d")
        fi
    done <<< "$candidates"

    rm -f "$cur_titles_file" 2>/dev/null

    # --- 4. Intelligent Selection from Top-Scored Candidates ---
    if [ ${#scored_pool[@]} -gt 0 ]; then
        if ! [ -S "$SOCKET" ]; then return; fi

        # Sort pool by score descending
        mapfile -t sorted_pool < <(printf "%s\n" "${scored_pool[@]}" | sort -t$'\t' -k1 -nr)

        # Pick randomly from the top 3 highest-ranked candidates to balance studio quality & variety
        local max_pick=3
        [ ${#sorted_pool[@]} -lt 3 ] && max_pick=${#sorted_pool[@]}
        local pick_idx=$((RANDOM % max_pick))

        IFS=$'\t' read -r chosen_score chosen_url chosen_t chosen_a chosen_d <<< "${sorted_pool[$pick_idx]}"

        echo "[$(date +%T)] [Success] Queuing (Score: $chosen_score): $chosen_t (by $chosen_a)" >> "$debug_log"
        mark_track_auto "$chosen_url"
        queue_item_ipc "$chosen_url" "$chosen_t" "$chosen_a" "$chosen_d"

        # Record in history & recent artists
        [[ "$chosen_url" =~ (v=|be\/|embed\/|watch\?v=)([a-zA-Z0-9_-]{11}) ]] && echo "${BASH_REMATCH[2]}" >> "$history_file"
        tail -n 100 "$history_file" > "$history_file.tmp" 2>/dev/null && mv "$history_file.tmp" "$history_file"

        local chosen_art=$(normalize_artist "$chosen_a" "$chosen_t")
        if [ -n "$chosen_art" ]; then
            echo "$chosen_art" >> "$recent_artists_file"
            tail -n 10 "$recent_artists_file" > "$recent_artists_file.tmp" 2>/dev/null && mv "$recent_artists_file.tmp" "$recent_artists_file"
        fi

        if [ "$force_fetch" = "true" ]; then
            echo -e "${C_GREEN}✨ Auto-Discovered & Queued:${C_RESET} ${C_PURPLE}Ⓐ${C_RESET} ${C_CYAN}${chosen_t}${C_RESET} ${C_GRAY}by${C_RESET} ${C_LIGHT_PINK}${chosen_a}${C_RESET} ${C_GRAY}[Score: ${chosen_score}]${C_RESET}"
        fi

        touch "$HOME/.cache/mpv/auto_cooldown"
        ( sleep 20; rm -f "$HOME/.cache/mpv/auto_cooldown" ) & disown
    else
        echo "[$(date +%T)] [Warning] No candidates passed quality & blacklist filters." >> "$debug_log"
        touch "$HOME/.cache/mpv/auto_cooldown"
        ( sleep 45; rm -f "$HOME/.cache/mpv/auto_cooldown" ) & disown
    fi
}

cmd_auto_status() {
    local auto_file="$HOME/.cache/mpv/auto_enabled"
    local seed_history_file="$HOME/.cache/mpv/auto_seed_history"
    local recent_artists_file="$HOME/.cache/mpv/auto_recent_artists"
    local blacklist_file="$HOME/.cache/mpv/auto_blacklist"
    touch "$seed_history_file" "$recent_artists_file" "$blacklist_file" 2>/dev/null

    print_header_box "${C_PINK}🤖 Queue Auto-Discovery Engine Status${C_RESET}"

    if [ -f "$auto_file" ]; then
        print_boxed_line "${C_TEAL}Auto Mode:     ${C_GREEN}ENABLED ✅${C_RESET} ${C_GRAY}(24/7 Zero-Gap discovery active)${C_RESET}"
    else
        print_boxed_line "${C_TEAL}Auto Mode:     ${C_GRAY}DISABLED ❌${C_RESET} ${C_GRAY}(Enable with: q -auto on)${C_RESET}"
    fi

    print_boxed_line "${C_TEAL}Algorithm:     ${C_WHITE}Dynamic Seed Rotation + Anti-Artist Echo Chamber ⚡${C_RESET}"

    # Active / Last Seed
    local last_seed=$(tail -n 1 "$seed_history_file" 2>/dev/null)
    if [ -n "$last_seed" ]; then
        local s_title=$(get_cached_title "https://www.youtube.com/watch?v=$last_seed")
        [ -z "$s_title" ] && s_title="Seed ($last_seed)"
        print_boxed_line "${C_TEAL}Active Seed:   ${C_CYAN}${s_title:0:$((INNER_WIDTH-17))}${C_RESET}"
    else
        print_boxed_line "${C_TEAL}Active Seed:   ${C_GRAY}Queue Dynamic Selection${C_RESET}"
    fi

    # Seed rotation count
    local seed_count=$(wc -l < "$seed_history_file" 2>/dev/null || echo "0")
    print_boxed_line "${C_TEAL}Seed Rotation: ${C_ORANGE}${seed_count} unique seeds rotated${C_RESET} ${C_GRAY}(Cycle depth: 15)${C_RESET}"

    # Recent Artists (Diversity Buffer)
    if [ -s "$recent_artists_file" ]; then
        local recent_arts=$(tail -n 3 "$recent_artists_file" 2>/dev/null | paste -sd ", " -)
        print_boxed_line "${C_TEAL}Artist Guard:  ${C_GREEN}Active${C_RESET} ${C_GRAY}(Fatigue buffer: ${recent_arts:0:$((INNER_WIDTH-35))})${C_RESET}"
    else
        print_boxed_line "${C_TEAL}Artist Guard:  ${C_GREEN}Active${C_RESET} ${C_GRAY}(Fatigue buffer clear)${C_RESET}"
    fi

    # Auto Tracks in Queue
    local auto_q_count=0
    if [ "$MPV_RUNNING" = true ] && [ -S "$SOCKET" ]; then
        load_auto_tracks_to_memory
        local pl_json=$(echo '{"command":["get_property","playlist"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)
        if [ -n "$pl_json" ]; then
            while IFS= read -r f; do
                [ -n "$f" ] && is_auto_track "$f" && ((auto_q_count++))
            done < <(echo "$pl_json" | jq -r 'select(.event == null) | .data[].filename // empty' 2>/dev/null)
        fi
    fi
    if [ "$auto_q_count" -gt 0 ]; then
        print_boxed_line "${C_TEAL}Auto Tracks:   ${C_PURPLE}Ⓐ ${C_CYAN}${auto_q_count} tracks in queue${C_RESET} ${C_GRAY}(marked Ⓐ)${C_RESET}"
    else
        print_boxed_line "${C_TEAL}Auto Tracks:   ${C_GRAY}0 auto tracks in queue${C_RESET} ${C_GRAY}(marked with Ⓐ)${C_RESET}"
    fi

    # Taste Profile
    local pl_count=$(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.txt" 2>/dev/null | wc -l)
    local bl_count=$(wc -l < "$blacklist_file" 2>/dev/null || echo "0")
    print_boxed_line "${C_TEAL}Taste Profile: ${C_PURPLE}${pl_count} saved playlists analyzed${C_RESET} ${C_GRAY}(${bl_count} tracks blacklisted)${C_RESET}"

    # Cooldown status
    if [ -f "$HOME/.cache/mpv/auto_cooldown" ]; then
        print_boxed_line "${C_TEAL}Cooldown:      ${C_YELLOW}Cooling down ⏳${C_RESET}"
    else
        print_boxed_line "${C_TEAL}Cooldown:      ${C_GREEN}Ready for next trigger ✅${C_RESET}"
    fi

    printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
    B_LINE=${B_LINE// /─}
    echo -e "${C_GRAY}${B_LINE}${C_RESET}"
    echo -e "${C_GRAY}💡 Quick Controls: ${C_WHITE}q -auto on${C_GRAY} | ${C_WHITE}q -auto off${C_GRAY} | ${C_WHITE}q -auto fetch${C_GRAY} (Force next) | ${C_WHITE}q -auto reset${C_RESET}"
}
