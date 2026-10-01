# VLC-Twitch.tv-playlist-parser-2026
Updated Twitch.tv LUA plugin for VLC

[Русский](README.md) | **English**

A VLC playlist script that opens Twitch live channels and VODs directly in VLC.

It replaces the stock `twitch.lua` bundled with VLC 3.0. The stock script relies on the removed `api.twitch.tv/api/*` and Kraken endpoints, and those now fail with HTTP 410. This version uses the same flow as the Twitch web player: a GQL `PlaybackAccessToken` request, followed by the HLS master playlist from `usher.ttvnw.net`.

## Features

- Plays live channels and VODs anonymously. No login, OAuth token or Client-Integrity is required.
- Makes one GQL request per open, which returns the access token and the metadata together (title, channel name, category, online status).
- Fills in VLC metadata: *Title*, *Artist*, *Genre*, *Now Playing* and *Description*.
- Prints clear errors to the VLC log for a missing channel, an offline stream, or a forbidden token (for example a geoblock).
- Starts on the best quality right away. It skips the audio-only variant and uses `adaptive-logic=highest`, so there is no ramp-up from 160p, no demuxer restart and no PCR resync after the stream starts.
- **Handles server-side prerolls.** Without this, VLC 3 shows a black screen with no audio once the ad ends. The script plays the ad as a separate item and then switches to the live stream past the break (see [Preroll ads](#preroll-ads)).
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
- `curl` available on `PATH`. VLC's Lua API can only send GET requests without custom headers, so the GQL POST request is sent through the system `curl`. Playlists (including the live wait after an ad) are fetched by VLC itself, with no external processes.

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

All settings are constants at the top of the script.

### Quality

```lua
local OPTIONS    = { ":adaptive-logic=highest" }
local MAX_HEIGHT = 0
```

`OPTIONS` applies when VLC is given the master playlist (a normal start with no ad, and VODs):

| Value | Behavior |
|---|---|
| `:adaptive-logic=highest` | Default. Plays the best variant from the first segment onward and never steps down |
| `:adaptive-logic=nearoptimal` | Adapts to bandwidth. Better on unstable connections, but may start at a lower quality |
| `:adaptive-logic=highest`, `:adaptive-maxheight=720` | Plays the best variant up to 720p |

`MAX_HEIGHT` applies when the preroll workaround kicks in. VLC is then given a single media playlist of one quality, with nothing to switch to. The script picks the variant with the highest resolution (then frame rate, then bitrate) that does not exceed `MAX_HEIGHT`. `0` means the best available. The order of variants in Twitch's master playlist is not relied on, because it varies.

These options apply only to items this script creates. Global VLC settings are not changed.

### Preroll ads

```lua
local SKIP_PREROLL  = true
local LIVE_DELAY_MS = 4000
local LIVE_MARGIN_S = 1
local AD_CUT_S      = 1
local RESUME_MAX_S  = 30
local PREROLL_MAX_S = 90
```

| Constant | Purpose |
|---|---|
| `SKIP_PREROLL` | `false` disables ad handling, and the script behaves as before |
| `LIVE_DELAY_MS` | Requested distance from the live edge after the ad (`:adaptive-livedelay`) |
| `LIVE_MARGIN_S` | Extra live content required on top of the computed threshold before switching |
| `AD_CUT_S` | How many seconds before its end the ad item is stopped. If a black frame flashes at the end of the ad, raise it to `2` |
| `RESUME_MAX_S` | Maximum wait for the live stream after the ad |
| `PREROLL_MAX_S` | Maximum wait when the ad length is unknown |

## How it works

1. `probe()` checks whether the URL belongs to twitch.tv.
2. `parse()` extracts the channel login or the VOD id from the URL.
3. `gql()` sends a single POST to `https://gql.twitch.tv/gql` through `curl`, with the public web `Client-ID`. It requests:
   - for live channels: `streamPlaybackAccessToken`, plus `user { displayName stream broadcastSettings }`;
   - for VODs: `videoPlaybackAccessToken`, plus `video { title description owner game }`.
4. The script builds the usher URL from the token's `value` and `signature`:
   - live: `https://usher.ttvnw.net/api/channel/hls/<login>.m3u8?...`
   - VOD: `https://usher.ttvnw.net/vod/<id>.m3u8?...`
5. For live channels, the script fetches the master playlist and the selected variant's media playlist, and checks whether the session starts with a stitched ad (`DATERANGE` tags of class `twitch-stitched-ad` and the segment titles).
6. With no ad, it returns a playlist item with the metadata attached, and VLC's `adaptive` demuxer plays the HLS stream from there. With an ad, see below.

The request body contains no string literals, backslashes or newlines. All literal values are passed as GraphQL variables. This lets one quoting routine work safely for both `cmd.exe` and `sh`, without temporary files.

### Preroll workaround

Anonymous tokens have `server_ads: true`, and Twitch stitches ads directly into the HLS stream. The switch from the ad to the live stream is an `EXT-X-DISCONTINUITY` with a large timestamp jump. VLC 3 loses its reference clock there: the log shows `Timestamp conversion failed … no reference clock`, and the screen stays black with no audio.

The script works around this as follows:

1. It returns **two playlist items** instead of one:
   - `[ad]`: the session's media playlist from the first segment, with a `:run-time` that stops playback `AD_CUT_S` seconds before the break. The ad is shown on screen as normal;
   - a helper URL, `https://www.twitch.tv/<channel>?vlcresume=…`, which comes back into this same script.
2. When the ad ends, VLC moves to the second item. The script polls the playlist until enough live segments have accumulated at its end.
3. It then opens the same session at the live edge, past the break.

The wait threshold is based on the actual segment length, not `#EXT-X-TARGETDURATION`. VLC 3 never starts closer than three segments to the live edge, and Twitch sets `TARGETDURATION` to 6 while its segments are 2 s long. Basing the threshold on `TARGETDURATION` added about 15 s of waiting.

If the ad length is unknown (the `DATERANGE` tag has no `DURATION`), the script does not show the ad and quietly waits for the live stream for up to `PREROLL_MAX_S` seconds. If a playlist cannot be read, the script falls back to the normal single-item behavior.

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
| `server-side preroll (Ns announced), playing it first` | An ad was detected and is shown as a separate item |
| `server-side preroll of unknown length, waiting for live` | The ad length is unknown, so the script waits for the live stream without showing the ad |
| `preroll done, switching to live` | The ad finished, and the script is waiting for live segments |
| `live content ready after N poll(s), Ns` | The live stream is ready and VLC opens it (debug level) |
| `variant <N>p chosen` | The quality picked for the preroll workaround (debug level) |
| `live wait timed out, playback may stall at the ad boundary` | The live stream did not appear in time. A black screen is possible; reopen the URL |
| `master playlist unreadable, preroll not handled` / `media playlist unreadable, preroll not handled` | A playlist failed to load, so the script runs without the ad workaround |

**Flatpak / Snap:** check whether curl is visible inside the sandbox:

```sh
flatpak run --command=sh org.videolan.VLC -c 'command -v curl'
snap run --shell vlc -c 'command -v curl'
```

If nothing is printed, use a distro-packaged VLC instead.

## Known limitations

- **Console flash on Windows.** `io.popen` starts `cmd.exe`, so a console window flashes briefly each time a Twitch URL is opened. This is a limitation of VLC's Lua sandbox. The live wait after an ad opens no console.
- **HTML download before the script runs.** VLC downloads the twitch.tv HTML page (~200 KB) before `probe()` is called. Playlist scripts run as stream filters on an already-opened URL, so this cannot be avoided.
- **Pause after the ad.** About 5–6 s of dark screen pass between the end of the ad and the start of the live stream, because VLC 3 cannot start closer than three segments to the live edge.
- **Two playlist entries.** While the ad plays, VLC's playlist shows both `[ad]` and the `?vlcresume=…` helper URL.
- **Several ads in a row.** Only the first ad is shown on screen; for the rest of the break the script waits for the live stream on a dark screen.
- **Mid-roll ads** are not handled and may cause a black screen or a freeze.
- **Subscriber-only content.** Sub-only VODs and streams require an authenticated token, which this script does not support.

## License

GNU General Public License v2.0 or later, the same license as the original VLC script.

Based on the original `twitch.lua` by Marvin Scholz (© 2017 the VideoLAN team). Rewritten in 2026 for the GQL `PlaybackAccessToken` API, with server-side preroll handling added.
