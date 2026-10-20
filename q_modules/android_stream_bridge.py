#!/usr/bin/env python3
"""
android_stream_bridge.py: Termux to MPV Android Local Stream Bridge
Serves dynamic M3U playlists and just-in-time HTTP 302 redirects for YouTube and local media streams.
Provides continuous multi-track playback, background pre-fetching, and Android Media notification support.
"""

import os
import sys
import json
import time
import socket
import signal
import threading
import subprocess
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_PORT = 8989
HOME = os.environ.get("HOME", "/data/data/com.termux/files/home")
CACHE_DIR = os.path.join(HOME, ".cache", "mpv")
CONFIG_DIR = os.path.join(HOME, ".config", "mpv")
PID_FILE = os.path.join(CACHE_DIR, "android_bridge.pid")
PORT_FILE = os.path.join(CACHE_DIR, "android_bridge.port")
CACHE_FILE = os.path.join(CACHE_DIR, "android_stream_cache.json")
TITLES_FILE = os.path.join(CACHE_DIR, "titles.txt")
RES_FILE = os.path.join(CONFIG_DIR, "queue_res")
LANG_FILE = os.path.join(CONFIG_DIR, "queue_lang")
DEFAULT_SOCKET = os.path.join(HOME, ".mpv-socket")
LAST_PLAYLIST_FILE = os.path.join(CACHE_DIR, "last_playlist.txt")

# Thread-safe stream URL cache: url -> {"edl": str, "expire": float, "res": str, "title": str}
stream_cache = {}
cache_lock = threading.Lock()
prefetch_queue = set()
prefetch_lock = threading.Lock()

def get_configured_resolution():
    """Retrieve saved resolution preference from ~/.config/mpv/queue_res."""
    if os.path.exists(RES_FILE):
        try:
            with open(RES_FILE, "r", encoding="utf-8") as f:
                content = f.read().strip().lower()
                if content:
                    return content
        except Exception:
            pass
    return "1080"

def get_configured_language():
    """Retrieve saved language preference from ~/.config/mpv/queue_lang."""
    if os.path.exists(LANG_FILE):
        try:
            with open(LANG_FILE, "r", encoding="utf-8") as f:
                content = f.read().strip().lower()
                if content:
                    return content
        except Exception:
            pass
    return "en"

def get_audio_selection(lang_pref=None):
    if not lang_pref:
        lang_pref = get_configured_language()
    lang_pref = lang_pref.lower()
    if lang_pref in ("auto", "orig", "original"):
        return "(bestaudio[acodec=opus]/bestaudio)"
    return f"(bestaudio[language={lang_pref}][acodec=opus]/bestaudio[language^={lang_pref}]/bestaudio[language={lang_pref}]/bestaudio[language^={lang_pref}]/bestaudio[acodec=opus]/bestaudio)"

def get_ytdl_format(res_pref=None, lang_pref=None):
    """Generate optimal yt-dlp format string based on target resolution and language."""
    if not res_pref:
        res_pref = get_configured_resolution()
    res_pref = res_pref.lower()
    audio_sel = get_audio_selection(lang_pref)
    if res_pref in ("720", "720p", "hd"):
        return f"bestvideo[height<=720]+{audio_sel}/best[height<=720]/best"
    elif res_pref in ("1080", "1080p", "fhd"):
        return f"bestvideo[height<=1080]+{audio_sel}/best[height<=1080]/best"
    elif res_pref in ("1440", "1440p", "2k", "qhd"):
        return f"bestvideo[height<=1440]+{audio_sel}/best[height<=1440]/best"
    elif res_pref in ("2160", "2160p", "4k", "uhd", "max"):
        return f"bestvideo+{audio_sel}/best"
    elif res_pref in ("480", "480p", "sd"):
        return f"bestvideo[height<=480]+{audio_sel}/best[height<=480]/best"
    elif res_pref in ("360", "360p", "low"):
        return f"bestvideo[height<=360]+{audio_sel}/best[height<=360]/best"
    else:  # auto / smart adaptive
        return f"bestvideo[height<=1080][fps<=60]+{audio_sel}/bestvideo[height<=720]+{audio_sel}/best"

def load_persistent_cache():
    global stream_cache
    if os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                now = time.time()
                current_res = get_configured_resolution()
                # Only keep items that have at least 10 minutes before expiring and match current resolution
                stream_cache = {k: v for k, v in data.items() if v.get("expire", 0) > now + 600 and v.get("res", "1080") == current_res}
        except Exception:
            stream_cache = {}

def save_persistent_cache():
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with cache_lock:
            with open(CACHE_FILE, "w", encoding="utf-8") as f:
                json.dump(stream_cache, f, indent=2)
    except Exception:
        pass

def load_titles_cache():
    """Load cached track titles from titles.txt."""
    titles = {}
    if os.path.exists(TITLES_FILE):
        try:
            with open(TITLES_FILE, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    parts = line.strip().split("\t")
                    if len(parts) >= 2 and parts[0] and parts[1]:
                        titles[parts[0]] = parts[1]
        except Exception:
            pass
    return titles

def parse_expire_timestamp(stream_url):
    """Extract expire query parameter from GoogleVideo URL or default to 5 hours."""
    try:
        parsed = urllib.parse.urlparse(stream_url)
        queries = urllib.parse.parse_qs(parsed.query)
        if "expire" in queries:
            return float(queries["expire"][0])
    except Exception:
        pass
    return time.time() + 18000.0

def query_mpv_socket(cmd_dict, timeout=1.5):
    """Query MPV UNIX domain IPC socket and return response data."""
    sock_path = os.environ.get("SOCKET", DEFAULT_SOCKET)
    if not os.path.exists(sock_path):
        return None
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(sock_path)
        payload = (json.dumps(cmd_dict) + "\n").encode("utf-8")
        s.sendall(payload)

        buffer = ""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                chunk = s.recv(8192)
            except socket.timeout:
                break
            if not chunk:
                break
            buffer += chunk.decode("utf-8", errors="ignore")

            # Process complete lines from socket stream
            while "\n" in buffer:
                line, buffer = buffer.split("\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                    # Skip asynchronous event messages
                    if "event" in msg and "data" not in msg:
                        continue
                    if "data" in msg:
                        s.close()
                        return msg["data"]
                    if msg.get("error") == "success":
                        s.close()
                        return msg.get("data")
                except json.JSONDecodeError:
                    continue
        s.close()
    except Exception:
        pass
    return None

def get_current_playlist():
    """Retrieve active playlist items from MPV socket or last_playlist.txt fallback."""
    titles_cache = load_titles_cache()

    # Priority 1: Query active MPV socket
    pl_data = query_mpv_socket({"command": ["get_property", "playlist"]})
    if pl_data and isinstance(pl_data, list) and len(pl_data) > 0:
        items = []
        for i, entry in enumerate(pl_data):
            fn = entry.get("filename", "")
            title = entry.get("title", "")
            if not title or title.startswith("http") or title.startswith("watch?v="):
                title = titles_cache.get(fn, "")
            if not title:
                title = os.path.basename(fn) if "/" in fn else fn
            items.append({"index": i, "url": fn, "title": title, "current": entry.get("current", False)})
        return items

    # Priority 2: Read from LAST_PLAYLIST_FILE
    if os.path.exists(LAST_PLAYLIST_FILE):
        try:
            items = []
            with open(LAST_PLAYLIST_FILE, "r", encoding="utf-8") as f:
                for i, line in enumerate(f):
                    url = line.strip()
                    if url:
                        title = titles_cache.get(url, "")
                        if not title:
                            title = os.path.basename(url) if "/" in url else url
                        items.append({"index": i, "url": url, "title": title, "current": (i == 0)})
            if items:
                return items
        except Exception:
            pass

    return []

def resolve_track_edl(raw_url):
    """Resolve a raw track URL into an Edit Decision List (EDL) for MPV.
    Combines high-res video (1080p60/4K) and pristine audio (Opus) into a single virtual stream."""
    now = time.time()
    current_res = get_configured_resolution()

    with cache_lock:
        if raw_url in stream_cache:
            entry = stream_cache[raw_url]
            if entry.get("res") == current_res and entry.get("expire", 0) > now + 300:
                return entry.get("edl", "")

    # Local file: return EDL pointing to local file path directly
    if not raw_url.startswith("http://") and not raw_url.startswith("https://"):
        local_path = os.path.abspath(raw_url) if os.path.exists(raw_url) else raw_url
        p_bytes = local_path.encode("utf-8")
        return f"# mpv EDL v0\n%{len(p_bytes)}%{local_path}\n"

    # Online stream: resolve via yt-dlp with configured resolution format
    fmt = get_ytdl_format(current_res)
    cmd = [
        "yt-dlp",
        "-g",
        "--no-warnings",
        "--extractor-args", "youtube:player_client=visionos,android,web",
        "-f", fmt,
        raw_url
    ]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=14)
        if proc.returncode == 0 and proc.stdout.strip():
            lines = [l.strip() for l in proc.stdout.strip().splitlines() if l.strip()]
            expire = now + 18000.0
            if len(lines) >= 2:
                v_url, a_url = lines[0], lines[1]
                v_bytes = v_url.encode("utf-8")
                a_bytes = a_url.encode("utf-8")
                edl_content = f"# mpv EDL v0\n%{len(v_bytes)}%{v_url}\n!new_stream\n%{len(a_bytes)}%{a_url}\n"
                expire = parse_expire_timestamp(v_url)
            elif len(lines) == 1:
                u = lines[0]
                u_bytes = u.encode("utf-8")
                edl_content = f"# mpv EDL v0\n%{len(u_bytes)}%{u}\n"
                expire = parse_expire_timestamp(u)
            else:
                edl_content = ""

            if edl_content:
                with cache_lock:
                    stream_cache[raw_url] = {
                        "edl": edl_content,
                        "res": current_res,
                        "expire": expire,
                        "cached_at": now
                    }
                save_persistent_cache()
                return edl_content
    except Exception as e:
        print(f"[Bridge] Error resolving {raw_url}: {e}", file=sys.stderr)

    # Fallback to single raw URL
    r_bytes = raw_url.encode("utf-8")
    return f"# mpv EDL v0\n%{len(r_bytes)}%{raw_url}\n"

def background_prefetch_worker(raw_url):
    """Background worker to resolve upcoming tracks without blocking playback."""
    with prefetch_lock:
        if raw_url in prefetch_queue:
            return
        prefetch_queue.add(raw_url)

    try:
        now = time.time()
        current_res = get_configured_resolution()
        with cache_lock:
            if raw_url in stream_cache:
                entry = stream_cache[raw_url]
                if entry.get("res") == current_res and entry.get("expire", 0) > now + 600:
                    return

        resolve_track_edl(raw_url)
    finally:
        with prefetch_lock:
            prefetch_queue.discard(raw_url)

def schedule_prefetch(raw_url):
    if raw_url and (raw_url.startswith("http://") or raw_url.startswith("https://")):
        t = threading.Thread(target=background_prefetch_worker, args=(raw_url,), daemon=True)
        t.start()

class StreamBridgeHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Quiet logging
        pass

    def do_HEAD(self):
        self.handle_request(is_head=True)

    def do_GET(self):
        self.handle_request(is_head=False)

    def handle_request(self, is_head=False):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")
        if not path:
            path = "/"

        port = self.server.server_address[1]
        base_url = f"http://127.0.0.1:{port}"

        # 1. PLAYLIST ENDPOINT: /playlist.m3u or /playlist.m3u8
        if path in ("/playlist.m3u", "/playlist.m3u8", "/playlist"):
            queries = urllib.parse.parse_qs(parsed.query)
            start_offset = 0
            if "start" in queries:
                try:
                    start_offset = int(queries["start"][0])
                except Exception:
                    pass

            playlist = get_current_playlist()
            lines = ["#EXTM3U"]

            # If no start query, check active track
            if "start" not in queries:
                for item in playlist:
                    if item.get("current"):
                        start_offset = item["index"]
                        break

            # Serve playlist in full sequential order (1 to N) so track numbers and queue structure match exactly
            for item in playlist:
                idx = item["index"]
                raw_title = item.get("title", f"Track {idx + 1}")
                clean_title = raw_title.replace("\r", " ").replace("\n", " ").strip()
                lines.append(f"#EXTINF:0,{clean_title}")
                lines.append(f"{base_url}/track/{idx}.edl")

            # Pre-fetch requested start track and upcoming track in background
            if playlist and 0 <= start_offset < len(playlist):
                schedule_prefetch(playlist[start_offset]["url"])
                if start_offset + 1 < len(playlist):
                    schedule_prefetch(playlist[start_offset + 1]["url"])

            if len(lines) == 1:
                # Empty playlist placeholder
                lines.append("#EXTINF:0,Queue Idle")
                lines.append(f"{base_url}/track/0.edl")

            content = "\n".join(lines) + "\n"
            content_bytes = content.encode("utf-8")

            # Also mirror to shared storage if accessible
            for sd_dest in ("/sdcard/Download/queue_playlist.m3u", "/storage/emulated/0/Download/queue_playlist.m3u"):
                try:
                    os.makedirs(os.path.dirname(sd_dest), exist_ok=True)
                    with open(sd_dest, "wb") as f:
                        f.write(content_bytes)
                    break
                except Exception:
                    pass

            self.send_response(200)
            self.send_header("Content-Type", "audio/x-mpegurl; charset=utf-8")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(content_bytes)))
            self.send_header("Connection", "close")
            self.end_headers()
            if not is_head:
                self.wfile.write(content_bytes)
            return

        # 2. TRACK STREAM ENDPOINT: /track/<idx> or /track/<idx>.edl
        if path.startswith("/track/"):
            try:
                sub = path.split("/")[2]
                if sub.endswith(".edl"):
                    sub = sub[:-4]
                idx = int(sub)
            except Exception:
                self.send_error(400, "Invalid track index")
                return

            playlist = get_current_playlist()
            if not playlist or idx < 0 or idx >= len(playlist):
                # Small retry window in case socket IPC is in middle of adding track
                for _ in range(3):
                    time.sleep(0.2)
                    playlist = get_current_playlist()
                    if playlist and 0 <= idx < len(playlist):
                        break

            if not playlist or idx < 0 or idx >= len(playlist):
                self.send_error(404, "Track index out of range")
                return

            item = playlist[idx]
            raw_url = item["url"]

            # Trigger background pre-fetch for next upcoming track
            next_idx = (idx + 1) % len(playlist)
            if next_idx < len(playlist):
                schedule_prefetch(playlist[next_idx]["url"])

            # Resolve direct EDL manifest
            edl_content = resolve_track_edl(raw_url)
            if not edl_content:
                self.send_error(500, "Failed to resolve stream")
                return

            edl_bytes = edl_content.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(edl_bytes)))
            self.send_header("Connection", "close")
            self.end_headers()
            if not is_head:
                self.wfile.write(edl_bytes)
            return

        # 3. STATUS ENDPOINT: /status
        if path == "/status":
            playlist = get_current_playlist()
            status_data = {
                "status": "online",
                "port": port,
                "resolution": get_configured_resolution(),
                "tracks_count": len(playlist),
                "cached_urls": len(stream_cache),
                "playlist": playlist
            }
            body = json.dumps(status_data, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            if not is_head:
                self.wfile.write(body)
            return

        # 4. QUIT ENDPOINT: /quit
        if path == "/quit":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Connection", "close")
            self.end_headers()
            if not is_head:
                self.wfile.write(b"Terminating bridge\n")
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return

        self.send_error(404, "Endpoint not found")

def run_bridge(requested_port=DEFAULT_PORT):
    load_persistent_cache()
    os.makedirs(CACHE_DIR, exist_ok=True)

    server = None
    actual_port = requested_port
    for p in range(requested_port, requested_port + 20):
        try:
            server = ThreadingHTTPServer(("127.0.0.1", p), StreamBridgeHandler)
            actual_port = p
            break
        except OSError:
            continue

    if not server:
        print(f"[Bridge] Fatal: Could not bind to any port in range {requested_port}-{requested_port+20}", file=sys.stderr)
        sys.exit(1)

    # Write PID and port files
    with open(PID_FILE, "w", encoding="utf-8") as f:
        f.write(str(os.getpid()) + "\n")
    with open(PORT_FILE, "w", encoding="utf-8") as f:
        f.write(str(actual_port) + "\n")

    def cleanup(sig=None, frame=None):
        try:
            if os.path.exists(PID_FILE):
                os.remove(PID_FILE)
            if os.path.exists(PORT_FILE):
                os.remove(PORT_FILE)
            save_persistent_cache()
        except Exception:
            pass
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    print(f"[Bridge] Termux Stream Bridge active on http://127.0.0.1:{actual_port}")
    try:
        server.serve_forever()
    finally:
        cleanup()

if __name__ == "__main__":
    port_arg = DEFAULT_PORT
    if len(sys.argv) > 1:
        try:
            port_arg = int(sys.argv[1])
        except ValueError:
            pass
    run_bridge(port_arg)
