#!/usr/bin/env bash
# Advanced Queue Manager (Synced Fetch Edition) - Finalized

# --- SELF-HEALING & ENVIRONMENT VALIDATION ---
# Ensure essential directories exist
mkdir -p "$HOME/.cache/mpv" 2>/dev/null
mkdir -p "$HOME/.local/share/mpv/playlists" 2>/dev/null
touch "$HOME/.cache/mpv/yt_cache.txt" 2>/dev/null

# Clean up dead sockets automatically
if [ -S "$HOME/.mpv-socket" ]; then
    if ! (echo '{"command":["get_property","idle-active"]}' | nc -N -U -w 1 "$HOME/.mpv-socket" >/dev/null 2>&1); then
        rm -f "$HOME/.mpv-socket"
    fi
fi

# Validate Dependencies
for dep in mpv yt-dlp fzf jq; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo -e "\033[0;31m❌ FATAL: Missing dependency: $dep\033[0m"
        echo -e "\033[0;36m👉 Fix: Please re-run 'install.sh' from your q-production folder to auto-install.\033[0m"
        exit 1
    fi
done
if ! command -v nc >/dev/null 2>&1; then
    echo -e "\033[0;31m❌ FATAL: Missing dependency: netcat (nc)\033[0m"
    echo -e "\033[0;36m👉 Fix: Please re-run 'install.sh'.\033[0m"
    exit 1
fi

# --- MODULES ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$SCRIPT_DIR/q_modules" ]; then
    MODULE_DIR="$SCRIPT_DIR/q_modules"
else
    MODULE_DIR="$HOME/.local/bin/mpv/q_modules"
fi
if [ ! -d "$MODULE_DIR" ]; then
    echo -e "\033[0;31m❌ FATAL: Core modules are missing! (Did you accidentally delete q_modules?)\033[0m"
    echo -e "\033[0;36m👉 Fix: Please re-run 'install.sh' from your q-production folder.\033[0m"
    exit 1
fi
source "$MODULE_DIR/ui.sh"
source "$MODULE_DIR/utils.sh"
source "$MODULE_DIR/playlist.sh"
source "$MODULE_DIR/queue.sh"
source "$MODULE_DIR/media.sh"
source "$MODULE_DIR/search.sh"
source "$MODULE_DIR/batch.sh"

SCRIPT_PATH=$(realpath "$0")

# --- Stdin Support ---
if [ ! -t 0 ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Aggressively strip Nerd Font icons, emojis, and leading symbols/whitespace
        # We strip everything until the first alphanumeric character, slash, dot, or tilde.
        clean_line=$(echo "$line" | sed 's/^[^[:alnum:]\/._~]*//')
        
        # Determine the target file path
        target_path=""
        if [ -f "$clean_line" ]; then
             target_path="$clean_line"
        else
             # If cleaning didn't help, try the original but trimmed
             trimmed_line=$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
             if [ -f "$trimmed_line" ]; then
                 target_path="$trimmed_line"
             fi
        fi

        # Filter: Only add if it's a valid media file or a URL
        if [ -n "$target_path" ]; then
             if is_media_file "$target_path"; then
                 set -- "$@" "$target_path"
             fi
        elif [[ "$line" =~ ^http ]]; then
             set -- "$@" "$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        fi
    done
fi

# --- Command Parsing ---

PROCESSED_ANY_FLAG=false
SMART_CMDS="^(play|stop|next|prev|vol|info|list|clear|shuffle|remove|move|swap|help|save|load|auto|fx)$"

while [[ "$1" =~ ^- ]] || [[ "$1" =~ $SMART_CMDS ]]; do
    PROCESSED_ANY_FLAG=true
    
    # Normalize Smart Commands to Flags
    CMD="$1"
    if [[ ! "$CMD" =~ ^- ]]; then
        case "$CMD" in
            play) CMD="-p" ;;
            stop) CMD="-stop" ;;
            next) CMD="-next" ;;
            prev) CMD="-prev" ;;
            vol) CMD="-v" ;;
            info) CMD="-i" ;;
            list) CMD="-pl-list" ;;
            clear) CMD="-clr" ;;
            shuffle) CMD="-shuf" ;;
            remove) CMD="-rm" ;;
            move) CMD="-mv" ;;
            swap) CMD="-sw" ;;
            help) CMD="-h" ;;
            save) CMD="-pl-save" ;;
            load) CMD="-pl-load" ;;
            auto) CMD="-auto" ;;
            fx) CMD="-fx" ;;
        esac
    fi

    case "$CMD" in
        -rm) 
            shift
            targets=()
            while [[ -n "$1" ]] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ $SMART_CMDS ]]; do
                targets+=("$1")
                shift
            done
            cmd_remove "${targets[@]}"
            ;; 
        -rmr) cmd_remove_redundant; shift ;; 
        -pl-rmr) 
            shift
            found=false
            while [[ -n "$1" ]] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ $SMART_CMDS ]]; do
                 if [[ "$1" =~ ^[0-9]+$ ]]; then
                     file=$(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.txt" | sort | sed -n "${1}p")
                 else
                     file="${PLAYLIST_DIR}/${1}.txt"
                 fi
                 cmd_remove_redundant "$file"
                 found=true
                 shift
            done
            [ "$found" = false ] && { echo -e "${C_PINK}🔍🤷 Usage: -pl-rmr <name/index>${C_RESET}"; }
            ;; 
        -clean) cmd_clean; shift ;; 
        -pl-clean) 
            shift
            found=false
            while [[ -n "$1" ]] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ $SMART_CMDS ]]; do
                 if [[ "$1" =~ ^[0-9]+$ ]]; then
                     file=$(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.txt" | sort | sed -n "${1}p")
                 else
                     file="${PLAYLIST_DIR}/${1}.txt"
                 fi
                 cmd_clean "$file"
                 found=true
                 shift
            done
            [ "$found" = false ] && { echo -e "${C_PINK}🔍🤷 Usage: -pl-clean <name/index>${C_RESET}"; }
            ;; 
        -l) cmd_loop "single"; shift ;; 
        -lp) cmd_loop "playlist"; shift ;; 
        -mv) 
            shift
            while [[ -n "$1" ]] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ $SMART_CMDS ]] && \
                  [[ -n "$2" ]] && [[ ! "$2" =~ ^- ]] && [[ ! "$2" =~ $SMART_CMDS ]]; do
                cmd_move "$1" "$2"
                shift 2
            done
            ;; 
        -sw|-swap)
            shift
            while [[ -n "$1" ]] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ $SMART_CMDS ]] && \
                  [[ -n "$2" ]] && [[ ! "$2" =~ ^- ]] && [[ ! "$2" =~ $SMART_CMDS ]]; do
                cmd_swap "$1" "$2"
                shift 2
            done
            ;;
        -rname) 
            shift
            if [ -n "$1" ] && [ -n "$2" ]; then
                cmd_rename "$1" "$2"
                shift 2
            else
                cmd_rename "" "" # Trigger usage
            fi
            ;; 
        -clr) cmd_clear; shift ;; 
        -auto)
            if [ -f "$HOME/.cache/mpv/auto_enabled" ]; then
                rm "$HOME/.cache/mpv/auto_enabled"
                echo -e "${C_ORANGE}🤖 Auto Mode: DISABLED${C_RESET}"
            else
                touch "$HOME/.cache/mpv/auto_enabled"
                rm -f "$HOME/.cache/mpv/radio_enabled" # Cleanup old
                
                # Disable looping to allow Auto Mode to manage discovery at the end of the queue
                if [ "$MPV_RUNNING" = true ]; then
                    echo '{ "command": ["set_property", "loop-file", "no"] }' | nc -N -U -w 1 "$SOCKET" > /dev/null
                    echo '{ "command": ["set_property", "loop-playlist", "no"] }' | nc -N -U -w 1 "$SOCKET" > /dev/null
                fi

                echo -e "${C_PINK}🤖 Auto Mode: ENABLED${C_RESET}"
                echo -e "${C_GRAY}   -> 24/7 Zero-Gap Playback. Auto-queuing related hits & goldmines.${C_RESET}"
                # Start monitor if MPV is running
                [ "$MPV_RUNNING" = true ] && start_idle_monitor
                # Trigger immediate check if idle
                ( auto_queue_related ) >/dev/null 2>&1 &
            fi
            shift
            ;;
        -shuf) 
            shift
            if [[ "$1" == "list" ]]; then
                cmd_shuffle "list"
                shift
            else
                cmd_shuffle ""
            fi
            ;; 
        -p|-play) 
            shift
            found=false
            while [[ -n "$1" ]] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ $SMART_CMDS ]]; do
                cmd_play "$1"
                found=true
                shift
            done
            [ "$found" = false ] && cmd_play ""
            ;; 
        -next) cmd_next; shift ;; 
        -prev) cmd_prev; shift ;; 
        -stop) cmd_stop; shift ;; 
        -v|-vol) 
            shift
            found=false
            while [[ -n "$1" ]] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ $SMART_CMDS ]]; do
                cmd_volume "$1"
                found=true
                shift
            done
            [ "$found" = false ] && cmd_volume ""
            ;; 
        -fx)
            shift
            if [[ "$1" =~ ^(on|off|toggle|status)$ ]]; then
                cmd_audio_fx "$1"
                shift
            else
                cmd_audio_fx "toggle"
            fi
            ;;
        -i) 
            shift
            found=false
            while [[ -n "$1" ]] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ $SMART_CMDS ]]; do
                cmd_info "$1"
                found=true
                shift
            done
            [ "$found" = false ] && cmd_info ""
            ;; 
        -raw) 
            if [ "$IN_FZF" != "true" ]; then
                export SHOW_INDICATOR=true
            fi
            show_queue
            shift
            ;; 
        -pl-save|-save) 
            shift
            while [[ -n "$1" ]] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ $SMART_CMDS ]]; do
                cmd_playlist_save "$1"
                shift
            done
            ;; 
        -pl-load|-load) 
            shift
            found=false
            while [[ -n "$1" ]] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ $SMART_CMDS ]]; do
                cmd_playlist_load "$1"
                found=true
                shift
            done
            [ "$found" = false ] && cmd_playlist_load ""
            ;; 
        -pl-list|-list|-pl) cmd_playlist_list; shift ;; 
        -pl-raw) 
            shift
            found=false
            while [[ -n "$1" ]] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ $SMART_CMDS ]]; do
                cmd_playlist_raw "$1"
                found=true
                shift
            done
            [ "$found" = false ] && cmd_playlist_raw ""
            ;; 
        -pl-rm) 
            shift
            targets=()
            while [[ -n "$1" ]] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ $SMART_CMDS ]]; do
                targets+=("$1")
                shift
            done
            cmd_playlist_rm "${targets[@]}"
            ;; 
        -to) 
            shift
            export TARGET_PLAYLIST="$1"
            shift 
            ;; 
        -h|--help) show_help; shift ;; 
        *) 
            echo -e "${C_PINK}🧐 I don't know what \"$1\" is 🔫... is it your distant cousin 👀❔${C_RESET}"
            shift 
            ;; 
    esac
done

if [ "$PROCESSED_ANY_FLAG" = true ] && [ -z "$1" ]; then
    exit 0
fi

if [ -z "$1" ]; then
    export IN_FZF=true
    
    # Start idle monitor for interactive session if MPV is running
    [ "$MPV_RUNNING" = true ] && start_idle_monitor

    # Get initial status
    mapfile -t init < <(echo -e '{"command":["get_property","playlist-count"]}\n{"command":["get_property","shuffle"]}\n{"command":["get_property","loop-file"]}\n{"command":["get_property","loop-playlist"]}\n{"command":["get_property","af"]}' | nc -N -U -w 1 "$SOCKET" 2>/dev/null | jq -s -r 'map(select(.event == null)) | .[0].data // 0, .[1].data // false, .[2].data // "no", .[3].data // "no", (if .[4].data == null or .[4].data == [] then "off" else "on" end)')    
    init_count="${init[0]}"; init_shuf="${init[1]}"; init_loop_f="${init[2]}"; init_loop_p="${init[3]}"; init_af="${init[4]}"

    STATUS_ICONS=""
    P_DEEP_PINK="\033[38;5;197m"
    P_RESET="\033[0m"
    P_TEAL="\033[1;38;5;37m"
    P_YELLOW="\033[1;33m"
    P_PURPLE="\033[1;38;5;171m"
    [ "$init_shuf" == "true" ] && STATUS_ICONS="${STATUS_ICONS}${P_DEEP_PINK} ><${P_RESET}"
    [ "$init_loop_f" == "inf" ] && STATUS_ICONS="${STATUS_ICONS}${P_DEEP_PINK} ⟳1${P_RESET}"
    [ "$init_loop_p" == "inf" ] && STATUS_ICONS="${STATUS_ICONS}${P_DEEP_PINK} ⟳${P_RESET}"
    [ "$init_af" == "on" ] && STATUS_ICONS="${STATUS_ICONS}${P_DEEP_PINK} Ꭰᗡ${P_RESET}"
    [ -f "$HOME/.cache/mpv/auto_enabled" ] && STATUS_ICONS="${STATUS_ICONS}${P_DEEP_PINK} ◖∞◗${P_RESET}"

    if [ "$init_count" == "0" ]; then
        PROMPT=$(printf "🎵 ${P_TEAL}Queue List ${P_YELLOW}(${P_PURPLE}Empty${P_YELLOW})${STATUS_ICONS}${P_RESET} > ")
    else
        PROMPT=$(printf "🎵 ${P_TEAL}Queue List${STATUS_ICONS}${P_RESET} > ")
    fi

    FZF_SOCK="$HOME/.cache/mpv/fzf_$$.sock"
    echo "$FZF_SOCK" > "$HOME/.cache/mpv/fzf_sock"

    # Background Monitor
    (
        last_title=""; last_count="$init_count"; last_shuf="$init_shuf"
        last_lf="$init_loop_f"; last_lp="$init_loop_p"; last_idle="false"
        last_radio_state="init"; last_af="$init_af"
        socket_failures=0

        while true; do
            raw=$(echo -e '{"command":["get_property","idle-active"]}\n{"command":["get_property","media-title"]}\n{"command":["get_property","filename"]}\n{"command":["get_property","playlist-count"]}\n{"command":["get_property","shuffle"]}\n{"command":["get_property","loop-file"]}\n{"command":["get_property","loop-playlist"]}\n{"command":["get_property","playlist-pos-1"]}\n{"command":["get_property","af"]}' | nc -N -U -w 1 "$SOCKET" 2>/dev/null | jq -s -j -r '
                map(select(.event == null)) |
                (if .[0].data == null then true else .[0].data end), "\t",
                ((.[1].data // .[2].data) // "😴💤" | gsub("\n"; " ")), "\t",
                (.[3].data // 0), "\t",
                (if .[4].data == null then false else .[4].data end), "\t",
                (.[5].data // "no"), "\t",
                (if .[6].data == null then "no" else .[6].data end), "\t",
                (.[7].data // "?"), "\t",
                (if .[8].data == null or .[8].data == [] then "off" else "on" end)
            ' 2>/dev/null)
            
            if [ -z "$raw" ]; then
                ((socket_failures++))
                if [ "$socket_failures" -ge 15 ]; then break; fi
                sleep 2; continue
            fi
            socket_failures=0
            IFS=$'\t' read -r idle curr_title curr_count curr_shuf curr_lf curr_lp curr_idx curr_af <<< "$raw"

            curr_radio="off"
            [ -f "$HOME/.cache/mpv/auto_enabled" ] && curr_radio="on"

            if [ "$curr_title" != "$last_title" ] || [ "$idle" != "$last_idle" ]; then
                clean_title=$(echo "$curr_title" | sed 's/"/\"/g')
                ESC=$'\e'; NL=$'\n'
                C_PURP="${ESC}[1;38;5;171m"; C_PINK="${ESC}[1;38;5;198m"; C_ORNG="${ESC}[38;5;215m"
                C_WHT="${ESC}[1;37m"; C_GRY="${ESC}[0;90m"; C_RST="${ESC}[0m"; C_BLD="${ESC}[1m"
                cols=$(tput cols); width=$((cols - 4)); [ "$width" -lt 0 ] && width=0
                printf -v LINE "%*s" "$width" ""; LINE=${LINE// /─}
                
                if [ "$idle" == "true" ]; then
                    [ "$curr_title" == "😴💤" ] && msg="$curr_title" || msg="(Idle - Queue Finished)"
                    header_text="${C_PURP}🪷 Now Playing: ${C_RST}${C_PINK}${C_BLD}${msg}${C_RST}${NL}${C_GRY}${LINE}${C_RST}"
                else
                    header_text="${C_PURP}🪷 Now Playing ${C_WHT}[${C_ORNG}${curr_idx}${C_WHT}] ${C_RST}${C_PINK}${C_BLD}${clean_title}${C_RST}${NL}${C_GRY}${LINE}${C_RST}"
                fi
                curl -s -X POST --unix-socket "$FZF_SOCK" -d "change-header~${header_text}~" http://localhost/ >/dev/null 2>&1
                last_title="$curr_title"; last_idle="$idle"
                fi

                if [ "$curr_count" != "$last_count" ] || [ "$curr_shuf" != "$last_shuf" ] || [ "$curr_lf" != "$last_lf" ] || [ "$curr_lp" != "$last_lp" ] || [ "$curr_radio" != "$last_radio_state" ] || [ "$curr_af" != "$last_af" ]; then
                NEW_ICONS=""
                [ "$curr_shuf" == "true" ] && NEW_ICONS="${NEW_ICONS}${P_DEEP_PINK} ><${P_RESET}"
                [ "$curr_lf" == "inf" ] && NEW_ICONS="${NEW_ICONS}${P_DEEP_PINK} ⟳1${P_RESET}"
                [ "$curr_lp" == "inf" ] && NEW_ICONS="${NEW_ICONS}${P_DEEP_PINK} ⟳${P_RESET}"
                [ "$curr_af" == "on" ] && NEW_ICONS="${NEW_ICONS}${P_DEEP_PINK} Ꭰᗡ${P_RESET}"
                [ "$curr_radio" == "on" ] && NEW_ICONS="${NEW_ICONS}${P_DEEP_PINK} ◖∞◗${P_RESET}"

                if [ "$curr_count" == "0" ]; then
                    new_p=$(printf "🎵 ${P_TEAL}Queue List ${P_YELLOW}(${P_PURPLE}Empty${P_YELLOW})${NEW_ICONS}${P_RESET} > ")
                else
                    new_p=$(printf "🎵 ${P_TEAL}Queue List${NEW_ICONS}${P_RESET} > ")
                fi
                curl -s -X POST --unix-socket "$FZF_SOCK" -d "change-prompt~${new_p}~" http://localhost/ >/dev/null 2>&1                
                if [ "$curr_count" != "$last_count" ]; then
                    sleep 1.2
                    curl -s -X POST --unix-socket "$FZF_SOCK" -d "reload(bash \"$SCRIPT_PATH\" -raw)" http://localhost/ >/dev/null 2>&1
                fi
                last_count="$curr_count"; last_shuf="$curr_shuf"; last_lf="$curr_lf"; last_lp="$curr_lp"
                last_radio_state="$curr_radio"; last_af="$curr_af"
            fi
            sleep 2
        done
    ) &
    MONITOR_PID=$!
    
    mkdir -p "$HOME/.cache/mpv"
    SELECTION_MODE_FILE="$HOME/.cache/mpv/q_selection_mode_$$"
    rm -f "$SELECTION_MODE_FILE"
    
    trap "kill $MONITOR_PID 2>/dev/null; wait $MONITOR_PID 2>/dev/null; rm -f \"$HOME/.cache/mpv/fzf_sock\" \"$FZF_SOCK\" \"$SELECTION_MODE_FILE\"" EXIT

    selection=$(show_queue | fzf --multi --ansi --height=100% --layout=reverse --border \
        --listen="$FZF_SOCK" \
        $FZF_COLOR_OPTS \
        --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
        --bind "ctrl-r:reload(bash \"$SCRIPT_PATH\" -raw)" \
        --bind "alt-a:toggle-all+execute-silent(touch \"$SELECTION_MODE_FILE\")" \
        --bind "insert:select-all+execute-silent(touch \"$SELECTION_MODE_FILE\")" \
        --bind "delete:deselect-all+execute-silent(rm -f \"$SELECTION_MODE_FILE\")" \
        --bind "tab:toggle+execute-silent(touch \"$SELECTION_MODE_FILE\")" \
        --header="Loading..." \
        --info=inline-right --prompt="$PROMPT" | sed "s/\x1b\[[0-9;]*m//g" | sed -E -n 's/^[[:space:]]*([0-9]+)\..*/\1/p')
    
    kill $MONITOR_PID 2>/dev/null
    
    # Re-validate if MPV is actually running before processing selection
    # (Socket might have started while we were in FZF)
    if [ "$MPV_RUNNING" = false ]; then
        if [ -S "$SOCKET" ] && echo '{ "command": ["get_property", "idle-active"] }' | nc -N -U -w 1 "$SOCKET" &>/dev/null; then
            MPV_RUNNING=true
        fi
    fi
    
    if [ -n "$selection" ]; then
        count=$(echo "$selection" | wc -l)
        # Pre-fetch track info for any actions below
        track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc -N -U -w 1 "$SOCKET" 2>/dev/null)
        
        if [ "$count" -gt 1 ] || [ -f "$SELECTION_MODE_FILE" ]; then
             action=$(echo -e "  |>  Play Selected\n  ✖  Remove from Queue\n  ✚  Save to Playlist" | \
                 fzf --height=100% --layout=reverse --border --info=inline-right \
                 $FZF_COLOR_OPTS \
                 --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
                 --header="Action for $count item(s)?" \
                 --prompt="Choose > ")
             
             if [ -z "$action" ]; then exit 0; fi

             # 1. Save to Playlist
             if echo "$action" | grep -q "Save"; then
                 declare -a TARGET_FILES
                 pl_name=""
                 if [ ! -d "$PLAYLIST_DIR" ] || [ -z "$(ls -A "$PLAYLIST_DIR")" ]; then
                     pl_name=$(get_input "✚ Create New Playlist" "Name > ")
                 else 
                     pl_opt=""
                     i=1
                     while IFS= read -r f; do
                         [ -z "$f" ] && continue
                         pl_opt+="${C_ORANGE}${i}.${C_RESET} 📂 ${f}\n"
                         ((i++))
                     done < <(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.txt" -exec basename {} .txt \; | sort)

                     pl_choice=$(echo -ne "✚ Create New...\n$pl_opt" | fzf --multi --ansi --height=100% --layout=reverse --border --info=inline-right \
                         $FZF_COLOR_OPTS \
                         --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
                         --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" \
                         --prompt="Select Playlist(s) > ")
                     
                     if [ -z "$pl_choice" ]; then exit 0; fi

                     if [[ "$pl_choice" == *"Create New"* ]]; then
                         pl_name=$(get_input "✚ Enter New Playlist Name" "Name > ")
                     fi

                     # Process all selected existing playlists
                     while IFS= read -r line; do
                         [ -z "$line" ] || [[ "$line" == *"Create New"* ]] && continue
                         # Strip ANSI, index, and emoji
                         name=$(echo -e "$line" | sed "s/\x1b\[[0-9;]*m//g" | sed 's/^[ 0-9]*\. //' | sed 's/^📂 //')
                         [ -n "$name" ] && TARGET_FILES+=("${PLAYLIST_DIR}/${name}.txt")
                     done <<< "$pl_choice"
                 fi

                 # Execute Save
                 if [ -n "$pl_name" ]; then
                     TARGET_FILES+=("${PLAYLIST_DIR}/${pl_name}.txt")
                 fi

                 if [ ${#TARGET_FILES[@]} -gt 0 ]; then
                     for target_file in "${TARGET_FILES[@]}"; do
                         name=$(basename "$target_file" .txt)
                         echo -e "${C_PINK}✚  Adding ${C_ORANGE}$count${C_PINK} items to: ${C_CYAN}$name${C_RESET}"
                         while IFS= read -r idx; do
                             item_json=$(echo "$track_info" | jq -s -c "map(select(.event == null)) | .[0].data[$((idx - 1))] // empty")
                             url=$(echo "$item_json" | jq -r '.filename // ""')
                             [ -n "$url" ] && echo "$url" >> "$target_file"
                         done <<< "$selection"
                     done
                     echo -e "${C_GREEN}✅ Saved successfully.${C_RESET}"
                 fi
             fi

             # 2. Play Selected
             if echo "$action" | grep -q "Play Selected"; then
                 first=$(echo "$selection" | head -n1)
                 cmd_play "$first"
             fi

             # 3. Remove from Queue
             if echo "$action" | grep -q "Remove"; then
                 track_info=$(echo '{ "command": ["get_property", "playlist"] }' | nc -N -U -w 1 "$SOCKET" 2>/dev/null)
                 current_idx=$(echo "$track_info" | jq -s -r 'map(select(.event == null)) | .[0].data | to_entries[] | select(.value.current) | .key + 1' 2>/dev/null)
                 
                 was_playing=false
                 removed_playing_filename=""
                 removed_playing_title=""

                 while IFS= read -r idx; do
                     item_json=$(echo "$track_info" | jq -s -c "map(select(.event == null)) | .[0].data[$((idx - 1))] // empty")
                     [ -z "$item_json" ] && continue

                     filename=$(echo "$item_json" | jq -r '.filename // ""')
                     mpv_title=$(echo "$item_json" | jq -r '.title // ""')
                     is_current=$(echo "$item_json" | jq -r '.current // false')
                     
                     if [ "$is_current" == "true" ]; then
                         was_playing=true
                         removed_playing_filename="$filename"
                         removed_playing_title="$mpv_title"
                     fi

                     echo "{ \"command\": [\"playlist-remove\", $((idx - 1))] }" | nc -N -U -w 1 "$SOCKET" > /dev/null
                 done < <(echo "$selection" | sort -nr)
                 
                 echo -e "${C_PINK}✖  Removed ${C_ORANGE}$count${C_PINK} tracks.${C_RESET}"
                 ( sleep 0.3; save_current_playlist true ) >/dev/null 2>&1 & disown
                 
                 if [ "$was_playing" = true ]; then
                     is_paused=$(echo '{ "command": ["get_property", "pause"] }' | nc -N -U -w 1 "$SOCKET" 2>/dev/null | jq -r '.data // "false"')
                     wait_for_playback_start
                     if [ "$is_paused" == "true" ]; then
                         log_now_playing "|| Paused: "
                     else
                         log_now_playing
                     fi
                 fi

                 # Proactive auto-queue check after removal (Pass removed playing track meta to maintain discovery vibe)
                 ( auto_queue_related "$removed_playing_title" "$removed_playing_filename" ) >/dev/null 2>&1 & disown
             fi
        else
             cmd_play "$selection"
        fi
    fi
    exit 0
fi

# --- BATCH PROCESSING ---
declare -a PLAYLIST_URLS
declare -a PLAYLIST_TITLES

IS_BATCH=false
for arg in "$@"; do
    if [[ "$arg" =~ ^http.* ]] || [ -f "$arg" ]; then
        IS_BATCH=true
        break
    fi
done

if [ "$IS_BATCH" = true ]; then
    for input in "$@"; do
        if [ -f "$input" ]; then
            # Filter non-media local files
            if ! is_media_file "$input"; then
                continue
            fi
            TARGET=$(realpath -- "$input"); NAME=$(basename -- "$input")
            PLAYLIST_URLS+=("$TARGET"); PLAYLIST_TITLES+=("$NAME")
        elif [[ "$input" =~ ^http.* ]]; then
            if [[ "$input" == *"list=RD"* ]] && [[ "$input" != *"v="* ]]; then
                if [[ "$input" =~ list=RD([^&]+) ]]; then
                    VIDEO_ID="${BASH_REMATCH[1]}"
                    echo -e "${C_PINK}🔧 Fixing Mix URL (Detected broken RD-Link)...${C_RESET}"
                    input="https://www.youtube.com/watch?v=$VIDEO_ID&list=RD$VIDEO_ID"
                    echo -e "${C_GRAY}   -> $input${C_RESET}"
                fi
            fi

            echo -e "${C_CYAN}🔍 Analyzing URL:${C_RESET} $input"
            PL_TMP=$(mktemp)
            # Use strict 4-column format for analysis and caching
            timeout 45s yt-dlp --js-runtimes node --extractor-args "youtube:player_client=android,web" --flat-playlist --print "%(webpage_url)s\t%(title)s\t%(uploader)s\t%(duration_string)s" --no-warnings --skip-download -- "$input" > "$PL_TMP" 2>/dev/null
            
            # Debug: Store last raw output
            cp "$PL_TMP" "$HOME/.cache/mpv/last_yt_dlp_raw" 2>/dev/null

            if [ -s "$PL_TMP" ]; then
                LINE_COUNT=$(wc -l < "$PL_TMP")
                [ "$LINE_COUNT" -gt 1 ] && echo -e "${C_PINK}✨ Detected Playlist: Found $LINE_COUNT tracks.${C_RESET}" || echo -e "${C_GREEN}✅ Track resolved.${C_RESET}"

                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    
                    item_url=$(echo -e "$line" | awk -F'\t' '{print $1}')
                    item_title=$(echo -e "$line" | awk -F'\t' '{print $2}')
                    item_artist=$(echo -e "$line" | awk -F'\t' '{print $3}')
                    item_dur=$(echo -e "$line" | awk -F'\t' '{print $4}')

                    if [ -n "$item_url" ]; then
                        PLAYLIST_URLS+=("$item_url")
                        
                        # Only fallback to URL if title is truly empty or NA
                        if [ -z "$item_title" ] || [ "$item_title" == "NA" ] || [ "$item_title" == "null" ]; then
                            item_title="$item_url"
                        fi
                        
                        PLAYLIST_TITLES+=("$item_title")
                        PLAYLIST_ARTISTS+=("$item_artist")
                        PLAYLIST_DURATIONS+=("$item_dur")
                        
                        # Cache in unified 4-column format
                        if [ "$item_title" != "$item_url" ]; then
                             printf "%s\t%s\t%s\t%s\n" "$item_url" "$item_title" "$item_artist" "$item_dur" >> "$CACHE_FILE"
                             # Update memory cache immediately to prevent stale reads
                             CACHE_MEM["$item_url"]="${item_title}"$'\t'"${item_artist}"$'\t'"${item_dur}"
                        fi
                    fi
                done < "$PL_TMP"
            else
                echo -e "${C_PINK}🙈 Failed to fetch info... the internet might be playing hide and seek!${C_RESET}"
                PLAYLIST_URLS+=("$input"); PLAYLIST_TITLES+=("$input")
                fetch_title_bg "$input"
            fi
            rm "$PL_TMP"
        else
            PLAYLIST_URLS+=("$input"); PLAYLIST_TITLES+=("$input")
        fi
    done
    execute_batch
else
    PLATFORM="ytsearch40"
    case "$1" in
        yt|youtube) PLATFORM="ytsearch40"; shift ;; 
        sc|soundcloud) PLATFORM="scsearch40"; shift ;; 
    esac
    for QUERY in "$@"; do
        [ -z "$QUERY" ] && continue
        perform_search "$QUERY" "$PLATFORM"
        if [ $? -eq 0 ] && [ ${#PLAYLIST_URLS[@]} -gt 0 ]; then IS_SEARCH=true execute_batch; fi
    done
fi
