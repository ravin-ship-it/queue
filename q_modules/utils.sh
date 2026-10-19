QUEUE_VERSION="1.1.0"
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
    ( sleep 3; rm -f "$resume_cd" ) >/dev/null 2>&1 & disown

    if [ "$MPV_RUNNING" = true ]; then
        local raw_state=$(echo -e '{"command":["get_property","idle-active"]}\n{"command":["get_property","eof-reached"]}\n{"command":["get_property","pause"]}\n{"command":["get_property","time-pos"]}\n{"command":["get_property","playlist-count"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -s -j -r 'map(select(.event == null)) | (.[0].data // false), "\t", (.[1].data // false), "\t", (.[2].data // false), "\t", (.[3].data // 0), "\t", (.[4].data // 0)')
        IFS=$'\t' read -r is_idle is_eof is_paused time_pos pl_count <<< "$raw_state"
        
        # If idle, at EOF, or paused at beginning of a track (transition glitch), resume playback!
        local time_int=${time_pos%.*}
        [[ ! "$time_int" =~ ^[0-9]+$ ]] && time_int=0

        if [ "$is_idle" == "true" ] || [ "$is_eof" == "true" ] || { [ "$is_paused" == "true" ] && [ "$time_int" -le 1 ]; }; then
            if [ -n "$force_idx" ]; then
                 # Wait for playlist to actually have the item (Race condition fix)
                 for i in {1..15}; do
                     local cnt=$(echo '{ "command": ["get_property", "playlist-count"] }' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // 0')
                     if [ "$cnt" -gt "$force_idx" ]; then break; fi
                     sleep 0.1
                 done
                 # Force play specific index
                 echo "{ \"command\": [\"playlist-play-index\", $force_idx] }" | nc $NC_OPTS -w 1 "$SOCKET" > /dev/null 2>&1
            fi
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

get_queue_mode() {
    if [ "$IS_WSL" = true ] && [ -f "$HOME/.config/mpv/queue_mode" ]; then
        local mode
        mode=$(cat "$HOME/.config/mpv/queue_mode" 2>/dev/null | tr -d '[:space:]')
        if [ "$mode" == "hybrid" ]; then
            echo "hybrid"
            return 0
        fi
    fi
    echo "standalone"
}

get_windows_user_dir() {
    if [ "$IS_WSL" = true ]; then
        local win_prof
        win_prof=$(cmd.exe /c "echo %USERPROFILE%" </dev/null 2>/dev/null | tail -n 1 | tr -d '\r\n')
        if [ -n "$win_prof" ]; then
            local u_dir
            u_dir=$(wslpath -u "$win_prof" 2>/dev/null)
            if [ -d "$u_dir" ]; then
                echo "$u_dir"
                return 0
            fi
        fi
        for u in /mnt/c/Users/*; do
            local base
            base=$(basename "$u")
            if [ "$base" != "Public" ] && [ "$base" != "Default" ] && [ "$base" != "All Users" ] && [ "$base" != "Default User" ] && [ -d "$u" ]; then
                echo "$u"
                return 0
            fi
        done
    fi
    echo ""
}

get_windows_user() {
    local u_dir
    u_dir=$(get_windows_user_dir)
    if [ -n "$u_dir" ]; then
        basename "$u_dir"
    else
        echo "HP"
    fi
}

find_windows_mpv() {
    if [ -f "/mnt/c/Program Files/MPV Player/mpv.com" ]; then
        echo "/mnt/c/Program Files/MPV Player/mpv.com"
    elif [ -f "/mnt/c/Program Files/MPV Player/mpv.exe" ]; then
        echo "/mnt/c/Program Files/MPV Player/mpv.exe"
    elif command -v mpv.exe >/dev/null 2>&1; then
        command -v mpv.exe
    elif [ -f "/mnt/c/Users/$(get_windows_user)/AppData/Local/Microsoft/WinGet/Links/mpv.exe" ]; then
        echo "/mnt/c/Users/$(get_windows_user)/AppData/Local/Microsoft/WinGet/Links/mpv.exe"
    else
        echo ""
    fi
}

find_windows_ytdlp() {
    local win_dir
    win_dir=$(get_windows_user_dir)
    [ -z "$win_dir" ] && win_dir="/mnt/c/Users/HP"
    if [ -f "$win_dir/yt-dlp.exe" ]; then
        wslpath -w "$win_dir/yt-dlp.exe" 2>/dev/null
    elif [ -f "$win_dir/AppData/Local/Microsoft/WinGet/Packages/yt-dlp.yt-dlp_Microsoft.Winget.Source_8wekyb3d8bbwe/yt-dlp.exe" ]; then
        wslpath -w "$win_dir/AppData/Local/Microsoft/WinGet/Packages/yt-dlp.yt-dlp_Microsoft.Winget.Source_8wekyb3d8bbwe/yt-dlp.exe" 2>/dev/null
    elif [ -f "/mnt/c/Program Files/MPV Player/yt-dlp.exe" ]; then
        echo "C:\\Program Files\\MPV Player\\yt-dlp.exe"
    elif command -v yt-dlp.exe >/dev/null 2>&1; then
        echo "yt-dlp.exe"
    else
        echo ""
    fi
}

format_path_for_mpv() {
    local target="$1"
    if [ "$IS_WSL" = true ] && [ "$(get_queue_mode)" == "hybrid" ]; then
        if [[ ! "$target" =~ ^[a-zA-Z0-9]+:// ]] && [[ ! "$target" =~ ^http ]] && [ -e "$target" ]; then
            wslpath -w "$target" 2>/dev/null || echo "$target"
            return
        fi
    fi
    echo "$target"
}

ensure_piperelay_compiled() {
    local win_dir
    win_dir=$(get_windows_user_dir)
    [ -z "$win_dir" ] && win_dir="/mnt/c/Users/HP"
    local win_exe="$win_dir/PipeRelay.exe"

    if [ -f "$win_exe" ] && [ -x "$win_exe" ]; then
        echo "$win_exe"
        return 0
    fi

    local csc_compiler="/mnt/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
    [ ! -f "$csc_compiler" ] && csc_compiler="/mnt/c/Windows/Microsoft.NET/Framework/v4.0.30319/csc.exe"

    if [ ! -f "$csc_compiler" ]; then
        return 1
    fi

    local cs_src="$SCRIPT_DIR/scripts/PipeRelay.cs"
    [ ! -f "$cs_src" ] && cs_src="$HOME/.local/bin/mpv/scripts/PipeRelay.cs"
    [ ! -f "$cs_src" ] && cs_src="$(dirname "$MODULE_DIR")/scripts/PipeRelay.cs"

    if [ ! -f "$cs_src" ]; then
        return 1
    fi

    cp "$cs_src" "$win_dir/PipeRelay.cs" 2>/dev/null
    (cd "$win_dir" && "$csc_compiler" /out:PipeRelay.exe /target:exe /nologo PipeRelay.cs </dev/null >/dev/null 2>&1)
    rm -f "$win_dir/PipeRelay.cs" 2>/dev/null

    if [ -f "$win_exe" ]; then
        echo "$win_exe"
        return 0
    fi
    return 1
}

load_playlist_file_to_mpv() {
    local file="$1"
    local replace_mode="${2:-replace}"
    [ ! -f "$file" ] || [ ! -s "$file" ] && return 1

    local target_path
    target_path=$(format_path_for_mpv "$file")

    # High-speed path: MPV native loadlist loads thousands of tracks instantaneously
    local cmd_json
    cmd_json=$(jq -nc --arg path "$target_path" --arg m "$replace_mode" '{"command":["loadlist",$path,$m]}')
    echo "$cmd_json" | nc $NC_OPTS -w 1 "$SOCKET" >/dev/null 2>&1

    for i in {1..20}; do
        local cnt
        cnt=$(echo '{"command":["get_property","playlist-count"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | jq -r 'select(.event == null) | .data // 0' 2>/dev/null)
        if [[ "$cnt" =~ ^[0-9]+$ ]] && [ "$cnt" -gt 0 ]; then
            return 0
        fi
        sleep 0.05
    done
    return 0
}

ensure_windows_ytdlp_configured() {
    local win_dir
    win_dir=$(get_windows_user_dir)
    [ -z "$win_dir" ] && win_dir="/mnt/c/Users/HP"
    local win_user="${win_dir##*/}"

    local win_ytdlp_dir="$win_dir/AppData/Roaming/yt-dlp"
    mkdir -p "$win_ytdlp_dir" 2>/dev/null

    local cookie_src=""
    if [ -f "$HOME/.config/yt-dlp/cookies.txt" ]; then
        cookie_src="$HOME/.config/yt-dlp/cookies.txt"
    elif [ -f "$HOME/.cache/yt-dlp/cookies.txt" ]; then
        cookie_src="$HOME/.cache/yt-dlp/cookies.txt"
    elif [ -f "$HOME/.config/mpv/cookies.txt" ]; then
        cookie_src="$HOME/.config/mpv/cookies.txt"
    fi

    local win_cookies_txt="$win_ytdlp_dir/cookies.txt"
    if [ -n "$cookie_src" ] && [ ! -f "$win_cookies_txt" ]; then
        cp "$cookie_src" "$win_cookies_txt" 2>/dev/null
    fi

    local win_conf="$win_ytdlp_dir/config"
    if [ ! -f "$win_conf" ]; then
        cat <<EOF > "$win_conf"
--extractor-args "youtube:player_client=android,web"
--no-warnings
EOF
        if [ -f "$win_cookies_txt" ]; then
            echo "--cookies \"C:\\Users\\$win_user\\AppData\\Roaming\\yt-dlp\\cookies.txt\"" >> "$win_conf"
        fi
    fi

    if [ ! -f "$win_dir/yt-dlp.conf" ] && [ -f "$win_conf" ]; then
        cp "$win_conf" "$win_dir/yt-dlp.conf" 2>/dev/null
    fi

    local win_mpv_dir="$win_dir/AppData/Roaming/mpv"
    mkdir -p "$win_mpv_dir" 2>/dev/null
    if [ ! -f "$win_mpv_dir/mpv.conf" ] || grep -q "pulse" "$win_mpv_dir/mpv.conf" 2>/dev/null; then
        cat << 'EOF' > "$win_mpv_dir/mpv.conf"
# MPV Native Windows Configuration (Queue Engine)
vo=gpu
gpu-context=auto
hwdec=auto-safe
ao=wasapi
audio-channels=stereo

# Smooth Caching & Performance
cache=yes
demuxer-max-bytes=256MiB
demuxer-max-back-bytes=64MiB
demuxer-readahead-secs=60

# YouTube / Streaming
ytdl=yes
ytdl-format=bestvideo[height<=1440][fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1440][fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1080][fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1080][fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=720][fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=720][fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1440][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1080][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=720][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo+bestaudio/best
script-opts=ytdl_hook-ytdl_path=yt-dlp
ytdl-raw-options=extractor-args="youtube:player_client=android,web"
tls-verify=no

# Desktop Video & Window Behavior
autofit=50%x50%
geometry=50%:50%
force-window=immediate
keep-open=yes
title="Queue (Direct3D 11/12 Host)"
EOF
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

        local mode
        mode=$(get_queue_mode)

        # --- HYBRID WINDOWS ENGINE STARTUP (WSL2 Host Delegation) ---
        if [ "$mode" == "hybrid" ] && [ "$IS_WSL" = true ]; then
            local win_mpv
            win_mpv=$(find_windows_mpv)
            local relay_bin
            relay_bin=$(ensure_piperelay_compiled)

            if [ -n "$win_mpv" ] && [ -n "$relay_bin" ]; then
                taskkill.exe /F /IM mpv.exe </dev/null 2>/dev/null || true
                taskkill.exe /F /IM mpv.com </dev/null 2>/dev/null || true
                taskkill.exe /F /IM PipeRelay.exe </dev/null 2>/dev/null || true
                pkill -f "hybrid_bridge.py" 2>/dev/null || true

                local pipe_name="mpv-q-pipe"
                local win_ytdlp
                win_ytdlp=$(find_windows_ytdlp)
                local ytdl_arg=""
                [ -n "$win_ytdlp" ] && ytdl_arg="'--script-opts=ytdl_hook-ytdl_path=$win_ytdlp',"

                local script_arg=""
                local script_path="$SCRIPT_DIR/scripts/queue_video.lua"
                [ ! -f "$script_path" ] && script_path="$HOME/.config/mpv/scripts/queue_video.lua"
                [ ! -f "$script_path" ] && script_path="$(dirname "$MODULE_DIR")/scripts/queue_video.lua"
                if [ -f "$script_path" ]; then
                    local win_script
                    win_script=$(wslpath -w "$script_path" 2>/dev/null)
                    [ -n "$win_script" ] && script_arg="'--script=$win_script',"
                fi

                local win_mpv_native
                win_mpv_native=$(wslpath -w "$win_mpv" 2>/dev/null)
                [ -z "$win_mpv_native" ] && win_mpv_native="$win_mpv"

                ensure_windows_ytdlp_configured

                powershell.exe -NoProfile -Command "Start-Process -FilePath '$win_mpv_native' -ArgumentList '--idle=yes','--keep-open=yes','--vo=null','--video=no',${ytdl_arg}${script_arg}'--input-ipc-server=\\\\.\\pipe\\$pipe_name' -WindowStyle Hidden" </dev/null >/dev/null 2>&1

                local bridge_script="$MODULE_DIR/hybrid_bridge.py"
                [ ! -f "$bridge_script" ] && bridge_script="$SCRIPT_DIR/q_modules/hybrid_bridge.py"

                if command -v setsid >/dev/null 2>&1; then
                    setsid python3 "$bridge_script" "$SOCKET" "$pipe_name" "$relay_bin" </dev/null >/dev/null 2>&1 &
                else
                    nohup python3 "$bridge_script" "$SOCKET" "$pipe_name" "$relay_bin" </dev/null >/dev/null 2>&1 &
                fi
                disown

                for i in {1..30}; do
                    [ -S "$SOCKET" ] && break
                    sleep 0.1
                done

                if [ -S "$SOCKET" ]; then
                    # Verify IPC responsiveness (wait up to 3s for MPV to initialize IPC)
                    for attempt in {1..30}; do
                        if echo '{"command":["get_property","idle-active"]}' | nc $NC_OPTS -w 1 "$SOCKET" 2>/dev/null | grep -q "data"; then
                            break
                        fi
                        sleep 0.1
                    done

                    MPV_RUNNING=true
                    start_idle_monitor
                    if [ -n "$pl_arg" ] && [ -f "$pl_arg" ] && [ -s "$pl_arg" ]; then
                        load_playlist_file_to_mpv "$pl_arg" "replace"
                    fi
                    restore_state_properties
                    return 0
                fi
            fi
            # If hybrid startup encountered issues, cleanly fall back to standalone
        fi

        # --- STANDALONE ENGINE (WSLg, Bare-Metal Linux, or macOS) ---
        # Graphical display connection & GPU acceleration setup
        if [ "$IS_WSL" = true ]; then
            # WSL2 / WSLg: ensure display socket connection and host D3D12 GPU acceleration
            if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
                if [ -d "/mnt/wslg" ] || [ -S "/tmp/.X11-unix/X0" ]; then
                    export DISPLAY=":0"
                    export WAYLAND_DISPLAY="wayland-0"
                fi
            fi
            export GALLIUM_DRIVER="${GALLIUM_DRIVER:-d3d12}"
            if [ -d "/usr/lib/wsl/lib" ] && [[ ":$LD_LIBRARY_PATH:" != *":/usr/lib/wsl/lib:"* ]]; then
                export LD_LIBRARY_PATH="/usr/lib/wsl/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            fi
            export XCURSOR_THEME="${XCURSOR_THEME:-Adwaita}"
            export XCURSOR_SIZE="${XCURSOR_SIZE:-36}"
        elif [ "$IS_LINUX" = true ]; then
            # Native Linux (Wayland / X11): Let Mesa auto-detect native DRM GPU driver (iris/radeonsi/nvidia)
            # Never set GALLIUM_DRIVER=d3d12 or WSL lib paths on bare metal Linux!
            export XCURSOR_THEME="${XCURSOR_THEME:-Adwaita}"
            export XCURSOR_SIZE="${XCURSOR_SIZE:-24}"
        fi

        # Apply X11 cursor scale if display and xrdb are available (Linux/WSL)
        if [ "$IS_MACOS" = false ] && [ -n "$DISPLAY" ] && command -v xrdb >/dev/null 2>&1; then
            if [ -f "$HOME/.Xresources" ]; then
                xrdb -merge "$HOME/.Xresources" 2>/dev/null
            else
                echo -e "Xcursor.theme: $XCURSOR_THEME\nXcursor.size: $XCURSOR_SIZE" | xrdb -merge 2>/dev/null
            fi
        fi

        local input_conf_opt=()
        if [ -f "$HOME/.config/mpv/input.conf" ]; then
            input_conf_opt=("--input-conf=$HOME/.config/mpv/input.conf")
        fi

        local script_opt=()
        if [ -f "$HOME/.config/mpv/scripts/queue_video.lua" ]; then
            script_opt=("--script=$HOME/.config/mpv/scripts/queue_video.lua")
        elif [ -f "$SCRIPT_DIR/scripts/queue_video.lua" ]; then
            script_opt=("--script=$SCRIPT_DIR/scripts/queue_video.lua")
        fi

        if command -v setsid >/dev/null 2>&1; then
            setsid mpv --idle --keep-open=yes --no-terminal --vo=null --video=no \
                "${input_conf_opt[@]}" "${script_opt[@]}" \
                --input-ipc-server="$SOCKET" "${initial_pl[@]}" </dev/null >/dev/null 2>&1 &
        else
            nohup mpv --idle --keep-open=yes --no-terminal --vo=null --video=no \
                "${input_conf_opt[@]}" "${script_opt[@]}" \
                --input-ipc-server="$SOCKET" "${initial_pl[@]}" </dev/null >/dev/null 2>&1 &
        fi
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
            curl -s -X POST --unix-socket "$fzf_sock" -d "reload-sync(bash \"$script_path\" -raw)" http://localhost/ >/dev/null 2>&1 &
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
        mp3|flac|wav|m4a|ogg|opus|mp4|webm|mkv|avi|mov|ts|m3u|m3u8|aac|wma|alac|aiff|ape|m4v) return 0 ;;
        *) return 1 ;;
    esac
}

load_cache_to_memory() {
    declare -g -A CACHE_MEM=()
    [ ! -f "$CACHE_FILE" ] && return
    
    # Read the 4-column cache file into memory safely with local variables
    local c_url c_title c_artist c_dur
    while IFS=$'\t' read -r c_url c_title c_artist c_dur; do
        [ -z "$c_url" ] && continue
        # Store as a single tab-separated string for easy extraction
        CACHE_MEM["$c_url"]="${c_title}"$'\t'"${c_artist}"$'\t'"${c_dur}"
    done < "$CACHE_FILE"
}

get_cached_row() {
    local url="$1"
    echo -e "${CACHE_MEM[$url]}"
}

get_cached_title() {
    local url="$1"
    [ ${#CACHE_MEM[@]} -eq 0 ] && load_cache_to_memory
    local row="${CACHE_MEM[$url]}"
    
    # Fuzzy match by ID if direct lookup fails
    if [ -z "$row" ]; then
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
        elif [[ "$url" =~ ^[a-zA-Z0-9_-]{11}$ ]]; then
            vid_id="$url"
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
