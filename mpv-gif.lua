-- Create animated GIFs with mpv
-- Requires ffmpeg.
-- Adapted from http://blog.pkh.me/p/21-high-quality-gif-with-ffmpeg.html
-- Usage: "g" to set start frame, "G" to set end frame, "Ctrl+g" to create.
local msg = require 'mp.msg'
local utils = require 'mp.utils'
mp.options = require 'mp.options'
local IS_WINDOWS = package.config:sub(1, 1) ~= "/"

-- options
-- require 'mp.options'
local options = {
    fps = 15,
    width = 600,
    height = -1,
    extension = "gif", -- file extension by default
    outputDirectory = "~/mpv-gifs", -- save to home directory by default
    flags = "lanczos", -- or "spline"
    customFilters = "",
    key = "g", -- Default key. It will be used as "g": start, "G": end, "Ctrl+g" create non-sub, "Ctrl+G": create sub.
    ffmpegCmd = "ffmpeg",
    ytdlpCmd = "yt-dlp",
    debug = false, -- for debug
}

mp.options.read_options(options, "gifgen")

if options.customFilters == nil or options.customFilters == "" then
    -- Set this to the filters to pass into ffmpeg's -vf option.
    -- filters="fps=24,scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=320:-1:flags=lanczos"
    filters = options.fps < 0 and "" or string.format("fps=%d,", options.fps)
    filters = filters .. string.format(
        "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=%d:%d:flags=%s",
        options.width, options.height, options.flags
    )
else
    filters = string.format(
        options.customFilters,
        options.width, options.height, options.flags
    )
end

log_verbose = options.debug and function (...)
    msg.info(...)
end or function (...) end

-- Debug only - Get printable strings for tables
function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end

function win_dir_esc(s)
    -- To create a dir using mkdir in cmd path requires to use backslash
    return string.gsub(s, [[/]], [[\]])
end

-- shell escape
function esc(s)
    -- Copied function. Probably not needed
    return string.gsub(s, '"', '"\\""')
end

function ffmpeg_esc(s)
    -- escape string to be used in ffmpeg arguments (i.e. filenames in filter)
    -- s = string.gsub(s, "/", IS_WINDOWS and "\\" or "/" ) -- Windows seems to work fine with forward slash '/'
    s = string.gsub(s, [[\]], [[/]])
    s = string.gsub(s, '"', '"\\""')
    -- s = string.gsub(s, ":", "\\:") -- Is this needed?
    s = string.gsub(s, "'", "\\'")
    return s
end

function clean_string(s)
    -- Remove problematic chars from strings
    return string.gsub(s, "[\\/|?*%[%]\"\'>< ]", [[_]])
end

-- expand given path (i.e. ~/, ~~/, …)
local res, err = mp.command_native({ "expand-path", options.outputDirectory })
options.outputDirectory = ffmpeg_esc(res)
res, err = mp.command_native({ "expand-path", options.ytdlpCmd })
options.ytdlpCmd = ffmpeg_esc(res)
res, err = mp.command_native({ "expand-path", options.ffmpegCmd })
options.ffmpegCmd = ffmpeg_esc(res)

log_verbose("[OPTIONS]:", utils.to_string(options))

start_time = -1
end_time = -1
temp_location = IS_WINDOWS and ffmpeg_esc(os.getenv("TEMP")) or "/tmp"
palette = temp_location .. "/mpv-gif-gen_palette.png"
segment_base = "mpv-gif-gen_segment"
segment = segment_base .. ".%(ext)s"

function make_gif_with_subtitles()
    if is_local_file() then
        msg.info('LOCAL FILE')
        make_gif_internal(true, start_time, end_time, get_path())
    else
        download_video_segment(start_time, end_time)
        msg.info('URL FILE')
    end
end

function make_gif()
    if is_local_file() then
        make_gif_internal(false, start_time, end_time, get_path())
    else
        download_video_segment(start_time, end_time)
    end
end

function is_local_file()
    -- Pathname for urls will be the url itself
    local pathname = mp.get_property("path", "")
    return string.find(pathname, "^https?://") == nil
end

function download_video_segment(start_time_l, end_time_l)
    if start_time_l == -1 or end_time_l == -1 or start_time_l >= end_time_l then
        mp.osd_message("Invalid start/end time.")
        return
    end

    mp.osd_message('Start video segment download')

    local url = mp.get_property("path", "")

    local args_ytdlp = {
        options.ytdlpCmd,
        "-v", -- For debug
        "--download-sections", "*" .. start_time_l .. "-" .. end_time_l, -- Specify download segment
        "--force-keyframes-at-cuts", -- Force cut at specify segment
        "-S", "proto:https", -- Avoid hls m3u8 for ffmpeg bug (https://github.com/yt-dlp/yt-dlp/issues/7824)
        "--path", temp_location, -- Path to download video
        "--output", segment, -- Name of the out file
        "--force-overwrites", -- Always overwrite previous file with same name in tmp dir
        "-f", "mp4",
        -- "--remux-video", "mp4", -- Force always getting a mp4
        url,
    }

    log_verbose("[ARGS] yt-dlp:", dump(args_ytdlp))

    local ytdlp_cmd = {
        name = "subprocess",
        args = args_ytdlp,
        capture_stdout = true,
        capture_stderr = true
    }


    -- Download video segment
    mp.command_native_async(ytdlp_cmd, function(res, val, err)
        if log_command_result("yt-dlp", res, val, err) ~= 0 then
            return
        end

        local segment_file = temp_location .. "/" .. segment_base .. ".mp4"
        local message = "Video segment downloaded: " .. segment_file
        msg.info(message)
        mp.osd_message(message)
        make_gif_internal(false, 0, end_time_l - start_time_l, segment_file)
        -- msg.info(dump(res))
    end)
end

function get_path()
    local is_absolute = nil
    local pathname = mp.get_property("path", "")
    pathname = ffmpeg_esc(pathname)

    if IS_WINDOWS then
        is_absolute = string.find(pathname, "^[a-zA-Z]:[/\\]") ~= nil
    else
        is_absolute = string.find(pathname, "^/") ~= nil
    end

    pathname = is_absolute and pathname or utils.join_path(
        mp.get_property("working-directory", ""),
        pathname
    )

    return ffmpeg_esc(pathname)
end

function get_gifname()
    -- then, make the gif
    local filename = is_local_file() and mp.get_property("filename/no-ext") or mp.get_property("media-title", mp.get_property("filename/no-ext"))
    local file_path = options.outputDirectory .. "/" .. clean_string(filename)

    -- increment filename
    for i = 0,999 do
        local fn = string.format('%s_%03d.%s', file_path, i, options.extension)
        if not file_exists(fn) then
            gifname = fn
            break
        end
    end

    if not gifname then
        msg.warning("No available filename")
        mp.osd_message('No available filenames!')
        return nil
    end

    return gifname
end

function log_command_result(command, res, val, err)
    log_verbose("[RES] " .. command .. " :", res)

    if val ~= nil then
        log_verbose("[VAL]:", dump(val))
    end

    if err ~= nil then
        log_verbose("[ERR]:", dump(err))
    end

    if not (res and (val == nil or val["status"] == 0)) then
        if val ~= nil and val["stderr"] then
            if mp.get_property("options/terminal") == "no" then
                file = io.open(string.format(temp_location .. "/mpv-gif-ffmpeg.%s.log", os.time()), "w")
                file:write(string.format("ffmpeg error %d:\n%s", val["status"], val["stderr"]))
                file:close()
            else
                msg.error(val["stderr"])
            end
        else
            if mp.get_property("options/terminal") == "no" then
                file = io.open(string.format(temp_location .. "/mpv-gif-ffmpeg.%s.log", os.time()), "w")
                file:write(string.format("ffmpeg error:\n%s", err))
                file:close()
            else
                msg.error("Error msg: " .. err)
            end
        end

        msg.error("GIF generation was unsuccessful")
        mp.osd_message("error creating GIF")
        return -1
    end

    return 0
end

function get_tracks()
    -- retrieve information about currently selected tracks
    local tracks, err = utils.parse_json(mp.get_property("track-list"))
    if tracks == nil then
        msg.warning("Couldn't parse track-list")
        return
    end

    local video = nil
    local has_sub = false
    local sub = nil

    for _, track in ipairs(tracks) do
        has_sub = has_sub or track["type"] == "sub"

        if track["selected"] == true then
            if track["type"] == "video" then
                video = {id=track["id"]}
            elseif track["type"] == "sub" then
                sub = {id=track["id"], codec=track["codec"]}
            end

        end
    end

    return video, sub, has_sub
end

function make_gif_internal(burn_subtitles, start_time_l, end_time_l, pathname)
    if start_time_l == -1 or end_time_l == -1 or start_time_l >= end_time_l then
        mp.osd_message("Invalid start/end time.")
        return
    end

    local sel_video, sel_sub, has_sub = get_tracks()

    if sel_video == nil then
        mp.osd_message("GIF abort: no video")
        msg.info("No video selected")
        return
    end

    msg.info("Creating GIF" .. (burn_subtitles and " (with subtitles)" or ""))
    mp.osd_message("Creating GIF" .. (burn_subtitles and " (with subtitles)" or ""))

    subtitle_filter = ""
    -- add subtitles only for final rendering as it slows down significantly
    if burn_subtitles and has_sub then
        -- TODO: implement usage of different subtitle formats (i.e. bitmap ones, …)
        sid = (sel_sub == nil and 0 or sel_sub["id"] - 1)  -- mpv starts counting subtitles with one
        subtitle_filter = string.format(",subtitles='%s':si=%d", pathname, sid)
    elseif burn_subtitles then
        msg.info("There are no subtitle tracks")
        mp.osd_message("GIF: ignoring subtitle request")
    end

    local position = start_time_l
    local duration = end_time_l - start_time_l

    -- Prepare out directory and file name
    ensure_out_dir(ffmpeg_esc(options.outputDirectory))
    local gifname = get_gifname()
    if gifname == nil then
        return
    end

    -- set arguments
    v_track = string.format("[0:v:%d] ", sel_video["id"] - 1)
    local filter_pal = v_track .. filters .. ",palettegen=stats_mode=diff"
    local args_palette = {
        options.ffmpegCmd,
        "-v", "warning",
        "-ss", tostring(position), "-t", tostring(duration),
        "-i", pathname,
        "-vf", filter_pal,
        "-y", palette
    }

    local filter_gif = v_track .. filters .. subtitle_filter .. " [x]; "
    filter_gif = filter_gif .. "[x][1:v] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
    local args_gif = {
        options.ffmpegCmd,
        "-v", "warning",
        "-ss", tostring(position), "-t", tostring(duration),  -- define which part to use
        "-copyts",  -- otherwise ss can't be reused
        "-i", pathname, "-i", palette,  -- open files
        "-an",  -- remove audio
        "-ss", tostring(position),  -- required for burning subtitles
        "-lavfi", filter_gif,
        "-y", gifname  -- output
    }

    local palette_cmd = {
        name = "subprocess",
        args = args_palette,
        capture_stdout = true,
        capture_stderr = true
    }

    local gif_cmd = {
        name = "subprocess",
        args = args_gif,
        capture_stdout = true,
        capture_stderr = true
    }

    log_verbose("[ARGS] ffmpeg palette:", dump(args_palette))
    log_verbose("[ARGS] ffmpeg gif:", dump(args_gif))

    -- first, create the palette
    mp.command_native_async(palette_cmd, function(res, val, err)
        if log_command_result("ffmpeg palette", res, val, err) ~= 0 then
            return
        end

        msg.info("Generated palette: " .. palette)

        -- then, make the gif
        mp.command_native_async(gif_cmd, function(res, val, err)
            if log_command_result("ffmpeg gif", res, val, err) ~= 0 then
                return
            end

            msg.info(string.format("GIF created - %s", gifname))
            mp.osd_message(string.format("GIF created - %s", gifname), 2)
        end)
    end)
end

function set_gif_start()
    start_time = mp.get_property_number("time-pos", -1)
    mp.osd_message("GIF Start: " .. start_time)
end

function set_gif_end()
    end_time = mp.get_property_number("time-pos", -1)
    mp.osd_message("GIF End: " .. end_time)
end

-- Remnant: Allow similar behavior to mkdir -p in linux
function split(inputstr, sep)
    if sep == nil then
        sep = "%s"
    end
    local t={}
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
        table.insert(t, str)
    end
    return t
end

--- Check if a file or directory exists in this path
function exists(file)
   local ok, err, code = os.rename(file, file)
   if not ok then
      if code == 13 then
         -- Permission denied, but it exists
         return true
      end
   end
   return ok, err
end

--- Check if a directory exists in this path
function is_dir(path)
   -- "/" works on both Unix and Windows
   return exists(path .. "/")
end

function ensure_out_dir(pathname)
    if is_dir(pathname) then
        return
    end

    msg.info("Out dir not found, creating: " .. pathname)
    if not IS_WINDOWS then
        os.execute('mkdir -p ' .. pathname)
    end

    -- TODO: Experimental if MSYS/MINGW is available, use its mkdir
    -- if os.execute("uname") then
    --     -- uname is available, so we can try to use gnu "mkdir"

    --     -- TODO: Add additional test to this
    --     os.execute('bash -c "mkdir -p \'' .. pathname .. '\'"')
    -- end

    -- Windows mkdir should behave like "mkdir -p" if command extensions are enabled.
    os.execute("mkdir " .. win_dir_esc(pathname))
end

function file_exists(name)
    -- io.open supports both '/' and '\' path separators
    local f = io.open(name, "r")
    if f ~= nil then io.close(f) return true else return false end
end

-- TODO: Check for removal
function get_containing_path(str, sep)
    sep = sep or package.config:sub(1,1)
    return str:match("(.*"..sep..")")
end

local lower_key = string.lower(options.key)
local upper_key = string.upper(options.key)

mp.add_key_binding(lower_key, "set_gif_start", set_gif_start)
mp.add_key_binding(upper_key, "set_gif_end", set_gif_end)
mp.add_key_binding(string.format("Ctrl+%s", lower_key), "make_gif", make_gif)
mp.add_key_binding(string.format("Ctrl+%s", upper_key), "make_gif_with_subtitles", make_gif_with_subtitles)
