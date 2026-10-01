--[[
Resolve Twitch channel and video URLs to the actual stream URL

 Copyright © 2017 the VideoLAN team

 Author: Marvin Scholz <epirat07 at gmail dot com>

 2026: rewritten for the GQL PlaybackAccessToken API (Helix/Kraken/api.* are gone)
 2026: server-side preroll skipping (VLC 3 can't cross the ad->live discontinuity)
 Author: mmrry <sl2007 at yandex dot com>

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
--]]

local CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
local GQL_URL   = "https://gql.twitch.tv/gql"
local USHER_URL = "https://usher.ttvnw.net"
local IS_WIN    = package.config:sub(1, 1) == "\\"

-- Preroll skipping.
-- Twitch stitches ads into the HLS playlist (server_ads=true in the token).
-- The ad->live switch is an EXT-X-DISCONTINUITY with a large PTS jump, after
-- which VLC 3 loses its reference clock: black screen, no audio.
-- Workaround: wait until the preroll is over and hand VLC the media playlist
-- of the same session, so playback starts at the live edge past the jump.
local SKIP_PREROLL   = true
local LIVE_DELAY_MS  = 6000   -- VLC starts this far behind the live edge (default 15000)
local LIVE_MARGIN_S  = 4      -- extra live content required before handing over
local PREROLL_MAX_S  = 90     -- give up waiting after this long
local POLL_S         = 2      -- playlist poll interval

-- Start on the best variant instead of ramping up from 160p
-- (avoids a demuxer/decoder restart and PCR resync right after start)
local OPTIONS   = { ":adaptive-logic=highest" } --OR :adaptive-logic=nearoptimal

-- No string literals inside queries: the body must stay free of '\' and
-- escaped quotes to survive shell quoting on Windows
local TOKEN_ARGS   = "$platform: String!, $backend: String!, $player: String!"
local TOKEN_PARAMS = "{platform: $platform, playerBackend: $backend, playerType: $player}"

local LIVE_QUERY = [[query($login: String!, ]] .. TOKEN_ARGS .. [[) {
  streamPlaybackAccessToken(channelName: $login, params: ]] .. TOKEN_PARAMS .. [[) {
    value signature authorization { isForbidden forbiddenReasonCode }
  }
  user(login: $login) {
    displayName stream { id } broadcastSettings { title game { displayName } }
  }
}]]

local VOD_QUERY = [[query($id: ID!, ]] .. TOKEN_ARGS .. [[) {
  videoPlaybackAccessToken(id: $id, params: ]] .. TOKEN_PARAMS .. [[) { value signature }
  video(id: $id) { title description owner { displayName } game { displayName } }
}]]

function probe()
    if vlc.access ~= "http" and vlc.access ~= "https" then
        return false
    end
    local host = vlc.path:match("^([%w%.]-)twitch%.tv/[%w_]")
    return host == "" or host == "www." or host == "m." or host == "go."
end

local function fail(msg)
    vlc.msg.err("Twitch: " .. msg)
    return {}
end

-- Copy of the shared OPTIONS plus per-item extras
local function item_options(extra)
    local opts = {}
    for _, v in ipairs(OPTIONS) do opts[#opts + 1] = v end
    for _, v in ipairs(extra or {}) do opts[#opts + 1] = v end
    return opts
end

-- Quote a single shell argument (cmd.exe on Windows, sh elsewhere)
local function quote(s)
    if IS_WIN then
        return '"' .. s:gsub('"', '\\"') .. '"'
    end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function run(cmd)
    local pipe = io.popen(cmd)
    if not pipe then
        return nil
    end
    local out = pipe:read("*a")
    pipe:close()
    return out
end

-- VLC's Lua API can't send POST requests or custom headers,
-- so the GQL call goes through the system curl (bundled with Windows 10+)
local function gql(query, variables)
    local json = require("dkjson")
    variables.platform, variables.backend, variables.player = "web", "mediaplayer", "site"
    local body = json.encode({ query = query:gsub("%s+", " "), variables = variables })
    local cmd  = table.concat({
        "curl -sS --max-time 10",
        "-H", quote("Client-ID: " .. CLIENT_ID),
        "-H", quote("Content-Type: text/plain; charset=UTF-8"),
        "--data-binary", quote(body),
        GQL_URL,
    }, " ")

    local resp = run(cmd)
    if not resp then
        return nil, "failed to run curl"
    end

    local obj, _, err = json.decode(resp)
    if not obj then
        return nil, "bad GQL response: " .. (err or "empty (is curl installed?)")
    end
    if obj.errors then
        return nil, "GQL error: " .. tostring(obj.errors[1].message)
    end
    return obj.data or {}, nil
end

-- Plain GET through curl, optionally after a delay (one process per poll).
-- The URL goes through a curl config file: usher/playlist URLs are full of
-- %XX escapes, which cmd.exe could expand as %VARIABLES%.
-- No --compressed: the curl bundled with Windows is built without zlib, and
-- without Accept-Encoding the playlist servers answer uncompressed.
local function http_get(url, delay)
    local cfg
    if IS_WIN then
        cfg = (os.getenv("TEMP") or os.getenv("TMP") or ".")
            .. "\\vlc_twitch_" .. math.random(99999999) .. ".cfg"
    else
        cfg = os.tmpname()
    end
    local f = io.open(cfg, "w")
    if not f then
        return nil
    end
    f:write('url = "', url, '"\n')
    f:close()

    local prefix = ""
    if delay and delay > 0 then
        if IS_WIN then
            prefix = "ping -n " .. (delay + 1) .. " 127.0.0.1 >nul & "
        else
            prefix = "sleep " .. delay .. "; "
        end
    end

    local body = run(prefix .. "curl -sS --max-time 10 -K " .. quote(cfg))
    os.remove(cfg)
    if not body or body == "" then
        return nil
    end
    return body
end

-- The access token value is a JSON document signed by Twitch
local function decode_token(token)
    local ok, t = pcall(function() return require("dkjson").decode(token.value) end)
    if ok and type(t) == "table" then
        return t
    end
    return nil
end

-- Log ad-related flags the server put into the (signed, immutable) token
local function log_token_flags(t)
    if not t then return end
    local function s(v) return tostring(v) end
    vlc.msg.dbg("Twitch: token server_ads=" .. s(t.server_ads)
        .. " show_ads=" .. s(t.show_ads) .. " hide_ads=" .. s(t.hide_ads)
        .. " turbo=" .. s(t.turbo) .. " subscriber=" .. s(t.subscriber))
end

-- Build usher HLS master playlist URL from an access token
local function usher_url(path, token)
    return USHER_URL .. path .. "?" .. table.concat({
        "sig=" .. token.signature,
        "token=" .. vlc.strings.encode_uri_component(token.value),
        "allow_source=true",
        "playlist_include_framerate=true",
        "player_backend=mediaplayer",
        "p=" .. math.random(9999999),
    }, "&")
end

-- Inspect a Twitch media playlist.
-- Live segments are titled "live" (#EXTINF:2.000,live), stitched ads are not.
local function scan_playlist(pl)
    local segs, has_live = {}, false
    for dur, title in pl:gmatch("#EXTINF:([%d%.]+),([^\r\n]*)") do
        local live = (title == "live")
        has_live = has_live or live
        segs[#segs + 1] = { dur = tonumber(dur) or 0, live = live }
    end

    local tail, all_live = 0, true
    for i = #segs, 1, -1 do
        if not segs[i].live then
            all_live = false
            break
        end
        tail = tail + segs[i].dur
    end

    return {
        count    = #segs,
        has_live = has_live,
        all_live = all_live,
        tail     = tail,   -- seconds of uninterrupted live content at the end
        marked   = pl:find('CLASS="twitch%-stitched%-ad"') ~= nil
                or pl:find('ID="stitched%-ad%-') ~= nil,
    }
end

-- Wait out a server-side preroll; returns the URL VLC should open
-- and extra item options
local function skip_preroll(master_url)
    local master = http_get(master_url)
    -- Twitch lists the source/best variant first
    local variant = master and master:match("#EXT%-X%-STREAM%-INF:[^\n]*\n([^\r\n]+)")
    if not variant then
        vlc.msg.warn("Twitch: no variant in master playlist, preroll not skipped")
        return master_url, {}
    end

    local extra  = { ":adaptive-livedelay=" .. LIVE_DELAY_MS }
    local need   = LIVE_DELAY_MS / 1000 + LIVE_MARGIN_S
    local waited = 0
    local announced = false

    while true do
        local pl = http_get(variant, waited > 0 and POLL_S or 0)
        if not pl then
            vlc.msg.warn("Twitch: media playlist fetch failed, opening as is")
            return variant, extra
        end

        local s = scan_playlist(pl)
        if s.all_live and not s.marked then
            -- no ad in this session at all: keep adaptive streaming via master
            if announced then
                return variant, extra
            end
            return master_url, {}
        end
        if not s.has_live and not s.marked then
            -- segments carry no titles: nothing to judge by
            return master_url, {}
        end
        if s.all_live or s.tail >= need then
            vlc.msg.info(string.format(
                "Twitch: preroll over after ~%ds, starting at live edge", waited))
            return variant, extra
        end

        if not announced then
            vlc.msg.info("Twitch: server-side preroll detected, waiting for live content")
            announced = true
        end
        vlc.msg.dbg(string.format("Twitch: preroll... %d segments, %.1fs live at tail",
            s.count, s.tail))

        if waited >= PREROLL_MAX_S then
            vlc.msg.warn("Twitch: preroll wait timed out, playback may stall at the ad boundary")
            return variant, extra
        end
        waited = waited + POLL_S
    end
end

-- Parse Twitch "t" parameter: 06h53m20s, 1h5m, 90s, 1234 -> seconds
local function parse_timestamp(t)
    if not t or t == "" then return nil end
    if t:match("^%d+$") then return tonumber(t) end
    if not t:match("^[%dhms]+$") then return nil end
    local mult  = { h = 3600, m = 60, s = 1 }
    local total, consumed = 0, 0
    for num, unit in t:gmatch("(%d+)([hms])") do
        total    = total + tonumber(num) * mult[unit]
        consumed = consumed + #num + 1
    end
    if consumed ~= #t or total == 0 then return nil end
    return total
end

local function parse_video(video_id)
    vlc.msg.dbg("Twitch: Loading video url for " .. video_id)

    local data, err = gql(VOD_QUERY, { id = video_id })
    if not data then
        return fail(err)
    end

    local token = data.videoPlaybackAccessToken
    if not token then
        return fail("no access token for video " .. video_id)
    end
    log_token_flags(decode_token(token))

    local extra = {}
    local start = parse_timestamp(vlc.path:match("[?&]t=([%w]+)"))
    if start then
        vlc.msg.dbg("Twitch: starting VOD at " .. start .. "s")
        extra[#extra + 1] = ":start-time=" .. start
    end

    local item = {
        path    = usher_url("/vod/" .. video_id .. ".m3u8", token),
        options = item_options(extra),
        name = "Twitch: " .. video_id,
        url  = vlc.path,
    }

    local video = data.video
    if video then
        item.name        = "Twitch: " .. video.title
        item.artist      = video.owner and video.owner.displayName
        item.description = video.description
        item.genre       = video.game and video.game.displayName
    end

    return { item }
end

local function parse_stream(channel)
    vlc.msg.dbg("Twitch: Loading stream url for " .. channel)

    local data, err = gql(LIVE_QUERY, { login = channel })
    if not data then
        return fail(err)
    end

    local user, token = data.user, data.streamPlaybackAccessToken
    if not user or not token then
        return fail("channel not found: " .. channel)
    end
    if not user.stream then
        return fail(user.displayName .. " is offline")
    end
    if token.authorization and token.authorization.isForbidden then
        return fail("playback forbidden: " .. tostring(token.authorization.forbiddenReasonCode))
    end

    local claims = decode_token(token)
    log_token_flags(claims)

    local path  = usher_url("/api/channel/hls/" .. channel:lower() .. ".m3u8", token)
    local extra = {}
    if SKIP_PREROLL and claims and claims.server_ads == true then
        path, extra = skip_preroll(path)
    end

    local bs   = user.broadcastSettings or {}
    local game = bs.game and bs.game.displayName
    return { {
        path        = path,
        options     = item_options(extra),
        name        = "Twitch: " .. user.displayName,
        artist      = user.displayName,
        nowplaying  = game and (user.displayName .. " playing " .. game),
        genre       = game,
        description = bs.title,
        url         = vlc.path,
    } }
end

function parse()
    local video_id = vlc.path:match("/videos/(%d+)")
    if video_id then
        return parse_video(video_id)
    end

    local channel = vlc.path:match("twitch%.tv/([%w_]+)")
    if not channel then
        return fail("failed to parse channel name from url")
    end
    return parse_stream(channel)
end
