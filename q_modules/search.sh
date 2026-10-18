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
        local s_header=$(printf "${C_GRAY}${H_LINE}${C_RESET}\n  ${C_PURPLE}🔍 Results for: ${C_CYAN}${QUERY}${C_RESET} ${C_GRAY}(ENTER select, TAB multi, CTRL-D dislike)${C_RESET}")
        local raw_sel=$(awk -F'\t' -v c="$C_CYAN" -v p="$C_LIGHT_PINK" -v o="$C_ORANGE" -v r="$C_RESET" -v clr_idx="$C_ORANGE" \
            '{gsub("::", ":", $1); gsub("::", ":", $3); gsub("::", ":", $4); printf "%s%d.%s %s%s %sby %s %s[%s]%s::%s::%s::%s::%s\n", clr_idx, NR, r, c, $1, p, $4, o, $3, r, $2, $1, $4, $3}' "$TMP_RESULTS" | \
            fzf --multi --exact --cycle --tiebreak=index --expect=ctrl-d,ctrl-x \
                --bind "tab:toggle,alt-a:toggle-all,insert:select-all,delete:deselect-all" --delimiter="::" --with-nth=1 --height=100% --layout=reverse --border --ansi \
                --bind 'ctrl-v:transform-query(echo -n {q}; get_clipboard)' \
                --header="$s_header" \
                $FZF_COLOR_OPTS \
                --info=inline-right --prompt="🎵 Select for \"$QUERY\" > ")
        
        [ -z "$raw_sel" ] && { echo -e "${C_PINK}👋 Selection cancelled for \"$QUERY\"${C_RESET}"; rm -f "$TMP_RESULTS"; return 1; }

        local key=$(head -n 1 <<< "$raw_sel")
        local selection=$(tail -n +2 <<< "$raw_sel")

        if [ -z "$selection" ]; then 
            echo -e "${C_PINK}👋 Selection cancelled for \"$QUERY\"${C_RESET}"
            rm -f "$TMP_RESULTS"
            return 1 # Skip to next query
        fi

        if [ "$key" == "ctrl-d" ] || [ "$key" == "ctrl-x" ]; then
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                local duration="${line##*::}"
                local tmp1="${line%::*}"
                local artist="${tmp1##*::}"
                local tmp2="${tmp1%::*}"
                local title="${tmp2##*::}"
                local tmp3="${tmp2%::*}"
                local url="${tmp3##*::}"
                add_to_auto_blacklist "$url" "$title"
                echo -e "${C_PINK}👎 Disliked & Blacklisted from Auto Mode:${C_RESET} ${C_CYAN}${title:-$url}${C_RESET}"
            done <<< "$selection"
            rm -f "$TMP_RESULTS"
            return 1
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

is_spotify_url() {
    local url="$1"
    if [[ "$url" =~ ^https?://(open\.)?spotify\.com/(track|album|playlist)/ ]] || [[ "$url" =~ ^spotify:(track|album|playlist): ]]; then
        return 0
    fi
    return 1
}

resolve_spotify_to_youtube() {
    local sp_url="$1"
    local temp_meta
    temp_meta=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/q_spotify_$$.tmp")

    python3 -c '
import urllib.request, re, json, html, sys

url = sys.argv[1]
m = re.search(r"(?:open\.spotify\.com/|spotify:)(track|album|playlist)[/:]([a-zA-Z0-9]+)", url)
if not m:
    sys.exit(1)

stype, sid = m.group(1), m.group(2)
embed_url = f"https://open.spotify.com/embed/{stype}/{sid}"
tracks = []

headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
req = urllib.request.Request(embed_url, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        content = resp.read().decode("utf-8", errors="ignore")
    m_data = re.search(r"<script id=\"__NEXT_DATA__\"[^>]*>([^<]+)</script>", content)
    if m_data:
        data = json.loads(m_data.group(1))
        entity = data.get("props", {}).get("pageProps", {}).get("state", {}).get("data", {}).get("entity", {})
        if stype == "track":
            title = entity.get("title") or entity.get("name")
            artists = ", ".join(a.get("name", "") for a in entity.get("artists", []))
            dur_ms = entity.get("duration") or 0
            if title:
                tracks.append((title, artists, int(dur_ms // 1000)))
        elif stype in ("album", "playlist"):
            for t in entity.get("trackList", []):
                t_title = t.get("title")
                t_artist = t.get("subtitle") or ""
                t_dur_ms = t.get("duration") or 0
                if t_title:
                    tracks.append((t_title, t_artist, int(t_dur_ms // 1000)))
except Exception:
    pass

# Fallback: scrape public HTML title and duration
if not tracks:
    main_url = f"https://open.spotify.com/{stype}/{sid}"
    req_main = urllib.request.Request(main_url, headers=headers)
    try:
        with urllib.request.urlopen(req_main, timeout=10) as resp:
            content = resp.read().decode("utf-8", errors="ignore")
        dur_s = 0
        dur_match = re.search(r"\"duration_ms\":\s*(\d+)", content)
        if dur_match:
            dur_s = int(dur_match.group(1)) // 1000

        title_m = re.search(r"<title>([^<]+)</title>", content)
        if title_m:
            raw = html.unescape(title_m.group(1))
            clean = re.sub(r"\s*\|\s*Spotify.*$", "", raw).strip()
            tm = re.match(r"^(.*?)\s*-\s*(?:song and lyrics by|song by|track by)\s*(.*?)$", clean, re.IGNORECASE)
            if tm:
                tracks.append((tm.group(1).strip(), tm.group(2).strip(), dur_s))
            else:
                tracks.append((clean, "", dur_s))
    except Exception:
        pass

for t, a, d in tracks:
    print(f"{t}\t{a}\t{d}")
' "$sp_url" > "$temp_meta" 2>/dev/null

    if [ ! -s "$temp_meta" ]; then
        echo -e "${C_PINK}⚠️ Could not extract metadata from Spotify link.${C_RESET}"
        rm -f "$temp_meta"
        return 1
    fi

    local track_count
    track_count=$(wc -l < "$temp_meta")
    if [ "$track_count" -gt 1 ]; then
        echo -e "${C_PINK}✨ Spotify Collection: Resolving ${C_ORANGE}${track_count}${C_PINK} tracks...${C_RESET}"
    fi

    local current=0
    local TAB=$'\t'
    local resolved_count=0

    while IFS=$'\t' read -r s_title s_artist s_dur; do
        [ -z "$s_title" ] && continue
        ((current++))
        [ -z "$s_dur" ] && s_dur=0

        if [ "$track_count" -eq 1 ]; then
            if [ -n "$s_artist" ]; then
                echo -e "${C_CYAN}🎧 Resolving Spotify:${C_RESET} ${C_WHITE}${s_title}${C_RESET} ${C_GRAY}(${s_artist})...${C_RESET}"
            else
                echo -e "${C_CYAN}🎧 Resolving Spotify:${C_RESET} ${C_WHITE}${s_title}${C_RESET}..."
            fi
        fi

        # Sanitize query: replace hyphens, underscores, slashes, quotes with spaces so YouTube never interprets "-word" as exclusion
        local clean_search_query
        clean_search_query=$(echo "$s_title $s_artist" | sed -E 's/[-_~/\\|"'"'"']/ /g' | tr -s ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

        # Fetch top 8 YouTube candidates for intelligent audio ranking
        local yt_cands
        yt_cands=$(timeout 15s yt-dlp --js-runtimes node --extractor-args "youtube:player_client=android,web" \
            --default-search "ytsearch8" \
            --print "%(webpage_url)s${TAB}%(title)s${TAB}%(uploader)s${TAB}%(duration_string)s" \
            --no-warnings --skip-download -- "$clean_search_query" 2>/dev/null)

        # Fallback query if no candidates: strip bracketed annotations like [Album ver.] or (feat. ...)
        if [ -z "$yt_cands" ]; then
            local clean_query
            clean_query=$(echo "$s_title" | sed -E 's/\[[^]]*\]//g; s/\([^)]*\)//g; s/[-_~/\\|"'"'"']/ /g')
            clean_query="$(echo "$clean_query" | tr -s ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') $s_artist"
            yt_cands=$(timeout 15s yt-dlp --js-runtimes node --extractor-args "youtube:player_client=android,web" \
                --default-search "ytsearch8" \
                --print "%(webpage_url)s${TAB}%(title)s${TAB}%(uploader)s${TAB}%(duration_string)s" \
                --no-warnings --skip-download -- "$clean_query" 2>/dev/null)
        fi

        # Score and pick the best audio match based on Spotify duration, artist, and studio quality
        local yt_res
        yt_res=$(python3 -c '
import sys, re

sp_title = sys.argv[1]
sp_artists = [a.strip() for a in sys.argv[2].split(",") if a.strip()]
try:
    sp_dur = int(sys.argv[3])
except Exception:
    sp_dur = 0

def parse_duration(d):
    if not d or d == "N/A": return 0
    parts = d.split(":")
    if len(parts) == 2: return int(parts[0])*60 + int(parts[1])
    if len(parts) == 3: return int(parts[0])*3600 + int(parts[1])*60 + int(parts[2])
    return 0

best_score = -99999
best_cand = None

stopwords = {"feat", "ft", "featuring", "by", "the", "a", "an", "and", "or", "of", "in", "on", "at", "to", "for", "with", "is", "it", "ver", "version"}
sp_tokens = [w for w in re.findall(r"[\w]+", sp_title.lower()) if w not in stopwords and len(w) > 1]

# Extract modifiers from brackets, parentheses, or dashes (e.g. "keisei REMIX", "Japanese.ver", "Radio Edit")
mods = re.findall(r"[\(\[\-]([^\(\)\[\]\-]+)[\)\]\-]?", sp_title)
mod_tokens = set()
for m in mods:
    for tok in re.findall(r"[\w]+", m.lower()):
        if tok not in stopwords and len(tok) > 1:
            mod_tokens.add(tok)

for line in sys.stdin:
    line = line.strip()
    if not line: continue
    parts = line.split("\t")
    if len(parts) < 4: continue
    url, title, uploader, dur = parts[0], parts[1], parts[2], parts[3]
    
    score = 0
    cand_s = parse_duration(dur)
    cand_lower = title.lower()
    uploader_lower = uploader.lower()

    # 1. Exact Duration comparison (studio releases closely match duration within 1-3s)
    if cand_s > 0 and sp_dur > 0:
        diff = abs(sp_dur - cand_s)
        if diff <= 2:
            score += 200
        elif diff <= 5:
            score += 140
        elif diff <= 10:
            score += 80
        elif diff <= 20:
            score += 30
        elif diff > 35:
            score -= 250
        elif diff > 60:
            score -= 600
        elif diff > 120:
            score -= 1200

    # 2. Title word matching
    for tok in sp_tokens:
        if tok in cand_lower:
            score += 40
        elif tok in uploader_lower:
            score += 35

    # 3. Creator/Artist & Remixer matching
    artist_matched = False
    for a in sp_artists:
        al = a.lower()
        if al and (al in uploader_lower or al in cand_lower):
            score += 80
            artist_matched = True
            break

    # If uploader matches a key non-generic token from sp_title (e.g. remixer name)
    if not artist_matched:
        for tok in sp_tokens:
            if tok not in {"remix", "original", "mix", "audio", "edit", "album", "single"} and len(tok) >= 3:
                if tok in uploader_lower:
                    score += 80
                    artist_matched = True
                    break

    # 4. - Topic channel / official distributor bonus
    if uploader_lower.endswith("- topic") or "- topic" in cand_lower:
        score += 100
    elif any(k in uploader_lower for k in ["official", "records", "vevo", "channel"]):
        score += 40
    elif not artist_matched:
        score -= 40 # Penalty for unverified third-party fan channels

    # 5. Clean studio audio bonus
    if re.search(r"(official\s+audio|audio\s+only|lyric\s+video|clean\s+audio)", cand_lower):
        score += 30

    # 6. Penalize unwanted modifiers if not present in the Spotify track title
    unwanted = ["cover", "remix", "live", "karaoke", "instrumental", "acoustic", "roblox", "speed up", "slowed", "reverb", "8d", "nightcore", "free download", "reaction", "bootleg", "bass boost", "tutorial", "lesson", "mashup"]
    for w in unwanted:
        if w in cand_lower and w not in sp_title.lower():
            score -= 180

    # 7. Specific modifier matching (e.g. remixer, acoustic, radio edit, live, japanese ver)
    if mod_tokens:
        matched_mods = sum(1 for m in mod_tokens if m in cand_lower or m in uploader_lower)
        score += matched_mods * 50
        # If the modifier specified a remixer (e.g. "keisei" with "remix")
        if "remix" in mod_tokens:
            remixers = {m for m in mod_tokens if m not in {"remix", "mix", "edit", "version", "ver"}}
            if remixers:
                matched_remixer = any(r in cand_lower or r in uploader_lower for r in remixers)
                if not matched_remixer:
                    score -= 200 # Heavy penalty for different/unrelated remix

    if score > best_score:
        best_score = score
        best_cand = f"{url}\t{title}\t{uploader}\t{dur}"

if best_cand and best_score > 0:
    print(best_cand)
' "$s_title" "$s_artist" "$s_dur" <<< "$yt_cands")

        local yt_url=$(echo -e "$yt_res" | awk -F'\t' '{print $1}')
        local yt_title=$(echo -e "$yt_res" | awk -F'\t' '{print $2}')
        local yt_artist=$(echo -e "$yt_res" | awk -F'\t' '{print $3}')
        local yt_dur=$(echo -e "$yt_res" | awk -F'\t' '{print $4}')

        if [ -n "$yt_url" ]; then
            ((resolved_count++))
            PLAYLIST_URLS+=("$yt_url")
            PLAYLIST_TITLES+=("${yt_title:-$s_title}")
            PLAYLIST_ARTISTS+=("${yt_artist:-$s_artist}")
            PLAYLIST_DURATIONS+=("$yt_dur")

            printf "%s\t%s\t%s\t%s\n" "$yt_url" "${yt_title:-$s_title}" "${yt_artist:-$s_artist}" "$yt_dur" >> "$CACHE_FILE"
            CACHE_MEM["$yt_url"]="${yt_title:-$s_title}"$'\t'"${yt_artist:-$s_artist}"$'\t'"$yt_dur"

            if [ "$track_count" -gt 1 ]; then
                echo -e "  ${C_GRAY}[${current}/${track_count}]${C_RESET} ${C_CYAN}${yt_title:-$s_title}${C_RESET} ${C_GRAY}[${yt_dur}]${C_RESET}"
            fi
        else
            echo -e "${C_PINK}  ⚠️ No YouTube match found for: ${C_WHITE}[${C_ORANGE}${s_title}${C_WHITE}] ${C_GRAY}(Skipping)${C_RESET}"
        fi
    done < "$temp_meta"

    rm -f "$temp_meta"

    if [ "$resolved_count" -eq 0 ]; then
        echo -e "${C_PINK}🚫 No tracks from the Spotify link could be found on YouTube.${C_RESET}"
        return 1
    fi
    return 0
}
