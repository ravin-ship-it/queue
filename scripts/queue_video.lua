-- queue_video.lua: Safe video window lifecycle management & seamless resolution switching for Queue (q)
-- Prevents Wayland/EGL/D3D12/Cocoa driver teardown crashes across Linux, WSLg, and macOS
-- Preserves playback position seamlessly during live stream quality changes

local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
local state_file = home ~= "" and (home .. "/.cache/mpv/video_active") or nil

local function safe_hide()
    mp.set_property_bool("window-minimized", true)
    if state_file then pcall(os.remove, state_file) end
    mp.commandv("show-text", "🎧 Audio Mode (Video Hidden)", "1500")
end

local function safe_show()
    mp.set_property_bool("window-minimized", false)
    mp.set_property_bool("force-window", true)
    if state_file then
        local f = io.open(state_file, "w")
        if f then
            f:write("1\n")
            f:close()
        end
    end
end

local function update_state()
    local minimized = mp.get_property_bool("window-minimized", false)
    local vo = mp.get_property("vo")
    local vid = mp.get_property("vid")

    if not minimized and vo and vo ~= "null" and vid and vid ~= "no" and vid ~= "false" then
        if state_file then
            local f = io.open(state_file, "w")
            if f then
                f:write("1\n")
                f:close()
            end
        end
    else
        if state_file then pcall(os.remove, state_file) end
    end
end

-- Seamless Resolution / Quality Switch with Zero-Restart Playback Position Memory
local pending_resume_pos = nil

local function on_playback_restart()
    if pending_resume_pos and pending_resume_pos > 2 then
        local pos = pending_resume_pos
        pending_resume_pos = nil
        mp.commandv("seek", pos, "absolute+exact")
    end
end

local function change_resolution(fmt, label)
    if not fmt or fmt == "" then return end
    local cur_time = mp.get_property_number("time-pos")
    if cur_time and cur_time > 2 then
        pending_resume_pos = cur_time
    else
        pending_resume_pos = nil
    end

    mp.set_property("ytdl-format", fmt)
    mp.commandv("playlist-play-index", "current")
    if label and label ~= "" then
        mp.commandv("show-text", "Quality: " .. label, 2500)
    end
end

mp.register_script_message("safe-hide-video", safe_hide)
mp.register_script_message("safe-show-video", safe_show)
mp.register_script_message("change-resolution", change_resolution)
mp.register_event("playback-restart", on_playback_restart)

-- Linux / Windows / WSL Close Hotkeys
mp.add_key_binding("q", "safe_hide_q", safe_hide)
mp.add_key_binding("Q", "safe_hide_Q", safe_hide)
mp.add_key_binding("CLOSE_WIN", "safe_hide_close", safe_hide)
mp.add_key_binding("Ctrl+w", "safe_hide_ctrlw", safe_hide)
mp.add_key_binding("Ctrl+W", "safe_hide_ctrlW", safe_hide)
mp.add_key_binding("Alt+F4", "safe_hide_altf4", safe_hide)

-- macOS Close Hotkeys (Command+W, Command+Q)
mp.add_key_binding("Meta+w", "safe_hide_metaw", safe_hide)
mp.add_key_binding("Meta+W", "safe_hide_metaW", safe_hide)
mp.add_key_binding("Meta+q", "safe_hide_metaq", safe_hide)
mp.add_key_binding("Meta+Q", "safe_hide_metaQ", safe_hide)

-- In-Window Quality Hotkeys (Seamless position memory)
local hotkey_0 = "bestvideo[height<=1440][fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1440][fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1080][fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1080][fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1080]+bestaudio[acodec=opus]/bestvideo[height<=1080]+bestaudio/bestvideo[height<=720]+bestaudio/bestvideo+bestaudio/best"
local hotkey_1 = "bestvideo[height<=720][fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=720][fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=720][fps>=50]+bestaudio/bestvideo[height<=720]+bestaudio[acodec=opus]/bestvideo[height<=720]+bestaudio/best[height<=720]"
local hotkey_2 = "bestvideo[height<=1080][fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1080][fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1080][fps>=50]+bestaudio/bestvideo[height<=1080]+bestaudio[acodec=opus]/bestvideo[height<=1080]+bestaudio/best"
local hotkey_3 = "bestvideo[height<=1440][fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1440][fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[height<=1440][fps>=50]+bestaudio/bestvideo[height<=1440]+bestaudio[acodec=opus]/bestvideo[height<=1440]+bestaudio/best"
local hotkey_4 = "bestvideo[fps>=50][vcodec^=avc1][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo[fps>=50][vcodec^=vp9][format_note!*=Premium]+bestaudio[acodec=opus]/bestvideo+bestaudio[acodec=opus]/bestvideo+bestaudio/best"

mp.add_key_binding("0", "quality_0", function() change_resolution(hotkey_0, "Auto / Smart 60FPS") end)
mp.add_key_binding("1", "quality_1", function() change_resolution(hotkey_1, "720p HD (60fps)") end)
mp.add_key_binding("2", "quality_2", function() change_resolution(hotkey_2, "1080p Full HD (60fps)") end)
mp.add_key_binding("3", "quality_3", function() change_resolution(hotkey_3, "1440p 2K QHD (60fps)") end)
mp.add_key_binding("4", "quality_4", function() change_resolution(hotkey_4, "Max / 4K UHD") end)

-- Reactive State Sync with q TUI
mp.observe_property("window-minimized", "bool", update_state)
mp.observe_property("vo", "string", update_state)
mp.observe_property("vid", "string", update_state)
