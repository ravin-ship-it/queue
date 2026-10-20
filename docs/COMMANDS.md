# 🕹️ Queue (q) — Command Reference Guide

This document contains a categorized reference of all CLI commands, keyboard shortcuts, search filters, and lifecycle flags.

---

## 🎵 Interactive TUI & Navigation

Running `q` without arguments opens the full interactive terminal queue.

### FZF Keyboard Shortcuts
| Key | Action | Description |
| :--- | :--- | :--- |
| `ENTER` | **Play / Select** | Plays selected track immediately (or opens Action Menu if multiple tracks are marked) |
| `TAB` | **Mark / Select** | Marks a track for multi-selection (batch actions, deletion, or playlist saving) |
| `ALT-A` | **Invert All** | Inverts current track selections |
| `INSERT` | **Select All** | Marks all tracks in the current view |
| `DELETE` | **Deselect All** | Clears all marked selections |
| `CTRL-D` | **Quick Dislike** | Blacklists and dislikes the highlighted track directly from search mode |
| `x` | **Dislike in Inspector** | Dislikes and removes track while viewing metadata (`q -i`) |
| `v` | **Watch Video Window** | Launches the desktop video window directly from Inspector (`q -i`) |

---

## 🔍 Ingestion & Streaming Syntax

Queue accepts URLs, search queries, local audio files, and playlist files:

```bash
# Search YouTube and pick from top 10 results
q "daft punk get lucky"

# Force YouTube search
q yt "synthwave radio 24/7"

# Force SoundCloud search
q sc "lofi hip hop beats"

# Direct YouTube Video or Playlist URL
q "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
q "https://www.youtube.com/playlist?list=PL..."

# Direct Spotify Track URL (Auto-matches highest quality audio on YouTube)
q "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT"

# Local file or directory
q ~/Music/favorite_song.mp3
q ~/Music/Albums/
```

---

## ⏯️ Playback Controls

| Command | Alias | Description |
| :--- | :--- | :--- |
| `q -p [N]` | `q play [N]` | Toggle Play/Pause, or jump directly to track `N` (Supports: `q -p 5`, `q -p +2`) |
| `q -pb [target]` | `q pb` / `q blind` | **Blind Mode**: One-time isolated play (pauses queue, never touches history, auto-resumes on exit) |
| `q -next` | `q next` | Skip to the next track |
| `q -prev` | `q prev` | Return to the previous track |
| `q -stop` | `q stop` | Terminate the MPV background daemon and release audio sinks |
| `q -v [0-100]` | `q vol [0-100]` | Display current volume or set volume to `N`% |
| `q -i [N\|URL]` | `q info` | Open the Metadata & Track Inspector (bitrate, resolution, codec, duration) |
| `q -clr` | `q clear` | Clear all entries from the active queue |

---

## 🔀 Smart Virtual Shuffle & Loop Engines

Queue includes an intelligent, non-destructive **Virtual Shuffle Engine**:

```bash
# Toggle Virtual Shuffle Mode ON/OFF
q -shuf       # or: q shuffle

# Physically shuffle and re-order the actual queue entries on disk
q -shuf list
```

### Virtual Shuffle Highlights:
* **Zero Repeat Guarantee**: Uses an in-memory & on-disk history stack (`yt_cache.txt`) to ensure tracks never repeat during a shuffle session.
* **Seamless EOF Transition**: When the current track ends, the background monitor selects an unplayed random track automatically.
* **Non-Destructive**: Turning shuffle OFF restores your original playlist order.

### Loop Controls
```bash
# Toggle Single-Track Loop (⟳1)
q -l          # or: q loop

# Toggle Full Playlist Loop (⟳)
q -lp         # or: q loop-playlist
```

---

## 📺 Desktop Video Controller (`q -vid` / `q -res`)

Queue allows you to watch high-definition music videos alongside background audio playback.

```bash
# Toggle Desktop Video Window (instant zero-gap toggle)
q -vid

# Open with specific size preset: small, med, large
q -vid small
q -vid med
q -vid large
```

### Video Window Hotkeys (Focused on MPV Window):
* `F11` or `f`: Toggle Fullscreen ON/OFF
* `ESC`: Exit fullscreen
* `w` / `W`: Cycle window presets (Small 480p ➔ Medium 720p ➔ Large 1080p)
* `+` / `-`: Scale window size up or down by 5%
* `0` - `4`: Quick quality presets (Auto, 480p, 720p, 1080p, 1440p/4K)
* `q`: Hide video window and return smoothly to background audio mode

### Video Resolution Control (`q -res`)
```bash
# View active video resolution and format selector
q -res

# Set target resolution cap
q -res 720    # 720p HD
q -res 1080   # 1080p Full HD (60 FPS prioritized)
q -res 1440   # 2K Quad HD
q -res 4k     # 4K Ultra HD
q -res auto   # Best available
```

---

## 🕶️ Blind Mode (`q -pb` / `q pb`)

Blind Mode is designed for times when you want to quickly watch or listen to a one-off video or audio clip without cluttering your carefully crafted queue, interrupting shuffle history, or saving temporary links to disk:

```bash
# Play a YouTube video blindly (pauses active queue, auto-resumes when done)
q -pb "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Search and play directly in blind mode
q -pb "funny cat meme"

# Pull URL directly from clipboard
q -pb

# Play local file blindly
q -pb ~/Downloads/preview.mp4
```

### How Blind Mode Works:
1. **Queue Snapshot**: Checks if a Queue playback session is active. If so, pauses it immediately.
2. **Pristine State Guarantee**: The target track/video is **never** added to your playlist files (`yt_cache.txt`) and **never** recorded in your shuffle history stack.
3. **Dedicated Video Window**: Automatically opens a resizable video window (supporting `F11` fullscreen, `w`/`W` sizing presets, `+/-` scaling, and `0-4` quality switches).
4. **Instant Queue Restoration**: When the video finishes (EOF) or when you close the window (`q` or `ESC`), Queue automatically unpauses your previous session, resuming playback at the exact second where you left off.

---

## 🚫 Dislike & Blacklist System

Queue protects your listening sessions from unwanted tracks and dead videos:

```bash
# Dislike and remove a track from queue
q -rmd [N]          # e.g., q -rmd 3

# Dislike a track without removing it
q -dis [N|title]

# Interactive Dislike Manager (FZF Hub to view and un-dislike)
q -disl

# Whitelist / Remove a track from dislike blacklist
q -undis [title]

# Clean dead, private, or geo-blocked videos from queue
q -clean

# Remove duplicate tracks from queue
q -rmr
```

---

## 📂 Playlist Hub

Manage custom playlists stored locally in `~/.local/share/mpv/playlists/`:

```bash
# Save current queue as a named playlist
q -pl-save "Workout Hits"

# Interactive Playlist Explorer (FZF Hub to load or browse playlists)
q -pl-load

# Directly load a playlist by name
q -pl-load "Workout Hits"

# List all saved playlists
q -pl-list

# Delete a saved playlist
q -pl-rm "Old Mix"

# Clean dead tracks or duplicates from a playlist
q -pl-clean "Workout Hits"
q -pl-rmr "Workout Hits"

# Direct search results directly into a playlist
q -to "Party Mix" "daft punk"
```

---

## 🎚️ Dolby Audio FX Equalizer (`q -fx`)

Enhance audio dynamics and vocal clarity:

```bash
# Check Audio FX status
q -fx

# Toggle Audio FX ON/OFF
q -fx toggle
q -fx on
q -fx off
```

---

## 📥 Downloader Wizard Hub (`q -d` / `q -dl`)

Download tracks or playlists in various formats with metadata and artwork:

```bash
# Open interactive download wizard for current or queued track
q -d

# Download a direct URL
q -d "https://www.youtube.com/watch?v=..."
```
Supported Formats: MP3 (320k), M4A (256k AAC), FLAC (Lossless), OPUS (160k Hi-Res), MP4 Video (1080p/4K).

---

## 🛠️ Diagnostics & Lifecycle Commands

| Command | Purpose |
| :--- | :--- |
| `q -deps` | Comprehensive boxed TUI multi-engine dependency diagnostic |
| `q -up` | Universal 1-command updater (yt-dlp, Queue modules, host bridges) |
| `q -install` | Reinstall or verify Queue engine |
| `q -uninstall` | Clean uninstallation checklist (preserves instant reinstaller) |
| `q -remove-setup` | Permanently wipe the setup file and launcher stub (only runs after uninstallation) |
| `q -version` | Display version information |
