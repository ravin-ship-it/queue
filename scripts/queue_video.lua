-- queue_video.lua: Safe video window lifecycle management, seamless resolution switching & adaptive network resilience for Queue (q)
-- Prevents Wayland/EGL/D3D12/Cocoa driver teardown crashes across Linux, WSLg, and macOS
-- Preserves playback position seamlessly during live stream quality changes
-- Implements YouTube-like Smart Adaptive Bitrate (ABR) with buffer underrun detection and auto-downshift
-- Implements Anti-Suicide Network Drop Safeguard to freeze queue during internet outages and auto-resume on reconnection
-- Implements Smart Virtual Shuffle Engine with persistent history stack across MPV daemon sessions

math.randomseed(os.time())
math.random(); math.random(); math.random()

local raw_home = os.getenv("USERPROFILE") or os.getenv("HOME") or ""
local home = raw_home:gsub("\\", "/")
local state_file = home ~= "" and (home .. "/.cache/mpv/video_active") or nil
local hist_file = home ~= "" and (home .. "/.cache/mpv/shuffle_history") or nil

-- =========================================================================
-- 1. Virtual Shuffle Engine & Persistent History
-- =========================================================================

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
        mp.set_property_bool("pause", false)
    else
        if is_auto_eof then
            local loop_p = mp.get_property("loop-playlist", "no")
            if pos >= 0 and (pos + 1) < count then
                mp.commandv("playlist-next")
                mp.set_property_bool("pause", false)
            elseif loop_p ~= "no" and loop_p ~= "false" and count > 0 then
                mp.commandv("playlist-play-index", 0)
                mp.set_property_bool("pause", false)
            end
        else
            mp.commandv("playlist-next")
            mp.set_property_bool("pause", false)
        end
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

-- =========================================================================
-- 2. Window Lifecycle & Crash Prevention
-- =========================================================================

local function safe_hide()
    mp.set_property_bool("window-minimized", true)
    if state_file then pcall(os.remove, state_file) end
    mp.commandv("show-text", "🎧 Audio Mode (Video Hidden)", 1500)
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

-- =========================================================================
-- 3. Audio Language & Quality Profile Engine
-- =========================================================================

local lang_file = home ~= "" and (home .. "/.config/mpv/queue_lang") or nil
local langs_cache_file = home ~= "" and (home .. "/.cache/mpv/current_audio_langs.json") or nil
local res_file = nil
local hw_ceiling_file = nil
local speed_file = nil
local audio_mode_file = nil
if home ~= "" then
    if (package.config:sub(1,1) == "\\") or (os.getenv("WINDIR") ~= nil) then
        res_file = home .. "/AppData/Roaming/mpv/queue_res"
        hw_ceiling_file = home .. "/AppData/Roaming/mpv/queue_hw_ceiling"
        speed_file = home .. "/AppData/Roaming/mpv/queue_speed"
        audio_mode_file = home .. "/AppData/Roaming/mpv/queue_audio_mode"
    else
        res_file = home .. "/.config/mpv/queue_res"
        hw_ceiling_file = home .. "/.config/mpv/queue_hw_ceiling"
        speed_file = home .. "/.config/mpv/queue_speed"
        audio_mode_file = home .. "/.config/mpv/queue_audio_mode"
    end
end

local function is_audio_mode_active()
    if not audio_mode_file then return false end
    local f = io.open(audio_mode_file, "r")
    if not f then return false end
    local content = f:read("*l")
    f:close()
    if content then
        content = content:match("^%s*(.-)%s*$")
        return (content == "true" or content == "1" or content == "on")
    end
    return false
end

local function save_audio_mode(enabled)
    if not audio_mode_file then return end
    local f = io.open(audio_mode_file, "w")
    if f then
        f:write(enabled and "true\n" or "false\n")
        f:close()
    end
end

local function get_saved_speed()
    if not speed_file then return 1.0 end
    local f = io.open(speed_file, "r")
    if not f then return 1.0 end
    local content = f:read("*a")
    f:close()
    if content then
        local trimmed = content:match("^%s*(.-)%s*$")
        local num = tonumber(trimmed)
        if num and num >= 0.25 and num <= 4.0 then
            return num
        end
    end
    return 1.0
end

local function save_speed(val)
    if not speed_file or not val then return end
    local f = io.open(speed_file, "w")
    if f then
        f:write(string.format("%.2f\n", val))
        f:close()
    end
end

local function set_playback_speed(val)
    if not val then return end
    val = math.max(0.25, math.min(4.0, math.floor(val * 100 + 0.5) / 100))
    mp.set_property_number("speed", val)
    pcall(mp.set_property, "user-data/queue-speed", string.format("%.2f", val))
    save_speed(val)

    local label = string.format("⚡ Speed: %.2fx", val)
    if math.abs(val - 1.0) < 0.01 then
        label = "⚡ Speed: 1.00x (Normal)"
    end
    mp.commandv("show-text", label, 1500)
end

local function adjust_playback_speed(delta)
    local cur = mp.get_property_number("speed", 1.0)
    set_playback_speed(cur + delta)
end

local function get_saved_res()
    if not res_file then return "auto" end
    local f = io.open(res_file, "r")
    if not f then return "auto" end
    local content = f:read("*a")
    f:close()
    if content then
        local trimmed = content:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then return trimmed:lower() end
    end
    return "auto"
end

local function save_res_pref(tier)
    if not res_file or not tier then return end
    local f = io.open(res_file, "w")
    if f then
        f:write(tier .. "\n")
        f:close()
    end
end

local function get_hw_ceiling()
    if not hw_ceiling_file then return "4k" end
    local f = io.open(hw_ceiling_file, "r")
    if not f then return "4k" end
    local content = f:read("*a")
    f:close()
    if content then
        local trimmed = content:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then return trimmed:lower() end
    end
    return "4k"
end

local function save_hw_ceiling(tier)
    if not hw_ceiling_file or not tier then return end
    local f = io.open(hw_ceiling_file, "w")
    if f then
        f:write(tier .. "\n")
        f:close()
    end
end

local function get_saved_lang()
    if not lang_file then return "en" end
    local f = io.open(lang_file, "r")
    if not f then return "en" end
    local content = f:read("*a")
    f:close()
    if content then
        local trimmed = content:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then return trimmed:lower() end
    end
    return "en"
end

local function save_lang_pref(lang)
    if not lang_file or not lang then return end
    local f = io.open(lang_file, "w")
    if f then
        f:write(lang .. "\n")
        f:close()
    end
end

local current_lang = get_saved_lang()
local cached_track_url = ""
local cached_audio_langs = {}

local function get_lang_label(code)
    code = (code or "auto"):lower()
    if code == "en" then return "English"
    elseif code == "zh" then return "Chinese (中文)"
    elseif code == "ja" then return "Japanese (日本語)"
    elseif code == "ko" then return "Korean (한국어)"
    elseif code == "es" then return "Spanish (Español)"
    elseif code == "fr" then return "French (Français)"
    elseif code == "de" then return "German (Deutsch)"
    elseif code == "ru" then return "Russian (Русский)"
    elseif code == "hi" then return "Hindi (हिन्दी)"
    elseif code == "pt" then return "Portuguese (Português)"
    elseif code == "it" then return "Italian (Italiano)"
    elseif code == "auto" or code == "orig" or code == "original" then return "Original Audio (Auto)"
    else return code:upper() end
end

local function get_audio_format(lang)
    lang = (lang or current_lang or "en"):lower()
    if lang == "auto" or lang == "orig" or lang == "original" then
        return "(bestaudio[acodec=opus]/bestaudio[acodec^=mp4a]/bestaudio)"
    end
    return string.format("(bestaudio[language=%s][acodec=opus]/bestaudio[language^=%s][acodec=opus]/bestaudio[language=%s]/bestaudio[language^=%s]/bestaudio[acodec=opus]/bestaudio[acodec^=mp4a]/bestaudio)", lang, lang, lang, lang)
end

local function get_quality_format(tier, lang)
    tier = (tier or "auto"):lower()
    local audio_fmt = get_audio_format(lang)
    local hw_ceiling = get_hw_ceiling()

    if tier == "audio" or tier == "aud" then
        return audio_fmt
    end

    if tier == "auto" or tier == "max" then
        if hw_ceiling == "8k" or hw_ceiling == "4320" then
            -- Uncapped 8K for high-end rigs with dedicated 8K hardware decoder
            return "bestvideo[fps>30][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[format_note!*=Premium]+" .. audio_fmt .. "/bestvideo+" .. audio_fmt .. "/best"
        elseif hw_ceiling == "high" or hw_ceiling == "1440" or hw_ceiling == "2k" then
            return "bestvideo[height<=1440][fps>30][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=1440][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=1440]+" .. audio_fmt .. "/best[height<=1440]"
        elseif hw_ceiling == "mid" or hw_ceiling == "1080" then
            return "bestvideo[height<=1080][fps>30][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=1080][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=1080]+" .. audio_fmt .. "/best[height<=1080]"
        else
            -- Default smooth hardware ceiling: 4K (2160p) @ 60 FPS (prevents 8K decoder overload & game-like lag)
            return "bestvideo[height<=2160][fps>30][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=2160][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=2160]+" .. audio_fmt .. "/best[height<=2160]"
        end
    elseif tier == "8k" or tier == "4320" then
        -- Explicit 8K manual override
        return "bestvideo[fps>30][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[format_note!*=Premium]+" .. audio_fmt .. "/bestvideo+" .. audio_fmt .. "/best"
    elseif tier == "4k" or tier == "2160" or tier == "uhd" then
        return "bestvideo[height<=2160][fps>30][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=2160][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=2160]+" .. audio_fmt .. "/best[height<=2160]"
    elseif tier == "high" or tier == "1440" or tier == "2k" or tier == "qhd" then
        return "bestvideo[height<=1440][fps>30][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=1440][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=1440]+" .. audio_fmt .. "/best[height<=1440]"
    elseif tier == "mid" or tier == "1080" or tier == "fhd" or tier == "medium" then
        return "bestvideo[height<=1080][fps>30][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=1080][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=1080]+" .. audio_fmt .. "/best[height<=1080]"
    elseif tier == "low" or tier == "720" or tier == "hd" then
        return "bestvideo[height<=720][fps>30][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=720][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=720]+" .. audio_fmt .. "/best[height<=720]"
    elseif tier == "480" or tier == "sd" then
        return "bestvideo[height<=480][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=480]+" .. audio_fmt .. "/best[height<=480]"
    elseif tier == "360" or tier == "emergency" then
        return "bestvideo[height<=360][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=360]+" .. audio_fmt .. "/best[height<=360]"
    else
        return "bestvideo[height<=2160][fps>30][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=2160][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=2160]+" .. audio_fmt .. "/best[height<=2160]"
    end
end

local QUALITY_PROFILES = {
    ["audio"] = { label = "Audio-Only (98% Bandwidth Reduction / Pure Opus Stream)" },
    ["auto"] = { label = "Auto / Smart (Hardware-adapted, protects buffer & smoothness)" },
    ["low"] = { label = "Low / 720p HD (60fps fluid / bandwidth saver)" },
    ["mid"] = { label = "Mid / 1080p Full HD (60fps crisp)" },
    ["high"] = { label = "High / 1440p 2K QHD (60fps ultra-crisp)" },
    ["max"] = { label = "Max / Hardware Ceiling (Highest smooth FPS & resolution)" },
    ["4k"] = { label = "4K UHD (3840x2160 @ 60fps smooth)" },
    ["8k"] = { label = "8K UHD (7680x4320 @ 60fps uncapped)" },
    ["480"] = { label = "480p SD (Low-bandwidth smooth)" },
    ["360"] = { label = "360p Low (Emergency smooth)" }
}

local initial_saved_res = get_saved_res()
local is_auto_mode = (initial_saved_res == "auto")
local current_tier = initial_saved_res
pcall(mp.set_property, "user-data/queue-res", current_tier)

if is_audio_mode_active() then
    mp.set_property("vid", "no")
    mp.set_property("video", "no")
    mp.set_property("force-window", "no")
    mp.set_property_bool("window-minimized", true)
    local fmt = get_quality_format("audio", current_lang)
    mp.set_property("ytdl-format", fmt)
end

local initial_saved_speed = get_saved_speed()
if initial_saved_speed and initial_saved_speed ~= 1.0 then
    mp.set_property_number("speed", initial_saved_speed)
    pcall(mp.set_property, "user-data/queue-speed", string.format("%.2f", initial_saved_speed))
end
local track_start_time = 0
local has_downshifted_this_track = false
local starved_buffer_seconds = 0
local last_adaptation_time = 0
local recent_stalls = {}
local stable_buffer_seconds = 0

local pending_resume_pos = nil
local resume_timer = nil

-- Position tracker for crash & network drop recovery
local last_valid_pos = -1
local last_valid_time = 0
local last_valid_url = ""

local function do_resume_seek()
    if not pending_resume_pos then
        if resume_timer then resume_timer:kill(); resume_timer = nil end
        return
    end

    local pos = pending_resume_pos
    local seekable = mp.get_property_bool("seekable", false)
    local cur_time = mp.get_property_number("time-pos", nil)

    if seekable and cur_time and cur_time >= 0 then
        if math.abs(cur_time - pos) > 2.0 then
            mp.commandv("seek", pos, "absolute")
        end
        pending_resume_pos = nil
        if resume_timer then resume_timer:kill(); resume_timer = nil end
    end
end

local function arm_resume_seek(pos)
    if not pos or pos <= 1.0 then return end
    pending_resume_pos = pos
    if resume_timer then resume_timer:kill(); resume_timer = nil end
end

local function queue_resume_seek(pos)
    if not pos or pos <= 1.0 then return end
    pending_resume_pos = pos
    if resume_timer then resume_timer:kill() end

    local attempts = 0
    resume_timer = mp.add_periodic_timer(0.12, function()
        attempts = attempts + 1
        if not pending_resume_pos or attempts > 50 then
            if resume_timer then resume_timer:kill(); resume_timer = nil end
            pending_resume_pos = nil
            return
        end
        do_resume_seek()
    end)
end

local function change_quality(target, is_auto_adaptive)
    target = string.lower(target or "auto")
    if target == "smart" then target = "auto" end

    -- Normalize aliases to canonical tiers: low, mid, high, max, auto
    if target == "720" or target == "720p" or target == "hd" or target == "low" then
        target = "low"
    elseif target == "1080" or target == "1080p" or target == "fhd" or target == "mid" or target == "medium" then
        target = "mid"
    elseif target == "1440" or target == "1440p" or target == "2k" or target == "qhd" or target == "high" then
        target = "high"
    elseif target == "4k" or target == "8k" or target == "2160" or target == "4320" or target == "uhd" or target == "max" then
        target = "max"
    elseif target == "sd" then
        target = "480"
    elseif target == "emergency" then
        target = "360"
    elseif target == "audio" or target == "aud" then
        target = "audio"
    end

    local profile = QUALITY_PROFILES[target]
    if not profile then
        profile = QUALITY_PROFILES["auto"]
        target = "auto"
    end

    if target == "audio" then
        save_audio_mode(true)
        mp.set_property("vid", "no")
        mp.set_property("video", "no")
        mp.set_property("force-window", "no")
        mp.set_property_bool("window-minimized", true)
        if state_file then pcall(os.remove, state_file) end
    else
        if is_audio_mode_active() then
            save_audio_mode(false)
            mp.set_property("vid", "auto")
            mp.set_property("video", "auto")
            safe_show()
        end
        if not is_auto_adaptive then
            is_auto_mode = (target == "auto")
            current_tier = target
            save_res_pref(target)
            has_downshifted_this_track = false
            starved_buffer_seconds = 0
            recent_stalls = {}
            stable_buffer_seconds = 0
            track_start_time = mp.get_time()
            last_adaptation_time = mp.get_time()
        else
            current_tier = target
            track_start_time = mp.get_time()
            last_adaptation_time = mp.get_time()
        end
        pcall(mp.set_property, "user-data/queue-res", current_tier)
    end

    -- Capture current timestamp and set start property + queue seek on reload
    local cur_time = mp.get_property_number("time-pos")
    if (not cur_time or cur_time < 1.0) and last_valid_time > 1.0 then
        cur_time = last_valid_time
    end
    if cur_time and cur_time > 1.0 then
        arm_resume_seek(cur_time)
        mp.set_property("start", string.format("%.2f", cur_time))
    else
        pending_resume_pos = nil
    end

    local fmt = get_quality_format(target, current_lang)
    mp.set_property("ytdl-format", fmt)
    mp.commandv("playlist-play-index", "current")

    local banner = "Quality: " .. profile.label
    if is_auto_adaptive then
        banner = "⚡ Adaptive Quality: Downshifted to " .. profile.label
    end
    mp.commandv("show-text", banner, 2500)
end

local function change_resolution(fmt, label)
    if not fmt or fmt == "" then return end
    local cur_time = mp.get_property_number("time-pos")
    if (not cur_time or cur_time < 1.0) and last_valid_time > 1.0 then
        cur_time = last_valid_time
    end
    if cur_time and cur_time > 1.0 then
        arm_resume_seek(cur_time)
        mp.set_property("start", string.format("%.2f", cur_time))
    else
        pending_resume_pos = nil
    end

    mp.set_property("ytdl-format", fmt)
    mp.commandv("playlist-play-index", "current")
    if label and label ~= "" then
        mp.commandv("show-text", "Quality: " .. label, 2500)
    end
end

local function change_language(lang, label)
    if not lang or lang == "" then lang = "auto" end
    lang = string.lower(lang)
    current_lang = lang
    save_lang_pref(lang)

    -- Capture current playback timestamp to seamlessly resume without restarting
    local cur_time = mp.get_property_number("time-pos")
    if (not cur_time or cur_time < 1.0) and last_valid_time > 1.0 then
        cur_time = last_valid_time
    end
    if cur_time and cur_time > 1.0 then
        arm_resume_seek(cur_time)
        mp.set_property("start", string.format("%.2f", cur_time))
    else
        pending_resume_pos = nil
    end

    -- 1. Check for native multi-track audio container (MKV / MP4 / local file)
    local tracks = mp.get_property_native("track-list", {})
    local local_audio_count = 0
    local matched_track = nil
    for _, t in ipairs(tracks) do
        if t.type == "audio" then
            local_audio_count = local_audio_count + 1
            local t_lang = string.lower(t.lang or "")
            if t_lang == lang or (lang == "auto" and t.default) then
                matched_track = t
            end
        end
    end

    if local_audio_count > 1 and matched_track then
        mp.set_property("aid", matched_track.id)
        local display = label or string.format("[%s] %s", matched_track.lang or "und", matched_track.title or ("Audio Track " .. matched_track.id))
        mp.commandv("show-text", "🔊 Audio Track: " .. display, 2500)
        return
    end

    -- 2. Remote / YouTube DASH stream reload
    local fmt = get_quality_format(current_tier, current_lang)
    mp.set_property("ytdl-format", fmt)
    mp.commandv("playlist-play-index", "current")

    local display = label or string.format("[%s] %s", lang, get_lang_label(lang))
    mp.commandv("show-text", "🔊 Audio Language: " .. display, 2500)
end

local function get_available_langs_cached()
    local path = mp.get_property("path", "")
    if path == "" then return {} end

    if cached_track_url == path and #cached_audio_langs > 0 then
        return cached_audio_langs
    end

    if langs_cache_file then
        local f = io.open(langs_cache_file, "r")
        if f then
            local content = f:read("*a")
            f:close()
            if content and content ~= "" then
                local u = require("mp.utils")
                local parsed = u.parse_json(content)
                if parsed and type(parsed) == "table" and #parsed > 0 then
                    cached_track_url = path
                    cached_audio_langs = parsed
                    return cached_audio_langs
                end
            end
        end
    end

    return {}
end

local function cycle_audio_language()
    -- Check local tracks first
    local tracks = mp.get_property_native("track-list", {})
    local local_audio_count = 0
    for _, t in ipairs(tracks) do
        if t.type == "audio" then local_audio_count = local_audio_count + 1 end
    end

    if local_audio_count > 1 then
        mp.commandv("cycle", "audio")
        local aid = mp.get_property("aid")
        local alang = mp.get_property("current-tracks/audio/lang") or "und"
        local atitle = mp.get_property("current-tracks/audio/title") or ""
        mp.commandv("show-text", string.format("🔊 Audio Track: #%s [%s] %s", tostring(aid), alang, atitle), 2000)
        return
    end

    local langs = get_available_langs_cached()
    if #langs <= 1 then
        mp.commandv("show-text", "🔊 Audio: Single track (no alternate dubs)", 2000)
        return
    end

    local cur_idx = 1
    for i, item in ipairs(langs) do
        if item.lang == current_lang then
            cur_idx = i
            break
        end
    end

    local next_idx = (cur_idx % #langs) + 1
    local next_item = langs[next_idx]
    local banner = string.format("[%s] %s (%d/%d)", next_item.lang, (next_item.note ~= "" and next_item.note or get_lang_label(next_item.lang)), next_idx, #langs)
    change_language(next_item.lang, banner)
end

local function fetch_stream_languages_async(url)
    if not url or not (url:match("^http://") or url:match("^https://")) then return end
    if cached_track_url == url and #cached_audio_langs > 0 then return end

    local ytdl = "yt-dlp"
    local raw_h = os.getenv("USERPROFILE") or ""
    if raw_h ~= "" and (raw_h:find("^[a-zA-Z]:") ~= nil) then
        local w_ytdl = home .. "/AppData/Local/Microsoft/WinGet/Packages/yt-dlp.yt-dlp_Microsoft.Winget.Source_8wekyb3d8bbwe/yt-dlp.exe"
        local f = io.open(w_ytdl, "r")
        if f then f:close(); ytdl = w_ytdl end
    end

    mp.command_native_async({
        name = "subprocess",
        args = { ytdl, "--dump-json", "--skip-download", "--flat-playlist", "--no-warnings", url },
        capture_stdout = true,
        playback_only = false
    }, function(success, res)
        if success and res and res.status == 0 and res.stdout and res.stdout ~= "" then
            local u = require("mp.utils")
            local d = u.parse_json(res.stdout)
            if d and d.formats then
                local found = {}
                local list = {}
                for _, fmt in ipairs(d.formats) do
                    if fmt.vcodec == "none" and fmt.acodec and fmt.acodec ~= "none" then
                        local l = fmt.language or "default"
                        if not found[l] then
                            found[l] = true
                            table.insert(list, {
                                lang = l,
                                note = fmt.format_note or ""
                            })
                        end
                    end
                end
                if #list > 0 then
                    cached_track_url = url
                    cached_audio_langs = list
                    if langs_cache_file then
                        local out_json = u.format_json(list)
                        local fw = io.open(langs_cache_file, "w")
                        if fw then
                            fw:write(out_json .. "\n")
                            fw:close()
                        end
                    end
                end
            end
        end
    end)
end

-- =========================================================================
-- 4. YouTube-like Smart Adaptive Bitrate (ABR) Brain
-- =========================================================================

local function evaluate_adaptive_bitrate()
    if is_audio_mode_active() then return end
    if not is_auto_mode then return end

    -- If player is idle or stream has not started demuxing frames yet, do not evaluate
    local cur_time = mp.get_property_number("time-pos", nil)
    if not cur_time or cur_time < 0.5 then
        return
    end

    local idle = mp.get_property_bool("idle-active", false)
    if idle then return end

    local path = mp.get_property("path", "")
    if not path or path == "" then return end
    local is_remote = (path:match("^https?://") ~= nil) or (path:match("^ytdl://") ~= nil)
    if not is_remote then return end -- Strict local file immunity: zero network downshifts

    local now = mp.get_time()
    -- 15-second grace period on new track start to allow demuxer to establish DASH buffers
    if track_start_time > 0 and (now - track_start_time < 15) then
        return
    end

    -- Downshift cooldown: at most one downshift per track, or 45s between emergency actions
    if has_downshifted_this_track and (now - last_adaptation_time < 45) then
        return
    end

    local cache_dur = mp.get_property_number("demuxer-cache-duration", 0)
    local paused = mp.get_property_bool("pause", false)
    local cache_paused = mp.get_property_bool("paused-for-cache", false)

    -- If user intentionally paused playback, do nothing
    if paused then return end

    -- THE PLAYABLE CACHE RULE:
    -- If demuxer buffer has playable seconds (cache_dur >= 6.0s), NEVER downshift or interrupt playback!
    -- Play the already-cached high quality frames uninterrupted.
    if cache_dur >= 6.0 then
        starved_buffer_seconds = 0
        return
    end

    -- Genuine cache starvation tracking: demuxer buffer < 3.5s
    if cache_dur < 3.5 then
        starved_buffer_seconds = starved_buffer_seconds + 2
    else
        starved_buffer_seconds = math.max(0, starved_buffer_seconds - 2)
    end

    -- Downshift trigger conditions:
    -- 1. Hard stall: player paused specifically for cache starvation AND buffer < 1.0s
    -- 2. Sustained starvation: cache continuously under 3.5s for >= 6 seconds
    local should_downshift = false
    if cache_paused and cache_dur < 1.0 then
        should_downshift = true
    elseif starved_buffer_seconds >= 6 then
        should_downshift = true
    end

    if should_downshift and (now - last_adaptation_time > 25) then
        local next_tier = nil
        if current_tier == "auto" or current_tier == "max" or current_tier == "high" or current_tier == "4k" or current_tier == "1440" then
            next_tier = "mid"
        elseif current_tier == "mid" or current_tier == "1080" then
            next_tier = "low"
        elseif current_tier == "low" or current_tier == "720" then
            next_tier = "480"
        elseif current_tier == "480" then
            next_tier = "360"
        end

        if next_tier then
            last_adaptation_time = now
            has_downshifted_this_track = true
            starved_buffer_seconds = 0
            change_quality(next_tier, true)
        end
    end
end

local function on_cache_pause_change(name, is_paused)
    if not is_paused then return end
    evaluate_adaptive_bitrate()
end

-- =========================================================================
-- 4b. Smart Hardware Compatibility & Dynamic Lag Guard
-- Prevents GPU decoder bottlenecks, software-decode choking, and 8K frame lag
-- =========================================================================

local prev_dec_drops = 0
local prev_vo_drops = 0
local consecutive_lag_checks = 0
local last_lag_check_time = 0

local function check_hardware_lag()
    if is_audio_mode_active() then return end
    local idle = mp.get_property_bool("idle-active", false)
    local paused = mp.get_property_bool("pause", false)
    if idle or paused then return end

    local cur_time = mp.get_property_number("time-pos", nil)
    if not cur_time or cur_time < 3.0 then return end

    local path = mp.get_property("path", "")
    if not path or path == "" then return end
    local is_remote = (path:match("^https?://") ~= nil) or (path:match("^ytdl://") ~= nil)
    if not is_remote then return end

    local now = mp.get_time()
    if (now - track_start_time) < 4.0 then
        -- Initial grace period on track start / quality change
        prev_dec_drops = mp.get_property_number("decoder-frame-drop-count", 0)
        prev_vo_drops = mp.get_property_number("frame-drop-count", 0)
        last_lag_check_time = now
        return
    end

    if last_lag_check_time == 0 then
        last_lag_check_time = now
        prev_dec_drops = mp.get_property_number("decoder-frame-drop-count", 0)
        prev_vo_drops = mp.get_property_number("frame-drop-count", 0)
        return
    end

    local dt = now - last_lag_check_time
    if dt < 1.8 then return end

    local cur_dec_drops = mp.get_property_number("decoder-frame-drop-count", 0)
    local cur_vo_drops = mp.get_property_number("frame-drop-count", 0)
    local d_dec = math.max(0, cur_dec_drops - prev_dec_drops)
    local d_vo = math.max(0, cur_vo_drops - prev_vo_drops)
    prev_dec_drops = cur_dec_drops
    prev_vo_drops = cur_vo_drops
    last_lag_check_time = now

    local h = mp.get_property_number("video-params/h", 0)
    if h <= 720 then return end -- Don't downshift below low

    local total_drops = d_dec + d_vo
    -- Stutter threshold: > 10 dropped frames in ~2s (or massive drop burst >= 25)
    if total_drops >= 25 then
        consecutive_lag_checks = 2
    elseif total_drops >= 10 then
        consecutive_lag_checks = consecutive_lag_checks + 1
    else
        consecutive_lag_checks = math.max(0, consecutive_lag_checks - 1)
    end

    if consecutive_lag_checks >= 2 then
        consecutive_lag_checks = 0
        local next_ceiling = nil
        local banner = ""

        if h > 2160 then
            next_ceiling = "4k"
            banner = "⚡ Hardware Lag Guard: 8K exceeded GPU capability. Auto-adapted to 4K (60 FPS smooth)."
        elseif h > 1440 then
            next_ceiling = "high"
            banner = "⚡ Hardware Lag Guard: 4K caused frame drops. Auto-adapted to 1440p 2K (60 FPS smooth)."
        elseif h > 1080 then
            next_ceiling = "mid"
            banner = "⚡ Hardware Lag Guard: Auto-adapted to 1080p Full HD (60 FPS smooth)."
        elseif h > 720 then
            next_ceiling = "low"
            banner = "⚡ Hardware Lag Guard: Auto-adapted to 720p HD (60 FPS smooth)."
        end

        if next_ceiling then
            save_hw_ceiling(next_ceiling)
            mp.commandv("show-text", banner, 3500)
            change_quality(next_ceiling, true)
        end
    end
end

-- Periodic Adaptive Watcher & Position Cache
mp.add_periodic_timer(2.0, function()
    -- Maintain playback position cache
    local p = mp.get_property_number("playlist-pos", -1)
    local t = mp.get_property_number("time-pos", 0)
    local path = mp.get_property("path", "")
    if p >= 0 and t > 0 then
        last_valid_pos = p
        last_valid_time = t
        if path ~= "" then last_valid_url = path end
    end

    -- 1. Hardware Lag & Frame Drop Guard (Prevents device stutter)
    check_hardware_lag()

    -- 2. Evaluate adaptive bitrate with playable buffer protection
    evaluate_adaptive_bitrate()
end)

-- =========================================================================
-- 5. Anti-Suicide & Network Drop Recovery Guard
-- =========================================================================

local network_offline = false
local network_probe_timer = nil
local consecutive_net_errors = 0

local function check_internet_connectivity(cb)
    local is_win = (package.config:sub(1,1) == "\\") or (os.getenv("WINDIR") ~= nil)
    local ping_cmd = is_win and {"ping", "-n", "1", "-w", "1000", "1.1.1.1"} or {"ping", "-c", "1", "-W", "1", "1.1.1.1"}

    mp.command_native_async({
        name = "subprocess",
        args = ping_cmd,
        capture_stdout = false,
        capture_stderr = false
    }, function(success, res, err)
        if success and res and res.status == 0 then
            cb(true)
        else
            cb(false)
        end
    end)
end

local function trigger_network_offline_freeze(saved_pos, saved_time)
    if network_offline then return end
    network_offline = true

    mp.set_property_bool("pause", true)
    local track_num = (saved_pos and (saved_pos + 1)) or 1
    mp.commandv("show-text", "📶 Network Offline: Paused Queue at track #" .. track_num .. ". Waiting for internet...", 60000)

    if network_probe_timer then network_probe_timer:kill() end
    network_probe_timer = mp.add_periodic_timer(2.5, function()
        check_internet_connectivity(function(is_online)
            if is_online then
                -- Internet connection restored!
                if network_probe_timer then network_probe_timer:kill(); network_probe_timer = nil end
                network_offline = false
                consecutive_net_errors = 0
                mp.commandv("show-text", "✅ Internet Restored! Resuming track #" .. track_num .. "...", 3500)

                if saved_time and saved_time > 2.0 then
                    queue_resume_seek(saved_time)
                end
                if saved_pos and saved_pos >= 0 then
                    mp.commandv("playlist-play-index", saved_pos)
                end
                mp.set_property_bool("pause", false)
            else
                -- Still offline: keep informing the user without skipping tracks
                mp.commandv("show-text", "📶 Still offline: Queue waiting for internet connection...", 2200)
            end
        end)
    end)
end

local function on_file_end(event)
    if event.reason == "error" then
        local current_path = mp.get_property("path", "")
        if (not current_path or current_path == "") and last_valid_url ~= "" then
            current_path = last_valid_url
        end

        local is_remote = false
        if current_path then
            is_remote = (current_path:match("^https?://") ~= nil) or (current_path:match("^ytdl://") ~= nil)
        end

        if is_remote then
            consecutive_net_errors = consecutive_net_errors + 1
            mp.set_property_bool("pause", true)

            check_internet_connectivity(function(is_online)
                if is_online then
                    -- Internet is working, but this specific URL failed (e.g. copyright / dead video)
                    if consecutive_net_errors < 3 then
                        mp.commandv("show-text", "⚠️ Stream unavailable (deleted or restricted). Moving to next...", 3000)
                        mp.set_property_bool("pause", false)
                        smart_next(true)
                    else
                        mp.commandv("show-text", "⚠️ Multiple tracks unplayable. Pausing Queue.", 5000)
                    end
                else
                    -- Complete internet drop! Freeze queue immediately and wait for connection!
                    trigger_network_offline_freeze(last_valid_pos, last_valid_time)
                end
            end)
            return
        end
    end

    if event.reason ~= "eof" then return end
    local lf = mp.get_property("loop-file", "no")
    if lf ~= "no" and lf ~= "false" then return end
    consecutive_net_errors = 0
    smart_next(true)
end

-- =========================================================================
-- Persistent Session State Engine (Preserves track & playlist on [X] / exit)
-- =========================================================================

local function get_saved_pos()
    local cache_dir = home ~= "" and (home .. "/.cache/mpv") or nil
    if not cache_dir then return -1 end
    local f = io.open(cache_dir .. "/state.json", "r")
    if not f then return -1 end
    local content = f:read("*a")
    f:close()
    if content and content ~= "" then
        local u = require("mp.utils")
        local parsed = u.parse_json(content)
        if parsed and parsed.pos and type(parsed.pos) == "number" and parsed.pos >= 0 then
            return math.floor(parsed.pos)
        end
    end
    return -1
end

local target_restore_pos = get_saved_pos()
local has_restored_session = (target_restore_pos <= 0)

local function save_session_state()
    if not has_restored_session then return end
    local cache_dir = home ~= "" and (home .. "/.cache/mpv") or nil
    if not cache_dir then return end

    -- 1. Determine active playlist position
    local pos = mp.get_property_number("playlist-pos", -1)
    if pos < 0 and last_valid_pos and last_valid_pos >= 0 then
        pos = last_valid_pos
    end
    if pos < 0 then pos = 0 end

    -- 2. State properties
    local shuffle = mp.get_property_bool("shuffle", false)
    local loop_f = mp.get_property("loop-file", "no")
    local loop_p = mp.get_property("loop-playlist", "no")

    local u = require("mp.utils")
    local state_data = {
        shuffle = shuffle,
        loop_file = loop_f,
        loop_playlist = loop_p,
        pos = pos
    }
    local state_json = u.format_json(state_data)
    if state_json then
        local sf = io.open(cache_dir .. "/state.json", "w")
        if sf then
            sf:write(state_json .. "\n")
            sf:close()
        end
    end

    -- 3. Save playlist items
    local pl = mp.get_property_native("playlist")
    if pl and type(pl) == "table" and #pl > 0 then
        local pf = io.open(cache_dir .. "/last_playlist.txt", "w")
        if pf then
            for _, item in ipairs(pl) do
                if item and item.filename and item.filename ~= "" then
                    pf:write(item.filename .. "\n")
                end
            end
            pf:close()
        end
    end
end

-- =========================================================================
-- 6. Event Registrations & Script Messages
-- =========================================================================

local function on_file_loaded()
    mp.set_property("start", "none")
    if pending_resume_pos and pending_resume_pos > 1.0 then
        local p = pending_resume_pos
        queue_resume_seek(p)
    end
    prev_dec_drops = 0
    prev_vo_drops = 0
    consecutive_lag_checks = 0
    last_lag_check_time = 0
    track_start_time = mp.get_time()
    save_session_state()
    local path = mp.get_property("path", "")
    local saved_sp = get_saved_speed()
    if saved_sp and saved_sp ~= 1.0 then
        mp.set_property_number("speed", saved_sp)
        pcall(mp.set_property, "user-data/queue-speed", string.format("%.2f", saved_sp))
    end
    if is_audio_mode_active() then
        mp.set_property("vid", "no")
        mp.set_property("video", "no")
        mp.set_property("force-window", "no")
        mp.set_property_bool("window-minimized", true)
        local fmt = get_quality_format("audio", current_lang)
        mp.set_property("ytdl-format", fmt)
    else
        if path and path ~= "" then
            local is_remote = (path:match("^https?://") ~= nil) or (path:match("^ytdl://") ~= nil)
            if is_remote and is_auto_mode then
                current_tier = "auto"
                has_downshifted_this_track = false
                starved_buffer_seconds = 0
                recent_stalls = {}
                track_start_time = mp.get_time()
                local fmt = get_quality_format("auto", current_lang)
                mp.set_property("ytdl-format", fmt)
            end
        end
    end
    if path and path ~= "" then
        fetch_stream_languages_async(path)
    end
end

mp.register_event("end-file", on_file_end)
mp.register_event("file-loaded", on_file_loaded)
mp.register_event("playback-restart", do_resume_seek)
mp.observe_property("playlist-count", "number", function(name, count)
    if count and count > 0 and not has_restored_session and target_restore_pos > 0 then
        if target_restore_pos < count then
            mp.commandv("playlist-play-index", target_restore_pos)
        end
        has_restored_session = true
    end
end)
mp.observe_property("playlist-pos", "number", function(name, val)
    if val and val >= 0 then
        if not has_restored_session then
            if target_restore_pos > 0 and val == target_restore_pos then
                has_restored_session = true
            elseif target_restore_pos <= 0 then
                has_restored_session = true
            end
        end
        last_valid_pos = val
        save_session_state()
    end
end)
mp.observe_property("shuffle", "bool", on_shuffle_change)
mp.observe_property("window-minimized", "bool", update_state)
mp.observe_property("vo", "string", update_state)
mp.observe_property("vid", "string", update_state)
mp.observe_property("paused-for-cache", "bool", on_cache_pause_change)

-- Script Messages
mp.register_script_message("set-audio-mode", function(val)
    local enabled = (val == "true" or val == "1" or val == "on" or val == "yes")
    save_audio_mode(enabled)
    if enabled then
        mp.set_property("vid", "no")
        mp.set_property("video", "no")
        mp.set_property("force-window", "no")
        mp.set_property_bool("window-minimized", true)
        if state_file then pcall(os.remove, state_file) end
        local fmt = get_quality_format("audio", current_lang)
        mp.set_property("ytdl-format", fmt)
    else
        mp.set_property("vid", "auto")
        mp.set_property("video", "auto")
        local fmt = get_quality_format(current_tier, current_lang)
        mp.set_property("ytdl-format", fmt)
    end
end)
mp.register_script_message("arm-resume-seek", function(pos)
    arm_resume_seek(tonumber(pos))
end)
mp.register_script_message("safe-hide-video", safe_hide)
mp.register_script_message("safe-show-video", safe_show)
mp.register_script_message("change-quality", function(target) change_quality(target, false) end)
mp.register_script_message("change-resolution", change_resolution)
mp.register_script_message("change-language", function(target) change_language(target) end)
mp.register_script_message("cycle-language", cycle_audio_language)
mp.register_script_message("smart-next", function() smart_next(false) end)
mp.register_script_message("smart-prev", smart_prev)
mp.register_script_message("set-speed", function(val) set_playback_speed(tonumber(val)) end)
mp.register_script_message("adjust-speed", function(delta) adjust_playback_speed(tonumber(delta)) end)
mp.register_script_message("reset-speed", function() set_playback_speed(1.0) end)

-- Smart Navigation Keybindings
mp.add_key_binding(">", "smart_next_key", function() smart_next(false) end)
mp.add_key_binding("ENTER", "smart_next_enter", function() smart_next(false) end)
mp.add_key_binding("<", "smart_prev_key", smart_prev)

-- Audio Language & Track Keybindings (YouTube Multi-Dub & Multi-Track)
mp.add_key_binding("a", "cycle_audio_a", cycle_audio_language)
mp.add_key_binding("A", "cycle_audio_A", cycle_audio_language)
mp.add_key_binding("#", "cycle_audio_hash", cycle_audio_language)

-- Fullscreen Hotkeys (F11, f, ESC)
mp.add_key_binding("F11", "toggle_fullscreen_f11", function()
    mp.commandv("cycle", "fullscreen")
end)
mp.add_key_binding("f", "toggle_fullscreen_f", function()
    mp.commandv("cycle", "fullscreen")
end)
mp.add_key_binding("ESC", "exit_fullscreen_esc", function()
    mp.set_property_bool("fullscreen", false)
end)

-- In-Window Window Scale Hotkeys (w/W presets, +/- 5% steps)
local function adjust_scale(delta)
    local cur = mp.get_property_number("window-scale", 1.0)
    local target = math.max(0.1, math.min(2.5, cur + delta))
    mp.set_property_number("window-scale", target)
    mp.commandv("show-text", string.format("Window Scale: %.2f", target), 1500)
end

mp.add_key_binding("w", "scale_cycle_w", function()
    mp.commandv("cycle_values", "window-scale", "0.35", "0.5", "0.75", "1.0")
    local scale = mp.get_property("window-scale") or ""
    mp.commandv("show-text", "Window Scale: " .. scale, 1500)
end)
mp.add_key_binding("W", "scale_cycle_W", function()
    mp.commandv("cycle_values", "window-scale", "1.0", "0.75", "0.5", "0.35")
    local scale = mp.get_property("window-scale") or ""
    mp.commandv("show-text", "Window Scale: " .. scale, 1500)
end)
mp.add_key_binding("+", "scale_add_plus", function() adjust_scale(0.05) end)
mp.add_key_binding("=", "scale_add_equal", function() adjust_scale(0.05) end)
mp.add_key_binding("-", "scale_sub_minus", function() adjust_scale(-0.05) end)
mp.add_key_binding("_", "scale_sub_underscore", function() adjust_scale(-0.05) end)

-- Window Close & Session Exit Hotkeys (Cross button [X], Alt+F4, q, Q quits session)
local function stop_session()
    has_restored_session = true
    save_session_state()
    if state_file then pcall(os.remove, state_file) end
    mp.commandv("quit")
end

mp.register_script_message("stop-session", stop_session)
mp.register_event("shutdown", function()
    has_restored_session = true
    save_session_state()
    if state_file then pcall(os.remove, state_file) end
end)

mp.add_forced_key_binding("CLOSE_WIN", "stop_close_win", stop_session)
mp.add_forced_key_binding("Alt+F4", "stop_altf4", stop_session)
mp.add_forced_key_binding("q", "stop_q", stop_session)
mp.add_forced_key_binding("Q", "stop_Q", stop_session)
mp.add_forced_key_binding("Ctrl+w", "stop_ctrlw", stop_session)
mp.add_forced_key_binding("Ctrl+W", "stop_ctrlW", stop_session)
mp.add_forced_key_binding("Meta+w", "stop_metaw", stop_session)
mp.add_forced_key_binding("Meta+W", "stop_metaW", stop_session)
mp.add_forced_key_binding("Meta+q", "stop_metaq", stop_session)
mp.add_forced_key_binding("Meta+Q", "stop_metaQ", stop_session)

-- Hide Video Window to Background Audio Hotkeys (h / H)
mp.add_forced_key_binding("h", "safe_hide_h", safe_hide)
mp.add_forced_key_binding("H", "safe_hide_H", safe_hide)

-- In-Window Quality Hotkeys (Forced overrides for number row, numpad, and Ctrl+Num)
mp.add_forced_key_binding("0", "quality_0", function() change_quality("auto", false) end)
mp.add_forced_key_binding("1", "quality_1", function() change_quality("low", false) end)
mp.add_forced_key_binding("2", "quality_2", function() change_quality("mid", false) end)
mp.add_forced_key_binding("3", "quality_3", function() change_quality("high", false) end)
mp.add_forced_key_binding("4", "quality_4", function() change_quality("max", false) end)

mp.add_forced_key_binding("KP0", "quality_kp0", function() change_quality("auto", false) end)
mp.add_forced_key_binding("KP1", "quality_kp1", function() change_quality("low", false) end)
mp.add_forced_key_binding("KP2", "quality_kp2", function() change_quality("mid", false) end)
mp.add_forced_key_binding("KP3", "quality_kp3", function() change_quality("high", false) end)
mp.add_forced_key_binding("KP4", "quality_kp4", function() change_quality("max", false) end)

mp.add_forced_key_binding("Ctrl+0", "quality_ctrl0", function() change_quality("auto", false) end)
mp.add_forced_key_binding("Ctrl+1", "quality_ctrl1", function() change_quality("low", false) end)
mp.add_forced_key_binding("Ctrl+2", "quality_ctrl2", function() change_quality("mid", false) end)
mp.add_forced_key_binding("Ctrl+3", "quality_ctrl3", function() change_quality("high", false) end)
mp.add_forced_key_binding("Ctrl+4", "quality_ctrl4", function() change_quality("max", false) end)

mp.add_forced_key_binding("F1", "quality_f1", function() change_quality("auto", false) end)
mp.add_forced_key_binding("F2", "quality_f2", function() change_quality("low", false) end)
mp.add_forced_key_binding("F3", "quality_f3", function() change_quality("mid", false) end)
mp.add_forced_key_binding("F4", "quality_f4", function() change_quality("high", false) end)
mp.add_forced_key_binding("F5", "quality_f5", function() change_quality("max", false) end)

-- In-Window Playback Speed Hotkeys ([, ], {, }, Backspace, Alt+0)
mp.add_forced_key_binding("[", "speed_down_bracket", function() adjust_playback_speed(-0.1) end)
mp.add_forced_key_binding("]", "speed_up_bracket", function() adjust_playback_speed(0.1) end)
mp.add_forced_key_binding("{", "speed_down_brace", function() adjust_playback_speed(-0.25) end)
mp.add_forced_key_binding("}", "speed_up_brace", function() adjust_playback_speed(0.25) end)
mp.add_forced_key_binding("BS", "speed_reset_bs", function() set_playback_speed(1.0) end)
mp.add_forced_key_binding("Alt+0", "speed_reset_alt0", function() set_playback_speed(1.0) end)
