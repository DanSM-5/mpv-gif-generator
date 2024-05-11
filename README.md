# MPV GIF generator script

Small script that uses ffmpeg in order to generate GIFs from a chosen part of the playing video.

This script is an extension of the original and forks:
- Original: https://gist.github.com/Ruin0x11/8fae0a9341b41015935f76f913b28d2a
- Forked version from: https://github.com/tyalie/mpv-gif-generator
- Windows support: https://github.com/the-honey/mpv-gif-generator

What's different from the other versions?
- It is cross platform (it should work in windows and linux at least).
- Keybinding is configurable. Default is "g" but you can change it to any A-Z key or set all keybinfings
  manually.
- Supports local videos as well as all videos supported by `yt-dlp`.
- Highly configurable. No that you need to change much from the defaults but you can.

## Dependencies
- ffmpeg
- mpv
- yt-dlp (optional)
- ffprob (optional, should come along ffmpeg)

## Demo
![rice](img/🍚.gif)

## Installation

Copy the lua script into
- `~/.config/mpv/scripts/` for linux (single user)
- `/etc/mpv/scripts` for linux (all users)
- `~/AppData/Roaming/mpv/scripts` for windows (single user)

Script supports cloning the repo into the scripts directory. On windows it may need to have
symlinks enabled.

### Debugging

If errors with ffmpeg occurs these are either logged to the terminal (when `terminal != no`) otherwise to `/tmp/mpv-gif-ffmpeg.<TIMESTAMP>.log`. The `terminal==no` case occurs for example when
starting mpv through the `*.desktop` entry (i.e. file explorer, …)

## Usage

### Keybindings

The script has one key configurable which can be any key from A-Z in the keyboard. The default key is "g" if not configured. The case is insensitive. See the table using the default "g".

| shortcut          | effect                    |
| ----------------- | ------------------------- |
| <kbd>g</kbd>      | set gif start             |
| <kbd>G</kbd>      | set gif end               |
| <kbd>Ctrl+g</kbd> | render gif                |
| <kbd>Ctrl+G</kbd> | render gif with subtitles |

You can of course map any of the 4 keybinfings separately using `keyStartTime`, `keyEndTime`, `keyMakeGif` and `keyMakeGifSub`. Any keybinding not provided will default to the default key (g or any set as `key` in the config).

**Note:** Rendering of gifs with subtitles is a bit limited as only non-bitmap ones are currently supported and the generation can take quite long when the file is in a network share or similar.

### Segments download

For videos played with `yt-dlp` it is required to download the segment of the video first which may take a bit of time. Be patient while the video downloads. You'll see a notification when gif processing starts.

### Changing mode
There are three modes available for configuring the behavior of the extension.

| mode              | behavior                         |
| ----------------- | ---------------------------------|
| <kbd>gif</kbd>    | Create a gif (default)           |
| <kbd>video</kbd>  | Cut and save the resulting video |
| <kbd>all</kbd>    | Do both operatios                |

For any non-valid mode the behavior will be to default to `gif`.

## Output
By default the output directory is `~/mpv-gifs`. This setting can be changed in the config with the key `outputDirectory`.
The output file name is in the format `<VIDEO NAME>_000<MODE INITIAL>.<EXT>`. Full path `~/mpv-gifs/<VIDEO NAME>_000<MODE INITIAL>.<EXT>`.

## Configurations
The script can be configured either by having a `script-opts/gifgen.conf` or using e.g. `--script-opts=gifgen-width=-1`. An example configuration file could be:

```conf
# Default configs

# fps for output (can be -1 for source fps).
fps=-1

# Width of the resulting gif.
width=600

# Leave -1 to automatically determine height or set to customize.
height=-1

# File extension (e.g. mp4 for telegram gifs).
extension=gif

# Gif output directory. It supports mpv expansions: https://mpv.io/manual/master/#paths
outputDirectory=~/mpv-gifs

# Set mode use to work with. Available 'gif', 'video' and 'all'.
mode=gif

# Set keybinding. See more in the table above.
key=g

# Set start time key
keyStartTime=""

# Set end time key
keyEndTime=""

# Make gif keybinding
keyMakeGif=""

# Make gif keybinding with subtitles
keyMakeGifSub=""

# Command used for ffmpeg. Useful if ffmpeg is not in the path. It supports mpv expansions.
ffmpegCmd=ffmpeg

# Command used for ffprog. Useful if ffmpeg is not in the path. It supports mpv expansions.
ffprogCmd=ffprog

# Command used for yt-dlp. Useful if yt-dlp is not in the path. It supports mpv expansions.
ytdlpCmd=yt-dlp

# If adding subtitles and video is played by yt-dlp, this will be passed to yt-dlp to filter
# the language of the subtitles. Default to english only subtitles.
ytdlpSubLang="en.*"

# When cutting a local video you can specify a codec for reencoding the video like "libx256"
# Using "copy" will preserver the original video codec.
# This does not apply to videos played with yt-dlp.
copyVideoCodec="copy"

# When cutting a local video you can specify a codec for reencoding the audio like "aac"
# Using "copy" will preserver the original audio codec.
# This does not apply to videos played with yt-dlp.
copyAudioCodec="copy"

# Add additional logs for debbuging
debug=false

# Either "spline" or "lanczos".
# These are different filters for downscaling.
# See more: https://superuser.com/questions/375718/which-resize-algorithm-to-choose-for-videos/375726#375726
# And: https://www.reddit.com/r/ffmpeg/comments/saxswa/scalezscale_and_lanczosspline
flags="lanczos"

# Pass arbitrary filter strings. It was used when debugging.
# Not recommended to set unless you know what you are doing.
# You can set templates for the formatting of width (%d), height (%d) and flags (%s) in that order.
# You will replace the string: "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=%d:%d:flags=%s"
customFilters=
```

## Known issues

- File names with single and double quotes (`'`, `"`) have scape issues
