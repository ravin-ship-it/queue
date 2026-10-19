-- queue_video.lua: Safe video window lifecycle management & seamless resolution switching for Queue (q)
-- Prevents Wayland/EGL/D3D12/Cocoa driver teardown crashes across Linux, WSLg, and macOS
-- Preserves playback position seamlessly during live stream quality changes
-- Implements Smart Virtual Shuffle Engine with persistent history stack across MPV daemon sessions

math.randomseed(os.time())
math.random(); math.random(); math.random()

local raw_home = os.getenv("USERPROFILE") or os.getenv("HOME") or ""
local home = raw_home:gsub("\\", "/")
local state_file = home ~= "" and (home .. "/.cache/mpv/video_active") or nil
local hist_file = home ~= "" and (home .. "/.cache/mpv/shuffle_history") or nil

local function record_history(idx)
    if not hist_file or not idx then return end
    local f = io.open(hist_file, "a")
    if f then
        f:write(tostring(idx) .. "\n")
        f:close()
    end
end

local function pop_history()
    if not hist_file then return nil end
    local f = io.open(hist_file, "r")
    if not f then return nil end
    local lines = {}
    for line in f:lines() do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            table.insert(lines, trimmed)
        end
    end
    f:close()
    if #lines == 0 then return nil end
    local last_idx = tonumber(lines[#lines])
    table.remove(lines)
    local fw = io.open(hist_file, "w")
    if fw then
        for _, l in ipairs(lines) do
            fw:write(l .. "\n")
        end
        fw:close()
    end
    return last_idx
end

local function smart_next(is_auto_eof)
    local shuf = mp.get_property_bool("shuffle", false)
    local count = mp.get_property_number("playlist-count", 0)
    local pos = mp.get_property_number("playlist-pos", -1)

    if shuf and count > 1 then
        if pos >= 0 then
            record_history(pos)
        end
        local rand_idx = pos
        for _ = 1, 30 do
            local r = math.random(0, count - 1)
            if r ~= pos then
                rand_idx = r
                break
            end
        end
        mp.commandv("playlist-play-index", rand_idx)
    elseif not is_auto_eof then
        mp.commandv("playlist-next")
    end
end

local function smart_prev()
    local shuf = mp.get_property_bool("shuffle", false)
    if shuf then
        local prev_idx = pop_history()
        if prev_idx and prev_idx >= 0 then
            mp.commandv("playlist-play-index", prev_idx)
            return
        end
    end
    mp.commandv("playlist-prev")
end

local function on_file_end(event)
    if event.reason ~= "eof" then return end
    local lf = mp.get_property("loop-file", "no")
    if lf ~= "no" and lf ~= "false" then return end
    smart_next(true)
end

local shuffle_init = false
local function on_shuffle_change(name, val)
    if not shuffle_init then
        shuffle_init = true
        return
    end
    if val == true then
        mp.commandv("show-text", "🔀 Shuffle: ON", 1500)
    elseif val == false then
        if hist_file then pcall(os.remove, hist_file) end
        mp.commandv("show-text", "Shuffle: OFF", 1500)
    end
end

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

-- Event Registrations
mp.register_event("end-file", on_file_end)
mp.register_event("playback-restart", on_playback_restart)
mp.observe_property("shuffle", "bool", on_shuffle_change)
mp.observe_property("window-minimized", "bool", update_state)
mp.observe_property("vo", "string", update_state)
mp.observe_property("vid", "string", update_state)

-- Script Messages
mp.register_script_message("safe-hide-video", safe_hide)
mp.register_script_message("safe-show-video", safe_show)
mp.register_script_message("change-resolution", change_resolution)
mp.register_script_message("smart-next", function() smart_next(false) end)
mp.register_script_message("smart-prev", smart_prev)

-- Smart Navigation Keybindings
mp.add_key_binding(">", "smart_next_key", function() smart_next(false) end)
mp.add_key_binding("ENTER", "smart_next_enter", function() smart_next(false) end)
mp.add_key_binding("<", "smart_prev_key", smart_prev)

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
