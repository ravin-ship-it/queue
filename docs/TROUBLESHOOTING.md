# 🔧 Queue (q) — Troubleshooting & Edge Cases

This guide addresses common questions, platform edge cases, and self-healing mechanisms in Queue.

---

## 🔍 First Step: Run System Diagnostic (`q -deps`)

Before debugging, run Queue's integrated multi-engine diagnostic:
```bash
q -deps      # Comprehensive multi-engine diagnostic
```
This inspects core binaries, JavaScript decryptor engines, WSLg graphics drivers, host bridges, and Android audio sinks.

---

## 🚫 Issue 1: YouTube HTTP 403 Forbidden / Anti-Bot Throttling

### Symptoms:
Streams stall after 8 seconds, or yt-dlp reports:
`HTTP Error 403: Forbidden` or `Sign in to confirm you're not a bot`.

### Root Cause:
YouTube continuously rolls out encrypted signature challenges on cipher endpoints. yt-dlp requires an external JavaScript runtime engine to decrypt these challenges in real-time.

### Solution:
Install a fast JavaScript runtime. Queue automatically detects and binds to:
* **Node.js**:
  * Ubuntu/Debian: `sudo apt install nodejs`
  * Arch Linux: `sudo pacman -S nodejs`
  * Fedora: `sudo dnf install nodejs`
  * macOS: `brew install node`
  * Android Termux: `pkg install nodejs`
* **Deno / Bun / QuickJS**: Any of these runtimes installed in your PATH are automatically integrated into Queue's `~/.config/yt-dlp/config`.

---

## ❄️ Issue 2: Video Stalls or Infinite Reconnection Loop (YouTube Premium Trap)

### Symptoms:
Video plays for ~8 seconds and freezes permanently with:
`underrun: true, error=End of file`.

### Root Cause:
Without active YouTube Premium credentials, YouTube's server allows downloading only the first ~8 seconds of the 1080p Premium Enhanced Bitrate format (`itag 616`).

### Solution:
Queue has built-in protection against format 616. Ensure your format selector excludes Premium streams:
```bash
# Verify active resolution profile
q -res 1080
```
Queue enforces `[format_note!*=Premium]` across all format selectors, automatically falling back to standard 1080p60 VP9 (`itag 248`) or AV1 (`itag 399`).

---

## 🐭 Issue 3: Microscopic Cursor in WSLg (Windows 11 / 10)

### Symptoms:
When hovering over the Queue video window in WSL2, the mouse cursor becomes tiny and difficult to see.

### Solution:
Queue automatically generates `~/.Xresources` and `~/.icons/default/index.theme` configuring cursor size:
```ini
Xcursor.theme: Adwaita
Xcursor.size: 36
```
To apply manually:
```bash
xrdb -merge ~/.Xresources
```

---

## 📱 Issue 4: Android / Termux Audio Stops When Screen Turns Off

### Symptoms:
Music pauses as soon as the Android device locks or goes to sleep.

### Root Cause:
Android OS battery optimization suspends background processes in Termux when screen is turned off.

### Solution:
1. Ensure `termux-api` package is installed:
   ```bash
   pkg install termux-api
   ```
2. Install the [Termux:API Addon from F-Droid](https://f-droid.org/en/packages/com.termux.api/).
3. Ensure storage access is granted:
   ```bash
   termux-setup-storage
   ```
4. In Android Settings ➔ Apps ➔ Termux ➔ **Battery Optimization** ➔ Set to **Unrestricted** / **Don't Optimize**.

---

## 🔊 Issue 5: Audio Stuttering or Underrun Warnings

### Symptoms:
Terminal logs display `audio underrun` or crackling sound on busy systems.

### Solution:
Increase MPV's demuxer buffer:
1. Open `~/.config/mpv/mpv.conf`.
2. Ensure network cache settings are tuned:
   ```ini
   demuxer-max-bytes=150MiB
   demuxer-readahead-secs=20
   audio-buffer=0.2
   ```
3. If on WSL2, consider switching to **Hybrid Boost Mode** (`q -hybrid on`), which uses native Windows WASAPI directly with zero audio latency.

---

## 🔄 Issue 6: Reinstalling Queue Without Repo (`q install`)

If you uninstalled Queue or moved files, run:
```bash
q install
```
If the local setup file exists, it reinstalls Queue immediately. If deleted, it pulls directly from GitHub.

---

## 📺 Issue 7: Black Screen When Switching from Audio to Video in Blind Mode (`q -pb`)

### Symptoms:
When starting Blind Mode in audio-only mode (or inheriting active audio mode) and toggling video (`q -vid` or `q -aud off`), an empty black MPV window appears with audio playing.

### Root Cause:
If a stream was loaded using pure audio formats (`bestaudio`), the yt-dlp demuxer does not download video chunks, leaving zero video tracks in MPV's track list. Simply setting `vid=auto` opens the window, but lacks video frames to render.

### Solution:
Queue automatically handles this by querying active MPV track lists:
1. When toggling video in Blind Mode, Queue inspects `track-list`.
2. If no video track is demuxed, Queue updates `ytdl-format` to `bestvideo+bestaudio`, registers an atomic `arm-resume-seek` with your current playback position, and reloads the stream index cleanly.
3. Playback resumes at the exact second with full hardware-accelerated video rendering.

---

## 📐 Issue 8: Box Border Misalignment on Custom or Ultra-Wide Terminals

### Symptoms:
Status dashboards or boxed dialogs have right borders (`│`) that extend past or fall short of the top/bottom corner lines (`╭─╮` / `╰─╯`).

### Root Cause:
Static width clamps or subshell column desynchronization.

### Solution:
Queue dynamically calculates terminal width using `get_terminal_width` across all rendering helpers:
* `print_header_box` (`╭─╮` and `├─┤`)
* `print_boxed_line` (`│ ... │`)
* `print_divider_box` (`├─┤`)
* `print_footer_box` (`╰─╯`)

Every component references the identical dynamic width query and unified purple border palette, guaranteeing alignment whether your terminal is 80, 100, 120, or 156+ columns wide.
