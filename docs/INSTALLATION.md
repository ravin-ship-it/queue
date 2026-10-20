# 📦 Queue (q) — Installation & Setup Guide

This guide covers all installation methods, platform prerequisites, automated flags, and lifecycle maintenance for Queue.

---

## ⚡ 1-Line Universal Setup (Recommended)

You can install Queue on any device (**Linux**, **macOS**, **Windows WSL2**, **Android Termux**) in seconds without cloning the repository. The smart setup script detects your operating system and pulls only the required modular components:

```bash
# Standard Standalone Mode (Headless / Native Audio & 60 FPS Video)
curl -fsSL https://raw.githubusercontent.com/ravin-ship-it/queue/main/setup.sh | bash

# Or enable Hybrid Boost Mode directly (Windows 120+ FPS / Android Hardware)
curl -fsSL https://raw.githubusercontent.com/ravin-ship-it/queue/main/setup.sh | bash -s -- --hybrid
```

> [!TIP]
> **100% Self-Contained Engine**: Queue installs permanently to `~/.local/bin/mpv`. You can delete any cloned repository folder immediately after installation.

---

## 🖥️ Manual Git Clone Installation by OS

If you prefer to clone the repository manually:

### 🐧 Ubuntu / Debian / Kali / Linux Mint / Pop!_OS
```bash
# 1. Install prerequisites
sudo apt update && sudo apt install -y git mpv fzf jq netcat-openbsd nodejs python3 python3-pip

# 2. Clone and install
git clone https://github.com/ravin-ship-it/queue.git
cd queue
./install.sh

# 3. Reload shell
source ~/.bashrc   # or: source ~/.zshrc
```

### 🏔️ Arch Linux / Manjaro / EndeavourOS
```bash
# 1. Install prerequisites
sudo pacman -S --needed git mpv yt-dlp fzf jq gnu-netcat nodejs python

# 2. Clone and install
git clone https://github.com/ravin-ship-it/queue.git
cd queue
./install.sh

# 3. Reload shell
source ~/.bashrc   # or: source ~/.zshrc
```

### 🎩 Fedora / RHEL / CentOS
```bash
# 1. Install prerequisites
sudo dnf install -y git mpv yt-dlp fzf jq nc nodejs python3

# 2. Clone and install
git clone https://github.com/ravin-ship-it/queue.git
cd queue
./install.sh

# 3. Reload shell
source ~/.bashrc   # or: source ~/.zshrc
```

### 🍎 macOS (Homebrew)
```bash
# 1. Install Homebrew (if not already installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. Install prerequisites
brew install mpv yt-dlp fzf jq node

# 3. Clone and install
git clone https://github.com/ravin-ship-it/queue.git
cd queue
./install.sh

# 4. Reload shell
source ~/.zshrc    # or: source ~/.bash_profile
```

### 🪟 Windows 11 / 10 (WSL2)
Queue provides two engines on WSL2:
* **Standalone WSL Mode**: Zero Windows configuration. Runs MPV inside Ubuntu/Debian at 60 FPS via WSLg Mesa D3D12.
* **Hybrid Boost Mode (Recommended)**: Uncapped **120+ FPS Direct3D 11/12**, native Windows WASAPI audio, sub-millisecond IPC named pipe relay, and zero host CPU overhead.

```bash
# Inside WSL2 terminal:
git clone https://github.com/ravin-ship-it/queue.git
cd queue

# Unattended automated setup (auto-installs Windows MPV & yt-dlp via winget):
./install.sh --hybrid

# Or standalone WSL-only setup:
./install.sh --standalone

# Reload shell
source ~/.bashrc   # or: source ~/.zshrc
```

### 📱 Android (Termux)
Queue turns your Android device into a battery-efficient music engine:
* **Standalone Termux Mode**: Headless MPV audio daemon with CPU wake-lock (ultra-low battery).
* **Hybrid Mobile Mode**: Hardware MediaCodec GPU video, AudioTrack tunneling, and Picture-in-Picture via the official [MPV Android App](https://play.google.com/store/apps/details?id=is.xyz.mpv).

```bash
# 1. Inside Termux (from F-Droid), grant storage access (REQUIRED):
termux-setup-storage

# 2. Install packages:
pkg update && pkg install -y git termux-api

# 3. Clone and install:
git clone https://github.com/ravin-ship-it/queue.git
cd queue
./install.sh --hybrid   # or: ./install.sh for standalone audio
```

---

## ⚙️ Automated Installer Flags

Both `install.sh` and `setup.sh` support non-interactive CLI flags:

| Flag | Purpose |
| :--- | :--- |
| `--hybrid` | Automatically enables and configures **Hybrid Boost Mode** (Windows host MPV / Android MPV app) |
| `--standalone` | Enforces standalone Linux/WSL/Termux MPV without external host bridges |
| `-y` / `--yes` | Non-interactive unattended mode; automatically accepts all prompts |

Example unattended installation:
```bash
./install.sh --hybrid -y
```

---

## 🔄 Reinstallation & Setup Lifecycle

### Instant Reinstallation (`q install`)
If Queue has been uninstalled or components are missing, you can reinstall or verify Queue without searching for git repos or curl scripts:
```bash
q install           # Standard reinstallation
q install --hybrid  # Reinstall in Hybrid Boost Mode
```

### Deleting the Setup File (`q -remove-setup`)
To prevent accidental corruption of active installations, `q -remove-setup` includes a built-in safety guard:
* **While Queue is actively installed**: Refuses to run and displays a safety warning (the setup engine is required for `q -up` auto-updates).
* **After uninstallation**: Permanently deletes the dormant setup file, removes the launcher stub, and cleans shell PATH entries.

---

## 🗑️ Clean Uninstallation (`q -uninstall`)

Queue provides an interactive component checklist or a 1-command wipe:

```bash
# 1. Interactive uninstallation (prompts per component)
q -uninstall

# 2. Non-interactive clean uninstallation (preserves instant reinstaller by default)
q -uninstall -y

# 3. Complete system wipe (purges everything, including setup file and PATH)
q -uninstall --purge
```

---

## 🔍 System Verification (`q -deps`)

After installation, verify that all dependencies and hardware profiles are healthy:
```bash
q -deps
```
This runs a multi-engine diagnostic checking core binaries, JS decryptor engines, WSLg hardware acceleration, Windows bridges, and Android audio sinks.
