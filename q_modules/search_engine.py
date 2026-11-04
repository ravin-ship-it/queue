#!/usr/bin/env python3
"""
Queue Universal Dynamic Search Engine
Searches YouTube and SoundCloud concurrently with sub-second response times,
integrates liked/disliked badges, Spotify URL resolution, query caching, and
outputs formatted entries for live FZF integration.
"""

import sys
import os
import re
import json
import time
import hashlib
import urllib.request
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

CACHE_DIR = os.path.expanduser("~/.cache/mpv/search_cache")
SC_CID_FILE = os.path.expanduser("~/.cache/mpv/sc_client_id")
LIKED_FILE = os.path.expanduser("~/.cache/mpv/liked_tracks")
DISLIKED_FILE = os.path.expanduser("~/.cache/mpv/auto_blacklist")
LAST_PL_FILE = os.path.expanduser("~/.cache/mpv/last_playlist.txt")
TITLES_FILE = os.path.expanduser("~/.cache/mpv/titles.txt")

# ANSI Color Codes matching Queue's aesthetic
C_RESET = "\033[0m"
C_GRAY = "\033[0;90m"
C_CYAN = "\033[1;36m"
C_GREEN = "\033[1;32m"
C_YELLOW = "\033[1;33m"
C_ORANGE = "\033[38;5;215m"
C_PINK = "\033[38;5;198m"
C_LIGHT_PINK = "\033[38;5;211m"
C_PURPLE = "\033[1;38;5;171m"
C_TEAL = "\033[1;38;5;37m"
C_WHITE = "\033[1;37m"
C_BOLD = "\033[1m"
C_RED = "\033[1;31m"
C_SC_ORANGE = "\033[1;38;5;208m"

USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

# Load Liked, Disliked, and Queued tracks for instant badge rendering
def load_track_sets():
    liked = set()
    disliked = set()
    queued = set()

    if os.path.exists(LIKED_FILE):
        try:
            with open(LIKED_FILE, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    parts = line.strip().split("\t")
                    if parts and parts[0]:
                        liked.add(parts[0])
                        # Also extract video id if youtube
                        m = re.search(r"(?:v=|/)([a-zA-Z0-9_-]{11})", parts[0])
                        if m: liked.add(m.group(1))
        except Exception: pass

    if os.path.exists(DISLIKED_FILE):
        try:
            with open(DISLIKED_FILE, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    parts = line.strip().split("\t")
                    if parts and parts[0]:
                        disliked.add(parts[0])
                        m = re.search(r"(?:v=|/)([a-zA-Z0-9_-]{11})", parts[0])
                        if m: disliked.add(m.group(1))
        except Exception: pass

    if os.path.exists(LAST_PL_FILE):
        try:
            with open(LAST_PL_FILE, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    parts = line.strip().split("\t")
                    if parts and parts[0]:
                        queued.add(parts[0])
                        m = re.search(r"(?:v=|/)([a-zA-Z0-9_-]{11})", parts[0])
                        if m: queued.add(m.group(1))
        except Exception: pass

    return liked, disliked, queued

LIKED_SET, DISLIKED_SET, QUEUED_SET = load_track_sets()

def get_badge(url):
    m = re.search(r"(?:v=|/)([a-zA-Z0-9_-]{11})", url)
    vid = m.group(1) if m else url
    if url in LIKED_SET or vid in LIKED_SET:
        return "🩷 "
    if url in DISLIKED_SET or vid in DISLIKED_SET:
        return "💔 "
    if url in QUEUED_SET or vid in QUEUED_SET:
        return "🎧 "
    return ""

def format_entry(idx, item):
    title = item.get("title", "Unknown Track").replace("::", ":")
    artist = item.get("artist", "").replace("::", ":")
    dur = item.get("dur", "").replace("::", ":")
    url = item.get("url", "").replace("::", ":")
    platform = item.get("platform", "YouTube")

    badge = get_badge(url)
    
    if platform == "YouTube":
        plat_tag = f"{C_RED}[YouTube]{C_RESET}"
    elif platform == "SoundCloud":
        plat_tag = f"{C_SC_ORANGE}[SoundCloud]{C_RESET}"
    elif platform == "Spotify":
        plat_tag = f"{C_GREEN}[Spotify]{C_RESET}"
    else:
        plat_tag = f"{C_TEAL}[{platform}]{C_RESET}"

    artist_part = f" {C_GRAY}by{C_RESET} {C_LIGHT_PINK}{artist}{C_RESET}" if artist and artist != "null" else ""
    dur_part = f" {C_ORANGE}[{dur}]{C_RESET}" if dur and dur != "0:00" and dur != "N/A" else ""

    display = f" {C_ORANGE}{idx:2d}.{C_RESET} {badge}{plat_tag} {C_CYAN}{title}{C_RESET}{artist_part}{dur_part}"
    hidden = f"{url}::{title}::{artist}::{dur}::{platform}"
    return f"{display}::{hidden}"

# --- YOUTUBE FAST INNERTUBE SEARCH ---
def search_youtube_innertube(query, limit=18):
    url = "https://www.youtube.com/youtubei/v1/search?prettyPrint=false"
    payload = {
        "context": {
            "client": {
                "clientName": "WEB",
                "clientVersion": "2.20240101.00.00",
                "hl": "en",
                "gl": "US"
            }
        },
        "query": query
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT}
    )
    results = []
    try:
        with urllib.request.urlopen(req, timeout=4) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        sections = data.get("contents", {}).get("twoColumnSearchResultsRenderer", {}).get("primaryContents", {}).get("sectionListRenderer", {}).get("contents", [])
        for sec in sections:
            for it in sec.get("itemSectionRenderer", {}).get("contents", []):
                vr = it.get("videoRenderer")
                if vr:
                    vid = vr.get("videoId")
                    title = "".join([r.get("text", "") for r in vr.get("title", {}).get("runs", [])])
                    uploader = "".join([r.get("text", "") for r in vr.get("ownerText", {}).get("runs", [])])
                    dur = vr.get("lengthText", {}).get("simpleText", "0:00")
                    results.append({
                        "platform": "YouTube",
                        "title": title,
                        "url": f"https://www.youtube.com/watch?v={vid}",
                        "dur": dur,
                        "artist": uploader
                    })
                    if len(results) >= limit: break
            if len(results) >= limit: break
    except Exception:
        pass
    return results

# --- SOUNDCLOUD V2 FAST SEARCH ---
def get_sc_client_id():
    if os.path.exists(SC_CID_FILE):
        try:
            with open(SC_CID_FILE, "r", encoding="utf-8") as f:
                cid = f.read().strip()
                if cid and len(cid) == 32: return cid
        except Exception: pass
    return refresh_sc_client_id()

def refresh_sc_client_id():
    try:
        req = urllib.request.Request("https://soundcloud.com", headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=4) as r:
            html = r.read().decode("utf-8", errors="ignore")
        scripts = re.findall(r'src=\"(https://a-v2\.sndcdn\.com/assets/[^\"]+\.js)\"', html)
        for s in scripts[-3:]:
            req2 = urllib.request.Request(s, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req2, timeout=4) as r2:
                js = r2.read().decode("utf-8", errors="ignore")
            m = re.search(r'client_id:\"([a-zA-Z0-9]{32})\"', js)
            if m:
                cid = m.group(1)
                os.makedirs(os.path.dirname(SC_CID_FILE), exist_ok=True)
                with open(SC_CID_FILE, "w", encoding="utf-8") as f:
                    f.write(cid)
                return cid
    except Exception: pass
    return None

def search_soundcloud_api(query, limit=10):
    cid = get_sc_client_id()
    if not cid: return []
    q_enc = urllib.parse.quote(query)
    url = f"https://api-v2.soundcloud.com/search/tracks?q={q_enc}&limit={limit}&client_id={cid}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    results = []
    try:
        with urllib.request.urlopen(req, timeout=4) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        for t in data.get("collection", []):
            dur_ms = t.get("duration", 0)
            mins = dur_ms // 60000
            secs = (dur_ms % 60000) // 1000
            dur_str = f"{mins}:{secs:02d}"
            results.append({
                "platform": "SoundCloud",
                "title": t.get("title", "Unknown Track"),
                "url": t.get("permalink_url", ""),
                "dur": dur_str,
                "artist": t.get("user", {}).get("username", "SoundCloud Artist")
            })
    except urllib.error.HTTPError as e:
        if e.code == 401:
            refresh_sc_client_id()
    except Exception:
        pass
    return results

# --- YT-DLP FALLBACK ENGINE ---
def search_ytdlp(query, platform="ytsearch15"):
    results = []
    try:
        import subprocess
        cmd = [
            "yt-dlp",
            "--default-search", platform,
            "--print", "%(title)s\t%(webpage_url)s\t%(duration_string)s\t%(uploader)s",
            "--no-warnings",
            "--flat-playlist",
            "--skip-download",
            "--", query
        ]
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        stdout, _ = p.communicate(timeout=6)
        plat_name = "SoundCloud" if "scsearch" in platform else "YouTube"
        for line in stdout.splitlines():
            parts = line.strip().split("\t")
            if len(parts) >= 2:
                title = parts[0]
                url = parts[1]
                dur = parts[2] if len(parts) > 2 else "0:00"
                uploader = parts[3] if len(parts) > 3 else ""
                results.append({
                    "platform": plat_name,
                    "title": title,
                    "url": url,
                    "dur": dur,
                    "artist": uploader
                })
    except Exception:
        pass
    return results

# --- DIRECT URL HANDLER ---
def handle_direct_url(url):
    results = []
    # YouTube URL
    if "youtube.com" in url or "youtu.be" in url:
        m = re.search(r"(?:v=|youtu\.be/)([a-zA-Z0-9_-]{11})", url)
        vid = m.group(1) if m else ""
        # Quick oEmbed title lookup
        try:
            oe_url = f"https://www.youtube.com/oembed?url={urllib.parse.quote(url)}&format=json"
            req = urllib.request.Request(oe_url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=3) as resp:
                d = json.loads(resp.read().decode("utf-8"))
                results.append({
                    "platform": "YouTube",
                    "title": d.get("title", url),
                    "url": url,
                    "dur": "Auto",
                    "artist": d.get("author_name", "YouTube")
                })
                return results
        except Exception:
            pass
        results.append({
            "platform": "YouTube",
            "title": url,
            "url": url,
            "dur": "Auto",
            "artist": "Direct Link"
        })
        return results

    # SoundCloud URL
    if "soundcloud.com" in url:
        try:
            oe_url = f"https://soundcloud.com/oembed?url={urllib.parse.quote(url)}&format=json"
            req = urllib.request.Request(oe_url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=3) as resp:
                d = json.loads(resp.read().decode("utf-8"))
                results.append({
                    "platform": "SoundCloud",
                    "title": d.get("title", url),
                    "url": url,
                    "dur": "Auto",
                    "artist": d.get("author_name", "SoundCloud")
                })
                return results
        except Exception:
            pass
        results.append({
            "platform": "SoundCloud",
            "title": url,
            "url": url,
            "dur": "Auto",
            "artist": "Direct Link"
        })
        return results

    # Spotify URL
    if "spotify.com" in url or "spotify:" in url:
        try:
            oe_url = f"https://open.spotify.com/oembed?url={urllib.parse.quote(url)}"
            req = urllib.request.Request(oe_url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=3) as resp:
                d = json.loads(resp.read().decode("utf-8"))
                s_title = d.get("title", "")
                if s_title:
                    # Search YouTube for the Spotify title
                    yt_match = search_youtube_innertube(s_title, limit=3)
                    if yt_match:
                        for item in yt_match:
                            item["platform"] = "Spotify"
                        return yt_match
        except Exception:
            pass

    return results

# --- INITIAL EMPTY QUERY SUGGESTIONS ---
def render_empty_suggestions():
    lines = []
    # Header Tips
    tip1 = f" {C_PURPLE}✨ Queue Universal Search{C_RESET} {C_GRAY}• Type any song, artist, album, or paste a URL{C_RESET}"
    tip2 = f" {C_GRAY}💡 TAB: multi-select • ENTER: add to queue (stays open) • ALT-ENTER: add & exit • CTRL-P: switch platform • ESC: exit{C_RESET}"
    lines.append(f"{tip1}::tip1")
    lines.append(f"{tip2}::tip2")

    idx = 1
    # 1. Liked Songs
    if os.path.exists(LIKED_FILE):
        try:
            with open(LIKED_FILE, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    parts = line.strip().split("\t")
                    if len(parts) >= 2 and parts[0].startswith("http"):
                        url = parts[0]
                        title = parts[1]
                        artist = parts[2] if len(parts) > 2 else "Liked Song"
                        dur = parts[3] if len(parts) > 3 else ""
                        item = {"platform": "YouTube", "title": title, "url": url, "dur": dur, "artist": artist}
                        lines.append(format_entry(idx, item))
                        idx += 1
                        if idx > 12: break
        except Exception: pass

    # 2. Recent Queue History if needed
    if idx <= 12 and os.path.exists(TITLES_FILE):
        try:
            with open(TITLES_FILE, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    parts = line.strip().split("\t")
                    if len(parts) >= 2 and parts[0].startswith("http") and parts[0] not in LIKED_SET:
                        url = parts[0]
                        title = parts[1]
                        artist = parts[2] if len(parts) > 2 else "Recent Track"
                        dur = parts[3] if len(parts) > 3 else ""
                        item = {"platform": "YouTube", "title": title, "url": url, "dur": dur, "artist": artist}
                        lines.append(format_entry(idx, item))
                        idx += 1
                        if idx > 20: break
        except Exception: pass

    return lines

# --- MAIN EXECUTION ---
def main():
    raw_query = sys.argv[1].strip() if len(sys.argv) > 1 else ""
    platform_arg = sys.argv[2].strip() if len(sys.argv) > 2 else "all"

    # Resolve platform arg if it points to a state file
    if os.path.isfile(platform_arg):
        try:
            with open(platform_arg, "r", encoding="utf-8") as f:
                platform_arg = f.read().strip()
        except Exception:
            platform_arg = "all"

    platform = platform_arg.lower()
    if platform not in ("all", "yt", "sc"):
        platform = "all"

    # Query Prefix parsing (e.g. "yt: lofi" or "sc: synthwave")
    clean_query = raw_query
    if re.match(r"^(?:yt|youtube)[:\s]+", clean_query, re.I):
        clean_query = re.sub(r"^(?:yt|youtube)[:\s]+", "", clean_query, flags=re.I).strip()
        platform = "yt"
    elif re.match(r"^(?:sc|soundcloud)[:\s]+", clean_query, re.I):
        clean_query = re.sub(r"^(?:sc|soundcloud)[:\s]+", "", clean_query, flags=re.I).strip()
        platform = "sc"

    # Case A: Empty or single char query -> show helpful suggestions & liked tracks
    if len(clean_query) < 2:
        for line in render_empty_suggestions():
            print(line)
        return

    # Case B: Direct URL entered
    if clean_query.startswith("http://") or clean_query.startswith("https://") or clean_query.startswith("spotify:"):
        results = handle_direct_url(clean_query)
        if results:
            for i, item in enumerate(results, start=1):
                print(format_entry(i, item))
            return

    # Case C: Search Cache Check
    os.makedirs(CACHE_DIR, exist_ok=True)
    q_hash = hashlib.md5(f"{platform}:{clean_query.lower()}".encode("utf-8")).hexdigest()
    cache_path = os.path.join(CACHE_DIR, f"{q_hash}.json")
    if os.path.exists(cache_path):
        try:
            # Valid for 6 hours
            if time.time() - os.path.getmtime(cache_path) < 21600:
                with open(cache_path, "r", encoding="utf-8") as f:
                    cached_results = json.load(f)
                    if cached_results:
                        for i, item in enumerate(cached_results, start=1):
                            print(format_entry(i, item))
                        return
        except Exception:
            pass

    # Case D: Live Concurrent Search
    results = []
    if platform == "all":
        with ThreadPoolExecutor(max_workers=2) as executor:
            fut_yt = executor.submit(search_youtube_innertube, clean_query, 18)
            fut_sc = executor.submit(search_soundcloud_api, clean_query, 8)
            yt_res = fut_yt.result()
            sc_res = fut_sc.result()

        # If InnerTube failed, try yt-dlp fallback
        if not yt_res:
            yt_res = search_ytdlp(clean_query, "ytsearch15")
        if not sc_res and not yt_res:
            sc_res = search_ytdlp(clean_query, "scsearch8")

        # Interleave results: 2 YouTube, 1 SoundCloud
        i_yt, i_sc = 0, 0
        while i_yt < len(yt_res) or i_sc < len(sc_res):
            if i_yt < len(yt_res):
                results.append(yt_res[i_yt]); i_yt += 1
            if i_yt < len(yt_res):
                results.append(yt_res[i_yt]); i_yt += 1
            if i_sc < len(sc_res):
                results.append(sc_res[i_sc]); i_sc += 1
    elif platform == "yt":
        results = search_youtube_innertube(clean_query, 25)
        if not results:
            results = search_ytdlp(clean_query, "ytsearch25")
    elif platform == "sc":
        results = search_soundcloud_api(clean_query, 20)
        if not results:
            results = search_ytdlp(clean_query, "scsearch20")

    if not results:
        print(f" {C_PINK}⚠️ No results found for \"{clean_query}\" on {platform.upper()}. Try another query or switch platform (CTRL-P).{C_RESET}::no_results")
        return

    # Cache results
    try:
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump(results, f)
    except Exception:
        pass

    # Output formatted lines for FZF
    for i, item in enumerate(results, start=1):
        print(format_entry(i, item))

if __name__ == "__main__":
    main()
