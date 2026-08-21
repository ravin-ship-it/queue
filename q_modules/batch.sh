# --- CORE LOGIC: EXECUTION HANDLER ---

execute_batch() {
    # Prepare execution variables
    local DO_QUEUE=false
    declare -a TARGET_FILES

    # Handle explicit -to flag (Legacy/Direct mode)
    if [ -n "$TARGET_PLAYLIST" ]; then
        TARGET_FILES+=("${PLAYLIST_DIR}/${TARGET_PLAYLIST}.txt")
    fi

    # Show Picker if NO explicit target was given AND:
    # 1. It came from a search results selection (IS_SEARCH=true)
    # 2. It's a batch of more than 1 track (likely a playlist)
    if [ -z "$TARGET_PLAYLIST" ] && [ ${#PLAYLIST_URLS[@]} -gt 0 ]; then
         local skip_picker=false
         if [ "$IS_SEARCH" != "true" ] && [ ${#PLAYLIST_URLS[@]} -eq 1 ]; then
             skip_picker=true
         fi

         if [ "$skip_picker" = true ] || ([ ! -t 1 ] && [ "$IN_FZF" != "true" ]); then
             # Default to queue
             local dest="  🎧 Active Queue"
         else
             # Small breather after search results
             sleep 0.2
             local Q_ICON="🎧 "; local P_ICON="📂 "; local N_ICON="✚ "
             local list_opts="  ${Q_ICON}Active Queue\n  ${N_ICON}Create New Playlist..."
             if [ -d "$PLAYLIST_DIR" ]; then
                 local i=1
                 # Ensure we find all current playlists from the FS
                 while IFS= read -r f; do
                     [ -z "$f" ] && continue
                     local count=$(grep -cve '^\s*$' "${PLAYLIST_DIR}/${f}.txt" 2>/dev/null || echo "0")
                     list_opts+="\n  ${C_ORANGE}${i}.${C_RESET} ${P_ICON}${f} (${count})"
                     ((i++))
                 done < <(ls "$PLAYLIST_DIR" | grep '\.txt$' | sed 's/\.txt$//' | sort)
             fi
             
             # Dynamic Header for context
             local header_txt="Where to add these ${#PLAYLIST_URLS[@]} tracks?"
             [ -n "$CURRENT_QUERY_CONTEXT" ] && header_txt="[Result: $CURRENT_QUERY_CONTEXT]\n$header_txt"

             local dest=$(echo -e "$list_opts" | fzf --multi --exact --cycle --tiebreak=index --height=100% --layout=reverse --border --ansi --info=inline-right \
                 --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
                 --header="$header_txt" \
                 --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
                 $FZF_COLOR_OPTS \
                 --prompt="Select Destination (TAB for multi) > ")
             
             if [ -z "$dest" ]; then 
                 echo -e "${C_PINK}👋 Selection cancelled... no music for you?${C_RESET}"
                 return 1
             fi
         fi

         # 1. Handle New Playlist Creation First
         if echo "$dest" | grep -q "${N_ICON}Create New Playlist..."; then
             # Another small breather before input box
             sleep 0.2
             local new_name=$(get_input "✚ Create New Playlist" "Name > ")
             if [ -n "$new_name" ]; then
                 TARGET_FILES+=("${PLAYLIST_DIR}/${new_name}.txt")
             else
                 echo -e "${C_PINK}💨 Skipped creation (empty name or cancelled).${C_RESET}"
             fi
         fi

         # 2. Process other selections
         while IFS= read -r line; do
             [ -z "$line" ] && continue
             if [[ "$line" == *"${Q_ICON}Active Queue"* ]]; then
                 DO_QUEUE=true
             elif [[ "$line" =~ ${P_ICON}(.*) ]]; then
                 # Extract name after icon, strip ANSI, and remove the (count) suffix
                 local pl_raw=$(echo -e "${BASH_REMATCH[1]}" | sed "s/\x1b\[[0-9;]*m//g" | sed 's/ ([0-9]*)$//')
                 # Trim leading/trailing whitespace
                 local pl_name=$(echo "$pl_raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                 [ -n "$pl_name" ] && TARGET_FILES+=("${PLAYLIST_DIR}/${pl_name}.txt")
             fi
         done < <(echo "$dest")
    fi

    # 1. Process Playlist Saves (Multi-Target)
    if [ ${#TARGET_FILES[@]} -gt 0 ]; then
        for pl_file in "${TARGET_FILES[@]}"; do
            local pl_name=$(basename "$pl_file" .txt)
            echo -e "${C_PINK}✚  Adding ${C_ORANGE}${#PLAYLIST_URLS[@]}${C_PINK} tracks to: ${C_CYAN}${pl_name}${C_RESET}..."
            
            for i in "${!PLAYLIST_URLS[@]}"; do
                local pl_url="${PLAYLIST_URLS[$i]}"
                local pl_title="${PLAYLIST_TITLES[$i]}"
                local pl_artist="${PLAYLIST_ARTISTS[$i]}"
                local pl_dur="${PLAYLIST_DURATIONS[$i]}"
                
                # Robust URL cleaning
                local pl_clean_url="${pl_url%%\\t*}"
                pl_clean_url="${pl_clean_url%%[[:space:]]*}"
                pl_clean_url=$(echo "$pl_clean_url" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

                echo "$pl_clean_url" >> "$pl_file"
                # Cache title
                if [ -n "$pl_title" ] && [ "$pl_title" != "$pl_url" ]; then
                    printf "%s\t%s\t%s\t%s\n" "$pl_clean_url" "$pl_title" "$pl_artist" "$pl_dur" >> "$CACHE_FILE"
                    CACHE_MEM["$pl_clean_url"]="${pl_title}"$'\t'"${pl_artist}"$'\t'"${pl_dur}"
                fi
            done
        done
        echo -e "${C_GREEN}✅ Playlists updated.${C_RESET}"
    fi

    # 2. Process Queue/Play (If selected or implicit)
    if [ "$DO_QUEUE" = true ] || ([ ${#TARGET_FILES[@]} -eq 0 ] && [ ${#PLAYLIST_URLS[@]} -gt 0 ]); then
        local SHOULD_START_PLAY=false

        if [ "$MPV_RUNNING" = false ]; then
            SHOULD_START_PLAY=true
            echo -e "${C_PINK}🚀 Starting MPV...${C_RESET}"
            rm -f "$SOCKET"
            local initial_pl_arg=()
            if [ -f "$LAST_PLAYLIST_FILE" ] && [ -s "$LAST_PLAYLIST_FILE" ]; then
                initial_pl_arg=("--playlist=$LAST_PLAYLIST_FILE")
            fi

            setsid mpv --idle --keep-open=yes --no-terminal --vo=null \
                --network-timeout=30 \
                --stream-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_delay_max=5 \
                --demuxer-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_delay_max=5 \
                --cache=yes --cache-secs=300 --demuxer-readahead-secs=300 \
                --demuxer-max-bytes=256MiB --demuxer-max-back-bytes=128MiB \
                --input-ipc-server="$SOCKET" "${initial_pl_arg[@]}" </dev/null >/dev/null 2>&1 &
            disown

            for i in {1..30}; do
                [ -S "$SOCKET" ] && break
                sleep 0.1
            done

            MPV_RUNNING=true
            start_idle_monitor
            restore_state_properties
        else
            # Check if MPV is running but idle, paused at EOF, or has no active track
            local raw_mpv_state=$(echo -e '{"command":["get_property","idle-active"]}\n{"command":["get_property","playlist-count"]}\n{"command":["get_property","playlist-pos"]}' | nc -N -U -w 1 "$SOCKET" 2>/dev/null | jq -s -j -r 'map(select(.event == null)) | (if .[0].data == null then true else .[0].data end), "\t", (if .[1].data == null then 0 else .[1].data end), "\t", (if .[2].data == null then -1 else .[2].data end)')
            IFS=$'\t' read -r m_idle m_count m_pos <<< "$raw_mpv_state"
            if [ "$m_idle" == "true" ] || [ "$m_count" -le 0 ] || [ "$m_pos" -eq -1 ]; then
                SHOULD_START_PLAY=true
            fi
        fi

        if [ "$MPV_RUNNING" = true ]; then
            # Current count before appending new items
            local init_count=$(echo '{ "command": ["get_property", "playlist-count"] }' | nc -N -U -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0')
            [[ ! "$init_count" =~ ^[0-9]+$ ]] && init_count=0

            local batch_cmds=""
            for i in "${!PLAYLIST_URLS[@]}"; do
                local q_url="${PLAYLIST_URLS[$i]}"
                local q_title="${PLAYLIST_TITLES[$i]}"
                local q_artist="${PLAYLIST_ARTISTS[$i]}"
                local q_dur="${PLAYLIST_DURATIONS[$i]}"

                # Robust URL cleaning
                local q_clean_url="${q_url%%\\t*}"
                q_clean_url="${q_clean_url%%[[:space:]]*}"
                q_clean_url=$(echo "$q_clean_url" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

                if [ -n "$q_title" ] && [ "$q_title" != "$q_url" ]; then
                    printf "%s\t%s\t%s\t%s\n" "$q_clean_url" "$q_title" "$q_artist" "$q_dur" >> "$CACHE_FILE"
                    CACHE_MEM["$q_clean_url"]="${q_title}"$'\t'"${q_artist}"$'\t'"${q_dur}"
                fi

                local q_json_cmd=$(jq -nc --arg path "$q_clean_url" '{"command": ["loadfile", $path, "append-play"]}')
                batch_cmds+="${q_json_cmd}\n"
            done

            echo -e "$batch_cmds" | nc -N -U -w 1 "$SOCKET" > /dev/null

            # Stabilization: wait for playlist count to increase
            for i in {1..15}; do
                local cur_cnt=$(echo '{ "command": ["get_property", "playlist-count"] }' | nc -N -U -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0')
                if [ "$cur_cnt" -gt "$init_count" ]; then break; fi
                sleep 0.1
            done

            if [ "$SHOULD_START_PLAY" = true ]; then
                # Directly play the newly added track immediately
                echo "{\"command\": [\"playlist-play-index\", $init_count]}" | nc -N -U -w 1 "$SOCKET" > /dev/null 2>&1
                echo '{"command": ["set_property", "pause", false]}' | nc -N -U -w 1 "$SOCKET" > /dev/null 2>&1
                wait_for_playback_start
                log_now_playing "|> Playing: "
            else
                # MPV is already playing: queue without interrupting
                if [ ${#PLAYLIST_URLS[@]} -gt 1 ]; then
                    echo -e "${C_GREEN}✅ Added ${#PLAYLIST_URLS[@]} tracks to queue.${C_RESET}"
                else
                    local display_title="${PLAYLIST_TITLES[0]}"
                    [ -z "$display_title" ] && display_title=$(basename "${PLAYLIST_URLS[0]}")
                    local formatted_track=$(format_track_log "$((init_count + 1))" "${PLAYLIST_URLS[0]}" "$display_title")
                    echo -e "${C_PINK}✅ Queued ${formatted_track}${C_RESET}"
                fi
            fi

            save_current_playlist true >/dev/null 2>&1 & disown
        fi
    fi
    
    # Reset for next batch (if any)
    PLAYLIST_URLS=()
    PLAYLIST_TITLES=()
    PLAYLIST_ARTISTS=()
    PLAYLIST_DURATIONS=()
}