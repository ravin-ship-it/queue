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

## 🤖 24/7 Smart Auto-Discovery Engine (`q -auto`)

Queue features a zero-gap, continuous auto-discovery radio engine with **Dynamic Seed Rotation** and an **Anti-Artist Echo Chamber Guard**:

```bash
# Toggle Auto Mode ON/OFF
q -auto             # or: q auto

# Explicitly enable or disable
q -auto on          # Enable 24/7 continuous discovery
q -auto off         # Disable auto-queuing

# View Auto-Discovery Engine Dashboard
q -auto status      # View active seed, rotation depth, fatigue buffer, & taste stats

# Trigger immediate discovery fetch with a fresh seed
q -auto fetch       # or: q auto next

# Reset seed memory & artist fatigue buffers
q -auto reset       # or: q auto clear-history
```

### Smart Intelligence Highlights:
* **Anti-Echo Chamber & Artist Fatigue**: Automatically prevents consecutive songs by the same artist (`-120` penalty) and limits recent artist repetition (`-50` fatigue penalty).
* **Removed Track Exclusion**: Removing or disliking a song permanently isolates it from becoming a seed, guaranteeing fresh recommendations instead of repeating removed artists.
* **Dynamic Seed Rotation**: Rotates through unused tracks in your active queue (depth of 15) so your entire playlist influences discovery rather than just the last track.
* **User Taste Profile Integration**: Analyzes your saved playlists (`~/.local/share/mpv/playlists/`) and boosts matching artists (`+45`) and preferred genres (`+30` for nightcore, slowed+reverb, acoustic covers, remixes).
* **Empty Queue Resurrection**: If your queue runs empty, Auto Mode automatically seeds from your saved playlists rather than repeating the same history track.
* **Auto-Added Track Indicator (`Ⓐ`)**: Tracks discovered and queued automatically by Auto Mode are branded with a distinctive purple `Ⓐ` indicator across the interactive FZF queue, terminal logs, and playback banners so you can effortlessly distinguish auto-discovered tracks from your handpicked manual tracks.

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
* `0`: Auto / Smart Adaptive (YouTube-like ABR with automatic buffer downshift)
* `1`: 720p HD (60 FPS fluid / bandwidth saver)
* `2`: 1080p Full HD (60 FPS crisp)
* `3`: 1440p 2K QHD (60 FPS ultra-crisp)
* `4`: Max / 4K UHD (Uncapped highest quality)
* `q`: Hide video window and return smoothly to background audio mode

### Video Resolution & Adaptive Network Engine (`q -res`)
```bash
# View active video resolution and format selector
q -res

# Set target resolution cap (seamless position memory: never restarts from 0:00)
q -res 720    # 720p HD (Fluid 60 FPS / bandwidth saver)
q -res 1080   # 1080p Full HD (Crisp 60 FPS)
q -res 1440   # 2K Quad HD (Ultra-crisp)
q -res 4k     # 4K Ultra HD (Uncapped)
q -res 480    # 480p SD (Low-bandwidth smooth)
q -res 360    # 360p Low (Emergency smooth)
q -res auto   # Smart Adaptive (Adapts dynamically to network fluctuations)
```

#### 🧠 YouTube-like Smart Adaptive Bitrate (ABR):
* **Buffer Underrun Detection**: When in `auto` mode, Queue continuously monitors player cache and buffer health. If your internet fluctuates or starves the buffer, Queue automatically downshifts to a lighter resolution (e.g., 1080p -> 720p -> 480p) without stopping playback.
* **Seamless Position Memory**: Any resolution switch (via keypress `0-4` or `q -res`) preserves your exact timestamp down to the second.
* **Anti-Suicide Network Safeguard**: If your internet drops completely, MPV normally skips and "suicides" through your entire playlist. Queue's network safeguard immediately freezes playback, holds your place at the exact second, probes for internet in the background, and automatically resumes playback as soon as your connection restores.

---

## 🎧 Audio-Only Pipeline (`q -aud`)

Switch dynamically between video and pure background audio with 98% bandwidth reduction:

```bash
# Toggle Audio-Only Mode
q -aud

# Explicitly enable or disable Audio-Only mode
q -aud on
q -aud off

# Check Audio-Only pipeline status
q -aud status
```

---

## ⏩ Playback Speed Controller (`q -speed`)

Fine-tune playback speed from 0.25x to 4.0x with smooth pitch correction:

```bash
# Check current playback speed
q -speed

# Set exact speed
q -speed 1.25    # 1.25x speed
q -speed 1.5     # 1.5x speed
q -speed 2.0     # 2x speed
q -speed reset   # Reset to 1.0x normal speed

# In-Window Hotkeys:
# '[' / ']'      Decrease / Increase speed by 0.1x
# '{' / '}'      Decrease / Increase speed by 0.25x
# Backspace      Reset to 1.0x
```

---

## 🌐 Audio Languages & Multi-Track Dubs (`q -lang`)

Queue natively inspects and switches multi-track audio dubs across YouTube and local media containers (e.g. English, Chinese, Japanese, Hindi, Spanish, etc.):

```bash
# Open interactive FZF/Boxed Language Picker
q -lang

# Quick switch to a specific language code
q -lang en       # English
q -lang zh       # Chinese (中文)
q -lang ja       # Japanese (日本語)
q -lang hi       # Hindi (हिन्दी)
q -lang auto     # Original / Default Audio

# Target specific playback session directly
q -lang -pb zh   # Switch Blind Mode session to Chinese directly
q -lang -q en    # Switch Normal Queue session to English directly
```

### Dual-Session Awareness & Intelligent Picker:
* **Active Session Detection**: When both **Normal Queue** and **Blind Mode (`q -pb`)** are active or paused simultaneously, `q -lang` automatically presents an interactive session selector showing the active track and status:
  ```text
  1. 🎵 [Normal Queue] ♬ Nightcore - Royalty (Lyrics) ♬ [⏸️ Paused]
  2. 🕶️ [Blind Mode]   Full Version | Campus Beauty      [▶ Playing]
  ```
* **Isolated Audio Preferences**: Selecting Blind Mode dynamically re-demuxes the stream for the isolated video player without touching your permanent normal queue preferences in `~/.config/mpv/queue_lang`.
* **In-Window Audio Track Cycling**: Press `'a'` or `'A'` inside any video window to cycle through available audio tracks and dubs with instant OSD feedback.

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

# Force video or audio-only blind mode
q -pb -vid "https://www.youtube.com/watch?v=..."
q -pb -aud "https://www.youtube.com/watch?v=..."
```

### How Blind Mode Works:
1. **Queue Snapshot**: Checks if a Queue playback session is active. If so, pauses it immediately.
2. **Pristine State Guarantee**: The target track/video is **never** added to your playlist files (`last_playlist.txt`) and **never** recorded in your shuffle history stack.
3. **Dedicated Video Window**: Automatically opens a resizable video window (supporting `F11` fullscreen, `w`/`W` sizing presets, `+/-` scaling, `0-4` quality switches, and `'a'` audio dub cycling).
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
| `q -up` | Universal 1-command updater (yt-dlp, Queue engine, host bridges, local dev auto-sync) |
| `q -install` | Reinstall or verify Queue engine |
| `q -uninstall` | Clean uninstallation checklist (preserves instant reinstaller) |
| `q -remove-setup` | Permanently wipe the setup file and launcher stub (only runs after uninstallation) |
| `q -version` | Display version information |
