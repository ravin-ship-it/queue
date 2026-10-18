-- queue_video.lua: Safe video window lifecycle management for Queue (q)
-- Prevents Wayland/EGL input-callback teardown race conditions in WSLg / Linux

local function safe_hide_video()
    mp.add_timeout(0.05, function()
        mp.set_property("vid", "no")
        mp.set_property("force-window", "no")
    end)
end

mp.register_script_message("safe-hide-video", safe_hide_video)
mp.add_key_binding("q", "safe_hide_q", safe_hide_video)
mp.add_key_binding("Q", "safe_hide_Q", safe_hide_video)
mp.add_key_binding("CLOSE_WIN", "safe_hide_close", safe_hide_video)
mp.add_key_binding("Ctrl+w", "safe_hide_ctrlw", safe_hide_video)
mp.add_key_binding("Ctrl+W", "safe_hide_ctrlW", safe_hide_video)
mp.add_key_binding("Alt+F4", "safe_hide_altf4", safe_hide_video)
