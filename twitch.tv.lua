--[[
Resolve Twitch channel and video URLs to the actual stream URL

 Copyright © 2017 the VideoLAN team

 Author: Marvin Scholz <epirat07 at gmail dot com>
 
 2026: rewritten for the GQL PlaybackAccessToken API (Helix/Kraken/api.* are gone)
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

-- Quote a single shell argument (cmd.exe on Windows, sh elsewhere)
local function quote(s)
    if IS_WIN then
        return '"' .. s:gsub('"', '\\"') .. '"'
    end
    return "'" .. s:gsub("'", "'\\''") .. "'"
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

    local pipe = io.popen(cmd)
    if not pipe then
        return nil, "failed to run curl"
    end
    local body = pipe:read("*a")
    pipe:close()

    local obj, _, err = json.decode(body or "")
    if not obj then
        return nil, "bad GQL response: " .. (err or "empty (is curl installed?)")
    end
    if obj.errors then
        return nil, "GQL error: " .. tostring(obj.errors[1].message)
    end
    return obj.data or {}, nil
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

    local item = {
        path    = usher_url("/vod/" .. video_id .. ".m3u8", token),
        options = OPTIONS,
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

    local bs   = user.broadcastSettings or {}
    local game = bs.game and bs.game.displayName
    return { {
        path        = usher_url("/api/channel/hls/" .. channel:lower() .. ".m3u8", token),
        options     = OPTIONS,
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