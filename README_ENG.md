# VLC-Twitch.tv-playlist-parser-2026
Updated Twitch.tv LUA plugin for VLC

A VLC playlist script that opens Twitch live channels and VODs directly in VLC.

It replaces the stock `twitch.lua` bundled with VLC 3.0. The stock script relies on the removed `api.twitch.tv/api/*` and Kraken endpoints, and those now fail with HTTP 410. This version uses the same flow as the Twitch web player: a GQL `PlaybackAccessToken` request, followed by the HLS master playlist from `usher.ttvnw.net`.

## Features

- Plays live channels and VODs anonymously. No login, OAuth token or Client-Integrity is required.
- Makes one GQL request per open, which returns the access token and the metadata together (title, channel name, category, online status).
- Fills in VLC metadata: *Title*, *Artist*, *Genre*, *Now Playing* and *Description*.
- Prints clear errors to the VLC log for a missing channel, an offline stream, or a forbidden token (for example a geoblock).
- Starts on the best quality right away. It skips the audio-only variant and uses `adaptive-logic=highest`, so there is no ramp-up from 160p, no demuxer restart and no PCR resync after the stream starts.
- Runs on Windows, Linux and macOS.

## Supported URLs

| URL | Result |
|---|---|
| `https://www.twitch.tv/<channel>` | Live stream |
| `https://twitch.tv/<channel>` | Live stream |
| `https://m.twitch.tv/<channel>` | Live stream |
| `https://go.twitch.tv/<channel>` | Live stream |
| `https://www.twitch.tv/videos/<id>` | VOD |

Clips (`clips.twitch.tv`) are not supported and are deliberately left unmatched.

## Requirements

- VLC 3.0.x.
- `curl` available on `PATH`. VLC's Lua API can only send GET requests without custom headers, so the GQL POST request is sent through the system `curl`.

| OS | curl |
|---|---|
| Windows 10 1803+ / 11 | Built in (`C:\Windows\System32\curl.exe`) |
| macOS | Built in (`/usr/bin/curl`) |
| Linux (distro package) | Usually preinstalled. If missing, run `sudo apt install curl` or the equivalent for your distro |
| Linux (Flatpak / Snap) | VLC uses the curl from its sandbox runtime, which may not include one. See [Troubleshooting](#troubleshooting) |

## Installation

Copy `twitch.lua` into your user playlist-scripts directory, creating the directory if needed:

| OS | Path |
|---|---|
| Windows | `%APPDATA%\vlc\lua\playlist\` |
| Linux | `~/.local/share/vlc/lua/playlist/` |
| Linux (Flatpak) | `~/.var/app/org.videolan.VLC/data/vlc/lua/playlist/` |
| Linux (Snap) | `~/snap/vlc/current/.local/share/vlc/lua/playlist/` |
| macOS | `~/Library/Application Support/org.videolan.vlc/lua/playlist/` |

VLC loads user scripts before the bundled ones, so this file takes over from the built-in `twitch.luac` automatically. Restart VLC after installing.

## Usage

- **GUI:** open *Media → Open Network Stream* (`Ctrl+N`) and paste a channel or VOD URL.
- **CLI:**
  ```sh
  vlc https://www.twitch.tv/<channel>
  vlc https://www.twitch.tv/videos/<id>
  ```

## Configuration

Playback options are set in the `OPTIONS` table at the top of the script:

```lua
local OPTIONS = { ":adaptive-logic=highest" }
```

| Value | Behavior |
|---|---|
| `:adaptive-logic=highest` | Default. Plays the best variant from the first segment onward and never steps down |
| `:adaptive-logic=nearoptimal` | Adapts to bandwidth. Better on unstable connections, but may start at a lower quality |
| `:adaptive-logic=highest`, `:adaptive-maxheight=720` | Plays the best variant up to 720p |

These options apply only to items this script creates. Global VLC settings are not changed.

## How it works

1. `probe()` checks whether the URL belongs to twitch.tv.
2. `parse()` extracts the channel login or the VOD id from the URL.
3. `gql()` sends a single POST to `https://gql.twitch.tv/gql` through `curl`, with the public web `Client-ID`. It requests:
   - for live channels: `streamPlaybackAccessToken`, plus `user { displayName stream broadcastSettings }`;
   - for VODs: `videoPlaybackAccessToken`, plus `video { title description owner game }`.
4. The script builds the usher URL from the token's `value` and `signature`:
   - live: `https://usher.ttvnw.net/api/channel/hls/<login>.m3u8?...`
   - VOD: `https://usher.ttvnw.net/vod/<id>.m3u8?...`
5. It returns a playlist item with the metadata attached. VLC's `adaptive` demuxer plays the HLS stream from there.

The request body contains no string literals, backslashes or newlines. All literal values are passed as GraphQL variables. This lets one quoting routine work safely for both `cmd.exe` and `sh`, without temporary files.

## Troubleshooting

Open *Tools → Messages* in VLC, or run `vlc -vv`, and look for lines starting with `Twitch:`.

| Log message | Meaning / fix |
|---|---|
| `bad GQL response: empty (is curl installed?)` | `curl` was not found or produced no output. Install curl, or check that it is on `PATH` |
| `GQL error: ...` | Twitch rejected the query. The API may have changed, so open an issue |
| `channel not found: <name>` | The login is misspelled, or the channel is banned or deleted |
| `<name> is offline` | The channel is not live right now |
| `playback forbidden: <code>` | The token was denied, for example because of a geoblock |
| `no access token for video <id>` | The VOD does not exist or is not public |

**Flatpak / Snap:** check whether curl is visible inside the sandbox:

```sh
flatpak run --command=sh org.videolan.VLC -c 'command -v curl'
snap run --shell vlc -c 'command -v curl'
```

If nothing is printed, use a distro-packaged VLC instead.

## Known limitations

- **Console flash on Windows.** `io.popen` starts `cmd.exe`, so a console window flashes briefly each time a Twitch URL is opened. This is a limitation of VLC's Lua sandbox.
- **HTML download before the script runs.** VLC downloads the twitch.tv HTML page (~200 KB) before `probe()` is called. Playlist scripts run as stream filters on an already-opened URL, so this cannot be avoided.
- **Ads.** Anonymous tokens have `server_ads: true`, so Twitch may stitch ad segments into the stream.
- **Subscriber-only content.** Sub-only VODs and streams require an authenticated token, which this script does not support.

## License

GNU General Public License v2.0 or later, the same license as the original VLC script.

Based on the original `twitch.lua` by Marvin Scholz (© 2017 the VideoLAN team). Rewritten in 2026 for the GQL `PlaybackAccessToken` API.