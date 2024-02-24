-- Create animated GIFs with mpv
-- Requires ffmpeg.
-- Adapted from http://blog.pkh.me/p/21-high-quality-gif-with-ffmpeg.html
-- Usage: "g" to set start frame, "G" to set end frame, "Ctrl+g" to create.
local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
mp.options = require 'mp.options'
local IS_WINDOWS = package.config:sub(1, 1) ~= "/"

-- Global start and end time
start_time = -1
end_time = -1

-- options
-- require 'mp.options'
local default_options = {
    fps = 15,
    width = 600,
    height = -1,
    extension = "gif", -- file extension by default
    outputDirectory = "~/mpv-gifs", -- save to home directory by default
    flags = "lanczos", -- or "spline"
    customFilters = "",
    key = "g", -- Default key. It will be used as "g": start, "G": end, "Ctrl+g" create non-sub, "Ctrl+G": create sub.
    keyStartTime = "",
    keyEndTime = "",
    keyMakeGif = "",
    keyMakeGifSub = "",
    ffmpegCmd = "ffmpeg",
    ffprogCmd = "ffprog",
    ytdlpCmd = "yt-dlp",
    ytdlpSubLang = "en.*",
    debug = false, -- for debug
    mode = "gif"
}

-- Read options on startup. Later executions will read the options again
-- so things like the commands and paths can be changed on the fly
-- while other things like keybindings will require you to relaunch
mp.options.read_options(default_options, "gifgen")

local log_verbose = default_options.debug and function (...)
    msg.info(...)
end or function (...) end

-- Debug only - Get printable strings for tables
local function dump(o)
    if not default_options.debug then
        return ""
    end

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

local function is_local_file()
    -- Pathname for urls will be the url itself
    local pathname = mp.get_property("path", "")
    return string.find(pathname, "^https?://") == nil
end

local function win_dir_esc(s)
    -- To create a dir using mkdir in cmd path requires to use backslash
    return string.gsub(s, [[/]], [[\]])
end

-- local function win_dir_esc_str(s)
--     return string.gsub(s, [[/]], [[\\]])
-- end

-- shell escape
-- local function esc(s)
--     -- Copied function. Probably not needed
--     return string.gsub(s, '"', '"\\""')
-- end

local function escape_colon(s)
    return string.gsub(s, ":", "\\:")
end

local function ffmpeg_esc(s)
    -- escape string to be used in ffmpeg arguments (i.e. filenames in filter)
    -- s = string.gsub(s, "/", IS_WINDOWS and "\\" or "/" ) -- Windows seems to work fine with forward slash '/'
    s = string.gsub(s, [[\]], [[/]])
    s = string.gsub(s, '"', '"\\""')
    s = string.gsub(s, "'", "\\'")
    return s
end

local function clean_string(s)
    -- Remove problematic chars from strings
    return string.gsub(s, "[\\/|?*%[%]\"\'>< ]", [[_]])
end

local function has_subtitles(filepath)
    -- Command will return "subtitle" if subtitles are available (https://superuser.com/questions/1206714/ffmpeg-errors-out-when-no-subtitle-exists)
    local args_ffprobe = {
        "ffprobe", "-loglevel", "error",
        "-select_streams", "s:0",
        "-show_entries", "stream=codec_type",
        "-of", "csv=p=0",
        filepath,
    }

    log_verbose("[GIF][ARGS] ffprobe subtitle:", dump(args_ffprobe))

    local ffprobe_res, ffprobe_err = mp.command_native({
        name = "subprocess",
        args = args_ffprobe,
        capture_stdout = true,
        capture_stderr = true
    })

    log_verbose("[GIF] Command ffprog complete. Res:", dump(ffprobe_res))
    log_verbose("[GIF] Command ffprog err:", dump(ffprobe_err))

    return ffprobe_res ~= nil and ffprobe_res["stdout"] ~= nil and string.find(ffprobe_res["stdout"], "subtitle") ~= nil
end

local function expand_string(s)
    -- expand given path (i.e. ~/, ~~/, …)
    local expand_res, expand_err = mp.command_native({ "expand-path", s })
    return ffmpeg_esc(expand_res)
end

--- Check if a file or directory exists in this path
local function exists(file)
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
local function is_dir(path)
   -- "/" works on both Unix and Windows
   return exists(path .. "/")
end

local function ensure_out_dir(pathname)
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

local function file_exists(name)
    -- io.open supports both '/' and '\' path separators
    local f = io.open(name, "r")
    if f ~= nil then io.close(f) return true else return false end
end

-- TODO: Check for removal
-- local function get_containing_path(str, sep)
--     sep = sep or package.config:sub(1,1)
--     return str:match("(.*"..sep..")")
-- end

math.randomseed(os.time(), tonumber(tostring(os.time()):reverse():sub(1, 9)))
local random = math.random
local function uuid()
    local template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    local id, _ = string.gsub(template, '[xy]', function (c)
        local v = (c == 'x') and random(0, 0xf) or random(8, 0xb)
        return string.format('%x', v)
    end)

    return id
end

local function get_path()
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

-- Remnant: Allow similar behavior to mkdir -p in linux
-- local function split(inputstr, sep)
--     if sep == nil then
--         sep = "%s"
--     end
--     local t={}
--     for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
--         table.insert(t, str)
--     end
--     return t
-- end

-- function get_file_name(name)
--   return name:match("^.+/(.+)$")
-- end

local function get_file_extension(name)
  return name:match("^.+(%..+)$")
end

local function get_file_names(options)
    local is_local = is_local_file()
    local filename = is_local and mp.get_property("filename/no-ext") or mp.get_property("media-title", mp.get_property("filename/no-ext"))
    local videoext = is_local and get_file_extension(mp.get_property("filename")) or 'mp4'
    local file_path = options.outputDirectory .. "/" .. clean_string(filename)
    local gifname = nil
    local videoname = nil

    -- increment filename
    for i = 0,999 do
        local gif_name = string.format('%s_%03dg.%s', file_path, i, options.extension)
        local video_name = string.format('%s_%03dv.%s', file_path, i, videoext)
        if (not file_exists(gif_name)) and (not file_exists(video_name)) then
            gifname = gif_name
            videoname = video_name
            break
        end
    end

    if not gifname then
        msg.warning("No available filename")
        mp.osd_message('No available filenames!')
        return
    end

    return gifname, videoname, videoext
end

local function shallow_copy(t)
  local table = {}
  for k, v in pairs(t) do
    table[k] = v
  end
  return table
end

local function log_command_result(res, val, err, command, tmp)
    command = command or "command"
    log_verbose("[GIF][RES] " .. command .. " :", res)

    if val ~= nil then
        log_verbose("[GIF][VAL]:", dump(val))
    end

    if err ~= nil then
        log_verbose("[GIF][ERR]:", dump(err))
    end

    if not (res and (val == nil or val["status"] == 0)) then
        local file = nil
        if val ~= nil and val["stderr"] then
            if mp.get_property("options/terminal") == "no" then
                file = io.open(string.format(tmp .. "/mpv-gif-ffmpeg.%s.log", os.time()), "w")
                file:write(string.format("ffmpeg error %d:\n%s", val["status"], val["stderr"]))
                file:close()
            else
                msg.error(val["stderr"])
            end
        else
            if mp.get_property("options/terminal") == "no" then
                file = io.open(string.format(tmp .. "/mpv-gif-ffmpeg.%s.log", os.time()), "w")
                file:write(string.format("ffmpeg error:\n%s", err))
                file:close()
            else
                msg.error("Error msg: " .. err)
            end
        end

        local message = string.format('[GIF] Command "%s" execution was unsuccessful', command)
        msg.error(message)
        mp.osd_message(message)
        return -1
    end

    return 0
end

local function get_tracks()
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

local function get_options()
    local options = shallow_copy(default_options)
    mp.options.read_options(options, "gifgen")

    options.outputDirectory = expand_string(options.outputDirectory)
    options.ytdlpCmd = expand_string(options.ytdlpCmd)
    options.ffmpegCmd = expand_string(options.ffmpegCmd)
    options.ffprogCmd = expand_string(options.ffprogCmd)

    log_verbose("[GIF][OPTIONS]:", utils.to_string(default_options))

    return options
end

local function get_file_options(options)
    local save_video = options.mode == 'video' or options.mode == 'all'
    local save_gif = options.mode == 'gif' or options.mode == 'all' or save_video == false
    local hash_name = uuid()
    local temp_location = IS_WINDOWS and ffmpeg_esc(os.getenv("TEMP")) or "/tmp"
    temp_location = temp_location .. '/gifgen/' .. hash_name
    local palette = temp_location .. "/mpv-gif-gen_palette.png"
    local segment_base = "mpv-gif-gen_segment"
    local segment_cmd = segment_base .. ".%(ext)s"
    local segment = temp_location .. "/" .. segment_base .. ".mp4"
    local gifname, videoname, videoext = get_file_names(options)
    local filters = ''

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

    log_verbose("[GIF][TMP] Location:", temp_location)

    local file_options = {
        save_video = save_video,
        save_gif = save_gif,
        hash = hash_name,
        tmp = temp_location,
        palette = palette,
        segment = segment,
        segment_base = segment_base,
        segment_cmd = segment_cmd,
        gifname = gifname,
        videoname = videoname,
        videoext = videoext,
        filters = filters,
    }

    log_verbose("[GIF] File opts:", file_options)

    return file_options
end

local function copy_file(target, destination, tmp)
    -- TODO: Allow custom copy command in config
    local args_cp = IS_WINDOWS and {
        -- Insert reference: "Look what they need to mimic a fraction of our power" 
        -- Using powershell (although slower up-time) as cmd copy command
        -- only accept '\' in the path. It is fine to change slash into
        -- backslash for os.execute but it seems to have issues with
        -- subprocess command. Either subprocess fails because of backslashes
        -- in strings or cmd complains of invalid syntax with forward slash.
        -- This can't use os.execute as the copy could take too much
        -- time for a blockeing call. Would be nice to have a proper
        -- executable for copy thus it may be useful to support custom
        -- commands in the future.
        "powershell",
        "-NoLogo",
        "-NonInteractive",
        "-NoProfile",
        "-Command",
        "Copy-Item",
        target,
        destination
        -- "cmd",
        -- "/c",
        -- "copy", 
        -- target, -- cmd doesn't like 
        -- destination, -- cmd does't like
        -- win_dir_esc_str(target), -- subprocess doesn't like
        -- win_dir_esc_str(destination), -- subprocess doesn't like
    } or {
        "cp",
        target,
        destination,
    }

    local cp_cmd = {
        name = "subprocess",
        args = args_cp,
        capture_stdout = true,
        capture_stderr = true
    }

    log_verbose(string.format("[GIF][ARGS] cp:"), dump(args_cp))

    mp.command_native_async(cp_cmd, function (res, val, err)
        if log_command_result(res, val, err, 'cp', tmp) ~= 0 then
            return
        end

        local message = string.format('Copy created - %s', destination)
        msg.info(message)
        mp.osd_message(message)
    end)
end

-- TODO: Consider alternative for copy files by copying
-- bytes rather than rely on native commands.
-- Ref: https://forum.cockos.com/showthread.php?t=244397
-- local function copy_file(old_path, new_path)
--   local old_file = io.open(old_path, "rb")
--   local new_file = io.open(new_path, "wb")
--   local old_file_sz, new_file_sz = 0, 0
--   if not old_file or not new_file then
--     return false
--   end
--   while true do
--     local block = old_file:read(2^13)
--     if not block then
--       old_file_sz = old_file:seek( "end" )
--       break
--     end
--     new_file:write(block)
--   end
--   old_file:close()
--   new_file_sz = new_file:seek( "end" )
--   new_file:close()
--   return new_file_sz == old_file_sz
-- end

local function cut_video(start_time_l, end_time_l, pathname, options, file_options)
    local position = start_time_l
    local duration = end_time_l - start_time_l

    -- Check time setup is in range
    if start_time_l == -1 or end_time_l == -1 or start_time_l >= end_time_l then
        mp.osd_message("Invalid start/end time.")
        return
    end

    local videoname = file_options.videoname

    -- TODO: consider using 'copy' or allow configurable
    -- codecs for re-encoding 'libx264' and 'aac'
    -- Ref: https://shotstack.io/learn/use-ffmpeg-to-trim-video/
    local args_cut = {
        options.ffmpegCmd,
        "-v", "warning",
        "-ss", tostring(position), "-t", tostring(duration),  -- define which part to use
        "-accurate_seek",
        "-i", pathname, -- input file
        "-c:v", "libx264", -- Re-encode video
        "-c:a", "copy", videoname, -- output file
    }

    local cut_cmd = {
        name = "subprocess",
        args = args_cut,
        capture_stdout = true,
        capture_stderr = true
    }

    mp.command_native_async(cut_cmd, function (res, val, err)
        if log_command_result(res, val, err, 'ffmpeg->cut', file_options.tmp) ~= 0 then
            return
        end

        local message = string.format('Video created - %s', videoname)
        msg.info(message)
        mp.osd_message(message)
    end)
end

local function download_video_segment(start_time_l, end_time_l, burn_subtitles, options, file_options)
    -- Check time setup is in range
    if start_time_l == -1 or end_time_l == -1 or start_time_l >= end_time_l then
        mp.osd_message("Invalid start/end time.")
        return
    end

    msg.info("Start video segment download" .. (burn_subtitles and " (with subtitles)" or ""))
    mp.osd_message("Start video segment download" .. (burn_subtitles and " (with subtitles)" or ""))

    local url = mp.get_property("path", "")

    local args_ytdlp = {
        options.ytdlpCmd,
        "-v", -- For debug
        "--download-sections", "*" .. start_time_l .. "-" .. end_time_l, -- Specify download segment
        "--force-keyframes-at-cuts", -- Force cut at specify segment
        "-S", "proto:https", -- Avoid hls m3u8 for ffmpeg bug (https://github.com/yt-dlp/yt-dlp/issues/7824)
        "--path", file_options.tmp, -- Path to download video
        "--output", file_options.segment_cmd, -- Name of the out file
        "--force-overwrites", -- Always overwrite previous file with same name in tmp dir
        "-f", "mp4", -- Select video format. Setting mp4 to get a mp4 container
        -- "--remux-video", "mp4", -- Force always getting a mp4
        url,
    }

    -- Pass flags to embed subtitles. Subtitles support depend on video.
    if burn_subtitles then
        -- Embed Subtitles
        -- https://www.reddit.com/r/youtubedl/comments/wrjaa6/burn_subtitle_while_downloading_video
        table.insert(args_ytdlp, "--embed-subs")
        table.insert(args_ytdlp, "--sub-langs")
        table.insert(args_ytdlp, options.ytdlpSubLang)
        -- TODO: Study if these options can be used
        -- table.insert(args_ytdlp, "--postprocessor-args")
        -- table.insert(args_ytdlp, "EmbedSubtitle:-disposition:s:0 forced")
        -- table.insert(args_ytdlp, "--merge-output-format")
        -- table.insert(args_ytdlp, "mp4")
    end

    log_verbose("[GIF][ARGS] yt-dlp:", dump(args_ytdlp))

    local ytdlp_cmd = {
        name = "subprocess",
        args = args_ytdlp,
        capture_stdout = true,
        capture_stderr = true
    }

    -- Download video segment
    mp.command_native_async(ytdlp_cmd, function(res, val, err)
        if log_command_result(res, val, err, "yt-dlp", file_options.tmp) ~= 0 then
            return
        end

        local segment = file_options.segment
        local message = string.format("Video segment downloaded: %s", segment)
        local duration = end_time_l - start_time_l
        msg.info(message)
        mp.osd_message(message)

        if file_options.save_gif then
            make_gif_internal(0, duration, burn_subtitles, options, file_options, segment)
        end

        if file_options.save_video and file_options.videoname then
            copy_file(segment, file_options.videoname, file_options.tmp)
        end
    end)
end

local function make_gif_internal(start_time_l, end_time_l, burn_subtitles, options, file_options, pathname)
    -- Check time setup is in range
    if start_time_l == -1 or end_time_l == -1 or start_time_l >= end_time_l then
        mp.osd_message("Invalid start/end time.")
        return
    end

    -- abort if no gifname available
    local gifname = file_options.gifname
    if gifname == nil then
        return
    end

    -- Prepare out directory
    ensure_out_dir(ffmpeg_esc(options.outputDirectory))

    local sel_video, sel_sub, has_sub = get_tracks()

    if sel_video == nil then
        mp.osd_message("GIF abort: no video")
        msg.info("No video selected")
        return
    end

    msg.info("Creating GIF" .. (burn_subtitles and " (with subtitles)" or ""))
    mp.osd_message("Creating GIF" .. (burn_subtitles and " (with subtitles)" or ""))

    local subtitle_filter = ""
    -- add subtitles only for final rendering as it slows down significantly
    if burn_subtitles and has_sub and is_local_file() then
        -- TODO: implement usage of different subtitle formats (i.e. bitmap ones, …)
        sid = (sel_sub == nil and 0 or sel_sub["id"] - 1)  -- mpv starts counting subtitles with one
        subtitle_filter = string.format(",subtitles='%s':si=%d", escape_colon(pathname), sid)
    elseif burn_subtitles and not is_local_file() and has_subtitles(pathname) then
        subtitle_filter = string.format(",subtitles='%s':si=0", escape_colon(pathname))
    elseif burn_subtitles then
        msg.info("There are no subtitle tracks")
        mp.osd_message("GIF: ignoring subtitle request")
    end

    local position = start_time_l
    local duration = end_time_l - start_time_l
    local palette = file_options.palette
    local filters = file_options.filters

    -- set arguments
    local v_track = string.format("[0:v:%d] ", sel_video["id"] - 1)
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

    log_verbose("[GIF][ARGS] ffmpeg palette:", dump(args_palette))
    log_verbose("[GIF][ARGS] ffmpeg gif:", dump(args_gif))

    -- first, create the palette
    mp.command_native_async(palette_cmd, function(res, val, err)
        if log_command_result(res, val, err, "ffmpeg->palette", file_options.tmp) ~= 0 then
            return
        end

        msg.info("Generated palette: " .. palette)

        -- then, make the gif
        mp.command_native_async(gif_cmd, function(res, val, err)
            if log_command_result(res, val, err, "ffmpeg->gif", file_options.tmp) ~= 0 then
                return
            end

            msg.info(string.format("GIF created - %s", gifname))
            mp.osd_message(string.format("GIF created - %s", gifname), 2)
        end)
    end)

    if is_local_file() and file_options.save_video then
        cut_video(start_time_l, end_time_l, pathname, options, file_options)
    end
end

-- Functions for keybindings

function set_gif_start()
    start_time = mp.get_property_number("time-pos", -1)
    mp.osd_message("GIF Start: " .. start_time)
end

function set_gif_end()
    end_time = mp.get_property_number("time-pos", -1)
    mp.osd_message("GIF End: " .. end_time)
end

function make_gif_with_subtitles()
    local options = get_options()
    local file_options = get_file_options(options)
    ensure_out_dir(file_options.tmp)
    if is_local_file() then
        make_gif_internal(start_time, end_time, true, options, file_options, get_path())
    else
        download_video_segment(start_time, end_time, true, options, file_options)
    end
end

function make_gif()
    local options = get_options()
    local file_options = get_file_options(options)
    ensure_out_dir(file_options.tmp)
    if is_local_file() then
        make_gif_internal(start_time, end_time, false, options, file_options, get_path())
    else
        download_video_segment(start_time, end_time, false, options, file_options)
    end
end

local lower_key = string.lower(default_options.key)
local upper_key = string.upper(default_options.key)
local start_time_key = default_options.keyStartTime ~= "" and default_options.keyStartTime or lower_key
local end_time_key = default_options.keyEndTime ~= "" and default_options.keyEndTime or upper_key
local make_gif_key = default_options.keyMakeGif ~= "" and default_options.keyMakeGif or string.format("Ctrl+%s", lower_key)
local make_gif_sub_key = default_options.keyMakeGifSub ~= "" and default_options.keyMakeGifSub or string.format("Ctrl+%s", upper_key)

log_verbose("[GIF] Keybindings:", dump({
    lower_key,
    upper_key,
    start_time_key,
    end_time_key,
    make_gif_key,
    make_gif_sub_key,
}))

mp.add_key_binding(start_time_key, "set_gif_start", set_gif_start)
mp.add_key_binding(end_time_key, "set_gif_end", set_gif_end)
mp.add_key_binding(make_gif_key, "make_gif", make_gif)
mp.add_key_binding(make_gif_sub_key, "make_gif_with_subtitles", make_gif_with_subtitles)
