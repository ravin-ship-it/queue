-- queue_video.lua: Safe video window lifecycle management for Queue (q)
-- Prevents Wayland/EGL/D3D12 driver teardown crashes in WSLg / Linux

local state_file = os.getenv("HOME") .. "/.cache/mpv/video_active"

local function safe_hide()
    mp.set_property_bool("window-minimized", true)
    os.remove(state_file)
    mp.commandv("show-text", "🎧 Audio Mode (Video Hidden)", "1500")
end

local function safe_show()
    mp.set_property_bool("window-minimized", false)
    mp.set_property_bool("force-window", true)
    local f = io.open(state_file, "w")
    if f then
        f:write("1\n")
        f:close()
    end
end

mp.register_script_message("safe-hide-video", safe_hide)
mp.register_script_message("safe-show-video", safe_show)

mp.add_key_binding("q", "safe_hide_q", safe_hide)
mp.add_key_binding("Q", "safe_hide_Q", safe_hide)
mp.add_key_binding("CLOSE_WIN", "safe_hide_close", safe_hide)
mp.add_key_binding("Ctrl+w", "safe_hide_ctrlw", safe_hide)
mp.add_key_binding("Ctrl+W", "safe_hide_ctrlW", safe_hide)
mp.add_key_binding("Alt+F4", "safe_hide_altf4", safe_hide)

mp.observe_property("window-minimized", "bool", function(name, val)
    if val == false then
        local vo = mp.get_property("vo")
        if vo and vo ~= "null" then
            local f = io.open(state_file, "w")
            if f then
                f:write("1\n")
                f:close()
            end
        end
    elseif val == true then
        os.remove(state_file)
    end
end)
