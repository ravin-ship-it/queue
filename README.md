<div align="center">

# 🎵 `q` — The Ultimate MPV Music Engine

<p align="center">
  <b>Turn lightweight MPV into an intelligent, feature-packed terminal music player.</b><br>
  <i>24/7 Auto-Discovery • Instant YouTube & SoundCloud Streaming • Interactive FZF TUI • Zero-Bloat</i>
</p>

<p align="center">
  <a href="#-quick-start"><img src="https://img.shields.io/badge/Quick_Start-30_Seconds-00c853?style=flat-square&logo=speedtest&logoColor=white" alt="Quick Start" /></a>
  <img src="https://img.shields.io/badge/Platform-Linux%20%7C%20WSL2%20%7C%20macOS%20%7C%20Termux-informational?style=flat-square&logo=linux&logoColor=white" alt="Platforms" />
  <img src="https://img.shields.io/badge/Engine-MPV%20%2B%20yt--dlp-ff1493?style=flat-square" alt="Engine" />
  <img src="https://img.shields.io/badge/TUI-FZF%20Interactive-8700ff?style=flat-square&logo=gnubash&logoColor=white" alt="TUI" />
  <img src="https://img.shields.io/badge/Built%20With-AI%20Augmented%20Dev-blueviolet?style=flat-square&logo=google&logoColor=white" alt="AI Augmented" />
  <img src="https://img.shields.io/badge/License-GPL--3.0-blue?style=flat-square" alt="License" />
</p>

<p align="center">
  <a href="#-what-is-q"><b>What is q?</b></a> •
  <a href="#-interactive-tui-preview"><b>TUI Showcase</b></a> •
  <a href="#-quick-start"><b>Quick Start</b></a> •
  <a href="#-cheat-sheet"><b>Commands</b></a> •
  <a href="#-smart-auto-mode-q--auto"><b>Auto-Mode</b></a> •
  <a href="#-why-q-vs-standard-players"><b>Why q?</b></a> •
  <a href="#-built-with-ai-augmented-development"><b>AI Development</b></a>
</p>

---

</div>

## 🌟 What is `q`?

**`q`** is a unified command center designed for music lovers who live in the terminal. Instead of reinventing media playback, `q` elegantly bridges together the most powerful Unix tools—**MPV**, **yt-dlp**, **fzf**, **jq**, and **netcat**—transforming a barebones CLI player into a rich, reactive, background-resilient music player.

```
       ┌──────────────┐       ┌──────────────┐       ┌──────────────┐
       │    yt-dlp    │       │     fzf      │       │  netcat + jq │
       │ (Stream Ext) │       │ (Active TUI) │       │  (JSON-IPC)  │
       └──────┬───────┘       └──────┬───────┘       └──────┬───────┘
              │                      │                      │
              └───────────────► 🎛️   q   ◄──────────────────┘
                                     │
                                     ▼
                          ┌─────────────────────┐
                          │   MPV Audio Core    │
                          │ (Background Daemon) │
                          └─────────────────────┘
```

### 🧩 Under the Hood:
| Tool | Role in `q` |
| :--- | :--- |
| 🎬 **[MPV](https://mpv.io/)** | High-fidelity, ultra-lightweight audio backend and equalizer |
| 📥 **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** | Decrypts and streams audio directly from YouTube & SoundCloud without local files |
| 🔍 **[fzf](https://github.com/junegunn/fzf)** | Lightning-fast fuzzy search interface with live now-playing banners |
| ⚡ **netcat & jq** | Zero-latency JSON-IPC channel controlling MPV without stopping playback |

---

## 🖥️ Interactive TUI Preview

Launch the full-screen interactive queue simply by typing `q`:

```text
╭──────────────────────────────────────────────────────────────────────────────╮
│ 🪷 Now Playing [2] Skillet - "The Resistance" [Official Lyric Video]         │
│ ──────────────────────────────────────────────────────────────────────────── │
│   1. DJ Slow Remix!!! Hubbuka Fi Qalbi (Aires Remix) by Aires Music [4:01]   │
│ > 2. Skillet - "The Resistance" [Official Lyric Video] by Skillet [4:01]     │
│   3. Numb (Official Music Video) [4K UPGRADE] – Linkin Park [3:08]           │
│   4. The Weeknd - Blinding Lights (Official Video) [4:23]                    │
│   5. STARSET - My Demons (Official Music Video) [3:43]                       │
│   6. Thousand Foot Krutch - Courtesy Call [3:52]                             │
╰──────────────────────────────────────────────────────────────────────────────╯
🎵 Queue List >< ◖∞◗ > search track...
```

## ⚡ Why `q` vs Standard Players?

| Feature | `q` | Spotify / Desktop Apps | Plain MPV CLI |
| :--- | :---: | :---: | :---: |
| **RAM Usage** | **< 15 MB** | 500 MB – 1.2 GB (Electron) | ~15 MB |
| **24/7 Smart Auto-Discovery** | ✅ (`q -auto`) | ✅ (Algorithm) | ❌ |
| **YouTube & SoundCloud Streaming** | ✅ Zero local storage | ❌ Spotify catalog only | ⚠️ Single URLs only |
| **Headless Background Daemon** | ✅ Continuous (`setsid`) | ❌ Window required | ❌ Blocks terminal |
| **Interactive Fuzzy Search (FZF)** | ✅ Instant (0ms) | ⚠️ Slower GUI search | ❌ None |
| **Dead Link Auto-Cleaner** | ✅ `q -clean` | ❌ None | ❌ None |
| **WSL2 / Linux Audio Resilience** | ✅ PulseAudio hardened | ⚠️ Often desyncs on WSL | ⚠️ Sinks wedge on pause |

---

## 🚀 Quick Start

### 1. Clone & Install
```bash
git clone https://github.com/ravin-ship-it/queue.git
cd queue
./install.sh
```

> **Automated Package Detection**: `install.sh` automatically installs missing dependencies on **Ubuntu/Debian/WSL**, **Arch Linux**, **Fedora**, **macOS (Homebrew)**, and **Termux**.

### 2. Apply Shell Integration
```bash
# For Zsh users:
source ~/.zshrc

# For Bash users:
source ~/.bashrc
```

### 3. Play Music!
```bash
# Open interactive player:
q

# Search & play instantly from YouTube:
q "blinding lights the weeknd"
```

---

## 🕹️ Everyday Usage & Examples

### 🔍 Instant Streaming & Ingestion
```bash
# 1. Search YouTube and pick from top results
q "linkin park in the end"

# 2. Force specific provider search
q yt "synthwave radio"
q sc "lofi chill beats"

# 3. Queue a direct YouTube video or entire playlist
q "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# 4. Queue a local folder or file
q ~/Music/favorite_song.mp3

# 5. Pipe tracks or text lists directly
cat playlist_urls.txt | q
```

---

## 📖 Cheat Sheet

You can use standard short flags (`q -p`) or clean smart commands (`q play`).

### 🎵 Playback & Audio
| Command | Flag | Action |
| :--- | :--- | :--- |
| `q play [N]` | `q -p [N]` | **Play / Pause** toggle, or jump to track `N` *(supports math: `10+5`)* |
| `q next` | `q -next` | Skip to next track |
| `q prev` | `q -prev` | Return to previous track |
| `q stop` | `q -stop` | Gracefully quit MPV and unhook audio |
| `q vol [0-130]` | `q -v [N]` | View or set playback volume |
| `q fx [on\|off]`| `q -fx` | Toggle spatial Dolby-like audio profile |
| `q shuffle` | `q -shuf [list]` | Toggle shuffle mode *(or randomize queue entries)* |
| `q auto` | `q -auto` | **Toggle 24/7 Auto-Discovery Radio Mode** |
| — | `q -l` / `q -lp` | Toggle Track Loop / Playlist Loop |

---

### 📋 Queue Management
| Command | Flag | Action |
| :--- | :--- | :--- |
| `q remove [N]` | `q -rm [N\|query]` | Remove track by index, title search, or remove currently playing track |
| `q move <A> <B>` | `q -mv <A> <B>` | Move track from position `A` to `B` |
| `q swap <A> <B>` | `q -sw <A> <B>` | Swap track positions `A` and `B` |
| `q clear` | `q -clr` | Wipe the current queue |
| — | `q -clean` | Scan and remove private/deleted/dead YouTube videos |
| — | `q -rmr` | Remove all duplicate tracks from queue |
| — | `q -raw` | Print plaintext queue list *(ideal for scripts/pipes)* |

---

### 📁 Custom Playlists
| Command | Flag | Action |
| :--- | :--- | :--- |
| `q save <name>` | `q -pl-save <name>` | Save active queue as a named playlist |
| `q load [name]` | `q -pl-load [name]` | Load playlist *(opens FZF picker if name omitted)* |
| `q list` | `q -pl-list` | Interactive playlist explorer and manager |
| — | `q -pl-rm <name>` | Delete a saved playlist |
| — | `q -pl-clean <name>` | Clean dead tracks from a saved playlist |
| — | `q -to <name>` | Route search results directly into a playlist |

---

## ⌨️ Interactive Keybindings (FZF Mode)

When navigating the interactive queue (`q`):

| Key | Function |
| :--- | :--- |
| <kbd>Enter</kbd> | **Play focused track** immediately *(or open Batch Actions menu)* |
| <kbd>Tab</kbd> | **Select / Mark track** for multi-item actions |
| <kbd>Alt</kbd> + <kbd>A</kbd> | **Invert selection** (toggle all tracks) |
| <kbd>Insert</kbd> / <kbd>Delete</kbd> | Select All / Deselect All |
| <kbd>Ctrl</kbd> + <kbd>V</kbd> | **Paste URL from clipboard** directly into the queue |
| <kbd>Ctrl</kbd> + <kbd>R</kbd> | Synchronize and reload queue from MPV |
| <kbd>Esc</kbd> / <kbd>Ctrl</kbd> + <kbd>C</kbd> | Exit TUI *(music continues playing uninterrupted)* |

---

## 🤖 Smart Auto-Mode (`q -auto`)

When Auto-Mode is enabled:
1. **Intelligent Seed Analysis**: When your queue approaches the end, `q` inspects your existing track history and genres.
2. **Zero-Gap Discovery**: Automatically discovers related high-quality hits from YouTube.
3. **Continuous Streaming**: Seamlessly queues and buffers the new tracks in the background, giving you a 24/7 personal radio station that never runs out of music.

---

## 🧠 Built with AI-Augmented Development

`q` was designed, architected, and continuously refined using **AI-Augmented Development** — an engineering paradigm where human product vision, design intuition, and user feedback pair directly with autonomous AI coding agents.

### 💡 Why AI-Augmented?
- **Root-Cause Resilience**: Complex low-level edge cases (such as WSLg PulseAudio socket unhooking, background daemon session detachment via `setsid`, long-pause HTTPS token expiration recovery, and real-time asynchronous TUI IPC) were diagnosed and solved at the protocol level.
- **Architectural Cohesion**: Features across 7 modular subsystems (`media`, `queue`, `playlist`, `search`, `batch`, `ui`, `utils`) maintain consistent error handling, cross-platform compatibility, and zero-latency inter-process synchronization.
- **Continuous Evolution**: Performance benchmarks, non-blocking asynchronous routines, and terminal aesthetics are continuously iterated and battle-tested in real-world environments.

---

## 🛠️ Uninstallation

```bash
./uninstall.sh
```
Cleanly removes all executables, shell wrapper functions, configurations, and cache files.

---

## 🤝 Contributing & License

Contributions, feature requests, and bug reports are warmly welcome! Feel free to open an issue or pull request.

Distributed under the **GPL-3.0 License**. See [LICENSE](file:///home/xen/queue/LICENSE) for more information.
