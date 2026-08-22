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

# Detect Netcat UNIX socket flags (Universal for OpenBSD netcat, Ncat, Termux, Linux, macOS)
if [ -z "$NC_OPTS" ]; then
    NC_OPTS="-U"
    if nc -h 2>&1 | grep -q -- "-N"; then
        NC_OPTS="-N -U"
    fi
    export NC_OPTS
fi

SOCKET="$HOME/.mpv-socket"
MPV_RUNNING=false
if [ -S "$SOCKET" ]; then
    # Verify if socket is actually responsive (1s timeout)
    if echo '{ "command": ["get_property", "idle-active"] }' | nc $NC_OPTS -w 1 "$SOCKET" &>/dev/null; then
        MPV_RUNNING=true
    else
        # Stale socket detected
        rm -f "$SOCKET"
    fi
fi

check_socket() {
    [ -S "$SOCKET" ] && echo '{ "command": ["get_property", "idle-active"] }' | nc $NC_OPTS -w 1 "$SOCKET" &>/dev/null
}

is_online() {
    ping -c 1 -W 2 1.1.1.1 &>/dev/null || ping -c 1 -W 2 8.8.8.8 &>/dev/null || curl -s --max-time 3 -o /dev/null https://www.google.com &>/dev/null
}

check_and_resume() {
    local force_idx="$1"
    
    # Cooldown to prevent duplicate concurrent triggers
    local resume_cd="$HOME/.cache/mpv/auto_resume_cd"
    if [ -f "$resume_cd" ]; then return; fi
    touch "$resume_cd"
    ( sleep 5; rm -f "$resume_cd" ) >/dev/null 2>&1 & disown

    if [ "$MPV_RUNNING" = true ]; then
        local raw_state=$(echo -e '{"command":["get_property","idle-active"]}\n{"command":["get_property","eof-reached"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -j -r 'map(select(.event == null)) | (.[0].data // false), "\t", (.[1].data // false)')
        IFS=$'\t' read -r is_idle is_eof <<< "$raw_state"
        
        # If idle or paused at EOF, we must intervene
        if [ "$is_idle" == "true" ] || [ "$is_eof" == "true" ]; then
            if [ -n "$force_idx" ]; then
                 # Wait for playlist to actually have the item (Race condition fix)
                 for i in {1..15}; do
                     local cnt=$(echo '{ "command": ["get_property", "playlist-count"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0')
                     if [ "$cnt" -gt "$force_idx" ]; then break; fi
                     sleep 0.1
                 done
                 # Force play specific index
                 echo "{ \"command\": [\"playlist-play-index\", $force_idx] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
            else
                 # Fallback to next
                 echo '{ "command": ["playlist-next"] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
            fi
            echo '{ "command": ["seek", 0, "absolute"] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
            echo '{ "command": ["set_property", "pause", false] }' | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
            
            # Check success
            sleep 0.2
            local new_idle=$(echo '{ "command": ["get_property", "idle-active"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // "false"')
            if [ "$new_idle" == "false" ]; then
                log_now_playing "|> Playing (Auto): "
            else
                echo -e "${C_GRAY}(Resume check failed: still idle)${C_RESET}"
            fi
        fi
    fi
}

ensure_mpv_running() {
    local pl_arg="$1"
    if [ "$MPV_RUNNING" = false ] || [ ! -S "$SOCKET" ]; then
        rm -f "$SOCKET"
        local initial_pl=()
        if [ -n "$pl_arg" ] && [ -f "$pl_arg" ] && [ -s "$pl_arg" ]; then
            initial_pl=("--playlist=$pl_arg")
        fi

        setsid mpv --idle --keep-open=yes --no-terminal --vo=null \
            --input-ipc-server="$SOCKET" "${initial_pl[@]}" </dev/null >/dev/null 2>&1 &
        disown

        for i in {1..30}; do
            [ -S "$SOCKET" ] && break
            sleep 0.1
        done

        MPV_RUNNING=true
        start_idle_monitor
        restore_state_properties
    fi
}

send_ipc() {
    echo "$1" | nc $NC_OPTS -w 1 "$SOCKET"
}

notify_fzf_reload() {
    if [ -f "$HOME/.cache/mpv/fzf_sock" ]; then
        local fzf_sock=$(cat "$HOME/.cache/mpv/fzf_sock" 2>/dev/null)
        if [ -n "$fzf_sock" ] && [ -S "$fzf_sock" ]; then
            local script_path="${0:-q}"
            [[ ! "$script_path" =~ ^/ ]] && script_path=$(command -v "$script_path" || echo "/home/xen/.local/bin/mpv/q")
            curl -s -X POST --unix-socket "$fzf_sock" -d "reload(bash \"$script_path\" -raw)" http://localhost/ >/dev/null 2>&1 &
        fi
    fi
}

save_current_playlist() {
    local force="${1:-false}"
    local allow_empty="${2:-false}"
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

    local raw=$(echo -e '{"command":["get_property","playlist"]}\n{"command":["get_property","shuffle"]}\n{"command":["get_property","loop-file"]}\n{"command":["get_property","loop-playlist"]}\n{"command":["get_property","playlist-pos"]}' | nc $NC_OPTS -w 2 "$SOCKET" 2>/dev/null | jq -s -c -r 'map(select(.event == null))')
    
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
                cp -f "$LAST_PLAYLIST_FILE" "${LAST_PLAYLIST_FILE}.bak" 2>/dev/null
            elif [ "$new_count" -eq 0 ] && [ "$allow_empty" == "true" ]; then
                # Queue is genuinely cleared by explicit user command (e.g. q -clr)
                > "$LAST_PLAYLIST_FILE"
            fi

            # Save state properties to state.json
            echo "$raw" | jq -c 'map(select(.data != null and (.data | type != "array"))) | {shuffle: .[0].data, loop_file: .[1].data, loop_playlist: .[2].data, pos: .[3].data}' 2>/dev/null > "$HOME/.cache/mpv/state.json.tmp"
            [ -s "$HOME/.cache/mpv/state.json.tmp" ] && mv "$HOME/.cache/mpv/state.json.tmp" "$HOME/.cache/mpv/state.json"
            notify_fzf_reload
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
    
    echo "{ \"command\": [\"set_property\", \"shuffle\", $shuf] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
    echo "{ \"command\": [\"set_property\", \"loop-file\", \"$lf\"] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
    echo "{ \"command\": [\"set_property\", \"loop-playlist\", \"$lp\"] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
    
    # Only restore position if it's valid
    if [ "$pos" != "null" ] && [ "$pos" -ge 0 ]; then
        echo "{ \"command\": [\"set_property\", \"playlist-pos\", $pos] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
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
    local secs="${1%s}"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
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
        local YTDL_OPTS=("--js-runtimes" "node" "--extractor-args" "youtube:player_client=android,web" "--print" "%(title)s\t%(uploader)s\t%(duration_string)s" "--no-warnings" "--skip-download")
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

    if ! is_online; then
        return
    fi

    # Load cache once for this background run
    load_cache_to_memory

    # Get current playlist from MPV
    local playlist_json=$(echo '{ "command": ["get_property", "playlist"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null)
    
    # Extract HTTP URLs that are NOT in cache or have old format
    local parallel_limit=2
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
             # Background fetch with lowest scheduling priority (nice 19) to never interrupt audio playback
             (
                 local COOKIES_FILE="$HOME/.config/mpv/cookies.txt"
                 local YTDL_OPTS=("--js-runtimes" "node" "--extractor-args" "youtube:player_client=android,web" "--print" "%(title)s\t%(uploader)s\t%(duration_string)s" "--no-warnings" "--skip-download")
                 [ -f "$COOKIES_FILE" ] && YTDL_OPTS+=("--cookies" "$COOKIES_FILE")

                 local info=$(run_with_timeout 30s nice -n 19 yt-dlp "${YTDL_OPTS[@]}" -- "$url" 2>/dev/null | sed 's/\\t/\t/g')
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
             sleep 0.1
        fi
    done
    wait
}
