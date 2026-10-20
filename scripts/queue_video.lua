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
        return "(bestaudio[acodec=opus]/bestaudio)"
    end
    return string.format("(bestaudio[language=%s][acodec=opus]/bestaudio[language^=%s][acodec=opus]/bestaudio[language=%s]/bestaudio[language^=%s]/bestaudio[acodec=opus]/bestaudio)", lang, lang, lang, lang)
end

local function get_quality_format(tier, lang)
    tier = (tier or "auto"):lower()
    local audio_fmt = get_audio_format(lang)
    if tier == "auto" then
        return "bestvideo[height<=1080][fps<=60][vcodec^=avc1][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=1080][fps<=60][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=720]+" .. audio_fmt .. "/best"
    elseif tier == "720" then
        return "bestvideo[height<=720][fps>=50][vcodec^=avc1][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=720][fps>=50][vcodec^=vp9][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=720]+" .. audio_fmt .. "/best[height<=720]"
    elseif tier == "1080" then
        return "bestvideo[height<=1080][fps>=50][vcodec^=avc1][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=1080][fps>=50][vcodec^=vp9][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=1080]+" .. audio_fmt .. "/best[height<=1080]"
    elseif tier == "1440" then
        return "bestvideo[height<=1440][fps>=50][vcodec^=avc1][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=1440][fps>=50][vcodec^=vp9][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[height<=1440]+" .. audio_fmt .. "/best[height<=1440]"
    elseif tier == "4k" then
        return "bestvideo[fps>=50][vcodec^=avc1][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo[fps>=50][vcodec^=vp9][format_note!*=Premium]+" .. audio_fmt .. "/bestvideo+" .. audio_fmt .. "/best"
    elseif tier == "480" then
        return "bestvideo[height<=480]+" .. audio_fmt .. "/best[height<=480]"
    elseif tier == "360" then
        return "bestvideo[height<=360]+" .. audio_fmt .. "/best[height<=360]"
    else
        return "bestvideo[height<=1080]+" .. audio_fmt .. "/best"
    end
end

local QUALITY_PROFILES = {
    ["auto"] = { label = "Auto / Smart 60FPS (Adapts to internet)" },
    ["720"] = { label = "720p HD (60fps fluid / bandwidth saver)" },
    ["1080"] = { label = "1080p Full HD (60fps crisp)" },
    ["1440"] = { label = "1440p 2K QHD (60fps ultra-crisp)" },
    ["4k"] = { label = "Max / 4K UHD (Uncapped highest quality)" },
    ["480"] = { label = "480p SD (Low-bandwidth smooth)" },
    ["360"] = { label = "360p Low (Emergency smooth)" }
}

local pending_resume_pos = nil
local resume_timer = nil
local is_auto_mode = true
local current_tier = "1080"
local recent_stalls = {}
local last_adaptation_time = 0
local stable_buffer_seconds = 0

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

    if seekable or (cur_time and cur_time >= 0) then
        pending_resume_pos = nil
        if resume_timer then resume_timer:kill(); resume_timer = nil end
        mp.commandv("seek", pos, "absolute")
    end
end

local function queue_resume_seek(pos)
    if not pos or pos <= 1.0 then return end
    pending_resume_pos = pos
    if resume_timer then resume_timer:kill() end

    local attempts = 0
    resume_timer = mp.add_periodic_timer(0.12, function()
        attempts = attempts + 1
        if not pending_resume_pos or attempts > 35 then
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
    if target == "hd" then target = "720" end
    if target == "fhd" then target = "1080" end
    if target == "2k" or target == "qhd" then target = "1440" end
    if target == "uhd" or target == "max" then target = "4k" end

    local profile = QUALITY_PROFILES[target]
    if not profile then
        profile = QUALITY_PROFILES["auto"]
        target = "auto"
    end

    if not is_auto_adaptive then
        is_auto_mode = (target == "auto")
        if not is_auto_mode then
            current_tier = target
        else
            current_tier = "1080"
        end
        recent_stalls = {}
        stable_buffer_seconds = 0
    end

    -- Capture current timestamp and schedule seamless seek on reload
    local cur_time = mp.get_property_number("time-pos")
    if (not cur_time or cur_time < 1.0) and last_valid_time > 1.0 then
        cur_time = last_valid_time
    end
    if cur_time and cur_time > 1.0 then
        queue_resume_seek(cur_time)
    end

    local fmt = get_quality_format(target, current_lang)
    mp.set_property("ytdl-format", fmt)
    local cur_path = mp.get_property("path", "")
    if cur_path and cur_path ~= "" and (cur_path:match("^https?://") or cur_path:match("^ytdl://")) then
        local start_sec = math.max(0, math.floor(cur_time or 0))
        mp.commandv("loadfile", cur_path, "replace", "-1", "start=" .. tostring(start_sec))
    else
        mp.commandv("playlist-play-index", "current")
    end

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
        queue_resume_seek(cur_time)
    end

    mp.set_property("ytdl-format", fmt)
    local cur_path = mp.get_property("path", "")
    if cur_path and cur_path ~= "" and (cur_path:match("^https?://") or cur_path:match("^ytdl://")) then
        local start_sec = math.max(0, math.floor(cur_time or 0))
        mp.commandv("loadfile", cur_path, "replace", "-1", "start=" .. tostring(start_sec))
    else
        mp.commandv("playlist-play-index", "current")
    end
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
        queue_resume_seek(cur_time)
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

    -- 2. Remote / YouTube DASH stream reload (preserve exact position)
    local fmt = get_quality_format(current_tier, current_lang)
    mp.set_property("ytdl-format", fmt)
    local cur_path = mp.get_property("path", "")
    if cur_path and cur_path ~= "" and (cur_path:match("^https?://") or cur_path:match("^ytdl://")) then
        local start_sec = math.max(0, math.floor(cur_time or 0))
        mp.commandv("loadfile", cur_path, "replace", "-1", "start=" .. tostring(start_sec))
    else
        mp.commandv("playlist-play-index", "current")
    end

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

local function on_cache_pause_change(name, is_paused)
    if not is_paused then return end
    if not is_auto_mode then return end

    local now = mp.get_time()
    if now - last_adaptation_time < 20 then return end -- cooldown period

    table.insert(recent_stalls, now)
    -- Prune stalls older than 45 seconds
    local filtered = {}
    for _, t in ipairs(recent_stalls) do
        if now - t <= 45 then
            table.insert(filtered, t)
        end
    end
    recent_stalls = filtered

    local cache_dur = mp.get_property_number("demuxer-cache-duration", 0)
    if #recent_stalls >= 1 and cache_dur < 1.5 then
        -- Step down the resolution ladder
        local next_tier = nil
        if current_tier == "4k" or current_tier == "1440" then
            next_tier = "1080"
        elseif current_tier == "1080" then
            next_tier = "720"
        elseif current_tier == "720" then
            next_tier = "480"
        elseif current_tier == "480" then
            next_tier = "360"
        end

        if next_tier then
            last_adaptation_time = now
            current_tier = next_tier
            recent_stalls = {}
            stable_buffer_seconds = 0
            change_quality(next_tier, true)
        end
    end
end

-- Periodic Adaptive Recovery Watcher (upshifts when network stabilizes)
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

    if not is_auto_mode then return end
    if current_tier == "1080" or current_tier == "1440" or current_tier == "4k" then
        return
    end

    local cache_dur = mp.get_property_number("demuxer-cache-duration", 0)
    local paused = mp.get_property_bool("pause", false)
    local cache_paused = mp.get_property_bool("paused-for-cache", false)

    if not paused and not cache_paused and cache_dur >= 30.0 then
        stable_buffer_seconds = stable_buffer_seconds + 2
    else
        stable_buffer_seconds = math.max(0, stable_buffer_seconds - 3)
    end

    -- If connection stayed rock-solid for 80 seconds, step up
    local now = mp.get_time()
    if stable_buffer_seconds >= 80 and (now - last_adaptation_time > 60) then
        local up_tier = nil
        if current_tier == "360" then
            up_tier = "480"
        elseif current_tier == "480" then
            up_tier = "720"
        elseif current_tier == "720" then
            up_tier = "1080"
        end

        if up_tier then
            last_adaptation_time = now
            current_tier = up_tier
            stable_buffer_seconds = 0
            recent_stalls = {}
            local profile = QUALITY_PROFILES[up_tier]
            mp.commandv("show-text", "⚡ Auto Quality: Network stabilized -> " .. profile.label, 3000)
            change_quality(up_tier, true)
        end
    end
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
-- 6. Event Registrations & Script Messages
-- =========================================================================

local function on_file_loaded()
    do_resume_seek()
    local path = mp.get_property("path", "")
    if path and path ~= "" then
        fetch_stream_languages_async(path)
    end
end

mp.register_event("end-file", on_file_end)
mp.register_event("file-loaded", on_file_loaded)
mp.register_event("playback-restart", do_resume_seek)
mp.observe_property("shuffle", "bool", on_shuffle_change)
mp.observe_property("window-minimized", "bool", update_state)
mp.observe_property("vo", "string", update_state)
mp.observe_property("vid", "string", update_state)
mp.observe_property("paused-for-cache", "bool", on_cache_pause_change)

-- Script Messages
mp.register_script_message("safe-hide-video", safe_hide)
mp.register_script_message("safe-show-video", safe_show)
mp.register_script_message("change-quality", function(target) change_quality(target, false) end)
mp.register_script_message("change-resolution", change_resolution)
mp.register_script_message("change-language", function(target) change_language(target) end)
mp.register_script_message("cycle-language", cycle_audio_language)
mp.register_script_message("smart-next", function() smart_next(false) end)
mp.register_script_message("smart-prev", smart_prev)

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

-- In-Window Quality Hotkeys (Seamless position memory & smart adaptive)
mp.add_key_binding("0", "quality_0", function() change_quality("auto", false) end)
mp.add_key_binding("1", "quality_1", function() change_quality("720", false) end)
mp.add_key_binding("2", "quality_2", function() change_quality("1080", false) end)
mp.add_key_binding("3", "quality_3", function() change_quality("1440", false) end)
mp.add_key_binding("4", "quality_4", function() change_quality("4k", false) end)
