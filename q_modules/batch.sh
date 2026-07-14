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
        if [ "$MPV_RUNNING" = false ]; then
            if [ -f "$LAST_PLAYLIST_FILE" ] && [ -s "$LAST_PLAYLIST_FILE" ]; then
                echo -e "${C_PINK}🚀 Starting MPV and restoring session...${C_RESET}"
                cmd_play >/dev/null 2>&1
                for i in {1..20}; do
                    [ -S "$SOCKET" ] && break
                    sleep 0.2
                done
                MPV_RUNNING=true
            else
                echo -e "${C_PINK}🚀 Starting MPV...${C_RESET}"
                if command -v termux-wake-lock >/dev/null 2>&1; then termux-wake-lock; fi
                ( command mpv --idle --no-terminal --input-ipc-server="$SOCKET" </dev/null >/dev/null 2>&1 & )
                for i in {1..20}; do
                    [ -S "$SOCKET" ] && break
                    sleep 0.2
                done
                MPV_RUNNING=true
                start_idle_monitor
            fi
        fi

        if [ "$MPV_RUNNING" = true ]; then
            if [ ${#PLAYLIST_URLS[@]} -gt 1 ]; then
                # Fetch count before adding to know where to resume
                local init_count=$(echo '{ "command": ["get_property", "playlist-count"] }' | nc -N -U -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0')
                
                echo -e "${C_PINK}🚀 Queuing ${C_ORANGE}${#PLAYLIST_URLS[@]}${C_PINK} tracks...${C_RESET}"
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
                echo -e "${C_GREEN}✅ All tracks added to queue.${C_RESET}"
                
                # Auto-resume if MPV was idle (start at the first new track)
                check_and_resume "$init_count"
                save_current_playlist >/dev/null 2>&1 & 
            else
                # Single item - Manual Cache Update to ensure Artist/Duration presence
                local q_url="${PLAYLIST_URLS[0]}"
                local q_title="${PLAYLIST_TITLES[0]}"
                local q_artist="${PLAYLIST_ARTISTS[0]}"
                local q_dur="${PLAYLIST_DURATIONS[0]}"
                
                queue_item_ipc "${q_url}" "${q_title}" "${q_artist}" "${q_dur}"
            fi
        fi
    fi
    
    # Reset for next batch (if any)
    PLAYLIST_URLS=()
    PLAYLIST_TITLES=()
    PLAYLIST_ARTISTS=()
    PLAYLIST_DURATIONS=()
}