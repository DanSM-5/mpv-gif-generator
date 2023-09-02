# MPV GIF generator script

Small script that uses ffmpeg in order to generate GIFs from a chosen part of the playing video.

This script is an extension of the original and forks:
- Original: https://github.com/the-honey/mpv-gif-generator
- Forked version from: https://github.com/tyalie/mpv-gif-generator
- Windows support: https://github.com/the-honey/mpv-gif-generator

What's different from the other versions?
- It is cross platform (it should work in windows and linux at least).
- Keybinding is configurable. Default is "g" but you can change it to any A-Z key.

## Caveats
The gif generation only works for files that are accessible in your computer. This means that
videos like the ones played with yt-dlp won't work.

## Dependencies
- ffmpeg
- mpv

## Installation

Copy the lua script into 
- `~/.config/mpv/scripts/` for linux (single user)
- `/etc/mpv/scripts` for linux (all users)
- `~/AppData/Roaming/mpv/scripts` for windows (single user)

### Debugging

If errors with ffmpeg occurs these are either logged to the terminal (when `terminal != no`) otherwise to `/tmp/mpv-gif-ffmpeg.<TIMESTAMP>.log`. The `terminal==no` case occurs for example when
starting mpv through the `*.desktop` entry (i.e. file explorer, …)

## Usage

The script has one key configurable which can be any key from A-Z in the keyboard. The default key is "g" if not configured. The case is insensitive. See the table using the default "g". 

| shortcut          | effect                    |
| ----------------- | ------------------------- |
| <kbd>g</kbd>      | set gif start             |
| <kbd>G</kbd>      | set gif end               |
| <kbd>Ctrl+g</kbd> | render gif                |
| <kbd>Ctrl+G</kbd> | render gif with subtitles |

**Note:** Rendering of gifs with subtitles is a bit limited as only non-bitmap ones are currently supported and the generation can take quite long when the file is in a network share or similar.

## Output
By default the output directory is `~/mpv-gifs`. This setting can be changed in the config with the key `outputDirectory`.
The output file name is in the format `<VIDEO NAME>_000.gif`. Full path `~/mpv-gifs/<VIDEO NAME_000.gif>`.

## Configurations
The script can be configured either by having a `script-opts/gifgen.conf` or using e.g. `--script-opts=gifgen-width=-1`. An example configuration file could be:

```conf
# Default configs

# fps for output (can be -1 for source fps).
fps=15

# Width of the resulting gif.
width=600

# Leave -1 to automatically determine height or set to customize.
height=-1

# File extension (e.g. mp4 for telegram gifs).
extension=gif

# gif output directory. Should support mpv expansions: https://mpv.io/manual/master/#paths
outputDirectory=~/mpv-gifs

# Set keybinding. See more in the table above.
key=g

# Either "spline" or "lanczos".
# These are different filters for downscaling.
# See more: https://superuser.com/questions/375718/which-resize-algorithm-to-choose-for-videos/375726#375726
# And: https://www.reddit.com/r/ffmpeg/comments/saxswa/scalezscale_and_lanczosspline
flags="lanczos"

# Pass arbitrary filter strings. It was used when debugging.
# Not recommended to set unless you know what you are doing.
# Will make 'width', 'height', 'fps', and 'flags' config useless.
# You will replace the string: "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=%d:%d:flags=%s"
customFilters=
```
