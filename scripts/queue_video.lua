-- queue_video.lua: Safe video window lifecycle management for Queue (q)
-- Prevents Wayland/EGL/D3D12/Cocoa driver teardown crashes across Linux, WSLg, and macOS

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

mp.register_script_message("safe-hide-video", safe_hide)
mp.register_script_message("safe-show-video", safe_show)

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

-- Reactive State Sync with q TUI
mp.observe_property("window-minimized", "bool", update_state)
mp.observe_property("vo", "string", update_state)
mp.observe_property("vid", "string", update_state)

