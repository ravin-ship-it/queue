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

cmd_playlist_opts_fzf() {
    [ ! -d "$PLAYLIST_DIR" ] && return
    local idx=1
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local count=$(grep -cve '^\s*$' "${PLAYLIST_DIR}/${f}.txt" 2>/dev/null || echo "0")
        echo -e "${C_ORANGE}${idx}.${C_RESET} 📂 ${C_CYAN}${f}${C_RESET} ${C_GRAY}(${count})${C_RESET}"
        ((idx++))
    done < <(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.txt" -exec basename {} .txt \; 2>/dev/null | sort)
}

cmd_playlist_items_fzf() {
    local selected_pl="$1"
    local file="${PLAYLIST_DIR}/${selected_pl}.txt"
    [ ! -f "$file" ] && return
    local i=1
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        local title=$(get_cached_title "$url")
        local log_line=$(format_track_log "$i" "$url" "$title")
        echo -e "${log_line}::${url}"
        ((i++))
    done < "$file"
}

cmd_playlist_load() {
    local input="$1"
    
    # Interactive FZF selection if no argument provided
    if [ -z "$input" ]; then
        if [ ! -d "$PLAYLIST_DIR" ] || [ -z "$(ls -A "$PLAYLIST_DIR")" ]; then
            echo -e "${C_PINK}💨 No saved playlists found... your collection is a ghost town${C_RESET}"
            return
        fi
        
        local pl_opts=$(cmd_playlist_opts_fzf)
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
    load_mode=$(echo -e "  🎧  Append to Active Queue\n  ✨  Replace with New Queue & Play\n  🔀  Shuffle & Append to Active Queue" | \
        fzf --height=100% --layout=reverse --border --info=inline-right \
        $FZF_COLOR_OPTS \
        --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
        --header="How would you like to load these tracks?" \
        --prompt="Action > ")
    [ -z "$load_mode" ] && return

    ensure_mpv_running

    local is_first_replace=true
    local total_loaded=0

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
        ((total_loaded += count))

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
            
            local m="append-play"
            if { [[ "$load_mode" == *"Replace"* ]] || [[ "$load_mode" == *"New Queue"* ]]; } && [ "$is_first_replace" = true ]; then
                m="replace"
                is_first_replace=false
            fi

            local json_cmd=$(jq -nc --arg path "$clean_url" --arg m "$m" '{"command": ["loadfile", $path, $m]}')
            send_ipc "$json_cmd" > /dev/null
        done < "$temp_list"
        
        [ "$temp_list" != "$file" ] && rm "$temp_list"
        echo -e "${C_GREEN}✅ Loaded ${C_ORANGE}${count}${C_GREEN} tracks from ${C_CYAN}${name}${C_RESET}"
    done <<< "$input"

    if [[ "$load_mode" == *"Replace"* ]] || [[ "$load_mode" == *"New Queue"* ]]; then
        for i in {1..15}; do
            local cur_cnt=$(echo '{ "command": ["get_property", "playlist-count"] }' | nc -N -U -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0')
            if [ "$cur_cnt" -gt 0 ]; then break; fi
            sleep 0.1
        done
        echo '{"command": ["set_property", "pause", false]}' | nc -N -U -w 1 "$SOCKET" > /dev/null 2>&1
        wait_for_playback_start
        log_now_playing "|> Playing (New Queue): "
    fi
    save_current_playlist true >/dev/null 2>&1 & disown
}

cmd_playlist_list() {
    if [ ! -d "$PLAYLIST_DIR" ] || [ -z "$(ls -A "$PLAYLIST_DIR")" ]; then
        echo -e "${C_PINK}💨 No saved playlists found... it feels empty here${C_RESET}"
        return
    fi

    # 1. Select Playlist
    local pl_opts=$(cmd_playlist_opts_fzf)
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
    local ex_header=$(printf "${C_GRAY}${H_LINE}${C_RESET}\n  ${C_PURPLE}🪷 Playlist: ${C_CYAN}${selected_pl}${C_RESET} ${C_GRAY}(ENTER action, TAB select)${C_RESET}")

    local selection=$(cmd_playlist_items_fzf "$selected_pl" | fzf --multi --exact --cycle --tiebreak=index --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
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
    local action=$(echo -e "  🎧  Append to Active Queue\n  ✨  New Queue from Selected & Play\n  🔀  Shuffle & Append to Active Queue\n  ✖  Remove from Playlist" | \
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

    if [[ "$action" == *"New Queue"* ]]; then
        echo -e "${C_PINK}✨ Initializing Fresh New Queue from ${C_ORANGE}$sel_count${C_PINK} tracks...${C_RESET}"
        ensure_mpv_running

        local is_first=true
        while IFS= read -r url; do
            [ -z "$url" ] && continue
            local clean_url="${url%%\\t*}"
            clean_url="${clean_url%%[[:space:]]*}"
            clean_url=$(echo "$clean_url" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            
            local m="append-play"
            [ "$is_first" = true ] && { m="replace"; is_first=false; }
            local json_cmd=$(jq -nc --arg path "$clean_url" --arg m "$m" '{"command": ["loadfile", $path, $m]}')
            send_ipc "$json_cmd" > /dev/null
        done < <(echo "$selection" | awk -F'::' '{print $2}')

        for i in {1..15}; do
            local cur_cnt=$(echo '{ "command": ["get_property", "playlist-count"] }' | nc -N -U -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0')
            if [ "$cur_cnt" -gt 0 ]; then break; fi
            sleep 0.1
        done

        echo '{"command": ["set_property", "pause", false]}' | nc -N -U -w 1 "$SOCKET" > /dev/null 2>&1
        wait_for_playback_start
        log_now_playing "|> Playing (New Queue): "
        save_current_playlist true >/dev/null 2>&1 & disown
        return
    fi

    # Append or Shuffle-Append
    ensure_mpv_running
    local urls=$(echo "$selection" | awk -F'::' '{print $2}')
    if [[ "$action" == *"Shuffle"* ]]; then
        urls=$(echo "$urls" | shuf)
    fi

    while IFS= read -r url; do
        [ -z "$url" ] && continue
        local clean_url="${url%%\\t*}"
        clean_url="${clean_url%%[[:space:]]*}"
        clean_url=$(echo "$clean_url" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        local json_cmd=$(jq -nc --arg path "$clean_url" '{"command": ["loadfile", $path, "append-play"]}')
        send_ipc "$json_cmd" > /dev/null
    done < <(echo "$urls")
    
    echo -e "${C_GREEN}✅ Loaded ${C_ORANGE}${sel_count}${C_GREEN} tracks from ${C_CYAN}${selected_pl}${C_RESET}"
    save_current_playlist true >/dev/null 2>&1 & disown
    
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
