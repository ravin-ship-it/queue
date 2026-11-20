#!/usr/bin/env python3
"""
clean_checker.py: High-speed concurrent playability and dead-track detector for Queue (q).
Validates active MPV queue tracks and saved playlist files in parallel.
"""
import sys
import os
import re
import json
import socket
import urllib.request
from concurrent.futures import ThreadPoolExecutor

DEAD_REASONS = [
    "video unavailable",
    "this video is private",
    "this video is unavailable",
    "this video has been removed",
    "private video",
    "deleted video",
    "account associated with this video has been terminated",
    "no longer available"
]

def check_youtube(vid):
    body = json.dumps({
        "context": {"client": {"clientName": "WEB", "clientVersion": "2.20231010.01.00", "hl": "en", "gl": "US"}},
        "videoId": vid
    }).encode("utf-8")
    req = urllib.request.Request(
        "https://www.youtube.com/youtubei/v1/player",
        data=body,
        headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"}
    )
    try:
        with urllib.request.urlopen(req, timeout=3.5) as resp:
            data = json.loads(resp.read().decode("utf-8", errors="ignore"))
            ps = data.get("playabilityStatus", {})
            status = ps.get("status", "")
            reason = ps.get("reason", "")
            if not reason:
                sub = ps.get("errorScreen", {}).get("playerErrorMessageRenderer", {}).get("subreason", {}).get("runs", [])
                if sub:
                    reason = " ".join(r.get("text", "") for r in sub)
            
            if status in ["UNPLAYABLE", "ERROR", "LOGIN_REQUIRED"]:
                low_reason = (reason or "").lower()
                if any(dr in low_reason for dr in DEAD_REASONS):
                    return False, (reason or "Video unavailable")
            return True, "OK"
    except Exception:
        # Transient network or timeout: do not false-positive
        return True, "OK"

def check_item(item):
    idx, url, title = item
    if not url:
        return idx, url, title, False, "Empty URL"
    
    # Check literal dead markers in title
    if title:
        low_t = title.lower()
        if any(marker in low_t for marker in ["[private video]", "[deleted video]", "video unavailable", "deleted video"]):
            return idx, url, title, False, title
    
    # Check local files
    if not url.startswith("http://") and not url.startswith("https://"):
        path = os.path.expanduser(url)
        if not os.path.exists(path):
            return idx, url, title, False, "File not found"
        return idx, url, title, True, "OK"
    
    # Check YouTube
    m = re.search(r"(?:v=|\/|embed\/|shorts\/)([a-zA-Z0-9_-]{11})(?:[&?]|$)", url)
    if m:
        vid = m.group(1)
        ok, reason = check_youtube(vid)
        return idx, url, title, ok, reason
    
    return idx, url, title, True, "OK"

def get_tracks_from_socket(sock_path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2.0)
    try:
        s.connect(sock_path)
        s.sendall(b'{"command":["get_property","playlist"]}\n')
        buf = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
            if b"\n" in buf:
                break
        res = json.loads(buf.decode("utf-8", errors="ignore"))
        data = res.get("data", [])
        return [(i, t.get("filename", ""), t.get("title", "")) for i, t in enumerate(data)]
    except Exception:
        return []
    finally:
        try:
            s.close()
        except Exception:
            pass

def get_tracks_from_file(file_path):
    tracks = []
    if not os.path.exists(file_path):
        return tracks
    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        for idx, line in enumerate(f):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            url = parts[0].strip()
            title = parts[1].strip() if len(parts) > 1 else ""
            tracks.append((idx, url, title))
    return tracks

def main():
    mode = None
    target = None
    if len(sys.argv) >= 3:
        mode = sys.argv[1]
        target = sys.argv[2]
    
    items = []
    if mode == "--socket":
        items = get_tracks_from_socket(target)
    elif mode == "--file":
        items = get_tracks_from_file(target)
    else:
        # Read JSON from stdin: [{"index": 0, "url": "...", "title": "..."}]
        try:
            raw = sys.stdin.read()
            if raw:
                loaded = json.loads(raw)
                items = [(d.get("index", i), d.get("url", ""), d.get("title", "")) for i, d in enumerate(loaded)]
        except Exception:
            pass

    if not items:
        return

    workers = min(24, max(4, len(items)))
    with ThreadPoolExecutor(max_workers=workers) as ex:
        results = list(ex.map(check_item, items))

    # Print dead items as TSV: idx\turl\ttitle\treason
    for idx, url, title, ok, reason in results:
        if not ok:
            clean_t = (title or "").replace("\t", " ").replace("\n", " ")
            clean_r = (reason or "Dead track").replace("\t", " ").replace("\n", " ")
            sys.stdout.write(f"{idx}\t{url}\t{clean_t}\t{clean_r}\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()
