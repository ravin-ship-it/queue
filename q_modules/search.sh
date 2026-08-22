perform_search() {
    local QUERY="$1"
    local PLATFORM="${2:-ytsearch40}"
    
    # Clear arrays for this query context
    PLAYLIST_URLS=()
    PLAYLIST_TITLES=()
    PLAYLIST_ARTISTS=()
    PLAYLIST_DURATIONS=()
    export CURRENT_QUERY_CONTEXT="$QUERY"

    echo -e "${C_GRAY}${H_LINE}${C_RESET}"
    echo -e "${C_CYAN}🔍 Searching for \"$QUERY\" (Deep Search)...${C_RESET}"
    
    # Ensure TMPDIR fallback for Android / Termux
    [ -z "$TMPDIR" ] && [ -d "/data/data/com.termux/files/usr/tmp" ] && export TMPDIR="/data/data/com.termux/files/usr/tmp"
    local TMP_RESULTS
    TMP_RESULTS=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/q_search_$$.tmp")
    local ERR_LOG="$HOME/.cache/mpv/last_search_err.log"
    mkdir -p "$(dirname "$ERR_LOG")"
    
    # Use strict Tab delimiter for reliability
    local TAB=$'\t'
    local COOKIES_FILE="$HOME/.config/mpv/cookies.txt"

    # Dynamically detect JS runtime (node)
    local js_runtime_opts=()
    if command -v node >/dev/null 2>&1; then
        js_runtime_opts=("--js-runtimes" "node")
    fi
    
    local COMMON_OPTS=("${js_runtime_opts[@]}" "--default-search" "$PLATFORM" "--print" "%(title)s${TAB}%(webpage_url)s${TAB}%(duration_string)s${TAB}%(uploader)s" "--no-warnings" "--flat-playlist" "--skip-download")
    [ -f "$COOKIES_FILE" ] && COMMON_OPTS+=("--cookies" "$COOKIES_FILE")

    # Tier 1: Search using android,web player clients
    run_with_timeout 30 yt-dlp "${COMMON_OPTS[@]}" --extractor-args "youtube:player_client=android,web" -- "$QUERY" > "$TMP_RESULTS" 2> "$ERR_LOG"
    
    # Tier 2: Search using web player client fallback
    if [ ! -s "$TMP_RESULTS" ]; then
        run_with_timeout 30 yt-dlp "${COMMON_OPTS[@]}" --extractor-args "youtube:player_client=web" -- "$QUERY" > "$TMP_RESULTS" 2>> "$ERR_LOG"
    fi

    # Tier 3: Search using vanilla default client (maximum compatibility for emulators/Termux)
    if [ ! -s "$TMP_RESULTS" ]; then
        run_with_timeout 30 yt-dlp "${COMMON_OPTS[@]}" -- "$QUERY" > "$TMP_RESULTS" 2>> "$ERR_LOG"
    fi
    
    if [ ! -s "$TMP_RESULTS" ]; then 
        echo -e "${C_PINK}🔍🤷 No results found for \"$QUERY\"... try another magic word?${C_RESET}"
        if [ -s "$ERR_LOG" ]; then
            if grep -qi "Sign in to confirm you’re not a bot\|bot\|captcha" "$ERR_LOG"; then
                echo -e "${C_ORANGE}💡 Tip: YouTube is requesting bot verification. Run 'q -up' to update yt-dlp or provide cookies.${C_RESET}"
            elif grep -qi "ExtractorError\|Unsupported URL" "$ERR_LOG"; then
                echo -e "${C_ORANGE}💡 Tip: Try updating yt-dlp: run 'q -up' or 'pip install -U yt-dlp'${C_RESET}"
            elif grep -qi "nodename nor servname provided\|Name or service not known\|Connection refused" "$ERR_LOG"; then
                echo -e "${C_ORANGE}💡 Tip: Network / DNS connection failed. Please check internet access.${C_RESET}"
            fi
        fi
        rm -f "$TMP_RESULTS"
        return 1 # Skip to next query
    fi
    echo -e "${C_GRAY}${H_LINE}${C_RESET}"

    # FZF Selection
    if command -v fzf >/dev/null; then
        # FZF Mode: Format for humans, hide URL/Title/Artist/Duration after ::
        # We pack ::URL::Title::Artist::Duration for retrieval
        local selection=$(awk -F'\t' -v c="$C_CYAN" -v p="$C_LIGHT_PINK" -v o="$C_ORANGE" -v r="$C_RESET" -v clr_idx="$C_ORANGE" \
            '{gsub("::", ":", $1); gsub("::", ":", $3); gsub("::", ":", $4); printf "%s%d.%s %s%s %sby %s %s[%s]%s::%s::%s::%s::%s\n", clr_idx, NR, r, c, $1, p, $4, o, $3, r, $2, $1, $4, $3}' "$TMP_RESULTS" | \
            fzf --multi --exact --cycle --tiebreak=index --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" --delimiter="::" --with-nth=1 --height=100% --layout=reverse --border --ansi \
                --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
                $FZF_COLOR_OPTS \
                --info=inline-right --prompt="🎵 Select for \"$QUERY\" > ")
        
        if [ -z "$selection" ]; then 
            echo -e "${C_PINK}👋 Selection cancelled for \"$QUERY\"${C_RESET}"
            rm "$TMP_RESULTS"
            return 1 # Skip to next query
        fi
        
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            # Parse from the end to handle "::" in Title correctly
            # Format: Display::URL::Title::Artist::Duration
            
            local duration="${line##*::}"
            local tmp1="${line%::*}" # Display::URL::Title::Artist
            
            local artist="${tmp1##*::}"
            local tmp2="${tmp1%::*}" # Display::URL::Title
            
            local title="${tmp2##*::}"
            local tmp3="${tmp2%::*}" # Display::URL
            
            local url="${tmp3##*::}"
            
            [ -z "$title" ] && title="Unknown Track"
            
            PLAYLIST_URLS+=("$url")
            PLAYLIST_TITLES+=("$title")
            PLAYLIST_ARTISTS+=("$artist")
            PLAYLIST_DURATIONS+=("$duration")
        done <<< "$selection"
    else
        # Manual Mode Fallback
        local i=1
        declare -A URL_MAP
        declare -A TITLE_MAP
        declare -A ARTIST_MAP
        declare -A DURATION_MAP
        while IFS=$'\t' read -r title url duration uploader; do
             [ -z "$duration" ] && duration="N/A"
             [ -z "$uploader" ] && uploader="Unknown"
             local SHORT_TITLE=$(truncate_text "$title" "$((TERM_WIDTH - 35))")
             printf " %2d. ${C_CYAN}%s${C_RESET} [${C_ORANGE}%s${C_RESET}] ${C_GRAY}by${C_RESET} ${C_LIGHT_PINK}%s${C_RESET}\n" "$i" "$SHORT_TITLE" "$duration" "$uploader"
             URL_MAP[$i]="$url"
             TITLE_MAP[$i]="$title"
             ARTIST_MAP[$i]="$uploader"
             DURATION_MAP[$i]="$duration"
             ((i++))
        done < "$TMP_RESULTS"
        echo -e "${C_GRAY}${H_LINE}${C_RESET}"
        echo -n -e "${C_PINK}>>> Select (e.g. '1 3 5') or 'c' to skip: ${C_RESET}"
        read -r selection_input < /dev/tty
        
        if [[ "$selection_input" == "c" ]]; then 
            echo -e "${C_PINK}🙅 Search cancelled${C_RESET}"
            rm "$TMP_RESULTS"
            return 1
        fi
        
        for selection in $selection_input; do
            if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -lt "$i" ]; then
                PLAYLIST_URLS+=("${URL_MAP[$selection]}")
                PLAYLIST_TITLES+=("${TITLE_MAP[$selection]}")
                PLAYLIST_ARTISTS+=("${ARTIST_MAP[$selection]}")
                PLAYLIST_DURATIONS+=("${DURATION_MAP[$selection]}")
            else
                echo -e "⚠️ ${C_ORANGE}Invalid/Out of range: $selection${C_RESET}"
            fi
        done
    fi
    rm "$TMP_RESULTS"
    return 0
}
