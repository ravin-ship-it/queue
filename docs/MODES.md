# ⚡ Queue (q) — Multi-Engine & Dual-Architecture Guide

Queue features a **Dual-Engine Architecture** that adapts its audio and video rendering backend to match the host hardware environment.

---

## 🪟 Windows + WSL2 Dual-Engine System

When running inside Windows Subsystem for Linux (WSL2), Queue offers two distinct operational modes:

| Feature | 🐧 Standalone WSL Mode | ⚡ Hybrid Boost Mode |
| :--- | :--- | :--- |
| **MPV Binary** | Linux MPV (`/usr/bin/mpv`) | Windows Native MPV (`mpv.exe`) |
| **Framerate Cap** | 60 FPS (WSLg Compositor) | **Uncapped (120+ / 144 / 240 FPS)** |
| **Graphics API** | Mesa Gallium D3D12 (Virtual) | **Direct3D 11/12 Hardware Native** |
| **Audio Backend** | PulseAudio / WSLg RDP Sink | **Windows WASAPI Exclusive / DirectSound** |
| **IPC Latency** | UNIX Domain Socket (`~/.mpv-socket`) | Sub-millisecond Named Pipe (`\\.\pipe\mpv-pipe`) |
| **Video Window** | WSLg Wayland Window | Borderless / Native Windows Aero Window |
| **Host Setup** | Zero Windows setup | Auto-installed via winget |

### Switching Engines on WSL2
You can switch engines at runtime without restarting your terminal:
```bash
# Activate Hybrid Boost Mode (120+ FPS Direct3D & WASAPI)
q -hybrid on

# Switch back to Standalone WSL Mode
q -hybrid off

# View active engine status and latency
q -hybrid status
```

### How Windows Hybrid Boost Mode Works Under the Hood
1. **Zero-Overhead Daemon**: When `q` is executed in WSL2, `hybrid_bridge.py` spawns a detached Windows MPV process on the Windows host.
2. **Sub-Millisecond Named Pipe Relay (`PipeRelay.exe`)**: Compiled via Windows' native .NET Framework (`csc.exe`), this zero-dependency binary bridges the Windows Named Pipe (`\\.\pipe\mpv-pipe`) to standard I/O, allowing WSL2 netcat (`nc`) to send sub-millisecond IPC commands.
3. **Instant Desktop Video Window (`q -vid`)**: Video is rendered directly by the host GPU using Direct3D. When hidden, MPV seamlessly drops video decoding to conserve CPU and bandwidth.

---

## 📱 Android / Termux Dual-Engine System

On Android devices running Termux, Queue provides two purpose-built engines:

| Feature | 🐧 Standalone Termux Mode | 🤖 Hybrid Mobile Mode |
| :--- | :--- | :--- |
| **Engine** | Headless CLI MPV (`pkg install mpv`) | Official **[MPV Android App](https://play.google.com/store/apps/details?id=is.xyz.mpv)** |
| **Battery Consumption** | **Ultra-Low (<2% per hour)** | Moderate (Full GPU active) |
| **Video Decoding** | Disabled (`vo=null`) | **MediaCodec GPU Hardware Acceleration** |
| **Audio Routing** | OpenSL ES / AAudio (Termux) | **Android AudioTrack Hardware Tunneling** |
| **Background Playback** | CPU Wake-Lock via `termux-api` | Native Android Media Notification |
| **Picture-in-Picture** | N/A | **Full Android PiP & Lockscreen Controls** |
| **Best For** | Walking, commuting, screen-off music | Music videos, 1080p60/4K anime, multitasking |

### Switching Engines on Android
```bash
# Enable Hybrid Mobile Mode (delegates to MPV Android App)
q -hybrid on

# Switch to Standalone Headless Audio Mode
q -hybrid off

# Check Android engine status
q -hybrid status
```

### How Android Hybrid Mode Works Under the Hood
1. **Dynamic Stream Bridge (`android_stream_bridge.py`)**: Runs an ultra-lightweight HTTP streaming proxy on `127.0.0.1:8989`. It negotiates direct DASH/HLS audio and video streams from yt-dlp.
2. **Multi-Stream EDL Synthesis**: Streams are packed into an EDL (Edit Decision List) URL (`edl://!no_clip...`), allowing the Android MPV app to merge separate 1080p video and 160k Opus audio chunks without local remuxing.
3. **Live IPC Command Buffer (`/sdcard/mpv/queue_cmd.txt`)**: A lightweight Lua bridge (`queue_android_bridge.lua`) inside the MPV app monitors commands written by Termux for real-time play, pause, seek, and track skips.

---

## 🐧 Bare-Metal Linux (Wayland / X11)

On native Linux desktop installations, Queue bypasses virtualization and renders directly to your display server:
* **Wayland**: Uses `vo=gpu-next` with native Wayland protocols.
* **X11**: Direct X11 window embedding with high-DPI scaling.
* **Audio Sinks**: Automatically prioritizes **PipeWire** (`--ao=pipewire`), falling back to **PulseAudio** or **ALSA** bit-perfect hardware output.

---

## 🍎 macOS (Darwin / Metal)

On macOS systems:
* **Video Rendering**: Automatically leverages Apple **Metal** API via `vo=gpu-next` and `gpu-api=opengl/metal`.
* **Audio**: Direct hardware output via **CoreAudio** with low latency.
* **Clipboard Integration**: Seamlessly pulls YouTube and Spotify URLs from the macOS clipboard via `pbpaste`.
