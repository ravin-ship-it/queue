CACHE_FILE="$HOME/.cache/mpv/titles.txt"
LAST_PLAYLIST_FILE="$HOME/.cache/mpv/last_playlist.txt"
PLAYLIST_DIR="$HOME/.local/share/mpv/playlists"
mkdir -p "$(dirname "$CACHE_FILE")"
mkdir -p "$PLAYLIST_DIR"
[ ! -f "$CACHE_FILE" ] && touch "$CACHE_FILE"

# Cleanup stale radio/monitor locks
rm -f "$HOME/.cache/mpv/radio_lock.lock"
rm -f "$HOME/.cache/mpv/radio_failed"
rm -f "$HOME/.cache/mpv/radio_cooldown"

SOCKET="$HOME/.mpv-socket"

# Portable netcat wrapper for MPV IPC socket communication.
# Detects available tool once at source-time: socat > GNU nc (with -N) > ncat
# Usage: ... | mpv_nc [timeout_seconds]
#   timeout defaults to 1 if not specified
if command -v socat &>/dev/null; then
    _NC_FLAVOR="socat"
elif nc -h 2>&1 | grep -q '\-N'; then
    _NC_FLAVOR="gnu"
else
    _NC_FLAVOR="ncat"
fi

mpv_nc() {
    local timeout="${1:-1}"
    case "$_NC_FLAVOR" in
        socat)  socat - UNIX-CONNECT:"$SOCKET",connect-timeout="$timeout" ;;
        gnu)    nc -N -U -w "$timeout" "$SOCKET" ;;
        ncat)   ncat -U -w "$timeout" "$SOCKET" ;;
    esac
}

MPV_RUNNING=false
if [ -S "$SOCKET" ]; then
    # Verify if socket is actually responsive (1s timeout)
    if echo '{ "command": ["get_property", "idle-active"] }' | mpv_nc 1 &>/dev/null; then
        MPV_RUNNING=true
    else
        # Stale socket detected
        rm -f "$SOCKET"
    fi
fi

check_socket() {
    [ -S "$SOCKET" ] && echo '{ "command": ["get_property", "idle-active"] }' | mpv_nc 1 &>/dev/null
}

check_and_resume() {
    local force_idx="$1"
    
    # Cooldown to prevent duplicate concurrent triggers
    local resume_cd="$HOME/.cache/mpv/auto_resume_cd"
    if [ -f "$resume_cd" ]; then return; fi
    touch "$resume_cd"
    ( sleep 5; rm -f "$resume_cd" ) >/dev/null 2>&1 & disown

    if [ "$MPV_RUNNING" = true ]; then
        local raw_state=$(echo -e '{"command":["get_property","idle-active"]}\n{"command":["get_property","eof-reached"]}' | mpv_nc 1 2>/dev/null | jq -s -r 'map(select(.event == null)) | (.[0].data // false), (.[1].data // false)')
        IFS=$'\n' read -r is_idle is_eof <<< "$raw_state"
        
        # If idle or paused at EOF, we must intervene
        if [ "$is_idle" == "true" ] || [ "$is_eof" == "true" ]; then
            if [ -n "$force_idx" ]; then
                 echo -e "${C_PINK}⚡ Auto-Resuming at index ${C_ORANGE}$((force_idx + 1))${C_PINK}...${C_RESET}"
                 
                 # Wait for playlist to actually have the item (Race condition fix)
                 for i in {1..10}; do
                     local cnt=$(echo '{ "command": ["get_property", "playlist-count"] }' | mpv_nc 1 2>/dev/null | jq -r '.data // 0')
                     if [ "$cnt" -gt "$force_idx" ]; then break; fi
                     sleep 0.1
                 done
                 # Force play specific index
                 echo "{ \"command\": [\"playlist-play-index\", $force_idx] }" | mpv_nc 1 > /dev/null
            else
                 echo -e "${C_PINK}⚡ Auto-Resuming...${C_RESET}"
                 # Fallback to next
                 echo '{ "command": ["playlist-next"] }' | mpv_nc 1 > /dev/null
            fi
            echo '{ "command": ["set_property", "pause", false] }' | mpv_nc 1 > /dev/null
            
            # Check success
            sleep 0.2
            local new_idle=$(echo '{ "command": ["get_property", "idle-active"] }' | mpv_nc 1 2>/dev/null | jq -r '.data // "false"')
            if [ "$new_idle" == "false" ]; then
                log_now_playing "|> Playing (Auto): "
            else
                echo -e "${C_GRAY}(Resume check failed: still idle)${C_RESET}"
            fi
        fi
    fi
}

send_ipc() {
    echo "$1" | mpv_nc 1
}

save_current_playlist() {
    local force="${1:-false}"
    [ "$MPV_RUNNING" = false ] && return
    
    # Cooldown of 30 seconds to avoid spamming IO and CPU with large playlists
    # Skip cooldown if force is true
    if [ "$force" != "true" ]; then
        local now=$(date +%s)
        local last_save=$(get_file_mtime "$LAST_PLAYLIST_FILE")
        if [ $((now - last_save)) -lt 30 ]; then return; fi
    fi

    # Small delay when forced to allow MPV state to settle after IPC edits
    [ "$force" == "true" ] && sleep 0.2

    local raw=$(echo -e '{"command":["get_property","playlist"]}\n{"command":["get_property","shuffle"]}\n{"command":["get_property","loop-file"]}\n{"command":["get_property","loop-playlist"]}\n{"command":["get_property","playlist-pos"]}' | mpv_nc 2 2>/dev/null | jq -s -c -r 'map(select(.event == null))')
    
    if [ -n "$raw" ] && [ "$raw" != "null" ]; then
        # Dynamically locate the response element containing the playlist array
        local playlist_items=$(echo "$raw" | jq -r '.[] | select(.data != null and (.data | type == "array")) | .data[].filename // empty' 2>/dev/null)
        local playlist_found=$(echo "$raw" | jq -r '.[] | select(.data != null and (.data | type == "array")) | "true"' 2>/dev/null | head -n 1)

        if [ "$playlist_found" == "true" ]; then
            local new_count=0
            if [ -n "$playlist_items" ]; then
                new_count=$(echo "$playlist_items" | grep -cve '^\s*$')
            fi
            
            if [ "$new_count" -gt 0 ]; then
                echo "$playlist_items" > "${LAST_PLAYLIST_FILE}.tmp" && mv "${LAST_PLAYLIST_FILE}.tmp" "$LAST_PLAYLIST_FILE"
            elif [ "$new_count" -eq 0 ]; then
                # Queue is genuinely empty
                > "$LAST_PLAYLIST_FILE"
            fi

            # Save state properties to state.json
            echo "$raw" | jq -c 'map(select(.data != null and (.data | type != "array"))) | {shuffle: .[0].data, loop_file: .[1].data, loop_playlist: .[2].data, pos: .[3].data}' 2>/dev/null > "$HOME/.cache/mpv/state.json.tmp"
            [ -s "$HOME/.cache/mpv/state.json.tmp" ] && mv "$HOME/.cache/mpv/state.json.tmp" "$HOME/.cache/mpv/state.json"
        fi
    fi
}

restore_state_properties() {
    local state_file="$HOME/.cache/mpv/state.json"
    [ ! -f "$state_file" ] && return
    
    local shuf=$(jq -r '.shuffle // "false"' "$state_file")
    local lf=$(jq -r '.loop_file // "no"' "$state_file")
    local lp=$(jq -r '.loop_playlist // "no"' "$state_file")
    local pos=$(jq -r '.pos // 0' "$state_file")
    
    echo "{ \"command\": [\"set_property\", \"shuffle\", $shuf] }" | mpv_nc 1 > /dev/null 2>&1
    echo "{ \"command\": [\"set_property\", \"loop-file\", \"$lf\"] }" | mpv_nc 1 > /dev/null 2>&1
    echo "{ \"command\": [\"set_property\", \"loop-playlist\", \"$lp\"] }" | mpv_nc 1 > /dev/null 2>&1
    
    # Only restore position if it's valid
    if [ "$pos" != "null" ] && [ "$pos" -ge 0 ]; then
        echo "{ \"command\": [\"set_property\", \"playlist-pos\", $pos] }" | mpv_nc 1 > /dev/null 2>&1
    fi
}

# Global Memory Cache
declare -A CACHE_MEM

# --- CROSS-PLATFORM HELPER FUNCTIONS ---

get_file_mtime() {
    local f="$1"
    if [ ! -e "$f" ]; then
        echo 0
        return
    fi
    # Linux GNU stat
    if stat -c %Y "$f" >/dev/null 2>&1; then
        stat -c %Y "$f"
    # macOS BSD stat
    elif stat -f %m "$f" >/dev/null 2>&1; then
        stat -f %m "$f"
    # Fallback
    else
        date +%s -r "$f" 2>/dev/null || echo 0
    fi
}

run_with_timeout() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null; then
        gtimeout "$secs" "$@"
    else
        # Fallback without timeout if neither exists
        "$@"
    fi
}

is_media_file() {
    local filename="$1"
    # Skip URLs (always assumed media for now)
    [[ "$filename" =~ ^http ]] && return 0
    
    # Supported media extensions
    local ext="${filename##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
        mp3|flac|wav|m4a|ogg|opus|mp4|webm|mkv|avi|mov|ts|m3u|m3u8) return 0 ;;
        *) return 1 ;;
    esac
}

load_cache_to_memory() {
    # Properly clear associative array without losing its attribute
    unset CACHE_MEM
    declare -g -A CACHE_MEM
    [ ! -f "$CACHE_FILE" ] && return
    
    # Read the 4-column cache file into memory
    while IFS=$'\t' read -r url title artist duration; do
        [ -z "$url" ] && continue
        # Store as a single tab-separated string for easy extraction
        CACHE_MEM["$url"]="${title}"$'\t'"${artist}"$'\t'"${duration}"
    done < "$CACHE_FILE"
}

get_cached_row() {
    local url="$1"
    echo -e "${CACHE_MEM[$url]}"
}

get_cached_title() {
    local url="$1"
    local row="${CACHE_MEM[$url]}"
    
    # Fuzzy match by ID if direct lookup fails
    if [ -z "$row" ] && ([[ "$url" =~ ^http.* ]] || [[ "$url" == watch\?v=* ]]); then
        local vid_id=""
        local id_regex="[?&]id=([a-zA-Z0-9_-]{11})"
        local pb_regex="videoplayback/id/([a-zA-Z0-9_-]{11})"
        
        if [[ "$url" =~ v=([a-zA-Z0-9_-]{11}) ]]; then 
            vid_id="${BASH_REMATCH[1]}"
        elif [[ "$url" =~ watch\?v=([a-zA-Z0-9_-]{11}) ]]; then
            vid_id="${BASH_REMATCH[1]}"
        elif [[ "$url" =~ $id_regex ]]; then
            vid_id="${BASH_REMATCH[1]}"
        elif [[ "$url" =~ $pb_regex ]]; then
            vid_id="${BASH_REMATCH[1]}"
        fi
        
        if [ -n "$vid_id" ] && [ "${#vid_id}" -eq 11 ]; then
            for key in "${!CACHE_MEM[@]}"; do
                if [[ "$key" == *"$vid_id"* ]]; then
                    row="${CACHE_MEM[$key]}"
                    break
                fi
            done
        fi
    fi
    
    [ -n "$row" ] && echo "$row" | cut -f1 || echo ""
}

fetch_title_bg() {
    local url="$1"
    (
        local COOKIES_FILE="$HOME/.config/mpv/cookies.txt"
        local YTDL_OPTS=("--print" "%(title)s\t%(uploader)s\t%(duration_string)s" "--no-warnings" "--skip-download")
        [ -f "$COOKIES_FILE" ] && YTDL_OPTS+=("--cookies" "$COOKIES_FILE")

        local info=$(run_with_timeout 30s yt-dlp "${YTDL_OPTS[@]}" -- "$url" 2>/dev/null | sed 's/\\t/\t/g')
        if [ -n "$info" ]; then
            # info is "title\tartist\tduration"
            printf "%s\t%s\n" "$url" "$info" >> "$CACHE_FILE"
        else
            # Mark failed fetch in cache to stop retrying
            printf "%s\tLoading Metadata...\tUnknown\t0:00\n" "$url" >> "$CACHE_FILE"
        fi
        
        if [ $(wc -l < "$CACHE_FILE") -gt 5000 ]; then
                tail -n 4000 "$CACHE_FILE" > "$CACHE_FILE.tmp" && mv "$CACHE_FILE.tmp" "$CACHE_FILE"
        fi
    ) & disown
}

fetch_missing_background() {
    local LOCK_DIR="$HOME/.cache/mpv_queue_fetch.lock"
    # Atomic lock with mkdir
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        # Check if stale (older than 10 mins)
        local last_mod=$(get_file_mtime "$LOCK_DIR")
        local now=$(date +%s)
        if [ -n "$last_mod" ] && [ $((now - last_mod)) -gt 600 ]; then
             rm -rf "$LOCK_DIR"
             mkdir "$LOCK_DIR" || return # Retry once
        else
            return # Already running
        fi
    fi
    trap 'rm -rf "$LOCK_DIR"' EXIT

    # Load cache once for this background run
    load_cache_to_memory

    # Get current playlist from MPV
    local playlist_json=$(echo '{ "command": ["get_property", "playlist"] }' | mpv_nc 1 2>/dev/null)
    
    # Extract HTTP URLs that are NOT in cache or have old format
    local parallel_limit=5
    local current_jobs=0

    echo "$playlist_json" | jq -s -r 'map(select(.event == null)) | .[0].data | select(type == "array") | .[].filename' 2>/dev/null | grep '^http' | while IFS= read -r raw_url; do
        [ -z "$raw_url" ] && continue
        
        # Clean URL
        local url="${raw_url%%\\t*}"
        url="${url%%$'\t'*}"
        url="${url%%[[:space:]]*}"
        
        # Instant memory lookup
        local cached_row="${CACHE_MEM[$url]}"
        local col_count=$(echo -e "$cached_row" | awk -F'\t' '{print NF}')
        
        if [ -z "$cached_row" ] || [ "$col_count" -lt 3 ]; then
             # Parallel Fetch with a bit of a limit
             (
                 local COOKIES_FILE="$HOME/.config/mpv/cookies.txt"
                 local YTDL_OPTS=("--print" "%(title)s\t%(uploader)s\t%(duration_string)s" "--no-warnings" "--skip-download")
                 [ -f "$COOKIES_FILE" ] && YTDL_OPTS+=("--cookies" "$COOKIES_FILE")

                 local info=$(run_with_timeout 30s yt-dlp "${YTDL_OPTS[@]}" -- "$url" 2>/dev/null | sed 's/\\t/\t/g')
                 if [ -n "$info" ]; then
                     { printf "%s\t%s\n" "$url" "$info"; } >> "$CACHE_FILE"
                 else
                     # Fallback to prevent infinite loading
                     { printf "%s\tLoading Metadata...\tUnknown\t0:00\n" "$url"; } >> "$CACHE_FILE"
                 fi
             ) &
             
             ((current_jobs++))
             if [ "$current_jobs" -ge "$parallel_limit" ]; then
                 wait -n 2>/dev/null || wait
                 ((current_jobs--))
             fi
        fi
    done
    wait
}
