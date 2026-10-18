-- queue_video.lua: Safe video window lifecycle management for Queue (q)
-- Prevents Wayland/EGL/D3D12 driver teardown crashes in WSLg / Linux

local function safe_hide()
    mp.set_property("vid", "no")
    mp.set_property_bool("window-minimized", true)
end

local function safe_show()
    mp.set_property_bool("window-minimized", false)
    mp.set_property("vid", "auto")
    mp.set_property_bool("force-window", true)
end

mp.register_script_message("safe-hide-video", safe_hide)
mp.register_script_message("safe-show-video", safe_show)

mp.add_key_binding("q", "safe_hide_q", safe_hide)
mp.add_key_binding("Q", "safe_hide_Q", safe_hide)
mp.add_key_binding("CLOSE_WIN", "safe_hide_close", safe_hide)
mp.add_key_binding("Ctrl+w", "safe_hide_ctrlw", safe_hide)
mp.add_key_binding("Ctrl+W", "safe_hide_ctrlW", safe_hide)
mp.add_key_binding("Alt+F4", "safe_hide_altf4", safe_hide)
