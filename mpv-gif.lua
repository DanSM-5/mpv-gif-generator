-- Create animated GIFs with mpv
-- Requires ffmpeg.
-- Adapted from http://blog.pkh.me/p/21-high-quality-gif-with-ffmpeg.html
-- Usage: "g" to set start frame, "G" to set end frame, "Ctrl+g" to create.
local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')
mp.options = require('mp.options')
local IS_WINDOWS = package.config:sub(1, 1) ~= '/'

-- Global start and end time
local start_time = -1
local end_time = -1

---@class BaseOptions
---@field fps number
---@field width number
---@field height number
---@field extension string
---@field outputDirectory string
---@field flags string
---@field customFilters string
---@field key string
---@field keyStartTime string
---@field keyEndTime string
---@field keyMakeGif string
---@field keyMakeGifSub string
---@field ffmpegCmd string
---@field ffprogCmd string
---@field ytdlpCmd string
---@field ytdlpSubLang string
---@field copyVideoCodec string
---@field copyAudioCodec string
---@field debug boolean
---@field mode 'gif' | 'video' | 'all'

---@class FileOptions
---@field save_video boolean
---@field save_gif boolean
---@field hash string
---@field tmp string
---@field palette string
---@field segment string
---@field tmpvideo string
---@field tmpgif string
---@field segment_base string
---@field segment_cmd string
---@field gifname string
---@field videoname string
---@field videoext string
---@field filters string

---@class Options: FileOptions, BaseOptions

---@type BaseOptions
local default_options = {
  fps = -1,
  width = 680,
  height = -1,
  extension = 'gif', -- file extension by default
  outputDirectory = '~/mpv-gifs', -- save to home directory by default
  flags = 'lanczos', -- or "spline"
  customFilters = '',
  ffmpegCmd = 'ffmpeg',
  ffprogCmd = 'ffprog',
  ytdlpCmd = 'yt-dlp',
  ytdlpSubLang = 'en.*',
  copyVideoCodec = 'copy',
  copyAudioCodec = 'copy',
  debug = false, -- for debug
  mode = 'gif',
  -- NOTE: key related configs cannot be remaped on the fly
  -- The other configs can be changed at any time
  key = 'g', -- Default key. It will be used as "g": start, "G": end, "Ctrl+g" create non-sub, "Ctrl+G": create sub.
  keyStartTime = '',
  keyEndTime = '',
  keyMakeGif = '',
  keyMakeGifSub = '',
}

-- Read options on startup. Later executions will read the options again
-- so things like the commands and paths can be changed on the fly
-- while other things like keybindings will require you to relaunch
mp.options.read_options(default_options, 'gifgen')

local log_verbose = default_options.debug and function(...)
  msg.info(...)
end or function(...) end

local debug_enabled = default_options.debug

-- Debug only - Get printable strings for tables
local function dump(o)
  if not debug_enabled then
    return ''
  end

  if type(o) == 'table' then
    local s = '{ '
    for k, v in pairs(o) do
      if type(k) ~= 'number' then
        k = '"' .. k .. '"'
      end
      s = s .. '[' .. k .. '] = ' .. dump(v) .. ','
    end
    return s .. '} '
  else
    return tostring(o)
  end
end

---Create a temporary lock file to reserve the filename
---as multiple gifts can be made in parallel
---@param name string Name of the lock file
---@return boolean
local function create_lock_file(name)
  -- "echo '' >> $name" should work to create an empty file on
  -- windows (cmd) and linux.
  -- os.execute(string.format("echo '' >> '%s'", name))
  local f = io.open(name, 'w')
  if f ~= nil then
    io.close(f)
    return true
  else
    return false
  end
end

---Delete lock file
---@param name string Name of the lock file to delete
---@return boolean If deletion succeded
---@return string? Error if deletion failed
local function delete_lock_file(name)
  local ok, err = os.remove(name)
  return ok, err
end

---Replace a lock file with the final file
---@param source string Path to the file that will replace the lockfile
---@param destination string Path to the lockfile to be replaced
---@return boolean If replacement of lockfile was successful
---@return string? Error if replacement of lockfile failed
local function replace_lock_file(source, destination)
  local message = string.format('[GIF][LOCK] Replacing %s with %s', source, destination)
  log_verbose(message)
  delete_lock_file(destination)
  if not IS_WINDOWS then
    local ok, err = os.execute(string.format('mv "%s" "%s"', source, destination))
    return ok or false, 'Unable to move temp file: ' .. err
  end
  local ok, err = os.rename(source, destination)
  return ok, err
end

---Check if the current playing asset is a video from the filesystem (local)
---@return boolean If the playing asset is local
local function is_local_file()
  -- Pathname for urls will be the url itself
  local pathname = mp.get_property('path', '')
  return string.find(pathname, '^https?://') == nil
end

---Replace all forward slash with backslash for windows
---specific paths that do not handle forward slash appropriately
---@param s string Path with potential forward slashes
---@return string Path forward slashes replaced by backslashes
local function win_dir_esc(s)
  -- To create a dir using mkdir in cmd path requires to use backslash
  local replaced = string.gsub(s, [[/]], [[\]])
  return replaced
end

-- local function win_dir_esc_str(s)
--     return string.gsub(s, [[/]], [[\\]])
-- end

-- shell escape
-- local function esc(s)
--     -- Copied function. Probably not needed
--     return string.gsub(s, '"', '"\\""')
-- end

---Escape colon character for windows absolute paths
---@param s string Path to escape colons from
---@return string Escaped string
local function escape_colon(s)
  local escaped = string.gsub(s, ':', '\\:')
  return escaped
end

---Escape characters for ffmpeg
---@param s string String to be processed
---@return string Escaped string
local function ffmpeg_esc(s)
  -- escape string to be used in ffmpeg arguments (i.e. filenames in filter)
  -- s = string.gsub(s, "/", IS_WINDOWS and "\\" or "/" )
  -- Windows seems to work fine with forward slash '/'
  -- Change the paths if running on windows.
  if IS_WINDOWS then
    -- TODO: local files with quotes are escaped
    -- and the next gsub change the escape to forward
    -- slash breaking the file name
    s = string.gsub(s, [[\]], [[/]])
  end

  -- ffmpeg is working with names with quotes,
  -- leave it commented for now.
  -- s = string.gsub(s, '"', '"\\""')
  -- s = string.gsub(s, "'", "\\'")
  return s
end

---Remove special characters from video/gif name to avoid issues
---due to presence of special characters.
---Carriage return and new line characters are removed. Others are
---replaced by an underscore
---@param s string string to be cleanup
---@return string cleaned string
local function clean_string(s)
  -- Remove problematic chars from strings
  local escaped = string.gsub(s, '[\\/:|!?*%[%]"\'><, ]', [[_]]):gsub('[\n\r]', [[]])
  return escaped
end

---Check if the given path to a video asset containers
---embedded subtitles.
---This is not a 100% accurate check but it works most of the times
---@param filepath string Path to video asset
---@return boolean Whether or not the video contains subtitles
local function has_subtitles(filepath)
  -- Command will return "subtitle" if subtitles are available (https://superuser.com/questions/1206714/ffmpeg-errors-out-when-no-subtitle-exists)
  local args_ffprobe = {
    'ffprobe',
    '-loglevel',
    'error',
    '-select_streams',
    's:0',
    '-show_entries',
    'stream=codec_type',
    '-of',
    'csv=p=0',
    filepath,
  }

  log_verbose('[GIF][ARGS] ffprobe subtitle:', dump(args_ffprobe))

  local ffprobe_res, ffprobe_err = mp.command_native({
    name = 'subprocess',
    args = args_ffprobe,
    capture_stdout = true,
    capture_stderr = true,
  })

  log_verbose('[GIF] Command ffprog complete. Res:', dump(ffprobe_res))
  log_verbose('[GIF] Command ffprog err:', dump(ffprobe_err))

  return ffprobe_res ~= nil and ffprobe_res['stdout'] ~= nil and string.find(ffprobe_res['stdout'], 'subtitle') ~= nil
end

---Expand special strings for mpv such as ~/, ~~/, etc.
---@param s string String to expand
---@return string Expanded string
local function expand_string(s)
  -- expand given path (i.e. ~/, ~~/, …)
  local expand_res, expand_err = mp.command_native({ 'expand-path', s })
  return ffmpeg_esc(expand_res)
end

--- Check if a file or directory exists in this path
---@param file string Path to item in filesystem
---@return boolean if the path exists
---@return string|nil Error if path check could not be verified
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
---@param path string check if a path to a directory exists
---@return boolean If the path exists
local function is_dir(path)
  -- "/" works on both Unix and Windows
  return exists(path .. '/')
end

--- Verify that path exists or creates it if not
--- This rely on native shell commands per platform
--- @param pathname string Path to directory make if it doesn't exists
local function ensure_out_dir(pathname)
  if is_dir(pathname) then
    return
  end

  msg.info('Out dir not found, creating: ' .. pathname)
  if not IS_WINDOWS then
    os.execute('mkdir -p ' .. pathname)
    return
  end

  -- TODO: Experimental if MSYS/MINGW is available, use its mkdir
  -- if os.execute("uname") then
  --     -- uname is available, so we can try to use gnu "mkdir"

  --     -- TODO: Add additional test to this
  --     os.execute('bash -c "mkdir -p \'' .. pathname .. '\'"')
  -- end

  -- Windows mkdir should behave like "mkdir -p" if command extensions are enabled.
  os.execute('mkdir ' .. win_dir_esc(pathname))
end

---Check that path exists and it is a file with write permissions
---@param name string Path to file to check
---@return boolean If the name is a file and it is writable
local function file_exists(name)
  -- io.open supports both '/' and '\' path separators
  local f = io.open(name, 'r')
  if f ~= nil then
    io.close(f)
    return true
  else
    return false
  end
end

-- TODO: Check for removal
-- local function get_containing_path(str, sep)
--     sep = sep or package.config:sub(1,1)
--     return str:match("(.*"..sep..")")
-- end

math.randomseed(os.time(), tonumber(tostring(os.time()):reverse():sub(1, 9)))
local random = math.random
---Generate a pseudo random UUID for temporary file storage
---This ensures that multiple gifs can be made simultaneously without
---temporary files conflicting due to sharing same name.
---@return string new UUID
local function uuid()
  local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  local id, _ = string.gsub(template, '[xy]', function(c)
    local v = (c == 'x') and random(0, 0xf) or random(8, 0xb)
    return string.format('%x', v)
  end)

  return id
end

---Get the path of the playing asset from mpv
---@return string
local function get_path()
  local is_absolute = nil
  local initial_pathname = mp.get_property('path', '')
  -- local filename = is_local and mp.get_property("filename/no-ext") or mp.get_property("media-title", mp.get_property("filename/no-ext"))

  local pathname = ffmpeg_esc(initial_pathname)

  if IS_WINDOWS then
    is_absolute = string.find(pathname, '^[a-zA-Z]:[/\\]') ~= nil
  else
    is_absolute = string.find(pathname, '^/') ~= nil
  end

  pathname = is_absolute and pathname
    or ffmpeg_esc(utils.join_path(mp.get_property('working-directory', ''), initial_pathname))

  log_verbose('[GIF][AssetPath] Filename/no-ext: ' .. mp.get_property('filename/no-ext'))
  log_verbose('[GIF][AssetPath] Media title: ' .. mp.get_property('media-title'))
  log_verbose('[GIF][AssetPath] Generated path: ' .. pathname)

  return pathname
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
  return name:match('^.+(%..+)$')
end

---Define the file names to be used for the gif or video
---@param options BaseOptions Options from the user
---@return string Name to be assined to the gif file
---@return string Name to be assined to the video file
---@return string Extension to be used for the video file
local function get_file_names(options)
  local is_local = is_local_file()
  local filename = is_local and mp.get_property('filename/no-ext')
    or mp.get_property('media-title', mp.get_property('filename/no-ext'))
  ---@type string
  local videoext = is_local and get_file_extension(mp.get_property('filename')) or 'mp4'
  local file_path = options.outputDirectory .. '/' .. clean_string(filename)
  ---@type string
  local gifname = nil
  ---@type string
  local videoname = nil

  -- remove starting dot
  if videoext:sub(1, 1) == '.' then
    videoext = videoext:sub(2)
  end

  -- increment filename
  for i = 0, 999 do
    local gif_name = string.format('%s_%03dg.%s', file_path, i, options.extension)
    local video_name = string.format('%s_%03dv.%s', file_path, i, videoext)
    if (not file_exists(gif_name)) and (not file_exists(video_name)) then
      gifname = gif_name
      videoname = video_name
      break
    end
  end

  if not gifname or not videoname then
    msg.warning('No available filename')
    mp.osd_message('No available filenames!')
    return '', '', ''
  end

  return gifname, videoname, videoext
end

--- Create shallow copy of a table
---@generic T Table to be shallowed copied
---@param t T Object table to be copied
---@return T New table with same properties as original
local function shallow_copy(t)
  local table = {}
  for k, v in pairs(t) do
    table[k] = v
  end
  return table
end

---Log the result of async commands if using a log file
---@param res string Result from native command
---@param val { status: integer; stderr: string? }|nil Status code and stderror from native command
---@param err string? Error if native command exited with non zero status code
---@param command string command that was run
---@param tmp string temporary location for files
---@return integer 0 if native command succeded
local function log_command_result(res, val, err, command, tmp)
  command = command or 'command'
  log_verbose('[GIF][RES] ' .. command .. ' :', res)

  if val ~= nil then
    log_verbose('[GIF][VAL]:', dump(val))
  end

  if err ~= nil then
    log_verbose('[GIF][ERR]:', dump(err))
  end

  if not (res and (val == nil or val['status'] == 0)) then
    local file = nil
    local options = shallow_copy(default_options)
    mp.options.read_options(options, 'gifgen')

    if val ~= nil and val['stderr'] then
      if mp.get_property('options/terminal') == 'no' or options.debug then
        file = io.open(string.format(tmp .. '/mpv-gif-ffmpeg.%s.log', os.time()), 'w')
        if file ~= nil then
          file:write(
            string.format(
              'Gif generation error %d:\n%s\n[VAL]: %s\n[ERR]: %s',
              val['status'],
              val['stderr'],
              dump(val),
              dump(err)
            )
          )
          file:close()
        end
      else
        msg.error(val['stderr'])
      end
    else
      if mp.get_property('options/terminal') == 'no' or options.debug then
        file = io.open(string.format(tmp .. '/mpv-gif-ffmpeg.%s.log', os.time()), 'w')
        if file ~= nil then
          file:write(string.format('Gif generation error:\n%s\n[VAL]: %s\n[ERR]: %s', err, dump(val), dump(err)))
          file:close()
        end
      else
        msg.error('Error msg: ' .. err)
      end
    end

    local message = string.format('[GIF] Command "%s" execution was unsuccessful', command)
    msg.error(message)
    mp.osd_message(message)
    return -1
  end

  return 0
end

---Attempt to extract the subtitle tracks to extract subtitles
---@return {id: integer}|nil
---@return { id: integer; codec: string; }|nil
---@return boolean Whether any of the tracks contain subtitles
local function get_tracks()
  -- retrieve information about currently selected tracks
  local tracks, err = utils.parse_json(mp.get_property('track-list'))
  if tracks == nil then
    msg.warning("Couldn't parse track-list")
    return nil, nil, false
  end

  local video = nil
  local has_sub = false
  local sub = nil

  for _, track in ipairs(tracks) do
    has_sub = has_sub or track['type'] == 'sub'

    if track['selected'] == true then
      if track['type'] == 'video' then
        video = { id = track['id'] }
      elseif track['type'] == 'sub' then
        sub = { id = track['id'], codec = track['codec'] }
      end
    end
  end

  return video, sub, has_sub
end

--- Create the config for files based on the provided config
---@param options BaseOptions Options from gifgen.conf file
---@return FileOptions Names and other file related data
local function get_file_options(options)
  local save_video = options.mode == 'video' or options.mode == 'all'
  local save_gif = options.mode == 'gif' or options.mode == 'all' or save_video == false
  local hash_name = uuid()
  local gifname, videoname, videoext = get_file_names(options)
  local temp_location = IS_WINDOWS and ffmpeg_esc(os.getenv('TEMP') or '') or '/tmp'
  temp_location = temp_location .. '/gifgen/' .. hash_name
  local palette = temp_location .. '/mpv-gif-gen_palette.png'
  local tmpvideo = temp_location .. '/mpv-gif-gen_tmpvideo' .. '.' .. videoext
  local tmpgif = temp_location .. '/mpv-gif-gen_tmpgif' .. '.' .. options.extension
  local segment_base = 'mpv-gif-gen_segment'
  local segment_cmd = segment_base .. '.%(ext)s'
  local segment = temp_location .. '/' .. segment_base .. '.mp4'
  local filters = ''

  if options.customFilters == nil or options.customFilters == '' then
    -- Set this to the filters to pass into ffmpeg's -vf option.
    -- filters="fps=24,scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=320:-1:flags=lanczos"
    filters = options.fps < 0 and '' or string.format('fps=%d,', options.fps)
    filters = filters
      .. string.format(
        "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=%d:%d:flags=%s",
        options.width,
        options.height,
        options.flags
      )
  else
    filters = string.format(options.customFilters, options.width, options.height, options.flags)
  end

  log_verbose('[GIF][TMP] Location:', temp_location)

  ---@type FileOptions
  local file_options = {
    save_video = save_video,
    save_gif = save_gif,
    hash = hash_name,
    tmp = temp_location,
    palette = palette,
    segment = segment,
    tmpvideo = tmpvideo,
    tmpgif = tmpgif,
    segment_base = segment_base,
    segment_cmd = segment_cmd,
    gifname = gifname,
    videoname = videoname,
    videoext = videoext,
    filters = filters,
  }

  log_verbose('[GIF] File opts:', utils.to_string(file_options))

  return file_options
end

---Generates the filenames and other file related options such as extension
---@return Options Options for the gif or video processing
local function get_options()
  local options = shallow_copy(default_options)
  mp.options.read_options(options, 'gifgen')

  -- Enable verbose if requested
  log_verbose = options.debug and function(...)
    msg.info(...)
  end or function(...) end

  -- You can only see this message if debug mode is enabled
  log_verbose('[GIF] Debug mode enabled!')
  debug_enabled = options.debug

  options.outputDirectory = ffmpeg_esc(expand_string(options.outputDirectory))
  options.ytdlpCmd = expand_string(options.ytdlpCmd)
  options.ffmpegCmd = expand_string(options.ffmpegCmd)
  options.ffprogCmd = expand_string(options.ffprogCmd)

  log_verbose('[GIF][OPTIONS]:', utils.to_string(default_options))

  local file_options = get_file_options(options)

  ---@cast options Options
  local fullOptions = options

  -- merge options
  for k, v in pairs(file_options) do
    fullOptions[k] = v
  end

  return fullOptions
end

---Copy a file from target to destination
---using native cli commands.
---cp in unix/unix-like operative systems
---Copy-Item cmdlet in windows
---@param target string File/directory to be copied
---@param destination string Path where the item should be copied to
---@param tmp string Path where temporary directories are located
local function copy_file(target, destination, tmp)
  -- TODO: Allow custom copy command in config
  local args_cp = IS_WINDOWS
      and {
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
        'powershell',
        '-WindowStyle',
        'Hidden',
        '-NoLogo',
        '-NonInteractive',
        '-NoProfile',
        '-Command',
        'Copy-Item',
        '-Force',
        '-Path',
        string.format("'%s'", target),
        '-Destination',
        string.format("'%s'", destination),
        -- "cmd",
        -- "/c",
        -- "copy",
        -- target, -- cmd doesn't like
        -- destination, -- cmd does't like
        -- win_dir_esc_str(target), -- subprocess doesn't like
        -- win_dir_esc_str(destination), -- subprocess doesn't like
      }
    or {
      'cp',
      '-f',
      target,
      destination,
    }

  local cp_cmd = {
    name = 'subprocess',
    args = args_cp,
    capture_stdout = true,
    capture_stderr = true,
  }

  log_verbose('[GIF][ARGS] cp:', dump(args_cp))

  mp.command_native_async(cp_cmd, function(res, val, err)
    if log_command_result(res, val, err, 'cp', tmp) ~= 0 then
      delete_lock_file(destination)
      local file = io.open(string.format(tmp .. '/mpv-gif-ffmpeg_cp.%s.log', os.time()), 'w')
      if file ~= nil then
        file:write(string.format('[CP] Command: %s\n[CP] Args: %s', dump(cp_cmd), dump(args_cp)))
        file:close()
      end
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

---Cut segment of video with the requested starting and ending time
---@param start_time_l number Start time for the video segment
---@param end_time_l number End time for the video segment
---@param pathname string Path to the video to be processed
---@param options Options Options with the data for the video process
local function cut_video(start_time_l, end_time_l, pathname, options)
  local position = start_time_l
  local duration = end_time_l - start_time_l

  -- Check time setup is in range
  if start_time_l == -1 or end_time_l == -1 or start_time_l >= end_time_l then
    mp.osd_message('Invalid start/end time.')
    delete_lock_file(options.videoname)
    return
  end

  local videoname = options.videoname
  local tmpvideo = options.tmpvideo

  -- Codecs for re-encoding 'libx264' and 'aac'
  -- Ref: https://shotstack.io/learn/use-ffmpeg-to-trim-video/
  local args_cut = {
    options.ffmpegCmd,
    '-v',
    'warning',
    '-ss',
    tostring(position),
    '-t',
    tostring(duration), -- define which part to use
    '-accurate_seek',
    '-i',
    pathname, -- input file
    '-c:v',
    options.copyVideoCodec, -- Use codec for video e.g. "libx264"
    '-c:a',
    options.copyAudioCodec, -- Use codec for audio e.g. "aac"
    tmpvideo, -- output file
  }

  local cut_cmd = {
    name = 'subprocess',
    args = args_cut,
    capture_stdout = true,
    capture_stderr = true,
  }

  mp.command_native_async(cut_cmd, function(res, val, err)
    if log_command_result(res, val, err, 'ffmpeg->cut', options.tmp) ~= 0 then
      delete_lock_file(options.videoname)
      return
    end

    local message = string.format('Video created - %s', videoname)
    local success_replace, err_replace = replace_lock_file(tmpvideo, videoname)

    if not success_replace then
      message = string.format('Error copying to destination. Gif in: %s', tmpvideo)
      mp.osd_message(message, 2)
      msg.info(message)
      msg.info(err_replace)
      delete_lock_file(videoname)
      return
    end

    msg.info(message)
    mp.osd_message(message)
  end)
end

---Creates a gif using ffmpeg
---@param start_time_l number Gif start time
---@param end_time_l number Gif end time
---@param burn_subtitles boolean Whether or not try to burn subtitles
---@param options Options Options for the gif creation
---@param pathname string Path to the video to process
local function make_gif_internal(start_time_l, end_time_l, burn_subtitles, options, pathname)
  -- Check time setup is in range
  if start_time_l == -1 or end_time_l == -1 or start_time_l >= end_time_l then
    mp.osd_message('Invalid start/end time.')
    delete_lock_file(options.gifname)
    return
  end

  -- abort if no gifname available
  local gifname = options.gifname
  local tmpgif = options.tmpgif

  -- gifname will be an empty string if there was abort
  -- failure to create the filename
  if gifname == '' then
    delete_lock_file(gifname)
    return
  end

  local sel_video, sel_sub, has_sub = get_tracks()

  if sel_video == nil then
    mp.osd_message('GIF abort: no video')
    msg.info('No video selected')
    delete_lock_file(gifname)
    return
  end

  msg.info('Creating GIF' .. (burn_subtitles and ' (with subtitles)' or ''))
  mp.osd_message('Creating GIF' .. (burn_subtitles and ' (with subtitles)' or ''))

  local subtitle_filter = ''
  -- add subtitles only for final rendering as it slows down significantly
  if burn_subtitles and has_sub and is_local_file() then
    local sid
    -- TODO: implement usage of different subtitle formats (i.e. bitmap ones, …)
    if sel_sub == nil then
      sid = 0
    else
      -- mpv starts counting subtitles with one
      sid = sel_sub['id'] - 1
    end
    -- sid = (sel_sub == nil and 0 or sel_sub["id"] - 1)
    subtitle_filter = string.format(",subtitles='%s':si=%d", escape_colon(pathname), sid)
  elseif burn_subtitles and not is_local_file() and has_subtitles(pathname) then
    subtitle_filter = string.format(",subtitles='%s':si=0", escape_colon(pathname))
  elseif burn_subtitles then
    msg.info('There are no subtitle tracks')
    mp.osd_message('GIF: ignoring subtitle request')
  end

  local position = start_time_l
  local duration = end_time_l - start_time_l
  local palette = options.palette
  local filters = options.filters

  -- set arguments
  local v_track = string.format('[0:v:%d] ', sel_video['id'] - 1)
  local filter_pal = v_track .. filters .. ',palettegen=stats_mode=diff'
  local args_palette = {
    options.ffmpegCmd,
    '-v',
    'warning',
    '-ss',
    tostring(position),
    '-t',
    tostring(duration),
    '-i',
    pathname,
    '-vf',
    filter_pal,
    '-y',
    palette,
  }

  local filter_gif = v_track .. filters .. subtitle_filter .. ' [x]; '
  filter_gif = filter_gif .. '[x][1:v] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle'
  local args_gif = {
    options.ffmpegCmd,
    '-v',
    'warning',
    '-ss',
    tostring(position),
    '-t',
    tostring(duration), -- define which part to use
    '-copyts', -- otherwise ss can't be reused
    '-i',
    pathname,
    '-i',
    palette, -- open files
    '-an', -- remove audio
    '-ss',
    tostring(position), -- required for burning subtitles
    '-lavfi',
    filter_gif,
    '-y',
    tmpgif, -- output
  }

  local palette_cmd = {
    name = 'subprocess',
    args = args_palette,
    capture_stdout = true,
    capture_stderr = true,
  }

  local gif_cmd = {
    name = 'subprocess',
    args = args_gif,
    capture_stdout = true,
    capture_stderr = true,
  }

  log_verbose('[GIF][ARGS] ffmpeg palette:', dump(args_palette))
  log_verbose('[GIF][ARGS] ffmpeg gif:', dump(args_gif))

  -- first, create the palette
  mp.command_native_async(palette_cmd, function(res_palette, val_palette, err_palette)
    if log_command_result(res_palette, val_palette, err_palette, 'ffmpeg->palette', options.tmp) ~= 0 then
      delete_lock_file(gifname)
      return
    end

    msg.info('Generated palette: ' .. palette)

    -- then, make the gif
    mp.command_native_async(gif_cmd, function(res_gif, val_gif, err_gif)
      if log_command_result(res_gif, val_gif, err_gif, 'ffmpeg->gif', options.tmp) ~= 0 then
        delete_lock_file(gifname)
        return
      end

      local completed_message = string.format('GIF created - %s', gifname)
      local success_replace, err_replace = replace_lock_file(tmpgif, gifname)

      if not success_replace then
        completed_message = string.format('Error copying to destination. Gif in: %s', tmpgif)
        mp.osd_message(completed_message, 2)
        msg.info(completed_message)
        msg.info(err_replace)
        delete_lock_file(gifname)
        return
      end

      msg.info(completed_message)
      mp.osd_message(completed_message, 2)
    end)
  end)
end

---Create a gif and/or video with the requested time
---and options.
---@param start_time_l number Start time for gif or video
---@param end_time_l number End time for gif or video
---@param with_subtitles boolean Whether or not to include subtitles
---@param options Options Options for the file processing
---@param pathname string Path to local video
---@param was_downloaded boolean Flag that indicates if the video segment was downloaded with yt-dlp
local function process_local_video(start_time_l, end_time_l, with_subtitles, options, pathname, was_downloaded)
  if options.save_gif then
    make_gif_internal(start_time_l, end_time_l, with_subtitles, options, pathname)
  else
    delete_lock_file(options.gifname)
  end

  if options.save_video then
    if was_downloaded then
      -- Downloaded file already has the requested time
      -- Just copy file to final destination
      copy_file(pathname, options.videoname, options.tmp)
    else
      -- For local files it is required to cut the video with ffmpeg
      cut_video(start_time_l, end_time_l, pathname, options)
    end
  else
    delete_lock_file(options.videoname)
  end
end

---Downloads the segment of video to be processed
---This function is only called when the video is not local
---@param start_time_l number Start time for gif
---@param end_time_l number End time for gif
---@param burn_subtitles boolean Whether or not to attempt to include subtitles
---@param options Options Options for the gif creation process
local function download_video_segment(start_time_l, end_time_l, burn_subtitles, options)
  -- Check time setup is in range
  if start_time_l == -1 or end_time_l == -1 or start_time_l >= end_time_l then
    mp.osd_message('Invalid start/end time.')
    delete_lock_file(options.gifname)
    delete_lock_file(options.videoname)
    return
  end

  msg.info('Start video segment download' .. (burn_subtitles and ' (with subtitles)' or ''))
  mp.osd_message('Start video segment download' .. (burn_subtitles and ' (with subtitles)' or ''))

  local url = mp.get_property('path', '')

  local args_ytdlp = {
    options.ytdlpCmd,
    '-v', -- For debug
    '--download-sections',
    '*' .. start_time_l .. '-' .. end_time_l, -- Specify download segment
    '--force-keyframes-at-cuts', -- Force cut at specify segment
    '-S',
    'proto:https', -- Avoid hls m3u8 for ffmpeg bug (https://github.com/yt-dlp/yt-dlp/issues/7824)
    '--path',
    options.tmp, -- Path to download video
    '--output',
    options.segment_cmd, -- Name of the out file
    '--force-overwrites', -- Always overwrite previous file with same name in tmp dir
    '-f',
    'mp4', -- Select video format. Setting mp4 to get a mp4 container
    -- "--remux-video", "mp4", -- Force always getting a mp4
    url,
  }

  -- Pass flags to embed subtitles. Subtitles support depend on video.
  if burn_subtitles then
    -- Embed Subtitles
    -- https://www.reddit.com/r/youtubedl/comments/wrjaa6/burn_subtitle_while_downloading_video
    table.insert(args_ytdlp, '--embed-subs')
    table.insert(args_ytdlp, '--sub-langs')
    table.insert(args_ytdlp, options.ytdlpSubLang)
    -- TODO: Study if these options can be used
    -- table.insert(args_ytdlp, "--postprocessor-args")
    -- table.insert(args_ytdlp, "EmbedSubtitle:-disposition:s:0 forced")
    -- table.insert(args_ytdlp, "--merge-output-format")
    -- table.insert(args_ytdlp, "mp4")
  end

  log_verbose('[GIF][ARGS] yt-dlp:', dump(args_ytdlp))

  local ytdlp_cmd = {
    name = 'subprocess',
    args = args_ytdlp,
    capture_stdout = true,
    capture_stderr = true,
  }

  -- Download video segment
  mp.command_native_async(ytdlp_cmd, function(res, val, err)
    if log_command_result(res, val, err, 'yt-dlp', options.tmp) ~= 0 then
      delete_lock_file(options.gifname)
      delete_lock_file(options.videoname)
      return
    end

    local segment = options.segment
    local message = string.format('Video segment downloaded: %s', segment)
    -- It is possible that the download completes but the output is either a bad video
    -- or empty due to the some encoding issue with youtube source.
    log_verbose('[GIF][YTDLP] Completed with success status code. For errors review the output video.')
    local duration = end_time_l - start_time_l
    msg.info(message)
    mp.osd_message(message)

    process_local_video(0, duration, burn_subtitles, options, segment, true)
  end)
end

---Starts the gif making process
---@param with_subtitles boolean Whether or not to include subtitles
local function process_gif_request(with_subtitles)
  local start_time_l = start_time
  local end_time_l = end_time
  local options = get_options()
  -- Prepare temporary files directory
  ensure_out_dir(options.tmp)
  -- Prepare out directory
  ensure_out_dir(options.outputDirectory)

  -- Prevent two calls to make gif override themselves
  -- due to same file names.
  create_lock_file(options.gifname)
  create_lock_file(options.videoname)

  if is_local_file() then
    process_local_video(start_time_l, end_time_l, with_subtitles, options, get_path(), false)
  else
    download_video_segment(start_time_l, end_time_l, with_subtitles, options)
  end
end

-- Functions for keybindings

local function set_gif_start()
  start_time = mp.get_property_number('time-pos', -1)
  mp.osd_message('GIF Start: ' .. start_time)
end

local function set_gif_end()
  end_time = mp.get_property_number('time-pos', -1)
  mp.osd_message('GIF End: ' .. end_time)
end

local function make_gif_with_subtitles()
  process_gif_request(true)
end

local function make_gif()
  process_gif_request(false)
end

local lower_key = string.lower(default_options.key)
local upper_key = string.upper(default_options.key)
local start_time_key = default_options.keyStartTime ~= '' and default_options.keyStartTime or lower_key
local end_time_key = default_options.keyEndTime ~= '' and default_options.keyEndTime or upper_key
local make_gif_key = default_options.keyMakeGif ~= '' and default_options.keyMakeGif
  or string.format('Ctrl+%s', lower_key)
local make_gif_sub_key = default_options.keyMakeGifSub ~= '' and default_options.keyMakeGifSub
  or string.format('Ctrl+%s', upper_key)

log_verbose(
  '[GIF] Keybindings:',
  dump({
    lower_key,
    upper_key,
    start_time_key,
    end_time_key,
    make_gif_key,
    make_gif_sub_key,
  })
)

mp.add_key_binding(start_time_key, 'set_gif_start', set_gif_start)
mp.add_key_binding(end_time_key, 'set_gif_end', set_gif_end)
mp.add_key_binding(make_gif_key, 'make_gif', make_gif)
mp.add_key_binding(make_gif_sub_key, 'make_gif_with_subtitles', make_gif_with_subtitles)
