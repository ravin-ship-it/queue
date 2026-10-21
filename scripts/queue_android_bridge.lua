-- queue_android_bridge.lua: Inter-Process Command Relay between Termux Queue & MPV Android
-- Facilitates dynamic live queue additions, track jumps, next/previous skips, shuffle, and synchronization.

math.randomseed(os.time())
math.random(); math.random(); math.random()

local cmd_file = "/sdcard/mpv/queue_cmd.txt"
local alt_cmd_file = "/storage/emulated/0/mpv/queue_cmd.txt"

local function check_and_execute_cmd()
    local path = cmd_file
    local f = io.open(path, "r")
    if not f then
        path = alt_cmd_file
        f = io.open(path, "r")
    end
    if not f then return end

    local content = f:read("*all")
    f:close()
    os.remove(path)

    if not content or content == "" then return end

    for line in content:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            local parts = {}
            for part in line:gmatch("%S+") do
                table.insert(parts, part)
            end
            if #parts > 0 then
                local cmd = parts[1]
                if cmd == "loadfile" and #parts >= 2 then
                    local url = parts[2]
                    local mode = parts[3] or "append"
                    mp.commandv("loadfile", url, mode)
                elseif cmd == "loadlist" and #parts >= 2 then
                    local url = parts[2]
                    local mode = parts[3] or "replace"
                    mp.commandv("loadlist", url, mode)
                elseif cmd == "playlist-play-index" and #parts >= 2 then
                    local idx = tonumber(parts[2])
                    if idx then
                        mp.commandv("playlist-play-index", idx)
                    end
                elseif cmd == "playlist-next" then
                    mp.commandv("playlist-next")
                elseif cmd == "playlist-prev" then
                    mp.commandv("playlist-prev")
                elseif cmd == "playlist-clear" then
                    mp.commandv("playlist-clear")
                elseif cmd == "pause" then
                    mp.set_property_bool("pause", true)
                elseif cmd == "play" or cmd == "unpause" then
                    mp.set_property_bool("pause", false)
                elseif cmd == "shuffle" and #parts >= 2 then
                    mp.set_property_bool("shuffle", parts[2] == "true")
                elseif cmd == "seek" and #parts >= 2 then
                    local target = tonumber(parts[2])
                    if target then
                        mp.commandv("seek", target, parts[3] or "absolute")
                    end
                elseif cmd == "speed" and #parts >= 2 then
                    local target = tonumber(parts[2])
                    if target then
                        mp.set_property_number("speed", target)
                        mp.commandv("show-text", string.format("⚡ Speed: %.2fx", target), 1500)
                    end
                end
            end
        end
    end
end

-- Natural EOF & Network Failure Protection for Android MPV
local function on_android_file_end(event)
    if event.reason == "error" then
        -- Freeze playback on network/stream errors to prevent rapid skipping suicide
        mp.set_property_bool("pause", true)
        mp.commandv("show-text", "⚠️ Stream Error / Network Issue: Playback paused to prevent track skipping.", 5000)
        return
    end

    if event.reason ~= "eof" then return end
    local lf = mp.get_property("loop-file", "no")
    if lf ~= "no" and lf ~= "false" then return end
    local shuf = mp.get_property_bool("shuffle", false)
    if not shuf then return end
    local count = mp.get_property_number("playlist-count", 0)
    if count <= 1 then return end
    local pos = mp.get_property_number("playlist-pos", -1)
    local rand_idx = pos
    for _ = 1, 30 do
        local r = math.random(0, count - 1)
        if r ~= pos then
            rand_idx = r
            break
        end
    end
    mp.commandv("playlist-play-index", rand_idx)
end

-- Check for incoming commands every 250ms (ultra-low CPU overhead)
mp.add_periodic_timer(0.25, check_and_execute_cmd)
mp.register_event("end-file", on_android_file_end)
