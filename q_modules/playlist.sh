cmd_playlist_save() {
    local name="$1"
    if [ -z "$name" ]; then
        print_header_box "💾 Save Current Queue"
        print_boxed_line "${C_ORANGE}Usage: q -save <name>${C_RESET}"
        printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
        B_LINE=${B_LINE// /─}
        echo -e "${C_GRAY}${B_LINE}${C_RESET}"
        return
    fi
    
    name=$(basename "$name")
    local file="${PLAYLIST_DIR}/${name}.txt"
    save_current_playlist # Sync first
    cp "$LAST_PLAYLIST_FILE" "$file"
    
    local count=$(wc -l < "$file")
    print_header_box "💾 Playlist Saved"
    print_boxed_line "${C_TEAL}Name:   ${C_CYAN}${name}${C_RESET}"
    print_boxed_line "${C_TEAL}Tracks: ${C_ORANGE}${count}${C_RESET}"
    print_boxed_line "${C_TEAL}Path:   ${C_GRAY}${file#$HOME/}${C_RESET}"
    printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
    B_LINE=${B_LINE// /─}
    echo -e "${C_GRAY}${B_LINE}${C_RESET}"
}

cmd_playlist_load() {
    local input="$1"
    
    # Interactive FZF selection if no argument provided
    if [ -z "$input" ]; then
        if [ ! -d "$PLAYLIST_DIR" ] || [ -z "$(ls -A "$PLAYLIST_DIR")" ]; then
            echo -e "${C_PINK}💨 No saved playlists found... your collection is a ghost town${C_RESET}"
            return
        fi
        
        # Build list with counts
        pl_opts=""
        local i=1
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            local count=$(grep -cve '^\s*$' "${PLAYLIST_DIR}/${f}.txt")
            pl_opts+="${C_ORANGE}${i}.${C_RESET} 📂 ${C_CYAN}${f}${C_RESET} ${C_GRAY}(${count})${C_RESET}\n"
            ((i++))
        done < <(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.txt" -exec basename {} .txt \; | sort)
        
        local pl_header=$(printf "${C_GRAY}${H_LINE}${C_RESET}\n  ${C_PURPLE}🪷 Select Playlists to Load${C_RESET}")

        input=$(echo -ne "$pl_opts" | \
            fzf --multi --exact --cycle --tiebreak=index --height=100% --layout=reverse --border --ansi \
            --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
            --header="$pl_header" \
            --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
            $FZF_COLOR_OPTS \
            --info=inline-right --prompt="📂 Playlist > " | sed "s/\x1b\[[0-9;]*m//g" | sed 's/^[ 0-9]*\. //' | sed 's/^📂 //' | sed 's/ ([0-9]*)$//')
        
        [ -z "$input" ] && { echo -e "${C_PINK}👋 Loading cancelled${C_RESET}"; return; }
    fi
    
    # Action Selection for loading multiple
    local load_mode="Append"
    if [ "$MPV_RUNNING" = true ]; then
        load_mode=$(echo -e "  ✚  Append to Queue\n  ▶  Replace Queue & Play\n  🔀 Shuffle & Append" | \
            fzf --height=100% --layout=reverse --border --info=inline-right \
            $FZF_COLOR_OPTS \
            --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
            --header="How would you like to load these tracks?" \
            --prompt="Action > ")
        [ -z "$load_mode" ] && return
    fi

    # Iterate over newline-separated inputs
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        
        local file=""
        if [[ "$item" =~ ^[0-9]+$ ]]; then
            file=$(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.txt" | sort | sed -n "${item}p")
        else
            file="${PLAYLIST_DIR}/${item}.txt"
        fi

        if [ ! -f "$file" ]; then
            echo -e "${C_PINK}🔍🤷 Playlist ${C_WHITE}[${C_ORANGE}${item}${C_WHITE}] ${C_PINK}not found${C_RESET}"
            continue
        fi
        
        local name=$(basename "$file" .txt)
        local count=$(wc -l < "$file")
        
        if [ "$MPV_RUNNING" = false ]; then
            # Stage to Last Session
            [ ! -f "$LAST_PLAYLIST_FILE" ] && touch "$LAST_PLAYLIST_FILE"
            grep -vE '^\s*$' "$file" >> "$LAST_PLAYLIST_FILE"
            echo -e "${C_PINK}📂 Staged ${C_ORANGE}${count}${C_PINK} tracks from ${C_CYAN}${name}${C_PINK} to session.${C_RESET}"
        else
            if [[ "$load_mode" == *"Replace"* ]]; then
                echo '{"command": ["playlist-clear"]}' | nc -N -U -w 1 "$SOCKET" > /dev/null
                load_mode="Append" # Switch to append for remaining files in loop
            fi

            local temp_list="$file"
            if [[ "$load_mode" == *"Shuffle"* ]]; then
                temp_list=$(mktemp)
                shuf "$file" > "$temp_list"
            fi

            while IFS= read -r url; do
                [ -z "$url" ] && continue
                # Robust URL cleaning
                local clean_url="${url%%\\t*}"
                clean_url="${clean_url%%[[:space:]]*}"
                clean_url=$(echo "$clean_url" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                
                local json_cmd=$(jq -nc --arg path "$clean_url" '{"command": ["loadfile", $path, "append-play"]}')
                send_ipc "$json_cmd" > /dev/null
            done < "$temp_list"
            
            [ "$temp_list" != "$file" ] && rm "$temp_list"
            echo -e "${C_GREEN}✅ Loaded ${C_ORANGE}${count}${C_GREEN} tracks from ${C_CYAN}${name}${C_RESET}"
        fi
    done <<< "$input"
    
    [ "$MPV_RUNNING" = true ] && save_current_playlist true >/dev/null 2>&1 & disown
    [ "$MPV_RUNNING" = false ] && echo -e "${C_GRAY}   (Run 'q -play' to start listening)${C_RESET}"
}

cmd_playlist_list() {
    if [ ! -d "$PLAYLIST_DIR" ] || [ -z "$(ls -A "$PLAYLIST_DIR")" ]; then
        echo -e "${C_PINK}💨 No saved playlists found... it feels empty here${C_RESET}"
        return
    fi

    # 1. Select Playlist
    local pl_opts=""
    local idx=1
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local count=$(grep -cve '^\s*$' "${PLAYLIST_DIR}/${f}.txt")
        pl_opts+="${C_ORANGE}${idx}.${C_RESET} 📂 ${C_CYAN}${f}${C_RESET} ${C_GRAY}(${count})${C_RESET}\n"
        ((idx++))
    done < <(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.txt" -exec basename {} .txt \; | sort)

    local pl_header=$(printf "${C_GRAY}${H_LINE}${C_RESET}\n  ${C_PURPLE}🪷 Explore Your Collections${C_RESET}")

    local selected_line=$(echo -ne "$pl_opts" | \
        fzf --exact --cycle --tiebreak=index --height=100% --layout=reverse --border --ansi \
        --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
        --header="$pl_header" \
        $FZF_COLOR_OPTS \
        --info=inline-right --prompt="📂 Playlist > ")

    [ -z "$selected_line" ] && return
    
    local selected_pl=$(echo -e "$selected_line" | sed "s/\x1b\[[0-9;]*m//g" | sed 's/^[ 0-9]*\. //' | sed 's/^📂 //' | sed 's/ ([0-9]*)$//')
    local file="${PLAYLIST_DIR}/${selected_pl}.txt"

    # 2. Explore Playlist Contents
    local items=$(mktemp)
    local i=1
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        # Use format_track_log for each item
        local title=$(get_cached_title "$url")
        local log_line=$(format_track_log "$i" "$url" "$title")
        echo -e "${log_line}::${url}" >> "$items"
        ((i++))
    done < "$file"

    local ex_header=$(printf "${C_GRAY}${H_LINE}${C_RESET}\n  ${C_PURPLE}🪷 Playlist: ${C_CYAN}${selected_pl}${C_RESET} ${C_GRAY}(ENTER to load, TAB to select, ALT-A invert, ALT-D none)${C_RESET}")

    local selection=$(cat "$items" | fzf --multi --exact --cycle --tiebreak=index --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
        --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
        --height=100% --layout=reverse --border --ansi \
        --header="$ex_header" \
        --delimiter="::" --with-nth=1 \
        $FZF_COLOR_OPTS \
        --info=inline-right --prompt="🎵 Track > ")

    rm "$items"
    [ -z "$selection" ] && return

    # 3. Choose Action
    local sel_count=$(echo "$selection" | wc -l)
    local action=$(echo -e "  ▶  Play Selected\n  ✚  Append to Queue\n  🔀 Shuffle & Append\n  ✖  Remove from Playlist" | \
        fzf --height=100% --layout=reverse --border --info=inline-right \
        $FZF_COLOR_OPTS \
        --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
        --header="Action for $sel_count track(s) from \"$selected_pl\"?" \
        --prompt="Choose > ")
    
    [ -z "$action" ] && return

    if [[ "$action" == *"Remove"* ]]; then
        # Removal Logic
        local temp_pl=$(mktemp)
        local urls_to_remove=$(echo "$selection" | awk -F'::' '{print $2}')
        grep -vFf <(echo "$urls_to_remove") "$file" > "$temp_pl"
        mv "$temp_pl" "$file"
        echo -e "${C_PINK}✖ Removed ${C_ORANGE}${sel_count}${C_PINK} tracks from ${C_CYAN}${selected_pl}${C_RESET}"
        return
    fi

    if [[ "$action" == *"Play"* ]]; then
        # Play First immediately, append rest
        local first_url=$(echo "$selection" | head -n1 | awk -F'::' '{print $2}')
        if [ "$MPV_RUNNING" = true ]; then
            local count=$(echo '{"command": ["get_property", "playlist-count"]}' | nc -N -U -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0')
            local json_cmd=$(jq -nc --arg path "$first_url" '{"command": ["loadfile", $path, "append-play"]}')
            send_ipc "$json_cmd" > /dev/null
            
            local play_cmd=$(jq -nc --argjson idx "$count" '{"command": ["playlist-play-index", $idx]}')
            send_ipc "$play_cmd" > /dev/null
            # Append others
            echo "$selection" | tail -n +2 | awk -F'::' '{print $2}' | while IFS= read -r url; do
                local json_cmd=$(jq -nc --arg path "$url" '{"command": ["loadfile", $path, "append-play"]}')
                send_ipc "$json_cmd" > /dev/null
            done
        fi
    else
        # Append or Shuffle-Append
        local urls=$(echo "$selection" | awk -F'::' '{print $2}')
        if [[ "$action" == *"Shuffle"* ]]; then
            urls=$(echo "$urls" | shuf)
        fi

        echo "$urls" | while IFS= read -r url; do
            [ -z "$url" ] && continue
            if [ "$MPV_RUNNING" = true ]; then
                local json_cmd=$(jq -nc --arg path "$url" '{"command": ["loadfile", $path, "append-play"]}')
                send_ipc "$json_cmd" > /dev/null
            else
                echo "$url" >> "$LAST_PLAYLIST_FILE"
            fi
        done
        
        if [ "$MPV_RUNNING" = false ]; then
            echo -e "${C_PINK}📂 Staged ${C_ORANGE}${sel_count}${C_PINK} tracks from ${C_CYAN}${selected_pl}${C_PINK} to session.${C_RESET}"
        else
            echo -e "${C_GREEN}✅ Loaded ${C_ORANGE}${sel_count}${C_GREEN} tracks from ${C_CYAN}${selected_pl}${C_RESET}"
        fi
    fi
    
    [ "$MPV_RUNNING" = true ] && save_current_playlist true >/dev/null 2>&1 & disown
}

cmd_playlist_raw() {
    local input="$1"
    
    # 1. Handle "List All" Case (No argument)
    if [ -z "$input" ]; then
        if [ ! -d "$PLAYLIST_DIR" ] || [ -z "$(ls -A "$PLAYLIST_DIR")" ]; then
            echo -e "${C_PINK}💨 No saved playlists found... go create some!${C_RESET}"
            return
        fi
        
        print_header_box "${C_PURPLE}🪷 Your Saved Collections${C_RESET}"
        local i=1
        while IFS= read -r pl; do
            [ -z "$pl" ] && continue
            local count=$(grep -cve '^\s*$' "${PLAYLIST_DIR}/${pl}.txt")
            print_boxed_line "${C_ORANGE}${i}.${C_RESET} 📂 ${C_CYAN}${pl}${C_RESET} ${C_GRAY}(${count})${C_RESET}"
            ((i++))
        done < <(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.txt" -exec basename {} .txt \; | sort)
        
        printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
        B_LINE=${B_LINE// /─}
        echo -e "${C_GRAY}${B_LINE}${C_RESET}"
        return
    fi

    # 2. Resolve Target (Index or Name)
    local name=""
    local file=""
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        file=$(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.txt" | sort | sed -n "${input}p")
        [ -n "$file" ] && name=$(basename "$file" .txt)
    else
        name="$input"
        file="${PLAYLIST_DIR}/${name}.txt"
    fi

    if [ ! -f "$file" ]; then
        echo -e "${C_PINK}🔍🤷 Playlist [${input}] not found${C_RESET}"
        return
    fi
    
    # 3. List Playlist Contents
    print_header_box "${C_PURPLE}📂 Playlist: ${C_CYAN}${name}${C_RESET}"
    
    local i=1
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        local title=$(get_cached_title "$url")
        local log_line=$(format_track_log "$i" "$url" "$title")
        print_boxed_line "$log_line"
        ((i++))
    done < "$file"
    
    printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
    B_LINE=${B_LINE// /─}
    echo -e "${C_GRAY}${B_LINE}${C_RESET}"
}

cmd_playlist_rm() {
    if [ "$#" -eq 0 ]; then
        print_header_box "✖ Delete Playlists"
        print_boxed_line "${C_ORANGE}Usage: q -pl-rm <name|N>...${C_RESET}"
        printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
        B_LINE=${B_LINE// /─}
        echo -e "${C_GRAY}${B_LINE}${C_RESET}"
        return
    fi
    
    local all_playlists=$(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.txt" | sort)
    declare -a FILES_TO_DELETE
    
    for input in "$@"; do
        local file=""
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            file=$(echo "$all_playlists" | sed -n "${input}p")
        else
            local safe_input=$(basename "$input")
            file="${PLAYLIST_DIR}/${safe_input}.txt"
        fi

        if [ -n "$file" ] && [ -f "$file" ]; then
            FILES_TO_DELETE+=("$file")
        else
            echo -e "${C_PINK}🔍🤷 Playlist ${C_WHITE}[${C_ORANGE}${input}${C_WHITE}] ${C_PINK}doesn't exist${C_RESET}"
        fi
    done

    if [ ${#FILES_TO_DELETE[@]} -gt 0 ]; then
        printf "%s\n" "${FILES_TO_DELETE[@]}" | sort -u | while IFS= read -r file; do
            local name=$(basename "$file" .txt)
            rm "$file"
            echo -e "${C_PINK}✖ Deleted playlist: ${C_CYAN}${name}${C_RESET}"
        done
    fi
}

cmd_rename() {
    local target="$1"
    local new_name="$2"

    if [ -z "$target" ] || [ -z "$new_name" ]; then
        print_header_box "✏️ Rename Target"
        print_boxed_line "${C_ORANGE}Usage: q -rname <target> <new_name>${C_RESET}"
        printf -v B_LINE "╰%*s╯" "$((TERM_WIDTH - 2))" ""
        B_LINE=${B_LINE// /─}
        echo -e "${C_GRAY}${B_LINE}${C_RESET}"
        return
    fi

    if [[ "$target" =~ ^http.* ]]; then
        echo -e "${C_PINK}🔗🔒 Online tracks cannot be renamed${C_RESET}"
        return
    fi

    new_name=$(basename "$new_name")

    local pl_old="${PLAYLIST_DIR}/${target}.txt"
    local pl_new="${PLAYLIST_DIR}/${new_name}.txt"

    if [ -f "$pl_old" ]; then
        if [ -f "$pl_new" ]; then
            echo -e "${C_ORANGE}⚠️ Playlist \"${new_name}\" already exists.${C_RESET}"
            return
        fi
        mv "$pl_old" "$pl_new"
        echo -e "${C_PINK}✏️ Renamed playlist: ${C_CYAN}${target}${C_RESET} -> ${C_CYAN}${new_name}${C_RESET}"
        return
    fi

    if [ -f "$target" ]; then
        local dir=$(dirname "$target")
        local new_path="${dir}/${new_name}"

        if [ -e "$new_path" ]; then
             echo -e "${C_ORANGE}⚠️ File \"${new_path}\" already exists.${C_RESET}"
             return
        fi

        mv "$target" "$new_path"
        echo -e "${C_PINK}✏️ Renamed file: ${C_CYAN}${target}${C_RESET} -> ${C_CYAN}${new_path}${C_RESET}"
        return
    fi

    echo -e "${C_PINK}🔍🤷 Target ${C_WHITE}[${C_ORANGE}${target}${C_WHITE}] ${C_PINK}not found${C_RESET}"
}
