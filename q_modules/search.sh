perform_search() {
    local QUERY="$1"
    local PLATFORM="${2:-ytsearch25}"
    
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
    local YTDL_OPTS=("--default-search" "$PLATFORM" "--print" "%(title)s${TAB}%(webpage_url)s${TAB}%(duration_string)s${TAB}%(uploader)s" "--no-warnings" "--flat-playlist" "--skip-download")
    
    # Auto-add JS runtime if available
    if command -v node >/dev/null 2>&1; then
        YTDL_OPTS+=("--js-runtimes" "node")
    elif command -v deno >/dev/null 2>&1; then
        YTDL_OPTS+=("--js-runtimes" "deno")
    fi

    # Apply cookies if they exist
    [ -f "$COOKIES_FILE" ] && YTDL_OPTS+=("--cookies" "$COOKIES_FILE")

    # Resolve working yt-dlp executable or Python module
    local YTDL_CMD=("yt-dlp")
    if ! yt-dlp --version >/dev/null 2>&1; then
        if python3 -m yt_dlp --version >/dev/null 2>&1; then
            YTDL_CMD=("python3" "-m" "yt_dlp")
        elif python -m yt_dlp --version >/dev/null 2>&1; then
            YTDL_CMD=("python" "-m" "yt_dlp")
        elif [ -x "$HOME/.local/bin/yt-dlp" ]; then
            YTDL_CMD=("$HOME/.local/bin/yt-dlp")
        fi
    fi

    run_with_timeout 45 "${YTDL_CMD[@]}" "${YTDL_OPTS[@]}" -- "$QUERY" > "$TMP_RESULTS" 2> "$ERR_LOG"
    
    # Fallback: If search yielded empty results, retry with default web player client
    if [ ! -s "$TMP_RESULTS" ]; then
        local YTDL_FALLBACK_OPTS=("--default-search" "$PLATFORM" "--print" "%(title)s${TAB}%(webpage_url)s${TAB}%(duration_string)s${TAB}%(uploader)s" "--no-warnings" "--flat-playlist" "--skip-download")
        [ -f "$COOKIES_FILE" ] && YTDL_FALLBACK_OPTS+=("--cookies" "$COOKIES_FILE")
        run_with_timeout 45 "${YTDL_CMD[@]}" "${YTDL_FALLBACK_OPTS[@]}" -- "$QUERY" > "$TMP_RESULTS" 2>> "$ERR_LOG"
    fi
    
    if [ ! -s "$TMP_RESULTS" ]; then 
        echo -e "${C_PINK}🔍🤷 No results found for \"$QUERY\"... try another magic word?${C_RESET}"
        if [ -s "$ERR_LOG" ]; then
            if grep -qi "Sign in to confirm you’re not a bot\|bot\|captcha" "$ERR_LOG"; then
                echo -e "${C_ORANGE}💡 Tip: YouTube is requesting bot verification. Run 'q' with YouTube cookies or update yt-dlp.${C_RESET}"
            elif grep -qi "CERTIFICATE_VERIFY_FAILED\|certificate verify failed" "$ERR_LOG"; then
                echo -e "${C_ORANGE}💡 Tip: SSL Certificate error detected. Run 'pkg install -y ca-certificates openssl-tool' on Termux.${C_RESET}"
            elif grep -qi "Traceback (most recent call last)" "$ERR_LOG"; then
                echo -e "${C_ORANGE}💡 Tip: Termux Python yt-dlp installation is broken. Fix it instantly with:${C_RESET}"
                echo -e "   ${C_CYAN}pkg install -y python python-pip && pip install -U --force-reinstall yt-dlp${C_RESET}"
            elif grep -qi "ExtractorError\|Unsupported URL" "$ERR_LOG"; then
                echo -e "${C_ORANGE}💡 Tip: Try updating yt-dlp: run 'q -up' or 'pip install -U yt-dlp'${C_RESET}"
            else
                local err_sample=$(head -n 2 "$ERR_LOG" 2>/dev/null | tr '\n' ' ' | sed 's/^[[:space:]]*//')
                [ -n "$err_sample" ] && echo -e "${C_GRAY}   Details: ${err_sample:0:120}...${C_RESET}"
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
