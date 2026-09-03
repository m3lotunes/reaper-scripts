-- @description CuePort Sync
-- @version 1.36.0
-- @author CuePort
-- @website https://cueport.app
-- @about
--   # CuePort Sync
--
--   Pulls the comments on a production from CuePort (cueport.app) -- the
--   artist's and the studio's, threads and all -- and drops each one as a
--   colored project marker on the Reaper ruler. Hover a marker to read the
--   full text, and reply to any of them without leaving the DAW. Switch
--   between everything the studio uploaded: instrumental, mix, every version.
--
--   CuePort is the studio platform that sits around your DAW: artists,
--   productions, versions, files, sessions and feedback. Every artist gets
--   their own login, comments pin to the exact second on the waveform, every
--   upload becomes a version, and Spotify stats pull themselves in daily.
--   The mixing stays in your DAW; this script is the Reaper end of it.
--
--   Requirements: ReaImGui (via ReaPack) + curl (bundled with Win 10+,
--   macOS, Linux). SWS and JS_ReaScriptAPI are recommended for the best
--   hover-detection experience.
--
--   Usage: run the action, click "Connect to CuePort", approve in the
--   browser, pick a production and press "Sync comments".
--
--   ## What it changes in your project
--
--   Only when you ask for it, and nothing else is touched:
--   project markers named "CP @author: time", one per comment; a marker
--   "CP: Render start" and the project time offset when you set the render
--   start; a hidden track "CuePort A/B" with one item and a hardware-output
--   send while the A/B reference is loaded, plus its audio file in a folder
--   "CuePort A-B" next to the .rpp; the bound production and a cache of its
--   comments in the project's extension data; and the edit cursor when you
--   click the waveform. Marker sync, render start and removing the A/B track
--   are named undo steps. Nothing from your project is ever uploaded.
--   The same list, in full, is on the script's About screen.
--
--   ## Licence
--
--   MIT. Copyright (c) 2026 melotunesmusic. Provided as is, without warranty
--   of any kind -- see the LICENSE file installed alongside, or the header at
--   the top of the script. Third-party: JSON parsing based on rxi/json.lua
--   (MIT, (c) 2020 rxi); the bundled Inter typeface under the SIL Open Font
--   License 1.1 (Inter-LICENSE.txt).
-- @changelog
--   The full version history lives with the package, not in this file:
--   ReaPack shows the changelog for every version under Extensions ->
--   ReaPack -> Browse packages, and the same list is in index.xml at
--   https://github.com/m3lotunes/reaper-scripts

-- ══════════════════════════════════════════════════════════════════════════════
-- CuePort Sync — Reaper integration for CuePort (https://cueport.app)
--
-- Copyright (c) 2026 melotunesmusic
-- SPDX-License-Identifier: MIT
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
-- THIRD-PARTY NOTICES
--   JSON parser   based on rxi/json.lua — Copyright (c) 2020 rxi, MIT licence
--   Inter         SIL Open Font License 1.1 — full text in Inter-LICENSE.txt,
--                 installed alongside this script
-- ══════════════════════════════════════════════════════════════════════════════

-- Constants live in one table on purpose. Lua caps a function — and the whole
-- file is one — at 200 locals in scope, and this chunk is long enough that a
-- slot per constant is a budget worth keeping.

local K = {}

K.VERSION            = '1.36.0'
K.API_URL = 'https://melotunes-upload.m3lotunes.workers.dev'
-- Das Portal (nicht die API): dort erzeugt das eingeloggte Studio den
-- Pairing-Code, den der Producer hier eintippt.
K.PAIR_URL = 'https://cueport.app/studio/reaper-link.html'

K.EXT_NS                 = 'CuePort'
K.TRACK_MARKER_EXT_KEY   = 'P_EXT:cueport_track'
K.ITEM_FB_ID_EXT_KEY     = 'P_EXT:cueport_feedback_id'
K.AB_TRACK_NAME          = 'CuePort A/B'
-- Marks the hidden A/B reference track. The value is the instance id of the
-- script run that built it, so a track that comes back with a re-opened
-- project (i.e. one that was saved while A/B was loaded) is recognisable as a
-- leftover and can be cleaned out — see AB.cleanupStrays().
K.AB_TRACK_EXT_KEY       = 'P_EXT:cueport_ab_ref'
-- ProjExtState flag: set while WE hold the master muted for the A/B swap, so
-- a project that was saved on the CuePort side can be un-muted again on load.
K.AB_MASTER_MUTE_KEY     = 'ab_master_muted'
-- Folder the reference audio is written to, next to the .rpp.
K.AB_DIR_NAME            = 'CuePort A-B'
-- Cover art lives in the global cache only, never next to the project: unlike the
-- A/B audio it is not a media source the project points at, so nothing breaks when
-- it is not there. Keeping it out of the project folder means we touch nothing the
-- user did not ask us to touch.
K.ART_DIR_NAME           = 'artwork'
K.ART_TILE               = 144  -- side of the cover tile in the production header
-- How far the cover's ring reaches. It cannot simply grow: the tile's right
-- edge IS the card's content edge, and UI.shadow paints through a replacing
-- clip, so anything past the card's inner padding (CARD_PAD_X, 12) minus the
-- ring's own offset (K.SHADOW_DX, 2) lands on the card's border. 10 is that
-- ceiling, and it is where the falloff gets the most room -- what makes a
-- gradient look soft is the number of pixels it has, not its curve.
K.ART_SHADOW             = 10
K.ART_TILE_SMALL         = 24   -- side of the tile in the picker list
K.ART_ROW_H              = 30   -- picker production row, tall enough for that tile
-- Global ExtState slot remembering an audio file that is still referenced by a
-- saved project; it is deleted once that project has been saved without it.
K.AB_ORPHAN_KEY          = 'ab_orphan'

local r = reaper

-- ── Dependency check ────────────────────────────────────────────────────────
if not r.APIExists('ImGui_CreateContext') then
  r.MB(
    'This script requires the ReaImGui extension.\n\n' ..
    'To install:\n1. Extensions → ReaPack → Browse packages\n' ..
    '2. Search "ReaImGui"\n3. Install\n4. Restart Reaper',
    'CuePort Sync', 0)
  return
end

-- JS_ReaScriptAPI powers the transport-attached pill and the window probing
-- behind it. SWS is probed where it is used (dependency banner, mouse-time
-- lookup); curl is verified lazily via the first HTTP call.
local HAS_JS  = r.APIExists('JS_Window_FindChildByID')

-- ══════════════════════════════════════════════════════════════════════════════
-- MINIMAL JSON PARSER
-- Based on rxi/json.lua — Copyright (c) 2020 rxi, MIT licence. The licence
-- requires the copyright notice to travel with the code, so it is named here
-- as well as in the header at the top of this file.
-- ══════════════════════════════════════════════════════════════════════════════
local json = {}
do
  local escape_chars = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

  local function decode_error(_str, idx, msg)
    error('JSON decode error at ' .. idx .. ': ' .. msg, 3)
  end

  local function next_char(str, idx, set, negate)
    for i = idx, #str do
      local in_set = (set:find(str:sub(i,i), 1, true) ~= nil)
      if in_set ~= negate then return i end
    end
    return #str + 1
  end

  local function parse_unicode(n)
    if n < 0x80 then
      return string.char(n)
    elseif n < 0x800 then
      return string.char(0xC0 + math.floor(n/0x40), 0x80 + (n % 0x40))
    elseif n < 0x10000 then
      return string.char(0xE0 + math.floor(n/0x1000),
        0x80 + (math.floor(n/0x40) % 0x40), 0x80 + (n % 0x40))
    else
      return string.char(0xF0 + math.floor(n/0x40000),
        0x80 + (math.floor(n/0x1000) % 0x40),
        0x80 + (math.floor(n/0x40) % 0x40),
        0x80 + (n % 0x40))
    end
  end

  local function parse_string(str, i)
    local res = ''
    local j = i + 1
    local k = j
    while j <= #str do
      local c = str:byte(j)
      if c < 32 then
        decode_error(str, j, 'control char in string')
      elseif c == 92 then -- '\'
        res = res .. str:sub(k, j-1)
        j = j + 1
        local ec = str:sub(j,j)
        if ec == 'u' then
          local hex = str:sub(j+1, j+4)
          local n = tonumber(hex, 16)
          if not n then decode_error(str, j, 'bad unicode escape') end
          -- surrogate pair handling
          if n >= 0xD800 and n <= 0xDBFF then
            if str:sub(j+5, j+6) ~= '\\u' then
              decode_error(str, j, 'bad surrogate')
            end
            local n2 = tonumber(str:sub(j+7, j+10), 16)
            if not n2 then decode_error(str, j, 'bad surrogate') end
            n = 0x10000 + (n - 0xD800) * 0x400 + (n2 - 0xDC00)
            j = j + 10
          else
            j = j + 4
          end
          res = res .. parse_unicode(n)
        elseif escape_chars[ec] then
          res = res .. escape_chars[ec]
        else
          decode_error(str, j, 'bad escape')
        end
        j = j + 1
        k = j
      elseif c == 34 then -- '"'
        res = res .. str:sub(k, j-1)
        return res, j + 1
      else
        j = j + 1
      end
    end
    decode_error(str, i, 'unterminated string')
  end

  local function parse_number(str, i)
    local j = next_char(str, i, '0123456789+-.eE', true)
    local num = tonumber(str:sub(i, j-1))
    if not num then decode_error(str, i, 'bad number') end
    return num, j
  end

  local function parse_literal(str, i)
    if str:sub(i, i+3) == 'true' then return true, i+4 end
    if str:sub(i, i+4) == 'false' then return false, i+5 end
    if str:sub(i, i+3) == 'null' then return nil, i+4 end
    decode_error(str, i, 'bad literal')
  end

  local parse  -- forward
  local function parse_array(str, i)
    local res, k = {}, 1
    i = i + 1
    i = next_char(str, i, ' \t\r\n', true)
    if str:sub(i, i) == ']' then return res, i+1 end
    while true do
      local val
      val, i = parse(str, i)
      res[k] = val
      k = k + 1
      i = next_char(str, i, ' \t\r\n', true)
      local c = str:sub(i, i)
      i = i + 1
      if c == ']' then return res, i end
      if c ~= ',' then decode_error(str, i, "expected ',' or ']'") end
    end
  end

  local function parse_object(str, i)
    local res = {}
    i = i + 1
    i = next_char(str, i, ' \t\r\n', true)
    if str:sub(i, i) == '}' then return res, i+1 end
    while true do
      i = next_char(str, i, ' \t\r\n', true)
      if str:sub(i, i) ~= '"' then decode_error(str, i, 'expected string key') end
      local key
      key, i = parse_string(str, i)
      i = next_char(str, i, ' \t\r\n', true)
      if str:sub(i, i) ~= ':' then decode_error(str, i, "expected ':'") end
      i = next_char(str, i + 1, ' \t\r\n', true)
      local val
      val, i = parse(str, i)
      res[key] = val
      i = next_char(str, i, ' \t\r\n', true)
      local c = str:sub(i, i)
      i = i + 1
      if c == '}' then return res, i end
      if c ~= ',' then decode_error(str, i, "expected ',' or '}'") end
    end
  end

  parse = function(str, i)
    i = next_char(str, i, ' \t\r\n', true)
    local c = str:sub(i, i)
    if c == '{' then return parse_object(str, i)
    elseif c == '[' then return parse_array(str, i)
    elseif c == '"' then return parse_string(str, i)
    elseif c == '-' or c:match('%d') then return parse_number(str, i)
    else return parse_literal(str, i) end
  end

  function json.decode(str)
    if type(str) ~= 'string' then return nil, 'not a string' end
    local ok, result = pcall(function()
      local res, _ = parse(str, 1)
      return res
    end)
    if not ok then return nil, tostring(result) end
    return result
  end

  function json.encode(v)
    local t = type(v)
    if t == 'nil' then return 'null' end
    if t == 'boolean' then return v and 'true' or 'false' end
    if t == 'number' then return tostring(v) end
    if t == 'string' then
      return '"' .. v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t') .. '"'
    end
    if t == 'table' then
      local parts = {}
      local isArr = (#v > 0) or (next(v) == nil)
      if isArr then
        for i = 1, #v do parts[i] = json.encode(v[i]) end
        return '[' .. table.concat(parts, ',') .. ']'
      else
        for k, val in pairs(v) do
          parts[#parts+1] = json.encode(tostring(k)) .. ':' .. json.encode(val)
        end
        return '{' .. table.concat(parts, ',') .. '}'
      end
    end
    return 'null'
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- STORAGE (persistent across Reaper sessions and projects)
-- ══════════════════════════════════════════════════════════════════════════════

local function getGlobalExt(key)    return r.GetExtState(K.EXT_NS, key) end
local function setGlobalExt(key, v) r.SetExtState(K.EXT_NS, key, v or '', true) end
local function delGlobalExt(key)    r.DeleteExtState(K.EXT_NS, key, true) end

local function getProjExt(key)
  local ok, val = r.GetProjExtState(0, K.EXT_NS, key)
  return ok == 1 and val ~= '' and val or nil
end
local function setProjExt(key, v) r.SetProjExtState(0, K.EXT_NS, key, v or '') end

-- ══════════════════════════════════════════════════════════════════════════════
-- HTTP (via curl through reaper.ExecProcess — cross-platform)
-- ══════════════════════════════════════════════════════════════════════════════

local function isWindows() return r.GetOS():find('Win') ~= nil end
local function pathSep() return isWindows() and '\\' or '/' end

-- Zitieren fuer die Shell, an die `ExecProcess` seine Zeile uebergibt.
--
-- POSIX: alles in einfache Anfuehrungszeichen, ein einfaches
-- Anfuehrungszeichen im Wert wird zu '\'' -- danach ist jedes Zeichen
-- woertlich, auch ; | & $ und der Backtick. In doppelten waeren $, ` und
-- der Rueckstrich weiterhin aktiv.
local function shQuote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

-- Ein Pfad fuer die Kommandozeile. Unter Windows fuehrt `cmd.exe` einfache
-- Anfuehrungszeichen NICHT als Zitat, sie wuerden Teil des Dateinamens --
-- dort also doppelte, in denen & | < > ^ ohnehin woertlich sind, und ein "
-- kann in einem Windows-Dateinamen gar nicht vorkommen.
local function pathQuote(path)
  if isWindows() then return '"' .. path .. '"' end
  return shQuote(path)
end

-- Ablage der temporaeren curl-Dateien (Konfiguration, Antwort, Downloads).
--
-- Sie liegen in REAPERs eigenem Ressourcenverzeichnis, also im Verzeichnis
-- des angemeldeten Benutzers, nicht in einer gemeinsamen Ablage des Rechners.
-- Der Name traegt zusaetzlich einen Zufallsteil je Lauf, damit zwei
-- gleichzeitig laufende REAPER-Instanzen einander nicht ins Gehege kommen.
--
-- Jede Verwendung eines solchen Pfades steht in Anfuehrungszeichen; die
-- frueher noetige Ruecksicht auf Pfade ohne Leerzeichen entfaellt damit.
local TMP_TAG = (function()
  local seed = math.floor((r.time_precise and r.time_precise() or os.clock()) * 1000) + os.time()
  math.randomseed(seed % 2147483647)
  return string.format('%08x%06x', seed % 0xffffffff, math.random(0, 0xffffff))
end)()

local function tmpPath(suffix)
  return r.GetResourcePath() .. pathSep() .. 'cueport_tmp_' .. TMP_TAG .. '_' .. suffix
end


-- Directory part of a full path ('' when there is none).
local function dirNameOf(path)
  return (path or ''):match('^(.*)[/\\][^/\\]*$') or ''
end

local function baseNameOf(path)
  return (path or ''):match('([^/\\]*)$') or ''
end

local function fileSize(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local sz = f:seek('end')
  f:close()
  return sz
end

local function curlBinary()
  -- Reaper on macOS/Linux doesn't inherit login-shell PATH → use absolute path
  if isWindows() then return 'curl.exe' end
  -- macOS ships curl at /usr/bin/curl; some Linux distros at /usr/bin/curl too
  local candidates = { '/usr/bin/curl', '/usr/local/bin/curl', '/opt/homebrew/bin/curl' }
  for _, p in ipairs(candidates) do
    local f = io.open(p, 'r')
    if f then f:close(); return p end
  end
  return 'curl'  -- last resort
end

-- Die curl-Zeile. Der Programmname ist eine der vier fest eingetragenen
-- Zeichenketten aus `curlBinary` und bleibt unter Windows unzitiert, wie
-- gehabt; zitiert wird der Pfad, der aus `GetResourcePath` stammt.
local function curlCfgCmd(cfgPath)
  local bin = curlBinary()
  if not isWindows() then bin = shQuote(bin) end
  return bin .. ' --config ' .. pathQuote(cfgPath)
end

-- Check whether curl is callable from Reaper's ExecProcess context. Runs
-- "curl --version" once and caches the result (exec is not free, ~50-200ms).
-- Returns: ok (bool), versionLine (string or nil)
local _curlCheck = nil
local function checkCurl(force)
  if _curlCheck ~= nil and not force then return _curlCheck.ok, _curlCheck.version end
  local bin = curlBinary()
  if not isWindows() then bin = shQuote(bin) end
  local cmd = bin .. ' --version'
  local raw = r.ExecProcess(cmd, 3000)
  local ok, version = false, nil
  if raw then
    -- raw format: "<returncode>\n<stdout>"
    local nl = raw:find('\n')
    local body = nl and raw:sub(nl + 1) or raw
    local first = body:match('([^\r\n]+)')
    if first and first:find('^curl ') then
      ok = true
      version = first
    end
  end
  _curlCheck = { ok = ok, version = version }
  return ok, version
end

local function writeFile(path, content)
  local f = io.open(path, 'wb')
  if not f then return false end
  f:write(content or '')
  f:close()
  return true
end

local function readFile(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local c = f:read('*a')
  f:close()
  return c
end

local function deleteFile(path) os.remove(path) end

-- Parse the output of reaper.ExecProcess: "<returncode>\n<stdout+stderr>"
local function parseExecOutput(out)
  if not out then return -1, '' end
  local nl = out:find('\n')
  if not nl then return tonumber(out) or 0, '' end
  local code = tonumber(out:sub(1, nl - 1)) or 0
  local body = out:sub(nl + 1)
  return code, body
end

-- Escape a value that goes between double quotes in a curl config file. In its
-- own words: inside quotes "the following escape sequences are available: \\,
-- \", \t, \n, \r and \v. A backslash preceding any other letter is ignored."
-- A Windows path is nothing but backslashes, so C:\Users\tom\... goes in and
-- C:Users<TAB>om\... comes back out -- the file then lands somewhere else than
-- where we look for it, with curl reporting success. On macOS and Linux there
-- are no backslashes in a path, which is why this never showed there.
local function cfgQ(s)
  return (tostring(s or ''):gsub('\\', '\\\\'):gsub('"', '\\"'))
end

-- What curl exited with, in words. Only the codes that can really happen to this
-- script, and only because "exit 35" tells a producer nothing about what to do
-- next. The number is kept either way: it is the part I can look up.
local CURL_WHY = {
  [6]  = 'the host could not be resolved',
  [7]  = 'the connection was refused',
  [18] = 'the transfer ended early',
  [28] = 'it timed out',
  [35] = 'the TLS handshake failed',
  [52] = 'the server answered nothing',
  [55] = 'sending the data failed',
  [56] = 'receiving the answer failed',
  [60] = 'the certificate could not be verified',
}
local function curlWhy(exitCode)
  local why = CURL_WHY[exitCode]
  return 'no answer (curl ' .. tostring(exitCode) .. (why and (': ' .. why) or '') .. ')'
end

-- Perform an HTTP request using a curl config file (avoids shell-escape hell).
-- Returns: status_code (number), body (string), error (string or nil)
-- `opts.maxTime` overrides the 30 s ceiling, `opts.bodyFile` sends a file that
-- is already on disk instead of a string. Both exist for one caller: an upload
-- part is megabytes, not a JSON line -- thirty seconds is not enough for it, and
-- copying it through a Lua string into a second temp file would double the
-- writing for nothing.
local function httpRequest(method, url, headers, bodyStr, opts)
  opts = opts or {}
  local cfgPath  = tmpPath('req.cfg')
  local bodyPath = tmpPath('req.body')
  local respPath = tmpPath('resp.body')
  local maxTime  = opts.maxTime or 30

  -- Write body if present
  if opts.bodyFile then
    bodyPath = opts.bodyFile
  elseif bodyStr and #bodyStr > 0 then
    if not writeFile(bodyPath, bodyStr) then
      return nil, nil, 'Failed to write body temp file'
    end
  end

  -- Build curl config file
  local cfg = { '--silent', '--show-error', '--connect-timeout 10',
                '--max-time ' .. tostring(math.floor(maxTime)) }
  cfg[#cfg+1] = '--request ' .. method
  for k, v in pairs(headers or {}) do
    cfg[#cfg+1] = 'header = "' .. cfgQ(k .. ': ' .. v) .. '"'
  end
  if opts.bodyFile or (bodyStr and #bodyStr > 0) then
    cfg[#cfg+1] = 'data-binary = "@' .. cfgQ(bodyPath) .. '"'
  end
  -- Write status code on its own line at the end of the body file
  cfg[#cfg+1] = 'output = "' .. cfgQ(respPath) .. '"'
  cfg[#cfg+1] = 'write-out = "\\n__CUEPORT_STATUS__:%{http_code}"'
  cfg[#cfg+1] = 'url = "' .. cfgQ(url) .. '"'

  if not writeFile(cfgPath, table.concat(cfg, '\n')) then
    return nil, nil, 'Failed to write curl config'
  end

  -- Execute curl
  local curlCmd = curlCfgCmd(cfgPath)
  local raw = r.ExecProcess(curlCmd, math.floor(maxTime * 1000) + 5000)
  local exitCode, curlOut = parseExecOutput(raw)

  local body = readFile(respPath) or ''
  -- Status code was appended to stdout (write-out), not the output file
  local status = curlOut:match('__CUEPORT_STATUS__:(%d+)')
  status = tonumber(status)

  -- Cleanup
  deleteFile(cfgPath)
  if bodyStr and not opts.bodyFile then deleteFile(bodyPath) end
  deleteFile(respPath)

  -- `%{http_code}` is 000 when curl never got an answer at all -- a refused
  -- connection, a dropped handshake, a timeout, a connection that died halfway
  -- through the body. That is not status zero: there is no such status. Read as
  -- one it came out of the upload page as "Stopped: HTTP 0", which names
  -- nothing and leaves nothing to try. Same branch as no status line at all,
  -- and curl's exit code is what actually says what happened.
  if not status or status == 0 then
    return nil, body, curlWhy(exitCode)
  end

  return status, body, nil
end

-- Convenience wrappers
local function httpGET(url, headers)
  return httpRequest('GET', url, headers, nil)
end

local function httpPOST(url, headers, bodyTbl)
  headers = headers or {}
  headers['Content-Type'] = 'application/json'
  return httpRequest('POST', url, headers, json.encode(bodyTbl or {}))
end


-- ══════════════════════════════════════════════════════════════════════════════
-- HOVER TOOLTIP STATE (declared early so UI.footer/UI.hoverTip both see
-- it as an upvalue; Lua resolves function-body references at function-creation
-- time, so the local must exist before any function body that references it).
-- ══════════════════════════════════════════════════════════════════════════════

local hover = { enabled = true }
do
  local v = getGlobalExt('hover_enabled')
  if v == '0' then hover.enabled = false end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- APPLICATION STATE
-- ══════════════════════════════════════════════════════════════════════════════

local state = {
  screen = 'init',  -- init, login, pairing, main, error

  -- API / auth
  apiUrl = K.API_URL,
  -- What the worker we are talking to says it can do, taken from the answer
  -- of every productions/comments call. Empty means "it did not say", which
  -- is what a build from before the capability list looks like.
  --
  -- This is how a route can differ WITHOUT a setting: a switch has to be
  -- found, understood and turned back off, and one left on quietly sends
  -- real work to a build nobody signed off. Asking the worker needs no
  -- maintenance at either end -- the day production lists a capability,
  -- the deviation stops by itself and there is nothing here to remove.
  apiFeatures = {},
  token = nil,

  -- Pairing
  deviceCode = nil,
  userCode = nil,
  verificationUrl = nil,
  pollInterval = 3,
  lastPoll = 0,
  pairingExpiresAt = 0,

  -- Productions list
  productions = nil,
  productionsFetching = false,
  productionsError = nil,
  filterText = '',

  -- Binding (from current project). activeProject/lastBindingCheck let the
  -- persistent loop notice project switches (and late-loading projects) and
  -- re-read the per-project binding accordingly.
  boundProductionId = nil,
  boundProduction = nil,
  activeProject = nil,
  lastBindingCheck = nil,
  -- Layout measurements taken one level above where they are used. bodyAvailH
  -- is how much room the window leaves below the header; pickerShowing keeps
  -- the picker's content height out of the window's minimum, because that
  -- screen is built to fill the window and the two would chase each other.
  bodyAvailH = nil,
  pickerShowing = false,
  -- Which screen the floor measurement last saw. A child that resizes to its
  -- own content reports the size ImGui worked out from the previous frame, so
  -- the first frame after a switch still carries the old page's height -- and
  -- feeding that into the floor is how coming back from About grew the window.
  prevFloorKey = nil,
  -- Cached file counts for the A/B storage rows in Settings, held for a second
  -- so that screen does not walk two directories on every frame.
  abStats = nil,
  -- Which production this session has already put markers on the ruler for.
  -- The markers come off when the script exits, so every run has to place them
  -- once -- and switching to another project tab is another once.
  markersPlacedFor = nil,

  -- Sync
  syncInProgress = false,
  syncStatus = '',
  lastSyncResult = nil,
  lastSyncAt = nil,

  -- Every version the production has, as GET /reaper/comments lists them, and
  -- which one is open. The id is persisted per project (K.VERSION_KEY), so a
  -- project reopened tomorrow is still on the version it was left on -- unless
  -- that version is gone from CuePort, in which case the server falls back and
  -- the answer it sends back is adopted.
  versions = nil,
  versionsForId = nil,
  -- Which binding the persisted list has already been looked for under, so a
  -- production without one does not re-read the project file every frame.
  versionsTriedFor = nil,
  selectedVersionId = nil,
  -- Which kind was pressed in the picker, until the first sync answers with a
  -- version id. Not persisted: it is a question, not a setting.
  pendingTrackType = nil,
  -- Set while a version switch is in flight, holding what to fall back to if
  -- the request for the new one fails.
  versionSwitchFrom = nil,

  -- Replying from the DAW. `replyTo` is the comment key the box is open under,
  -- `replyPending` is a send waiting for the loop -- the request blocks for as
  -- long as curl takes, so it must not happen inside the frame the button was
  -- clicked in.
  replyTo = nil,
  replyText = '',
  -- Der eingetippte Pairing-Code (umgekehrter Flow). Jedes Bild uebernommen.
  pairCode = '',
  -- Set when the box is opened, cleared the frame the field takes the keyboard.
  -- One shot: asking for focus on every frame would take it back the moment the
  -- user clicked anywhere else, including into the field itself.
  replyFocus = false,
  replyPending = nil,
  -- The comment column's status line: it reports both sending and deleting,
  -- because there is one line and only one of the two can be in flight.
  -- `replyStatusAt` is when it was set and `replyStatusHold` marks the ones
  -- that must NOT time out -- a failure is the one message worth keeping until
  -- the next action, because it is the only place the reason is written down.
  replyStatus = nil,
  replyStatusAt = 0,
  replyStatusHold = false,

  -- Deleting from the DAW. Two steps on purpose: `delArm` holds the comment
  -- key whose control is asking "Sure?", and only a second press queues
  -- `delPending`. The control sits a few pixels from Reply on a row that only
  -- lights up under the mouse, and this is the one action here that cannot be
  -- undone.
  delArm = nil,
  delPending = nil,

  -- Waveform (peaks + duration for the active version, from /reaper/comments)
  waveform = nil,        -- { peaks = {float...}, duration = number|nil }
  waveformForId = nil,   -- productionId the cached waveform belongs to
  -- Loudness/dynamics of the active version, as GET /reaper/comments returns
  -- them. nil when the worker predates the metrics field, when the version was
  -- uploaded before CuePort analysed at all, or when nothing has synced yet --
  -- all three look the same from here and all three mean "show nothing".
  metrics = nil,
  -- The comment list on the left, and which comment the mouse is over in the
  -- waveform. The second one is written while the strip renders and read while
  -- the list renders -- the list comes first in the frame, so it is always one
  -- frame behind. At 30+ fps that is invisible, and the alternative (measuring
  -- the strip before drawing the list) would mean laying the waveform out
  -- twice.
  commentsOpen = false,
  hoverCommentId = nil,
  -- And the other way round: which row the mouse is over in the list, so the
  -- pin out on the strip can light up with it. This one is NOT a frame behind
  -- -- the list is laid out before the body that holds the waveform, so the
  -- value is written and read inside the same frame. It has to be its own
  -- field: sharing `hoverCommentId` would mean the strip overwrites the list's
  -- answer with its own every frame, and nothing would ever light.
  hoverRowCommentId = nil,
  -- Which comment the column has already scrolled to, so hovering a pin brings
  -- its row into view once rather than re-centring it on every frame.
  cmtScrollTo = nil,
  -- Where each comment row landed last frame, so a click can be tested against
  -- it. Built by the list itself; see UI.commentList for why it has to be the
  -- previous frame's rectangle.
  cmtRects = nil,
  -- ...and where that row's controls landed, so the same click can be told
  -- apart from a click on a control. Kept beside the row rectangles because it
  -- has to be the previous frame's answer for the same reason.
  cmtCtl = nil,
  pendingSeekAt = nil,   -- audio-time of a click that is waiting for the play
                         -- cursor to catch up (Reaper defers seek to next bar)
  versionFilename = nil, -- filename of the active version (for the file ext)
  versionId = nil,       -- id of the active version (cache key for the A/B audio)

  -- A/B compare: hidden reference track playing the CuePort version straight
  -- to the soundcard (bypassing the project master), toggled against the DAW.
  ab = {
    loaded     = false,  -- reference track + item exist
    onCuePort  = false,  -- true = hearing CuePort version, false = hearing DAW
    forId      = nil,    -- productionId the loaded reference belongs to
    forVersion = nil,    -- and which version of it: switching version has to
                         -- invalidate the reference, or the A/B would be
                         -- against a mix that is no longer on screen
    downloading= false,  -- a download/build is in progress
    pendingLoad= false,  -- click queued; do the blocking work next frame
    frameShown = false,  -- the "loading…" frame has been painted once
    status     = nil,    -- last status / error string
    tempPath   = nil,    -- reference audio file on disk
    persisted  = false,  -- the project was saved while the reference existed →
                         -- the .rpp on disk points at tempPath, so the file
                         -- must outlive the reference track
  },

  -- Project save detection (IsProjectDirty 1 → 0). Drives the A/B file
  -- bookkeeping: a save is what turns our audio file into something a project
  -- on disk depends on.
  lastDirty = nil,
  lastStrayCheck = nil,

  -- Error
  errorMsg = nil,

  -- UI
  showDebug = false,

  -- Docking (main window). dockId 0 = floating, negative = a Reaper docker.
  -- lastDockId remembers which docker to reattach to when re-enabling docking.
  -- pendingDock, when set, is applied to the next frame (nil = leave as-is so
  -- the user can freely drag-dock/undock without us fighting them each frame).
  mainDocked = false,
  dockId     = 0,
  lastDockId = -1,
  pendingDock = nil,
}

-- Load persisted state
local function loadState()
  state.apiUrl = K.API_URL
  state.apiFeatures = {}
  state.studioName = getGlobalExt(K.STUDIO_NAME_KEY)

  -- One-time migration: older script versions stored the token under a
  -- host-specific key (`token_prod` / `token_preview`). Migrate whichever
  -- is present over to the canonical `token` key so users don't have to
  -- re-pair after updating.
  -- Remembered across sessions: reopening the window should not silently undo
  -- a choice about how the screen is laid out.
  state.commentsOpen = getGlobalExt(K.COMMENTS_OPEN_KEY) == '1'
  state.token = getGlobalExt('token')
  if state.token == '' or state.token == nil then
    local legacy = getGlobalExt('token_prod')
    if legacy == '' or legacy == nil then legacy = getGlobalExt('token_preview') end
    if legacy and legacy ~= '' then
      setGlobalExt('token', legacy)
      delGlobalExt('token_prod')
      delGlobalExt('token_preview')
      delGlobalExt('use_preview')
      state.token = legacy
    end
  end
  if state.token == '' then state.token = nil end

  -- Project binding
  state.boundProductionId = getProjExt('production_id')
  local vid = getProjExt(K.VERSION_KEY)
  state.selectedVersionId = (vid ~= '' and vid) or nil
end

local function saveToken(tok)
  if tok then setGlobalExt('token', tok) else delGlobalExt('token') end
  state.token = tok
end

-- ══════════════════════════════════════════════════════════════════════════════
-- API WRAPPERS (calls against /reaper/* endpoints)
-- ══════════════════════════════════════════════════════════════════════════════

local function authHeaders()
  if not state.token then return {} end
  return { ['Authorization'] = 'Bearer ' .. state.token }
end

-- Das Plugin tauscht den vom Studio erzeugten Code gegen ein Token. Der Code ist
-- schon beim Erzeugen an das Studio gebunden, es gibt keinen Freigabe-Schritt.
local function apiPairingClaim(userCode)
  local status, body, err = httpPOST(state.apiUrl .. '/reaper/pairing/claim', nil,
    { user_code = userCode, name = 'Reaper' })
  if not status then return nil, err end
  local parsed = json.decode(body)
  if not parsed then return nil, 'Invalid JSON from server' end
  parsed._http_status = status
  return parsed
end

local function apiDeviceStart()
  local status, body, err = httpPOST(state.apiUrl .. '/reaper/device/start', nil, {})
  if not status then return nil, err end
  if status ~= 200 then return nil, 'HTTP ' .. status .. ': ' .. body end
  return json.decode(body)
end

local function apiDevicePoll(deviceCode)
  local status, body, err = httpPOST(state.apiUrl .. '/reaper/device/poll', nil, { device_code = deviceCode })
  if not status then return nil, err end
  local parsed = json.decode(body)
  if not parsed then return nil, 'Invalid JSON from server' end
  parsed._http_status = status
  return parsed
end

-- Where the data endpoints are answered.
--
-- Normally the production worker, and that is the only host this script talks
-- to once CuePort has caught up with it. The exception is the window where the
-- script is ahead of what is deployed: a version of this file that asks for
-- versions, threads and replies, against a worker that does not know them yet.
--
-- This is not a matter of secrets. Both workers run in the same Cloudflare
-- account and read the same database, so the device token is valid on either
-- one and nothing leaves that account by asking the other. What it IS, is
-- talking to a build nobody released -- so it is never silent: the sync line
-- says which host answered.
--
-- Recognised on a POSITIVE signal, never on an error. The new worker always
-- sends a `versions` list with the comments and `track_types` with the
-- productions; the old one sends neither. An error code would be useless here:
-- the old worker answers the new comment endpoint with exactly the 401 that an
-- expired token produces, so falling back on 401 would reroute every genuine
-- token expiry.
--
-- Production is asked FIRST on every probe. The day it carries this code the
-- second call stops happening by itself, which is why this needs no taking out
-- and cannot quietly become the normal path.
K.API_URL_PREVIEW = 'https://melotunes-preview.m3lotunes.workers.dev'

-- Run `attempt(base)` against production, and against the preview worker only
-- if production answered like a build from before this feature. `isNew` is what
-- "the new one answered" looks like for that particular call.
--
-- A production worker that does not answer at all (network down, revoked token)
-- is NOT a reason to ask the other one: its answer is returned as it is, so a
-- dead connection stays one error rather than becoming two waits.
local function apiTry(attempt, isNew)
  local resp, err = attempt(K.API_URL)
  if not resp then return resp, err end
  if isNew(resp) then
    state.apiUrl = K.API_URL
    return resp, err
  end
  if not K.API_URL_PREVIEW or K.API_URL_PREVIEW == K.API_URL then return resp, err end
  local alt, aerr = attempt(K.API_URL_PREVIEW)
  if alt and isNew(alt) then
    state.apiUrl = K.API_URL_PREVIEW
    return alt, aerr
  end
  return resp, err   -- production's answer is still the one that counts
end

-- Remember what the worker said it can do. Every productions/comments answer
-- carries the list; an answer without one is a build from before it existed,
-- and that is exactly the case this is here to notice.
local function apiNoteFeatures(res)
  if type(res) ~= 'table' then return end
  local set = {}
  if type(res.features) == 'table' then
    for _, f in ipairs(res.features) do set[tostring(f)] = true end
  end
  state.apiFeatures = set
end

local function apiProductions()
  local function attempt(base)
    local status, body, err = httpGET(base .. '/reaper/productions', authHeaders())
    if not status then return nil, err end
    if status == 401 then return nil, 'unauthorized' end
    if status ~= 200 then return nil, 'HTTP ' .. status end
    local parsed = json.decode(body)
    if not parsed or not parsed.productions then return nil, 'Bad response' end
    return parsed, nil
  end
  -- `res`, not `r`: `r` is this file's alias for the whole Reaper API, and a
  -- parameter of that name would shadow it inside the callback.
  local resp, err = apiTry(attempt, function(res)
    -- An empty studio cannot say either way, so it counts as current: there is
    -- nothing the older worker would have answered differently.
    if #res.productions == 0 then return true end
    for _, p in ipairs(res.productions) do
      if p.track_types ~= nil then return true end
    end
    return false
  end)
  if not resp then return nil, err end
  apiNoteFeatures(resp)
  -- The studio's name comes back with every sync now, not only with the
  -- pairing. Devices paired before the header showed it have nothing stored,
  -- and a studio that renames itself would otherwise keep the old name for
  -- ever. Only overwritten when the worker actually said something -- an older
  -- worker omits the field, and blanking a good name over that would put
  -- CONNECTED back.
  if type(resp.studio_name) == 'string' and resp.studio_name ~= '' then
    if resp.studio_name ~= state.studioName then
      state.studioName = resp.studio_name
      setGlobalExt(K.STUDIO_NAME_KEY, state.studioName)
    end
  end
  return resp.productions
end

-- `versionId` is optional: without it the server hands back the version it
-- always did (newest mixmaster), which is what a project that has never chosen
-- one should see. With it, that exact version -- and if it has since been
-- deleted in CuePort the server falls back and says so in its answer, which is
-- why the caller adopts `resp.version.id` rather than trusting what it asked
-- for.
local function apiComments(productionId, versionId, trackType)
  local function attempt(base)
    local url = base .. '/reaper/comments?production_id=' .. productionId
    if versionId and versionId ~= '' then
      url = url .. '&version_id=' .. versionId
    elseif trackType and trackType ~= '' then
      -- No version chosen yet, but a kind was: the server answers with the
      -- newest of that kind, which is what pressing "Instrumental" in the
      -- picker means.
      url = url .. '&track_type=' .. trackType
    end
    local status, body, err = httpGET(url, authHeaders())
    if not status then return nil, err end
    if status == 401 then return nil, 'unauthorized' end
    if status == 404 then return nil, 'production not found' end
    if status ~= 200 then return nil, 'HTTP ' .. status end
    return json.decode(body), nil
  end
  -- `versions` is the signal: the new worker always sends the list (an empty
  -- one for a production with no uploads), the old one has no such field.
  local resp, err = apiTry(attempt, function(res) return res.versions ~= nil end)
  apiNoteFeatures(resp)
  return resp, err
end

-- Write a reply back to CuePort. The server builds the stored message (it is
-- the side that knows the parent's author and timestamp, and both portals parse
-- that exact shape back out) -- from here it is the parent's id and the text.
local function apiPostComment(productionId, versionId, parentId, text)
  local status, body, err = httpPOST(state.apiUrl .. '/reaper/comment', authHeaders(), {
    production_id = productionId,
    version_id    = versionId,
    parent_id     = parentId,
    text          = text,
  })
  if not status then return nil, err end
  if status == 401 then return nil, 'unauthorized' end
  if status ~= 200 then
    local parsed = json.decode(body or '')
    return nil, (parsed and parsed.error) or ('HTTP ' .. status)
  end
  return json.decode(body)
end

-- Remove a reply. Only a reply: the server refuses the head of a thread, which
-- is usually the artist's remark and would take the conversation with it.
local function apiDeleteComment(feedbackId)
  local status, body, err = httpPOST(state.apiUrl .. '/reaper/comment/delete', authHeaders(), {
    feedback_id = feedbackId,
  })
  if not status then return nil, err end
  if status == 401 then return nil, 'unauthorized' end
  if status ~= 200 then
    local parsed = json.decode(body or '')
    return nil, (parsed and parsed.error) or ('HTTP ' .. status)
  end
  return json.decode(body)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- REAPER TRACK & ITEM HELPERS
-- ══════════════════════════════════════════════════════════════════════════════

-- Find existing comments track (via P_EXT marker). Returns track or nil.
local function findCommentsTrack()
  for i = 0, r.CountTracks(0) - 1 do
    local t = r.GetTrack(0, i)
    local _, marker = r.GetSetMediaTrackInfo_String(t, K.TRACK_MARKER_EXT_KEY, '', false)
    if marker == '1' then return t end
  end
  return nil
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PROJECT MARKER SYNC (v1.3+)
-- ══════════════════════════════════════════════════════════════════════════════
-- Stores feedback as project markers on the ruler. Marker names are short
-- ("CP @Author: MM:SS") so the ruler stays scannable; the full comment text
-- lives in ProjExtState and is looked up on hover. We identify "our" markers
-- by name prefix + uniform color.

K.CP_MARKER_NAME_PREFIX = 'CP '

local function cpMarkerColor()
  -- Combine RGB purple with the "custom color" flag Reaper expects
  local rgb = r.ColorToNative(0x7B, 0x45, 0xC8)
  return rgb | 0x1000000
end

local function formatTimestamp(pos)
  local total = math.max(0, math.floor(pos or 0))
  local m = math.floor(total / 60)
  local s = total - m * 60
  return string.format('%d:%02d', m, s)
end

local function formatCueportMarkerName(comment)
  local author = (comment.author or 'Artist'):gsub('[\r\n]+', ' ')
  return string.format('CP @%s: %s', author, formatTimestamp(comment.timestamp or 0))
end

-- Everything to do with our markers on the ruler, in one table rather than as
-- loose top-level functions: the whole script is a single Lua chunk and every
-- top-level `local` counts against the 200 the language allows. That ceiling is
-- a load error, not a warning, and it was reached the moment this file grew one
-- more helper.
local Markers = {}

-- Enumerate all markers that belong to us (by uniform color + name prefix).
function Markers.enumerate()
  local list = {}
  local expectedColor = cpMarkerColor()
  local i = 0
  while true do
    local retval, isrgn, pos, _, name, idx, color = r.EnumProjectMarkers3(0, i)
    if retval == 0 then break end
    if not isrgn
       and name and name:sub(1, #K.CP_MARKER_NAME_PREFIX) == K.CP_MARKER_NAME_PREFIX
       and color == expectedColor
    then
      list[#list+1] = { pos = pos, idx = idx, name = name }
    end
    i = i + 1
  end
  return list
end

-- Cache of { id, timestamp, text, author } stored in ProjExtState as JSON so
-- we can recover the full content at hover time after a script reload.
K.COMMENTS_CACHE_KEY = 'comments_cache'
-- Cache of { peaks = {float...}, duration = number } for the active version so
-- the waveform block can render immediately when the window is reopened,
-- without forcing a re-sync first.
K.WAVEFORM_CACHE_KEY = 'waveform_cache'
-- Whether the comment list is open. Global, not per project: it is a way of
-- working, not a property of one .rpp.
K.COMMENTS_OPEN_KEY  = 'comments_open'
-- Two more ways of working, global for the same reason. Both default to ON when
-- the key has never been written: the markers on the ruler are what this script
-- was for in the first place, and a fresh install must behave as it always did.
-- Read through Markers.wanted / renderMarkerWanted, never raw, so "unset means
-- on" lives in exactly one place.
K.MARKERS_ON_KEY     = 'markers_on'
K.RS_MARKER_ON_KEY   = 'render_marker_on'
-- That the render start was set by us. The marker on the ruler is normally the
-- proof; with the marker switched off there is nothing to look at, so the fact
-- is written down here as well. Per project, because that is what it describes.
K.RENDER_START_KEY   = 'render_start_set'
-- Which studio this device is paired to. Kept globally, like the token, and
-- shown in the header: a badge saying CONNECTED answers "is there a token",
-- which was never the question. The name is the answer, and a name that is not
-- yours is worth noticing.
K.STUDIO_NAME_KEY    = 'studio_name'
-- Which version of the production this project is looking at. Per project,
-- like the binding itself: two .rpp files bound to the same production may
-- well be working on different versions of it.
K.VERSION_KEY        = 'version_id'
-- The Reply control, in the top-right corner of a comment. Small enough not to
-- reach into the text it sits over, since it is only there while the mouse is
-- on the row.
K.REPLY_W            = 52
K.REPLY_H            = 18
-- The delete control beside it: a cross, not a word. The comment column is
-- K.COMMENT_LIST_W wide and the controls are painted OVER the header line, so
-- every pixel they take is a pixel of "0:12 . Ira . studio" that cannot be
-- read while the row is lit. A second 56 px word would have eaten the author.
K.DEL_W              = 22
-- While it asks it needs the room for the question, and it grows to the LEFT
-- so that Reply does not move under a mouse that is already aiming at it.
K.DEL_ARM_W          = 52
-- Gap between the two, so an armed delete is not a mis-aimed Reply.
K.DEL_GAP            = 8
-- How long the status line beside COMMENTS stays. It sits on the heading's own
-- line now, so it costs no height -- but it is a receipt for something that has
-- already happened, and a receipt that never goes away becomes furniture.
K.STATUS_SECS        = 2
K.COMMENT_LIST_W     = 210
-- Below this the list would leave the waveform too narrow to aim at, so it
-- steps aside instead. Measured against the body, not the window.
K.COMMENTS_MIN_ROOM  = 520

-- Metrics ride along in the same cache entry rather than in one of their own:
-- they belong to exactly the same version as the peaks, so a second store
-- would be a second thing that can go stale on its own. The version LIST is in
-- here for the same reason: without it a restart came back with the binding,
-- the waveform and the numbers, but no version switcher and no version pills --
-- they only appeared after the first Sync, which made them look like something
-- syncing creates rather than something the production has.
--
-- `production_id` is written with it and checked on the way out. The entry is
-- one per PROJECT, not one per production: bind another production in the same
-- project and the old entry is still sitting there, so without the check the
-- next read hands one production's peaks and one production's version list to
-- another one. An entry from a build before this field is refused and refills
-- itself on the next sync.
local function saveWaveformCache(e)
  setProjExt(K.WAVEFORM_CACHE_KEY, json.encode({
    production_id = e.productionId,
    peaks    = e.peaks or {},
    duration = e.duration,
    filename = e.filename,
    version_id = e.versionId,
    metrics  = e.metrics,
    versions = e.versions,
  }))
end

local function loadWaveformCache(productionId)
  local raw = getProjExt(K.WAVEFORM_CACHE_KEY)
  if not raw or raw == '' then return nil end
  local ok, parsed = pcall(json.decode, raw)
  if not ok or type(parsed) ~= 'table' then return nil end
  if not productionId or parsed.production_id ~= productionId then return nil end
  if type(parsed.peaks) ~= 'table' then parsed.peaks = {} end
  return parsed
end

-- Reaper lets the user shift the displayed time origin via
-- "Change start time/measure → Set 0:00 to current edit cursor". When that
-- offset is non-zero, the ruler shows `internal - offset`, i.e. a marker
-- stored at internal position P appears at ruler position P - offset. Our
-- comment timestamps are ruler-relative (seconds from the start of the
-- audio, as the artist heard it), so we must create markers at
-- `timestamp + offset` to land them at the correct ruler spot.
local function getProjectStartOffset()
  if not reaper.GetProjectTimeOffset then return 0 end
  local ok, v = pcall(reaper.GetProjectTimeOffset, 0, false)
  if ok and type(v) == 'number' then return v end
  return 0
end

-- Distinct name + color for the visible "render start" marker. We check for
-- exact name match so regular CuePort comment markers (prefix "CP ") are
-- unaffected.
K.CP_START_MARKER_NAME = 'CP: Render start'

local function cpStartMarkerColor()
  -- Lighter/brighter purple — distinct from comment markers (darker purple)
  local rgb = r.ColorToNative(0xE0, 0x9B, 0xFF)
  return rgb | 0x1000000
end

-- Unset means on: a fresh install keeps the behaviour the script always had,
-- and only a deliberate "no" turns it off.
function Markers.wanted()
  return getGlobalExt(K.MARKERS_ON_KEY) ~= '0'
end

local function renderMarkerWanted()
  return getGlobalExt(K.RS_MARKER_ON_KEY) ~= '0'
end

local function findRenderStartMarker()
  local i = 0
  while true do
    local retval, isrgn, pos, _, name, idx = r.EnumProjectMarkers3(0, i)
    if retval == 0 then break end
    if not isrgn and name == K.CP_START_MARKER_NAME then
      return { pos = pos, idx = idx }
    end
    i = i + 1
  end
  return nil
end

-- Shift the project ruler so that the edit-cursor position becomes 0:00 AND
-- drop a visible "render start" marker at that spot.
--
-- We invoke the native Reaper action 43345 ("Markers: Set project time
-- offset to current edit cursor position") — the same action triggered by
-- the ruler-right-click menu under "Change start time/measure → Set 0:00
-- to current edit cursor". This is version-proof across Reaper builds.
K.ACTION_SET_TIMEOFFS_TO_CURSOR = 43345

-- `pos` rather than always the cursor: a render bounded by a time selection
-- knows exactly where the file begins (GetSet_LoopTimeRange), and having to put
-- the cursor there first to say so would be a step the script can take itself.
-- The action reads the edit cursor, so the cursor is moved, the action run, and
-- the cursor put back -- the same three steps clearRenderStart already used.
local function setRenderStartAt(pos)
  local cursor = tonumber(pos) or r.GetCursorPosition()
  local savedCursor = r.GetCursorPosition()
  r.Undo_BeginBlock()
  if cursor ~= savedCursor then r.SetEditCurPos(cursor, false, false) end
  r.Main_OnCommand(K.ACTION_SET_TIMEOFFS_TO_CURSOR, 0)
  if cursor ~= savedCursor then r.SetEditCurPos(savedCursor, false, false) end

  -- Written down whether or not the marker is drawn: with the marker switched
  -- off there is nothing on the ruler to read the answer off, and "is the
  -- render start set?" still has to have one.
  setProjExt(K.RENDER_START_KEY, '1')

  local existing = findRenderStartMarker()
  if renderMarkerWanted() then
    local color = cpStartMarkerColor()
    if existing then
      r.SetProjectMarker3(0, existing.idx, false, cursor, 0, K.CP_START_MARKER_NAME, color)
    else
      r.AddProjectMarker2(0, false, cursor, 0, K.CP_START_MARKER_NAME, -1, color)
    end
  elseif existing then
    -- Switched off while one was still lying there.
    r.DeleteProjectMarker(0, existing.idx, false)
  end

  r.UpdateTimeline()
  r.Undo_EndBlock('CuePort: Set render start', -1)
  return true
end

local function setRenderStartAtCursor()
  return setRenderStartAt(r.GetCursorPosition())
end

-- Clear the project time offset (back to 0:00 at internal 0) and remove the
-- render-start marker we placed. We reset by temporarily placing the edit
-- cursor at 0 and re-running the "set offset" action; then restore the
-- cursor.
local function clearRenderStart()
  r.Undo_BeginBlock()
  local savedCursor = r.GetCursorPosition()
  r.SetEditCurPos(0, false, false)
  r.Main_OnCommand(K.ACTION_SET_TIMEOFFS_TO_CURSOR, 0)
  r.SetEditCurPos(savedCursor, false, false)
  local existing = findRenderStartMarker()
  if existing then
    r.DeleteProjectMarker(0, existing.idx, false)
  end
  setProjExt(K.RENDER_START_KEY, '')
  r.UpdateTimeline()
  r.Undo_EndBlock('CuePort: Clear render start', -1)
end

-- `parent_id` and `is_studio` are carried through because the list draws a
-- thread, not a flat run of lines: without the parent the reply has nothing to
-- hang under, and without the flag a studio answer is indistinguishable from
-- the artist's own words.
local function saveCommentsCache(comments, offset)
  local stripped = {}
  for _, c in ipairs(comments or {}) do
    stripped[#stripped+1] = {
      id = c.id,
      timestamp = c.timestamp,                       -- ruler-relative, as returned by the API
      markerPos = (c.timestamp or 0) - (offset or 0), -- internal Reaper position where the marker lives
      author = c.author,
      text = c.text,
      parent_id = c.parent_id,
      is_studio = c.is_studio,
      created_at = c.created_at,
    }
  end
  setProjExt(K.COMMENTS_CACHE_KEY, json.encode(stripped))
end

local function loadCommentsCache()
  local raw = getProjExt(K.COMMENTS_CACHE_KEY)
  if not raw or raw == '' then return {} end
  local ok, parsed = pcall(json.decode, raw)
  if not ok or type(parsed) ~= 'table' then return {} end
  return parsed
end

-- Find the cached comment whose stored marker position matches a given
-- Reaper internal time. Falls back to `timestamp` for cache entries written
-- by older script versions that did not store `markerPos`.
local function findCachedCommentAtPos(pos)
  if not pos then return nil end
  local list = loadCommentsCache()
  local best, bestD = nil, math.huge
  for _, c in ipairs(list) do
    local target = c.markerPos or c.timestamp
    if target then
      local d = math.abs(target - pos)
      if d < 0.1 and d < bestD then best, bestD = c, d end
    end
  end
  return best
end

-- Delete every media item we previously placed on the Comments track (from
-- earlier versions that used items). Leaves user-placed items alone (those
-- without our K.ITEM_FB_ID_EXT_KEY marker). Deletes the track entirely if it
-- ends up empty afterwards.
local function cleanupLegacyItems()
  local track = findCommentsTrack()
  if not track then return 0 end
  local removed = 0
  local i = r.CountTrackMediaItems(track) - 1
  while i >= 0 do
    local item = r.GetTrackMediaItem(track, i)
    local _, fid = r.GetSetMediaItemInfo_String(item, K.ITEM_FB_ID_EXT_KEY, '', false)
    if fid and fid ~= '' then
      r.DeleteTrackMediaItem(track, item)
      removed = removed + 1
    end
    i = i - 1
  end
  -- If the comments track is now empty, delete it to tidy up
  if r.CountTrackMediaItems(track) == 0 then
    local idx = r.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER')
    if idx and idx > 0 then
      r.DeleteTrack(track)
    end
  end
  return removed
end

local function syncCommentsToMarkers(comments)
  r.Undo_BeginBlock()

  -- Migrate off the legacy item-based approach (no-op if none exist)
  local legacyRemoved = cleanupLegacyItems()

  -- Timestamp first, then age. The second key is not cosmetic: a reply carries
  -- its parent's timestamp, so on timestamp alone the two are equal and Lua's
  -- sort is free to put the answer above the question. Every reply is written
  -- after the comment it answers, so age settles it.
  table.sort(comments, function(a, b)
    local at, bt = (a.timestamp or 0), (b.timestamp or 0)
    if at ~= bt then return at < bt end
    return (a.created_at or 0) < (b.created_at or 0)
  end)

  -- Honour Reaper's project start offset so comments at timestamp T end up
  -- at ruler 0:00 + T (not at internal time T which would show at T-offset
  -- once the user has moved the ruler origin).
  local offset = getProjectStartOffset()

  -- Rebuild strategy: delete all our existing CP markers, then create fresh
  -- from the current API payload. Simpler than diffing and keeps the marker
  -- ruler in lock-step with the server without carrying stable IDs in names.
  local existing = Markers.enumerate()
  local previouslyCount = #existing
  for i = #existing, 1, -1 do
    r.DeleteProjectMarker(0, existing[i].idx, false)
  end

  -- The cache is written either way: the pins on the waveform and the comment
  -- column read from it, and they are exactly what a user who turns the markers
  -- off is left with. Only the ruler stays clean.
  local wantMarkers = Markers.wanted()
  local color = cpMarkerColor()
  local created = 0
  local validComments = {}
  for _, c in ipairs(comments) do
    if c.id then
      -- A reply shares its parent's timestamp, so giving it its own marker
      -- would stack a second pin on exactly the same spot and say nothing new.
      -- The thread is read in the list; the ruler carries one pin per comment.
      -- A comment with no timestamp cannot be placed at all -- it is kept in
      -- the cache and shown in the list, just not on the ruler.
      if wantMarkers and c.timestamp ~= nil and not c.parent_id then
        local name = formatCueportMarkerName(c)
        local markerPos = c.timestamp - offset
        r.AddProjectMarker2(0, false, markerPos, 0, name, -1, color)
        created = created + 1
      end
      validComments[#validComments+1] = c
    end
  end

  saveCommentsCache(validComments, offset)

  r.UpdateTimeline()
  r.Undo_EndBlock('CuePort: Sync artist comments (markers)', -1)
  return {
    created = created,
    removed = previouslyCount,
    legacyItemsRemoved = legacyRemoved,
    offset = offset,
  }
end

-- ══════════════════════════════════════════════════════════════════════════════
-- OS helpers
-- ══════════════════════════════════════════════════════════════════════════════

-- `ExecProcess` uebergibt die Zeile an eine echte Shell, nicht an ein
-- Argument-Feld -- alles, was dort hineingeschrieben wird, gehoert deshalb
-- zitiert. Die Pairing-URL kommt aus der Antwort des Servers
-- (`verification_url_complete`), also aus einer Quelle, die dieses Skript
-- nicht kontrolliert, und `startPairing` oeffnet sie ohne Zutun des Nutzers.
--
-- Zwei Riegel, absichtlich beide:
--   1. Es wird nur geoeffnet, was wie eine http(s)-Adresse aussieht -- keine
--      Steuerzeichen, kein Leerraum, kein Anfuehrungszeichen (das braucht
--      eine echte URL nie, es gehoert prozentkodiert).
--   2. Und selbst dann wird zitiert, statt sich auf Punkt 1 zu verlassen.
local function urlIsSafe(url)
  if type(url) ~= 'string' or #url == 0 or #url > 2048 then return false end
  if not url:match('^https?://[^%s]+$') then return false end
  -- %c faengt Steuerzeichen samt Zeilenumbruch; ein " bricht unter Windows
  -- aus den Anfuehrungszeichen von `start` aus.
  if url:find('[%c"]') then return false end
  return true
end

local function openUrl(url)
  if not urlIsSafe(url) then return false end
  if isWindows() then
    -- Innerhalb der Anfuehrungszeichen von cmd sind & | < > ^ woertlich;
    -- gefaehrlich waere nur ein " , und das ist oben ausgeschlossen.
    r.ExecProcess('cmd.exe /c start "" "' .. url .. '"', 0)
  elseif r.GetOS():find('OSX') or r.GetOS():find('macOS') then
    r.ExecProcess('/usr/bin/open ' .. shQuote(url), 0)
  else
    r.ExecProcess('xdg-open ' .. shQuote(url), 0)
  end
  return true
end

local function clipboardSet(text)
  if r.CF_SetClipboard then r.CF_SetClipboard(text) end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- FLOW CONTROLLERS (kick off async sub-flows; polled via defer loop)
-- ══════════════════════════════════════════════════════════════════════════════

local function submitPairing()
  state.errorMsg = nil
  local code = (state.pairCode or ''):gsub('%s', ''):upper()
  if #code < 4 then
    state.errorMsg = 'Enter the pairing code shown in CuePort.'
    return
  end
  local resp, err = apiPairingClaim(code)
  if err or not resp or not resp.ok or not resp.access_token then
    state.errorMsg = 'Could not connect: ' .. (err or (resp and resp.error) or 'invalid or expired code')
    return
  end
  saveToken(resp.access_token)
  state.studioName = resp.studio_name or ''
  setGlobalExt(K.STUDIO_NAME_KEY, state.studioName)
  state.pairCode = ''
  state.screen = 'main'
  state.productions = nil
end

local function startPairing()
  state.errorMsg = nil
  local resp, err = apiDeviceStart()
  if err or not resp or not resp.ok then
    state.errorMsg = 'Could not start pairing: ' .. (err or (resp and resp.error) or 'Unknown')
    state.screen = 'login'
    return
  end
  state.deviceCode = resp.device_code
  state.userCode = resp.user_code
  state.verificationUrl = resp.verification_url_complete or resp.verification_url
  state.pollInterval = (resp.interval or 3)
  state.pairingExpiresAt = (r.time_precise() + (resp.expires_in or 900))
  state.lastPoll = 0
  state.screen = 'pairing'
  -- Auto-open browser. Geht die Adresse nicht auf (weil sie nicht wie eine
  -- URL aussieht), ist das kein Sackgassen-Zustand: der Code steht auf dem
  -- Bildschirm und laesst sich im Portal von Hand eintippen. Gesagt werden
  -- muss es trotzdem, sonst klickt jemand ins Leere.
  state.urlBlocked = false
  if state.verificationUrl and not openUrl(state.verificationUrl) then
    state.urlBlocked = true
  end
end

local function cancelPairing()
  state.deviceCode = nil
  state.userCode = nil
  state.verificationUrl = nil
  state.screen = 'login'
end

local function pollPairing()
  if not state.deviceCode then return end
  local now = r.time_precise()
  if now < state.lastPoll + state.pollInterval then return end
  state.lastPoll = now
  if now > state.pairingExpiresAt then
    state.errorMsg = 'Pairing code expired. Please try again.'
    cancelPairing()
    return
  end
  local resp, err = apiDevicePoll(state.deviceCode)
  if err then
    state.errorMsg = err
    return
  end
  if resp.status == 'approved' and resp.access_token then
    saveToken(resp.access_token)
    -- Older workers do not send it. An empty name simply falls back to the old
    -- label rather than showing a blank pill.
    state.studioName = resp.studio_name or ''
    setGlobalExt(K.STUDIO_NAME_KEY, state.studioName)
    state.deviceCode = nil
    state.userCode = nil
    state.verificationUrl = nil
    state.screen = 'main'
    state.productions = nil
  elseif resp.status == 'denied' then
    state.errorMsg = 'Access denied.'
    cancelPairing()
  elseif resp.status == 'expired' or (resp._http_status == 410) then
    state.errorMsg = 'Pairing code expired.'
    cancelPairing()
  end
  -- else: still pending — keep polling
end

-- Declared here rather than beside its methods: logout takes the A/B reference
-- down with everything else, and a `local` written below that point would be a
-- different (global, nil) name up here. The methods are all attached long
-- before anything can call one.
--
-- Where reference audio is stored: inside the project folder for a saved
-- project (travels with it, survives a cache wipe), otherwise a global cache
-- for projects that have never been written to disk.
local AB = {}

-- Cover art: download, cache, draw. Declared up here for the same reason AB is --
-- logout has to be able to clear it, and a table declared below logout would be a
-- different (global, empty) name at that point.
local Art = {}

local function logout()
  saveToken(nil)
  state.studioName = nil
  state.up, state.upload = nil, nil
  delGlobalExt(K.STUDIO_NAME_KEY)
  -- Everything the session was showing goes with the token. It is all studio
  -- content: the list, the production, its waveform, its numbers, its comments.
  -- Leaving any of it up means a logged-out script still displaying the work of
  -- a studio it is no longer connected to -- which is what the comment column
  -- did, still listing the last production's comments on the login screen.
  state.productions = nil
  state.boundProduction = nil
  state.waveform, state.waveformForId = nil, nil
  state.metrics = nil
  state.versionFilename, state.versionId = nil, nil
  state.versions, state.versionsForId, state.selectedVersionId = nil, nil, nil
  state.versionsTriedFor = nil
  state.versionSwitchFrom, state.pendingTrackType = nil, nil
  state.replyTo, state.replyText, state.replyStatus, state.replyPending = nil, '', nil, nil
  state.delArm, state.delPending = nil, nil
  state.replyFocus = false
  state.pendingSeekAt = nil
  state.hoverCommentId, state.hoverRowCommentId, state.cmtRects = nil, nil, nil
  state.cmtCtl = nil
  state.cmtScrollTo = nil
  state.lastSyncResult = nil
  state.syncStatus = ''
  state.expandedArtists = {}
  state.filterText = ''
  -- The reference audio came from the studio too.
  pcall(AB.remove)
  -- And the cover art. Files AND the in-memory images: leaving the textures
  -- attached would keep a logged-out script holding a studio's artwork.
  pcall(Art.clear)
  -- And so did the markers and the comments behind them. Only the active
  -- project can be reached from here -- another open tab keeps its own cache
  -- until it is opened and logged out from as well.
  pcall(Markers.remove)
  setProjExt(K.COMMENTS_CACHE_KEY, '')
  setProjExt(K.WAVEFORM_CACHE_KEY, '')
  state.markersPlacedFor = nil
  -- And the binding with it: logging out means this Reaper is no longer
  -- connected to that studio, so the project should not still be claiming to
  -- belong to one of its productions. Logging back in starts from the picker.
  setProjExt('production_id', '')
  state.boundProductionId = nil
  state.showPickerOverride = false
  state.screen = 'login'
  -- Both pill variants refuse to draw without a token, so logging out takes
  -- away the only other way of reaching the script. If the window were hidden
  -- at that moment, nothing at all would be on screen and the single-instance
  -- handshake would be the only way back. Put the window up instead.
  state.windowVisible = true
end

-- ══════════════════════════════════════════════════════════════════════════════
-- DEPENDENCY CHECK
-- ══════════════════════════════════════════════════════════════════════════════

local function getDependencies()
  local curlOk, curlVer = checkCurl()
  return {
    { name = 'ReaImGui',         required = true,  ok = r.APIExists('ImGui_CreateContext'),
      what    = 'Draws this window. Nothing you see here exists without it.',
      install = 'Extensions → ReaPack → Browse packages → "ReaImGui"' },
    { name = 'curl',             required = true,  ok = curlOk,
      detail  = curlVer,
      what    = 'Every call to CuePort goes through it: pairing, productions, ' ..
                'comments, the audio and the cover art.',
      install = 'Usually preinstalled (Win 10+, macOS, Linux)',
      url     = 'https://curl.se/download.html' },
    { name = 'SWS Extension',    required = false, ok = r.APIExists('BR_PositionAtMouseCursor'),
      what    = 'Reads the project time under the mouse. Without it the script ' ..
                'works that out from the arrange view itself.',
      install = 'Download, or Extensions → ReaPack → Browse packages',
      url     = 'https://www.sws-extension.org' },
    { name = 'JS_ReaScriptAPI',  required = false, ok = r.APIExists('JS_Window_FindChildByID'),
      what    = 'Carries the pill that attaches to the transport, and the ' ..
                'window probing behind it. Everything else works without it.',
      install = 'Extensions → ReaPack → Browse packages → "js_ReaScriptAPI"' },
  }
end

local function missingRequiredDeps()
  local out = {}
  for _, d in ipairs(getDependencies()) do
    if d.required and not d.ok then out[#out+1] = d end
  end
  return out
end

-- ══════════════════════════════════════════════════════════════════════════════
-- AUTO-START (modifies Reaper's __startup.lua to invoke this script headless)
-- ══════════════════════════════════════════════════════════════════════════════

K.AUTOSTART_BEGIN = '-- BEGIN CuePort Sync auto-start --'
K.AUTOSTART_END   = '-- END CuePort Sync auto-start --'

local function getStartupScriptPath()
  local sep = isWindows() and '\\' or '/'
  return r.GetResourcePath() .. sep .. 'Scripts' .. sep .. '__startup.lua'
end

local function getScriptSelfPath()
  local info = debug.getinfo(1, 'S')
  if info and info.source then
    return info.source:match('^@(.*)$')
  end
  return nil
end

local function escLuaPat(s) return (s:gsub('[%-%(%)%.%%%+%-%*%?%[%]%^%$]', '%%%1')) end

local function autostartBlock()
  local selfPath = getScriptSelfPath() or ''
  return K.AUTOSTART_BEGIN .. '\n'
      .. 'do\n'
      .. '  _G.CUEPORT_STARTUP = true\n'
      .. '  local ok, err = pcall(dofile, ' .. string.format('%q', selfPath) .. ')\n'
      .. '  _G.CUEPORT_STARTUP = nil\n'
      .. '  if not ok then reaper.ShowConsoleMsg("CuePort auto-start error: " .. tostring(err) .. "\\n") end\n'
      .. 'end\n'
      .. K.AUTOSTART_END
end

local function isAutostartEnabled()
  local content = readFile(getStartupScriptPath()) or ''
  return content:find(K.AUTOSTART_BEGIN, 1, true) ~= nil
end

local function setAutostart(enable)
  local path = getStartupScriptPath()
  local content = readFile(path) or ''
  local pattern = escLuaPat(K.AUTOSTART_BEGIN) .. '.-' .. escLuaPat(K.AUTOSTART_END)
  content = content:gsub(pattern .. '\n?', '')
  if enable then
    if content ~= '' and not content:match('\n$') then content = content .. '\n' end
    content = content .. autostartBlock() .. '\n'
  end
  return writeFile(path, content)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- SINGLE-INSTANCE DETECTION (heartbeat via global ExtState)
-- ══════════════════════════════════════════════════════════════════════════════

K.INSTANCE_HB_KEY       = 'instance_hb'
K.SHOW_WINDOW_REQ_KEY   = 'show_window_req'
K.INSTANCE_ALIVE_WIN_SEC = 5

local function isOtherInstanceAlive()
  local hbStr = r.GetExtState(K.EXT_NS, K.INSTANCE_HB_KEY)
  local hb = tonumber(hbStr)
  if not hb then return false end
  return (r.time_precise() - hb) < K.INSTANCE_ALIVE_WIN_SEC
end

local function signalShowWindow()
  r.SetExtState(K.EXT_NS, K.SHOW_WINDOW_REQ_KEY, '1', false)
end

local function consumeShowWindowRequest()
  local v = r.GetExtState(K.EXT_NS, K.SHOW_WINDOW_REQ_KEY)
  if v == '1' then
    r.DeleteExtState(K.EXT_NS, K.SHOW_WINDOW_REQ_KEY, false)
    return true
  end
  return false
end

local function clearInstanceHeartbeat()
  r.DeleteExtState(K.EXT_NS, K.INSTANCE_HB_KEY, false)
end


-- ══════════════════════════════════════════════════════════════════════════════
-- UPDATES — ask GitHub, install, restart
-- ══════════════════════════════════════════════════════════════════════════════
-- Everything hangs off `Upd` rather than sitting at the top level: the whole
-- script is one Lua chunk and a chunk may hold 200 locals, so a dozen loose
-- `local function`s here would be a dozen steps towards a script that no longer
-- loads at all.
--
-- The check costs 200 bytes. raw.githubusercontent answers range requests
-- (measured: HTTP 206), so we ask for the head of the very file ReaPack would
-- install and read line 2 -- `-- @version X.Y.Z`. The whole file is 350 KB and
-- index.xml is 130 KB; neither is worth pulling to learn a version number.
--
-- The same reply also carries `content-range: bytes 0-199/350705`, which is the
-- exact size of the new file. That turns "did the download finish?" from a
-- guess into a comparison.

local Upd = {}

K.UPD_RAW_URL    = 'https://raw.githubusercontent.com/m3lotunes/reaper-scripts/' ..
                   'main/CuePort%20Sync/cueport_sync.lua'
K.UPD_INDEX_URL  = 'https://raw.githubusercontent.com/m3lotunes/reaper-scripts/' ..
                   'main/index.xml'
K.UPD_CHECK_KEY  = 'upd_check'      -- '0' turns the check off
K.UPD_LAST_KEY   = 'upd_last'       -- os.time() of the last completed check
K.UPD_SEEN_KEY   = 'upd_seen'       -- version found then
K.UPD_LAST_VER_KEY = 'upd_last_ver' -- the version that DID that check
K.UPD_SIZE_KEY   = 'upd_size'       -- and its size in bytes
K.UPD_FIX_KEY    = 'upd_repo_fix'   -- repair note for the ReaPack path
K.UPD_EVERY_SEC  = 86400            -- once a day is plenty for a script
K.UPD_HEAD_LEN   = 199              -- 0-199, enough for the header comment
K.UPD_JOB_SECS   = 120              -- give up on a detached curl after this
K.UPD_WATCH_SEC  = 3                -- how often the watchdog reads its own head
K.UPD_SHOW_KEY   = 'upd_show_after'  -- os.time() of a restart the user asked for
K.UPD_SHOW_SECS  = 30               -- how long that request stays good
-- ReaPack either starts within a couple of seconds or it has decided there is
-- nothing to do. Two minutes of a locked window is a hang, not a wait.
K.UPD_RP_SECS    = 20

-- Runtime state, created on first use (same shape as Art.st).
function Upd.st()
  state.upd = state.upd or {}
  return state.upd
end

function Upd.enabled() return getGlobalExt(K.UPD_CHECK_KEY) ~= '0' end

-- The `@version` line out of whatever chunk of text we were handed. Anchored
-- to the comment marker so a stray "@version" further down cannot win.
function Upd.versionIn(text)
  if type(text) ~= 'string' then return nil end
  return text:match('%-%-%s*@version%s+([%w%.%-]+)')
end

-- Compare two version strings. ReaPack knows how to do this properly and is
-- usually present; the fallback handles the shape we actually publish (three
-- numbers) and is deliberately dumb about anything else.
function Upd.cmp(a, b)
  if r.APIExists('ReaPack_CompareVersions') then
    local ok, res = pcall(r.ReaPack_CompareVersions, a, b, '', 128)
    if ok and type(res) == 'number' then return res end
  end
  local function parts(v)
    local t = {}
    for n in tostring(v or ''):gmatch('(%d+)') do t[#t+1] = tonumber(n) end
    return t
  end
  local pa, pb = parts(a), parts(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x < y and -1 or 1 end
  end
  return 0
end

function Upd.newer(candidate, current)
  if not candidate or candidate == '' then return false end
  return Upd.cmp(candidate, current or K.VERSION) > 0
end

-- What ReaPack knows about the file we are running from, or nil.
-- Three states matter and they are not two: no ReaPack at all, ReaPack but this
-- file belongs to no package (installed by hand), and a real package entry.
function Upd.entry()
  if not r.APIExists('ReaPack_GetOwner') then return nil end
  local self = getScriptSelfPath()
  if not self then return nil end
  local ok, ent = pcall(r.ReaPack_GetOwner, self)
  if not ok or not ent or ent == '' then return nil end
  -- Signature verified against production code (Lokasenna GUI v2): the out
  -- parameters come back as return values, there are no size arguments.
  --   ret, repo, cat, pkg, desc, type, ver, author, pinned, fileCount
  local res = { pcall(r.ReaPack_GetEntryInfo, ent) }
  pcall(r.ReaPack_FreeEntry, ent)
  if not res[1] or not res[2] then return nil end
  local repo, ver, flags = res[3], res[8], res[10]
  if not repo or repo == '' then return nil end
  -- Position 9 (index 10 here, past pcall's own boolean) was `pinnedOut`, a
  -- bool, and is `flagsOut` in current ReaPack, an int whose &1 is the pin.
  -- Both are read rather than assuming which build is installed: pinned means
  -- the user said "keep me on this version", and that outranks our button.
  local pinned = (flags == true)
                 or ((tonumber(flags) or 0) % 2 == 1)
  return { repo = repo, version = ver, pinned = pinned }
end

-- 'reapack' | 'manual' | 'noreapack'
function Upd.mode()
  if not r.APIExists('ReaPack_GetOwner') then return 'noreapack' end
  return Upd.entry() and 'reapack' or 'manual'
end

-- Launch curl detached from a config file. No shell: curl writes its own output
-- files, so there is nothing to redirect, and that is what used to force the
-- Windows path through cmd.exe and its quoting rules. A negative timeout means
-- ExecProcess hands the line over and returns at once.
function Upd.launch(lines, cfgSuffix)
  local cfgPath = tmpPath(cfgSuffix)
  if not writeFile(cfgPath, table.concat(lines, '\n') .. '\n') then return nil end
  local ok = r.ExecProcess(curlCfgCmd(cfgPath), -1)
  if not ok then deleteFile(cfgPath); return nil end
  return cfgPath
end

-- ── The check ────────────────────────────────────────────────────────────────

function Upd.due()
  -- Which version ASKED, not which version was found. The stored answer belongs
  -- to the build that fetched it, so a different build -- an update, a ReaPack
  -- downgrade, a hand-installed copy that is ahead of the release -- is worth
  -- one fresh look. Exactly one: the next check writes this key, and the daily
  -- rule takes over again.
  --
  -- This used to compare the ANSWER against ourselves ("an answer older than us
  -- is stale, so look again"), which is true and, as a condition, never stops
  -- being true: the fresh answer names the same older version, so the next
  -- frame asks again. On a build ahead of the release that meant the card sat
  -- on "Checking..." for as long as the script ran and Github was asked for the
  -- same 200 bytes over and over. Reported from the device on 2026-08-23; the
  -- same shape as the 1.30.5 loop, from the other direction.
  if getGlobalExt(K.UPD_LAST_VER_KEY) ~= K.VERSION then return true end
  local last = tonumber(getGlobalExt(K.UPD_LAST_KEY)) or 0
  return (os.time() - last) >= K.UPD_EVERY_SEC
end

function Upd.startCheck(force)
  local st = Upd.st()
  if st.job then return false end
  if not force and (not Upd.enabled() or not Upd.due()) then return false end
  local headPath, hdrPath = tmpPath('updhead'), tmpPath('updhdr')
  deleteFile(headPath); deleteFile(hdrPath)
  -- raw.githubusercontent answers with `cache-control: max-age=300`, so the
  -- same URL can hand back a five minute old file. For the once-a-day look
  -- that is fine and saves everyone the traffic. For "Check now" it is wrong:
  -- the user pressed a button that says look NOW, and getting "up to date" out
  -- of a stale cache is worse than no button at all. A throwaway query string
  -- is enough to miss the cached copy; the path itself is unchanged.
  local url = K.UPD_RAW_URL
  if force then
    url = url .. '?cb=' .. tostring(os.time()) .. tostring(math.floor(r.time_precise() * 1000) % 100000)
  end
  local cfg = Upd.launch({
    'silent',
    'range = "0-' .. K.UPD_HEAD_LEN .. '"',
    'dump-header = "' .. cfgQ(hdrPath) .. '"',
    'output = "' .. cfgQ(headPath) .. '"',
    'url = "' .. cfgQ(url) .. '"',
  }, 'updcheck.cfg')
  if not cfg then return false end
  st.job = { kind = 'check', cfg = cfg, head = headPath, hdr = hdrPath,
             started = r.time_precise(), nextCheck = r.time_precise() + 0.25 }
  st.error = nil
  return true
end

-- Reading the answer is the same act as deciding it has arrived: a half-written
-- head has no complete version line, so there is nothing to wait for separately.
function Upd.finishCheck(job)
  local head = readFile(job.head)
  local ver  = Upd.versionIn(head or '')
  if not ver then return false end
  local size
  local hdr = readFile(job.hdr) or ''
  -- content-range: bytes 0-199/350705 -- the number after the slash is what the
  -- whole file weighs, and the only free way to learn it.
  local total = hdr:match('[Cc]ontent%-[Rr]ange:%s*bytes%s+%d+%-%d+/(%d+)')
  if total then size = tonumber(total) end
  setGlobalExt(K.UPD_LAST_KEY, tostring(os.time()))
  setGlobalExt(K.UPD_LAST_VER_KEY, K.VERSION)
  setGlobalExt(K.UPD_SEEN_KEY, ver)
  setGlobalExt(K.UPD_SIZE_KEY, size and tostring(size) or '')
  return true
end

-- What the last completed check found, or nil when that is not newer than us.
function Upd.available()
  local ver = getGlobalExt(K.UPD_SEEN_KEY)
  if not Upd.newer(ver, K.VERSION) then return nil end
  return ver, tonumber(getGlobalExt(K.UPD_SIZE_KEY))
end

-- ── Installing: replace our own file ─────────────────────────────────────────
-- Works in all three constellations (no ReaPack, ReaPack but hand-installed,
-- ReaPack-managed), which is why it is also the fallback when the ReaPack path
-- below does not come through.

function Upd.selfPaths()
  local self = getScriptSelfPath()
  if not self then return nil end
  return self, self .. '.new', self .. '.bak'
end

function Upd.startInstall()
  local st = Upd.st()
  if st.job then return false end
  local ver, size = Upd.available()
  if not ver then return false end
  local self, newPath = Upd.selfPaths()
  if not self then st.error = 'Cannot tell where this script lives.'; return false end
  -- Fail here rather than after a 350 KB download: if the directory cannot be
  -- written to, nothing else in this function is going to work either.
  local probe = io.open(newPath, 'wb')
  if not probe then
    st.error = 'No permission to write beside the script.'
    return false
  end
  probe:close(); deleteFile(newPath)
  local cfg = Upd.launch({
    'silent',
    'output = "' .. cfgQ(newPath) .. '"',
    'url = "' .. cfgQ(K.UPD_RAW_URL) .. '"',
  }, 'updget.cfg')
  if not cfg then st.error = 'Could not start curl.'; return false end
  st.job = { kind = 'install', cfg = cfg, path = newPath, want = ver, size = size,
             started = r.time_precise(), nextCheck = r.time_precise() + 0.25 }
  st.error = nil
  return true
end

-- Three checks before anything is replaced. A download that died halfway is the
-- one failure that could leave the user without a working script, so it is
-- caught three different ways rather than trusted once.
function Upd.verify(path, wantVer, wantSize)
  local body = readFile(path)
  if not body or #body == 0 then return false, 'nothing downloaded' end
  -- 1. The exact byte count the server told us during the check.
  if wantSize and #body ~= wantSize then
    return false, 'size mismatch (' .. #body .. ' of ' .. wantSize .. ')'
  end
  -- 2. It has to be the version we were promised.
  local got = Upd.versionIn(body)
  if wantVer and got ~= wantVer then
    return false, 'version mismatch (' .. tostring(got) .. ')'
  end
  -- 3. And it has to be valid Lua. `load` compiles without running, so a file
  --    cut short mid-chunk fails here and never reaches the disk slot we run
  --    from. Nothing in the downloaded file is executed by this.
  local chunk, err = load(body, 'cueport_update')
  if not chunk then return false, 'not valid Lua (' .. tostring(err) .. ')' end
  return true
end

function Upd.finishInstall(job)
  local st = Upd.st()
  local ok, why = Upd.verify(job.path, job.want, job.size)
  if not ok then
    deleteFile(job.path)
    st.error = 'Download failed: ' .. why
    return false
  end
  local self, newPath, bakPath = Upd.selfPaths()
  -- Keep the old one. If the new file turns out to be broken in a way none of
  -- the three checks can see, this is the way back.
  deleteFile(bakPath)
  if not os.rename(self, bakPath) then
    deleteFile(newPath)
    st.error = 'Could not move the old file aside.'
    return false
  end
  if not os.rename(newPath, self) then
    os.rename(bakPath, self)  -- put it back, we changed nothing
    st.error = 'Could not put the new file in place.'
    return false
  end
  return true
end

-- ── Installing: hand it to ReaPack ───────────────────────────────────────────
-- Only for a ReaPack-managed copy, and preferred there: its registry stays
-- correct and we never touch a file a package manager owns.
--
-- ReaPack has no "install this package" call. What it does have is
-- AddSetRepository, and ReaPack::addSetRemote starts a synchronize for that one
-- repository when the entry changes -- enabled must flip, or the URL must. Ours
-- is already enabled, so we switch it off and on again. That is the whole trick.

function Upd.canReaPack()
  return r.APIExists('ReaPack_AddSetRepository')
     and r.APIExists('ReaPack_ProcessQueue')
     and r.APIExists('ReaPack_GetRepositoryInfo')
end

-- Would ReaPack actually install anything? Its registry, not the file on disk,
-- is what it compares against the index (SynchronizeTask::synchronize: same
-- version and all files present means "nothing to do here"). So if the registry
-- already carries the version we are being offered, asking would start a
-- transaction that finishes without touching anything -- and we would sit in
-- front of a locked window waiting for a file that is never going to change.
-- The honest answer then is to replace the file ourselves.
function Upd.reaPackWouldAct(newVer)
  local ent = Upd.entry()
  if not ent or not ent.version or not newVer then return true end
  return Upd.cmp(ent.version, newVer) < 0
end

function Upd.viaReaPack()
  local st = Upd.st()
  local ent = Upd.entry()
  if not ent then return false, 'not installed through ReaPack' end
  if not Upd.canReaPack() then return false, 'this ReaPack is too old' end
  local newVer = Upd.available()
  if not Upd.reaPackWouldAct(newVer) then
    return false, 'ReaPack already lists ' .. tostring(ent.version) ..
                  ' as installed, so it would not fetch anything'
  end
  local res = { pcall(r.ReaPack_GetRepositoryInfo, ent.repo) }
  -- retval, urlOut, enabledOut, autoInstallOut
  if not res[1] or not res[2] then return false, 'repository not in ReaPack' end
  local autoBefore = tonumber(res[5]) or 2

  -- The note goes down BEFORE the repository is touched. Everything between the
  -- two calls below runs with the user's repository disabled, and a Lua error
  -- in there would leave it that way for good. With the note, the next start
  -- puts it back -- see Upd.repairRepo, called from the bootstrap.
  setGlobalExt(K.UPD_FIX_KEY, ent.repo .. '|' .. tostring(autoBefore))

  -- An empty URL keeps the one already stored, so the user's repository URL is
  -- never rewritten from a constant of ours.
  local okOff = pcall(r.ReaPack_AddSetRepository, ent.repo, '', false, autoBefore)
  -- autoInstall must be 1 here, not 2: the guard in addSetRemote reads it
  -- before it starts anything, and 2 means "obey the global setting" which
  -- ReaPack ships switched off. It is put back to the user's value once the
  -- new file has landed.
  local okOn  = pcall(r.ReaPack_AddSetRepository, ent.repo, '', true, 1)
  if not (okOff and okOn) then
    -- The note stays: calling back in now could land in a transaction that the
    -- first of the two calls already opened.
    return false, 'ReaPack refused the repository change'
  end
  pcall(r.ReaPack_ProcessQueue, true)
  st.rpStarted = r.time_precise()
  st.rpRepo, st.rpAuto = ent.repo, autoBefore
  return true
end

-- Give the repository back exactly as we found it. Called after a successful
-- update, and from the bootstrap when a note from a crashed run is lying about.
function Upd.repairRepo()
  local note = getGlobalExt(K.UPD_FIX_KEY)
  if not note or note == '' then return false end
  local repo, auto = note:match('^(.*)|([^|]*)$')
  if not repo or repo == '' then setGlobalExt(K.UPD_FIX_KEY, ''); return false end
  if Upd.canReaPack() then
    -- Enabled and same URL, so this restores the setting without starting a
    -- second synchronize.
    pcall(r.ReaPack_AddSetRepository, repo, '', true, tonumber(auto) or 2)
    pcall(r.ReaPack_ProcessQueue, false)
  end
  setGlobalExt(K.UPD_FIX_KEY, '')
  return true
end

-- ── The watchdog ─────────────────────────────────────────────────────────────
-- Reads the head of the file we are running from and compares it with the
-- version compiled into us. Whoever changed it -- us, ReaPack, or the user with
-- a text editor -- the answer is the same: what is on disk is no longer what is
-- in memory, and a restart is what fixes that.
--
-- Safe to read at any moment: ReaPack downloads into a temporary file and only
-- renames it into place once every part succeeded (InstallTask::commit), so the
-- file is never half new. On Windows the rename is preceded by a remove, so it
-- can be missing for an instant -- that is not an error, just read again later.

function Upd.watch()
  local st = Upd.st()
  local now = r.time_precise()
  if st.nextWatch and now < st.nextWatch then return end
  st.nextWatch = now + K.UPD_WATCH_SEC
  local self = getScriptSelfPath()
  if not self then return end
  local f = io.open(self, 'rb')
  if not f then return end            -- mid-rename, or gone: ask again later
  local head = f:read(400)
  f:close()
  local ver = Upd.versionIn(head or '')
  if ver and ver ~= K.VERSION then
    st.onDisk = ver
  else
    st.onDisk = nil
  end
end

-- ── Restarting ───────────────────────────────────────────────────────────────

-- Our own command id. `mayRegister` is not a convenience flag, it is the whole
-- point: AddRemoveReaScript with commit=true WRITES Reaper's action
-- registration to disk, and this used to be reachable from the drawing code --
-- which meant reaper-kb.ini was rewritten on every frame for as long as the
-- update card was on screen. Doing that while ReaPack was touching the same
-- registration took Reaper down with it.
--
-- So: only from the press, and only once per session. Everything that draws
-- asks Upd.canRestart instead, which is a question about capability and writes
-- nothing at all.
function Upd.cmdId(mayRegister)
  local st = Upd.st()
  if st.cmdIdKnown ~= nil then return st.cmdIdKnown or nil end
  local _, _, _, cmdID = r.get_action_context()
  cmdID = tonumber(cmdID)
  if cmdID and cmdID > 0 then st.cmdIdKnown = cmdID; return cmdID, 'context' end
  if not mayRegister then return nil, 'unknown' end
  -- Started from __startup.lua (or anything else that is not an action click):
  -- the context is empty, but the file itself is registered. Asking to add a
  -- script that is already there returns its existing id.
  local self = getScriptSelfPath()
  if self and r.AddRemoveReaScript then
    local ok, id = pcall(r.AddRemoveReaScript, true, 0, self, true)
    id = ok and tonumber(id) or nil
    if id and id > 0 then st.cmdIdKnown = id; return id, 'registry' end
  end
  -- false rather than nil: a remembered "we looked and there is none", so the
  -- expensive lookup is not repeated on the next press either.
  st.cmdIdKnown = false
  return nil, 'none'
end

-- Are we the second half of a restart the user just asked for? A timestamp
-- rather than a flag, and it is not consumed by whoever reads it first: the new
-- instance may well start while the old one still has a heartbeat, take the
-- single-instance exit and never reach the line that would clear it. A window
-- that expires on its own cannot be eaten by an instance that does not get far
-- enough to use it.
function Upd.restartPending()
  local t = tonumber(getGlobalExt(K.UPD_SHOW_KEY))
  if not t then return false end
  return (os.time() - t) <= K.UPD_SHOW_SECS
end

-- Cheap enough to ask while drawing: either the id is already in hand, or there
-- is a way to get it once the button is actually pressed.
function Upd.canRestart()
  local st = state.upd
  if st and st.cmdIdKnown then return true end
  if st and st.cmdIdKnown == false then return false end
  local _, _, _, cmdID = r.get_action_context()
  if tonumber(cmdID) and tonumber(cmdID) > 0 then return true end
  return r.AddRemoveReaScript ~= nil
end

function Upd.restart()
  local cmdID = Upd.cmdId(true)
  if not cmdID then return false end
  -- Drop our heartbeat first. The new instance checks for a live one and would
  -- otherwise decide another copy is already running, signal "show window" and
  -- exit -- which looks exactly like the restart doing nothing.
  pcall(clearInstanceHeartbeat)
  -- A restart the user asked for should come back visible, even for someone
  -- who starts the script in the background: they pressed a button and expect
  -- to see the result. The new instance reads this once and clears it, so the
  -- setting is untouched for every ordinary launch.
  setGlobalExt(K.UPD_SHOW_KEY, tostring(os.time()))
  -- flag&1: auto-terminate when re-launched while running. flag&2: and then
  -- launch again. Set here and not at startup on purpose: permanently on, a
  -- second click on the action would restart the script instead of bringing the
  -- hidden window up, which is what "Start in background" depends on.
  if r.set_action_options then pcall(r.set_action_options, 3) end
  r.Main_OnCommand(cmdID, 0)
  state.running = false
  return true
end

-- ── One call per frame ───────────────────────────────────────────────────────

function Upd.poll()
  local st = Upd.st()

  -- A restart asked for by the UI is carried out here, between frames, rather
  -- than inside the click that wanted it: Main_OnCommand tears this instance
  -- down, and doing that in the middle of drawing is asking for trouble.
  if st.restartWanted then
    st.restartWanted = nil
    if Upd.restart() then return end
    st.error = 'This script is not in the action list, so it cannot restart ' ..
               'itself. Please start it again by hand. (Looked for: ' ..
               tostring(getScriptSelfPath()) .. ')'
  end

  Upd.watch()

  -- Ask GitHub at most once a day, and never in the first seconds of a run --
  -- startup is busy enough. Detached, so nothing here waits for the network.
  if not st.job and not st.firstSeen then st.firstSeen = r.time_precise() end
  if not st.job and st.firstSeen and r.time_precise() - st.firstSeen > 5
     and Upd.enabled() and Upd.due() then
    Upd.startCheck(false)
  end

  local job = st.job
  if job then
    local now = r.time_precise()
    if now >= (job.nextCheck or 0) then
      job.nextCheck = now + 0.25
      local done = false
      if job.kind == 'check' then
        done = Upd.finishCheck(job)
      else
        -- The downloaded file is complete when it verifies, and no sooner.
        -- Nothing else can tell us: a detached curl leaves no exit code.
        if fileSize(job.path) and Upd.verify(job.path, job.want, job.size) then
          done = Upd.finishInstall(job)
          if done then st.justInstalled = job.want end
        end
      end
      if done or (now - (job.started or now)) > K.UPD_JOB_SECS then
        if not done and job.kind == 'install' then
          -- Ran out of time with nothing usable: clean up, say so, leave the
          -- installed script exactly as it was.
          deleteFile(job.path)
          st.error = st.error or 'The download did not finish.'
        end
        deleteFile(job.cfg)
        if job.hdr then deleteFile(job.hdr) end
        if job.head then deleteFile(job.head) end
        st.job = nil
      end
    end
  end

  -- The ReaPack path has no callback, so the watchdog above is what tells us the
  -- file changed. What it does NOT tell us is that ReaPack has finished: the
  -- rename happens in InstallTask::commit and the report dialog only afterwards,
  -- in onFinish. Calling back into ReaPack in that gap -- which is what putting
  -- the repository setting back does, via AddSetRepository and ProcessQueue --
  -- lands in the middle of a running transaction, and commitConfig then calls
  -- runTasks on it. That crashed Reaper three times.
  --
  -- So once we have asked ReaPack to do something, we do not touch it again for
  -- the rest of this session. The repair note stays on file and the next start
  -- acts on it -- and after an update there is a restart anyway.
  if st.rpStarted then
    if st.onDisk then
      st.rpStarted = nil
    elseif r.time_precise() - st.rpStarted > K.UPD_RP_SECS then
      st.rpStarted = nil
      st.error = 'ReaPack did not report an update. You can try replacing the file directly.'
    end
  end
end

local function loadProductions()
  state.productionsFetching = true
  state.productionsError = nil
  local list, err = apiProductions()
  state.productionsFetching = false
  if err == 'unauthorized' then
    state.errorMsg = 'Token is no longer valid — please reconnect.'
    logout()
    return
  end
  if err then
    state.productionsError = err
    return
  end
  state.productions = list
  -- Cover art is started one frame later, not here: the list should be on screen
  -- filling itself in, not waiting. The download itself runs detached and the
  -- covers appear as they land -- see Art.startJob. Nothing is fetched twice.
  Art.st().pending = true
  -- Refresh bound production info
  if state.boundProductionId then
    for _, p in ipairs(list) do
      if p.id == state.boundProductionId then state.boundProduction = p; break end
    end
    if not state.boundProduction then
      state.boundProduction = { id = state.boundProductionId, title = '(not found)', artist_name = '' }
    end
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- A/B COMPARE — hidden reference track (CuePort version vs DAW mix)
-- ══════════════════════════════════════════════════════════════════════════════
-- Downloads the active version and plays it from a hidden track that bypasses
-- the project master and goes straight to hardware out 1/2. A/B is then a
-- mute-swap between that reference and the master — both run under the one
-- transport, so they stay sample-synced. The track is temporary: removed on
-- production switch, window/script exit, or the "Remove" button.
--
-- The *audio file* is deliberately NOT temporary. Reaper saves every track it
-- has, hidden ones included, so a project that is saved while A/B is loaded
-- ends up pointing at this file. Up to v1.5.2 the file was a /tmp scratch file
-- that got deleted on script exit, and re-opening such a project greeted the
-- user with Reaper's "media not found" prompt. So:
--   • the file lives next to the project (CuePort A-B/) and survives removal
--   • it is only deleted once no saved project can still reference it
--   • a reference track that comes back with a re-opened project is detected
--     and cleaned out, which frees the file on the next save

-- Peaks are built asynchronously. Ask for them before they exist and Reaper
-- hands out a buffer of zeros; leave them unbuilt and Reaper does the work
-- itself whenever it feels the need -- which, for a file it has no peak cache
-- for, is every time the arrange view comes back to the front. Mode 0 says how
-- many passes are left, mode 1 works at one, mode 2 finishes.
--
-- Two ceilings, not one. The clock is the ceiling that matters in Reaper; the
-- spin count is the one that matters anywhere the clock does not move, and a
-- loop whose only exit is a clock is a hang waiting for a stopped one.
local function ensurePeaks(src, seconds)
  if not src then return end
  if not r.APIExists or not r.APIExists('PCM_Source_BuildPeaks') then return end
  local okB, need = pcall(r.PCM_Source_BuildPeaks, src, 0)
  if not okB or not need or need == 0 then return end
  local t0, left, spins = r.time_precise(), need, 0
  while left ~= 0 and spins < 20000 and (r.time_precise() - t0) < (seconds or 10) do
    local ok2, res = pcall(r.PCM_Source_BuildPeaks, src, 1)
    if not ok2 then break end
    left = res
    spins = spins + 1
  end
  pcall(r.PCM_Source_BuildPeaks, src, 2)
end

-- Reaper redraws the track list when it feels like it, not when the track list
-- changes. Add a track and hide it in the same pass and the TCP can keep
-- showing it, and the Track Manager -- if it was already open -- can keep
-- showing nothing, until something else forces a redraw: a click in the TCP,
-- or the next track the user adds. Reported from the forum, and it has been
-- like this since v1.28 (the function that builds the reference is byte for
-- byte the same there). This is the call that says "now".
--
-- Four things, because they are four different things, and it turned out that
-- only the last one reaches the Track Manager.
--
-- TrackList_AdjustWindows redraws the TCP and the mixer. That works -- the
-- reference disappears from the arrange at once. CSurf_SetTrackListChange
-- announces the change to control surfaces. Neither wakes the Track Manager:
-- it kept showing nothing until the user clicked somewhere, and a click is a
-- SELECTION change. That is what it watches.
--
-- Guessed twice and wrong twice, so the third time it was measured instead:
-- test/reaper-probe-trackmanager.lua walks nine candidates in the user's own
-- Reaper and asks after each one. It named this one, with the control (nothing
-- called) answering no -- so it is not the dialog doing it.
--
-- The touch is arranged so his own selection is never disturbed: an
-- UNSELECTED track is selected and unselected again. Only if every track in
-- the project is already selected does it go the other way round, and then it
-- puts it back in the same breath.
local function touchTrackSelection(pref)
  if not r.SetTrackSelected or not r.IsTrackSelected then return end
  local tr = (pref and not r.IsTrackSelected(pref)) and pref or nil
  if not tr then
    for i = 0, r.CountTracks(0) - 1 do
      local t = r.GetTrack(0, i)
      if t and not r.IsTrackSelected(t) then tr = t; break end
    end
  end
  if tr then r.SetTrackSelected(tr, true); r.SetTrackSelected(tr, false); return end
  -- Everything is selected. Deselect and reselect the first one -- a change
  -- either way is a change, and this one is undone immediately.
  local t = r.GetTrack(0, 0)
  if t then r.SetTrackSelected(t, false); r.SetTrackSelected(t, true) end
end

local function refreshTrackList(pref)
  if r.CSurf_SetTrackListChange then pcall(r.CSurf_SetTrackListChange) end
  if r.TrackList_AdjustWindows then pcall(r.TrackList_AdjustWindows, false) end
  if r.TrackList_UpdateAllExternalSurfaces then
    pcall(r.TrackList_UpdateAllExternalSurfaces)
  end
  pcall(touchTrackSelection, pref)
  if r.UpdateArrange then pcall(r.UpdateArrange) end
end

-- (The table itself is declared further up, above logout, which has to be able
-- to tear the reference down.)
function AB.globalCacheDir()
  return r.GetResourcePath() .. pathSep() .. 'CuePort' .. pathSep() .. 'ab-cache'
end

function AB.storeDir()
  local _, projfn = r.EnumProjects(-1, '')
  local dir = dirNameOf(projfn)
  if dir ~= '' then return dir .. pathSep() .. K.AB_DIR_NAME end
  return AB.globalCacheDir()
end

-- File name is keyed by version id, so a new version in CuePort never reuses
-- the previously downloaded audio (which would silently A/B against a stale
-- mix). Falls back to the production id when the id is unknown, e.g. when the
-- filename came from the persisted waveform cache rather than a fresh sync.
function AB.fileName()
  local ext = 'wav'
  local fn = state.versionFilename
  if fn then
    local e = fn:match('%.([%w]+)%s*$')
    if e then ext = e:lower():gsub('[^%w]', '') end
  end
  if ext == '' then ext = 'wav' end
  local key = tostring(state.versionId or state.boundProductionId or 'ref'):gsub('[^%w%-_]', '')
  if key == '' then key = 'ref' end
  return 'cueport_ab_' .. key .. '.' .. ext
end

-- Full destination path, creating the folder on the way.
function AB.targetPath()
  local dir = AB.storeDir()
  r.RecursiveCreateDirectory(dir, 0)
  return dir .. pathSep() .. AB.fileName()
end

-- Only ever delete files we wrote ourselves — the path can point into the
-- user's project folder, so a stray value must not turn into a delete.
function AB.deleteAudioFile(path)
  if not path or path == '' then return end
  if not baseNameOf(path):match('^cueport_ab_') then return end
  deleteFile(path)
end

-- Remember a file that a saved project still points at. It is deleted once
-- that project has been saved again without the reference track (see
-- AB.onProjectSaved). Kept in the global ExtState rather than the project's, so
-- noting it down doesn't dirty the project the user just saved.
function AB.scheduleOrphanDelete(path)
  if not path or path == '' then return end
  local _, projfn = r.EnumProjects(-1, '')
  setGlobalExt(K.AB_ORPHAN_KEY, json.encode({ path = path, proj = projfn or '' }))
end

-- Blocking download of the active version's audio to destPath via curl.
-- Returns ok(bool), err(string|nil).
function AB.download(destPath)
  -- Download to a sidecar first and move it into place only once it is
  -- complete, so an aborted transfer can never be mistaken for a usable
  -- cached file on the next run.
  local partPath = destPath .. '.part'
  deleteFile(partPath)
  local cfgPath = tmpPath('abdl.cfg')
  local cfg = {
    '--silent', '--show-error', '--location',
    '--connect-timeout 15', '--max-time 300',
  }
  for k, v in pairs(authHeaders()) do
    cfg[#cfg+1] = 'header = "' .. cfgQ(k .. ': ' .. v) .. '"'
  end
  cfg[#cfg+1] = 'output = "' .. cfgQ(partPath) .. '"'
  cfg[#cfg+1] = 'write-out = "\\n__CUEPORT_STATUS__:%{http_code}"'
  -- The version is named explicitly: without it the server hands back its
  -- default (newest mixmaster), which is the wrong file the moment the user has
  -- switched to anything else -- and it would be A/B'd against a waveform that
  -- belongs to a different mix.
  local abUrl = state.apiUrl .. '/reaper/audio?production_id=' .. (state.boundProductionId or '')
  if state.versionId and state.versionId ~= '' then
    abUrl = abUrl .. '&version_id=' .. state.versionId
  end
  cfg[#cfg+1] = 'url = "' .. cfgQ(abUrl) .. '"'
  if not writeFile(cfgPath, table.concat(cfg, '\n')) then
    return false, 'Could not write download config'
  end
  local raw = r.ExecProcess(curlCfgCmd(cfgPath), 305000)
  local _, out = parseExecOutput(raw)
  deleteFile(cfgPath)
  local status = tonumber((out or ''):match('__CUEPORT_STATUS__:(%d+)'))
  if status ~= 200 then
    deleteFile(partPath)
    return false, 'Download failed (HTTP ' .. tostring(status or '?') .. ')'
  end
  local sz = fileSize(partPath)
  if not sz then deleteFile(partPath); return false, 'Downloaded file missing' end
  if sz < 1024 then deleteFile(partPath); return false, 'Downloaded file looks empty' end
  deleteFile(destPath)
  if not os.rename(partPath, destPath) then
    deleteFile(partPath)
    return false, 'Could not write ' .. destPath
  end
  return true
end

-- Every A/B reference track in the active project, with the instance id that
-- built it. Tracks written by v1.5.2 and older carry the literal '1'; they are
-- treated like any other foreign owner, i.e. as a leftover to clean up.
function AB.findAll()
  local out = {}
  for i = 0, r.CountTracks(0) - 1 do
    local t = r.GetTrack(0, i)
    local ok, m = r.GetSetMediaTrackInfo_String(t, K.AB_TRACK_EXT_KEY, '', false)
    if ok and m and m ~= '' then out[#out+1] = { track = t, owner = m } end
  end
  return out
end

function AB.ownerId() return state.instanceId or '1' end

-- The reference track this run is responsible for.
function AB.find()
  for _, e in ipairs(AB.findAll()) do
    if e.owner == AB.ownerId() then return e.track end
  end
  return nil
end

-- Path of the audio a reference track points at (nil when it has no item).
function AB.trackFilePath(tr)
  local item = tr and r.GetTrackMediaItem(tr, 0)
  if not item then return nil end
  local take = r.GetActiveTake(item)
  if not take then return nil end
  local src = r.GetMediaItemTake_Source(take)
  if not src then return nil end
  local ok, a, b = pcall(r.GetMediaSourceFileName, src, '')
  if not ok then return nil end
  local path = (type(a) == 'string' and a ~= '' and a) or (type(b) == 'string' and b ~= '' and b) or nil
  return path
end

-- Muting the master is what silences the DAW mix during A/B — and it is saved
-- with the project like anything else. The flag lets a later run tell "this
-- master is muted because of A/B" from "the user muted it", so re-opening a
-- project that was saved on the CuePort side doesn't stay silent.
function AB.setMasterMuted(muted)
  local master = r.GetMasterTrack(0)
  if master then r.SetMediaTrackInfo_Value(master, 'B_MUTE', muted and 1 or 0) end
  setProjExt(K.AB_MASTER_MUTE_KEY, muted and '1' or '')
end

-- Mute-swap: reference audible vs master audible.
function AB.applyState(onCuePort)
  local ref = AB.find()
  if ref then r.SetMediaTrackInfo_Value(ref, 'B_MUTE', onCuePort and 0 or 1) end
  AB.setMasterMuted(onCuePort)
  state.ab.onCuePort = onCuePort
end

-- Build (or rebuild) the hidden reference track from a downloaded file.
function AB.buildTrack(filePath)
  -- InsertTrackAtIndex makes a VISIBLE track, and it is two calls later that it
  -- is hidden. Without this the user gets a track flashing into his arrange for
  -- a frame -- or, worse, staying there, because nothing told Reaper to redraw.
  r.PreventUIRefresh(1)
  local old = AB.find()
  if old then r.DeleteTrack(old) end

  local idx = r.CountTracks(0)
  r.InsertTrackAtIndex(idx, false)
  local tr = r.GetTrack(0, idx)
  if not tr then r.PreventUIRefresh(-1); refreshTrackList(); return false, 'Could not create track' end

  r.GetSetMediaTrackInfo_String(tr, 'P_NAME', K.AB_TRACK_NAME, true)
  r.GetSetMediaTrackInfo_String(tr, K.AB_TRACK_EXT_KEY, AB.ownerId(), true)
  -- Background track: hidden from arrange + mixer.
  r.SetMediaTrackInfo_Value(tr, 'B_SHOWINTCP', 0)
  r.SetMediaTrackInfo_Value(tr, 'B_SHOWINMIXER', 0)
  -- Bypass the master/parent send so the reference does NOT run through the
  -- project's master chain…
  r.SetMediaTrackInfo_Value(tr, 'B_MAINSEND', 0)
  -- …and instead route straight to hardware outputs 1/2.
  local sendIdx = r.CreateTrackSend(tr, nil)  -- nil dest = hardware output send
  if sendIdx and sendIdx >= 0 then
    r.SetTrackSendInfo_Value(tr, 1, sendIdx, 'I_DSTCHAN', 0)  -- 0 = stereo outs 1/2
  end

  -- Place the audio so audio-time 0 lands at internal position -offset (the
  -- render-start), matching the comment markers + waveform mapping.
  local offset = getProjectStartOffset()
  local src = r.PCM_Source_CreateFromFile(filePath)
  if not src then
    r.DeleteTrack(tr)
    r.PreventUIRefresh(-1); refreshTrackList()
    return false, 'Could not read audio file'
  end
  -- Build the peak cache once, here, while the user is already waiting for the
  -- download. Without it Reaper carries the reference with no cache on disk and
  -- re-reads the whole file every time the window comes back to the front --
  -- reported as "the A/B peaks are computed again" after a minimise or an
  -- alt-tab. The file sits beside the project (or in our own cache folder), so
  -- the .reapeaks Reaper writes lands somewhere we already clean up.
  ensurePeaks(src, 20)
  local item = r.AddMediaItemToTrack(tr)
  local take = r.AddTakeToMediaItem(item)
  r.SetMediaItemTake_Source(take, src)
  r.SetMediaItemInfo_Value(item, 'D_POSITION', -offset)
  r.SetMediaItemInfo_Value(item, 'D_LENGTH', r.GetMediaSourceLength(src) or 0)
  r.UpdateItemInProject(item)
  r.PreventUIRefresh(-1)
  refreshTrackList(tr)
  return true
end

-- Keep the reference item aligned when the render-start offset changes.
function AB.reposition()
  local tr = AB.find()
  if not tr then return end
  local item = r.GetTrackMediaItem(tr, 0)
  if not item then return end
  r.SetMediaItemInfo_Value(item, 'D_POSITION', -getProjectStartOffset())
  r.UpdateItemInProject(item)
  r.UpdateTimeline()
end

-- Tear down: remove the reference track and unmute the master.
--
-- The audio file is only deleted when nothing on disk can point at it. Once
-- the user has saved the project while the reference existed, the .rpp holds
-- its path — deleting it there is exactly what produced the "media not found"
-- prompt on the next open. In that case the file is kept and queued for
-- deletion after the project has been saved without the reference.
-- `keepAudio` for the teardown at script exit. The track has to go either way
-- -- it is stamped with this run and a later run would only sweep it out -- but
-- the downloaded audio is worth keeping: quitting the script is not "I am done
-- with this reference", it is "the script stopped", and the same project will
-- very likely be opened again wanting the same version. Deleting it there meant
-- every restart pulled the whole file down again.
--
-- It is not left to sit forever: the file is queued as an orphan, so the next
-- save of that project without a reference track in it drops it. Pressing
-- "Remove" is the explicit "done with it" and still deletes straight away.
function AB.remove(keepAudio)
  local tr = AB.find()
  if tr then
    r.Undo_BeginBlock()
    r.DeleteTrack(tr)
    r.Undo_EndBlock('CuePort: remove A/B reference', -1)
    refreshTrackList()
  end
  AB.setMasterMuted(false)
  if state.ab.tempPath then
    if state.ab.persisted or keepAudio then
      AB.scheduleOrphanDelete(state.ab.tempPath)
      -- The .rpp still lists the track we just removed → make sure the user's
      -- next save writes a project without it. Only when it really is in there:
      -- dirtying a project the reference was never saved into would put a
      -- "save changes?" in the way of a plain script quit.
      if tr and state.ab.persisted then r.MarkProjectDirty(0) end
    else
      AB.deleteAudioFile(state.ab.tempPath)
    end
  end
  state.ab.loaded = false
  state.ab.onCuePort = false
  state.ab.forId = nil
  state.ab.forVersion = nil
  state.ab.tempPath = nil
  state.ab.persisted = false
  r.UpdateTimeline()
end

-- A reference track left behind by an earlier run — the project was saved
-- while A/B was loaded, and re-opening it brought the hidden track back. Drop
-- it, restore the master, and dirty the project so the next save is clean.
function AB.cleanupStrays()
  local mine = AB.ownerId()
  local removed = false
  for _, e in ipairs(AB.findAll()) do
    if e.owner ~= mine then
      local path = AB.trackFilePath(e.track)
      r.DeleteTrack(e.track)
      removed = true
      if path then AB.scheduleOrphanDelete(path) end
    end
  end
  if not removed then return end
  if getProjExt(K.AB_MASTER_MUTE_KEY) then AB.setMasterMuted(false) end
  refreshTrackList()
  r.MarkProjectDirty(0)
  r.UpdateTimeline()
end

-- Called when a save has just completed (IsProjectDirty 1 → 0).
function AB.onProjectSaved()
  if #AB.findAll() > 0 then
    -- The project on disk now points at our audio file.
    state.ab.persisted = true
    return
  end
  state.ab.persisted = false
  -- No reference in the project any more → a file we queued earlier is now
  -- unreferenced and can go.
  local raw = getGlobalExt(K.AB_ORPHAN_KEY)
  if not raw or raw == '' then return end
  local ok, parsed = pcall(json.decode, raw)
  if not ok or type(parsed) ~= 'table' then setGlobalExt(K.AB_ORPHAN_KEY, ''); return end
  local _, projfn = r.EnumProjects(-1, '')
  if (parsed.proj or '') ~= (projfn or '') then return end  -- a different project saved
  AB.deleteAudioFile(parsed.path)
  setGlobalExt(K.AB_ORPHAN_KEY, '')
end

-- Global fallback cache (used by projects that were never saved to disk).
-- Files next to a saved project are that project's media and are left alone.
-- How many of our files sit in one directory, and how big they are together.
-- Only ours: the project folder belongs to the user, and a count that included
-- their files would be a number about their work, not about this script.
-- `prefix` defaults to the A/B naming. It has to be a parameter: the cover cache
-- uses the same counting but a different prefix, and a hard-coded one would have
-- reported an always-empty folder -- exactly the misleading row v1.18.5 fixed.
-- Reaper writes a .reapeaks sidecar beside the reference audio. It belongs to
-- the file and is deleted with it, so its bytes count -- but it is not a second
-- reference, so it must not raise the file count. Counting it would tell the
-- user he has two A/B files cached when he has one.
function AB.statsIn(dir, prefix)
  prefix = prefix or '^cueport_ab_'
  local count, bytes = 0, 0
  local i = 0
  while true do
    local fn = r.EnumerateFiles(dir, i)
    if not fn then break end
    if fn:match(prefix) then
      if not fn:match('%.reapeaks$') then count = count + 1 end
      bytes = bytes + (fileSize(dir .. pathSep() .. fn) or 0)
    end
    i = i + 1
  end
  return count, bytes
end

function AB.cacheStats() return AB.statsIn(AB.globalCacheDir()) end

-- The other place, and the one that is used far more often: a saved project
-- keeps its reference audio beside the .rpp. nil while the project has never
-- been written to disk -- there is no folder to look in, and everything goes to
-- the shared cache instead.
function AB.projectStats()
  local _, projfn = r.EnumProjects(-1, '')
  local dir = dirNameOf(projfn)
  if dir == '' then return nil end
  return AB.statsIn(dir .. pathSep() .. K.AB_DIR_NAME)
end

-- Both, at most once a second. Settings redraws at frame rate and this walks
-- directories; without the hold it would be two scans per frame for numbers
-- that change when a file is written, not sixty times a second.
function AB.storageStats()
  local now = r.time_precise()
  local s = state.abStats
  if s and now < s.at + 1.0 then return s end
  s = { at = now }
  s.cacheCount, s.cacheBytes = AB.cacheStats()
  s.projCount,  s.projBytes  = AB.projectStats()
  state.abStats = s
  return s
end

function AB.clearCache()
  local dir = AB.globalCacheDir()
  local names = {}
  local i = 0
  while true do
    local fn = r.EnumerateFiles(dir, i)
    if not fn then break end
    if fn:match('^cueport_ab_') then names[#names+1] = fn end
    i = i + 1
  end
  for _, fn in ipairs(names) do deleteFile(dir .. pathSep() .. fn) end
  return #names
end

-- Perform the queued download + build. Called from the loop AFTER one painted
-- "loading…" frame, so the UI shows feedback before the blocking curl call.
function AB.doLoad()
  if state.ab.loaded then AB.remove() end
  local dest = AB.targetPath()
  -- The file name is keyed by version id, so anything already sitting there is
  -- this exact version — reuse it instead of pulling the audio down again.
  local cached = (fileSize(dest) or 0) >= 1024
  if not cached then
    local ok, err = AB.download(dest)
    if not ok then
      state.ab.downloading = false
      state.ab.status = err or 'Download failed'
      return
    end
  end
  local bok, berr = AB.buildTrack(dest)
  if not bok then
    state.ab.downloading = false
    state.ab.status = berr or 'Could not build reference track'
    if not cached then AB.deleteAudioFile(dest) end
    return
  end
  state.ab.persisted = false
  state.ab.tempPath = dest
  state.ab.loaded = true
  state.ab.forId = state.boundProductionId
  state.ab.forVersion = state.versionId
  state.ab.downloading = false
  state.ab.status = nil
  AB.applyState(false)  -- start on the DAW mix
end

-- A version switch while the reference is loaded. The audio on the hidden track
-- belongs to the version being left, so it cannot stay -- and it is not quietly
-- replaced either: the track goes, its file goes with it (AB.remove deletes
-- what it downloaded), and the new version has to be loaded on purpose. That is
-- the point of the button: an automatic re-download on every switch is a file
-- per version sitting next to the project for a comparison nobody asked for.
function AB.dropForVersion()
  if not state.ab.loaded and not state.ab.pendingLoad then return end
  state.ab.pendingLoad, state.ab.downloading, state.ab.frameShown = false, false, false
  AB.remove()
  state.ab.status = nil
end

-- ── Render settings: borrow, use, hand back ────────────────────────────────
--
-- The whole reason this table exists is one sentence from the user: the script
-- must not rummage around in the native render dialog. It has to, briefly --
-- a render runs "using the most recent render settings", so what we do not set
-- comes from whatever was rendered last, and that may well have been a mono
-- bounce for the bassist. So: write down all 21 fields, set ours, render, put
-- every one of them back byte for byte.
--
-- That the write-back really is byte-exact is not an assumption:
-- test/reaper-probe-render.lua measured it on the user's machine, including
-- the format blob. Without that result this whole feature would be dead.
local Rnd = {}

K.RND_PREFIX    = 'cueport_render_'
K.RND_NOTE_NAME = 'cueport_render_restore.txt'
-- FLAC 24 bit, level 5 -- the same file the studio portal produces, measured
-- from this four-byte cookie on the probe run. NEVER compare RENDER_FORMAT
-- against this string: it reads back expanded, not as the cookie.
K.RND_FORMAT    = 'calf'
K.ACTION_RENDER_LAST = 41824   -- File: Render project, using the most recent settings

-- Source selection inside RENDER_SETTINGS. Measured, not read off the docs:
-- four probe runs on the user's machine gave 0 for master mix, 3 (bits 0+1)
-- for stems, 128 (bit 7) for selected tracks through the master. Every other
-- bit in that field is something we did not identify and therefore leave
-- exactly as we found it.
K.RND_SRC_MASK    = 131
K.RND_SRC_MASTER  = 0
K.RND_SRC_STEMS   = 3
K.RND_SRC_VIAMSTR = 128
-- Bounds, from the same runs.
K.RND_BOUNDS_PROJECT = 1
K.RND_BOUNDS_TIMESEL = 2

K.RND_STR_FIELDS = { 'RENDER_FILE', 'RENDER_PATTERN', 'RENDER_FORMAT', 'RENDER_FORMAT2' }
K.RND_NUM_FIELDS = {
  'RENDER_SETTINGS', 'RENDER_BOUNDSFLAG', 'RENDER_CHANNELS', 'RENDER_SRATE',
  'RENDER_STARTPOS', 'RENDER_ENDPOS', 'RENDER_TAILFLAG', 'RENDER_TAILMS',
  'RENDER_ADDTOPROJ', 'RENDER_DITHER', 'RENDER_NORMALIZE', 'RENDER_NORMALIZE_TARGET',
  'RENDER_BRICKWALL', 'RENDER_FADEIN', 'RENDER_FADEOUT',
  'RENDER_FADEINSHAPE', 'RENDER_FADEOUTSHAPE',
}

function Rnd.getNum(key)
  local ok, v = pcall(r.GetSetProjectInfo, 0, key, 0, false)
  if not ok then return nil end
  return v
end

function Rnd.setNum(key, v)
  pcall(r.GetSetProjectInfo, 0, key, v, true)
end

function Rnd.getStr(key)
  local ok, _, v = pcall(r.GetSetProjectInfo_String, 0, key, '', false)
  if not ok then return nil end
  return v
end

function Rnd.setStr(key, v)
  pcall(r.GetSetProjectInfo_String, 0, key, v or '', true)
end

-- Everything we are about to touch, plus everything next to it. The list is
-- the one a Reaper render preset covers; a field left out here is a field that
-- silently keeps our value afterwards.
function Rnd.snapshot()
  local snap = { str = {}, num = {} }
  for _, k in ipairs(K.RND_STR_FIELDS) do snap.str[k] = Rnd.getStr(k) end
  for _, k in ipairs(K.RND_NUM_FIELDS) do snap.num[k] = Rnd.getNum(k) end
  return snap
end

-- Strings first: RENDER_FORMAT decides which of the numeric fields Reaper even
-- considers meaningful, so putting the numbers back before the format can have
-- them land in the wrong interpretation.
function Rnd.restore(snap)
  if type(snap) ~= 'table' then return false end
  for _, k in ipairs(K.RND_STR_FIELDS) do
    if snap.str and snap.str[k] ~= nil then Rnd.setStr(k, snap.str[k]) end
  end
  for _, k in ipairs(K.RND_NUM_FIELDS) do
    if snap.num and snap.num[k] ~= nil then Rnd.setNum(k, snap.num[k]) end
  end
  return true
end

-- ── the note that survives a crash ─────────────────────────────────────────
--
-- A blocking render can take minutes on a long project, and if Reaper dies in
-- the middle the restore below never runs -- the producer is then left with our
-- output folder and our format sitting in his render dialog. Same shape as the
-- repo repair note of v1.30.0: written BEFORE the first write, worked off by
-- the next start.
--
-- A file, not ExtState: persisted ExtState is flushed when Reaper exits, and
-- an exit is exactly what did not happen here.
--
-- Only for a SAVED project, and keyed by its path. An unsaved project has
-- nothing on disk that could carry our settings forward, so there is nothing to
-- repair -- and a note without a path would have to guess which project it
-- belongs to, which is worse than not writing one.
function Rnd.projectPath()
  local _, fn = r.EnumProjects(-1, '')
  return fn or ''
end

function Rnd.notePath()
  return AB.globalCacheDir() .. pathSep() .. K.RND_NOTE_NAME
end

-- Lossless and one line per field: the format blob is arbitrary bytes and may
-- well contain a newline, so anything that splits on lines has to escape first.
local function rndEsc(s)
  return (tostring(s):gsub('[^%w%._%-]', function(c) return ('%%%02X'):format(c:byte()) end))
end

local function rndUnesc(s)
  return (s:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end

function Rnd.writeNote(snap)
  local proj = Rnd.projectPath()
  if proj == '' then return false end
  -- The cache folder may not exist yet: the note can be the very first thing
  -- this script ever writes there, and io.open does not make directories.
  r.RecursiveCreateDirectory(AB.globalCacheDir(), 0)
  local out = { 'project ' .. rndEsc(proj) }
  for _, k in ipairs(K.RND_STR_FIELDS) do
    if snap.str[k] ~= nil then out[#out+1] = 's ' .. k .. ' ' .. rndEsc(snap.str[k]) end
  end
  for _, k in ipairs(K.RND_NUM_FIELDS) do
    if snap.num[k] ~= nil then out[#out+1] = 'n ' .. k .. ' ' .. rndEsc(snap.num[k]) end
  end
  return writeFile(Rnd.notePath(), table.concat(out, '\n') .. '\n')
end

function Rnd.readNote()
  local body = readFile(Rnd.notePath())
  if not body or body == '' then return nil end
  local snap, proj = { str = {}, num = {} }, nil
  for line in body:gmatch('[^\n]+') do
    local kind, key, val = line:match('^(%S+)%s+(%S+)%s*(.*)$')
    if kind == 'project' then proj = rndUnesc(key)
    elseif kind == 's' and key then snap.str[key] = rndUnesc(val)
    elseif kind == 'n' and key then snap.num[key] = tonumber(rndUnesc(val)) end
  end
  if not proj then return nil end
  return snap, proj
end

function Rnd.clearNote() deleteFile(Rnd.notePath()) end

-- Run at start. Restores only into the project the note names -- putting one
-- project's render settings into another would be a second bug, not a repair.
function Rnd.repairIfNeeded()
  local snap, proj = Rnd.readNote()
  if not snap then return false end
  if proj ~= Rnd.projectPath() or proj == '' then return false end
  r.Undo_BeginBlock()
  Rnd.restore(snap)
  r.Undo_EndBlock('CuePort: Restore render settings', -1)
  Rnd.clearNote()
  return true
end

-- ── the profile ────────────────────────────────────────────────────────────
--
-- Deliberately short. Format, bit depth, sample rate and channel count are not
-- the user's to choose here: the file has to arrive the way CuePort wants it,
-- and that is decided in the portal, not in our judgement. What he does choose
-- is bounds and source, and those two are all this touches beyond the target
-- path.
function Rnd.apply(opts)
  opts = opts or {}
  Rnd.setStr('RENDER_FORMAT', K.RND_FORMAT)
  Rnd.setNum('RENDER_CHANNELS', 2)     -- the mono trap that started all of this
  Rnd.setNum('RENDER_SRATE', 0)        -- project rate; the portal does not resample either
  Rnd.setNum('RENDER_NORMALIZE', 0)
  Rnd.setNum('RENDER_BRICKWALL', 0)
  Rnd.setNum('RENDER_DITHER', 0)
  Rnd.setNum('RENDER_TAILFLAG', 0)
  Rnd.setNum('RENDER_FADEIN', 0)
  Rnd.setNum('RENDER_FADEOUT', 0)
  Rnd.setNum('RENDER_ADDTOPROJ', 0)    -- an upload must not leave an item behind

  Rnd.setNum('RENDER_BOUNDSFLAG',
             opts.bounds == 'timesel' and K.RND_BOUNDS_TIMESEL or K.RND_BOUNDS_PROJECT)

  -- Mask, do not overwrite: everything in RENDER_SETTINGS other than the three
  -- source bits is something we did not identify on the probe runs, and a field
  -- assigned outright would take those unknowns with it.
  local cur = Rnd.getNum('RENDER_SETTINGS') or 0
  local src = K.RND_SRC_MASTER
  if opts.source == 'stems' then src = K.RND_SRC_STEMS
  elseif opts.source == 'viamaster' then src = K.RND_SRC_VIAMSTR end
  Rnd.setNum('RENDER_SETTINGS', (math.floor(cur) & ~K.RND_SRC_MASK) | src)

  if opts.dir then Rnd.setStr('RENDER_FILE', opts.dir) end
  if opts.pattern then Rnd.setStr('RENDER_PATTERN', opts.pattern) end
end

-- Where a render of ours goes. Its own prefix, and not by accident:
-- AB.deleteAudioFile only ever removes '^cueport_ab_', so a bounce the producer
-- wanted to keep is not swept away with the reference audio.
function Rnd.outDir() return AB.storeDir() end

function Rnd.outName(versionKey)
  -- Not `versionKey or state.boundProductionId`: an empty string is TRUE in Lua,
  -- so that would take the empty one and fall straight through to 'render',
  -- putting two different productions' renders under the same name. Same trap
  -- as `x or default` with a numeric zero.
  local key = versionKey
  if key == nil or key == '' then key = state.boundProductionId end
  if key == nil or key == '' then key = 'render' end
  key = tostring(key):gsub('[^%w%-_]', '')
  if key == '' then key = 'render' end
  return K.RND_PREFIX .. key
end

-- ── looking at the file, not at the settings ───────────────────────────────
--
-- Deliberately the result and not the dialog: a mono plugin at the end of the
-- master chain produces a mono file without RENDER_CHANNELS ever saying so, and
-- that is the failure the producer would only hear about from the artist.
K.RND_AUDIO_EXT = { flac = true, wav = true, mp3 = true, aiff = true,
                    aif = true, m4a = true, ogg = true }

function Rnd.inspect(path)
  local info = { path = path, bytes = fileSize(path) or 0 }
  info.name = baseNameOf(path)
  info.ext  = (path:match('%.([%w]+)%s*$') or ''):lower()
  local ok, src = pcall(r.PCM_Source_CreateFromFile, path)
  if ok and src then
    local okL, len = pcall(r.GetMediaSourceLength, src)
    if okL then info.length = tonumber(len) or 0 end
    local okC, ch = pcall(r.GetMediaSourceNumChannels, src)
    if okC then info.channels = tonumber(ch) or 0 end
    local okS, sr = pcall(r.GetMediaSourceSampleRate, src)
    if okS then info.srate = tonumber(sr) or 0 end
    pcall(r.PCM_Source_Destroy, src)
  end
  return info
end

-- Hard stops and soft ones, kept apart on purpose. A hard stop means we do not
-- know what we would be uploading; a warning means we do, and it is the
-- producer's call. Turning a warning into a stop would make him fight the
-- script; turning a stop into a warning would let a stem end up on the artist's
-- production labelled as the mix.
function Rnd.check(info, expectSec)
  local errs, warns = {}, {}
  if not info or (info.bytes or 0) <= 0 then
    errs[#errs+1] = 'no file was written'
    return errs, warns
  end
  if not K.RND_AUDIO_EXT[info.ext or ''] then
    errs[#errs+1] = 'not an audio file (.' .. tostring(info.ext) .. ')'
  end
  if info.channels == 1 then
    warns[#warns+1] = 'the file is mono'
  end
  if expectSec and expectSec > 0 and (info.length or 0) > 0 then
    -- Generous: a tail, a fade or a rounding difference is normal. What this
    -- is looking for is the order-of-magnitude miss -- eight seconds where
    -- three minutes were meant, which is what a forgotten time selection
    -- produces.
    local off = math.abs(info.length - expectSec)
    if off > math.max(2.0, expectSec * 0.05) then
      warns[#warns+1] = ('length is %s, expected about %s')
        :format(formatTimestamp(info.length), formatTimestamp(expectSec))
    end
  end
  return errs, warns
end

-- Is this file this render's? Deliberately not a prefix test: the key is a
-- production id filed down to [%w%-_], so the pattern for `prod-1` is a prefix
-- of the one for `prod-11` -- and a prefix test would sweep away a bounce
-- belonging to a different production. Only `<pattern>.<ext>` counts, plus the
-- `<pattern>-2.<ext>` form Reaper uses when it refuses to overwrite.
function Rnd.isOurs(fn, pattern)
  if fn:sub(1, #pattern) ~= pattern then return false end
  local rest = fn:sub(#pattern + 1)
  return rest:match('^%.%w+$') ~= nil or rest:match('^%-%d+%.%w+$') ~= nil
end

-- Everything of ours already lying at the target. Reaper does not overwrite
-- silently -- it puts a number after the name -- so a leftover from last time
-- would make "exactly one file" false and hand back the wrong path.
function Rnd.clearTargets(dir, pattern)
  local i, names = 0, {}
  while true do
    local fn = r.EnumerateFiles(dir, i)
    if not fn then break end
    -- The peak cache goes too, or Reaper reads yesterday's peaks for today's
    -- file.
    if Rnd.isOurs(fn, pattern) or Rnd.isOurs((fn:gsub('%.reapeaks$', '')), pattern) then
      names[#names+1] = fn
    end
    i = i + 1
  end
  for _, fn in ipairs(names) do deleteFile(dir .. pathSep() .. fn) end
  return #names
end

function Rnd.producedFiles(dir, pattern)
  local i, out = 0, {}
  while true do
    local fn = r.EnumerateFiles(dir, i)
    if not fn then break end
    if Rnd.isOurs(fn, pattern) then out[#out+1] = dir .. pathSep() .. fn end
    i = i + 1
  end
  table.sort(out)
  return out
end

-- The whole trip. Returns ok, info-or-message, warnings.
--
-- The shape here is the one the probe run insisted on: the restore runs OUTSIDE
-- the pcall, so a throw in the middle still gives the producer his dialog back,
-- and the verdict is read off the files afterwards rather than claimed.
function Rnd.run(opts)
  opts = opts or {}
  local dir     = opts.dir or Rnd.outDir()
  local pattern = opts.pattern or Rnd.outName(opts.versionKey)

  r.RecursiveCreateDirectory(dir, 0)
  Rnd.clearTargets(dir, pattern)

  local snap = Rnd.snapshot()
  Rnd.writeNote(snap)

  local okRun = pcall(function()
    Rnd.apply({ bounds = opts.bounds, source = opts.source, dir = dir, pattern = pattern })
    r.Main_OnCommand(K.ACTION_RENDER_LAST, 0)
  end)

  Rnd.restore(snap)
  Rnd.clearNote()

  local files = Rnd.producedFiles(dir, pattern)
  if not okRun then return false, 'the render did not run' end
  if #files == 0 then
    -- The honest reading, and the one that comes up in practice: bounds set to
    -- a time selection that is not there.
    return false, 'the render wrote no file'
  end
  if #files > 1 then
    return false, ('the render wrote %d files -- stems or regions, not one mix'):format(#files)
  end

  local info = Rnd.inspect(files[1])
  local errs, warns = Rnd.check(info, opts.expectSec)
  if #errs > 0 then return false, errs[1], warns end
  return true, info, warns
end

-- Has he actually selected something? Measured, not asked: a dialog that comes
-- up every time gets clicked away, and the answer is already knowable.
-- start == end is Reaper's way of saying "nothing selected", and a
-- time-selection render would then write zero files.
function Rnd.timeSelection()
  local s, e = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  s, e = tonumber(s) or 0, tonumber(e) or 0
  if e - s <= 0 then return nil end
  return s, e - s
end

-- ── the waveform that goes up with the file ────────────────────────────────
--
-- Without it the version arrives in CuePort with no waveform at all, and stays
-- that way until somebody opens it in the portal or runs the admin backfill --
-- so the artist gets a player with nothing drawn in it. Building the peaks here
-- costs 0.017 s (measured, at the flat resolution this used to read); it reads
-- 1024 times as many values now -- see K.RND_PEAKS_SUBS -- so that number is a
-- floor, not the figure. The probe measured 282 ms for that read on a
-- three-minute file.
--
-- It goes through the same ensurePeaks as the A/B reference, so Reaper writes
-- its .reapeaks beside the rendered file. Rnd's own cleanup knows that name and
-- takes the sidecar with the render.
--
-- The cost is honest and named on the About page: reading peaks out needs a
-- take, and a take needs an item on a track. One track is inserted, read from,
-- and removed again inside one undo block. There is no way to read peaks from a
-- source that is not in the project.
-- The upload page goes two columns from this much room per PAGE, so each column
-- gets a little over 400 -- more than the 300 the whole page is held to in the
-- narrow test, and that width is the one that has to work.
K.UP_TWO_COL_MIN  = 820
-- How far back below the threshold it has to fall before it stacks again.
-- Wider than any scrollbar, which is the thing that would otherwise decide it.
K.UP_TWO_COL_HYST = 24
K.UP_COL_GAP      = 14

-- How tall the strip over the file that is about to go up is drawn, and how far
-- it will squeeze. Everything else on this page is a fixed number of lines, so
-- the strip is the one thing that can give -- and it has to, or pulling the
-- window down to its smallest leaves the last button half a line under the edge
-- and the whole page scrolling for it.
K.UP_WAVE_H   = 46
K.UP_WAVE_MIN = 18
-- What the loop draws under this page: one Dummy before the (empty) footer.
K.UP_TAIL     = 10

K.RND_PEAKS_N = 150   -- what the portal stores per version
-- How many sub-buckets are read per stored value. Reading 150 straight out of
-- the peaks API gives the MAXIMUM over ~1 second, and on a limited master that
-- is the ceiling in every second the music plays -- a solid block with no
-- structure in it. The portal stores the MEAN of |sample| over the same window,
-- which still has the arrangement in it.
--
-- There is no mean in the peaks API -- the third block is spectral, not RMS --
-- so it is read fine and averaged down. The finer the read, the closer the
-- average gets to the mean, because the maximum over a shrinking window IS the
-- sample once the window is one sample long. So the deviation from the portal's
-- curve falls monotonically with the number of sub-buckets, and the only
-- questions are how far it falls and what the reading costs.
--
-- Both have now been measured on a real file rather than simulated. Against the
-- curve the portal computed for the same three-minute master, at 256:
--
--   correlation 0.956, mean deviation 0.058, worst 0.19, both peaking in the
--   same 1/150th -- but the error is not spread evenly. In the loudest parts
--   the two curves agree to within 1%; in the quiet opening the script reads a
--   quarter low. That is the crest factor: the average of window maxima sits
--   above the mean of the samples by a factor that depends on the material, and
--   normalising divides by the factor at the LOUDEST point, so everywhere with
--   a smaller factor comes out too low.
--
-- The cure is the same one, applied harder: a shorter window has a smaller
-- crest factor, and at one sample it has none. The probe (test/reaper-probe-
-- peaks.lua) measured what Reaper will actually hand out -- 1024 sub-buckets,
-- 153,600 values for a three-minute file, in 282 ms, no truncation. So the
-- ladder starts there. 282 ms is real but it is spent once, next to an upload
-- that takes seconds.
--
-- A ladder, not one number: if the API hands back fewer values than were asked
-- for, the next size down is tried before giving up. Falling straight from the
-- top to a flat read would put the block back, which is worse than a coarser
-- average.
K.RND_PEAKS_SUBS = { 1024, 256, 64, 8 }

-- ── the same arithmetic the portal does, on the same numbers ───────────────
--
-- Everything above reads Reaper's PEAKS, and peaks are maxima. The portal reads
-- SAMPLES and takes the mean of their absolute value. No amount of reading
-- maxima finely enough turns one into the other: the average of window maxima
-- sits above the mean by a factor that depends on the material, normalising
-- divides by that factor at the loudest point, and every quieter part comes out
-- too low. Measured against the portal's own curve for a real master: the loud
-- parts agreed to within 1%, the quiet opening read a quarter low.
--
-- So this does not approximate it. It runs the portal's function:
--
--     raw   = channel 0 of the decoded audio
--     block = floor(#raw / 150)
--     out_i = mean of |raw[j]| for the block
--     normalised by the largest of them
--
-- Reaper hands out the decoded samples through an audio accessor, at the file's
-- own sample rate, so both sides work from the same numbers. The remaining
-- differences are two, and both are smaller than a rounding step: the browser
-- decodes at its audio context's rate rather than the file's, and the sample
-- count is worked out from the source length rather than counted.
--
-- It costs a pass over every sample of the file, which is far more work than
-- reading peaks. That is the price of the two pictures being the same picture.
-- If it cannot be done -- no accessor, a build without the API, a file that
-- reads as silence -- Rnd.peaks falls back to the peak ladder below, and says
-- so nowhere, because a coarse waveform is still better than none.
K.RND_WAVE_CHUNK = 65536   -- samples per channel per accessor read
K.RND_WAVE_SECS  = 60      -- hang guard, not a budget: nothing should near it

function Rnd.samplePeaks(tk, len, n)
  if not (r.APIExists and r.APIExists('GetAudioAccessorSamples')
          and r.CreateTakeAudioAccessor) then return nil end
  local rate = tonumber(state.rndWaveRate) or 0
  local chans = tonumber(state.rndWaveChans) or 0
  if rate <= 0 then return nil end
  local nch = (chans >= 2) and 2 or 1
  local total = math.floor(len * rate)
  local blk   = math.floor(total / n)
  if blk < 1 then return nil end

  local acc = r.CreateTakeAudioAccessor(tk)
  if not acc then return nil end
  local t0 = 0
  if r.GetAudioAccessorStartTime then
    t0 = tonumber(r.GetAudioAccessorStartTime(acc)) or 0
  end

  local buf = r.new_array(K.RND_WAVE_CHUNK * nch)
  local out, peak, deadline = {}, 0, r.time_precise() + K.RND_WAVE_SECS
  local bad = false
  for i = 1, n do
    local sum, done = 0, 0
    while done < blk do
      if r.time_precise() > deadline then bad = true; break end
      local want = blk - done
      if want > K.RND_WAVE_CHUNK then want = K.RND_WAVE_CHUNK end
      -- A silent stretch answers 0 and leaves the buffer zeroed, which is the
      -- right answer for silence. Only a file that is silent from end to end is
      -- suspicious, and that is caught by the peak check below.
      local okS = pcall(r.GetAudioAccessorSamples, acc, rate, nch,
                        t0 + ((i - 1) * blk + done) / rate, want, buf)
      if not okS then bad = true; break end
      for j = 0, want - 1 do
        local v = tonumber(buf[j * nch + 1]) or 0
        sum = sum + ((v < 0) and -v or v)
      end
      done = done + want
    end
    if bad then break end
    out[i] = sum / blk
    if out[i] > peak then peak = out[i] end
  end
  pcall(r.DestroyAudioAccessor, acc)
  if bad or peak <= 0 then return nil end
  for i = 1, n do out[i] = math.floor((out[i] / peak) * 1000 + 0.5) / 1000 end
  return out
end

function Rnd.peaks(path, lengthSec, n)
  n = n or K.RND_PEAKS_N
  if not r.APIExists or not r.APIExists('GetMediaItemTake_Peaks') then return nil end
  local len = tonumber(lengthSec) or 0
  if len <= 0 then return nil end

  local src = r.PCM_Source_CreateFromFile(path)
  if not src then return nil end

  -- Read off the source, not the take: the accessor needs both and the take is
  -- built further down, inside the pcall.
  state.rndWaveRate  = r.GetMediaSourceSampleRate and r.GetMediaSourceSampleRate(src) or 0
  state.rndWaveChans = r.GetMediaSourceNumChannels and r.GetMediaSourceNumChannels(src) or 0

  ensurePeaks(src, 10)

  local out
  r.PreventUIRefresh(1)
  r.Undo_BeginBlock()
  local idx = r.CountTracks(0)
  r.InsertTrackAtIndex(idx, false)
  local tr = r.GetTrack(0, idx)
  local it
  pcall(function()
    if not tr then return end
    it = r.AddMediaItemToTrack(tr)
    local tk = it and r.AddTakeToMediaItem(it)
    if not tk then return end
    r.SetMediaItemTake_Source(tk, src)
    r.SetMediaItemInfo_Value(it, 'D_LENGTH', len)

    -- The one that matches the portal. Everything below it is the fallback.
    out = Rnd.samplePeaks(tk, len, n)
    if out then return end

    -- One read at a given resolution. nil when the API hands back fewer values
    -- than were asked for: those cover less time than the file, so spreading
    -- them over the whole width would draw a waveform that is simply wrong.
    -- The return value carries the count in its low 20 bits.
    local function read(count)
      local buf = r.new_array(count * 3)
      if not pcall(function() buf.clear() end) then
        for i = 1, count * 3 do buf[i] = 0 end
      end
      local got = r.GetMediaItemTake_Peaks(tk, count / len, 0, 1, count, 0, buf)
      local spl = math.floor(math.abs(tonumber(got) or 0)) % 1048576
      if spl < count then return nil end
      -- The buffer is three blocks: maxima, minima, then extra. A waveform
      -- wants how far the signal went either way, so both halves count.
      local mags = {}
      for i = 1, count do
        local hi = math.abs(tonumber(buf[i]) or 0)
        local lo = math.abs(tonumber(buf[count + i]) or 0)
        mags[i] = (hi > lo) and hi or lo
      end
      return mags
    end

    local vals, peak
    for _, sub in ipairs(K.RND_PEAKS_SUBS) do
      local fine = read(n * sub)
      if fine then
        -- Averaged, not maxed: the maximum is what made the block in the first
        -- place, and taking it again over the sub-buckets would only rebuild it.
        vals = {}
        for i = 1, n do
          local acc = 0
          for k = 1, sub do acc = acc + fine[(i - 1) * sub + k] end
          vals[i] = acc / sub
        end
        break
      end
    end
    if not vals then
      -- Better a coarse waveform than none: this is the shape it had before,
      -- and it is still a great deal more than the artist gets from a version
      -- with no peaks at all.
      vals = read(n)
    end
    if not vals then return end
    peak = 0
    for i = 1, n do
      if vals[i] > peak then peak = vals[i] end
    end
    -- All zero means either silence or peaks that were never ready, and those
    -- are not the same thing. Rather than send a flat line the artist would read
    -- as "the file is empty", send nothing and let the portal fill it in.
    if peak <= 0 then return end
    for i = 1, n do vals[i] = math.floor((vals[i] / peak) * 1000 + 0.5) / 1000 end
    out = vals
  end)
  -- Outside the pcall, exactly like the settings restore: a throw in the middle
  -- must not leave a stray track sitting in his project.
  if tr then
    if it then pcall(r.DeleteTrackMediaItem, tr, it) end
    pcall(r.DeleteTrack, tr)
  end
  r.Undo_EndBlock('CuePort: Read waveform', -1)
  r.PreventUIRefresh(-1)
  -- Same reason: a track was added and taken away again, and the list Reaper
  -- draws is not the list it holds until it is told.
  refreshTrackList()
  pcall(r.PCM_Source_Destroy, src)
  return out
end

-- ── Uploading a render ─────────────────────────────────────────────────────
--
-- Four calls at the other end: start, one PUT per part, complete, and abort for
-- when it goes wrong. Driven one step per frame from the loop rather than in one
-- go: a 60 MB file is a minute of curl, and a minute in which Reaper does not
-- redraw is a minute in which the producer thinks it has hung.
--
-- Honest about what that does NOT fix: each individual part still blocks while
-- curl runs, so the window stutters between steps. It stays answerable and it
-- shows how far along it is, which one blocking call would not.
local Up = {}

K.UP_PART_SIZE = 8 * 1024 * 1024   -- what the server suggests; it may say otherwise
K.UP_MAX_TIME  = 600               -- seconds for one part
K.UP_CHUNK_TMP = 'upload.part'

-- Where an upload goes. Reading and commenting always stay on production; this
-- one route may differ, and only while production cannot serve it at all.
--
-- Not a setting: a switch has to be found, understood and turned back off, and
-- one left on quietly sends a real render to a build nobody signed off. The
-- worker states its capabilities instead, so this needs no maintenance at either
-- end -- the day production lists `upload`, this returns the production host and
-- the preview worker stops being contacted, with nothing to remove here.
--
-- The second return value says whether this IS the deviation, and the page that
-- uses it has to say so: the preview worker shares production's database and
-- bucket, so an upload sent there is a real version on the artist's production,
-- not a test.
function Up.base()
  if state.apiFeatures and state.apiFeatures['upload'] then
    return state.apiUrl, false
  end
  if K.API_URL_PREVIEW and K.API_URL_PREVIEW ~= state.apiUrl then
    return K.API_URL_PREVIEW, true
  end
  return state.apiUrl, false
end

-- The server's word for what went wrong, not ours. It is the side that knows
-- about plan limits, file types and ownership, and its message is what the
-- status line shows.
local function upFail(status, body)
  local parsed = json.decode(body or '')
  if parsed and parsed.error then return tostring(parsed.error) end
  return 'HTTP ' .. tostring(status)
end

function Up.start(productionId, trackType, filename, size)
  local status, body, err = httpPOST(Up.base() .. '/reaper/upload/start', authHeaders(), {
    production_id = productionId, track_type = trackType,
    filename = filename, size = size,
  })
  if not status then return nil, err end
  if status ~= 200 then return nil, upFail(status, body) end
  local parsed = json.decode(body or '')
  if not parsed or not parsed.upload_id then return nil, 'Bad response' end
  return parsed
end

function Up.part(uploadId, number, chunkPath)
  local h = authHeaders()
  h['X-Upload-Id']   = uploadId
  h['X-Part-Number'] = tostring(number)
  h['Content-Type']  = 'application/octet-stream'
  local status, body, err = httpRequest('PUT', Up.base() .. '/reaper/upload/part', h, nil,
                                        { bodyFile = chunkPath, maxTime = K.UP_MAX_TIME })
  if not status then return nil, err end
  if status ~= 200 then return nil, upFail(status, body) end
  local parsed = json.decode(body or '')
  if not parsed or not parsed.etag then return nil, 'Bad response' end
  return parsed.etag
end

function Up.complete(uploadId, fields)
  local payload = { upload_id = uploadId, parts = fields.parts }
  payload.name     = fields.name
  payload.label    = fields.label
  payload.duration = fields.duration
  payload.waveform = fields.waveform
  payload.notify   = fields.notify
  local status, body, err = httpRequest('POST', Up.base() .. '/reaper/upload/complete',
    (function() local h = authHeaders(); h['Content-Type'] = 'application/json'; return h end)(),
    json.encode(payload), { maxTime = 120 })
  if not status then return nil, err end
  if status ~= 200 then return nil, upFail(status, body) end
  local parsed = json.decode(body or '')
  if not parsed or not parsed.version then return nil, 'Bad response' end
  return parsed
end

-- Best effort by design: this runs when something has already gone wrong, and a
-- failure here must not replace the message that says what.
function Up.abort(uploadId)
  if not uploadId then return end
  pcall(httpPOST, Up.base() .. '/reaper/upload/abort', authHeaders(), { upload_id = uploadId })
end

-- The name the artist sees in CuePort. Not the name on disk: that one is
-- technical and unique on purpose, this one is read by a person and is also
-- what a download is called.
function Up.displayName(title, trackType, versionNumber, ext)
  local kind = (trackType == 'instrumental') and 'Instrumental' or 'Mix Master'
  local base = (title and title ~= '') and title or 'CuePort'
  -- Not `%c`: that class is `iscntrl`, and under a Windows codepage locale that
  -- covers 0x80-0x9F -- which are continuation bytes of perfectly ordinary UTF-8.
  -- "Виновата ли я" went up as "? инова? а ли ?" because of it: every Cyrillic
  -- letter whose second byte fell in that range had the byte replaced with a
  -- space, breaking the character in half. The range is written out so it means
  -- the same thing everywhere the script runs.
  base = base:gsub('[\1-\31\127/\\"]', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
  return ('%s (%s v%d).%s'):format(base, kind, versionNumber or 1, ext or 'flac')
end

-- ── the state machine ──────────────────────────────────────────────────────
--
-- One step per frame. `state.upload` is the whole of it, so a cancel is one
-- assignment and there is no second place holding half a transfer.
function Up.begin(job)
  local size = fileSize(job.path) or 0
  state.upload = {
    phase = 'start', path = job.path, size = size,
    productionId = job.productionId, trackType = job.trackType,
    title = job.title, label = job.label, notify = job.notify,
    duration = job.duration, waveform = job.waveform,
    ext = (job.path:match('%.([%w]+)%s*$') or 'flac'):lower(),
    parts = {}, sent = 0, partSize = K.UP_PART_SIZE,
    keepRender = job.keepRender,
  }
  return state.upload
end

function Up.cancel()
  local u = state.upload
  if not u then return end
  if u.uploadId then Up.abort(u.uploadId) end
  state.upload = nil
end

-- The line the window shows while a transfer is running, in one place: the
-- upload page prints it under its buttons and the veil prints it under its
-- spinner, and two of them would drift.
function Up.progressLine()
  local u = state.upload
  if not u then return nil end
  local total = (u.size or 0) > 0 and math.max(1, math.ceil(u.size / (u.partSize or 1))) or 1
  return ('Uploading %d%%  (part %d of %d)')
    :format(math.floor(Up.progress() * 100 + 0.5), #(u.parts or {}), total)
end

function Up.progress()
  local u = state.upload
  if not u or (u.size or 0) <= 0 then return 0 end
  return math.min(1, (u.sent or 0) / u.size)
end

-- Reads one part out of the file into a temp file curl can point at. Reading it
-- into a Lua string first and writing it back out is deliberate and not a
-- detour: curl has no way of sending a byte range of a file, and the whole file
-- in one request would be refused at the edge long before the 2 GB the server
-- allows.
function Up.writeChunk(u)
  local f = io.open(u.path, 'rb')
  if not f then return nil, 'cannot read the render' end
  f:seek('set', u.sent or 0)
  local data = f:read(u.partSize or K.UP_PART_SIZE)
  f:close()
  if not data or #data == 0 then return nil, 'the render ended sooner than its size said' end
  local chunkPath = tmpPath(K.UP_CHUNK_TMP)
  if not writeFile(chunkPath, data) then return nil, 'cannot write the part' end
  return chunkPath, #data
end

function Up.step()
  local u = state.upload
  if not u then return end

  if u.phase == 'start' then
    local res, err = Up.start(u.productionId, u.trackType,
                              Up.displayName(u.title, u.trackType, 1, u.ext), u.size)
    -- Which of the three steps stopped, not just why. "Stopped: no answer" is
    -- the same sentence whether the upload never opened or died on its last
    -- part, and those are not the same problem.
    if not res then u.phase, u.error = 'error', 'opening the upload: ' .. tostring(err); return end
    u.uploadId = res.upload_id
    u.versionNumber = res.version_number or 1
    if type(res.part_size) == 'number' and res.part_size > 0 then u.partSize = res.part_size end
    u.phase = 'part'
    return
  end

  if u.phase == 'part' then
    local chunkPath, n = Up.writeChunk(u)
    if not chunkPath then u.phase, u.error = 'error', n; Up.abort(u.uploadId); return end
    local number = #u.parts + 1
    local etag, err = Up.part(u.uploadId, number, chunkPath)
    deleteFile(chunkPath)
    if not etag then
      local total = (u.size or 0) > 0 and math.max(1, math.ceil(u.size / (u.partSize or 1))) or 1
      u.phase, u.error = 'error', ('part %d of %d: '):format(number, total) .. tostring(err)
      Up.abort(u.uploadId); return
    end
    u.parts[#u.parts+1] = { part_number = number, etag = etag }
    u.sent = (u.sent or 0) + n
    if u.sent >= u.size then u.phase = 'complete' end
    return
  end

  if u.phase == 'complete' then
    local res, err = Up.complete(u.uploadId, {
      parts = u.parts,
      name  = Up.displayName(u.title, u.trackType, u.versionNumber, u.ext),
      label = u.label,
      duration = u.duration,
      waveform = u.waveform,
      notify = u.notify,
    })
    if not res then
      u.phase, u.error = 'error', 'finishing the upload: ' .. tostring(err)
      Up.abort(u.uploadId); return
    end
    u.version  = res.version
    u.notified = res.notified
    u.phase    = 'done'
    -- The bounce is his, not ours: it sits in his project folder and the A/B
    -- cleanup does not touch our prefix. Only remove it if he said to.
    if u.keepRender == false then deleteFile(u.path) end
    return
  end
end

function Up.busy()
  local u = state.upload
  return u ~= nil and (u.phase == 'start' or u.phase == 'part' or u.phase == 'complete')
end

-- `trackType` is what the user pressed in the picker: the production plus which
-- of its uploads to open. Without one the server picks as it always has (newest
-- mixmaster), which is what clicking the row itself means.
local function bindProduction(prod, trackType)
  AB.remove()  -- a previous production's reference must not linger
  -- The upload choices belong to the production they were made for: which
  -- kind, which file, which warnings. Carrying them across would offer to send
  -- one production's bounce to another.
  state.up, state.upload = nil, nil
  setProjExt('production_id', prod.id)
  state.boundProductionId = prod.id
  state.boundProduction = prod
  state.showPickerOverride = false  -- leave the picker after a successful pick
  -- Drop the in-memory waveform so the block reloads for the new binding
  -- (UI.ensureWaveform picks the cache up again on the next frame).
  state.waveform = nil
  state.waveformForId = nil
  state.metrics = nil
  state.pendingSeekAt = nil
  state.versionFilename = nil
  state.versionId = nil
  -- A version id belongs to one production; carrying it into another would ask
  -- the server for a version that is not in it (and get the fallback anyway).
  state.versions, state.versionsForId = nil, nil
  state.versionsTriedFor = nil
  state.selectedVersionId, state.versionSwitchFrom = nil, nil
  setProjExt(K.VERSION_KEY, '')
  -- Asked for once, on the first sync of this binding: after that the version
  -- id is what identifies the version, and a type left standing would override
  -- it on every sync that followed.
  state.pendingTrackType = trackType
  state.replyTo, state.replyText, state.replyStatus = nil, '', nil
  state.delArm, state.delPending = nil, nil
  state.replyFocus = false
  -- Pull the comments right away, so the player shows the current version
  -- without the user having to press Sync first. Deferred to the loop rather
  -- than called here: doSync is defined further down, and syncing inside the
  -- click would freeze the frame it was clicked in.
  state.syncRequested = true
  state.syncStatus    = 'Loading comments...'
end

-- Moving the ruler origin means every comment marker has to be re-placed. That
-- needs the comments and the new offset — and both are already here: the
-- comments are cached in the project, and syncCommentsToMarkers reads the
-- offset itself. So this is local work, no request.
--
-- It used to call doSync() instead, which fetched the same comments over the
-- network first. That is where the wait after Set and Clear came from; it has
-- been in that path since v1.3.0 and had nothing to do with the button.
-- Returns false only when this project has never synced, so the caller can fall
-- back to a real sync.
--
-- "Never synced" is the *absence of the cache key*, not an empty list. A
-- production with no comments writes an empty list, and treating that as "no
-- cache" sent every Set and Clear back to the server for a list that was
-- already known to be empty — the wait that survived v1.10.2.
-- `quiet` for the times this is putting markers back rather than moving them:
-- at startup, and whenever the active project changes to one that is bound.
-- Saying "realigned" there would be a claim about something the user did not do.
local function realignMarkers(quiet)
  local raw = getProjExt(K.COMMENTS_CACHE_KEY)
  if not raw or raw == '' then return false end
  local summary = syncCommentsToMarkers(loadCommentsCache())
  state.lastSyncResult = summary
  if not quiet then
    state.syncStatus = string.format('Markers realigned — %d', summary.created or 0)
  end
  return true
end

-- Take our markers back off the ruler. The counterpart to the line above: the
-- markers exist while the script does, and the project is left as it was found.
-- Everything needed to put them back is in the project's own ProjExtState, so
-- nothing is lost -- see the placement in the binding check.
function Markers.remove()
  local existing = Markers.enumerate()
  if #existing == 0 then return 0 end
  r.Undo_BeginBlock()
  for i = #existing, 1, -1 do
    r.DeleteProjectMarker(0, existing[i].idx, false)
  end
  r.Undo_EndBlock('CuePort: remove comment markers', -1)
  r.UpdateTimeline()
  return #existing
end

-- The two switches, effect and all. They live here rather than in the settings
-- row that calls them because "what happens when this is turned off" is the
-- part worth pinning down, and a body inside a UI callback can only be checked
-- by rebuilding it in the harness -- which would then be checking the rebuild.
--
-- Both take effect on the spot: off takes the markers away now, on puts them
-- back from what is already in the project, so neither costs a request.
function Markers.setEnabled(on)
  setGlobalExt(K.MARKERS_ON_KEY, on and '1' or '0')
  if on then
    state.markersPlacedFor = state.boundProductionId
    realignMarkers(true)
  else
    Markers.remove()
  end
end

function Markers.setRenderMarker(on)
  setGlobalExt(K.RS_MARKER_ON_KEY, on and '1' or '0')
  local existing = findRenderStartMarker()
  if on then
    -- Back at the ruler origin. The internal position of "0:00 on the ruler" is
    -- minus the project offset -- the same number the A/B item is placed at.
    -- Only if the render start was actually set: otherwise this would invent a
    -- marker for something that never happened.
    if not existing and getProjExt(K.RENDER_START_KEY) == '1' then
      r.AddProjectMarker2(0, false, -getProjectStartOffset(), 0,
                          K.CP_START_MARKER_NAME, -1, cpStartMarkerColor())
    end
  elseif existing then
    r.DeleteProjectMarker(0, existing.idx, false)
  end
  r.UpdateTimeline()
  state.rsSet = nil   -- the answer comes from somewhere else now
end

-- Ask for a sync without doing it here. The caller's frame finishes painting
-- (so the change it just made is visible), the loop runs the blocking request
-- on the next one. The status is set right away, otherwise the queued frame
-- looks like nothing happened.
local function queueSync()
  if not state.boundProductionId or state.syncInProgress then return end
  state.syncRequested = true
  state.syncStatus    = 'Loading comments...'
end

local function doSync()
  if not state.boundProductionId or state.syncInProgress then return end
  state.syncInProgress = true
  state.syncStatus = 'Loading comments...'
  local resp, err = apiComments(state.boundProductionId, state.selectedVersionId,
                                state.pendingTrackType)
  state.syncInProgress = false
  if err == 'unauthorized' then
    state.errorMsg = 'Token is no longer valid — please reconnect.'
    logout()
    return
  end
  if err or not resp or not resp.ok then
    local why = err or (resp and resp.error) or 'Unknown'
    local back = state.versionSwitchFrom
    if back then
      -- Nothing came back, so nothing on screen can be the new version: the
      -- markers on the ruler, the waveform and the comment list are all still
      -- the old one's. Go back to naming it, rather than leaving the header
      -- claiming a version none of that belongs to.
      state.versionSwitchFrom = nil
      state.selectedVersionId = back.id
      state.versionId         = back.versionId
      state.versionFilename   = back.filename
      setProjExt(K.VERSION_KEY, back.id or '')
      -- The reference is gone either way -- the switch took it down before the
      -- request went out -- so there is nothing to put back here. It is loaded
      -- again by pressing the button, for whichever version we ended up on.
      state.syncStatus = 'Could not load that version (' .. why .. ') - back on ' ..
                         (back.label or 'the previous one')
      return
    end
    state.syncStatus = 'Error: ' .. why
    return
  end
  -- It landed: the markers, the waveform and the list below are all replaced
  -- from this response, so there is nothing to go back to any more.
  state.versionSwitchFrom = nil
  local comments = resp.comments or {}
  local summary = syncCommentsToMarkers(comments)
  state.lastSyncResult = summary
  state.lastSyncAt = os.time()

  -- Stash the waveform (peaks + duration) that came back with the comments so
  -- the waveform block can draw it. Persist it per-project too, so it survives
  -- a window reopen without a re-sync.
  local peaks = (type(resp.peaks) == 'table') and resp.peaks or {}
  local duration = (type(resp.duration) == 'number' and resp.duration > 0) and resp.duration or nil
  state.waveform = { peaks = peaks, duration = duration }
  state.waveformForId = state.boundProductionId
  state.metrics = (type(resp.metrics) == 'table') and resp.metrics or nil
  -- The sync is where a cover uploaded after the list was fetched arrives. The
  -- tag rides along on the comments response for exactly that reason; a changed
  -- one means a different file name, so the next pass downloads it.
  if resp.cover_tag and state.boundProduction then
    if state.boundProduction.cover_tag ~= resp.cover_tag then
      state.boundProduction.cover_tag = resp.cover_tag
      for _, p in ipairs(state.productions or {}) do
        if p.id == state.boundProductionId then p.cover_tag = resp.cover_tag; break end
      end
    end
    Art.st().pending = true
  end
  state.versionFilename = (resp.version and resp.version.filename) or state.versionFilename
  state.versionId = (resp.version and resp.version.id) or state.versionId
  -- The whole list, so the switcher can offer them without another request.
  if type(resp.versions) == 'table' then
    state.versions      = resp.versions
    state.versionsForId = state.boundProductionId
  end
  -- What the server actually opened, which is not always what was asked for:
  -- a version deleted in CuePort since this project was last touched sends us
  -- back to its fallback. Adopting the answer keeps the stored id honest
  -- instead of asking for a dead one on every sync.
  if resp.version and resp.version.id then
    state.selectedVersionId = resp.version.id
    setProjExt(K.VERSION_KEY, resp.version.id)
  end
  state.pendingTrackType = nil
  saveWaveformCache({
    productionId = state.boundProductionId, peaks = peaks, duration = duration,
    filename = state.versionFilename, versionId = state.versionId,
    metrics = state.metrics, versions = state.versions,
  })
  local v = resp.version
  local vLabel = v and (v.label or '?') or '?'
  local extra = ''
  if summary.legacyItemsRemoved and summary.legacyItemsRemoved > 0 then
    extra = string.format('  · %d legacy items migrated', summary.legacyItemsRemoved)
  end
  -- Which host answered, whenever it was not the production one. A fallback
  -- that cannot be seen is a fallback nobody can rule out when something looks
  -- wrong, so it is said every single time rather than once at the switch.
  if state.apiUrl ~= K.API_URL then extra = extra .. '  · preview worker' end
  state.syncStatus = string.format('Synced — %d markers (%d replaced)  (Version: %s)%s',
    summary.created or 0, summary.removed or 0, vLabel, extra)
end


-- ══════════════════════════════════════════════════════════════════════════════
-- UI (ReaImGui)
-- ══════════════════════════════════════════════════════════════════════════════

local ImGui = {}
for name, func in pairs(reaper) do
  if name:match('^ImGui_') then ImGui[name:sub(7)] = func end
end

K.FONT_SIZE  = 14
K.FONT_SMALL = 11.5   -- hints, section labels, diagnostics
K.FONT_LEAD  = 16     -- screen titles and the production headline
-- The wordmark is the one piece of branding in the window, so it carries its
-- own size and a shadow rather than sharing the heading size with everything
-- else. Bigger than a heading, but not so big that the badge and the menu
-- button beside it stop looking like they belong on the same row.
K.FONT_BRAND    = 20
K.BRAND_LOGO    = 27  -- the mark, square
-- The mark and the wordmark sit this much below the top of the header row. A
-- line in ImGui is aligned by its TOP edge, so without it the 27px logo and the
-- ~20px controls on the right share an upper edge and the brand reads as pinned
-- to the ceiling. Only the brand moves; the controls stay where they were.
K.BRAND_DROP    = 4
K.BRAND_SHADOW_DX = 1
K.BRAND_SHADOW_DY = 2
K.WINDOW_PAD_X = 14   -- breathing room at the left and right edges
K.SCROLL_GAP   = 6    -- air between the content and the scrollbar
-- The scrollbar lives *inside* the right-hand padding rather than next to it,
-- so the content keeps the same margin on both sides whether the bar is there
-- or not. Deriving the width keeps that true if the padding ever changes.
K.SCROLLBAR_W  = K.WINDOW_PAD_X - K.SCROLL_GAP
-- Enable docking so the main window can be attached to a Reaper docker. The
-- floating pill and modals opt out individually via WindowFlags_NoDocking.
local _dockCfg = (ImGui.ConfigFlags_DockingEnable and ImGui.ConfigFlags_DockingEnable()) or 0
local ctx = ImGui.CreateContext('CuePort Sync', _dockCfg)
-- The main window carries no title bar, so the only place left to grab it is
-- its empty space -- in practice the header strip. That is off when ImGui is
-- told to move windows by the title bar only, which would leave the window
-- stuck where it is. Set it explicitly rather than trusting a default we
-- cannot see from here.
if ImGui.SetConfigVar and ImGui.ConfigVar_WindowsMoveFromTitleBarOnly then
  pcall(ImGui.SetConfigVar, ctx, ImGui.ConfigVar_WindowsMoveFromTitleBarOnly(), 0)
end
-- Declared here, filled in once UI.scriptDir exists (see UI.loadFonts below).
-- 'sans-serif' resolves to whatever the OS happens to pick -- Arial on one
-- machine, Helvetica on the next -- so the window never looks like the same
-- product twice. We ship Inter instead, the face cueport.app uses.
local FONT, FONT_BOLD

-- ══════════════════════════════════════════════════════════════════════════════
-- LOGO LOADING
-- ══════════════════════════════════════════════════════════════════════════════
-- The PNG is shipped alongside the script via the ReaPack manifest
-- (<source file="cueport_icon.png">). We find it next to the running script
-- and hand the path to ImGui_CreateImage. Images must be cached — creating
-- one per frame leaks memory. The result is drawn in every window header.

-- Everything that draws. One table instead of ~25 locals (see K above).
local UI = {}

UI._logo = nil
UI._logoChecked = false

function UI.scriptDir()
  local src = debug.getinfo(1, 'S').source or ''
  if src:sub(1,1) == '@' then src = src:sub(2) end
  return src:match('^(.-)[^/\\]+$') or ''
end

function UI.logoImage()
  if UI._logoChecked then return UI._logo end
  UI._logoChecked = true
  if not r.APIExists('ImGui_CreateImage') then return nil end
  local path = UI.scriptDir() .. 'cueport_icon.png'
  local f = io.open(path, 'rb')
  if not f then return nil end
  f:close()
  local ok, img = pcall(r.ImGui_CreateImage, path, 0)
  if ok and img then
    -- Attach image to context so it persists across frames
    if r.ImGui_Attach then pcall(r.ImGui_Attach, ctx, img) end
    UI._logo = img
  end
  return UI._logo
end

-- ══════════════════════════════════════════════════════════════════════════════
-- FONTS
-- ══════════════════════════════════════════════════════════════════════════════
-- Three steps, best first: the Inter file shipped next to the script, then an
-- Inter installed on the machine, then the generic family. A missing file
-- therefore costs polish and never breaks the script -- which matters because
-- ReaPack users on an older package have the script but not the fonts yet.
--
-- CreateFontFromFile needs ReaImGui 0.10. So does PushFont with a size, which
-- this script already relies on everywhere, so that floor is not new.

function UI.fontFrom(file, family)
  if file and r.APIExists('ImGui_CreateFontFromFile') then
    local path = UI.scriptDir() .. file
    local h = io.open(path, 'rb')
    if h then
      h:close()
      local ok, f = pcall(r.ImGui_CreateFontFromFile, path, 0, 0)
      if ok and f then return f end
    end
  end
  -- Older ReaImGui took a size here; newer takes flags. Try the modern shape
  -- first so we never pass a size where a flag is expected.
  local ok, f = pcall(r.ImGui_CreateFont, family)
  if ok and f then return f end
  ok, f = pcall(r.ImGui_CreateFont, family, K.FONT_SIZE)
  if ok and f then return f end
  return nil
end

function UI.loadFonts()
  FONT      = UI.fontFrom('Inter-Regular.ttf',  'Inter')
                or UI.fontFrom(nil, 'sans-serif')
  FONT_BOLD = UI.fontFrom('Inter-SemiBold.ttf', 'Inter') or FONT
  if FONT then ImGui.Attach(ctx, FONT) end
  if FONT_BOLD and FONT_BOLD ~= FONT then ImGui.Attach(ctx, FONT_BOLD) end
end

UI.loadFonts()

-- ══════════════════════════════════════════════════════════════════════════════
-- CUEPORT THEME — shared styling for every script window (main + floating +
-- tooltip). Dark neutral surface, purple accents, subtle borders, rounded
-- corners, compact padding. Matches the cueport.app web UI.
-- ══════════════════════════════════════════════════════════════════════════════

local CP_COLORS = {
  accent       = 0xB088E0FF,  -- highlight purple (brand)
  accentStrong = 0x7B45C8FF,
  -- The same purple at a third of its opacity, for a switch that is on but
  -- cannot be pressed. Nothing else in the theme covers "on and disabled".
  accentMuted  = 0x7B45C855,
  bg           = 0x18181CFF,  -- fully opaque dark surface
  border       = 0x3A3A3DFF,
  text         = 0xE8E8EAFF,
  textDim      = 0x8B8B92FF,
  hover        = 0x35353CFF,
  active       = 0x42424AFF,
  success      = 0x4ADE80FF,
  warn         = 0xFFA500FF,
  danger       = 0xFF4F6DFF,

  -- Card layout: content sits in slightly raised panels rather than floating
  -- between separators, which is what made the older screens read as a list of
  -- loose controls.
  -- Card surfaces lift off the background by ~12 per channel rather than 6.
  -- Everything that sits *on* a card has to move with it or it stops reading:
  -- the border, the row separators, the input fields and the hover state below
  -- are all measured against this, not against the window background.
  card         = 0x24242BFF,
  cardBorder   = 0x32323AFF,
  rowSep       = 0x2E2E36FF,
  sectionText  = 0x7A7A86FF,
  hairline     = 0x2A2A30FF,
  hairlineFade = 0x2A2A3000,  -- same colour, zero alpha, for the fading rule
  trackOff     = 0x33333BFF,  -- switch track, off
  knob         = 0xD8D8DDFF,
  waveIdle     = 0x5A4A72FF,  -- waveform past the play cursor
  waveGlow     = 0x18181C00,
  -- The waveform sits *in* the production card, so it is a recess rather than
  -- a second card: darker than the surface around it, with the top inner edge
  -- a shade darker again, which is where a real inset catches its own shadow.
  waveWell     = 0x1A1A20FF,
  waveWellTop  = 0x131317FF,
  waveWellEdge = 0x2C2C34FF,
  -- Under the wordmark. Black rather than a darker purple: a tinted shadow
  -- reads as a second, blurry copy of the letters, a black one reads as depth.
  brandShadow  = 0x000000B0,
  brandGlow    = 0xB088E022,
  -- The row the mouse is over in the waveform, lit in the comment list. Low
  -- alpha on purpose: it has to be findable out of the corner of the eye
  -- without turning the row into a block of colour you then read through.
  -- Who said it decides the colour, the same way cueport.app's own player does
  -- it: amber for the artist, purple for the studio. Until now every pin and
  -- every timestamp was purple, so the strip said nothing about who had spoken.
  -- The value is the landing page's --amber (#fbbf24) verbatim.
  artist       = 0xFBBF24FF,
  artistStrong = 0xD9A21BFF,  -- resting dot, a shade down like accentStrong
  artistStem   = 0xFBBF2499,  -- resting stem, same alpha as the purple one
  studioStem   = 0x7B45C899,
  commentLit   = 0xB088E01E,

  -- Depth. A flat fill reads as a dialog box; a surface needs a light
  -- direction. The wash lifts the top of the window by ~3%, the glow puts a
  -- single brand-coloured light source behind the header, and the shadow sits
  -- under every card. All three are deliberately near the threshold of
  -- visibility -- if you can point at them individually they are too strong.
  washTop      = 0xFFFFFF0A,
  washNone     = 0xFFFFFF00,
  -- The comment column carries its gradient *on* its surface, not under it,
  -- because a card is opaque and hides the window's wash entirely. Giving it
  -- the window's wash therefore did not make it match -- it made it the one
  -- card on screen lighter than the rest, by exactly that amount.
  -- So it starts from a base *below* `card` and the gradient lifts the top
  -- back over it: mean lightness the same as every other card, but with a
  -- visible fall from top to bottom instead of a flat fill.
  -- Numbers, so the next change to them is a decision rather than a nudge:
  -- base 0x17, the gradient lifts the top to ~0x25 and it falls back to 0x17
  -- at the bottom, mean ~0x1E. `card` is 0x24, so only the very top edge
  -- reaches the surface the other cards sit on and everything below it is
  -- darker -- the column reads as recessed, like the waveform well (0x1A),
  -- rather than as a panel laid on top.
  listBase     = 0x17171CFF,
  listWash     = 0xFFFFFF10,
  glow         = 0xB088E024,
  -- Shadows overlap: cards sit a few pixels apart and a card inside a card
  -- puts one ring straight onto the other. Whatever value looks right for a
  -- single card is therefore too strong for a screen full of them.
  shadow       = 0x0000002A,
  -- The cover's own ring. Lighter than a card's: a card sits on the window and
  -- carries the whole block, the cover is one element inside a card and only
  -- needs to lift off it. At full strength it read as a hard edge under the
  -- picture rather than as depth.
  shadowArt    = 0x00000018,
}

-- ══════════════════════════════════════════════════════════════════════════════
-- DEPTH — soft texture, shadows, backdrop
-- ══════════════════════════════════════════════════════════════════════════════
-- ImGui has no shadow primitive and no blur, and its one gradient call
-- (AddRectFilledMultiColor) cannot round its corners. Both gaps close with the
-- same trick: build one small texture at load time whose alpha falls off
-- smoothly from an opaque centre, then nine-slice it for shadows and stretch
-- it for the backdrop glow. Nine-slicing needs that opaque centre -- the
-- middle tile is what the stretched edges are cut from.
--
-- Needs ReaImGui 0.10 (CreateImageFromSize / Image_SetPixels_Array). Without
-- it every function here returns quietly and the UI looks like it did before.

K.SOFT_TEX  = 64   -- texture edge in pixels
K.SOFT_CORE = 8    -- opaque centre square, also the nine-slice middle
-- One number for every card shadow. It has to fit inside the window padding:
-- a card fills its container edge to edge, so the ring can only spread into
-- the margin the window keeps on either side. 12 leaves 2px of air at 14.
K.SHADOW_SPREAD = 12
-- Offset, so the light has a direction instead of sitting straight above.
-- Down more than right: that is where a light in the top-left corner puts it,
-- and it matches the glow the backdrop already draws there.
-- SPREAD + DX must stay within the padding, or the ring runs off the window.
K.SHADOW_DX = 2
K.SHADOW_DY = 4

-- ══════════════════════════════════════════════════════════════════════════════
-- COVER ART
-- ══════════════════════════════════════════════════════════════════════════════
-- Defined down here, after CP_COLORS: a table declared further down the file is a
-- different (global, empty) name inside a function written above it. The Art table
-- itself is declared way up next to AB, so logout can reach it.
--
-- What the server hands us is `cover_tag`, eight hex characters over the cover's
-- filename and byte size. It canNOT be the R2 key: that one is built from artist
-- and production id and stays identical when a cover is replaced. The tag is part
-- of the cached filename, so a new cover is simply a file we do not have yet.
--
-- Everything lands in <resource path>/CuePort/artwork. Downloads are one curl call
-- for all missing covers at once (one config file with several url/output pairs),
-- and that call runs detached: it used to block, which was felt as a pause on the
-- first login of a studio with a lot of productions.

function Art.st()
  state.art = state.art or { img = {}, gone = {} }
  return state.art
end

function Art.dir()
  return r.GetResourcePath() .. pathSep() .. 'CuePort' .. pathSep() .. K.ART_DIR_NAME
end

-- Only ever build names we can also recognise again when cleaning up.
function Art.fileName(prodId, tag)
  local key = tostring(prodId or ''):gsub('[^%w%-_]', '')
  local t   = tostring(tag or ''):gsub('[^%w]', '')
  if key == '' or t == '' then return nil end
  return 'cueport_art_' .. key .. '_' .. t .. '.jpg'
end

function Art.path(prodId, tag)
  local fn = Art.fileName(prodId, tag)
  if not fn then return nil end
  return Art.dir() .. pathSep() .. fn
end

function Art.have(prodId, tag)
  local p = Art.path(prodId, tag)
  if not p then return false end
  local sz = fileSize(p)
  return sz ~= nil and sz > 0
end

-- items: { {id=..., tag=...}, ... }. Returns how many files were written.
-- Skips what is already on disk and what the server has already said no to, so a
-- second run costs nothing at all.
function Art.fetchMissing(items)
  if not state.token or type(items) ~= 'table' then return 0 end
  local st, want = Art.st(), {}
  -- One download at a time. Without this the second request would fall through
  -- to the blocking path below and freeze the window -- which is the very thing
  -- the detached job exists to avoid. Nothing is lost: `rearm` makes the poll
  -- ask again once the running one is done.
  if st.job then st.rearm = true; return 0 end
  for _, it in ipairs(items) do
    local id, tag = it.id, it.tag
    if id and tag and tag ~= '' and not st.gone[tostring(id) .. ':' .. tostring(tag)]
       and not Art.have(id, tag) and Art.path(id, tag) then
      want[#want+1] = { id = id, tag = tag }
    end
  end
  if #want == 0 then return 0 end

  local dir = Art.dir()
  r.RecursiveCreateDirectory(dir, 0)
  local cfg = {
    '--silent', '--show-error', '--location',
    '--connect-timeout 15', '--max-time 120',
  }
  for k, v in pairs(authHeaders()) do
    cfg[#cfg+1] = 'header = "' .. cfgQ(k .. ': ' .. v) .. '"'
  end
  -- One url/output pair per cover. curl keeps the connection open across them,
  -- which is the whole point of doing it in a single call.
  for _, it in ipairs(want) do
    cfg[#cfg+1] = 'url = "' .. cfgQ(state.apiUrl .. '/reaper/artwork?production_id=' ..
                  tostring(it.id)) .. '"'
    cfg[#cfg+1] = 'output = "' .. cfgQ(Art.path(it.id, it.tag) .. '.part') .. '"'
    cfg[#cfg+1] = 'write-out = "\\n__CP_ART__:%{http_code}"'
  end
  local cfgPath = tmpPath('artdl.cfg')
  if not writeFile(cfgPath, table.concat(cfg, '\n')) then return 0 end

  -- Preferred path: hand the whole thing to a detached process and carry on
  -- painting. Only when that cannot be set up does the old blocking call run.
  if Art.startJob(want, cfgPath) then return 0 end

  local raw = r.ExecProcess(curlCfgCmd(cfgPath), 130000)
  local _, out = parseExecOutput(raw)
  deleteFile(cfgPath)
  return Art.finish(want, out)
end

-- Move the finished downloads into place. Shared by both paths, so the async
-- one cannot drift away from the blocking one.
-- `out` is curl's own output: one `__CP_ART__:<code>` per url, in the order the
-- urls were listed.
function Art.finish(want, out)
  local st, codes, written = Art.st(), {}, 0
  for c in tostring(out or ''):gmatch('__CP_ART__:(%d+)') do codes[#codes+1] = tonumber(c) end
  for i, it in ipairs(want) do
    local dest, part = Art.path(it.id, it.tag), Art.path(it.id, it.tag) .. '.part'
    local sz = fileSize(part)
    if codes[i] == 200 and sz and sz > 0 then
      deleteFile(dest)
      if os.rename(part, dest) then written = written + 1 else deleteFile(part) end
    else
      deleteFile(part)
      -- 404 means this production has no cover the server will give us. Remember
      -- that, otherwise every sync asks again for something that is not there.
      if codes[i] == 404 then st.gone[tostring(it.id) .. ':' .. tostring(it.tag)] = true end
    end
  end
  return written
end

-- Start the download as a detached process. Returns true when it is running.
--
-- Why a launcher file and not one long command line: ExecProcess with a negative
-- timeout hands the line to the shell and returns at once, but then there is no
-- exit code and no output to read. So the launcher redirects curl's output to a
-- file and writes a sentinel afterwards -- that sentinel is how `Art.poll` knows
-- the download is over. Putting those two lines in a file instead of quoting a
-- compound command keeps paths with spaces out of the danger zone.
--
-- Windows keeps the blocking path on purpose: the `cmd.exe /c` quoting rules
-- around a batch file in a path with spaces are not something I can test from
-- here, and a launcher that silently never runs would mean covers that never
-- appear at all. The freeze there is what it always was.
function Art.startJob(want, cfgPath)
  if isWindows() then return false end
  local st = Art.st()
  if st.job then return false end
  local outPath, donePath = tmpPath('artdl.out'), tmpPath('artdl.done')
  deleteFile(outPath); deleteFile(donePath)
  local shPath = tmpPath('artdl.sh')
  -- Nur Unix (Windows ist oben schon heraus), also durchgehend einfache
  -- Anfuehrungszeichen: der Ressourcenpfad kann $, ` oder einen Rueckstrich
  -- enthalten, und in doppelten waeren die aktiv.
  local body = '#!/bin/sh\n' ..
               shQuote(curlBinary()) .. ' --config ' .. shQuote(cfgPath) ..
               ' > ' .. shQuote(outPath) .. ' 2>&1\n' ..
               'echo done > ' .. shQuote(donePath) .. '\n'
  if not writeFile(shPath, body) then return false end
  -- -1: start it and do not wait. The process is REAPER's child and goes away
  -- with it, which is what we want for a download nobody is waiting on.
  if not r.ExecProcess('/bin/sh ' .. shQuote(shPath), -1) then
    deleteFile(shPath); return false
  end
  local now = r.time_precise()
  st.job = { want = want, out = outPath, done = donePath, cfg = cfgPath,
             sh = shPath, started = now, nextCheck = now + 0.25 }
  return true
end

-- Called every frame. Cheap: it only touches the disk four times a second, and
-- only while a download is actually running.
function Art.poll()
  local st = state.art
  local job = st and st.job
  if not job then return 0 end
  -- Wall clock, not os.clock: that one counts processor time, and a script that
  -- spends its life waiting in a defer loop barely accumulates any -- a quarter
  -- of a second of it can be many seconds on the wall.
  local now = r.time_precise()
  if now < (job.nextCheck or 0) then return 0 end
  job.nextCheck = now + 0.25

  local finished = fileSize(job.done) ~= nil
  -- A curl that never returns must not leave the job wedged forever, or no
  -- further cover would ever be fetched in this session.
  if not finished and now - (job.started or now) < 180 then return 0 end

  local out = ''
  if finished then
    local f = io.open(job.out, 'rb')
    if f then out = f:read('*a') or ''; f:close() end
  end
  local written = Art.finish(job.want, out)
  deleteFile(job.cfg); deleteFile(job.sh); deleteFile(job.out); deleteFile(job.done)
  st.job = nil
  -- Somebody asked while this one was running. Ask again now that the slot is
  -- free, otherwise those covers wait for the next sync.
  if st.rearm then st.rearm = nil; st.pending = true end
  return written
end

-- Pull the tags out of whatever the server last handed us and fetch what is new.
function Art.syncFromList()
  if type(state.productions) ~= 'table' then return 0 end
  local items = {}
  for _, p in ipairs(state.productions) do
    if p.cover_tag then items[#items+1] = { id = p.id, tag = p.cover_tag } end
  end
  return Art.fetchMissing(items)
end

-- Images must be cached: creating one per frame leaks memory. `false` marks an
-- attempt that failed, so a broken file is not retried on every frame -- but a
-- file that is merely not downloaded yet is NOT marked, or it would never appear.
function Art.image(prodId, tag)
  if not tag or tag == '' then return nil end
  local st = Art.st()
  local ck = tostring(prodId) .. ':' .. tostring(tag)
  local cached = st.img[ck]
  if cached ~= nil then return cached or nil end
  if not r.APIExists('ImGui_CreateImage') then st.img[ck] = false; return nil end
  if not Art.have(prodId, tag) then return nil end
  local ok, img = pcall(r.ImGui_CreateImage, Art.path(prodId, tag), 0)
  if ok and img then
    if r.ImGui_Attach then pcall(r.ImGui_Attach, ctx, img) end
    st.img[ck] = img
    return img
  end
  st.img[ck] = false
  return nil
end

-- The music glyph from cueport.app, drawn rather than loaded: ReaImGui decodes
-- PNG and JPEG only, there is no SVG path. This is the same figure as the site's
-- uiSvg('music') -- <path d="M9 18V5l12-2v13"/> plus circles at (6,18) and
-- (18,16), r=3, in a 24x24 box -- so it scales to any tile and takes the theme
-- colour instead of shipping as a second image file.
function Art.note(dl, x, y, size, col)
  local s  = size / 24
  local th = math.max(1, size / 16)
  local function px(v) return x + v * s end
  local function py(v) return y + v * s end
  ImGui.DrawList_AddLine(dl, px(9), py(18), px(9),  py(5),  col, th)
  ImGui.DrawList_AddLine(dl, px(9), py(5),  px(21), py(3),  col, th)
  ImGui.DrawList_AddLine(dl, px(21), py(3), px(21), py(16), col, th)
  if ImGui.DrawList_AddCircle then
    ImGui.DrawList_AddCircle(dl, px(6),  py(18), 3 * s, col, 0, th)
    ImGui.DrawList_AddCircle(dl, px(18), py(16), 3 * s, col, 0, th)
  end
end

-- Draws the cover, or the placeholder when there is none (or it has not arrived
-- yet). Paints straight into a draw list and never moves the cursor, so callers
-- stay in charge of the layout.
function Art.tile(dl, prodId, tag, x, y, size, shadow)
  local rnd = math.max(3, size * 0.14)
  -- Behind everything else, so the opaque middle of the soft texture is covered
  -- by the tile itself and only the ring around it survives. (In a popup that
  -- order is impossible and the middle shows as a veil -- see UI.shadow.)
  if shadow then UI.shadow(x, y, x + size, y + size, K.ART_SHADOW, CP_COLORS.shadowArt) end
  local img = Art.image(prodId, tag)
  if img and ImGui.DrawList_AddImage then
    -- Rounded, not square with a rounded outline drawn on top: the artwork is a
    -- square picture, so the corners outside the outline used to stick out past
    -- the frame. AddImageRounded is the only call that can cut them off -- there
    -- is no rounded clip. A build without it keeps the old square image, which
    -- is what shipped until now, rather than no cover at all.
    if ImGui.DrawList_AddImageRounded then
      local ok = pcall(ImGui.DrawList_AddImageRounded, dl, img, x, y, x + size, y + size,
                       0, 0, 1, 1, 0xFFFFFFFF, rnd)
      if not ok then ImGui.DrawList_AddImage(dl, img, x, y, x + size, y + size) end
    else
      ImGui.DrawList_AddImage(dl, img, x, y, x + size, y + size)
    end
  else
    ImGui.DrawList_AddRectFilled(dl, x, y, x + size, y + size, CP_COLORS.waveWell, rnd)
    local g = size * 0.52
    Art.note(dl, x + (size - g) / 2, y + (size - g) / 2, g, CP_COLORS.textDim)
  end
  ImGui.DrawList_AddRect(dl, x, y, x + size, y + size, CP_COLORS.waveWellEdge, rnd)
end

-- Logout: the files and the textures both go. Only files this script wrote are
-- touched -- same rule as AB.deleteAudioFile, the path is ours but the folder is
-- on the user's disk.
function Art.clear()
  local st = Art.st()
  -- A download still in flight has to be dropped first, or it would move its
  -- .part files into the folder we are about to empty and leave covers of the
  -- studio we just logged out of lying around.
  if st.job then
    for _, it in ipairs(st.job.want or {}) do
      local p = Art.path(it.id, it.tag)
      if p then deleteFile(p .. '.part') end
    end
    deleteFile(st.job.cfg); deleteFile(st.job.sh)
    deleteFile(st.job.out); deleteFile(st.job.done)
    st.job = nil
  end
  st.img, st.gone = {}, {}
  -- Collect first, delete after: deleting while enumerating shifts the indices
  -- under the loop, which silently skips every second file.
  local dir, doomed, i = Art.dir(), {}, 0
  while true do
    local fn = r.EnumerateFiles(dir, i)
    if not fn then break end
    if fn:match('^cueport_art_') then doomed[#doomed+1] = dir .. pathSep() .. fn end
    i = i + 1
  end
  for _, p in ipairs(doomed) do deleteFile(p) end
  return #doomed
end

function UI.softTex()
  if UI._softChecked then return UI._soft end
  UI._softChecked = true
  if not (r.APIExists('ImGui_CreateImageFromSize')
      and r.APIExists('ImGui_Image_SetPixels_Array') and r.new_array) then return nil end
  local N, C = K.SOFT_TEX, K.SOFT_CORE
  local ok, img = pcall(r.ImGui_CreateImageFromSize, N, N)
  if not ok or not img then return nil end
  local half, R, mid = C / 2, (N - C) / 2, N / 2
  local buf = r.new_array(N * N)
  local i = 1
  for py = 0, N - 1 do
    for px = 0, N - 1 do
      -- Distance to the centre *square*, not the centre point: that is what
      -- makes the edges of the nine-slice fall off straight and the corners
      -- fall off round.
      local dx = math.abs(px + 0.5 - mid) - half; if dx < 0 then dx = 0 end
      local dy = math.abs(py + 0.5 - mid) - half; if dy < 0 then dy = 0 end
      local t  = 1 - math.sqrt(dx * dx + dy * dy) / R
      if t < 0 then t = 0 elseif t > 1 then t = 1 end
      -- A plain power curve, softer than the smoothstep this used to be: it
      -- leaves the edge later and rises more evenly, so the ring has no point
      -- you can put a finger on. The radius cannot grow much (spread plus
      -- offset has to stay inside the window margin), so the softness has to
      -- come from the shape of the ramp rather than from more pixels.
      local a = t ^ 1.6
      -- Pixel format is 0xRRGGBBAA. White, so the tint colour passed to
      -- AddImage decides what the shape actually looks like.
      buf[i] = 0xFFFFFF00 + math.floor(a * 255 + 0.5)
      i = i + 1
    end
  end
  if not pcall(r.ImGui_Image_SetPixels_Array, img, 0, 0, N, N, buf) then return nil end
  if r.ImGui_Attach then pcall(r.ImGui_Attach, ctx, img) end
  UI._soft = img
  return img
end

-- Stretch the whole texture over a rectangle: one soft, round-ish light.
function UI.glow(x, y, w, h, col)
  local img = UI.softTex()
  if not (img and ImGui.DrawList_AddImage) then return end
  ImGui.DrawList_AddImage(ImGui.GetWindowDrawList(ctx), img,
    x, y, x + w, y + h, 0, 0, 1, 1, col)
end

-- Nine-slice the texture around a rectangle. Corners keep their aspect, edges
-- stretch along one axis only, so the blur width is the same the whole way
-- round no matter how big the card is.
-- `outside` paints only what falls beyond the rectangle, and nothing above its
-- top edge. It exists for the menu panel, and the reason is where the ring gets
-- issued: a card's goes into the *parent's* list before the child composites,
-- so the tiles that land on the card are covered by the card itself. A popup
-- has a list of its own and the ring can only be added after its background and
-- its rows -- the same call there lays the texture's opaque centre over the
-- whole menu as a grey veil and drags a soft band across the top edge, which is
-- exactly where the join with the button has to stay unbroken.
--
-- So: three bands, clipped, and deliberately *disjoint* -- two overlapping
-- passes would paint the corners twice and leave a dark blob there. No drop
-- offset either, because an offset ring leaves a lit gap on one side that no
-- rectangular clip can fill.
function UI.shadow(x0, y0, x1, y1, spread, col, outside)
  local img = UI.softTex()
  if not (img and ImGui.DrawList_AddImage) then return end
  if not (x0 and y0 and x1 and y1) or x1 <= x0 or y1 <= y0 then return end
  local s  = spread or K.SHADOW_SPREAD
  local c  = col or CP_COLORS.shadow
  -- Drop, not halo: the whole ring moves down and to the right, so the top-left
  -- edge keeps only a hairline and the weight collects under the card.
  if not outside then
    x0, x1 = x0 + K.SHADOW_DX, x1 + K.SHADOW_DX
    y0, y1 = y0 + K.SHADOW_DY, y1 + K.SHADOW_DY
  end
  local N, C = K.SOFT_TEX, K.SOFT_CORE
  local u0, u1 = ((N - C) / 2) / N, ((N + C) / 2) / N
  local dl = ImGui.GetWindowDrawList(ctx)
  local ax, ay, bx, by = x0 - s, y0 - s, x1 + s, y1 + s
  local clipped = ImGui.DrawList_PushClipRect and ImGui.DrawList_PopClipRect
  local function tile(qx0, qy0, qx1, qy1, tu0, tv0, tu1, tv1)
    ImGui.DrawList_AddImage(dl, img, qx0, qy0, qx1, qy1, tu0, tv0, tu1, tv1, c)
  end
  local function ring()
    tile(ax, ay, x0, y0,  0,  0, u0, u0)   -- corners
    tile(x1, ay, bx, y0, u1,  0,  1, u0)
    tile(ax, y1, x0, by,  0, u1, u0,  1)
    tile(x1, y1, bx, by, u1, u1,  1,  1)
    tile(x0, ay, x1, y0, u0,  0, u1, u0)   -- edges
    tile(x0, y1, x1, by, u0, u1, u1,  1)
    tile(ax, y0, x0, y1,  0, u0, u0, u1)
    tile(x1, y0, bx, y1, u1, u0,  1, u1)
    -- The middle exists so a rounded card cannot show a gap at its corners. In
    -- `outside` mode every band lies beyond the rectangle, so it would draw
    -- nothing -- but a build without clipping falls through to the plain path
    -- below, and there it would be the veil. Hence the guard, not just the
    -- clip.
    if not outside then tile(x0, y0, x1, y1, u0, u0, u1, u1) end
  end
  if outside then
    -- Without a replacing clip there is no way to keep the ring off the panel,
    -- and half a shadow is better than a veil over the whole menu.
    if not clipped then return end
    for _, b in ipairs({ { ax, y0, x0, by },     -- left of the panel
                         { x1, y0, bx, by },     -- right of it
                         { x0, y1, x1, by } }) do   -- under it
      ImGui.DrawList_PushClipRect(dl, b[1], b[2], b[3], b[4], false)
      ring()
      ImGui.DrawList_PopClipRect(dl)
    end
    return
  end
  -- The ring lives outside the card, and a card fills its container exactly:
  -- the body region ends where the content ends, so ImGui's clip rectangle
  -- cuts the whole ring away at the sides and trims it top and bottom. Widen
  -- the clip for the duration of the ring -- 'false' replaces the current
  -- rectangle instead of narrowing it, which is the only way to paint outside
  -- the region you are in. Everything is put back straight after: a clip left
  -- on the stack corrupts every later draw.
  if clipped then ImGui.DrawList_PushClipRect(dl, ax, ay, bx, by, false) end
  ring()
  if clipped then ImGui.DrawList_PopClipRect(dl) end
end

-- Painted right after Begin, so it sits on the window background and under
-- every piece of content.
-- The wash on its own, over whatever window is current -- the main one or a
-- child. One implementation, so the two cannot drift apart; the strength and
-- how far down it reaches are arguments, because a card is opaque and hides
-- the window's own wash, so a card that wants a gradient has to carry its own
-- and needs a different one (see CP_COLORS.listWash).
function UI.wash(colTop, frac)
  if not ImGui.DrawList_AddRectFilledMultiColor then return end
  local x, y = ImGui.GetWindowPos(ctx)
  local w, h = ImGui.GetWindowSize(ctx)
  if not (x and y and w and h) or w < 2 or h < 2 then return end
  local dl  = ImGui.GetWindowDrawList(ctx)
  local col = colTop or CP_COLORS.washTop
  -- The gradient call cannot round, and the window can, so the top strip is a
  -- rounded fill in the start colour and the wash begins below it. Over 8px
  -- the gradient has barely moved, so the join is not visible -- but painting
  -- a square gradient into a rounded window would put a block in each corner.
  -- The bottom needs no such strip: it ends fully transparent.
  local rnd = 8
  local top = (ImGui.DrawFlags_RoundCornersTop and ImGui.DrawFlags_RoundCornersTop()) or 0
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + rnd, col, rnd, top)
  ImGui.DrawList_AddRectFilledMultiColor(dl, x, y + rnd, x + w, y + h * (frac or 0.55),
    col, col, CP_COLORS.washNone, CP_COLORS.washNone)
  return x, y
end

function UI.backdrop()
  local x, y = UI.wash()
  if not x then return end
  -- One light source, behind the wordmark, bleeding off the top-left corner.
  UI.glow(x - 70, y - 90, 340, 250, CP_COLORS.glow)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- UI PRIMITIVES
-- ══════════════════════════════════════════════════════════════════════════════
-- The screens are built from four pieces: a section label with a rule that
-- fades out, a card that grows with its contents, rows that put the control on
-- the right of its label, and a switch. ImGui ships none of these, so they are
-- assembled from the draw list here rather than repeated at every call site.

local CARD_PAD_X, CARD_PAD_Y = 12, 9

-- Cards need a child window that sizes itself to its contents. Without that
-- flag a zero height means "fill the rest of the window", which would turn the
-- first card into a full-page box — so we fall back to plain content instead.
local HAS_CARDS = ImGui.ChildFlags_AutoResizeY ~= nil

function UI.section(label)
  ImGui.Dummy(ctx, 0, 6)
  -- Caps at 11.5px go thin and grey out; the heavier weight is what keeps a
  -- section label readable as a label rather than as faint noise.
  ImGui.PushFont(ctx, FONT_BOLD, K.FONT_SMALL)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.sectionText)
  ImGui.Text(ctx, label:upper())
  ImGui.PopStyleColor(ctx)
  ImGui.PopFont(ctx)
  -- Rule from the end of the label to the right edge, fading into the
  -- background so it guides the eye without boxing the section in.
  if ImGui.DrawList_AddRectFilledMultiColor then
    local lx, ly = ImGui.GetItemRectMax(ctx)
    local _, ty  = ImGui.GetItemRectMin(ctx)
    local midY   = math.floor((ty + ly) / 2)
    -- Content region, not window width: inside the scrolling body the two
    -- differ by the scrollbar gutter, and using the window width drew the rule
    -- underneath the scrollbar.
    local cx     = ImGui.GetCursorScreenPos(ctx)
    local right  = cx + ImGui.GetContentRegionAvail(ctx)
    if right > lx + 20 then
      ImGui.DrawList_AddRectFilledMultiColor(ImGui.GetWindowDrawList(ctx),
        lx + 9, midY, right, midY + 1,
        CP_COLORS.hairline, CP_COLORS.hairlineFade,
        CP_COLORS.hairlineFade, CP_COLORS.hairline)
    end
  end
  ImGui.Dummy(ctx, 0, 1)
end

-- Returns a token to hand back to UI.cardEnd. Content in between is indented
-- and sits on the card surface.
-- `h` forces the card's height. Without it the card grows to its contents,
-- which is what almost every card wants; a card that shares a row with another
-- one needs the row's height instead, and needs it as a real height rather than
-- as padding poured into the contents -- padded, the two boxes still end up
-- however ImGui chooses to round their auto height, and "almost the same" is
-- what a grid is for avoiding.
function UI.cardBegin(id, h)
  if not HAS_CARDS then return false end
  h = tonumber(h) or 0
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg(), CP_COLORS.card)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border(),  CP_COLORS.cardBorder)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ChildRounding(), 8)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding(), CARD_PAD_X, CARD_PAD_Y)
  local f = 0
  if h <= 0 then f = ImGui.ChildFlags_AutoResizeY() end
  if ImGui.ChildFlags_Borders          then f = f | ImGui.ChildFlags_Borders()
  elseif ImGui.ChildFlags_Border       then f = f | ImGui.ChildFlags_Border() end
  if h <= 0 and ImGui.ChildFlags_AlwaysAutoResize then
    f = f | ImGui.ChildFlags_AlwaysAutoResize()
  end
  local open = ImGui.BeginChild(ctx, id, 0, h, f)
  return { open = open }
end

-- A card in a grid of them.
--
-- Two columns of cards that each grow to their own contents line up at the top
-- and nowhere else: the second heading on the left sits wherever the first card
-- happened to end, and the one on the right somewhere else entirely. That reads
-- as two lists side by side rather than as a page.
--
-- So each card reports the height its contents actually took, and the taller of
-- a pair sets the height of the row. The shorter one is padded up to it -- with
-- a Dummy, after the measurement, so the padding can never feed back into the
-- number it is derived from. `rowKey` nil means "not in a row" (the stacked,
-- narrow layout, and the full-width cards), and then nothing is padded.
--
-- One frame behind, like the About columns: the row height comes from the last
-- frame. That is invisible while a page sits still and self-corrects on the
-- next one, which is what these contents do.
function UI.cardGrid(id, rowKey, body)
  -- The height the row wants, from the frame before. Nothing is forced on the
  -- first frame, so a card always gets one pass at its natural size.
  local want = rowKey and (state.upRowH and state.upRowH[rowKey]) or 0
  local card = UI.cardBegin(id, want)
  local y0 = ImGui.GetCursorPosY(ctx)
  body()
  -- What the CONTENTS took, measured whether or not the box was forced -- the
  -- contents do not change because the box around them is taller. That is what
  -- keeps this from feeding back into itself.
  local h = math.max(0, (ImGui.GetCursorPosY(ctx) or 0) - (y0 or 0))
  state.upCardH = state.upCardH or {}
  state.upCardH[id] = h
  UI.cardEnd(card)
  return h
end

-- After both cards of a row have been drawn: the taller one is the row.
function UI.cardRow(rowKey, idA, idB)
  local hs = state.upCardH or {}
  local a, b = hs[idA] or 0, hs[idB] or 0
  local tall = (a > b) and a or b
  state.upRowH = state.upRowH or {}
  -- Contents plus the card's own padding, top and bottom: that is the height of
  -- the box, which is the thing that has to match.
  state.upRowH[rowKey] = (tall > 0) and (tall + CARD_PAD_Y * 2) or 0
end

function UI.cardEnd(card)
  if not card then return end
  -- ReaImGui already calls EndChild itself when BeginChild returned false.
  if card.open then ImGui.EndChild(ctx) end
  ImGui.PopStyleVar(ctx, 2)
  ImGui.PopStyleColor(ctx, 2)
  -- The shadow is drawn *after* the card, on purpose. A card is a child
  -- window with its own draw list, and child lists are composited after the
  -- parent's -- so anything painted here, in the parent, ends up underneath
  -- it. Drawing it first is impossible anyway: the card only knows its height
  -- once its contents have been laid out.
  if card.open then
    local ax, ay = ImGui.GetItemRectMin(ctx)
    local bx, by = ImGui.GetItemRectMax(ctx)
    UI.shadow(ax, ay, bx, by)
  end
end

-- The height of one line of text. Everything that has to sit on a line beside
-- text is built to this and centres itself inside it: ImGui lines up items of
-- differing heights by their tops, so anything shorter than the text rides high
-- unless it claims the whole line and places itself in the middle of it.
function UI.lineH()
  if ImGui.GetTextLineHeight then return ImGui.GetTextLineHeight(ctx) end
  local _, th = ImGui.CalcTextSize(ctx, 'X')
  return th
end

-- A "?" that shows its explanation on hover. Every setting keeps its
-- description, but the cards stay short enough to scan — the paragraph under
-- each row made the screen tall and loud.
function UI.help(id, text)
  if not text or text == '' then return end
  local d      = 15
  -- The item is as tall as the line of text it sits beside, and the ring is
  -- centred inside that. Items of different heights on one line are aligned by
  -- ImGui at the top, not through their middles, so a 15px circle next to a
  -- taller line of text sits high -- which is what the row looked like, and
  -- what the "nudge the cursor up by one" at the call site was papering over.
  local lh     = UI.lineH()
  local x, y   = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, id, d, lh)
  local hov    = ImGui.IsItemHovered(ctx)
  local dl     = ImGui.GetWindowDrawList(ctx)
  local cx, cy = x + d / 2, y + lh / 2
  local col    = hov and CP_COLORS.accent or CP_COLORS.sectionText
  ImGui.DrawList_AddCircle(dl, cx, cy, (d / 2) - 0.5, col, 0, 1.2)
  local tw, th = ImGui.CalcTextSize(ctx, '?')
  ImGui.DrawList_AddText(dl, cx - tw / 2, cy - th / 2, col, '?')
  if hov and ImGui.BeginTooltip(ctx) then
    if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 340) end
    ImGui.Text(ctx, text)
    if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
    ImGui.EndTooltip(ctx)
  end
end

-- A small green check, drawn rather than typed: the bundled faces are subset
-- and a tick glyph would be a gamble on every machine, whereas two lines are
-- two lines. It is the whole of what the old green "Render start set" line
-- said -- the words are gone, the fact is not, and the number that used to
-- trail them now lives behind the "?" next to it.
function UI.tick(size)
  local d    = size or 13
  -- Same as the "?" beside it: the item is a full text line tall and the mark
  -- is centred in it, so the three things on the row share one middle instead
  -- of hanging from a common top edge.
  local lh   = UI.lineH()
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local dl   = ImGui.GetWindowDrawList(ctx)
  local cy   = y + lh / 2
  local col  = CP_COLORS.success
  ImGui.DrawList_AddCircleFilled(dl, x + d / 2, cy, d / 2, 0x4ADE801C)
  local t = cy - d / 2
  ImGui.DrawList_AddLine(dl, x + d * 0.28, t + d * 0.52, x + d * 0.44, t + d * 0.70, col, 1.6)
  ImGui.DrawList_AddLine(dl, x + d * 0.44, t + d * 0.70, x + d * 0.74, t + d * 0.32, col, 1.6)
  ImGui.Dummy(ctx, d, lh)
end

-- A disclosure triangle, drawn rather than typed. The picker used the glyphs
-- "▼" and "▶", which are exactly the kind of codepoint that lands in whatever
-- the platform decides is the nearest font -- a different weight from the text
-- beside it at best, an emoji at worst. Two triangles are two triangles.
--
-- Takes screen coordinates and does not touch the cursor: the row it marks is
-- a Selectable spanning the whole line, so the mark has to be painted at a
-- position captured before that Selectable moved the cursor on.
function UI.disclosure(dl, x, y, open, col)
  local d = 9
  if open then
    ImGui.DrawList_AddTriangleFilled(dl, x, y + 1, x + d, y + 1, x + d / 2, y + d - 1, col)
  else
    ImGui.DrawList_AddTriangleFilled(dl, x + 1, y, x + 1, y + d, x + d - 1, y + d / 2, col)
  end
end

-- Label on the left with its "?" beside it, control on the right.
-- `draw` renders the control and is called with the cursor already placed.
-- `mark` is an optional glyph between the two -- a state that belongs to the
-- label rather than to the control.
-- `controlH` is the height of whatever `draw` puts on the right. Given, the
-- label, its mark and its "?" are centred against it; left out, nothing moves
-- and the row behaves exactly as it always did.
--
-- Why it has to be told: ImGui lines items up by their TOP edge, so a label
-- beside a 24 px button sits five pixels above the middle of the row -- which
-- is what "the text is not centred in the card" looks like. And the height of
-- the control cannot be measured here, because it is drawn after the label.
--
-- Every item on the line sets its own Y, including the control back at the top.
-- SameLine puts the cursor back to where the line began, so a single nudge
-- before the first item would drag the whole row down with it rather than
-- centring one thing inside it.
function UI.row(label, hint, controlW, draw, mark, controlH)
  local avail = ImGui.GetContentRegionAvail(ctx)
  local x0    = ImGui.GetCursorPosX(ctx)
  local yTop  = ImGui.GetCursorPosY(ctx)
  local lh    = UI.lineH()
  local rowH  = math.max(controlH or 0, lh)
  local lift  = (rowH > lh) and math.floor((rowH - lh) / 2 + 0.5) or 0
  local ctlUp = (rowH > (controlH or lh))
                and math.floor((rowH - (controlH or lh)) / 2 + 0.5) or 0
  -- Claim the height before anything is drawn. Without this the line is only
  -- as tall as the items put on it so far, and `SameLine` -- which every part
  -- of the row uses, including a control that draws two buttons -- returns the
  -- cursor to whatever the line's top was at that moment. The second button
  -- would then follow the *label's* lowered Y instead of the row's top.
  if rowH > lh then
    ImGui.Dummy(ctx, 0, rowH)
    ImGui.SameLine(ctx, 0, 0)
    ImGui.SetCursorPosX(ctx, x0)
  end
  local function atLabel() if lift > 0 then ImGui.SetCursorPosY(ctx, yTop + lift) end end
  atLabel()
  ImGui.Text(ctx, label)
  if mark then
    ImGui.SameLine(ctx, 0, 6)
    atLabel()
    mark()
  end
  if hint then
    ImGui.SameLine(ctx, 0, 6)
    -- No nudge of its own: the "?" is a full text line tall and centres its own
    -- ring, so it wants the same Y as the label and nothing else. That nudge
    -- was the symptom of the alignment being wrong, not the cure.
    atLabel()
    UI.help('##help_' .. label, hint)
  end
  if draw then
    ImGui.SameLine(ctx)
    ImGui.SetCursorPosX(ctx, x0 + math.max(0, avail - (controlW or 0)))
    -- Centred in the row as well, which for the usual case (the control IS the
    -- tallest thing) means straight back to the top.
    if rowH > lh or ctlUp > 0 then ImGui.SetCursorPosY(ctx, yTop + ctlUp) end
    draw()
  end
end

-- Hairline between rows of the same card.
function UI.rowSep()
  ImGui.Dummy(ctx, 0, 5)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w    = ImGui.GetContentRegionAvail(ctx)
  ImGui.DrawList_AddLine(ImGui.GetWindowDrawList(ctx), x, y, x + w, y, CP_COLORS.rowSep, 1)
  ImGui.Dummy(ctx, 0, 5)
end

-- Switch. ImGui only offers a checkbox, so this is drawn by hand: a rounded
-- track with a knob that sits on the side matching the state.
-- `dim` because this switch is painted into the draw list, and BeginDisabled
-- only greys out what ImGui draws itself. A row whose label had gone dim while
-- its switch still glowed at full strength read as "off but somehow still on".
function UI.toggle(id, value, dim)
  local w, h = 32, K.TOGGLE_H
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local hit  = ImGui.InvisibleButton(ctx, id, w, h)
  local hov  = ImGui.IsItemHovered(ctx) and not dim
  local on   = value and true or false
  if hit and not dim then on = not on end
  local dl   = ImGui.GetWindowDrawList(ctx)
  local track = on and (dim and CP_COLORS.accentMuted or CP_COLORS.accentStrong)
                    or (hov and CP_COLORS.active or CP_COLORS.trackOff)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, track, h / 2)
  if on and hov then
    ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, CP_COLORS.accent, h / 2)
  end
  local kr = (h / 2) - 2
  local kx = on and (x + w - kr - 2) or (x + kr + 2)
  ImGui.DrawList_AddCircleFilled(dl, kx, y + h / 2, kr,
    on and (dim and 0xFFFFFF80 or 0xFFFFFFFF) or CP_COLORS.knob)
  return hit, on
end

-- Two halves in one outline, the active one filled. A/B is a choice between
-- two things, and a single button that says what it will switch to made the
-- reader work out which one they were hearing.
-- Returns the index the user picked, or nil.
-- `disabled` is a set of indices that are shown but cannot be chosen -- a kind
-- the production has no upload of. They are drawn, because "there is no
-- instrumental yet" is worth seeing, and they never return a pick.
-- How wide this control has to be for its own labels to fit. Measured, because
-- a number that works on one machine is a guess on the next: the text metric
-- depends on the font, its size and whatever Reaper's UI scale is set to, and
-- none of that is knowable from here.
K.SEG_PAD = 10

-- Where a second button may sit on the sync row, and whether it fits at all.
--
-- `reserved` is the strip on the right that something else already occupies
-- WITHOUT having reserved it: the cover paints itself into the corner straight
-- into the draw list and never moves the cursor, so GetContentRegionAvail knows
-- nothing about it. Right-aligning against the full width put the button on top
-- of the artwork -- seen at the device on 2026-08-23, and the card's own
-- comments had said as much two screens further up.
function UI.pairOnRow(avail, tailW, reserved, btnW, minFirst)
  local room = avail - (reserved or 0)
  local firstW = room - (tailW or 0) - btnW - 12
  if firstW < (minFirst or 90) then return false end
  return true, math.max(0, room - btnW), firstW
end

function UI.segmentedMinW(labels)
  local widest = 0
  for _, l in ipairs(labels) do
    local tw = ImGui.CalcTextSize(ctx, l)
    if tw > widest then widest = tw end
  end
  return math.ceil((widest + K.SEG_PAD * 2) * #labels)
end

function UI.segmented(id, labels, activeIdx, totalW, disabled)
  disabled = disabled or {}
  local h      = 28
  local x, y   = ImGui.GetCursorScreenPos(ctx)
  local avail  = ImGui.GetContentRegionAvail(ctx)
  -- The caller says how wide it would LIKE this to be. It does not get to make
  -- it narrower than its own text: below that the centring pushes each label
  -- out past its half, and the first one ends up drawn outside the card
  -- entirely. Reported from a real Reaper on 2026-08-23, and invisible here
  -- because the harness models 7 px per character.
  local w = math.max(totalW or avail, UI.segmentedMinW(labels))
  -- ...and never wider than the region it sits in, or the window becomes
  -- draggable sideways. When both cannot be had, the clip below is what stops
  -- the text escaping.
  if avail and avail > 0 then w = math.min(w, avail) end
  local halfW  = w / #labels
  local picked = nil
  local dl     = ImGui.GetWindowDrawList(ctx)
  local rc     = ImGui.DrawFlags_RoundCornersAll and 0 or 0

  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, CP_COLORS.card, 7)
  for i, label in ipairs(labels) do
    local sx = x + (i - 1) * halfW
    local ex = sx + halfW
    ImGui.SetCursorScreenPos(ctx, sx, y)
    if ImGui.InvisibleButton(ctx, id .. '_' .. i, halfW, h) and not disabled[i] then
      picked = i
    end
    local hov = ImGui.IsItemHovered(ctx) and not disabled[i]
    if i == activeIdx then
      -- Only the outer corners of the active half are rounded, so the pair
      -- reads as one control rather than two pills.
      local flags = rc
      if #labels > 1 then
        if i == 1 and ImGui.DrawFlags_RoundCornersLeft then
          flags = ImGui.DrawFlags_RoundCornersLeft()
        elseif i == #labels and ImGui.DrawFlags_RoundCornersRight then
          flags = ImGui.DrawFlags_RoundCornersRight()
        end
      end
      ImGui.DrawList_AddRectFilled(dl, sx + 2, y + 2, ex - 2, y + h - 2,
                                   CP_COLORS.accentStrong, 5, flags)
    elseif hov then
      ImGui.DrawList_AddRectFilled(dl, sx + 2, y + 2, ex - 2, y + h - 2,
                                   CP_COLORS.hover, 5)
    end
    local tw, th = ImGui.CalcTextSize(ctx, label)
    local tcol = CP_COLORS.textDim
    if i == activeIdx then tcol = 0xFFFFFFFF
    elseif disabled[i] then tcol = CP_COLORS.sectionText end
    -- Clipped to its own half, always. The width above should make this
    -- unnecessary; it is here because "should" is what the overflowing build
    -- also thought, and a label that cannot fit is better cut off than drawn
    -- across its neighbour.
    local clipped = ImGui.DrawList_PushClipRect
                    and pcall(ImGui.DrawList_PushClipRect, dl, sx, y, ex, y + h, true)
    ImGui.DrawList_AddText(dl, sx + math.max(0, (halfW - tw) / 2), y + (h - th) / 2, tcol, label)
    if clipped then ImGui.DrawList_PopClipRect(dl) end
  end
  ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, CP_COLORS.cardBorder, 7)
  ImGui.SetCursorScreenPos(ctx, x, y + h)
  -- The geometry rides along so a harness can ask where this control actually
  -- ended up. Hunting for it among the frame's rectangles picks the wrong one
  -- and the assertion then measures nothing -- which is exactly what the first
  -- attempt at the overflow check did.
  return picked, x, w, h
end

-- A pill: a rounded, clickable chip. Drawn rather than assembled from a Button
-- so the text sits properly centred in it and the active one can be filled
-- without fighting the theme's button colours. `w` is the caller's, because a
-- row of these has to be measured before any of them is drawn -- otherwise
-- there is no way to know where the row breaks.
-- Split from UI.pill because the picker cannot do both at once: its hit area has
-- to be submitted BEFORE the row's Selectable (ImGui gives hover to the first
-- item that claims it) while its paint has to happen AFTER it (the Selectable
-- paints its hover highlight over whatever was drawn before, which is what hid
-- these pills behind it).
function UI.pillPaint(dl, x, y, w, h, label, active, hovered)
  local bg = active and CP_COLORS.accentStrong or (hovered and CP_COLORS.hover or CP_COLORS.card)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, bg, h / 2)
  if not active then
    ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, CP_COLORS.cardBorder, h / 2)
  end
  local tw, th = ImGui.CalcTextSize(ctx, label)
  ImGui.DrawList_AddText(dl, x + (w - tw) / 2, y + (h - th) / 2,
                         active and 0xFFFFFFFF or CP_COLORS.text, label)
end

function UI.pill(id, label, active, w, h)
  h = h or 22
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local hit  = ImGui.InvisibleButton(ctx, id, w, h)
  UI.pillPaint(ImGui.GetWindowDrawList(ctx), x, y, w, h, label, active,
               ImGui.IsItemHovered(ctx))
  return hit
end

-- A compact badge: a dot, a word, a rounded outline. Drawn rather than
-- assembled from widgets so the text sits properly centred inside it.
-- Width is returned so callers can position from a measurement instead of an
-- estimate — guessing it is what pushed the Settings button off the edge.
-- The badge sizes itself from its text, so anything that has to match its
-- height has to ask rather than guess. The hamburger guessed 22 and came out a
-- shade shorter than the badge beside it.
function UI.badgeHeight()
  ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
  local _, th = ImGui.CalcTextSize(ctx, 'X')
  ImGui.PopFont(ctx)
  return th + 8
end

-- The badge is a status, not a control, so it is deliberately smaller than the
-- buttons beside it: badgeHeight stays the row height (the menu button and the
-- close box are square to it), while the pill itself is K.BADGE_SHRINK shorter
-- and centred in that row. It carries no dot any more either -- the word is
-- the state, and the dot only added weight to the one thing on the row that
-- cannot be clicked.
K.BADGE_SHRINK = 6
-- Its own size, a shade under the small text elsewhere. Shortening the pill
-- alone left the letters at full size, so it barely read as smaller.
K.FONT_BADGE   = 10

-- What the header pill says. It used to say CONNECTED, which answers "is there
-- a token" -- a question nobody was asking. The studio name answers the one
-- that matters before anything is uploaded: WHICH studio is this device paired
-- to. A name that is not yours is meant to be noticed.
--
-- Recognition, not prevention: pairing is still approved in the browser, and
-- this does not stop a device being paired to the wrong place. It makes it
-- visible, which is the cheapest thing that helps.
K.CONN_LABEL_MAX = 22

function UI.connLabel()
  -- The deviation wins the pill: which worker is being talked to is the more
  -- surprising fact of the two, and it is temporary.
  if state.apiUrl ~= K.API_URL then return 'PREVIEW' end
  local name = state.studioName
  if type(name) ~= 'string' then return 'CONNECTED' end
  name = name:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' then return 'CONNECTED' end
  return UI.connTrim(name, K.CONN_LABEL_MAX)
end

-- Cut on a character, not on a byte. Studio names are not guaranteed to be
-- ASCII -- half the productions in this account are Russian -- and a byte-wise
-- cut through a two-byte letter puts a broken glyph in the header.
function UI.connTrim(s, maxChars)
  local n, i = 0, 1
  while i <= #s do
    local b = s:byte(i)
    local size = (b < 0x80 and 1) or (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4
    if n + 1 > maxChars then
      -- Room for the ellipsis inside the budget, so the label never grows past
      -- what the header was measured for.
      local cut, m, j = 1, 0, 1
      while j <= #s and m < maxChars - 1 do
        local bb = s:byte(j)
        j = j + ((bb < 0x80 and 1) or (bb < 0xE0 and 2) or (bb < 0xF0 and 3) or 4)
        m, cut = m + 1, j
      end
      return s:sub(1, cut - 1) .. '\u{2026}'
    end
    n = n + 1
    i = i + size
  end
  return s
end

function UI.badgeWidth(label)
  ImGui.PushFont(ctx, FONT, K.FONT_BADGE)
  local tw = ImGui.CalcTextSize(ctx, label)
  ImGui.PopFont(ctx)
  return 7 + tw + 7
end

function UI.badge(label, col, bgAlphaCol, borderCol)
  -- badgeHeight (and with it the menu button and the close box) stays on
  -- FONT_SMALL; only the pill uses the smaller face.
  local rowH = UI.badgeHeight()
  ImGui.PushFont(ctx, FONT, K.FONT_BADGE)
  local tw, th = ImGui.CalcTextSize(ctx, label)
  local padX = 7
  local bw   = padX + tw + padX
  local bh   = rowH - K.BADGE_SHRINK
  local x, y = ImGui.GetCursorScreenPos(ctx)
  -- Down by half the difference, so a shorter pill still sits on the same
  -- centre line as the controls next to it instead of hanging at the top.
  y = y + math.floor((rowH - bh) / 2)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + bw, y + bh, bgAlphaCol, bh / 2)
  ImGui.DrawList_AddRect(dl, x, y, x + bw, y + bh, borderCol, bh / 2)
  ImGui.DrawList_AddText(dl, x + padX, y + (bh - th) / 2, col, label)
  -- The item keeps the full row height: nothing below may move just because
  -- the pill got shorter.
  ImGui.Dummy(ctx, bw, rowH)
  ImGui.PopFont(ctx)
end

-- The one action a screen is really about.
function UI.primaryButton(label, w)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button(),        CP_COLORS.accentStrong)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered(), CP_COLORS.accent)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive(),  CP_COLORS.accentStrong)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(),          0xFFFFFFFF)
  local hit = ImGui.Button(ctx, label, w or 0, 0)
  ImGui.PopStyleColor(ctx, 4)
  return hit
end

-- Prose inside a card: small, dim, and wrapped. The About screen is nothing but
-- prose, and prose that does not wrap is what lets a window be dragged sideways
-- (which is the whole point of test-narrow).
function UI.para(text, bright)
  ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), bright and CP_COLORS.text or CP_COLORS.textDim)
  if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 0) end
  ImGui.Text(ctx, text)
  if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
  ImGui.PopStyleColor(ctx)
  ImGui.PopFont(ctx)
end

-- A list item. The bullet travels inside the string rather than being a widget
-- of its own: an item drawn as "glyph, SameLine, wrapped text" wraps its second
-- line back to the far left of the card, which reads as a new item rather than
-- as a continuation.
function UI.bullet(text)
  ImGui.Indent(ctx, 8)
  UI.para('\u{2022}  ' .. text)
  ImGui.Unindent(ctx, 8)
  ImGui.Dummy(ctx, 0, 3)
end

-- A row whose control is a button that opens something in the browser. `id`
-- because two rows may share a label, and ImGui tells buttons apart by their
-- label alone.
function UI.linkRow(label, url, hint, id)
  local w = ImGui.CalcTextSize(ctx, 'Open') + 24
  UI.row(label, hint, w, function()
    if ImGui.Button(ctx, 'Open##' .. (id or url), w, 0) then openUrl(url) end
  end, nil, ImGui.GetFrameHeight and ImGui.GetFrameHeight(ctx) or nil)
end

-- One line of small text, clipped rather than wrapped, and exactly one line tall
-- whatever it says. Wrapping is right for prose and wrong for a status line: a
-- sentence that takes two lines on a narrow window and one on a wide one makes
-- the block below it move as the window is dragged, and a line that appears and
-- disappears makes it move on every click.
--
-- An empty string still takes its line. That is the whole point: the slot is
-- there whether or not there is anything to put in it.
function UI.oneLine(text, bright)
  local lh = UI.lineH()
  if not text or text == '' then ImGui.Dummy(ctx, 0, lh); return end
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w    = ImGui.GetContentRegionAvail(ctx)
  local dl   = ImGui.GetWindowDrawList(ctx)
  local clipped = ImGui.DrawList_PushClipRect
                  and pcall(ImGui.DrawList_PushClipRect, dl, x, y, x + w, y + lh, true)
  ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
  ImGui.DrawList_AddText(dl, x, y, bright and CP_COLORS.text or CP_COLORS.textDim, text)
  ImGui.PopFont(ctx)
  if clipped then ImGui.DrawList_PopClipRect(dl) end
  ImGui.Dummy(ctx, 0, lh)
end

-- A slot of exactly `n` lines. Height by construction, not by measurement:
-- reading the cursor back and padding the difference would depend on the
-- content having been measured, and there are frames where it has not been.
function UI.slot(n, lines, bright)
  for i = 1, n do UI.oneLine(lines and lines[i] or nil, bright) end
end

-- Break `text` over at most `n` lines that fit `maxW`. UI.oneLine clips on a
-- hard edge -- which is right for a filename and wrong for a sentence: the
-- warning about an empty time selection read "Nothing is selected in the
-- timeline. This would" and then stopped, four pixels short of the word that
-- says what happens. Greedy by word, measured rather than counted, because a
-- character is not a width.
function UI.wrapLines(text, maxW, n)
  local out = {}
  if not text or text == '' then return out end
  local line = nil
  for word in tostring(text):gmatch('%S+') do
    local try = line and (line .. ' ' .. word) or word
    if line and (ImGui.CalcTextSize(ctx, try) or 0) > maxW then
      out[#out + 1] = line
      if #out >= n then
        -- No room left: the last line takes what is left of the text, cut.
        out[#out] = UI.ellipsisEnd(line .. ' ' .. word, maxW)
        return out
      end
      line = word
    else
      line = try
    end
  end
  if line then out[#out + 1] = line end
  return out
end

-- `n` lines, wrapped, and always exactly `n` tall -- the empty ones are Dummies
-- like everywhere else on this page.
function UI.slotWrap(n, text, bright)
  local w = ImGui.GetContentRegionAvail(ctx)
  local ls = UI.wrapLines(text, w, n)
  UI.slot(n, ls, bright)
end

function UI.ellipsisEnd(text, maxW)
  if (ImGui.CalcTextSize(ctx, text) or 0) <= maxW then return text end
  local cut = text
  while #cut > 1 do
    cut = cut:sub(1, utf8.offset(cut, -1) - 1)
    if (ImGui.CalcTextSize(ctx, cut .. '\u{2026}') or 0) <= maxW then break end
  end
  return cut .. '\u{2026}'
end

-- A path is cut in the MIDDLE, not at the end: the tail is the folder anybody
-- is actually looking for, and "/Users/x/Library/Application Support/REAPER/ab"
-- with the rest silently gone is worse than useless -- it reads like a complete
-- path that happens to be wrong.
function UI.ellipsisMid(text, maxW)
  text = tostring(text or '')
  if (ImGui.CalcTextSize(ctx, text) or 0) <= maxW then return text end
  local n = utf8.len(text)
  if not n or n < 4 then return text end
  local keepTail = math.floor(n / 2)
  local head = text:sub(1, utf8.offset(text, n - keepTail) - 1)
  local tail = text:sub(utf8.offset(text, -keepTail))
  -- Shrink both halves together until it fits.
  while utf8.len(head) and utf8.len(head) > 1 and utf8.len(tail) and utf8.len(tail) > 1 do
    if (ImGui.CalcTextSize(ctx, head .. '\u{2026}' .. tail) or 0) <= maxW then break end
    head = head:sub(1, utf8.offset(head, -1) - 1)
    tail = tail:sub(utf8.offset(tail, 2))
  end
  return head .. '\u{2026}' .. tail
end

-- Dimmed key on the left, value right-aligned. Used for the diagnostics block.
function UI.kv(key, value)
  local avail = ImGui.GetContentRegionAvail(ctx)
  local x0    = ImGui.GetCursorPosX(ctx)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.textDim)
  ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
  ImGui.Text(ctx, key)
  ImGui.SameLine(ctx)
  local vw = ImGui.CalcTextSize(ctx, value)
  ImGui.SetCursorPosX(ctx, x0 + math.max(0, avail - vw))
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.text)
  ImGui.Text(ctx, value)
  ImGui.PopStyleColor(ctx)
  ImGui.PopFont(ctx)
  ImGui.PopStyleColor(ctx)
end

-- Apply full CuePort theme to the next ImGui window. Returns (numColors,
-- numVars) so the caller can pop them after ImGui_End().
-- ══════════════════════════════════════════════════════════════════════════════
-- MENU — hamburger in the header, everything that navigates behind it
-- ══════════════════════════════════════════════════════════════════════════════

-- Three lines in a rounded hit area. Drawn rather than a button with a label so
-- it keeps the weight of the rest of the header. While the menu is open it
-- stays lit in the menu's own background colour and loses its bottom rounding,
-- so button and panel read as one shape rather than two.
-- With no title bar there is no system close box, so the header carries its
-- own. Square, same height as the badge and the hamburger, so the three read
-- as one row of controls. It hides the window rather than ending the script:
-- the hover tooltip and the pill keep running, which is what "Quit" in the
-- menu does not do.
function UI.closeButton(id)
  local d    = UI.badgeHeight()
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local hit  = ImGui.InvisibleButton(ctx, id, d, d)
  local hov  = ImGui.IsItemHovered(ctx)
  local dl   = ImGui.GetWindowDrawList(ctx)
  if hov then ImGui.DrawList_AddRectFilled(dl, x, y, x + d, y + d, CP_COLORS.hover, 6) end
  local col = hov and CP_COLORS.text or CP_COLORS.textDim
  local m   = 7                       -- same inset the hamburger uses
  ImGui.DrawList_AddLine(dl, x + m, y + m, x + d - m, y + d - m, col, 1.6)
  ImGui.DrawList_AddLine(dl, x + d - m, y + m, x + m, y + d - m, col, 1.6)
  return hit
end

function UI.hamburger(id, open)
  -- Height comes from the badge next to it, so the two always line up.
  local h    = UI.badgeHeight()
  local w    = h + 6
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local hit  = ImGui.InvisibleButton(ctx, id, w, h)
  local hov  = ImGui.IsItemHovered(ctx)
  local dl   = ImGui.GetWindowDrawList(ctx)
  if open then
    -- The tab, drawn right here in the header — no reaching outside a window,
    -- which not every ReaImGui build can do. Panel surface, panel border,
    -- rounded on top and open at the bottom.
    --
    -- It carries on well past the button's own bottom edge. Where the panel
    -- starts right there, the panel simply covers the surplus (same colour, and
    -- it hides the side borders too). Where ImGui has nudged the panel down a
    -- little, that surplus is what bridges the gap instead of leaving daylight
    -- between button and menu. Either way there is nothing to see through.
    local topOnly = ImGui.DrawFlags_RoundCornersTop and ImGui.DrawFlags_RoundCornersTop() or 0
    local bot     = y + h + K.MENU_BRIDGE
    -- A pixel in from the button's own sides where the panel is going to cover
    -- this anyway. ImGui floors a window's position, so the panel can sit a
    -- fraction to the left of the button; a surplus drawn out to the button's
    -- right edge then shows as a sliver of surface standing beside the panel,
    -- ten pixels of it, right under the join. Above the panel the seam patch
    -- repaints this whole area, so the inset is invisible where it would matter.
    -- Without the patch the fallback below outlines the same rectangle, and
    -- there the two have to keep agreeing -- hence no inset in that case.
    local ins = UI.CAN_PATCH and 1 or 0
    ImGui.DrawList_AddRectFilled(dl, x + ins, y, x + w - ins, bot, K.MENU_BG, K.MENU_ROUND, topOnly)
    -- A border only where the panel cannot paint the join itself. Otherwise the
    -- panel's border is the only one in the whole shape, which is the point:
    -- this one sat a fraction beside it and showed up as a frayed edge at the
    -- top corner and a step down the right-hand side.
    if not UI.CAN_PATCH then
      ImGui.DrawList_AddRect(dl, x, y, x + w, bot, K.MENU_BORDER, K.MENU_ROUND, topOnly)
      ImGui.DrawList_AddRectFilled(dl, x, bot - 1.5, x + w - 1, bot + 1.5, K.MENU_BG)
    end
  elseif hov then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, CP_COLORS.hover, 6)
  end
  local col = open and CP_COLORS.accent or (hov and CP_COLORS.text or CP_COLORS.textDim)
  local mid = y + h / 2
  for i = -1, 1 do
    local ly = mid + i * 4.5
    ImGui.DrawList_AddLine(dl, x + 7, ly, x + w - 7, ly, col, 1.6)
  end
  -- Remember where the button sits and how much room the window has: the menu
  -- is positioned by hand from this, so it opens inside the window instead of
  -- wherever ImGui would have dropped it.
  local ax0, ay0 = ImGui.GetItemRectMin(ctx)
  local ax1, ay1 = ImGui.GetItemRectMax(ctx)
  local wx,  wy  = ImGui.GetWindowPos(ctx)
  -- Two returns, so this cannot be folded into an `and` expression: that keeps
  -- only the first one and the height would silently stay nil.
  local ww,  wh  = 0, 0
  if ImGui.GetWindowSize then ww, wh = ImGui.GetWindowSize(ctx) end
  state.menuAnchor = { x0 = ax0, y0 = ay0, x1 = ax1, y1 = ay1,
                       wx = wx, wy = wy, ww = ww or 0, wh = wh or 0,
                       -- The panel paints over this button, so it has to carry
                       -- the hover state across or hovering would do nothing
                       -- visible while the menu is open.
                       hovered = hov and true or false }
  return hit
end

-- One row of the menu: full width, rounded hover, no ImGui menu chrome. The row
-- for the screen you are on is marked rather than hidden — a menu that drops
-- the entry you came from makes you hunt for where you are.
function UI.menuItem(id, label, opts)
  opts = opts or {}
  local w    = ImGui.GetContentRegionAvail(ctx)
  local h    = 27
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local hit  = ImGui.InvisibleButton(ctx, id, w, h)
  local hov  = ImGui.IsItemHovered(ctx)
  local dl   = ImGui.GetWindowDrawList(ctx)
  if hov then ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, CP_COLORS.hover, 6) end
  local col = CP_COLORS.text
  if opts.danger then col = CP_COLORS.danger elseif opts.dim then col = CP_COLORS.textDim end
  if opts.active then
    col = CP_COLORS.accent
    ImGui.DrawList_AddRectFilled(dl, x + 2, y + 6, x + 5, y + h - 6, CP_COLORS.accent, 1.5)
  end
  local _, th = ImGui.CalcTextSize(ctx, label)
  ImGui.DrawList_AddText(dl, x + 10, y + (h - th) / 2, col, label)
  return hit
end

-- Can the panel paint the join over the button? Only if it may set a clip
-- rectangle outside its own window. When it can, the button must not draw a
-- border of its own: two borders that never land on exactly the same pixel are
-- what makes the corners look frayed.
UI.CAN_PATCH = (ImGui.DrawList_PushClipRect ~= nil)
               or (ImGui.DrawList_PushClipRectFullScreen ~= nil)

-- The other half of the join, drawn from inside the panel: its own top edge is
-- opened up where the tab sits, so the two surfaces run into each other with no
-- line between them.
--
-- Everything here happens inside the panel's own rectangle. The first attempt
-- drew the whole shape from in here and had to paint outside the window to
-- reach the button, which needs full-screen clipping — not something every
-- ReaImGui build offers, and where it is missing the button fell back to
-- looking like a separate box floating above the menu.
function UI.menuOpenSeam()
  local a = state.menuAnchor
  if not a or not ImGui.GetWindowSize then return end
  local px, py = ImGui.GetWindowPos(ctx)
  local pw, ph = ImGui.GetWindowSize(ctx)
  local dl     = ImGui.GetWindowDrawList(ctx)
  if not (pw and ph and pw > 0 and ph > 0) then return end
  local x0, y0, x1 = a.x0, a.y0, a.x1
  local R          = K.MENU_ROUND
  local bot        = py + R
  local function dflag(n) local f = ImGui['DrawFlags_' .. n]; return f and f() or 0 end
  local fill    = a.hovered and UI.mix(K.MENU_BG, CP_COLORS.hover, 0.75) or K.MENU_BG
  local hasPath = ImGui.DrawList_PathLineTo and ImGui.DrawList_PathArcTo
                  and ImGui.DrawList_PathStroke

  -- The panel is right-aligned under the button, so their right-hand edges are
  -- the same line and the two can be drawn as one shape. If they have been
  -- pulled apart -- a window too narrow for the panel to sit under its button --
  -- they cannot, and the fallback further down draws them as two.
  local flush = UI.CAN_PATCH and hasPath and math.abs(x1 - (px + pw)) < 1.5

  -- ImGui floors a window's position, and the button's right edge does not have
  -- to be a whole number -- padding and text metrics put it wherever they put
  -- it. So the panel can end up to a pixel to the left of the button it hangs
  -- from. Move the tab onto the panel: same width, but its right edge *is* the
  -- panel's, by construction rather than by rounding.
  if flush then
    local dx = (px + pw) - x1
    x0, x1 = x0 + dx, x1 + dx
  end

  if flush then
    -- ONE outline for the whole silhouette: up the tab's left edge, round its
    -- top, down its right edge -- which is the panel's right edge, so it simply
    -- carries on -- round the panel and back along the top to where the tab
    -- began.
    --
    -- Every version before this drew the panel's border as a rectangle, painted
    -- the part under the tab away again, and pieced what was left back together
    -- with a stroke here and a one-pixel line there. Three different calls met
    -- on the same two columns of pixels, and no two of them lay down ink quite
    -- the same way: a notch at one bottom corner of the tab, a broken length of
    -- border at the other. A single path cannot disagree with itself, and there
    -- is nothing left to erase or restore.
    ImGui.DrawList_PushClipRect(dl, px - 1, y0 - 2, px + pw + 1, py + ph + 1, false)

    -- Surface first, under the outline. The tab above the panel carries the
    -- hover highlight; the strip below it does not -- that is the panel's own
    -- surface, and it is only painted at all to fill the rounded top-right
    -- corner ImGui gives the popup, which would otherwise cut into the join.
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, py, fill, R, dflag('RoundCornersTop'))
    ImGui.DrawList_AddRectFilled(dl, x0, py, x1, bot, K.MENU_BG)

    if ImGui.DrawList_PathClear then ImGui.DrawList_PathClear(dl) end
    ImGui.DrawList_PathLineTo(dl, x0 + 0.5, py + 0.5)                                  -- tab, bottom left
    ImGui.DrawList_PathArcTo(dl, x0 + 0.5 + R, y0 + 0.5 + R, R, math.pi, math.pi * 1.5)
    ImGui.DrawList_PathArcTo(dl, x1 - 0.5 - R, y0 + 0.5 + R, R, math.pi * 1.5, math.pi * 2)
    -- No point of its own between the tab and the panel: the tab's right edge
    -- and the panel's are the same x, so the polyline runs straight down.
    ImGui.DrawList_PathArcTo(dl, px + pw - 0.5 - R, py + ph - 0.5 - R, R, 0, math.pi * 0.5)
    ImGui.DrawList_PathArcTo(dl, px + 0.5 + R,      py + ph - 0.5 - R, R, math.pi * 0.5, math.pi)
    ImGui.DrawList_PathArcTo(dl, px + 0.5 + R,      py + 0.5 + R,      R, math.pi, math.pi * 1.5)
    -- Closed, so the top edge back to the tab is the path's own closing segment
    -- rather than a second line drawn over the same pixels. `or 1` would keep a
    -- zero, and zero means open -- so the value is checked, not defaulted.
    local cf = 1
    if ImGui.DrawFlags_Closed then
      local v = ImGui.DrawFlags_Closed()
      if v and v ~= 0 then cf = v end
    end
    ImGui.DrawList_PathStroke(dl, K.MENU_BORDER, cf, 1)

    -- The icon is under all of that now, so it comes back on top.
    local mid = y0 + (a.y1 - y0) / 2
    for i = -1, 1 do
      local ly = mid + i * 4.5
      ImGui.DrawList_AddLine(dl, x0 + 7, ly, x1 - 7, ly, CP_COLORS.accent, 1.6)
    end
    ImGui.DrawList_PopClipRect(dl)
    return
  end

  -- Fallback: the panel has been clamped away from its button, or this build
  -- has no path API. Two shapes then, each with its own border, and the join is
  -- as good as painting over it gets.
  ImGui.DrawList_AddRect(dl, px + 0.5, py + 0.5, px + pw - 0.5, py + ph - 0.5,
                         K.MENU_BORDER, R, 0)
  local clipped = false
  if ImGui.DrawList_PushClipRect then
    -- `false` = do not intersect with the current clip, which is what makes it
    -- possible to draw above the panel at all.
    ImGui.DrawList_PushClipRect(dl, x0 - 1, y0 - 2, x1 + 1, bot + 2, false)
    clipped = true
  elseif ImGui.DrawList_PushClipRectFullScreen then
    ImGui.DrawList_PushClipRectFullScreen(dl)
    clipped = true
  end
  if clipped then
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, py, fill, R, dflag('RoundCornersTop'))
    ImGui.DrawList_AddRectFilled(dl, x0, py, x1, bot, fill)
    if hasPath then
      if ImGui.DrawList_PathClear then ImGui.DrawList_PathClear(dl) end
      ImGui.DrawList_PathLineTo(dl, x0 + 0.5, py + 0.5)
      ImGui.DrawList_PathArcTo(dl, x0 + 0.5 + R, y0 + 0.5 + R, R, math.pi, math.pi * 1.5)
      ImGui.DrawList_PathArcTo(dl, x1 - 0.5 - R, y0 + 0.5 + R, R, math.pi * 1.5, math.pi * 2)
      ImGui.DrawList_PathLineTo(dl, x1 - 0.5, bot)
      ImGui.DrawList_PathStroke(dl, K.MENU_BORDER, 0, 1)
    else
      -- No path API: a box whose bottom edge falls outside the clip, so the
      -- clip does the opening instead.
      ImGui.DrawList_AddRect(dl, x0 + 0.5, y0 + 0.5, x1 - 0.5, bot + 6,
                             K.MENU_BORDER, R, dflag('RoundCornersTop'))
    end
    local mid = y0 + (a.y1 - y0) / 2
    for i = -1, 1 do
      local ly = mid + i * 4.5
      ImGui.DrawList_AddLine(dl, x0 + 7, ly, x1 - 7, ly, CP_COLORS.accent, 1.6)
    end
    ImGui.DrawList_PopClipRect(dl)
  end
end

function UI.menuSep()
  ImGui.Dummy(ctx, 0, 4)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w    = ImGui.GetContentRegionAvail(ctx)
  ImGui.DrawList_AddLine(ImGui.GetWindowDrawList(ctx), x + 6, y, x + w - 6, y, CP_COLORS.rowSep, 1)
  ImGui.Dummy(ctx, 0, 4)
end

K.MENU_W   = 230
K.MENU_ROW = 27
K.MENU_SEP = 9
-- One source for the panel's surface and outline. The tab that joins it to the
-- button is drawn by hand while the panel itself is painted by ImGui, so any
-- second opinion about either colour shows up as a seam: the outline used to be
-- the card border on the tab and the generic window border on the panel, which
-- is two different greys meeting in the middle.
K.MENU_BG     = CP_COLORS.card
K.MENU_BORDER = CP_COLORS.cardBorder
-- Corner radius of the panel, and how far the tab reaches into it. The tab has
-- to cover the panel's rounded top-right corner completely, so reaching in by
-- exactly the radius is the smallest value that works — tying them together
-- keeps it that way if the radius is ever changed.
K.MENU_ROUND  = 6
K.MENU_TAB_IN = K.MENU_ROUND
-- The panel's wash, as fractions rather than pixels, because the panel is as
-- tall as it has rows and a distance in pixels would be a different gradient on
-- a five-row menu than on an eight-row one.
--
-- WASH_TO   how far down the panel it reaches
-- WASH_PEAK where it is brightest, within that span. Not zero: unlike the
--           cards' the wash cannot start at full strength, it has to climb, and
--           a climb needs room -- washTop is ten steps of alpha, and ten steps
--           over a few pixels is a visible ladder however smooth the curve.
-- WASH_SEG  how many bands the curve is sampled into. A multiple of 1/WASH_PEAK
--           so the peak lands exactly on a band edge instead of being clipped
--           just short of it.
K.MENU_WASH_TO   = 0.70
K.MENU_WASH_PEAK = 0.30
K.MENU_WASH_SEG  = 10
-- How far the tab carries on below the button. It has to cover the panel's
-- rounded corner (hence at least the radius) and to bridge any gap ImGui might
-- put between the button and the panel, so it is deliberately generous: the
-- surplus is invisible either way, once because the panel covers it and once
-- because it is exactly what fills the gap.
K.MENU_BRIDGE = 10
K.BTN_H    = 24   -- one height for buttons that share a row
K.TOGGLE_H = 18   -- and one for the switches, so a row can centre its label
-- What the picker leaves under its list: the spacer and footer that follow
-- every screen. Subtracted rather than left to "fill", because filling is what
-- pulled the window longer every frame.
K.PICKER_BOTTOM_PAD = 16
-- Two settings tiles plus the gap and the two margins was the old floor (668).
-- A third wider, because that floor predates the comment column: at 668 the
-- body has 520px of room, exactly K.COMMENTS_MIN_ROOM, so the column sat right
-- on the edge of stepping aside and the waveform beside it was as thin as it
-- is ever allowed to be. The height floor is whatever the content measures,
-- capped so it can never ask for more than a laptop screen.
K.MAIN_MIN_W     = 890
K.MAIN_MIN_H_CAP = 800

-- Blend two 0xRRGGBBAA colours. Used for the pulse on a button that is asking
-- to be pressed; keeping it here means the pulse is one expression, not a
-- hand-rolled bit fiddle at the call site.
-- Is CuePort's render start actually set? Answered by the marker we place, not
-- by Reaper's project time offset: a project template can carry an offset the
-- user never asked for, and then the button sat there claiming to be done on a
-- brand new project. Deleting the marker is also the first thing "Clear" does,
-- so this flips the moment it is pressed rather than after the re-sync.
--
-- Cached for a quarter second because it walks every project marker, and after
-- a sync there can be a lot of them. Set/Clear drop the cache themselves.
function UI.renderStartSet()
  local now = r.time_precise()
  if state.rsSet ~= nil and state.rsAt and now < state.rsAt + 0.25 then
    return state.rsSet
  end
  state.rsAt  = now
  -- While the marker is on the ruler it is the answer, and a marker the user
  -- deleted by hand is a "no" -- that is the whole reason this reads the ruler
  -- rather than Reaper's offset, which a project template can carry in without
  -- anybody asking. With the marker switched off there is nothing to look at,
  -- so the note we wrote when setting it stands in.
  if renderMarkerWanted() then
    state.rsSet = findRenderStartMarker() ~= nil
  else
    state.rsSet = getProjExt(K.RENDER_START_KEY) == '1'
  end
  return state.rsSet
end

function UI.mix(a, b, t)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local out = 0
  for _, shift in ipairs({ 24, 16, 8, 0 }) do
    local ca = (a >> shift) & 0xFF
    local cb = (b >> shift) & 0xFF
    out = out | (math.floor(ca + (cb - ca) * t + 0.5) << shift)
  end
  return out
end

-- What the menu holds, as data. Building the list first means its height is
-- known before the panel opens, which is what lets it be placed by hand.
function UI.menuItems()
  local it = {}
  local function add(id, label, opts, run) it[#it+1] = { id = id, label = label, opts = opts, run = run } end
  local function sep() it[#it+1] = { sep = true } end

  -- Exactly one row may be marked, and it is the screen in front of you. The
  -- picker override survives a trip into the settings, so asking it alone
  -- marked two rows at once.
  local onMain   = state.screen == 'main'
  local onPicker = onMain and (state.showPickerOverride and true or false)

  if state.token then
    add('##m_home', 'Production', { active = onMain and not onPicker }, function()
      state.screen = 'main'
      state.showPickerOverride = false
    end)
    if state.boundProductionId and not state.syncInProgress then
      add('##m_sync', 'Sync comments', nil, function() doSync() end)
    end
    add('##m_change', 'Change production', { active = onPicker }, function()
      state.showPickerOverride = true
      state.screen = 'main'
    end)
    sep()
  end
  add('##m_settings', 'Settings', { active = state.screen == 'settings' }, function()
    state.previousScreen = state.screen
    state.screen = 'settings'
  end)
  add('##m_about', 'About', { active = state.screen == 'about' }, function()
    state.previousScreen = state.screen
    state.screen = 'about'
  end)
  -- The update lives on the Dependencies page, so that entry carries the hint.
  -- Without it the feature exists and nobody notices.
  local depsLabel = 'Dependencies'
  if Upd.st().onDisk or Upd.available() then depsLabel = depsLabel .. ' - update' end
  add('##m_deps', depsLabel, { active = state.screen == 'deps' }, function()
    state.previousScreen = state.screen
    state.screen = 'deps'
  end)
  sep()
  if state.token then
    add('##m_logout', 'Log out', { dim = true }, function() logout() end)
  end
  add('##m_quit', 'Quit script', { danger = true }, function() state.running = false end)
  return it
end

-- The menu itself. Everything that moves you somewhere lives here, so the
-- screens carry their content and nothing else.
--
-- Positioned by hand under the hamburger and right-aligned with it, then
-- clamped to the window: left to itself a popup opens wherever it likes, which
-- put the panel outside the script window and over Reaper's arrange view.
function UI.mainMenu()
  if not (ImGui.BeginPopup and ImGui.EndPopup) then return end
  local items = UI.menuItems()

  -- Height 0 means "fit the content" — the panel is exactly as tall as its rows
  -- and never needs to scroll. Working the height out by hand looked right on
  -- paper and was short by ImGui's own spacing between items, which cost the
  -- last row and put a scrollbar in a seven-line menu.
  --
  -- The one thing the height is still needed for is keeping the panel inside a
  -- short window, and for that the measurement from the previous frame is both
  -- accurate and good enough: an estimate only ever stands in for the very
  -- first frame it is shown.
  local h = state.menuHeight
  if not h then
    h = 12
    for _, e in ipairs(items) do h = h + (e.sep and K.MENU_SEP or K.MENU_ROW) + 4 end
  end

  local a = state.menuAnchor
  if a and ImGui.SetNextWindowPos then
    local x = a.x1 - K.MENU_W          -- right edges line up with the button
    local y = a.y1                     -- touching it, so the tab can join them
    if a.ww > 0 then
      -- Keep it inside the window, and never push it off the left edge either.
      x = math.min(x, a.wx + a.ww - K.MENU_W - 6)
      x = math.max(x, a.wx + 6)
      if a.wh > 0 then y = math.min(y, math.max(a.wy + 6, a.wy + a.wh - h - 6)) end
    end
    ImGui.SetNextWindowPos(ctx, x, y, ImGui.Cond_Always and ImGui.Cond_Always() or 0)
  end
  ImGui.SetNextWindowSize(ctx, K.MENU_W, 0)

  local n = 0
  local function pv(id, va, vb)
    if not id then return end
    if vb then ImGui.PushStyleVar(ctx, id, va, vb) else ImGui.PushStyleVar(ctx, id, va) end
    n = n + 1
  end
  pv(ImGui.StyleVar_WindowPadding and ImGui.StyleVar_WindowPadding(), 6, 6)
  -- PopupRounding is what a popup actually uses; WindowRounding is set beside
  -- it only so the two cannot disagree if ReaImGui ever reads the other one.
  pv(ImGui.StyleVar_PopupRounding and ImGui.StyleVar_PopupRounding(), K.MENU_ROUND)
  pv(ImGui.StyleVar_WindowRounding and ImGui.StyleVar_WindowRounding(), K.MENU_ROUND)
  -- The panel outlines itself (see UI.menuOpenSeam), so ImGui should not.
  pv(ImGui.StyleVar_WindowBorderSize and ImGui.StyleVar_WindowBorderSize(), 0)
  local nc = 0
  if ImGui.Col_PopupBg then
    ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg(), K.MENU_BG); nc = nc + 1
  end
  -- ...and the window colour with it. The theme paints windows in the darker
  -- background, and a build that reads that one for popups gave the panel a
  -- different surface from the tab drawn on top of it — which is why the tab
  -- looked lighter than the menu hanging off it.
  if ImGui.Col_WindowBg then
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg(), K.MENU_BG); nc = nc + 1
  end
  -- The theme's window border is a lighter grey than the cards use. Left alone
  -- it drew the panel's outline in one colour and the tab's in another.
  if ImGui.Col_Border then
    ImGui.PushStyleColor(ctx, ImGui.Col_Border(), K.MENU_BORDER); nc = nc + 1
  end
  if ImGui.BeginPopup(ctx, 'cpmenu') then
    -- Room for the join. The patch that carries the button into the panel
    -- covers the top corner radius, so the first row has to start below that or
    -- its hover highlight runs underneath the patch and loses its top edge.
    ImGui.Dummy(ctx, 0, K.MENU_ROUND)

    -- The panel already shares its surface, border and radius with the cards.
    -- What it never got is their depth: the gradient over the top and the ring
    -- underneath. Both start K.MENU_ROUND down from the top edge, which is
    -- exactly where the join with the button ends -- run either of them across
    -- that and the two stop reading as one shape, which is the whole point of
    -- the seam and took four attempts to get right.
    --
    -- The height is last frame's, the same measurement the clamp above uses:
    -- the panel sizes itself to its rows, so this frame's height does not exist
    -- until the rows have been laid out, and by then the wash would be painting
    -- over them instead of under.
    if state.menuHeight and ImGui.GetWindowPos and ImGui.DrawList_AddRectFilledMultiColor then
      local px, py = ImGui.GetWindowPos(ctx)
      local dl     = ImGui.GetWindowDrawList(ctx)
      -- Square, not rounded: below the radius the sides are straight, so there
      -- are no corners for the gradient call (which cannot round) to square off.
      --
      -- What makes this soft is the *room*, not the curve. washTop is ten steps
      -- of alpha; the first attempt put all ten into twelve pixels, which is
      -- nearly a step per pixel and reads as a ladder however it is shaped.
      -- Spread over a quarter of the panel the same ten steps are one every
      -- five pixels, which is a gradient.
      --
      -- The curve is smoothstep, flat at both ends and at the peak, so there is
      -- no change of slope anywhere for the eye to read as a line. Measured, it
      -- makes no visible difference at this alpha depth: sampled at ten points
      -- it and a straight ramp round to the same numbers but for one step in
      -- two bands. It is kept because it costs one expression and would matter
      -- the moment washTop is raised -- not because it is doing the work today.
      --
      -- The window and the cards need none of this: theirs starts under a
      -- rounded cap at the very top edge, where a gradient may begin at full
      -- strength because there is nothing above it to step away from. This one
      -- has to begin in the middle of a flat surface -- the top belongs to the
      -- join.
      local top  = py + K.MENU_ROUND
      local bot  = py + state.menuHeight * K.MENU_WASH_TO
      local segs = K.MENU_WASH_SEG
      -- Bands under ~3px are not a gradient any more, they are a stack of
      -- lines; a menu that short simply goes without.
      if bot - top >= segs * 3 then
        local rgb  = CP_COLORS.washTop & 0xFFFFFF00
        local peak = CP_COLORS.washTop & 0xFF
        local p    = K.MENU_WASH_PEAK
        local function at(t)
          local u = (t <= p) and (t / p) or (1 - (t - p) / (1 - p))
          if u < 0 then u = 0 elseif u > 1 then u = 1 end
          return rgb | math.floor(peak * (u * u * (3 - 2 * u)) + 0.5)
        end
        for i = 0, segs - 1 do
          local t0, t1 = i / segs, (i + 1) / segs
          local c0, c1 = at(t0), at(t1)
          ImGui.DrawList_AddRectFilledMultiColor(dl,
            px, top + (bot - top) * t0, px + K.MENU_W, top + (bot - top) * t1,
            c0, c0, c1, c1)
        end
      end
    end

    local close = false
    for _, e in ipairs(items) do
      if e.sep then
        UI.menuSep()
      elseif UI.menuItem(e.id, e.label, e.opts) then
        e.run()
        close = true
      end
    end
    -- What it actually came out at, for next frame's clamp and wash.
    if ImGui.GetWindowSize then
      local _, hh = ImGui.GetWindowSize(ctx)
      if hh and hh > 0 then
        state.menuHeight = hh
        -- The ring, with this frame's real height. It lives outside the panel,
        -- so it can be drawn after the rows without covering anything -- and it
        -- has to be, because until the rows are laid out there is no height to
        -- draw it around. Its top starts below the join, so the button and the
        -- panel keep one unbroken edge between them.
        local px, py = ImGui.GetWindowPos(ctx)
        -- The whole panel, not from the radius down: in `outside` mode the ring
        -- never crosses the top edge anyway, so starting it lower only left the
        -- panel's upper corners standing against the header with no shadow.
        if px then UI.shadow(px, py, px + K.MENU_W, py + hh, nil, nil, true) end
      end
    end
    -- Last, so it covers the panel's own border where the button meets it.
    UI.menuOpenSeam()
    if close and ImGui.CloseCurrentPopup then ImGui.CloseCurrentPopup(ctx) end
    ImGui.EndPopup(ctx)
  end
  if nc > 0 then ImGui.PopStyleColor(ctx, nc) end
  if n  > 0 then ImGui.PopStyleVar(ctx, n) end
end

function UI.pushTheme()
  local function v_(id) return ImGui['StyleVar_' .. id] and ImGui['StyleVar_' .. id]() or nil end
  local function c_(id) return ImGui['Col_' .. id]      and ImGui['Col_' .. id]()      or nil end
  local sv, sc = 0, 0
  local function pushVar(id, a, b)
    if id == nil then return end
    if b then ImGui.PushStyleVar(ctx, id, a, b) else ImGui.PushStyleVar(ctx, id, a) end
    sv = sv + 1
  end
  local function pushCol(id, col)
    if id == nil then return end
    ImGui.PushStyleColor(ctx, id, col); sc = sc + 1
  end

  pushVar(v_('WindowRounding'),     8)
  pushVar(v_('WindowPadding'),      K.WINDOW_PAD_X, 10)
  pushVar(v_('WindowBorderSize'),   1)
  pushVar(v_('FramePadding'),       7, 4)
  pushVar(v_('FrameRounding'),      5)
  pushVar(v_('ItemSpacing'),        6, 5)
  pushVar(v_('ItemInnerSpacing'),   6, 4)
  pushVar(v_('ScrollbarRounding'),  5)
  -- The body keeps its scrollbar on at all times so content never shifts. That
  -- only works visually if the bar is unobtrusive: no track, a dim grab.
  pushVar(v_('ScrollbarSize'),      K.SCROLLBAR_W)
  pushVar(v_('GrabRounding'),       4)
  pushVar(v_('PopupRounding'),      6)

  pushCol(c_('WindowBg'),           CP_COLORS.bg)
  pushCol(c_('PopupBg'),            CP_COLORS.bg)
  pushCol(c_('TitleBg'),            CP_COLORS.bg)
  pushCol(c_('TitleBgActive'),      CP_COLORS.bg)
  pushCol(c_('TitleBgCollapsed'),   CP_COLORS.bg)
  pushCol(c_('MenuBarBg'),          CP_COLORS.bg)
  pushCol(c_('Border'),             CP_COLORS.border)
  pushCol(c_('Text'),               CP_COLORS.text)
  pushCol(c_('TextDisabled'),       CP_COLORS.textDim)
  pushCol(c_('Separator'),          CP_COLORS.border)
  pushCol(c_('ScrollbarBg'),        0x00000000)
  pushCol(c_('ScrollbarGrab'),      CP_COLORS.rowSep)
  pushCol(c_('ScrollbarGrabHovered'), CP_COLORS.hover)
  pushCol(c_('ScrollbarGrabActive'),  CP_COLORS.active)

  -- Buttons
  pushCol(c_('Button'),             CP_COLORS.hover)
  pushCol(c_('ButtonHovered'),      CP_COLORS.accentStrong)
  pushCol(c_('ButtonActive'),       CP_COLORS.accent)

  -- Selectables (menu rows)
  pushCol(c_('Header'),             0x00000000)
  pushCol(c_('HeaderHovered'),      CP_COLORS.hover)
  pushCol(c_('HeaderActive'),       CP_COLORS.active)

  -- Inputs
  pushCol(c_('FrameBg'),            0x2C2C34FF)
  pushCol(c_('FrameBgHovered'),     0x36363EFF)
  pushCol(c_('FrameBgActive'),      0x3B3B44FF)

  -- Checkboxes
  pushCol(c_('CheckMark'),          CP_COLORS.accent)

  -- Scrollbars
  pushCol(c_('ScrollbarBg'),        0x1D1D20FF)
  pushCol(c_('ScrollbarGrab'),      0x3A3A3DFF)
  pushCol(c_('ScrollbarGrabHovered'), 0x4A4A4DFF)
  pushCol(c_('ScrollbarGrabActive'), 0x5A5A5DFF)

  return sc, sv
end

function UI.popTheme(sc, sv)
  if sc and sc > 0 then ImGui.PopStyleColor(ctx, sc) end
  if sv and sv > 0 then ImGui.PopStyleVar(ctx, sv) end
end

-- Window flags shared by all our windows: non-dockable, so the user can
-- position these anywhere without them snapping into Reaper's dock zones.
function UI.windowFlags(extra)
  local f = extra or 0
  local nd = ImGui.WindowFlags_NoDocking and ImGui.WindowFlags_NoDocking() or 0
  return f | nd
end

-- Text with a shadow under it. ImGui has no such thing, so the glyphs are
-- drawn twice: once offset and dark straight into the draw list, then the real
-- text on top through ImGui.Text, which is what keeps the layout measuring it.
--
-- nil font and 0 size mean "whatever is pushed right now", so the shadow can
-- never end up in a different face or size than the text it belongs to.
function UI.shadowText(text, col)
  if ImGui.DrawList_AddTextEx then
    local x, y = ImGui.GetCursorScreenPos(ctx)
    ImGui.DrawList_AddTextEx(ImGui.GetWindowDrawList(ctx), nil, 0,
      x + K.BRAND_SHADOW_DX, y + K.BRAND_SHADOW_DY, CP_COLORS.brandShadow, text)
  end
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), col)
  ImGui.Text(ctx, text)
  ImGui.PopStyleColor(ctx)
end

-- The comment list, in a column of its own on the left. Same surface as every
-- other card, its own shadow, and the row under the mouse in the waveform lit
-- up here at the same time -- the strip records which comment it is over, this
-- reads it back.
--
-- Rows are drawn by hand rather than with Selectable: a comment is a timestamp
-- over an author over wrapped text, which is three items with one hit area
-- around them, and Selectable only does one line.
-- A well: a card-sized region that reads as sunk into the surface rather than
-- laid on it. Used for the two long lists -- the comments and the production
-- picker -- so they cannot drift apart the next time either is touched.
--
-- Its base is deliberately *below* `card`, and the gradient lifts only the top
-- edge back over that: painting the window's own wash on `card` instead is what
-- once made the comment column the single bright panel on the screen. Over the
-- full height rather than the window's top 55%, because a region this tall
-- would otherwise stop washing halfway down and read as two surfaces.
function UI.wellBegin(id, w, h)
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg(), CP_COLORS.listBase)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border(),  CP_COLORS.cardBorder)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ChildRounding(), 8)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding(), 10, 9)
  local f = 0
  if ImGui.ChildFlags_Borders    then f = f | ImGui.ChildFlags_Borders()
  elseif ImGui.ChildFlags_Border then f = f | ImGui.ChildFlags_Border() end
  local card = { open = ImGui.BeginChild(ctx, id, w, h, f) }
  -- Before anything else in the child, so every row lands on top of it.
  if card.open then UI.wash(CP_COLORS.listWash, 1.0) end
  return card
end

function UI.wellEnd(card)
  if not card then return end
  -- ReaImGui already calls EndChild itself when BeginChild returned false.
  if card.open then ImGui.EndChild(ctx) end
  ImGui.PopStyleVar(ctx, 2)
  ImGui.PopStyleColor(ctx, 2)
  -- After the child, in the parent's list: a child composites afterwards, so a
  -- shadow issued from inside would end up on top of its own contents.
  if card.open then
    local ax, ay = ImGui.GetItemRectMin(ctx)
    local bx, by = ImGui.GetItemRectMax(ctx)
    UI.shadow(ax, ay, bx, by)
  end
end

-- Is the production picker what the main screen is showing? Asked in two
-- places -- here, where it is drawn, and one level up, where the comment column
-- decides whether it belongs on screen at all. One expression for both, because
-- two copies of this would drift and the column would then be beside a screen
-- it has nothing to do with.
--
-- Safe to ask before the body renders: all three inputs are set by the header
-- (the menu) or by the binding, never by the body itself.
function UI.showingPicker()
  return (not state.boundProductionId) or state.showPickerOverride
      or (not state.boundProduction) or false
end

-- One name for a comment, used by both the list and the strip. Cached rows
-- written by older versions of the script can be missing an id; the index is
-- the fallback, and it matches because both sides walk the same array in the
-- same order. Computed in one place so the two can never drift apart -- if they
-- did, hovering would light the wrong comment, which is worse than lighting
-- none.
function UI.commentKey(c, i)
  local id = c and c.id
  if id ~= nil and id ~= '' then return 'id:' .. tostring(id) end
  return 'ix:' .. tostring(i)
end

-- Group a cached comment list into threads, keeping every comment's index in
-- the flat array: that index is half of UI.commentKey, and the waveform strip
-- keys its pins off the same array, so a row and its pin have to agree on it.
--
-- A reply whose parent is not in the list (the parent was deleted in CuePort,
-- or it belongs to another version) is shown as a thread of its own rather than
-- dropped -- someone wrote it, and swallowing it would be the same mistake the
-- artist-only filter made.
-- The comment column's status line. Every setter goes through here so that
-- "when was this said" is recorded in one place rather than at six call sites,
-- and so `hold` is a decision someone made rather than a field someone forgot.
function UI.setStatus(text, hold)
  state.replyStatus     = text
  state.replyStatusAt   = r.time_precise()
  state.replyStatusHold = hold and true or false
end

-- What to draw beside the heading, or nil. Clears the line once it is stale,
-- which is why this is a function and not an `if` in the middle of the render:
-- the rule is the thing worth checking.
function UI.statusText()
  local t = state.replyStatus
  if not t or t == '' then return nil end
  if state.replyStatusHold then return t end
  if (r.time_precise() - (state.replyStatusAt or 0)) > K.STATUS_SECS then
    state.replyStatus = nil
    return nil
  end
  return t
end

function UI.commentThreads(comments)
  local byId, threads = {}, {}
  for _, c in ipairs(comments) do
    if c.id ~= nil then byId[tostring(c.id)] = true end
  end
  for i, c in ipairs(comments) do
    local pid = c.parent_id and tostring(c.parent_id) or nil
    if pid and byId[pid] then
      local t = threads[pid]
      if t then t.replies[#t.replies+1] = { c = c, i = i } end
    else
      local t = { c = c, i = i, replies = {} }
      threads[#threads+1] = t
      if c.id ~= nil then threads[tostring(c.id)] = t end
    end
  end
  return threads
end

-- One comment's header line: time, author, and who they are. The studio's own
-- name is marked, because on a shared timeline "Ann" and "Ann from the studio"
-- are different people to the person reading it.
-- The three colours a comment is drawn in: lit, resting dot, resting stem.
-- One function so a pin and its row in the list can never disagree about who
-- wrote the thing they both stand for. A row from an older cache has no
-- `is_studio` at all -- artist is the right guess there, it is who opens a
-- thread nearly every time.
function UI.commentTint(c)
  if c and c.is_studio == 1 then
    return CP_COLORS.accent, CP_COLORS.accentStrong, CP_COLORS.studioStem
  end
  return CP_COLORS.artist, CP_COLORS.artistStrong, CP_COLORS.artistStem
end

function UI.commentHead(c, lit)
  local stamp = c.timestamp and formatTimestamp(c.timestamp) or '\u{2014}'
  ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
  -- Only the timestamp is tinted, not the whole line: it is the part that also
  -- exists out on the waveform as a pin, so colouring it is what ties the two
  -- together. The name beside it stays quiet, the way it always was.
  local tint = UI.commentTint(c)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), tint)
  ImGui.Text(ctx, stamp)
  ImGui.PopStyleColor(ctx)
  ImGui.SameLine(ctx, 0, 0)
  local who = c.author or 'Artist'
  if c.is_studio == 1 then who = who .. ' \u{b7} studio' end
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), lit and CP_COLORS.accent or CP_COLORS.textDim)
  ImGui.Text(ctx, '  \u{b7}  ' .. who)
  ImGui.PopStyleColor(ctx)
  ImGui.PopFont(ctx)
end

-- The box under a comment. Enter sends, as it does everywhere else a single
-- line is typed; the buttons are there because a keyboard shortcut nobody is
-- told about is not a control.
function UI.replyBox(key)
  ImGui.Dummy(ctx, 0, 3)
  ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
  local availW = ImGui.GetContentRegionAvail(ctx)
  ImGui.SetNextItemWidth(ctx, math.max(60, availW))
  -- Deliberately WITHOUT InputTextFlags_EnterReturnsTrue.
  --
  -- That flag was the whole of "Send does nothing, Enter works". With it the
  -- widget reports only on Enter -- and, reported twice from real use, the
  -- buffer does not come back while typing either. So `state.replyText` was
  -- still empty when Send was pressed, and Enter worked because Enter is the
  -- one moment the value arrives. My first fix (take the buffer every frame)
  -- assumed the buffer always comes back and only the report is withheld; the
  -- harness modelled that same assumption, so it agreed with me instead of
  -- checking me. Without the flag this is the ordinary path: the value comes
  -- back on every keystroke, which is not conditional on anything.
  -- Straight into the field, so you can start typing without a second click.
  -- Before the item, because that is what the call points at; and only once,
  -- see state.replyFocus.
  if state.replyFocus and ImGui.SetKeyboardFocusHere then
    ImGui.SetKeyboardFocusHere(ctx)
    state.replyFocus = false
  end
  local _, val = ImGui.InputTextWithHint(ctx, '##cpreply', 'Write a reply...', state.replyText or '')
  if type(val) == 'string' then state.replyText = val end
  -- Enter, detected on its own now: the field was left after an edit AND the
  -- key went down in this frame. Leaving it by clicking somewhere else
  -- deactivates it too, so without the key check a click on the waveform would
  -- send the half-typed reply.
  local send = false
  if ImGui.IsItemDeactivatedAfterEdit and ImGui.IsItemDeactivatedAfterEdit(ctx)
     and ImGui.IsKeyPressed then
    local hit = (ImGui.Key_Enter and ImGui.IsKeyPressed(ctx, ImGui.Key_Enter()))
             or (ImGui.Key_KeypadEnter and ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter()))
    if hit then send = true end
  end
  local sendW = math.max(52, math.min(70, (availW - 8) / 2))
  if ImGui.Button(ctx, 'Send##cpreplysend', sendW, K.BTN_H) then send = true end
  ImGui.SameLine(ctx, 0, 8)
  if ImGui.Button(ctx, 'Cancel##cpreplycancel', sendW, K.BTN_H) then
    state.replyTo, state.replyText = nil, ''
  end
  if send then
    local txt = (state.replyText or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if txt ~= '' then
      -- Queued, not sent: the request blocks for as long as curl takes, and
      -- doing that inside the click would freeze the frame it happened in.
      state.replyPending = { parent_id = key, text = txt }
      UI.setStatus('Sending...')
      state.replyTo, state.replyText = nil, ''
    end
  end
  ImGui.PopFont(ctx)
end

-- Send whatever the reply box queued. Out here rather than in the loop for the
-- same reason the two marker switches are: what happens when a control is used
-- is the part worth pinning down, and a body inside the loop can only be
-- checked by rebuilding it in the harness -- which then checks the rebuild.
function UI.flushReply()
  local pend = state.replyPending
  if not pend then return end
  state.replyPending = nil
  local resp, err = apiPostComment(state.boundProductionId, state.versionId,
                                   pend.parent_id, pend.text)
  if err == 'unauthorized' then
    state.errorMsg = 'Token is no longer valid - please reconnect.'
    logout()
    return
  end
  if err or not resp or not resp.ok then
    -- The text is not thrown away: it goes back into the box so the user can
    -- try again rather than retype it.
    UI.setStatus('Reply failed: ' .. (err or (resp and resp.error) or 'Unknown'), true)
    state.replyTo, state.replyText = pend.parent_id, pend.text
    state.replyFocus = true
    return
  end
  -- Sent is not the same as on screen: the reply only really exists once the
  -- server has given it an id, and that is what the next sync brings back.
  UI.setStatus('Reply sent.')
  state.syncRequested = true
end

-- Send the delete the control queued. Out here for the same reason as
-- UI.flushReply: what happens when a control is used is the part worth pinning
-- down, and a body inside the loop can only be checked by rebuilding it.
function UI.flushDelete()
  local pend = state.delPending
  if not pend then return end
  state.delPending = nil
  local resp, err = apiDeleteComment(pend.id)
  if err == 'unauthorized' then
    state.errorMsg = 'Token is no longer valid - please reconnect.'
    logout()
    return
  end
  if err or not resp or not resp.ok then
    UI.setStatus('Delete failed: ' .. (err or (resp and resp.error) or 'Unknown'), true)
    return
  end
  -- Gone on the server; the list here still shows it. Fetched again rather than
  -- removed locally, so the column and the markers say what the server says.
  UI.setStatus('Reply deleted.')
  state.syncRequested = true
end

function UI.commentList(w, h)
  local comments = loadCommentsCache()
  local threads  = UI.commentThreads(comments)
  local card = UI.wellBegin('cpcomments', w, h)
  if card.open then
    ImGui.PushFont(ctx, FONT_BOLD, K.FONT_SMALL)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.sectionText)
    ImGui.Text(ctx, 'COMMENTS')
    ImGui.PopStyleColor(ctx)
    ImGui.PopFont(ctx)
    -- The status beside the heading rather than under it: it is a receipt, and
    -- a line of its own pushed the whole conversation down every time one was
    -- issued. Clipped rather than wrapped -- wrapping would put back exactly
    -- the extra line this is meant to avoid, and the column is 210 px wide.
    local statusNow = UI.statusText()
    if statusNow then
      ImGui.SameLine(ctx, 0, 8)
      local sx, sy = ImGui.GetCursorScreenPos(ctx)
      local room   = ImGui.GetContentRegionAvail(ctx)
      ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
      local dl = ImGui.GetWindowDrawList(ctx)
      if ImGui.DrawList_PushClipRect then
        ImGui.DrawList_PushClipRect(dl, sx, sy - 2, sx + math.max(0, room), sy + 20, true)
      end
      ImGui.DrawList_AddText(dl, sx, sy, CP_COLORS.textDim, statusNow)
      if ImGui.DrawList_PopClipRect then ImGui.DrawList_PopClipRect(dl) end
      ImGui.PopFont(ctx)
      ImGui.NewLine(ctx)
    end
    ImGui.Dummy(ctx, 0, 4)

    if #threads == 0 then
      ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
      if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 0) end
      ImGui.TextDisabled(ctx, 'No comments on this version yet.')
      if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
      ImGui.PopFont(ctx)
    end

    -- Where each row ended up last frame. A row is a timestamp line over
    -- wrapped text -- three items whose height nobody knows before they are
    -- laid out -- so hover has to be measured against the rectangle they
    -- occupied, and that rectangle only exists after the fact. Laying an
    -- InvisibleButton over them instead would either push the layout down or
    -- swallow their own hover. One frame late is not visible.
    -- Hovering a pin out on the waveform brings its comment into view. Only
    -- when the pin CHANGES: scrolling every frame the mouse rests on it would
    -- fight anyone trying to scroll the column by hand. Cleared when the mouse
    -- leaves the strip, so coming back to the same pin scrolls again.
    if state.hoverCommentId == nil then state.cmtScrollTo = nil end
    state.cmtRects = state.cmtRects or {}
    local rects    = state.cmtRects
    -- Where this row's controls sat last frame, so the seek guard above can ask
    -- instead of guess. Same one-frame-late trick as `rects` itself.
    state.cmtCtl   = state.cmtCtl or {}
    local ctls     = state.cmtCtl
    local overList = (ImGui.IsWindowHovered and ImGui.IsWindowHovered(ctx)) or false
    local clickNow = (ImGui.IsMouseClicked and ImGui.IsMouseClicked(ctx, 0)) or false

    for _, th in ipairs(threads) do
      local c, i = th.c, th.i
      local x0, y0 = ImGui.GetCursorScreenPos(ctx)
      local availR = ImGui.GetContentRegionAvail(ctx)
      -- Lit either because the mouse is over the pin out in the waveform, or
      -- because it is over this row.
      local key = UI.commentKey(c, i)
      local lit = (state.hoverCommentId ~= nil and key == state.hoverCommentId)
      -- Filled while the row draws, handed to `ctls` at the end of it.
      local rowCtl = {}
      -- One entry per answer: its id and the y it started at, so its delete
      -- control can be submitted after the group instead of inside it.
      local repRows = {}
      local rc  = rects[i]
      local onRow = overList and rc and ImGui.IsMouseHoveringRect
        and ImGui.IsMouseHoveringRect(ctx, rc[1], rc[2], rc[3], rc[4]) or false
      if onRow then
        lit = true
        -- The other direction: tell the strip which pin to light. Read there
        -- later in this same frame.
        state.hoverRowCommentId = key
        -- Only a comment that has a time can be jumped to. One without is a
        -- note about the version as a whole; a click that silently moved the
        -- cursor to 0:00 would be worse than a click that does nothing.
        -- Not on the controls: a click there is a click on a control, not on
        -- the comment, and it must not also move the cursor. Measured rather
        -- than recomputed -- the controls sit in several places now (Reply on
        -- the head, a delete on every reply) and an armed one is wider than a
        -- resting one, so a rectangle worked out here would have to predict all
        -- of that. What they actually occupied last frame cannot be wrong about
        -- it. One frame late is not visible: they do not move.
        local onCtl = false
        for _, cr in ipairs(ctls[i] or {}) do
          if ImGui.IsMouseHoveringRect
             and ImGui.IsMouseHoveringRect(ctx, cr[1], cr[2], cr[3], cr[4]) then
            onCtl = true
          end
        end
        if clickNow and not onCtl and c.timestamp then
          -- The same conversion the waveform strip does: the timestamps are
          -- times in the audio, and the ruler may be shifted under them.
          r.SetEditCurPos(c.timestamp - getProjectStartOffset(), true, true)
        end
      end
      ImGui.PushID(ctx, 'cmt' .. tostring(i))
      ImGui.BeginGroup(ctx)
      UI.commentHead(c, lit)
      if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 0) end
      ImGui.PushStyleColor(ctx, ImGui.Col_Text(),
        lit and CP_COLORS.text or CP_COLORS.textDim)
      ImGui.Text(ctx, c.text or '')
      ImGui.PopStyleColor(ctx)
      if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
      -- The answers, indented under the comment they belong to and behind a
      -- rule, so a thread reads as one block rather than as more comments.
      for _, rp in ipairs(th.replies) do
        ImGui.Dummy(ctx, 0, 3)
        ImGui.Indent(ctx, 10)
        local rx, ry = ImGui.GetCursorScreenPos(ctx)
        ImGui.BeginGroup(ctx)
        UI.commentHead(rp.c, false)
        if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 0) end
        ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.textDim)
        ImGui.Text(ctx, rp.c.text or '')
        ImGui.PopStyleColor(ctx)
        if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
        ImGui.EndGroup(ctx)
        local _, ry1 = ImGui.GetItemRectMax(ctx)
        ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx),
          rx - 7, ry, rx - 6, ry1, CP_COLORS.rowSep)
        -- Where this answer began, for the delete control. Only remembered
        -- here -- submitting it inside the group is what raised
        -- "Code uses SetCursorScreenPos() to extend window/parent boundaries"
        -- out of EndGroup: moving the cursor to the far right and putting it
        -- back without an item in between leaves the group with a boundary it
        -- was never told to grow into. The head's Reply control has always sat
        -- outside the group for the same reason; this one now does too.
        if rp.c.id ~= nil then
          repRows[#repRows+1] = { id = tostring(rp.c.id), y = ry }
        end
        ImGui.Unindent(ctx, 10)
      end
      ImGui.EndGroup(ctx)
      -- After the group, so the scroll is aimed at the whole row rather than at
      -- whichever line was drawn last. hoverCommentId is the strip's answer and
      -- nothing else -- a row lit because the mouse is ON it must not scroll
      -- itself out from under that mouse.
      if state.hoverCommentId ~= nil and key == state.hoverCommentId
         and state.cmtScrollTo ~= key then
        state.cmtScrollTo = key
        -- A third of the way down rather than dead centre: the row above is
        -- usually the one before it in time, and seeing it is worth more than
        -- symmetry.
        if ImGui.SetScrollHereY then ImGui.SetScrollHereY(ctx, 0.35) end
      end
      local _, y1 = ImGui.GetItemRectMax(ctx)
      -- Painted after the group, so it lands on top of the text: the fill is
      -- a wash at low alpha, not a block, and the bar is what actually reads
      -- from the corner of the eye.
      if lit and availR and availR > 0 then
        local dl = ImGui.GetWindowDrawList(ctx)
        ImGui.DrawList_AddRectFilled(dl, x0 - 5, y0 - 3, x0 + availR, y1 + 3,
                                     CP_COLORS.commentLit, 5)
        ImGui.DrawList_AddRectFilled(dl, x0 - 5, y0 - 3, x0 - 3, y1 + 3,
                                     CP_COLORS.accent, 1)
      end
      -- Replying needs a comment to reply to, so the control lives on the row.
      -- In its top-right CORNER, painted over the row rather than added under
      -- it: a control that appears below the text pushes every comment after it
      -- down the moment the mouse arrives, and the list jumps under the pointer.
      -- Drawn only while the row is lit, because sitting there permanently it
      -- would cover the end of the header line.
      --
      -- The hit area, though, is submitted ALWAYS. This is the whole of the
      -- "pressing Reply does nothing" bug: ImGui's IsWindowHovered answers false
      -- while an item is being held down (that is what
      -- HoveredFlags_AllowWhenBlockedByActiveItem exists for), so the row went
      -- un-lit between press and release, the button was not submitted on the
      -- next frame, and ImGui cancelled the click it had already started. An
      -- item that is always there cannot be taken away mid-click.
      local cid = c.id and tostring(c.id) or nil
      if cid and state.replyTo ~= cid and not state.replyPending
         and availR and availR > 0 then
        local rx, ry = x0 + availR - K.REPLY_W, y0 - 2
        local cx, cy = ImGui.GetCursorScreenPos(ctx)
        ImGui.SetCursorScreenPos(ctx, rx, ry)
        local hitR = ImGui.InvisibleButton(ctx, '##cprep', K.REPLY_W, K.REPLY_H)
        local hovR = ImGui.IsItemHovered(ctx)
        if lit or hovR then
          ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
          UI.pillPaint(ImGui.GetWindowDrawList(ctx), rx, ry, K.REPLY_W, K.REPLY_H,
                       'Reply', false, hovR)
          ImGui.PopFont(ctx)
        end
        -- Back where the row was, so none of this moved the layout.
        ImGui.SetCursorScreenPos(ctx, cx, cy)
        rowCtl[#rowCtl+1] = { rx, ry, rx + K.REPLY_W, ry + K.REPLY_H }
        if hitR then
          state.replyTo, state.replyText = cid, ''
          state.replyFocus  = true
          state.replyStatus = nil
          -- Reaching for Reply is not an answer to "Sure?", so it takes the
          -- question away rather than leaving it primed on the row.
          state.delArm = nil
        end
      end
      -- Removing an answer, on the answer itself: it belongs there and not on
      -- the head of the thread, which is usually the artist's remark and would
      -- take the whole conversation with it. Submitted out here, after the
      -- group, for the reason spelled out where the rows were collected.
      --
      -- Two presses, not one -- this is the only action in the script that
      -- cannot be undone, on a control that appears under the mouse rather than
      -- being aimed at. And as with Reply, the hit area is submitted whatever
      -- the row is doing: ImGui reports a window as un-hovered while an item is
      -- held, so a control that exists only while the row is lit loses its own
      -- click halfway through.
      if availR and availR > 0 and not state.delPending then
        for _, rr in ipairs(repRows) do
          local armed = (state.delArm == rr.id)
          local dw = armed and K.DEL_ARM_W or K.DEL_W
          local dx = x0 + availR - dw
          local cx2, cy2 = ImGui.GetCursorScreenPos(ctx)
          ImGui.SetCursorScreenPos(ctx, dx, rr.y - 2)
          -- One scope per answer. The PushID further up is per THREAD, so with
          -- two answers both controls were the same item to ImGui -- which says
          -- so, loudly, the moment the mouse touches one: "2 visible items with
          -- conflicting ID". The label stays '##cpdel'; the id it resolves to
          -- does not.
          ImGui.PushID(ctx, rr.id)
          local hitD = ImGui.InvisibleButton(ctx, '##cpdel', dw, K.REPLY_H)
          local hovD = ImGui.IsItemHovered(ctx)
          ImGui.PopID(ctx)
          if hovD and not armed and ImGui.SetTooltip then
            ImGui.SetTooltip(ctx, 'Delete this reply')
          end
          -- An armed control stays visible even off the row: it is a question
          -- waiting for an answer, and a question that vanishes when you look
          -- away has not been answered, it has been lost.
          if lit or hovD or armed then
            local dl = ImGui.GetWindowDrawList(ctx)
            ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
            if armed then
              ImGui.DrawList_AddRectFilled(dl, dx, rr.y - 2, dx + dw,
                                           rr.y - 2 + K.REPLY_H,
                                           CP_COLORS.danger, K.REPLY_H / 2)
              local qw, qh = ImGui.CalcTextSize(ctx, 'Sure?')
              ImGui.DrawList_AddText(dl, dx + (dw - qw) / 2,
                                     rr.y - 2 + (K.REPLY_H - qh) / 2,
                                     0xFFFFFFFF, 'Sure?')
            else
              UI.pillPaint(dl, dx, rr.y - 2, dw, K.REPLY_H, '\u{d7}', false, hovD)
            end
            ImGui.PopFont(ctx)
          end
          ImGui.SetCursorScreenPos(ctx, cx2, cy2)
          rowCtl[#rowCtl+1] = { dx, rr.y - 2, dx + dw, rr.y - 2 + K.REPLY_H }
          if hitD then
            if armed then
              -- Queued, not sent: the request blocks for as long as curl takes.
              state.delPending  = { id = rr.id }
              UI.setStatus('Deleting...')
              state.delArm      = nil
            else
              state.delArm      = rr.id
              state.replyStatus = nil
            end
          end
        end
      end
      if cid and state.replyTo == cid then UI.replyBox(cid) end
      ImGui.PopID(ctx)
      -- The rectangle the row is lit by and tested against. The Reply control
      -- sits inside it (its corner), so nothing has to be added for it; the
      -- reply box, when open, is below it on purpose -- a click into the box is
      -- not a click on the comment.
      if availR and availR > 0 then
        rects[i] = { x0 - 5, y0 - 3, x0 + availR, y1 + 3 }
      end
      ctls[i] = rowCtl
      ImGui.Dummy(ctx, 0, 7)
    end
  end
  UI.wellEnd(card)
end

-- Loudness and dynamics of the active version, in the top-right corner of the
-- production card. CuePort measures these in the browser when a mix is
-- uploaded; the script only reads them.
--
-- Painted straight into the draw list at the cursor's own line, deliberately
-- without touching the layout: the artist and title beside it are ordinary
-- items and would otherwise have to be sized around this, which turns a corner
-- of spare room into a column that every future change has to respect.
--
-- Nothing at all when the values are missing. That is not an error state --
-- older versions were uploaded before CuePort analysed anything -- so it says
-- nothing rather than explaining an absence.
-- `inset` keeps the right edge of the numbers clear of whatever else sits in the
-- corner -- the cover tile, since v1.22.0.
-- Returns the width the numbers actually occupy, so callers can keep text clear
-- of them instead of guessing a constant that drifts with the font size.
function UI.metricsCorner(inset)
  local m = state.metrics
  if type(m) ~= 'table' then return 0 end
  local rows = {}
  local function add(val, unit, fmt)
    if type(val) ~= 'number' then return end
    rows[#rows+1] = { v = string.format(fmt or '%.1f', val), u = unit }
  end
  add(m.lufs_integrated, 'LUFS')
  add(m.true_peak_db,    'dBTP')
  add(m.dr,              'DR', '%d')
  if #rows == 0 then return 0 end

  local x, y   = ImGui.GetCursorScreenPos(ctx)
  local avail  = ImGui.GetContentRegionAvail(ctx)
  local right  = x + avail - (inset or 0)
  local dl     = ImGui.GetWindowDrawList(ctx)
  ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
  local _, lh = ImGui.CalcTextSize(ctx, 'X')
  local step  = lh + 3
  local widest = 0
  for i, row in ipairs(rows) do
    -- Value and unit measured separately so the unit can be dimmer without
    -- the pair drifting apart, and the whole line ends on the same right edge.
    local uw = ImGui.CalcTextSize(ctx, ' ' .. row.u)
    local vw = ImGui.CalcTextSize(ctx, row.v)
    local ly = y + (i - 1) * step
    ImGui.DrawList_AddText(dl, right - uw - vw, ly, CP_COLORS.text, row.v)
    ImGui.DrawList_AddText(dl, right - uw, ly, CP_COLORS.textDim, ' ' .. row.u)
    if uw + vw > widest then widest = uw + vw end
  end
  ImGui.PopFont(ctx)
  return widest
end

-- Draw the CuePort logo + wordmark at the top of a window. Uses the PNG when
-- available, falls back to a simple styled dot + text.
function UI.brand()
  -- Where the header row really begins. Kept because the brand is about to be
  -- pushed below it and the controls on the right have to come back here:
  -- SameLine returns to wherever the line currently starts, which after the
  -- offset is the lowered brand -- so they would quietly follow it down.
  local topY = ImGui.GetCursorPosY(ctx)
  ImGui.SetCursorPosY(ctx, topY + K.BRAND_DROP)
  local img = UI.logoImage()
  if img and r.ImGui_Image then
    -- A soft light behind the mark, from the same texture the shadows use.
    -- Drawn before the image so it stays behind it.
    local gx, gy = ImGui.GetCursorScreenPos(ctx)
    local d = K.BRAND_LOGO
    UI.glow(gx - d * 0.5, gy - d * 0.5, d * 2, d * 2, CP_COLORS.brandGlow)
    pcall(r.ImGui_Image, ctx, img, d, d)
    ImGui.SameLine(ctx)
  else
    ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
    ImGui.Text(ctx, '●')
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
  end
  ImGui.PushFont(ctx, FONT_BOLD, K.FONT_BRAND)
  UI.shadowText('CuePort', CP_COLORS.accent)
  ImGui.SameLine(ctx, 0, 6)
  UI.shadowText('Sync', CP_COLORS.textDim)
  local _, brandH = ImGui.CalcTextSize(ctx, 'Sync')
  ImGui.PopFont(ctx)

  -- The update signpost, right behind the wordmark and on its line. Plain text
  -- and a small button, no box. It is the first thing to go when the window
  -- narrows: the badge, the menu and the close box all outrank it, so its own
  -- width has to be weighed against theirs before a pixel of it is committed.
  do
    local updLabel = UI.updateHeaderLabel()
    if updLabel then
      ImGui.PushFont(ctx, FONT, K.FONT_BADGE)
      local lw, lh = ImGui.CalcTextSize(ctx, updLabel)
      local updW = lw + 8 + ImGui.CalcTextSize(ctx, 'Open') + 16
      ImGui.PopFont(ctx)
      local rightW = UI.badgeHeight() * 2 + 12
                     + (state.token and (UI.badgeWidth(
                          (state.apiUrl ~= K.API_URL) and 'PREVIEW' or 'CONNECTED') + 10) or 0)
      ImGui.SameLine(ctx, 0, 16)
      local room = ImGui.GetWindowWidth(ctx) - K.WINDOW_PAD_X
                   - ImGui.GetCursorPosX(ctx) - rightW
      if room >= updW then
        -- On the wordmark's line, not above it: the brand sits K.BRAND_DROP
        -- lower than the row, and a small label pinned to the row's top edge
        -- reads as belonging to something else.
        local rowY = ImGui.GetCursorPosY(ctx)
        ImGui.SetCursorPosY(ctx, rowY + math.floor(((brandH or lh) - lh) / 2))
        ImGui.PushFont(ctx, FONT, K.FONT_BADGE)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
        ImGui.Text(ctx, updLabel)
        ImGui.PopStyleColor(ctx)
        ImGui.SameLine(ctx, 0, 8)
        local btnH = (ImGui.GetFrameHeight and ImGui.GetFrameHeight(ctx) or lh)
        -- A SmallButton carries no vertical frame padding, so it is a text line
        -- tall rather than a full frame; splitting the difference puts its
        -- middle on the label's middle either way.
        btnH = (btnH + lh) / 2
        ImGui.SetCursorPosY(ctx, rowY + math.floor(((brandH or lh) - btnH) / 2))
        if ImGui.SmallButton(ctx, 'Open##upd_hdr') then
          state.previousScreen = state.screen
          state.screen = 'deps'
        end
        ImGui.PopFont(ctx)
        ImGui.SetCursorPosY(ctx, rowY)
      else
        -- No room: take the SameLine back so the right-hand group starts from
        -- the wordmark, exactly as it did before there was a signpost.
        ImGui.NewLine(ctx)
        ImGui.SameLine(ctx)
      end
    end
  end

  -- Right-aligned: the connection badge and the menu. The hamburger is on every
  -- screen, because it is now the only way around — the screens carry their
  -- content and nothing else.
  do
    -- Measured, not estimated: the badge knows its own width and the hamburger
    -- has a fixed one.
    local menuW  = UI.badgeHeight() + 6
    local closeW = UI.badgeHeight()
    local closeGap = 6
    -- The badge normally reads CONNECTED. On the preview worker it says so
    -- instead: this is the one label that is on screen at all times, and
    -- "which build am I talking to" belongs where it cannot be missed.
    local badgeLabel = UI.connLabel()
    local badgeW = state.token and UI.badgeWidth(badgeLabel) or 0
    local gap    = state.token and 10 or 0
    local winW   = ImGui.GetWindowWidth(ctx)
    -- The body below keeps its scrollbar inside the right-hand padding, so the
    -- content edge down there is exactly one padding in from the window edge —
    -- inset the header by the same amount and both right edges line up.
    local rightPad = K.WINDOW_PAD_X
    ImGui.SameLine(ctx)
    -- Back to the top of the row, undoing the brand's offset for this group
    -- only -- and after EVERY SameLine below, not just this one. SameLine
    -- restores the y the line started at, and that is the lowered brand: a
    -- single reset here holds for the badge and for nothing after it, so the
    -- menu and the close box dropped back down while the badge stayed up.
    local function atTop() ImGui.SetCursorPosY(ctx, topY) end
    atTop()
    -- Where the wordmark actually ended, measured rather than assumed. The
    -- right-hand group is placed from the window edge inwards, so on a narrow
    -- docker it can be told to start left of where the wordmark stops -- and
    -- the two then overlap, which no width assertion catches because
    -- SetCursorPosX is absolute.
    local used  = ImGui.GetCursorPosX(ctx)
    local fixed = closeW + closeGap + menuW      -- menu and close never go
    local showBadge = state.token
      and (winW - rightPad - used) >= (badgeW + gap + fixed)
    if not showBadge then badgeW, gap = 0, 0 end
    -- Never left of the wordmark: the menu and the close box have to stay
    -- reachable even when there is not enough room for everything.
    ImGui.SetCursorPosX(ctx, math.max(used, winW - rightPad - fixed - gap - badgeW))
    if showBadge then
      if badgeLabel == 'PREVIEW' then
        UI.badge(badgeLabel, CP_COLORS.warn, 0xFFA5001C, 0xFFA50040)
      else
        UI.badge(badgeLabel, CP_COLORS.success, 0x4ADE801C, 0x4ADE8040)
      end
      ImGui.SameLine(ctx, 0, 10)
      atTop()
    end
    local menuOpen = ImGui.IsPopupOpen and ImGui.IsPopupOpen(ctx, 'cpmenu') or false
    if UI.hamburger('##hdrmenu', menuOpen) then
      if ImGui.OpenPopup and ImGui.BeginPopup and ImGui.EndPopup then
        ImGui.OpenPopup(ctx, 'cpmenu')
      else
        -- Ancient ReaImGui without popups: at least keep Settings reachable.
        state.previousScreen = state.screen
        state.screen = 'settings'
      end
    end
    ImGui.SameLine(ctx, 0, closeGap)
    atTop()
    if UI.closeButton('##hdrclose') then state.windowVisible = false end
    UI.mainMenu()
  end

  ImGui.Dummy(ctx, 0, 3)
  do
    local x, y = ImGui.GetCursorScreenPos(ctx)
    -- The indent already set the left end; take the right margin off the width
    -- so the rule ends where the content below does instead of at the window
    -- edge (the window itself has no horizontal padding).
    local w    = ImGui.GetContentRegionAvail(ctx) - K.WINDOW_PAD_X
    ImGui.DrawList_AddLine(ImGui.GetWindowDrawList(ctx), x, y, x + w, y, CP_COLORS.cardBorder, 1)
  end
  ImGui.Dummy(ctx, 0, 2)
end

function UI.relTime(ts)
  if not ts then return 'never' end
  local diff = os.time() - ts
  if diff < 60 then return 'just now' end
  if diff < 3600 then return math.floor(diff / 60) .. ' min' end
  if diff < 86400 then return math.floor(diff / 3600) .. ' h' end
  return math.floor(diff / 86400) .. ' d'
end

-- Legacy UI.header kept as a thin shim so callers keep working; the new
-- branded header is UI.brand() defined further up.
function UI.header()
  -- The window has no horizontal padding of its own (see the main loop), so the
  -- header makes its own left margin — the same one the body indents by, which
  -- is what keeps the brand and the content below flush with each other.
  ImGui.Indent(ctx, K.WINDOW_PAD_X)
  UI.brand()
  ImGui.Unindent(ctx, K.WINDOW_PAD_X)
end

-- Forward-defined here (before UI.footer) so the upvalue resolves; the
-- full implementation is paired with Pill.renderFloating further below.
function UI.setFloatingMenu(v)
  state.floatingMenuEnabled = v and true or false
  setGlobalExt('floating_menu', v and '1' or '0')
end

function UI.settings()
  -- No Back button here: navigating is the menu's job, and the way back sits at
  -- the top of it on this screen.
  ImGui.PushFont(ctx, FONT_BOLD, K.FONT_LEAD)
  ImGui.Text(ctx, 'Settings')
  ImGui.PopFont(ctx)

  -- Each group is a tile: a section label and one card. Written as a list so
  -- the layout below can decide how many fit next to each other — on a wide
  -- window two columns, on a narrow one the same tiles stacked. The content of
  -- a tile never changes with the width, only where the tile sits.
  local panels = {}
  local function panel(id, title, draw) panels[#panels+1] = { id = id, title = title, draw = draw } end

  panel('startup', 'Startup', function()
    local asHit, asVal
    UI.row('Start with Reaper',
           'Runs in the background from launch. The window opens any time from the Actions list.',
           32, function() asHit, asVal = UI.toggle('##autostart', isAutostartEnabled()) end,
           nil, K.TOGGLE_H)
    if asHit then
      local ok, err = setAutostart(asVal)
      if not ok then state.errorMsg = err or 'Could not update the startup script.' end
    end

    UI.rowSep()

    local smHit, smVal
    UI.row('Start in background',
           'Launch without opening this window. The pill is enough for a quick sync.',
           32, function() smHit, smVal = UI.toggle('##startmin', getGlobalExt('start_minimized') == '1') end,
           nil, K.TOGGLE_H)
    if smHit then setGlobalExt('start_minimized', smVal and '1' or '0') end
  end)

  panel('updates', 'Updates', function()
    local uHit, uVal
    UI.row('Check for updates',
           'Once a day, in the background. It reads 200 bytes from GitHub and ' ..
           'never makes you wait for it.',
           32, function() uHit, uVal = UI.toggle('##updcheck', Upd.enabled()) end,
           nil, K.TOGGLE_H)
    if uHit then setGlobalExt(K.UPD_CHECK_KEY, uVal and '1' or '0') end
  end)

  panel('window', 'Window', function()
    local dockLabel = state.mainDocked and 'Undock window' or 'Dock in Reaper'
    -- The button shrinks with the tile: in two columns a tile is half as wide.
    local availW = ImGui.GetContentRegionAvail(ctx)
    local dockW  = math.max(90, math.min(150, availW - 90))
    UI.row('Docking',
      'By hand: click the small arrow at the top left of the docker to reveal ' ..
      'the tab bar, then drag the "CuePort Sync" tab out. Dragging the arrow ' ..
      'itself moves the whole docker and leaves this window inside it.',
      dockW, function()
      if UI.primaryButton(dockLabel .. '##dockbtn', dockW) then
        if state.mainDocked then
          state.pendingDock = 0
        else
          state.pendingDock = (state.lastDockId and state.lastDockId ~= 0) and state.lastDockId or -1
        end
      end
    end)

    UI.rowSep()

    -- Lives here rather than in the menu: the menu is for things you do, and
    -- this is a choice about the layout that stays put once it is made.
    local clHit, clVal
    UI.row('Comment list',
           'A column beside the waveform listing every comment on the version. ' ..
           'Hovering a pin lights its comment; clicking a comment moves the ' ..
           'cursor to its pin. It needs the room, so a narrow window leaves it out.',
           32, function() clHit, clVal = UI.toggle('##commentlist', state.commentsOpen) end,
           nil, K.TOGGLE_H)
    if clHit then
      state.commentsOpen = clVal
      setGlobalExt(K.COMMENTS_OPEN_KEY, clVal and '1' or '0')
    end
  end)

  -- What the script is allowed to put on the ruler. Its own tile, because this
  -- is the one group of settings that changes the project rather than the
  -- window -- and both of them take effect on the spot: switching off takes the
  -- markers away now, switching on puts them back from the cache in the project,
  -- which costs no request.
  panel('ruler', 'Project markers', function()
    local cmHit, cmVal
    UI.row('Comment markers',
           'One marker per comment on the ruler. Turn this off to keep the ' ..
           'ruler to yourself: the pins on the waveform and the comment list ' ..
           'still show every comment, and nothing else changes.',
           32, function() cmHit, cmVal = UI.toggle('##cmtmarkers', Markers.wanted()) end,
           nil, K.TOGGLE_H)
    if cmHit then Markers.setEnabled(cmVal) end

    UI.rowSep()

    local rmHit, rmVal
    UI.row('Render start marker',
           'The marker showing where bar 1 sits. Turning it off leaves the ' ..
           'ruler origin exactly where it is -- only the marker goes. Set and ' ..
           'Clear go on working, and the marker returns with this switch.',
           32, function() rmHit, rmVal = UI.toggle('##rsmarker', renderMarkerWanted()) end,
           nil, K.TOGGLE_H)
    if rmHit then Markers.setRenderMarker(rmVal) end
  end)

  panel('quick', 'Quick access', function()
    local fmHit, fmVal
    UI.row('Floating pill',
           'A small always-there window with Sync and Open.',
           32, function() fmHit, fmVal = UI.toggle('##floatmenu', state.floatingMenuEnabled) end,
           nil, K.TOGGLE_H)
    if fmHit then UI.setFloatingMenu(fmVal) end

    if state.floatingMenuEnabled then
      UI.rowSep()
      if HAS_JS then
        local paHit, paVal
        UI.row('Attach to transport',
               'Drawn inside the transport. Drag to move, click for the menu, right-click to detach.',
               32, function() paHit, paVal = UI.toggle('##pillattach', getGlobalExt('pill_attach') == '1') end,
               nil, K.TOGGLE_H)
        if paHit then setGlobalExt('pill_attach', paVal and '1' or '0') end
        if getGlobalExt('pill_attach') == '1' then
          ImGui.Dummy(ctx, 0, 5)
          if ImGui.SmallButton(ctx, 'Reset position') then state.pillResetPos = true end
          ImGui.SameLine(ctx, 0, 6)
          UI.help('##help_pillreset', 'Moves the pill back to the left edge of the transport.')
        end
      else
        ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
        if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 0) end
        ImGui.TextDisabled(ctx, 'Attaching to the transport needs the JS_ReaScriptAPI extension.')
        if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
        ImGui.PopFont(ctx)
      end
    end
  end)

  panel('ab', 'Cached files', function()
    -- Two places, and only one of them was ever shown here. Downloaded audio
    -- goes beside the project whenever the project has been saved, which is
    -- almost always -- so this panel reported "0 file(s)" while a file had just
    -- landed in the project folder, and the row above was the only thing on the
    -- screen to read that as.
    local st = AB.storageStats()
    local cCount, cBytes = st.cacheCount, st.cacheBytes

    if st.projCount then
      local pv = string.format('%d file(s) \u{b7} %.1f MB', st.projCount, st.projBytes / 1048576)
      UI.row('This project',
        'Reference audio for a saved project lives in a "' .. K.AB_DIR_NAME ..
        '" folder next to the .rpp, so the project still finds it after a ' ..
        'reopen. It is cleaned up by itself: a file is removed once the project ' ..
        'has been saved without the reference track in it, so there is nothing ' ..
        'to clear by hand here.',
        ImGui.CalcTextSize(ctx, pv), function()
          ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
          ImGui.TextDisabled(ctx, pv)
          ImGui.PopFont(ctx)
        end)
    else
      UI.row('This project',
        'This project has never been saved, so there is no folder to keep its ' ..
        'reference audio in. It goes to the shared cache below instead.',
        0, nil)
    end

    -- Cover art, the third place files land in. Grouped by what the files are
    -- rather than by where they sit: "where" is what made the old single row
    -- misleading, because it only ever knew one of two locations.
    do
      local acount, abytes = AB.statsIn(Art.dir(), '^cueport_art_')
      local av = string.format('%d file(s) \u{b7} %.1f MB',
                               acount or 0, (abytes or 0) / 1048576)
      UI.row('Cover art',
        'Artwork shown next to a production is cached in a "' .. K.ART_DIR_NAME ..
        '" folder in the REAPER resource path, never in the project folder: ' ..
        'nothing in the project points at it. It is small, it survives updates, ' ..
        'and signing out clears it.',
        ImGui.CalcTextSize(ctx, av), function()
          ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
          ImGui.TextDisabled(ctx, av)
          ImGui.PopFont(ctx)
        end)
    end

    UI.rowSep()

    local v = string.format('%d file(s) \u{b7} %.1f MB', cCount, cBytes / 1048576)
    UI.row('Shared cache',
      'Only for projects that have never been saved to disk -- a saved project ' ..
      'keeps its audio beside itself, so this stays empty for it. Nothing here ' ..
      'is deleted on its own, because there is no project whose saving could ' ..
      'tell us it is no longer needed. That is what the button is for.',
      ImGui.CalcTextSize(ctx, v), function()
        ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
        ImGui.TextDisabled(ctx, v)
        ImGui.PopFont(ctx)
      end)
    if cCount > 0 then
      ImGui.Dummy(ctx, 0, 6)
      if ImGui.SmallButton(ctx, 'Clear shared cache') then
        state.abCacheCleared = AB.clearCache()
        state.abStats = nil          -- the numbers above are now stale
      end
      if state.abCacheCleared then
        ImGui.SameLine(ctx, 0, 8)
        ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
        if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 0) end
        ImGui.TextDisabled(ctx, string.format('%d file(s) removed', state.abCacheCleared))
        if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
        ImGui.PopFont(ctx)
      end
    end
  end)

  panel('diag', 'Diagnostics', function()
    UI.kv('Version',  'v' .. K.VERSION)
    UI.kv('Instance', tostring(state.instanceId or '?'))
    -- Raw docking reading. Kept because this corner has been misread before and
    -- a screenshot of one line settles it faster than any amount of reasoning.
    UI.kv('Dock', string.format('%s \u{b7} id %s',
      state.mainDocked and 'docked' or 'floating', tostring(state.dockId)))
    ImGui.Dummy(ctx, 0, 7)
    if ImGui.SmallButton(ctx, 'Dependencies') then
      state.previousScreen = state.screen
      state.screen = 'deps'
    end
  end)

  -- No Account tile: log out and quit are navigation, so they live in the menu.

  -- ── Layout ──────────────────────────────────────────────────────────────
  -- Two columns once there is room for them; one below that. The threshold is
  -- about the tile, not the screen: half of it has to stay wide enough for a
  -- label, its "?" and the control on the right.
  local availW = ImGui.GetContentRegionAvail(ctx)
  local GAP    = 14
  local tileFlags = nil
  if HAS_CARDS then
    tileFlags = ImGui.ChildFlags_AutoResizeY()
    if ImGui.ChildFlags_AlwaysAutoResize then
      tileFlags = tileFlags | ImGui.ChildFlags_AlwaysAutoResize()
    end
  end
  local twoCol = tileFlags ~= nil and availW >= 640
  local colW   = twoCol and math.floor((availW - GAP) / 2) or 0

  local function body(p)
    UI.section(p.title)
    local card = UI.cardBegin('set_' .. p.id)
    p.draw()
    UI.cardEnd(card)
  end

  for i, p in ipairs(panels) do
    if twoCol then
      if ImGui.BeginChild(ctx, 'tile_' .. p.id, colW, 0, tileFlags) then
        body(p)
        ImGui.EndChild(ctx)
      end
      -- Left column: keep the next tile on this line. ImGui starts the
      -- following line below the taller of the two, so uneven heights are fine.
      if (i % 2) == 1 and i < #panels then ImGui.SameLine(ctx, 0, GAP) end
    else
      body(p)
    end
  end

  ImGui.Dummy(ctx, 0, 8)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- ABOUT & LEGAL
-- ══════════════════════════════════════════════════════════════════════════════
-- What CuePort is, what this script does, and -- the part that earns the screen
-- -- exactly what it changes in the project it is pointed at. It writes markers,
-- inserts a track, moves the edit cursor and can shift the project's time
-- offset; a user is entitled to read that somewhere other than the source.
--
-- Everything on this page is checked against the code rather than remembered:
-- the list below names the calls it is describing, so a change that adds a
-- fifth thing to the project has an obvious place to be written down.
function UI.about()
  ImGui.PushFont(ctx, FONT_BOLD, K.FONT_LEAD)
  ImGui.Text(ctx, 'About')
  ImGui.PopFont(ctx)

  local panels = {}
  local function panel(id, title, draw) panels[#panels+1] = { id = id, title = title, draw = draw } end

  panel('what', 'What CuePort is', function()
    UI.para('CuePort is the studio platform that sits around your DAW. Artists, ' ..
            'productions, versions, files, sessions and feedback live there. The ' ..
            'mixing stays where it always was.', true)
    ImGui.Dummy(ctx, 0, 7)
    UI.bullet('Every artist gets their own login. They hear new versions, leave ' ..
              'feedback and upload covers or stems, without ever touching your ' ..
              'dashboard.')
    UI.bullet('Comments pin to the exact second on the waveform, color-coded by ' ..
              'who left them.')
    UI.bullet('Every upload is a version. Nothing overwrites the last take, and ' ..
              'you can switch between them in the player.')
    UI.bullet('A production runs through six steps, from lyrics to paid, so ' ..
              'everyone can see where it stands.')
    UI.bullet('Studio sessions your artists can request and reschedule, with the ' ..
              'whole calendar synced to your own by iCal.')
    UI.bullet('Lyrics both sides edit in the same place, team roles with live ' ..
              'presence, and Spotify stats that pull themselves in daily.')
    ImGui.Dummy(ctx, 0, 7)
    UI.para('This script is the Reaper end of it. It brings the comments for the ' ..
            'active version onto your ruler as project markers, draws the same ' ..
            'waveform inside Reaper, and plays the uploaded version against your ' ..
            'DAW mix. Apart from a render you choose to send back yourself, ' ..
            'nothing leaves Reaper.', true)
    ImGui.Dummy(ctx, 0, 8)
    UI.linkRow('CuePort', 'https://cueport.app', 'The studio portal and everything else about it.', 'site')
  end)

  panel('how', 'How it works', function()
    UI.bullet('Pair once. The script asks CuePort for a device code, opens your ' ..
              'browser, and you approve it in the studio portal. The token it gets ' ..
              'back is kept in Reaper, not in your project, so a project file you ' ..
              'hand to somebody else never carries it.')
    UI.bullet('Where that token lives: Reaper\'s own settings, as plain text, ' ..
              'the same place every script keeps its settings -- a script has no ' ..
              'way to reach the system keychain. It survives restarts on purpose, ' ..
              'so you pair once and not every session. Log out removes it, and ' ..
              'that is the thing to do on a machine you share or hand back.')
    UI.bullet('Pick a production per project. The choice is stored in the .rpp, so ' ..
              'each project remembers its own and finds it again on reopen.')
    UI.bullet('Sync pulls every comment on the version you are looking at -- the ' ..
              'artist\'s, the studio\'s and the replies -- and puts one marker on ' ..
              'the ruler per thread. Hover a marker to read it, and answer from ' ..
              'the comment column without leaving Reaper.')
    UI.bullet('The Version button lists everything the studio uploaded, ' ..
              'instrumental and mix, every version of both. Switching takes the ' ..
              'waveform, the comments, the markers and the A/B reference with it.')
    UI.bullet('The waveform is the one CuePort measured when the version was ' ..
              'uploaded, with the comment pins on it and a live play cursor. ' ..
              'Click or drag it to seek; click a comment to jump to its pin.')
    UI.bullet('A/B downloads the version\'s audio into a hidden track that routes ' ..
              'straight to your soundcard, past the master bus -- so the comparison ' ..
              'is against your mix, not through your master chain.')
    UI.bullet('Render start marks where bar 1 of your project sits inside the ' ..
              'uploaded file, so a comment at 1:23 lands at 1:23 of the audio and ' ..
              'not 1:23 of your timeline.')
    UI.bullet('Send a render back, without the browser. The Render page borrows ' ..
              'Reaper\'s render settings for the one pass and puts all of them ' ..
              'back afterwards, byte for byte, whether it worked or not. The ' ..
              'finished file is shown to you first -- its length, its waveform, ' ..
              'and anything that looks off, like a time selection you forgot ' ..
              'about -- and nothing is sent until you press the button.')
    UI.bullet('Every upload becomes a new version, exactly as it would from the ' ..
              'studio portal. Nothing is overwritten and no comment is carried ' ..
              'over or marked as answered. You decide per upload whether the ' ..
              'artist gets an email about it; the portal never sends one, ' ..
              'because there you are already looking at the screen.')
  end)

  panel('project', 'What it changes in your project', function()
    UI.para('This is the honest list. Everything here happens only when you ask ' ..
            'for it, and nothing else in your project is touched.', true)
    ImGui.Dummy(ctx, 0, 7)
    UI.bullet('Project markers named "CP @author: time", one per comment thread ' ..
              '-- a reply shares its parent\'s time and gets no pin of its own. ' ..
              'Sync removes the previous set and writes the current one, so ' ..
              'switching version replaces them with that version\'s. Nothing at ' ..
              'all if you switched them off under Settings, Project markers.')
    UI.bullet('A marker named "' .. K.CP_START_MARKER_NAME .. '", when you set the ' ..
              'render start -- unless you switched that marker off. The project\'s ' ..
              'time offset moves either way: the switch only hides the marker, and ' ..
              'clearing puts the offset back.')
    UI.bullet('A track named "' .. K.AB_TRACK_NAME .. '", hidden from the track ' ..
              'panel and the mixer, with one item and a hardware-output send, for ' ..
              'as long as the A/B reference is loaded.')
    UI.bullet('One audio file in a folder named "' .. K.AB_DIR_NAME .. '" next to ' ..
              'your .rpp, for the same reason. It is removed once the project has ' ..
              'been saved without the reference in it.')
    UI.bullet('Cover art, in a "' .. K.ART_DIR_NAME .. '" folder inside the REAPER ' ..
              'resource path. Never in your project folder, because nothing in the ' ..
              'project points at it. Signing out deletes it.')
    UI.bullet('The bound production, which version of it you are looking at, and ' ..
              'a cache of that version\'s comments and waveform, in the project\'s ' ..
              'own extension data. This marks the project modified.')
    UI.bullet('The edit cursor, when you click the waveform or a comment.')
    UI.bullet('The track selection, for an instant, whenever the reference track ' ..
              'is added or removed: Reaper\'s Track Manager only notices a new ' ..
              'track when the selection changes. An unselected track is selected ' ..
              'and unselected again, so what you had selected stays selected.')
    UI.bullet('The render settings, while a render for CuePort is running. All ' ..
              'twenty-one fields are written down first and put back straight ' ..
              'afterwards, whether it worked or not. If REAPER should die in the ' ..
              'middle, the next start puts them back -- into this project only.')
    UI.bullet('One audio file named "' .. K.RND_PREFIX .. '..." beside your .rpp, ' ..
              'for each render sent to CuePort. It stays unless you say otherwise; ' ..
              'the A/B cleanup does not touch it.')
    UI.bullet('One empty track, for a fraction of a second, to read the waveform ' ..
              'off the finished render. There is no way to read peaks from a file ' ..
              'that is not in the project. It is removed again in the same undo step.')
    UI.bullet('Its own file, when you press the update button -- and only then. ' ..
              'The new one is checked three ways before it is put in place and ' ..
              'the old one stays beside it as a .bak. If ReaPack manages this ' ..
              'copy, ReaPack does the replacing instead and the script briefly ' ..
              'switches that one repository off and on again, which is what ' ..
              'makes ReaPack update it alone; the setting is put back afterwards.')
    ImGui.Dummy(ctx, 0, 7)
    UI.para('Syncing markers, setting or clearing the render start, reading the ' ..
            'waveform and removing the A/B track are named undo steps. Inserting ' ..
            'the A/B track is not -- use Remove rather than Undo for that one.')
  end)

  panel('privacy', 'What leaves this machine', function()
    UI.bullet('Pairing: a device code, and whatever you approve in the browser.')
    UI.bullet('Sync: your device token, the id of the production you picked and ' ..
              'the version you are looking at. Back comes the comment list, the ' ..
              'list of versions, the waveform and the track length.')
    UI.bullet('A/B: the same token and ids, to download that version\'s audio.')
    UI.bullet('Replies: the text you type, the comment it answers and the same ' ..
              'ids -- only when you press Send.')
    UI.bullet('Deleting: the id of the reply you asked twice to remove. Only ' ..
              'replies -- the comment a thread starts with cannot be removed ' ..
              'from here. These two are the only things the script sends.')
    UI.bullet('Updates: once a day, 200 bytes are read from this script\'s own ' ..
              'file on GitHub to learn the current version number. No token, no ' ..
              'ids, nothing about you -- GitHub sees a request for a public file. ' ..
              'Switch it off in Settings and nothing is sent at all.')
    UI.bullet('Uploads: the one rendered file, its length and its waveform, and ' ..
              'only when you press the button. Nothing else from your project ' ..
              'ever leaves.')
    UI.bullet('Everything else goes to CuePort and nowhere else. There is one ' ..
              'exception, and the badge above says PREVIEW while it applies: if ' ..
              'CuePort answers like a version older than this script, the rest ' ..
              'of the session goes to CuePort\'s preview worker instead -- same ' ..
              'company, same database, and it stops by itself once the release ' ..
              'catches up. The same applies to an upload while this CuePort has ' ..
              'no upload path: it goes there, and what arrives is a real version ' ..
              'on a real production.')
    ImGui.Dummy(ctx, 0, 6)
    UI.para('That is the whole of it. Nothing from your project -- no audio, no ' ..
            'track names, no project file -- is ever sent anywhere.', true)
    ImGui.Dummy(ctx, 0, 8)
    UI.linkRow('Privacy policy', 'https://cueport.app/legal/datenschutz/',
               'How CuePort handles the data behind your account.', 'privacy')
  end)

  panel('warranty', 'No warranty', function()
    UI.para('This script is free software and comes with no warranty of any kind. ' ..
            'It writes to the project you point it at, and while it is careful and ' ..
            'checked, nobody can promise that a script, Reaper and your project ' ..
            'will never disagree. Keep backups, the way you would with any script.', true)
    ImGui.Dummy(ctx, 0, 7)
    UI.para('In the words of the license: the software is provided "as is", without ' ..
            'warranty of any kind, express or implied. In no event shall the authors ' ..
            'or copyright holders be liable for any claim, damages or other ' ..
            'liability arising from, out of or in connection with the software or ' ..
            'the use or other dealings in the software.')
    ImGui.Dummy(ctx, 0, 7)
    UI.para('Your CuePort account is a separate matter -- the terms for the service ' ..
            'itself are on the website.')
    ImGui.Dummy(ctx, 0, 8)
    UI.linkRow('Terms of service', 'https://cueport.app/legal/agb/',
               'For the CuePort service, not for this script.', 'terms')
    UI.rowSep()
    UI.linkRow('Imprint', 'https://cueport.app/legal/impressum/', nil, 'imprint')
  end)

  panel('licenses', 'Licenses', function()
    -- The attribution lines are prose, not values: a kv row right-aligns its
    -- value and cannot wrap, so "Inter-LICENSE.txt, next to this script" ran
    -- straight out of a 300px card.
    UI.kv('CuePort Sync', 'MIT')
    UI.para('\u{a9} 2026 melotunesmusic')
    UI.rowSep()
    UI.kv('JSON parser', 'MIT')
    UI.para('Based on rxi/json.lua, \u{a9} 2020 rxi.')
    UI.rowSep()
    UI.kv('Inter typeface', 'SIL OFL 1.1')
    UI.para('Full text in Inter-LICENSE.txt, installed next to this script.')
    ImGui.Dummy(ctx, 0, 8)
    UI.para('The full text of the MIT license is at the top of this script, and in ' ..
            'the LICENSE file installed beside it.')
    ImGui.Dummy(ctx, 0, 8)
    UI.linkRow('Source code', 'https://github.com/m3lotunes/reaper-scripts',
               'The repository this is built and released from.', 'src')
    UI.rowSep()
    UI.kv('Version', 'v' .. K.VERSION)
  end)

  -- Same two-column rule as Settings: the threshold is about a tile staying
  -- readable at half width, not about the screen.
  local availW = ImGui.GetContentRegionAvail(ctx)
  local GAP    = 14
  local tileFlags = nil
  if HAS_CARDS then
    tileFlags = ImGui.ChildFlags_AutoResizeY()
    if ImGui.ChildFlags_AlwaysAutoResize then
      tileFlags = tileFlags | ImGui.ChildFlags_AlwaysAutoResize()
    end
  end
  local twoCol = tileFlags ~= nil and availW >= 640
  local colW   = twoCol and math.floor((availW - GAP) / 2) or 0

  local function body(pn)
    UI.section(pn.title)
    local card = UI.cardBegin('abt_' .. pn.id)
    pn.draw()
    UI.cardEnd(card)
  end

  if not twoCol then
    for _, pn in ipairs(panels) do body(pn) end
    ImGui.Dummy(ctx, 0, 8)
    return
  end

  -- Two columns as two stacks, not as a row of pairs. A row is as tall as its
  -- taller tile, so a short card beside a long one leaves the difference
  -- standing as dead space -- and on this screen one card is a paragraph and
  -- the next is six bullets, so that difference was most of a screen.
  --
  -- Which card goes where is decided from the heights the last frame actually
  -- came out at: a guess made from the content would drift the moment anyone
  -- edits a sentence. The first frame has nothing to go on and splits evenly;
  -- the width of a column does not depend on the split, so the heights do not
  -- either, and it settles on the frame after and stays settled.
  state.aboutH = state.aboutH or {}
  local cols = { {}, {} }
  local hgt  = { 0, 0 }
  for _, pn in ipairs(panels) do
    -- `or 220` alone would not do: a measurement of zero is a number, and zero
    -- is true in Lua, so one bad frame -- a build without GetCursorPosY, a card
    -- whose BeginChild came back false -- would leave every card weighing
    -- nothing and the whole screen in the first column, permanently. Anything
    -- that is not a real height falls back to the even split instead.
    local h = state.aboutH[pn.id]
    if type(h) ~= 'number' or h <= 1 then h = 220 end
    local c = (hgt[1] <= hgt[2]) and 1 or 2
    cols[c][#cols[c] + 1] = pn
    hgt[c] = hgt[c] + h
  end

  for c = 1, 2 do
    if ImGui.BeginChild(ctx, 'abcol_' .. c, colW, 0, tileFlags) then
      for _, pn in ipairs(cols[c]) do
        local y0 = ImGui.GetCursorPosY and ImGui.GetCursorPosY(ctx)
        body(pn)
        local y1 = ImGui.GetCursorPosY and ImGui.GetCursorPosY(ctx)
        if y0 and y1 and (y1 - y0) > 1 then state.aboutH[pn.id] = y1 - y0 end
      end
      ImGui.EndChild(ctx)
    end
    if c == 1 then ImGui.SameLine(ctx, 0, GAP) end
  end

  ImGui.Dummy(ctx, 0, 8)
end

-- Footer has been collapsed into the header (Settings + signed-in indicator
-- live there now). Kept as a no-op shim so the loop can still call it.
function UI.footer() end

-- ══════════════════════════════════════════════════════════════════════════════
-- DEPENDENCIES MODAL
-- ══════════════════════════════════════════════════════════════════════════════

-- The dependency page. It was the last thing in the product that opened a
-- SECOND window: its own title bar, separators, a tick glyph in front of a line
-- of text, and a fixed 500x360 -- while every other page is a section label over
-- cards inside the one window. About is just as informational and is a screen,
-- so this is one too, reached from the menu the same way.
--
-- The old "Re-check" button did nothing: it called TextDisabled inside its own
-- click branch, so it drew a line of text for a single frame and checked
-- nothing. What can honestly be re-checked is curl -- APIExists is fixed for
-- the life of a Reaper session -- so that is what the button does, and the
-- sentence next to it says why the rest needs a restart.
-- Stop whatever is running and put everything back the way it was: the
-- repository setting via its note, a half-finished download off the disk.
function Upd.cancel()
  local st = Upd.st()
  if st.job then
    if st.job.kind == 'install' and st.job.path then deleteFile(st.job.path) end
    if st.job.cfg then deleteFile(st.job.cfg) end
    if st.job.hdr then deleteFile(st.job.hdr) end
    if st.job.head then deleteFile(st.job.head) end
    st.job = nil
  end
  -- Not repairRepo() here either, and here least of all: cancelling happens
  -- while ReaPack is most likely still working. The note stays, the next start
  -- puts the setting back.
  st.rpStarted = nil
  st.error = 'Cancelled.'
end

-- Is something running that the user has to wait for? A check is not one of
-- those: it costs 200 bytes and nobody notices it. A download and a ReaPack run
-- are, and while one is going the window would otherwise look like it stopped.
-- What the window is waiting on, or nil. One place, because three things have
-- to agree about it: the veil, the BeginDisabled around the content underneath,
-- and the Cancel on top of it. A veil over a page that is still pressable, or a
-- Cancel that cancels the other job, is worse than no veil at all.
function UI.busyJob()
  local st = state.upd
  if st then
    if st.rpStarted then return { label = 'Waiting for ReaPack...', cancel = Upd.cancel } end
    if st.job and st.job.kind == 'install' then
      return { label = 'Downloading...', cancel = Upd.cancel }
    end
  end
  -- A transfer of tens of megabytes is the longest thing this script does, and
  -- until now it said so only in a small line under the buttons while the rest
  -- of the page still looked pressable.
  if Up.busy() then
    return { label = Up.progressLine() or 'Uploading...', cancel = Up.cancel }
  end
  return nil
end

function UI.busy()
  return UI.busyJob() ~= nil
end

-- Over everything, once the content is drawn: the window dims and an arc turns
-- in the middle of it. The content underneath is wrapped in BeginDisabled, so
-- nothing can be pressed while this is up -- half a window that reacts and half
-- that does not is worse than one that plainly waits.
--
-- On the FOREGROUND draw list, and this is the whole trick. The first version
-- drew on the window's own list, and the upload page puts its two columns in
-- child windows -- a child is composited AFTER its parent, so the veil, the
-- plate and the label all landed UNDERNEATH the very cards they were meant to
-- cover. On screen that read as a see-through plate with the render card's text
-- running straight through the progress line.
--
-- For the same reason Cancel cannot be an ImGui button here: a widget belongs to
-- the window that draws it, and that window is behind the children too. It is
-- drawn on the same list and hit-tested against its rectangle, the way the
-- menu's rows already are.
function UI.busyOverlay()
  local x, y = ImGui.GetWindowPos(ctx)
  local w, h = ImGui.GetWindowSize(ctx)
  if not (w and h and w > 0 and h > 0) then return end
  local dl = (ImGui.GetForegroundDrawList and ImGui.GetForegroundDrawList(ctx))
             or ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, 0x08080EF0, K.WINDOW_ROUND or 0)

  local job = UI.busyJob() or {}
  local label = job.label or 'Working...'
  local tw = ImGui.CalcTextSize(ctx, label) or 0
  local cx = x + w / 2
  local rad = 24

  -- The panel, sized from the label so a long progress line cannot run off it,
  -- and placed as one block rather than around the middle of the window: the
  -- three parts belong together and the eye should find them in one place.
  local pw = tw + 64
  if pw < 240 then pw = 240 end
  local bw2, bh2 = 104, 28
  local lh = UI.lineH() or 16
  local ph = 20 + rad * 2 + 18 + lh + 16 + bh2 + 20
  local px0, px1 = cx - pw / 2, cx + pw / 2
  local py0 = y + h / 2 - ph / 2
  local py1 = py0 + ph
  ImGui.DrawList_AddRectFilled(dl, px0, py0, px1, py1, 0x14161EFF, 16)
  ImGui.DrawList_AddRect(dl, px0, py0, px1, py1, 0x33344AFF, 16, 0, 1)

  local cy = py0 + 20 + rad
  if ImGui.DrawList_PathArcTo and ImGui.DrawList_PathStroke then
    local t  = r.time_precise() * 3
    local a0 = t % (math.pi * 2)
    -- A faint full ring behind it, so the moving part reads as a part of
    -- something rather than as a stray stroke.
    ImGui.DrawList_PathArcTo(dl, cx, cy, rad, 0, math.pi * 2)
    ImGui.DrawList_PathStroke(dl, 0xB088E030, 0, 4)
    ImGui.DrawList_PathArcTo(dl, cx, cy, rad, a0, a0 + math.pi * 1.35)
    ImGui.DrawList_PathStroke(dl, CP_COLORS.accent, 0, 4)
  else
    ImGui.DrawList_AddCircle(dl, cx, cy, rad, CP_COLORS.accent, 0, 4)
  end

  local ty = cy + rad + 18
  ImGui.DrawList_AddText(dl, cx - tw / 2, ty, CP_COLORS.text or 0xFFFFFFFF, label)

  -- A wait with no way out is a trap, and this one locks everything behind it.
  local bx0 = cx - bw2 / 2
  local by0 = ty + lh + 16
  local hot = ImGui.IsMouseHoveringRect
              and ImGui.IsMouseHoveringRect(ctx, bx0, by0, bx0 + bw2, by0 + bh2) or false
  ImGui.DrawList_AddRectFilled(dl, bx0, by0, bx0 + bw2, by0 + bh2,
                               hot and 0x2B2E3EFF or 0x1E2130FF, 8)
  ImGui.DrawList_AddRect(dl, bx0, by0, bx0 + bw2, by0 + bh2, 0x44475EFF, 8, 0, 1)
  local cw = ImGui.CalcTextSize(ctx, 'Cancel') or 0
  ImGui.DrawList_AddText(dl, bx0 + (bw2 - cw) / 2, by0 + (bh2 - lh) / 2,
                         CP_COLORS.text or 0xFFFFFFFF, 'Cancel')
  if hot and ImGui.IsMouseClicked and ImGui.IsMouseClicked(ctx, 0) and job.cancel then
    job.cancel()
  end
end

-- Something is happening and it is not instant: a download, or ReaPack going
-- about its business. Without a moving part the window looks like it stopped.
-- The arc is drawn from the wall clock, so it turns whether or not anything
-- else on screen changes.
function UI.spinner(size)
  size = size or 14
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local cx, cy, rad = x + size / 2, y + size / 2, size / 2 - 1.5
  local dl = ImGui.GetWindowDrawList(ctx)
  -- Not every ReaImGui build carries the path functions (see UI.menuOpenSeam),
  -- and a missing spinner must not take the line it sits on with it.
  if ImGui.DrawList_PathArcTo and ImGui.DrawList_PathStroke then
    local t  = r.time_precise() * 3
    local a0 = t % (math.pi * 2)
    ImGui.DrawList_PathArcTo(dl, cx, cy, rad, a0, a0 + math.pi * 1.35)
    ImGui.DrawList_PathStroke(dl, CP_COLORS.accent, 0, 2)
  else
    ImGui.DrawList_AddCircle(dl, cx, cy, rad, CP_COLORS.accent, 0, 2)
  end
  ImGui.Dummy(ctx, size, size)
end

-- What the header should say about updates, or nil. Kept apart from the
-- drawing so the width can be worked out before anything is committed to the
-- row -- the header only shows it when there is room, like the badge.
function UI.updateHeaderLabel()
  local st = Upd.st()
  if st.onDisk then return 'Update ready ' .. st.onDisk end
  local newVer = Upd.available()
  if not newVer then return nil end
  -- A pinned package is not an offer, so it gets no signpost either.
  local ent = (Upd.mode() == 'reapack') and Upd.entry() or nil
  if ent and ent.pinned then return nil end
  return 'Update available ' .. newVer
end

-- The update panel on the Dependencies page. It is the same four steps in every
-- constellation -- check, offer, install, restart -- and only the middle one
-- differs: a ReaPack-managed copy is handed back to ReaPack, everything else
-- replaces its own file.
function UI.updateCard()
  local st   = Upd.st()
  local mode = Upd.mode()
  local ent  = (mode == 'reapack') and Upd.entry() or nil
  local newVer = Upd.available()

  UI.section('Updates')
  local card = UI.cardBegin('upd_card')

  -- Where this copy comes from. Worth stating plainly: it decides which button
  -- appears below, and it is the first thing worth knowing when something is
  -- odd about an install.
  local origin
  if mode == 'reapack' then
    origin = 'Installed through ReaPack, from the repository "' .. tostring(ent and ent.repo) .. '".'
  elseif mode == 'manual' then
    origin = 'This file does not belong to any ReaPack package, so it is ' ..
             'updated by replacing it directly.'
  else
    origin = 'ReaPack is not installed, so this file is updated by replacing it directly.'
  end
  UI.row('This script', origin, UI.badgeWidth(K.VERSION), function()
    UI.badge(K.VERSION, CP_COLORS.textDim, 0xFFFFFF10, 0xFFFFFF28)
  end, nil, UI.badgeHeight())

  UI.rowSep()

  local bw = 150
  if st.onDisk then
    -- Whoever changed the file -- us, ReaPack, or a text editor -- what runs in
    -- memory is now the old one. This is the only state that offers a restart.
    UI.row('Version ' .. st.onDisk .. ' is on disk',
      Upd.canRestart()
        and ('Restarting loads it. The comment markers come off the ruler and go ' ..
             'back on, and the A/B reference track is removed -- the same as any ' ..
             'other restart.')
        or  ('This script is not in the action list, so it cannot restart itself. ' ..
             'Start it again by hand to load it. Looked for it as: ' ..
             tostring(getScriptSelfPath())),
      bw, function()
        if Upd.canRestart() then
          if UI.primaryButton('Restart now##upd_restart', bw) then
            Upd.st().restartWanted = true
          end
        end
      end, nil, K.BTN_H)

  elseif st.job and st.job.kind == 'install' then
    UI.row('Downloading ' .. tostring(st.job.want), nil, 16,
           function() UI.spinner(14) end, nil, 16)
    UI.para(
           'The file is checked three ways before anything is replaced: its ' ..
           'byte count, its version line, and whether it compiles at all.')

  elseif st.rpStarted then
    UI.row('Waiting for ReaPack', nil, 16, function() UI.spinner(14) end, nil, 16)
    UI.para('ReaPack is fetching the package. Its own progress window shows the ' ..
            'download; this line changes once the new file is in place.')

  elseif st.job and st.job.kind == 'check' then
    UI.row('Checking...', nil, 16, function() UI.spinner(14) end, nil, 16)
    UI.para('Asking GitHub for the current version number.')

  elseif newVer and ent and ent.pinned then
    -- Their decision beats our convenience: pinned means "keep me here".
    UI.row('Version ' .. newVer .. ' is available')
    UI.para('You have pinned this package in ReaPack, so it is deliberately kept ' ..
            'at ' .. K.VERSION .. '. Unpin it there if you want the update.')

  elseif newVer then
    -- Only offer ReaPack when ReaPack would actually fetch something. Its
    -- registry can already list this version -- after a hand-placed file, for
    -- instance -- and then the button would lock the window until the timeout
    -- for a transaction that was never going to do anything.
    local viaRp = (mode == 'reapack') and Upd.reaPackWouldAct(newVer)
    local label = viaRp and 'Update via ReaPack' or 'Install update'
    UI.row('Version ' .. newVer .. ' is available', nil,
      bw, function()
        if UI.primaryButton(label .. '##upd_go', bw) then
          local st2 = Upd.st()
          st2.error = nil
          if viaRp then
            local ok, why = Upd.viaReaPack()
            if not ok then st2.error = why; Upd.startInstall() end
          else
            Upd.startInstall()
          end
        end
      end, nil, K.BTN_H)
    UI.para(viaRp
      and 'ReaPack fetches it, so its records stay correct. The script restarts itself afterwards.'
      or  'The file is replaced and the script restarts itself. The previous version is kept as .bak beside it.')

  else
    local seen = getGlobalExt(K.UPD_SEEN_KEY)
    UI.row('Up to date', nil, bw, function()
        if UI.primaryButton('Check now##upd_check', bw) then
          Upd.st().error = nil
          Upd.startCheck(true)
        end
      end, nil, K.BTN_H)
    UI.para((seen ~= '' and ('GitHub last reported ' .. seen .. '. ') or '') ..
            'Checked once a day in the background, never while you wait.')
  end

  -- Anything that went wrong stays on screen. Two seconds is enough for a
  -- receipt and nowhere near enough for a reason.
  if st.error then
    UI.rowSep()
    UI.row('Last attempt', nil, bw, function()
      -- The way out when ReaPack did not come through: the direct replacement
      -- exists for the hand-installed cases anyway, so offering it here costs
      -- nothing and is the one path that always works.
      if newVer and not (ent and ent.pinned) then
        if UI.primaryButton('Replace file##upd_force', bw) then
          Upd.st().error = nil
          Upd.startInstall()
        end
      end
    end, nil, K.BTN_H)
    UI.para(st.error)
  end

  UI.cardEnd(card)
end

function UI.deps()
  ImGui.PushFont(ctx, FONT_BOLD, K.FONT_LEAD)
  ImGui.Text(ctx, 'Dependencies')
  ImGui.PopFont(ctx)

  UI.updateCard()

  UI.section('What the script runs on')
  local card = UI.cardBegin('deps_list')
  for i, d in ipairs(getDependencies()) do
    if i > 1 then UI.rowSep() end
    -- Three states, and the badge carries all of them: installed, missing and
    -- needed, missing and optional. The old page put that in a glyph and a
    -- parenthesis after the name, which read as part of the name.
    local mark, col, bg, br
    if d.ok then
      mark, col, bg, br = 'INSTALLED', CP_COLORS.success, 0x4ADE801C, 0x4ADE8040
    elseif d.required then
      mark, col, bg, br = 'REQUIRED',  CP_COLORS.danger,  0xFF4F6D1C, 0xFF4F6D40
    else
      mark, col, bg, br = 'OPTIONAL',  CP_COLORS.warn,    0xFFA5001C, 0xFFA50040
    end
    UI.row(d.name, nil, UI.badgeWidth(mark),
      function() UI.badge(mark, col, bg, br) end, nil, UI.badgeHeight())
    if d.what then UI.para(d.what) end
    if d.ok then
      if d.detail then UI.para(d.detail) end
    else
      UI.para(d.install, true)
      if d.url then
        ImGui.Dummy(ctx, 0, 4)
        UI.linkRow(d.name, d.url, nil, 'dep_' .. d.name)
      end
    end
  end
  UI.cardEnd(card)

  UI.section('Re-checking')
  local card2 = UI.cardBegin('deps_recheck')
  local bw = ImGui.CalcTextSize(ctx, 'Re-check') + 24
  UI.row('Ask curl again', 'Reaper loads its extensions once at startup, so an ' ..
         'install only shows up here after a restart. curl is a program, not an ' ..
         'extension, so it can be asked on the spot.', bw, function()
    if ImGui.Button(ctx, 'Re-check##deps_curl', bw, 0) then checkCurl(true) end
  end, nil, ImGui.GetFrameHeight and ImGui.GetFrameHeight(ctx) or nil)
  UI.cardEnd(card2)

  ImGui.Dummy(ctx, 0, 8)
end

-- An error, wherever a screen needs to show one. Was a bare red line of text on
-- three screens, each with its own spacing; a card in the danger colour reads
-- as a state of the screen rather than as a sentence someone left lying there.
function UI.errorCard(msg)
  msg = msg or state.errorMsg
  if not msg then return end
  ImGui.Dummy(ctx, 0, 6)
  local card = UI.cardBegin('errcard')
  if card.open then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.danger)
    if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 0) end
    ImGui.Text(ctx, msg)
    if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
    ImGui.PopStyleColor(ctx)
  end
  UI.cardEnd(card)
end

function UI.login()
  UI.section('Connect')
  local card = UI.cardBegin('logincard')
  if card.open then
    if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 0) end
    ImGui.Text(ctx,
      'Open CuePort in your browser, generate a pairing code there, and ' ..
      'enter it below to connect this Reaper to your studio.')
    if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
    ImGui.Dummy(ctx, 0, 10)
    if UI.primaryButton('Open CuePort in browser', 220) then openUrl(K.PAIR_URL) end
    ImGui.Dummy(ctx, 0, 12)
    ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.textDim)
    ImGui.Text(ctx, 'PAIRING CODE')
    ImGui.PopStyleColor(ctx)
    ImGui.PopFont(ctx)
    ImGui.SetNextItemWidth(ctx, 220)
    local _, val = ImGui.InputTextWithHint(ctx, '##cppair', 'XXXX-XXXX', state.pairCode or '')
    state.pairCode = val
    ImGui.Dummy(ctx, 0, 10)
    if UI.primaryButton('Connect', 220) then submitPairing() end
    -- Uebergangsweise bleibt der klassische Browser-Freigabe-Weg erreichbar,
    -- solange der Worker beide Wege haelt. Faellt beim Cutover mit den alten
    -- device/*-Endpunkten wieder weg.
    ImGui.Dummy(ctx, 0, 8)
    if UI.primaryButton('Classic browser approval', 220) then startPairing() end
  end
  UI.cardEnd(card)
  UI.errorCard()
end

function UI.pairing()
  UI.section('Pairing')
  local card = UI.cardBegin('paircard')
  if card.open then
    if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 0) end
    ImGui.Text(ctx,
      'A browser window should have opened. Log in to the studio portal ' ..
      'and confirm the code below.')
    if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end

    -- The code is the whole point of this screen, so it is the headline, not a
    -- word on a line beginning "Your code:".
    ImGui.Dummy(ctx, 0, 10)
    ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.textDim)
    ImGui.Text(ctx, 'YOUR CODE')
    ImGui.PopStyleColor(ctx)
    ImGui.PopFont(ctx)
    ImGui.PushFont(ctx, FONT_BOLD, K.FONT_BRAND)
    UI.shadowText(state.userCode or '----', CP_COLORS.accent)
    ImGui.PopFont(ctx)
    ImGui.SameLine(ctx, 0, 10)
    -- An ordinary button: a SmallButton beside full-size ones reads as a
    -- different kind of control, which it is not.
    if ImGui.Button(ctx, 'Copy', 70, K.BTN_H) then clipboardSet(state.userCode or '') end

    ImGui.Dummy(ctx, 0, 10)
    if state.verificationUrl and ImGui.Button(ctx, 'Reopen browser', 160, K.BTN_H) then
      state.urlBlocked = not openUrl(state.verificationUrl)
    end
    ImGui.SameLine(ctx, 0, 8)
    if ImGui.Button(ctx, 'Cancel', 100, K.BTN_H) then cancelPairing() end

    local remaining = math.max(0, state.pairingExpiresAt - r.time_precise())
    ImGui.Dummy(ctx, 0, 8)
    ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
    ImGui.TextDisabled(ctx, string.format(
      'Waiting for approval \u{b7} valid for %d more sec', math.floor(remaining)))
    ImGui.PopFont(ctx)
  end
  UI.cardEnd(card)
  UI.errorCard()
end

function UI.picker()
  -- Cancel row — only shown when there's an existing binding we could return
  -- to. Lets the user back out of a "Change project..." click without losing
  -- their current binding.
  if state.boundProductionId and state.boundProduction then
    UI.section('Current production')
    local cur = UI.cardBegin('pickercur')
    if cur.open then
      local bp = state.boundProduction
      local backW = 150
      -- Both measured before anything is drawn, because SetCursorPosX is
      -- absolute: placing the button from where the text happened to end would
      -- put it somewhere different for every title.
      local avail = ImGui.GetContentRegionAvail(ctx)
      local x0    = ImGui.GetCursorPosX(ctx)
      -- Artist over title, the same shape the bound screen gives them, so the
      -- thing you are leaving looks like the thing you would go back to.
      ImGui.BeginGroup(ctx)
      ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.textDim)
      ImGui.Text(ctx, (bp.artist_name or '-'):upper())
      ImGui.PopStyleColor(ctx)
      ImGui.PopFont(ctx)
      -- Wrapped short of the button: an artist and title of any length would
      -- otherwise make this row wider than the window, and content wider than
      -- its window can be dragged sideways.
      if ImGui.PushTextWrapPos then
        ImGui.PushTextWrapPos(ctx, ImGui.GetCursorPosX(ctx) + math.max(80, avail - backW - 12))
      end
      ImGui.Text(ctx, bp.title or '?')
      if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
      ImGui.EndGroup(ctx)
      ImGui.SameLine(ctx)
      ImGui.SetCursorPosX(ctx, x0 + math.max(0, avail - backW))
      if ImGui.Button(ctx, 'Back to it', backW, K.BTN_H) then
        state.showPickerOverride = false
      end
    end
    UI.cardEnd(cur)
  end

  UI.section('Choose a production')
  local search = UI.cardBegin('pickersearch')
  if search.open then
    local availS  = ImGui.GetContentRegionAvail(ctx)
    local refresh = 90
    ImGui.SetNextItemWidth(ctx, math.max(80, availS - refresh - 8))
    local ch, val = ImGui.InputTextWithHint(ctx, '##filter', 'Search...', state.filterText)
    if ch then state.filterText = val end
    ImGui.SameLine(ctx, 0, 8)
    if ImGui.Button(ctx, 'Refresh', refresh, K.BTN_H) then loadProductions() end
  end
  UI.cardEnd(search)

  if state.productionsFetching then
    ImGui.Dummy(ctx, 0, 8)
    ImGui.TextDisabled(ctx, 'Loading productions...')
    return
  end
  if state.productionsError then
    UI.errorCard('Error: ' .. state.productionsError)
    return
  end
  if not state.productions then
    loadProductions()
    return
  end

  -- Persist expand state across frames and filter changes
  state.expandedArtists = state.expandedArtists or {}

  local filter = (state.filterText or ''):lower()

  -- Group productions by artist (productions are already sorted by
  -- last_version_at DESC from the API; grouping preserves that order).
  local byArtist, order = {}, {}
  for _, p in ipairs(state.productions) do
    local a = p.artist_name or '—'
    if not byArtist[a] then
      byArtist[a] = {}
      order[#order+1] = a
    end
    table.insert(byArtist[a], p)
  end
  table.sort(order, function(x, y) return x:lower() < y:lower() end)

  -- Collect matching entries per artist (filter applies to title + artist +
  -- feat so searching by artist name also works).
  local totalMatches = 0
  local perArtist = {}
  for _, a in ipairs(order) do
    local matched = {}
    for _, p in ipairs(byArtist[a]) do
      local hay = ((p.title or '') .. ' ' .. a .. ' ' .. (p.feat or '')):lower()
      if filter == '' or hay:find(filter, 1, true) then
        matched[#matched+1] = p
      end
    end
    if #matched > 0 then
      perArtist[a] = matched
      totalMatches = totalMatches + #matched
    end
  end

  -- A well, the same one the comment column sits in, sized to what is left of
  -- the window rather than to a fixed 360px -- that left a strip of dead window
  -- under it on a tall docker and cut the list short on a short one.
  --
  -- Worked out here rather than passed as 0. This screen is inside a region
  -- that auto-resizes to its content: a child asking there for "the rest of the
  -- region" makes the region bigger, which makes the rest bigger, and the
  -- window is dragged longer every frame. The height comes from the window
  -- (state.bodyAvailH) minus how far down the page we already are -- and that
  -- distance is settled before the list is drawn, so nothing feeds back.
  local listH = math.max(140,
    (state.bodyAvailH or 360) - ImGui.GetCursorPosY(ctx) - K.PICKER_BOTTOM_PAD)
  local list = UI.wellBegin('prodlist', 0, listH)
  if list.open then
    if totalMatches == 0 then
      ImGui.TextDisabled(ctx, filter == '' and 'No productions.' or 'No matches.')
    else
      for _, a in ipairs(order) do
        local matched = perArtist[a]
        if matched then
          -- Auto-expand when a filter is active so the user sees matches immediately
          local open = (filter ~= '') or state.expandedArtists[a]
          -- The triangle is drawn first and the row's hit area laid over the
          -- whole line: a Selectable carrying the glyph in its label would put
          -- the mark in whatever font the platform picked for it.
          local tx, ty = ImGui.GetCursorScreenPos(ctx)
          ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
          ImGui.PushFont(ctx, FONT_BOLD, K.FONT_SIZE)
          if ImGui.Selectable(ctx, '     ' .. a .. '##cpart_' .. a, false, 0, 0, 0) then
            state.expandedArtists[a] = not (state.expandedArtists[a])
          end
          ImGui.PopFont(ctx)
          ImGui.PopStyleColor(ctx)
          do
            local dl = ImGui.GetWindowDrawList(ctx)
            UI.disclosure(dl, tx, ty + 5, open, CP_COLORS.accent)
            -- The count, right-aligned and dimmed, so the eye reads the names
            -- down the left edge without a number in the middle of each one.
            local availA = ImGui.GetContentRegionAvail(ctx)
            local cnt    = tostring(#matched)
            ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
            local cw = ImGui.CalcTextSize(ctx, cnt)
            ImGui.DrawList_AddText(dl, tx + availA - cw, ty + 3, CP_COLORS.textDim, cnt)
            ImGui.PopFont(ctx)
          end

          if open then
            ImGui.Indent(ctx, 14)
            for _, p in ipairs(matched) do
              local plabel = p.title or '?'
              if p.feat and p.feat ~= '' then
                plabel = plabel .. '   feat. ' .. p.feat
              end
              -- Cover tile plus title, both painted by hand. The Selectable is
              -- only the hit area: its label would sit at the top of a row this
              -- tall (ImGui aligns to the top, not the middle), and the tile has
              -- to be drawn at a position captured BEFORE the Selectable moved
              -- the cursor on -- same pattern as the comment rows.
              local px, py = ImGui.GetCursorScreenPos(ctx)
              local availW = ImGui.GetContentRegionAvail(ctx)
              -- What this production actually holds, as pills you can press:
              -- press "Instrumental" and that is what opens, rather than the
              -- mix that used to open no matter what was in there.
              --
              -- Submitted BEFORE the row's Selectable on purpose. ImGui gives
              -- hover to the first item that claims it, so a pill drawn after
              -- the Selectable would sit under it and never be clickable. The
              -- cursor is put back afterwards, since the Selectable has to
              -- start where the row does.
              local pickType, tailW, chips = nil, 0, nil
              do
                local tt = p.track_types
                if type(tt) == 'table' and #tt > 0 then
                  -- Same reading order as the player, and sorted here rather
                  -- than trusted from the server: which end the instrumental
                  -- sits on is a question about this screen.
                  -- `x, y`: `a` is the artist name this loop is already inside.
                  table.sort(tt, function(x, y)
                    return UI.typeRank(x.type) < UI.typeRank(y.type)
                  end)
                  ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
                  local ws, total = {}, 0
                  for i, e in ipairs(tt) do
                    ws[i] = ImGui.CalcTextSize(ctx, UI.versionTypeLabel(e.type)) + 18
                    total = total + ws[i] + (i > 1 and 6 or 0)
                  end
                  -- Only if there is room for the title beside them; on a very
                  -- narrow window the name of the track wins.
                  if total + 90 <= availW then
                    local cx = px + availW - total
                    chips = {}
                    for i, e in ipairs(tt) do
                      local cy = py + (K.ART_ROW_H - 20) / 2
                      ImGui.SetCursorScreenPos(ctx, cx, cy)
                      local hit = ImGui.InvisibleButton(
                        ctx, '##cppt_' .. p.id .. '_' .. tostring(e.type), ws[i], 20)
                      if hit then pickType = e.type end
                      chips[#chips+1] = { x = cx, y = cy, w = ws[i],
                                          label = UI.versionTypeLabel(e.type),
                                          hov = ImGui.IsItemHovered(ctx) }
                      cx = cx + ws[i] + 6
                    end
                    tailW = total + 12
                  end
                  ImGui.PopFont(ctx)
                  ImGui.SetCursorScreenPos(ctx, px, py)
                end
              end
              if ImGui.Selectable(ctx, '##cpprod_' .. p.id, false, 0, 0, K.ART_ROW_H) then
                bindProduction(p)
              end
              if pickType then bindProduction(p, pickType) end
              local dl = ImGui.GetWindowDrawList(ctx)
              -- After the Selectable, never before: it paints its hover
              -- highlight across the whole row, and pills drawn earlier
              -- disappeared underneath it the moment the row was hovered.
              if chips then
                ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
                for _, ch in ipairs(chips) do
                  UI.pillPaint(dl, ch.x, ch.y, ch.w, 20, ch.label, false, ch.hov)
                end
                ImGui.PopFont(ctx)
              end
              local tile = K.ART_TILE_SMALL
              Art.tile(dl, p.id, p.cover_tag, px, py + (K.ART_ROW_H - tile) / 2, tile)
              local _, tlh = ImGui.CalcTextSize(ctx, 'X')
              local textX = px + tile + 10
              -- Clipped, not just placed: the title used to be the Selectable's
              -- label, where ImGui kept it inside. Drawn by hand it would happily
              -- run past the right edge, and a row wider than the region is what
              -- lets the whole window be dragged sideways. The clip stops short
              -- of the type labels for the same reason it stops at the edge.
              ImGui.DrawList_PushClipRect(dl, px, py, px + availW - tailW, py + K.ART_ROW_H, true)
              ImGui.DrawList_AddText(dl, textX, py + (K.ART_ROW_H - tlh) / 2,
                                     CP_COLORS.text, plabel)
              ImGui.DrawList_PopClipRect(dl)
            end
            ImGui.Unindent(ctx, 14)
            ImGui.Dummy(ctx, 0, 4)
          end
        end
      end
    end
  end
  UI.wellEnd(list)
end

-- ── Version switcher ────────────────────────────────────────────────────────
-- A production in CuePort is not one file. It carries whatever the studio
-- uploaded -- an instrumental, a mix, a master -- and each of those has its own
-- run of versions. Until now the script opened exactly one of them (the newest
-- mixmaster) and offered no way to any of the others, so checking a note left
-- on the instrumental meant going to the browser for it.
function UI.versionTypeLabel(tt)
  if tt == 'mixmaster'    then return 'Mix Master' end
  if tt == 'instrumental' then return 'Instrumental' end
  if not tt or tt == ''   then return 'Version' end
  return (tostring(tt):gsub('^%l', string.upper))
end

function UI.versionLabel(v, long)
  if not v then return 'Version' end
  local s = UI.versionTypeLabel(v.track_type) .. '  \u{b7}  v' .. tostring(v.version_number or '?')
  if long and v.label and v.label ~= '' then s = s .. '  \u{b7}  ' .. tostring(v.label) end
  return s
end

-- The list only counts while it belongs to the production on screen. After a
-- binding change the old list is still in memory for a frame or two, and
-- offering it would let a click ask for a version of a different production.
-- Lazy-load the persisted version list, the same way the waveform block picks
-- up its peaks. Hung off the one function that reads the list, so every caller
-- gets it -- the switcher, the pills and the upload page all ask through here.
-- Tried once per binding: a production with no cached list must not re-read the
-- project file on every frame.
function UI.ensureVersions()
  local pid = state.boundProductionId
  if not pid or state.versionsForId == pid or state.versionsTriedFor == pid then return end
  state.versionsTriedFor = pid
  local cached = loadWaveformCache(pid)
  if cached and type(cached.versions) == 'table' and #cached.versions > 0 then
    state.versions     = cached.versions
    state.versionsForId = pid
  end
end

function UI.versionsFor()
  UI.ensureVersions()
  if not state.boundProductionId then return nil end
  if state.versionsForId ~= state.boundProductionId then return nil end
  local list = state.versions
  if type(list) ~= 'table' or #list == 0 then return nil end
  return list
end

-- Fold a version the server just told us about into the list we hold. Only
-- ever adds -- an id that is already in there is left alone, so a repeated
-- frame cannot duplicate it.
function UI.rememberVersion(v)
  if type(v) ~= 'table' or not v.id or not state.boundProductionId then return end
  if state.versionsForId ~= state.boundProductionId then
    -- No list for this production yet: start one, otherwise UI.versionsFor
    -- refuses it as belonging to something else.
    state.versions, state.versionsForId = {}, state.boundProductionId
  end
  state.versions = state.versions or {}
  for _, e in ipairs(state.versions) do
    if e.id == v.id then return end
  end
  state.versions[#state.versions + 1] = {
    id = v.id, track_type = v.track_type, version_number = v.version_number,
    label = v.label, filename = v.name or v.filename, created_at = v.created_at,
  }
end

function UI.activeVersion()
  local list = UI.versionsFor()
  if not list then return nil end
  local want = state.selectedVersionId or state.versionId
  for _, v in ipairs(list) do
    if v.id == want then return v end
  end
  return nil
end

-- Switching is: remember the choice, adopt the new identity straight away, and
-- ask for the rest. The identity (id + filename) comes from the list we already
-- have rather than from the answer, because the A/B file name and download URL
-- are built from it -- waiting for the sync would mean one round where they
-- still point at the version being left.
function UI.switchVersion(v)
  if not v or not v.id then return end
  if v.id == state.selectedVersionId then return end
  local prevId, prevVersionId = state.selectedVersionId, state.versionId
  local prevFilename = state.versionFilename
  local prevLabel = UI.versionLabel(UI.activeVersion())
  state.selectedVersionId = v.id
  setProjExt(K.VERSION_KEY, v.id)
  state.versionId       = v.id
  state.versionFilename = v.filename
  -- The waveform, the numbers and the comments on screen all belong to the
  -- version being left. They are replaced together by the sync -- which blocks
  -- for its own frame, so nothing is cleared here: clearing first would only
  -- risk leaving the screen empty if the request fails.
  state.pendingSeekAt = nil
  state.replyTo, state.replyText, state.replyStatus = nil, '', nil
  state.delArm, state.delPending = nil, nil
  state.replyFocus = false
  -- What we are leaving. If the request for the new version fails there is
  -- nothing to put on screen, and the markers, the waveform and the comment
  -- list would all still be the old version's while the header named the new
  -- one -- a screen that lies about which mix the pins belong to. doSync puts
  -- this back on failure and clears it on success.
  state.versionSwitchFrom = {
    id = prevId, versionId = prevVersionId, filename = prevFilename,
    label = prevLabel,
  }
  -- The reference track is playing the old version's audio. Take it down and
  -- delete its file; loading the new one is a decision, not a side effect.
  AB.dropForVersion()
  state.syncRequested = true
  state.syncStatus    = 'Loading ' .. UI.versionLabel(v) .. '...'
end

-- The types this production actually has, in the order the server sent them
-- (mixmaster first). Derived from the version list rather than from the
-- picker's `track_types`, so the two can never disagree about a production that
-- has been opened.
-- Both kinds, always, in a fixed order -- plus anything else the studio might
-- have uploaded. The switch is not only a way to change kind, it is the label
-- that says which kind you are looking at, so it has to be there even when
-- there is nothing to switch to. `have` marks the ones that actually exist;
-- the rest are drawn dim and cannot be pressed.
-- Reading order, left to right, the way the work happens: the instrumental
-- comes before the mix of it.
K.VERSION_TYPES = { 'instrumental', 'mixmaster' }

-- Where a kind sits in that order. Anything the list does not name goes last,
-- in the order it turned up.
function UI.typeRank(tt)
  for i, t in ipairs(K.VERSION_TYPES) do
    if t == tt then return i end
  end
  return #K.VERSION_TYPES + 1
end

function UI.versionTypes(list)
  local types, seen, have = {}, {}, {}
  for _, tt in ipairs(K.VERSION_TYPES) do
    types[#types+1] = tt
    seen[tt] = true
  end
  for _, v in ipairs(list or {}) do
    have[v.track_type] = true
    if not seen[v.track_type] then
      seen[v.track_type] = true
      types[#types+1] = v.track_type
    end
  end
  return types, have
end

-- The versions of one kind, oldest first: v1 v2 v3 reads the way they were
-- made. The server sends them newest-first, which is the right default for
-- "open this kind" and the wrong one for a row you read left to right.
function UI.versionsOfType(list, tt)
  local out = {}
  for _, v in ipairs(list or {}) do
    if v.track_type == tt then out[#out+1] = v end
  end
  table.sort(out, function(a, b)
    return (tonumber(a.version_number) or 0) < (tonumber(b.version_number) or 0)
  end)
  return out
end

-- The newest of a kind. Taken as the highest version number rather than as the
-- first match: the order the list happens to arrive in is the server's business
-- and has already changed once.
function UI.newestOfType(list, tt)
  local best = nil
  for _, v in ipairs(list or {}) do
    if v.track_type == tt then
      if not best or (tonumber(v.version_number) or 0) > (tonumber(best.version_number) or 0) then
        best = v
      end
    end
  end
  return best
end

-- Type over versions: the two questions are asked in that order, so the screen
-- asks them in that order too. The type is a choice between two things and gets
-- the segmented control; the versions are a short run of numbers and get pills.
-- Nothing at all before the first sync: the list is what the server sends with
-- the comments, and inventing a "Version 1" for a production nobody has opened
-- yet would be a label with no answer behind it.
-- `trailing` is a control that belongs on the same line as the kind switcher,
-- pushed against the right edge. That line is the first one BELOW the cover --
-- the card has already moved the cursor past its bottom edge -- so the full
-- width is free here, unlike on the sync row further up.
--
-- Returns whether it was placed: on a narrow card there is no room beside the
-- switcher, and the caller then has to put it somewhere of its own.
function UI.versionRow(trailing, trailingW)
  local list = UI.versionsFor()
  if not list then return false end
  local cur = UI.activeVersion()
  local types, have = UI.versionTypes(list)
  -- What is open. Never a kind the production does not have: the fallback is
  -- the first kind there IS something of, not simply the first name on the list.
  local curType = cur and cur.track_type or nil
  if not curType then
    for _, tt in ipairs(types) do
      if have[tt] then curType = tt; break end
    end
  end

  -- No caption over it: a row of "v1 v2 v3" says what it is, and a label would
  -- cost a line in the one part of the card that is already three rows deep.
  --
  -- The kinds are always shown, including the ones this production has nothing
  -- of -- they are what says which kind is on screen, and that answer is needed
  -- whether or not there is a second one to switch to.
  local labels, activeIdx, off = {}, 1, {}
  for i, tt in ipairs(types) do
    labels[i] = UI.versionTypeLabel(tt)
    if tt == curType then activeIdx = i end
    if not have[tt] then off[i] = true end
  end
  local availT = ImGui.GetContentRegionAvail(ctx)
  local rowX0  = ImGui.GetCursorPosX(ctx)
  -- The switcher keeps what it needs; the trailing control gets the rest, and
  -- only if what is left over is still enough for the switcher to read as one.
  local paired, trailX = false, nil
  if trailing and trailingW then
    paired, trailX = UI.pairOnRow(availT, 0, 0, trailingW, 160)
  end
  local segW = paired and math.min(360, math.max(160, trailX - 12)) or math.min(360, availT)
  local pick = UI.segmented('##cpvtype', labels, activeIdx, segW, off)
  if pick and types[pick] and types[pick] ~= curType then
    UI.switchVersion(UI.newestOfType(list, types[pick]))
  end
  if paired then
    ImGui.SameLine(ctx)
    ImGui.SetCursorPosX(ctx, rowX0 + trailX)
    trailing()
  end
  ImGui.Dummy(ctx, 0, 7)

  -- The versions of that type, newest first. Measured before anything is drawn
  -- so the row knows where to break: a row of pills wider than the card is the
  -- classic way to make the whole window draggable sideways.
  local avail = ImGui.GetContentRegionAvail(ctx)
  local pickV = nil
  ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
  local used, first = 0, true
  for _, v in ipairs(UI.versionsOfType(list, curType)) do
    local label = 'v' .. tostring(v.version_number or '?')
    local w = math.max(34, ImGui.CalcTextSize(ctx, label) + 20)
    if first then
      used, first = w, false
    elseif used + 6 + w <= avail then
      ImGui.SameLine(ctx, 0, 6)
      used = used + 6 + w
    else
      used = w   -- wrapped onto a new line
    end
    if UI.pill('##cpv_' .. tostring(v.id), label, cur and cur.id == v.id, w) then
      pickV = v
    end
  end
  ImGui.PopFont(ctx)

  -- What the studio called this one. Underneath rather than in the pill: a pill
  -- has to stay short enough that a run of them fits, and "final master v3" in
  -- every one of them would not.
  --
  -- The age used to stand beside it ("138 d") and is gone: next to a version
  -- number it reads like another number about the version rather than like a
  -- date, and nobody switching versions was asking how old this one is.
  if cur then
    local note = {}
    if cur.label and cur.label ~= '' then note[#note+1] = tostring(cur.label) end
    if cur.locked == 1 then note[#note+1] = 'locked by the studio plan' end
    if #note > 0 then
      ImGui.Dummy(ctx, 0, 4)
      ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
      if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 0) end
      ImGui.TextDisabled(ctx, table.concat(note, '  \u{b7}  '))
      if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
      ImGui.PopFont(ctx)
    end
  end
  ImGui.Dummy(ctx, 0, 6)
  if pickV then UI.switchVersion(pickV) end
  return paired
end

-- Lazy-load the persisted waveform for the current binding if we don't yet
-- have one in memory for it (e.g. right after the window was reopened without
-- a fresh sync).
function UI.ensureWaveform()
  if not state.boundProductionId then return end
  if state.waveform and state.waveformForId == state.boundProductionId then return end
  local cached = loadWaveformCache(state.boundProductionId)
  if cached then
    state.waveform = { peaks = cached.peaks or {}, duration = cached.duration }
    if type(cached.metrics) == 'table' then state.metrics = cached.metrics end
    if cached.filename and not state.versionFilename then
      state.versionFilename = cached.filename
    end
    if cached.version_id and not state.versionId then
      state.versionId = cached.version_id
    end
  else
    state.waveform = nil
  end
  state.waveformForId = state.boundProductionId
end

-- Collapsible waveform block: draws the ~150-point peak strip for the active
-- version, overlays the artist comment markers (hover to read) and the live
-- DAW play/edit cursor. Click the strip to move the DAW cursor (and seek
-- playback) to that spot. A small transport row offers Play/Pause + Stop.
--
-- Time mapping (kept in lock-step with syncCommentsToMarkers): a comment at
-- audio-time T is placed at internal Reaper position `T - offset`, where
-- `offset = getProjectStartOffset()`. So:
--     audio_time   = internal_pos + offset
--     internal_pos = audio_time   - offset
function UI.waveform()
  -- No collapsing header any more. The waveform is the reason this screen
  -- exists, so it is always open; a header that could hide it only offered a
  -- way to make the window less useful, and it put a second "Waveform" label
  -- above a card that is already about one track.
  UI.ensureWaveform()
  local wf       = state.waveform
  local peaks    = wf and wf.peaks or {}
  local duration = wf and wf.duration or nil

  if #peaks == 0 then
    ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
    ImGui.TextDisabled(ctx, 'No waveform stored for this version yet.')
    ImGui.TextDisabled(ctx, 'Upload a version in CuePort, then Sync again.')
    ImGui.PopFont(ctx)
    return
  end

  local comments = loadCommentsCache()
  local offset   = getProjectStartOffset()
  local playState = r.GetPlayState()
  local playing   = (playState & 1) == 1
  local paused    = (playState & 2) == 2

  -- ── Waveform strip (clickable) ──────────────────────────────────────────
  -- The strip comes first now: it is the thing to look at, and the transport
  -- reads better underneath it than above it, the way a player does.
  local w = ImGui.GetContentRegionAvail(ctx)
  if not w or w < 40 then w = 40 end
  local h = 96
  local clicked = ImGui.InvisibleButton(ctx, '##cpwavehit', w, h)
  local x0, y0  = ImGui.GetItemRectMin(ctx)
  local x1, y1  = ImGui.GetItemRectMax(ctx)
  local hovered = ImGui.IsItemHovered(ctx)

  local dl = ImGui.GetWindowDrawList(ctx)
  -- The strip lives inside the production card now, so it must not cast a
  -- shadow of its own -- a card floating on a card is one layer too many. It
  -- reads as recessed instead: a surface darker than the card it sits in, with
  -- the top inner edge a shade darker still, which is where a real inset
  -- catches its own shadow.
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, CP_COLORS.waveWell, 8)
  ImGui.DrawList_AddLine(dl, x0 + 8, y0 + 1, x1 - 8, y0 + 1, CP_COLORS.waveWellTop, 1)
  ImGui.DrawList_AddRect(dl, x0, y0, x1, y1, CP_COLORS.waveWellEdge, 8)

  local pad     = 8
  local innerX0 = x0 + pad
  local innerW  = (x1 - pad) - innerX0
  if innerW < 1 then innerW = 1 end
  local midY    = y0 + h / 2
  local maxHalf = (h / 2) - pad - 4      -- room for the marker pins on top
  local n       = #peaks

  -- Where the play cursor sits, as a fraction of the strip. Everything left of
  -- it is drawn in the brand colour, everything right of it stays muted — the
  -- progress is then readable from the waveform itself, not just from the
  -- cursor line.
  local playFrac = nil
  if duration and duration > 0 then
    local pos = playing and r.GetPlayPosition() or r.GetCursorPosition()
    local f   = (pos + offset) / duration
    if f >= 0 and f <= 1 then playFrac = f end
  end

  -- Centre line, so quiet passages still read as audio rather than emptiness.
  ImGui.DrawList_AddLine(dl, innerX0, midY, innerX0 + innerW, midY, CP_COLORS.rowSep, 1)

  -- Bars: rounded, with a gap, mirrored around the centre.
  local slot = innerW / n
  local bw   = math.max(1.5, math.min(3.0, slot * 0.62))
  for i = 1, n do
    local p = peaks[i] or 0
    if p < 0 then p = 0 elseif p > 1 then p = 1 end
    local cx   = innerX0 + ((i - 0.5) / n) * innerW
    local half = p * maxHalf
    if half < 1.5 then half = 1.5 end
    local col = CP_COLORS.waveIdle
    if playFrac and ((i - 0.5) / n) <= playFrac then col = CP_COLORS.accent end
    ImGui.DrawList_AddRectFilled(dl, cx - bw / 2, midY - half, cx + bw / 2, midY + half,
                                 col, bw / 2)
  end

  -- Comment markers on top — only when we know the track length.
  local hoverMarker, hoverMarkerKey = nil, nil
  local mx          = ImGui.GetMousePos(ctx)
  if duration and duration > 0 then
    local bestD = 7  -- px hit radius
    for i, c in ipairs(comments) do
      local ts = c.timestamp
      -- Replies carry their parent's time, so a pin for each would stack them
      -- on the same pixel and light together. One pin per thread; the answers
      -- are read in the list beside it.
      if ts and not c.parent_id then
        local frac = ts / duration
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        -- Snapped to the pixel grid: a 1 px line at a fractional x is spread
        -- over two columns by anti-aliasing while the dot lands on the exact
        -- centre, and the dot then reads as sitting beside its own stem.
        -- Half-pixel centre = one full column for a 1 px line.
        local cx = math.floor(innerX0 + frac * innerW) + 0.5
        local near = hovered and math.abs(mx - cx) < bestD
        -- Lit from the other side: the mouse is over this comment's row in the
        -- list. Deliberately NOT folded into `near` -- that one also decides
        -- which comment gets the tooltip, and a tooltip popping up out on the
        -- strip while the mouse is over in the list would follow nothing.
        local lit = near or (state.hoverRowCommentId ~= nil
                             and UI.commentKey(c, i) == state.hoverRowCommentId)
        -- A thin stem with a dot on top reads as a pin without cutting the
        -- waveform in half the way a full-height line did.
        --
        -- A rectangle, NOT AddLine: AddLine shifts both of its endpoints by
        -- (0.5, 0.5) before stroking, so a line handed x lands half a pixel to
        -- the right of it while the dot -- AddCircleFilled adds nothing -- stays
        -- put. That half pixel is what "the dot sits beside its own stem" is. A
        -- filled rect has no hidden offset: this covers exactly the column
        -- [cx-0.5, cx+0.5], centred on the same cx the dot uses.
        -- Amber for the artist, purple for the studio -- the same reading the
        -- web player gives, and the reason the strip can be glanced at at all:
        -- with one colour for everyone it said only "somebody said something".
        local tLit, tDot, tStem = UI.commentTint(c)
        ImGui.DrawList_AddRectFilled(dl, cx - 0.5, y0 + 7, cx + 0.5, y1 - 4,
                               lit and tLit or tStem)
        ImGui.DrawList_AddCircleFilled(dl, cx, y0 + 7, lit and 4.5 or 3.5,
                               lit and tLit or tDot)
        if near then
          bestD = math.abs(mx - cx)
          hoverMarker, hoverMarkerKey = c, UI.commentKey(c, i)
        end
      end
    end
  end

  -- Live DAW play/edit cursor on top of everything.
  if playFrac then
    -- Whole pixel, and two columns wide so the stroke sits evenly either side
    -- of it. Same reason as the pin above for the rectangle: AddLine would move
    -- the stroke half a pixel right of cx while the triangle stayed on cx, and
    -- that is exactly what "the arrow is not centred on the cursor" looks like.
    local cx = math.floor(innerX0 + playFrac * innerW + 0.5)
    ImGui.DrawList_AddRectFilled(dl, cx - 1, y0 + 3, cx + 1, y1 - 3, 0xFFFFFFEE)
    ImGui.DrawList_AddTriangleFilled(dl, cx - 4, y1 - 3, cx + 4, y1 - 3, cx, y1 - 9, 0xFFFFFFEE)
  end

  -- Click/drag the strip → move the DAW cursor there. While dragging, the
  -- edit cursor follows live (no replay jump); on release we also seek
  -- playback so a playing transport jumps to the clicked spot in sync.
  local active = ImGui.IsItemActive(ctx)
  if duration and duration > 0 and (active or clicked) then
    local frac = (mx - innerX0) / innerW
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local internalPos = (frac * duration) - offset   -- audio time → internal
    r.SetEditCurPos(internalPos, true, clicked)       -- moveview; seekplay on release
    if clicked then
      -- During playback Reaper defers the actual jump to the next bar. Remember
      -- the target so we can show a faint "pending" line until the play cursor
      -- catches up; when stopped the move is immediate, so no marker is needed.
      state.pendingSeekAt = playing and (frac * duration) or nil
    end
  end

  -- Pending-seek line: faint mark at a clicked target the play cursor hasn't
  -- reached yet. Clears once the cursor lands there (or playback stops).
  if state.pendingSeekAt and duration and duration > 0 then
    if not playing then
      state.pendingSeekAt = nil
    else
      local curAudio = r.GetPlayPosition() + offset
      if math.abs(curAudio - state.pendingSeekAt) < 0.30 then
        state.pendingSeekAt = nil
      else
        local pf = state.pendingSeekAt / duration
        if pf >= 0 and pf <= 1 then
          local px = innerX0 + pf * innerW
          ImGui.DrawList_AddLine(dl, px, y0 + 1, px, y1 - 1, 0xFFFFFF55, 1.5)
        end
      end
    end
  end

  -- Remembered for the comment list, which highlights the same row.
  -- The key, not the raw id: the list looks the comment up the same way, and a
  -- cached row without an id would otherwise light every other id-less row.
  state.hoverCommentId = hoverMarkerKey
  if hoverMarker then
    ImGui.BeginTooltip(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
    ImGui.Text(ctx, (hoverMarker.author or 'Artist') .. '  ·  ' .. formatTimestamp(hoverMarker.timestamp or 0))
    ImGui.PopStyleColor(ctx)
    if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 320) end
    ImGui.Text(ctx, hoverMarker.text or '')
    if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
    ImGui.EndTooltip(ctx)
  end

  -- ── Transport + time, on one line under the strip ───────────────────────
  -- Two rows became one: the buttons on the left, the clock hard right where
  -- a transport always puts it.
  ImGui.Dummy(ctx, 0, 7)
  if UI.primaryButton(((playing and not paused) and 'Pause' or 'Play') .. '##wfplay', 84) then
    if playing and not paused then r.OnPauseButton() else r.OnPlayButton() end
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Stop##wfstop', 70, 0) then r.OnStopButton() end

  if duration and duration > 0 then
    -- Position on the left, total on the right, like any transport.
    local pos     = playing and r.GetPlayPosition() or r.GetCursorPosition()
    local atime   = pos + offset
    if atime < 0 then atime = 0 elseif atime > duration then atime = duration end
    ImGui.SameLine(ctx)
    local lx      = ImGui.GetCursorPosX(ctx)
    local avail   = ImGui.GetContentRegionAvail(ctx)
    ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
    local total   = formatTimestamp(duration)
    local elapsed = formatTimestamp(atime)
    -- Right-aligned as a pair, measured rather than guessed: "0:03 / 2:41"
    -- keeps the same right edge whatever the elapsed time reads.
    local pairW   = ImGui.CalcTextSize(ctx, elapsed .. '  /  ' .. total)
    -- A docker can be 300px wide, and there the buttons plus the clock do not
    -- fit on one line. Rather than letting the row run past the edge -- which
    -- is what lets the whole view be dragged sideways -- the clock drops to a
    -- line of its own, still right-aligned.
    if avail < pairW + 6 then
      if ImGui.NewLine then ImGui.NewLine(ctx) else ImGui.Dummy(ctx, 0, 0) end
      lx    = ImGui.GetCursorPosX(ctx)
      avail = ImGui.GetContentRegionAvail(ctx)
    end
    ImGui.SetCursorPosX(ctx, lx + math.max(0, avail - pairW))
    ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.text)
    ImGui.Text(ctx, elapsed)
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx, 0, 0)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.textDim)
    ImGui.Text(ctx, '  /  ' .. total)
    ImGui.PopStyleColor(ctx)
    ImGui.Dummy(ctx, 0, 2)
    local cnt = 0
    for _, c in ipairs(comments) do
      if c.timestamp and not c.parent_id then cnt = cnt + 1 end
    end
    ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.textDim)
    if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 0) end
    ImGui.Text(ctx, string.format('%d comment%s  \u{b7}  click to seek, hover a pin to read it',
      cnt, cnt == 1 and '' or 's'))
    if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
    ImGui.PopStyleColor(ctx)
    ImGui.PopFont(ctx)
  else
    ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
    ImGui.TextDisabled(ctx, 'Track length unknown, so the cursor and pins stay hidden. Re-upload the version in CuePort to store it.')
    ImGui.PopFont(ctx)
  end
end

-- A/B compare controls: load the CuePort version into a hidden reference track
-- and toggle between hearing it (straight to outputs 1/2) and the DAW mix.
function UI.abCompare()
  if not state.boundProductionId then return end
  ImGui.Dummy(ctx, 0, 6)

  if state.ab.downloading then
    ImGui.TextDisabled(ctx, 'Loading A/B reference… this can take a few seconds.')
    return
  end

  local loaded = state.ab.loaded and state.ab.forId == state.boundProductionId
                 and state.ab.forVersion == state.versionId
  if not loaded then
    if not state.versionFilename then
      ImGui.TextDisabled(ctx, 'A/B compare: press "Sync comments" once to enable it.')
      return
    end
    -- Width from the room there is, never a fixed number: a fixed 200 plus the
    -- caption beside it ran past the edge in a narrow docker, and anything
    -- wider than its window can be dragged sideways.
    local abAvail = ImGui.GetContentRegionAvail(ctx)
    local abCap   = 'your mix vs the CuePort version'
    local abW     = math.max(90, math.min(200, abAvail))
    if ImGui.Button(ctx, 'Load A/B compare', abW, 0) then
      state.ab.downloading = true
      state.ab.pendingLoad = true
      state.ab.frameShown  = false
      state.ab.status      = nil
    end
    -- The caption only shares the line while it fits whole; below that it goes
    -- underneath rather than pushing the row past the window edge.
    if (abAvail - abW - 8) >= ImGui.CalcTextSize(ctx, abCap) then
      ImGui.SameLine(ctx)
    end
    if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 0) end
    ImGui.TextDisabled(ctx, abCap)
    if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
    if state.ab.status then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.danger)
      if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 0) end
      ImGui.Text(ctx, state.ab.status)
      if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
      ImGui.PopStyleColor(ctx)
    end
    return
  end

  -- Loaded → both sources side by side, the one you are hearing filled in. The
  -- old single button described what it would switch to, which left the reader
  -- working out what they were hearing right now.
  local onCue = state.ab.onCuePort
  -- The switch takes the width it has, not a fixed 300: the "?" and "Remove"
  -- share the row, and a fixed width pushed the row past the window edge on a
  -- narrow window — which let the whole view be dragged sideways.
  -- Everything on this row is measured against the switch's height so the three
  -- controls sit on one centre line. "Remove" used to be a SmallButton nudged a
  -- pixel by hand: shorter than its neighbours and centred on nothing.
  local ROW_H  = 28
  local REM_H  = 22
  local remW   = ImGui.CalcTextSize(ctx, 'Remove') + 22
  local availW = ImGui.GetContentRegionAvail(ctx)
  local tailW  = 8 + 15 + 10 + remW
  local pick   = UI.segmented('##abswitch', { 'Your mix', 'CuePort version' },
                              onCue and 2 or 1,
                              math.max(60, math.min(300, availW - tailW)))
  if pick then AB.applyState(pick == 2) end
  ImGui.SameLine(ctx, 0, 8)
  local rowY = ImGui.GetCursorPosY(ctx)
  ImGui.SetCursorPosY(ctx, rowY + (ROW_H - 15) / 2)
  UI.help('##help_ab',
    'CuePort plays direct to outputs 1/2, bypassing your master chain, so the ' ..
    'finished bounce is heard untouched. The audio is stored in a "' ..
    K.AB_DIR_NAME .. '" folder next to the project, so saving the project while ' ..
    'A/B is loaded is safe.')
  ImGui.SameLine(ctx, 0, 10)
  ImGui.SetCursorPosY(ctx, rowY + (ROW_H - REM_H) / 2)
  if ImGui.Button(ctx, 'Remove##abremove', remW, REM_H) then AB.remove() end
end

function UI.bound()
  local p = state.boundProduction
  if not p then return end  -- defensive: caller only reaches here once resolved
  UI.section('Production')
  local card = UI.cardBegin('bound_prod')
    -- Before anything else on the card: it paints into the corner at the
    -- current line without moving the cursor, so it has to run while the
    -- cursor is still at the top of the card.
    -- Cover in the corner, the numbers to its left. Both paint into the draw list
    -- without moving the cursor, so the text below keeps flowing from the top.
    local artW, artBottom = 0, nil
    do
      local cx, cy = ImGui.GetCursorScreenPos(ctx)
      local availW = ImGui.GetContentRegionAvail(ctx)
      local tile   = K.ART_TILE
      if availW > tile * 3 then
        Art.tile(ImGui.GetWindowDrawList(ctx), p.id, p.cover_tag,
                 cx + availW - tile, cy, tile, true)
        artW = tile + 12
        artBottom = cy + tile
      end
    end
    local metricsW = UI.metricsCorner(artW) or 0
    -- Artist small and dim above, title as the headline: the track is what the
    -- eye should land on, not the label "Connected to:".
    --
    -- Wrapped short of the corner. Without this a long title runs straight under
    -- the numbers -- it did before the cover was there, and the tile makes the
    -- occupied strip wider, so it would happen sooner.
    local wrapAt = nil
    if ImGui.PushTextWrapPos then
      wrapAt = ImGui.GetCursorPosX(ctx) + ImGui.GetContentRegionAvail(ctx)
               - artW - (metricsW > 0 and metricsW + 14 or 0)
      ImGui.PushTextWrapPos(ctx, wrapAt)
    end
    ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.textDim)
    ImGui.Text(ctx, (p.artist_name or '-'):upper())
    ImGui.PopStyleColor(ctx)
    ImGui.PopFont(ctx)
    ImGui.PushFont(ctx, FONT_BOLD, K.FONT_LEAD)
    ImGui.Text(ctx, p.title or '?')
    ImGui.PopFont(ctx)
    if wrapAt then ImGui.PopTextWrapPos(ctx) end
    if p.feat and p.feat ~= '' then
      ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
      ImGui.TextDisabled(ctx, 'feat. ' .. p.feat)
      ImGui.PopFont(ctx)
    end

    ImGui.Dummy(ctx, 0, 9)
    -- A queued sync counts as in progress here: it is one frame away and the
    -- user has already pressed something.
    if state.syncInProgress or state.syncRequested then
      ImGui.TextDisabled(ctx, state.syncStatus or 'Syncing...')
    else
      -- Leave room for the "synced 5 min ago" note beside it rather than
      -- insisting on 200 px and pushing the card past the window edge.
      local syncAvail = ImGui.GetContentRegionAvail(ctx)
      local syncTail  = state.lastSyncAt
        and (10 + ImGui.CalcTextSize(ctx, UI.relTime(state.lastSyncAt))) or 0
      -- The upload button shares this line when there is room for it. The card
      -- had a whole row of its own for it with the cover sitting above an empty
      -- half -- one row spent on one button, and the space beside it wasted.
      if UI.primaryButton('Sync comments##dosync',
                          math.max(90, math.min(200, syncAvail - syncTail))) then doSync() end
      if state.lastSyncAt then
        ImGui.SameLine(ctx, 0, 10)
        ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
        ImGui.TextDisabled(ctx, UI.relTime(state.lastSyncAt))
        ImGui.PopFont(ctx)
      end
    end

    if state.lastSyncResult and state.syncStatus and state.syncStatus ~= '' then
      ImGui.Dummy(ctx, 0, 5)
      ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
      if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 0) end
      ImGui.TextDisabled(ctx, state.syncStatus)
      if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
      ImGui.PopFont(ctx)
    end
    -- The way to a new version, from the place the producer is already in when
    -- he has finished working the feedback off. One entry, not two: both ways
    -- of getting a file up there answer the same three questions, and a second
    -- door would be a second place to ask them.
    --
    -- A line of its own only when it did not fit beside Sync. Two buttons that
    -- insist on a width are how a narrow docker starts scrolling sideways, so
    -- the pairing above is measured rather than assumed.

    -- The cover paints into the corner without moving the cursor, so nothing
    -- reserves its height. Since it is taller than the artist + title + button
    -- column beside it, the hairline below would otherwise cut straight through
    -- the picture. Push the cursor down to the bottom edge of the tile first.
    if artBottom then
      local _, curY = ImGui.GetCursorScreenPos(ctx)
      if type(curY) == 'number' and curY < artBottom then
        ImGui.Dummy(ctx, 0, artBottom - curY)
      end
    end
    -- ── Waveform + A/B, inside the same card ──────────────────────────────
    -- One card, not three stacked boxes: the title, the waveform and the A/B
    -- switch are all about the same track, and a border between them said
    -- otherwise. A hairline does the separating instead, which groups without
    -- boxing.
    ImGui.Dummy(ctx, 0, 11)
    -- Above the rule, with the title and the sync button: which version is open
    -- is a fact about the production, and the rule separates that from the
    -- player below it.
    -- The way to a new version, beside the kind switcher. That line is the
    -- first one below the cover -- the cursor has already been pushed past its
    -- bottom edge above -- so the right-hand half of the card is genuinely
    -- free there, which it is not on the sync row further up.
    local upW = ImGui.CalcTextSize(ctx, K.UPLOAD_BTN) + 30
    state.uploadBtnPaired = UI.versionRow(function()
      if ImGui.Button(ctx, K.UPLOAD_BTN .. '##goupload', upW, 0) then
        state.screen = 'upload'
      end
    end, upW)
    -- A line of its own when there was no room beside the switcher, or no
    -- switcher at all -- a production with nothing uploaded yet draws none, and
    -- that is precisely the one a first render goes to. AFTER the row, not
    -- before it: asked earlier this would read the previous frame's answer and
    -- both would draw.
    if not state.uploadBtnPaired then
      if ImGui.Button(ctx, K.UPLOAD_BTN .. '##goupload2',
                      math.max(150, math.min(220, ImGui.GetContentRegionAvail(ctx))), 0) then
        state.screen = 'upload'
      end
      ImGui.Dummy(ctx, 0, 7)
    end
    do
      local rx, ry = ImGui.GetCursorScreenPos(ctx)
      local rw     = ImGui.GetContentRegionAvail(ctx)
      if rw and rw > 0 then
        ImGui.DrawList_AddLine(ImGui.GetWindowDrawList(ctx),
          rx, ry, rx + rw, ry, CP_COLORS.rowSep, 1)
      end
    end
    ImGui.Dummy(ctx, 0, 11)
    UI.waveform()
    UI.abCompare()
  UI.cardEnd(card)

  -- ── Render-start anchor section ─────────────────────────────────────────
  -- Lets the user tell Reaper where the render starts (== ruler 0:00) so
  -- that comment timestamps land at the correct ruler positions.
  UI.section('Align markers with your render')
  card = UI.cardBegin('bound_align')
    -- The explanation sits behind a "?" like every description in Settings, so
    -- the card is a row to scan instead of a paragraph to read.
    -- Read first: the offset only belongs in the explanation once our own
    -- marker is really on the ruler.
    local isSet = UI.renderStartSet()
    local HELP_ALIGN =
      'Move the edit cursor to the exact start of your rendered audio and press ' ..
      '"Set render start at cursor". CuePort shifts the ruler so that position ' ..
      'becomes 0:00 and drops a visible marker there, which is what makes the ' ..
      'comment timestamps land in the right place. "Clear" undoes it.'
    if isSet then
      -- Was a green line under the card. It said "is set" whenever Reaper
      -- reported any offset at all -- including one a project template brought
      -- along that nobody asked for -- so it could claim the markers were
      -- anchored while the button beside it was still pulsing for attention.
      -- Now it hangs off the marker, and it lives behind the "?" with the rest
      -- of the explanation rather than as a permanent line of status.
      HELP_ALIGN = HELP_ALIGN .. string.format(
        '\n\nCurrently set: the ruler is offset by %+.2fs.', getProjectStartOffset())
    end

    -- Widths come from the space there is, never from a fixed number: a fixed
    -- 240 plus "Clear" ran past the edge on a narrow window, and anything wider
    -- than its window can be dragged sideways.
    local availA = ImGui.GetContentRegionAvail(ctx)
    -- Both are ordinary buttons now: a SmallButton next to a Button is shorter
    -- by its own frame padding, and the pair read as two different controls.
    local clearW = ImGui.CalcTextSize(ctx, 'Clear') + 22
    -- Label, its "?", and the check when there is one -- all three, or the row
    -- claims more room for the buttons than it has and the pair runs past the
    -- card edge on a narrow window.
    local labelW = ImGui.CalcTextSize(ctx, 'Render start') + 6 + 15 + (isSet and (6 + 13) or 0)
    local btnW   = math.max(80, math.min(240, availA - clearW - 8 - labelW - 12))
    -- Label and buttons share a line while there is room; below that the
    -- buttons drop under the label and keep their width.
    local oneLine = (labelW + 12 + btnW + 8 + clearW) <= availA

    local function alignButtons()
      -- Until a render start is set the markers cannot land in the right place,
      -- so the button asks for attention: a slow pulse between the two brand
      -- purples. Once it is set it goes quiet and looks like any other button.
      local pulsed = 0
      if not isSet then
        local t = (math.sin(r.time_precise() * 3.2) + 1) / 2
        ImGui.PushStyleColor(ctx, ImGui.Col_Button(),        UI.mix(CP_COLORS.accentStrong, CP_COLORS.accent, t))
        ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered(), CP_COLORS.accent)
        ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive(),  CP_COLORS.accentStrong)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text(),          0xFFFFFFFF)
        pulsed = 4
      end
      local go = ImGui.Button(ctx, 'Set render start at cursor', btnW, K.BTN_H)
      if pulsed > 0 then ImGui.PopStyleColor(ctx, pulsed) end
      if go then
        local ok, err = setRenderStartAtCursor()
        if ok then
          state.errorMsg = nil
          -- Move the A/B reference with the new offset so it stays aligned.
          AB.reposition()
          state.rsSet = nil            -- re-read the marker on the next frame
          -- Re-place the markers from the cached comments. No request, so the
          -- ruler is right before the click has finished. Only a project that
          -- has never synced falls back to fetching.
          if not realignMarkers() then queueSync() end
        else
          state.errorMsg = err or 'Could not set render start.'
        end
      end
      ImGui.SameLine(ctx, 0, 8)
      -- Same kind of button and the same height as its neighbour, so the pair
      -- reads as one control group.
      if ImGui.Button(ctx, 'Clear', clearW, K.BTN_H) then
        clearRenderStart()
        AB.reposition()
        state.rsSet = nil
        if not realignMarkers() then queueSync() end
      end
    end

    -- Shown only once our own marker is really on the ruler, which is also the
    -- moment the button stops pulsing. The two never disagree.
    local mark = isSet and function() UI.tick() end or nil
    if oneLine then
      UI.row('Render start', HELP_ALIGN, btnW + 8 + clearW, alignButtons, mark, K.BTN_H)
    else
      UI.row('Render start', HELP_ALIGN, 0, nil, mark)
      ImGui.Dummy(ctx, 0, 6)
      alignButtons()
    end

  UI.cardEnd(card)
  -- Switching production is in the menu now ("Change production"), which keeps
  -- this screen to the production itself.
end

-- ══════════════════════════════════════════════════════════════════════════════
-- UPLOAD SCREEN — send a render to CuePort as a new version
-- ══════════════════════════════════════════════════════════════════════════════
--
-- One entry, from the player, because both ways out of here answer the same
-- three questions (which kind, notify or not, keep the bounce or not). Two
-- entries would be two places asking the same thing.
K.UPLOAD_BTN = 'Upload new version'
K.UP_SRC_LABELS = { 'Master mix', 'Via master', 'Stems' }
K.UP_SRC_KEYS   = { 'master', 'viamaster', 'stems' }

function UI.uploadDefaults()
  local u = state.up
  if u then return u end
  u = {
    bounds = 'project', source = 'master',
    notify = true, keepRender = true, setStart = true,
    trackType = nil, mode = nil, file = nil, fileInfo = nil,
  }
  state.up = u
  return u
end

-- Which kind a new version would be. Prefilled from what the player has open,
-- because that is what he was just listening to -- but BOTH are pressable here,
-- unlike in the player. Two cases the prefill cannot cover: a production with no
-- versions at all (the player draws no switch), and the first instrumental of a
-- production (in the player that kind is dimmed, which is right for listening
-- and wrong for uploading).
function UI.uploadType()
  local u = UI.uploadDefaults()
  if u.trackType then return u.trackType end
  local cur = UI.activeVersion()
  if cur and cur.track_type then return cur.track_type end
  return 'mixmaster'
end

-- What the new version will be called, asked of the versions we already know
-- about. The server assigns the real number when the upload starts -- this is
-- the preview, and it says so by being a preview rather than by being right.
function UI.uploadNextNumber(trackType)
  local list = state.versions or {}
  local mx = 0
  for _, v in ipairs(list) do
    if v.track_type == trackType then
      local n = tonumber(v.version_number) or 0
      if n > mx then mx = n end
    end
  end
  return mx + 1
end

function UI.uploadTargetLine()
  local p = state.boundProduction
  local tt = UI.uploadType()
  return ('%s  \u{2192}  %s v%d'):format(
    (p and p.title) or '?', UI.versionTypeLabel(tt), UI.uploadNextNumber(tt))
end

-- The file picker. GetUserFileNameForRead is native, so this adds no dependency
-- -- JS_ReaScriptAPI would only give a prettier dialog and is optional here.
function UI.uploadPickFile()
  if not r.GetUserFileNameForRead then return end
  local ok, path = r.GetUserFileNameForRead(Rnd.outDir() .. pathSep(),
                                            'Choose the file to upload', '')
  if not ok or not path or path == '' then return end
  local u = UI.uploadDefaults()
  if state.upload and (state.upload.phase == 'done' or state.upload.phase == 'error') then
    state.upload = nil
  end
  UI.uploadUseFile(path)
  if u.file and not u.fileError then
    -- Same reason the render is armed rather than run: reading the peaks
    -- blocks, and doing it inside the frame the button was pressed on freezes
    -- the window with an unpressed-looking button on it.
    u.status = 'Reading the waveform...'
    u.pending, u.frameShown = 'peaks', false
  end
end

-- Everything shown under the button is read off the FILE, not off the render
-- dialog: this is also the check on the result, and a mono plugin at the end of
-- the chain does not announce itself in any setting.
function UI.uploadUseFile(path)
  local u = UI.uploadDefaults()
  u.file = path
  u.fileInfo = Rnd.inspect(path)
  -- A waveform belongs to one file. Carrying the previous one over would draw
  -- the shape of the last render over the name of this one, which is the single
  -- most convincing way to be wrong.
  u.peaks = nil
  local errs, warns = Rnd.check(u.fileInfo)
  u.fileError = errs[1]
  u.warnings = warns
end

-- The one thing that cannot be taken back after pressing: which version this
-- becomes. Nothing is overwritten, ever -- every upload is a new version, the
-- same as in the browser.
-- Pressed. Everything that can be answered without doing anything is answered
-- here, so the reason for a refusal appears on the frame he pressed on; the
-- work itself is armed and happens one frame later.
--
-- Why not straight away: a render BLOCKS -- 0.23 s for two seconds of audio,
-- minutes for a long project -- and doing that inside the frame that is being
-- drawn means Reaper freezes with the old screen still up, showing a button
-- that looks unpressed. Same shape as the A/B load: let one frame paint, then
-- go. Reading the peaks blocks too, if only briefly.
function UI.uploadStart(mode)
  local u = UI.uploadDefaults()
  if not state.boundProduction then return end
  u.warnings = nil
  -- A finished or failed upload is history the moment a new file is being made.
  -- Left standing it would keep the veil's idea of "working" and the page's
  -- idea of "done" alive at the same time.
  if mode ~= 'send' and state.upload
     and (state.upload.phase == 'done' or state.upload.phase == 'error') then
    state.upload = nil
  end

  if mode == 'render' then
    if u.bounds == 'timesel' and not Rnd.timeSelection() then
      u.status = 'Nothing is selected in the timeline, so a time-selection render would write no file.'
      return
    end
    -- A render no longer sends. It makes the file and stops, so the producer
    -- gets to see what he made before it leaves the machine.
    u.file, u.fileInfo, u.fileError, u.peaks = nil, nil, nil, nil
    u.status = 'Rendering...'
  elseif not u.file or u.fileError then
    u.status = u.fileError or 'Choose a file first.'
    return
  end
  u.pending, u.frameShown = mode, false
end

-- One frame later, from the loop.
function UI.uploadPump()
  local u = state.up
  if not u or not u.pending then return end
  if not u.frameShown then u.frameShown = true; return end
  local mode = u.pending
  u.pending, u.frameShown = nil, false

  local p = state.boundProduction
  if not p then return end
  local tt = UI.uploadType()

  if mode == 'render' then
    local expect = nil
    if u.bounds == 'timesel' then
      local s, len = Rnd.timeSelection()
      if not s then
        u.status = 'Nothing is selected in the timeline, so a time-selection render would write no file.'
        return
      end
      expect = len
    end
    local ok, info, warns = Rnd.run({
      bounds = u.bounds, source = u.source, expectSec = expect,
      versionKey = state.boundProductionId,
    })
    if not ok then u.status = tostring(info); return end
    u.warnings = warns
    -- Only now, and only for a render we actually made: shifting the ruler for
    -- a run that failed would move his project for nothing.
    --
    -- Both kinds of render, and zero is a position like any other: a render
    -- from the top of the project puts the ruler back to 0:00, which is the
    -- case that used to be skipped and left the offset of the render before it
    -- standing.
    if u.setStart then
      local startAt = 0
      if u.bounds == 'timesel' then startAt = Rnd.timeSelection() or 0 end
      setRenderStartAt(startAt)
    end
    UI.uploadUseFile(info.path)
    -- Read here rather than at send time: the strip over the result card is
    -- what makes this state worth stopping in, and reading it blocks -- doing
    -- that while the window says "Rendering..." is the one moment it is free.
    UI.uploadReadPeaks()
    u.status = nil
    return
  end

  if mode == 'peaks' then UI.uploadReadPeaks(); u.status = nil; return end
  if mode ~= 'send' then u.status = nil; return end

  if not u.file or u.fileError then
    u.status = u.fileError or 'Choose a file first.'
    return
  end
  local info = u.fileInfo or {}
  if type(u.peaks) ~= 'table' or #u.peaks == 0 then UI.uploadReadPeaks() end
  Up.begin({
    path = u.file, productionId = state.boundProductionId, trackType = tt,
    title = p.title, notify = u.notify, keepRender = u.keepRender,
    duration = info.length,
    waveform = u.peaks,
  })
  u.status = nil
end

-- The 150 numbers that travel with the file, read once and kept. Blocking, and
-- named as such: it is a pass over every sample of the render.
function UI.uploadReadPeaks()
  local u = UI.uploadDefaults()
  u.peaks = nil
  if not u.file or u.fileError then return end
  local info = u.fileInfo or {}
  local ok, pk = pcall(Rnd.peaks, u.file, info.length)
  if ok and type(pk) == 'table' and #pk > 0 then u.peaks = pk end
end

-- ── the render settings, said in one sentence ─────────────────────────────
--
-- Eight controls in a table answer "what can I set". Nobody asks that. The
-- question in front of a render is "does this go out the way I want", and that
-- is one sentence. The table is still there, one press away, for the times the
-- answer is no.
--
-- Returns text, isWarning. The warning case is the one that has to be right:
-- a summary that says "Time selection 0:00 to 0:08" while nothing is selected
-- would be worse than no summary at all -- it would be a claim.
function UI.renderSummary()
  local u = UI.uploadDefaults()
  local src = 'Master mix'
  for i, k in ipairs(K.UP_SRC_KEYS) do
    if k == u.source then src = K.UP_SRC_LABELS[i] end
  end
  if u.bounds ~= 'timesel' then
    return 'The whole project, from 0:00 \u{00b7} ' .. src, false
  end
  local selStart, selLen = Rnd.timeSelection()
  if not selStart then
    return 'Time selection \u{2014} but nothing is selected in the timeline, so ' ..
           'this would write no file.', true
  end
  local line = ('Time selection %s to %s (%s) \u{00b7} %s'):format(
    formatTimestamp(selStart), formatTimestamp(selStart + selLen),
    formatTimestamp(selLen), src)
  if selStart > 0 and u.setStart then line = line .. ' \u{00b7} 0:00 = render start' end
  return line, false
end

-- "Mix Master v3" -- the kind plus the number this upload WOULD become. The
-- number is the highest one this kind already has plus one; with no versions
-- list to go on the kind stands alone, because a guessed number on the one line
-- that says what is about to happen is worse than no number.
function UI.uploadTargetVersion()
  local tt = UI.uploadType()
  local label = UI.versionTypeLabel(tt)
  local best = nil
  for _, v in ipairs(UI.versionsFor() or {}) do
    if v.track_type == tt then
      local n = tonumber(v.version_number)
      if n and (not best or n > best) then best = n end
    end
  end
  if not best then return label end
  return label .. ' v' .. tostring(best + 1)
end

-- There is a file and it passed the checks. Says nothing about whether it has
-- been sent -- the card that shows it stays up either way, because a render
-- that vanishes the moment it is uploaded takes the only proof of what was sent
-- with it.
function UI.uploadHasFile()
  local u = state.up
  return (u and u.file and not u.fileError) and true or false
end

-- This exact file has already gone up. Not "an upload happened": the name is
-- compared, so a fresh render or another pick clears it by being a different
-- file, and a second press on the same one cannot.
function UI.uploadSent()
  local u = state.up
  if not u or not u.file then return false end
  return u.sentFile ~= nil and u.sentFile == u.file
end

-- Pressable. There is a file, it has not been sent, and nothing is in flight.
--
-- Sending the same file twice is refused rather than made to replace anything.
-- Every upload is a new version, in the browser and here -- so a second press
-- would not correct the first, it would add a second identical version next to
-- it, and the artist would have two things to listen to where there is one.
-- Render again and the file changes; then it is a real second version and this
-- opens up by itself.
function UI.uploadReady()
  local u = state.up
  if not UI.uploadHasFile() then return false end
  if UI.uploadSent() then return false end
  if state.upload then return false end
  return (u ~= nil) and not u.pending
end

-- How tall the strip may be this frame.
--
-- The trick is what it is measured against. Shrinking it by however much does
-- not fit would oscillate: shrink, it fits, grow back, it does not, shrink. So
-- the page height WITHOUT the strip is what is worked from, and that number
-- does not move when the strip does. `state.bodyAvailH` is taken from the outer
-- body, which does not resize itself to its contents -- asking the inner one
-- would be the same feedback loop one level up.
function UI.uploadWaveH()
  local avail = tonumber(state.bodyAvailH) or 0
  if avail <= 0 then state.upWaveH = K.UP_WAVE_H; return K.UP_WAVE_H end

  -- The height of this strip is the one number on the page that is allowed to
  -- move, and getting it to hold still took three attempts. What follows is the
  -- reasoning, because the two wrong versions both looked right.
  --
  -- (1) Work "the page without the strip" out of the measured page height every
  --     frame and derive the strip from it. On paper the strip cancels out and
  --     the number is a fixed point. On the machine it was not: a screen
  --     recording showed the last button jumping between three positions on
  --     every frame. Frame-differencing that recording put the first changed
  --     pixel exactly at the top of the strip, so the strip was the thing
  --     moving, and everything under it went along.
  --
  -- (2) Key the height on the geometry of the window instead, measure once per
  --     geometry, then latch. Right idea, wrong key: it used the content
  --     region's WIDTH as part of it, and that width is not independent of the
  --     page. When the page is too tall the body grows a scrollbar, which takes
  --     the width down; the key changes, the strip resets to full height, the
  --     page gets taller still, the strip shrinks, the page fits, the scrollbar
  --     goes, the width comes back, the key changes again. The loop I thought I
  --     had cut, re-tied one level up.
  --
  -- (3) This one. The key is the available HEIGHT alone, quantised, and a
  --     vertical scrollbar does not change a height. Rounded to steps of 8 so a
  --     pixel of wobble cannot re-key. Within one key the strip is measured
  --     exactly once and then never reads anything the page produced again.
  local key = math.floor(avail / 8)
  if state.upFixedKey ~= key then
    state.upFixedKey, state.upFixedH = key, nil
    state.upWaveH = K.UP_WAVE_H
    return K.UP_WAVE_H
  end
  if not state.upFixedH then
    -- Only a page that was drawn WITH a full-height strip can tell us what the
    -- rest of it costs.
    local pageH = tonumber(state.upPageH) or 0
    if pageH <= 0 or (tonumber(state.upWaveH) or 0) < K.UP_WAVE_H then
      state.upWaveH = K.UP_WAVE_H
      return K.UP_WAVE_H
    end
    state.upFixedH = pageH - K.UP_WAVE_H
  end

  local want = avail - state.upFixedH - K.UP_TAIL
  if want > K.UP_WAVE_H   then want = K.UP_WAVE_H   end
  if want < K.UP_WAVE_MIN then want = K.UP_WAVE_MIN end
  state.upWaveH = want
  return want
end

-- The waveform of the file that is about to go up, drawn from the same 150
-- numbers that travel with it. Not decoration: eight seconds instead of three
-- minutes, or a mix that fell silent halfway, is visible here and nowhere else.
function UI.filePeaks(h)
  local u = UI.uploadDefaults()
  local pk = u.peaks
  local w = ImGui.GetContentRegionAvail(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  if type(pk) ~= 'table' or #pk == 0 then
    -- No peaks is a fact, not a blank: say so rather than draw a flat line the
    -- artist would read as silence.
    ImGui.Dummy(ctx, 0, 4)
    UI.slot(1, { 'No waveform could be read from this file.' })
    return
  end
  local n = #pk
  local step = w / n
  local bw = math.max(1, math.floor(step) - 1)
  local mid = y + h / 2
  for i = 1, n do
    local v = tonumber(pk[i]) or 0
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    local bh = math.max(1, v * (h / 2 - 1))
    local bx = x + (i - 1) * step
    ImGui.DrawList_AddRectFilled(dl, bx, mid - bh, bx + bw, mid + bh,
                                 UI.peakTint(v), 1)
  end
  ImGui.Dummy(ctx, w, h)
end

-- Exactly `n` lines of lead-font text, wrapped by hand. Same reason as
-- UI.slotWrap: the point is the fixed height, not the wrapping.
function UI.leadLines(n, text)
  ImGui.PushFont(ctx, FONT_BOLD, K.FONT_LEAD)
  local w  = ImGui.GetContentRegionAvail(ctx)
  local ls = UI.wrapLines(text, w, n)
  for i = 1, n do
    if ls[i] then ImGui.Text(ctx, ls[i]) else ImGui.Dummy(ctx, 0, UI.lineH()) end
  end
  ImGui.PopFont(ctx)
end

-- A line of text centred inside a block of exactly `h`, painted rather than laid
-- out. Nothing here is an item, so the block costs `h` and not a pixel more --
-- which is what lets the empty state and the waveform be the same height.
function UI.hintIn(h, text)
  local w = ImGui.GetContentRegionAvail(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local lh = UI.lineH()
  ImGui.PushFont(ctx, FONT, K.FONT_SMALL)
  local tw = ImGui.CalcTextSize(ctx, text) or 0
  if tw > w then text = UI.ellipsisEnd(text, w); tw = ImGui.CalcTextSize(ctx, text) or 0 end
  ImGui.DrawList_AddText(dl, x + math.max(0, (w - tw) / 2),
                         y + math.max(0, (h - lh) / 2), CP_COLORS.textDim, text)
  ImGui.PopFont(ctx)
  ImGui.Dummy(ctx, w, h)
end

-- Louder reads brighter. One expression, so the strip cannot drift apart from
-- itself the way two call sites would.
function UI.peakTint(v)
  local a = 0x66 + math.floor(v * 0x99)
  if a > 0xFF then a = 0xFF end
  return (CP_COLORS.accent & 0xFFFFFF00) | a
end

-- The line under the title: everything that is TRUE about the file, read off
-- the file itself rather than off the settings that were supposed to make it.
function UI.fileFacts()
  local u = UI.uploadDefaults()
  local fi = u.fileInfo or {}
  local bits = {}
  if (fi.ext or '') ~= '' then bits[#bits+1] = fi.ext:upper() end
  if (fi.channels or 0) > 0 then
    bits[#bits+1] = (fi.channels == 1) and 'mono' or
                    ((fi.channels == 2) and 'stereo' or (tostring(fi.channels) .. ' ch'))
  end
  if (fi.srate or 0) > 0 then bits[#bits+1] = ('%g kHz'):format(fi.srate / 1000) end
  if (fi.length or 0) > 0 then bits[#bits+1] = formatTimestamp(fi.length) end
  if (fi.bytes or 0) > 0 then bits[#bits+1] = ('%.1f MB'):format(fi.bytes / 1048576) end
  return table.concat(bits, '  \u{00b7}  ')
end

function UI.upload()
  local u = UI.uploadDefaults()
  local p = state.boundProduction
  if not p then state.screen = 'main'; return end
  local up = state.upload

  -- Latch the fact that THIS file went up, and what it became. Kept on the page
  -- rather than read off state.upload every frame, because state.upload is
  -- cleared the moment the next render starts and the stamp has to outlive that
  -- -- otherwise pressing Render would quietly un-say "this was sent".
  -- Keyed on the upload itself, not on the file name. Keyed on the name it
  -- would re-stamp: leave a finished upload standing, render again, and the NEW
  -- file would be marked as sent without ever having gone anywhere.
  if up and up.phase == 'done' and u.file and u.sentFor ~= up then
    u.sentFor = up
    u.sentFile = u.file
    u.sentNotified = up.notified and true or false
    local v = up.version
    u.sentVersion = (v and v.version_number)
      and (UI.versionTypeLabel(v.track_type or UI.uploadType()) .. ' v' .. v.version_number)
      or nil
    -- The list this page counts from is the one fetched at the last sync, and
    -- no sync happens between an upload and the next render. Without this it
    -- would still hold v3 as the highest after v4 went up, so the button would
    -- offer "Upload as v4" for a second time -- while the SERVER, which is the
    -- one that assigns the number (MAX + 1), would make it v5. The button would
    -- have been lying, not the upload.
    --
    -- So the list learns what was just made. The next sync overwrites it with
    -- the server's own answer either way; this only has to hold until then.
    UI.rememberVersion(v)
  end

  local pageY0 = ImGui.GetCursorPosY(ctx)

  -- Nothing on this page appears or disappears. Every line that depends on a
  -- setting sits in a slot of a fixed number of lines, and every explanation is
  -- behind a "?" like everywhere else in this script. The first version had
  -- paragraphs that came and went with the toggles, and each of them shoved
  -- everything below it down the moment you pressed something.
  -- Which production and which kind this becomes.
  local function blockTarget(rowKey)
  UI.section('New version')
  UI.cardGrid('up_target', rowKey, function()
    -- Two lines, always, whatever the title is and however wide the card is.
    -- A wrapping Text here would be one line at one width and two at another --
    -- and the width of this card is not independent of the page: too tall a
    -- page grows a scrollbar in the body, which takes the width down. Any
    -- height on this page that reacts to width is the same trap the waveform
    -- fell into, one card further along.
    UI.leadLines(2, UI.uploadTargetLine())
    ImGui.Dummy(ctx, 0, 8)

    local tt = UI.uploadType()
    local labels, active = {}, 1
    for i, k in ipairs(K.VERSION_TYPES) do
      labels[i] = UI.versionTypeLabel(k)
      if k == tt then active = i end
    end
    -- Both pressable, unlike the player's: a kind with nothing in it yet is
    -- exactly the kind a first upload goes to.
    --
    -- The "?" sits at the end of this row, so the switcher asks for the width
    -- that is left over rather than for all of it.
    local helpGap, helpD = 8, 15
    local segTop = ImGui.GetCursorPosY(ctx)
    local pick, _, _, segH = UI.segmented('##upkind', labels, active,
      math.min(360, ImGui.GetContentRegionAvail(ctx) - helpGap - helpD))
    if pick and K.VERSION_TYPES[pick] then u.trackType = K.VERSION_TYPES[pick] end
    ImGui.SameLine(ctx, 0, helpGap)
    -- Centred against the switcher instead of sitting at the top of the line:
    -- the ring is one text line tall and the switcher is 28, and ImGui aligns
    -- items of different heights by their tops.
    local helpLift = math.max(0, math.floor(((segH or 28) - UI.lineH()) / 2 + 0.5))
    if helpLift > 0 then ImGui.SetCursorPosY(ctx, segTop + helpLift) end
    -- What used to be a standing line under this row. It is a rule of the
    -- product, not a state of this page: it is true before you press anything
    -- and still true afterwards, so it belongs behind a "?" like every other
    -- explanation here rather than costing a line every time the page is open.
    UI.help('##upkindwhat', 'Every upload is a new version. Nothing is replaced, ' ..
            'and no comment is carried over -- the same as uploading in the browser.')
    ImGui.Dummy(ctx, 0, 6)

    -- One line, always. Whether it is filled changes; how much room it takes
    -- does not.
    local cur = UI.activeVersion()
    local note = nil
    if cur and cur.track_type and cur.track_type ~= tt then
      note = 'You are listening to ' .. UI.versionTypeLabel(cur.track_type) ..
             ', this goes to ' .. UI.versionTypeLabel(tt) .. '.'
    end
    -- Nothing here about which worker the upload takes. It was one line in this
    -- slot and it is out on the user's decision: the route is a fact about our
    -- deployment, not about his render, and the page is about his render. Where
    -- it still is said: the sync line marks every answer that did not come from
    -- production, and the About screen names it under what leaves this machine.
    -- The routing itself is untouched.
    UI.slot(1, { note })
  end)
  end

  -- How the file is made.
  local function blockRender(rowKey)
  UI.section('Render')
  UI.cardGrid('up_render', rowKey, function()
    local segW = math.max(160, math.min(300, ImGui.GetContentRegionAvail(ctx) - 130))

    UI.row('Bounds', 'Whole project starts at 0:00. Time selection renders only ' ..
           'what is selected in the timeline. Nothing else about your render ' ..
           'settings is changed, and all of them are put back afterwards.',
           segW, function()
      local b = UI.segmented('##upbounds', { 'Whole project', 'Time selection' },
                             u.bounds == 'timesel' and 2 or 1, segW)
      if b == 1 then u.bounds = 'project' elseif b == 2 then u.bounds = 'timesel' end
    end, nil, 28)

    -- Two lines, always, and WRAPPED. Measured rather than asked: a dialog that
    -- comes up every time gets clicked away, and start == end is Reaper for
    -- "nothing selected" -- such a render writes no file at all. It used to be
    -- one clipped line, which cut this sentence off before the part that says
    -- what happens.
    local selStart, selLen = Rnd.timeSelection()
    local selLine
    if u.bounds ~= 'timesel' then
      selLine = 'The whole project, from 0:00.'
    elseif not selStart then
      selLine = 'Nothing is selected in the timeline. This would write no file.'
    else
      selLine = ('Selected: %s to %s  (%s)'):format(
        formatTimestamp(selStart), formatTimestamp(selStart + selLen),
        formatTimestamp(selLen))
    end
    UI.slotWrap(2, selLine, u.bounds == 'timesel' and not selStart)

    UI.rowSep()
    UI.row('Source', 'Master mix is the whole mix. Via master sends the selected ' ..
           'tracks through the master chain. Stems writes the selected tracks on ' ..
           'their own, which is more than one file -- an upload takes one.',
           segW, function()
      local activeSrc = 1
      for i, k in ipairs(K.UP_SRC_KEYS) do if k == u.source then activeSrc = i end end
      local sPick = UI.segmented('##upsrc', K.UP_SRC_LABELS, activeSrc, segW)
      if sPick and K.UP_SRC_KEYS[sPick] then u.source = K.UP_SRC_KEYS[sPick] end
    end, nil, 28)

    ImGui.Dummy(ctx, 0, 6)
    UI.slot(1, { 'FLAC 24 bit \u{00b7} stereo \u{00b7} project rate \u{00b7} your own ' ..
                 'settings are put back afterwards' })
  end)
  end

  -- What goes out. Full width, at the foot of the page, and ALWAYS there --
  -- a waveform in a half-width column is one nobody can read, and a card that
  -- appears only once something has been rendered makes the page jump at the
  -- moment the producer is looking somewhere else.
  --
  -- Three states, one height. Empty it says what to do; with a file it shows
  -- the file; after the upload it keeps showing the file and says so. The last
  -- one matters: the render is the only proof of what was actually sent, and
  -- clearing it away the second it lands takes that with it.
  local function blockResult()
    UI.section('What goes out')
    UI.cardGrid('up_result', nil, function()
      local has = UI.uploadHasFile()
      local sent = UI.uploadSent()

      ImGui.PushFont(ctx, FONT_BOLD, K.FONT_LEAD)
      ImGui.Text(ctx, p.title .. '  \u{2192}  ' ..
                      (sent and (u.sentVersion or UI.uploadTargetVersion())
                             or UI.uploadTargetVersion()))
      ImGui.PopFont(ctx)
      UI.slot(1, { has and UI.fileFacts() or nil })
      ImGui.Dummy(ctx, 0, 6)

      -- The stamp sits above the waveform, in its own line, so the strip below
      -- it is the same strip it was a moment ago rather than a redrawn one.
      UI.slot(1, { sent and ('UPLOADED' ..
                   (u.sentNotified and '  \u{00b7}  the artist has been told'
                                    or '  \u{00b7}  the artist was not told')) or nil },
              sent)

      local waveH = UI.uploadWaveH()
      if has then
        UI.filePeaks(waveH)
      else
        -- Exactly the same cost as the waveform: ONE Dummy of the same height,
        -- with the line painted into it rather than laid out. Built out of
        -- layout items it came to a few pixels more -- the spacing between
        -- them -- so the page was a different height with a file than without
        -- one, and the height worked out for the one state was wrong for the
        -- other.
        UI.hintIn(waveH, 'Render your mix, or choose a file. It appears here ' ..
                         'before anything is sent.')
      end

      ImGui.Dummy(ctx, 0, 6)
      UI.slot(1, { has and UI.ellipsisMid(u.file, ImGui.GetContentRegionAvail(ctx)) or nil })
      -- The warnings from Rnd.check. They are not stops -- the file is fine to
      -- send, it just may not be what he meant -- so they sit here, where he is
      -- looking anyway, rather than in a dialog he would click away.
      UI.slot(1, { has and (u.warnings and u.warnings[1]) or nil }, true)
    end)
  end

  -- What happens once it is up.
  local function blockAfter(rowKey)
  UI.section('When it is done')
  UI.cardGrid('up_after', rowKey, function()
    UI.row('Tell the artist', 'CuePort sends no mail for a new version by itself ' ..
           '-- in the browser the producer is already there to say so. From here, ' ..
           'nothing reaches the artist unless this is on.', 32, function()
      local hit, on = UI.toggle('##upnotify', u.notify)
      if hit then u.notify = on end
    end, nil, K.TOGGLE_H)
    UI.rowSep()
    UI.row('Keep the render', 'The file stays in your project folder. The A/B ' ..
           'cleanup does not touch it.', 32, function()
      local hit, on = UI.toggle('##upkeep', u.keepRender)
      if hit then u.keepRender = on end
    end, nil, K.TOGGLE_H)

    UI.rowSep()
    -- It sits here rather than under Bounds on the user's call. It is a change
    -- to HIS project that outlives the render -- the ruler stays shifted -- so
    -- it belongs with the other two things that happen to the world rather than
    -- to the file.
    --
    -- And it is always pressable, which it was not: it used to grey itself out
    -- whenever the render already began at 0:00. That reading was wrong. If the
    -- ruler is still shifted from an earlier render and this one starts at the
    -- top of the project, then moving 0:00 to the render start is exactly what
    -- has to happen -- it puts the ruler BACK. Greyed out, the project kept the
    -- old offset and every comment on the new version landed askew, which is
    -- the very thing this row exists to prevent.
    UI.row('Move 0:00 to the render start',
           'The file starts where the render does, so without this every ' ..
           'comment lands that far away from where it was meant -- silently. ' ..
           'This shifts the whole ruler, not just the marker: a render from the ' ..
           'top of the project moves it back to zero.',
           32, function()
      local hit, on = UI.toggle('##upstart', u.setStart)
      if hit then u.setStart = on end
    end, nil, K.TOGGLE_H)
  end)
  end

  -- The act. Three controls, and the SAME three in every state -- one press
  -- sends, the other two make a different file. They only ever grey out; what
  -- the card says changes, what it offers does not. A card whose buttons are
  -- swapped out under the pointer is one you have to re-read every time.
  local function blockSend(rowKey)
  UI.section('Send it')
  UI.cardGrid('up_go', rowKey, function()
    -- Two lines about what pressing would do, or what the last press did.
    local line
    if up and up.phase == 'error' then
      line = 'Stopped: ' .. tostring(up.error)
    elseif Up.busy() or u.pending then
      -- While the veil is up it carries the progress line and the way out. Two
      -- copies of the same sentence on one screen is not a busy state, it is a
      -- bug -- so the card holds its height and says nothing.
      line = (not UI.busy()) and ((Up.busy() and Up.progressLine()) or u.status) or nil
    elseif UI.uploadSent() then
      line = 'Sent. Render again or choose another file to make the next version.'
    elseif UI.uploadHasFile() then
      line = 'Nothing is replaced. This becomes ' .. UI.uploadTargetVersion() ..
             (u.notify and ', and the artist gets a mail.' or '. The artist is not told.')
    else
      line = u.fileError or u.status
    end
    UI.slotWrap(2, line, true)
    ImGui.Dummy(ctx, 0, 8)

    local availB = ImGui.GetContentRegionAvail(ctx)
    local canSend = UI.uploadReady()
    if not canSend and ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, true) end
    if UI.primaryButton('Upload as ' .. UI.uploadTargetVersion() .. '##upsend', availB)
       and canSend then
      UI.uploadStart('send')
    end
    if not canSend and ImGui.EndDisabled then ImGui.EndDisabled(ctx) end

    ImGui.Dummy(ctx, 0, 8)
    local busy = Up.busy() or u.pending
    if busy and ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, true) end
    local halfB = (availB - 10) / 2
    local sideBySide = halfB >= 130
    local bw = sideBySide and halfB or availB
    if ImGui.Button(ctx, 'Render##upredo', bw, 0) and not busy then UI.uploadStart('render') end
    if sideBySide then ImGui.SameLine(ctx, 0, 10) else ImGui.Dummy(ctx, 0, 8) end
    if ImGui.Button(ctx, 'Choose a file...##uppick', bw, 0) and not busy then
      UI.uploadPickFile()
    end
    if busy and ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
  end)
  end

  -- Leaving. Outside both cards and outside the columns, because it is not part
  -- of sending: three buttons of equal weight in one box read as three ways of
  -- doing the same thing, and the one that goes back is not one of them.
  local function blockLeave()
    ImGui.Dummy(ctx, 0, 10)
    if Up.busy() or u.pending then
      ImGui.Dummy(ctx, 0, ImGui.GetFrameHeight and ImGui.GetFrameHeight(ctx) or 24)
      return
    end
    local sentV = (up and up.phase == 'done') and up.version or nil
    if ImGui.Button(ctx, 'Back to the production##upleave', 200, 0) then
      state.upload = nil
      state.screen = 'main'
      -- Land on the version that was just sent, not on the one that was open
      -- before it. doSync asks for `state.selectedVersionId`, so without this
      -- the sync right after an upload fetches the OLD version: its comments,
      -- its markers and its waveform, while the producer is looking for the
      -- render he just made. Same route as the switcher, so the A/B reference
      -- for the previous mix comes down with it.
      --
      -- `filename` is what the version list calls it; the upload answer calls
      -- the same string `name`. The A/B file name and the download URL are
      -- built from it, so it has to be the one the list would have given.
      if sentV and sentV.id then
        UI.switchVersion({ id = sentV.id, filename = sentV.name, label = sentV.label,
                           version_number = sentV.version_number,
                           track_type = sentV.track_type })
      elseif sentV then
        queueSync()
      end
    end
  end

  -- Two columns when there is room for them, one when there is not.
  --
  -- Every row on this page is a label at the left edge and its control at the
  -- right, so in a wide window the middle was empty while the page itself ran
  -- off the bottom and had to be scrolled -- reported from the device. Side by
  -- side, the same content is about half as tall and the empty middle is what
  -- pays for it.
  --
  -- The threshold is per column, not per window: below it the page is exactly
  -- the page it has always been, stacked, which is the only shape a narrow
  -- docker can hold. Decisions on the left, the button on the right.
  local availUp = ImGui.GetContentRegionAvail(ctx)
  -- Two columns above the threshold, back to one only well below it. The plain
  -- comparison sat on a knife edge for a reason that is easy to miss: a page
  -- that does not fit grows a scrollbar, the scrollbar takes a few pixels of
  -- width, and at a window width near the threshold that is enough to flip the
  -- whole layout -- which changes the height, which decides the scrollbar. The
  -- gap is what makes that impossible rather than unlikely.
  local twoCol = state.upTwoCol
  if twoCol == nil then twoCol = availUp >= K.UP_TWO_COL_MIN end
  if availUp >= K.UP_TWO_COL_MIN then twoCol = true
  elseif availUp < K.UP_TWO_COL_MIN - K.UP_TWO_COL_HYST then twoCol = false end
  state.upTwoCol = twoCol
  if twoCol then
    local colW = math.floor((availUp - K.UP_COL_GAP) / 2)
    local cf = ImGui.ChildFlags_AutoResizeY and ImGui.ChildFlags_AutoResizeY() or 0
    -- Same contract as UI.cardBegin: ReaImGui closes the child itself when
    -- BeginChild returns false, so EndChild is only ours to call when it is
    -- open. Calling it either way is one End too many and takes the window
    -- with it.
    -- Row by row, not column by column. Two stacks side by side line up at the
    -- top and nowhere else; drawn as rows, the second pair of headings sits on
    -- one line because the pair above it is one height.
    local lOpen = ImGui.BeginChild(ctx, '##upcolL', colW, 0, cf)
    if lOpen then blockTarget('r1') end
    if lOpen then ImGui.EndChild(ctx) end
    ImGui.SameLine(ctx, 0, K.UP_COL_GAP)
    local rOpen = ImGui.BeginChild(ctx, '##upcolR', colW, 0, cf)
    if rOpen then blockAfter('r1') end
    if rOpen then ImGui.EndChild(ctx) end
    UI.cardRow('r1', 'up_target', 'up_after')

    ImGui.Dummy(ctx, 0, 2)
    local l2 = ImGui.BeginChild(ctx, '##upcolL2', colW, 0, cf)
    if l2 then blockRender('r2') end
    if l2 then ImGui.EndChild(ctx) end
    ImGui.SameLine(ctx, 0, K.UP_COL_GAP)
    local r2 = ImGui.BeginChild(ctx, '##upcolR2', colW, 0, cf)
    if r2 then blockSend('r2') end
    if r2 then ImGui.EndChild(ctx) end
    UI.cardRow('r2', 'up_render', 'up_go')
  else
    blockTarget(); blockRender(); blockAfter(); blockSend()
  end
  blockResult()
  blockLeave()
  -- What the page took, so the strip above knows how much room is left over
  -- next frame. Measured here rather than one level up: this is the only place
  -- that knows where the page began.
  local endY = ImGui.GetCursorPosY(ctx)
  if pageY0 and endY and endY > pageY0 then state.upPageH = endY - pageY0 end

end

function UI.main()
  if not state.productions and not state.productionsFetching and not state.productionsError then
    loadProductions()
  end

  -- We may hold a restored binding id (e.g. after opening a project) without
  -- its details yet. Resolve the production from the loaded list so the bound
  -- view has a name to show — falling back to a placeholder if it's gone.
  if state.boundProductionId and not state.boundProduction and state.productions then
    for _, p in ipairs(state.productions) do
      if p.id == state.boundProductionId then state.boundProduction = p; break end
    end
    if not state.boundProduction then
      state.boundProduction = { id = state.boundProductionId, title = '(not found)', artist_name = '' }
    end
  end

  -- Show the bound view unless the user has explicitly asked to pick another
  -- production (via "Change project..." in either the main window or the
  -- floating menu). The override keeps the existing binding intact so the
  -- user can Cancel back to it without losing their choice. If we have a
  -- binding id but couldn't resolve its details yet, fall back to the picker
  -- rather than rendering a half-empty bound view.
  local showPicker = UI.showingPicker()
  -- Read one level up, where the window's minimum height is worked out: this
  -- screen's content height is not a number that floor may be built from.
  state.pickerShowing = showPicker
  if showPicker then
    UI.picker()
  else
    UI.bound()
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN LOOP
-- ══════════════════════════════════════════════════════════════════════════════

function UI.initialScreen()
  if state.token then
    state.screen = 'main'
  else
    state.screen = 'login'
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- HOVER TOOLTIP — floating ImGui window when mouse is over a Cueport item
-- ══════════════════════════════════════════════════════════════════════════════
-- NOTE: `hover` table + hoverSetEnabled are declared earlier (before UI funcs)
-- so that UI.footer's upvalue resolution picks up the correct local.

-- Get project time at the mouse cursor. Prefers SWS's BR_PositionAtMouseCursor
-- which handles Retina/multi-display/ruler-vs-arrange automatically. Falls
-- back to manual math via JS_ReaScriptAPI only if SWS isn't installed.
function UI.mouseTime()
  if r.APIExists('BR_PositionAtMouseCursor') then
    local t = r.BR_PositionAtMouseCursor(true)  -- allow outside arrange
    if t and t >= 0 then return t end
    return nil
  end
  -- Fallback (JS_ReaScriptAPI)
  if not r.APIExists('JS_Window_FindChildByID') then return nil end
  local main = r.GetMainHwnd()
  if not main then return nil end
  local arrangeWin = r.JS_Window_FindChildByID(main, 1000)
  if not arrangeWin then return nil end
  local okRect, l, _, right = r.JS_Window_GetClientRect(arrangeWin)
  if not okRect then return nil end
  local mx = r.GetMousePosition()
  if not mx or mx < l or mx > right then return nil end
  local startT, endT = r.GetSet_ArrangeView2(0, false, 0, 0)
  if not startT or not endT or endT <= startT then return nil end
  local width = math.max(1, right - l)
  return startT + ((mx - l) / width) * (endT - startT)
end

function UI.markerNearMouse()
  local t = UI.mouseTime()
  if not t then return nil end
  local pxPerSec = r.GetHZoomLevel()
  if not pxPerSec or pxPerSec <= 0 then pxPerSec = 100 end
  local tolSec = 10 / pxPerSec  -- ±10 screen pixels
  local markers = Markers.enumerate()
  local nearest, nearestDist = nil, math.huge
  for _, m in ipairs(markers) do
    local d = math.abs(m.pos - t)
    if d <= tolSec and d < nearestDist then
      nearest = m
      nearestDist = d
    end
  end
  return nearest
end

function UI.hoverTip()
  if not hover.enabled then return end
  local mx, my = r.GetMousePosition()
  if not mx or not my then return end

  local author, text, pos
  local foundSource = nil

  -- First: check CuePort markers near mouse X (primary data source in v1.3+).
  -- Marker name only contains "CP @Author: MM:SS" — full text lives in the
  -- ProjExtState cache, looked up by position.
  local m = UI.markerNearMouse()
  if m then
    local cached = findCachedCommentAtPos(m.pos)
    if cached then
      author, text, pos = cached.author, cached.text, cached.timestamp
    else
      -- No cache entry yet: parse author from the marker name, show empty text
      local a = (m.name or ''):match('^CP @([^:]+):')
      author, text, pos = a or 'Artist', '(comment not cached — sync again)', m.pos
    end
    foundSource = 'marker'
  end

  -- Fallback: legacy items on the Comments track (pre-v1.3 projects)
  if not foundSource then
    local item, _ = r.GetItemFromPoint(mx, my, true)
    if item then
      local track = r.GetMediaItem_Track(item)
      if track then
        local _, tmark = r.GetSetMediaTrackInfo_String(track, K.TRACK_MARKER_EXT_KEY, '', false)
        local _, fid = r.GetSetMediaItemInfo_String(item, K.ITEM_FB_ID_EXT_KEY, '', false)
        if tmark == '1' and fid and fid ~= '' then
          local _, notes = r.GetSetMediaItemInfo_String(item, 'P_NOTES', '', false)
          local src = notes
          if not src or src == '' then
            local take = r.GetActiveTake(item)
            if take then
              local _, n = r.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', false)
              src = n or ''
            end
          end
          local a, t2 = (src or ''):match('^@([^:]+):%s*(.*)$')
          author = a or 'Artist'
          text = t2 or src or ''
          pos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
          foundSource = 'item'
        end
      end
    end
  end

  if not foundSource then return end

  local mins = math.floor((pos or 0) / 60)
  local secs = math.floor((pos or 0) % 60)
  local ts = string.format('%d:%02d', mins, secs)

  -- Convert native OS mouse coords → ImGui viewport coords.
  -- On macOS Retina + multi-display setups this matters; without the
  -- conversion the tooltip can land in a completely wrong location.
  local wx, wy = mx, my
  if r.APIExists('ImGui_PointConvertNative') then
    local ok, nx, ny = pcall(r.ImGui_PointConvertNative, ctx, mx, my, false)
    if ok and nx and ny then wx, wy = nx, ny end
  end

  -- Draw floating tooltip window at mouse position
  ImGui.SetNextWindowPos(ctx, wx + 18, wy + 18)
  local baseFlags = (ImGui.WindowFlags_NoTitleBar and ImGui.WindowFlags_NoTitleBar() or 0)
              | (ImGui.WindowFlags_NoResize and ImGui.WindowFlags_NoResize() or 0)
              | (ImGui.WindowFlags_AlwaysAutoResize and ImGui.WindowFlags_AlwaysAutoResize() or 0)
              | (ImGui.WindowFlags_NoMove and ImGui.WindowFlags_NoMove() or 0)
              | (ImGui.WindowFlags_NoFocusOnAppearing and ImGui.WindowFlags_NoFocusOnAppearing() or 0)
              | (ImGui.WindowFlags_NoNav and ImGui.WindowFlags_NoNav() or 0)
              | (ImGui.WindowFlags_NoSavedSettings and ImGui.WindowFlags_NoSavedSettings() or 0)
  local flags = UI.windowFlags(baseFlags)
  local tsc, tsv = UI.pushTheme()

  local visible2, _ = ImGui.Begin(ctx, 'CuePortHoverTip##cphover', false, flags)
  if visible2 then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
    ImGui.Text(ctx, '@' .. author)
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
    ImGui.TextDisabled(ctx, '· ' .. ts)
    ImGui.Separator(ctx)
    if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 420) end
    ImGui.Text(ctx, text or '')
    if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
    ImGui.End(ctx)
  end
  UI.popTheme(tsc, tsv)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- FLOATING MENU — small persistent quick-access bar (always visible when on)
-- ══════════════════════════════════════════════════════════════════════════════
-- Tiny ImGui window with Sync + Show buttons and the bound production name.
-- Opt-in via settings. Persisted in global ExtState. Position handled by
-- ImGui's own layout state (drag to move, ImGui remembers it across sessions
-- via its built-in .ini storage in the Reaper resource folder).

-- ══════════════════════════════════════════════════════════════════════════════
-- TRANSPORT-ATTACHED PILL (js_ReaScriptAPI)
-- ══════════════════════════════════════════════════════════════════════════════
-- Instead of a floating ImGui window, draw the pill as a LICE bitmap and
-- composite it straight onto Reaper's Transport window (JS_Composite), so it
-- lives *inside* the transport and can be dragged around there. Mouse clicks on
-- the pill are captured with JS_WindowMessage_Intercept (only while hovering it,
-- so the rest of the transport stays clickable). Requires js_ReaScriptAPI.

K.PILL_TRANSPORT_TITLE = (r.JS_Localize and r.JS_Localize('Transport', 'common')) or 'Transport'
K.PILL_MOVE_CURSOR = r.JS_Mouse_LoadCursor and r.JS_Mouse_LoadCursor(32646) or nil
K.PILL_MSGS = {
  'WM_SETCURSOR', 'WM_LBUTTONDOWN', 'WM_LBUTTONUP', 'WM_RBUTTONDOWN', 'WM_RBUTTONUP',
}
-- Colors as 0xRRGGBB (alpha added at draw time)
K.PILL_BG     = 0x1E1E22
K.PILL_BORDER = 0x3A3A3D
K.PILL_TEXT   = 0xE8E8EA
K.PILL_ACCENT = 0xB088E0

-- Transport pill: state and behaviour in one table (see K above for why).
local Pill = { box = {}, ts = {}, intercepting = false }

function Pill.attachActive()
  return HAS_JS and state.floatingMenuEnabled and state.token
     and getGlobalExt('pill_attach') == '1'
end

function Pill.clamp()
  if not (Pill.ww and Pill.wh) then return end
  local w, h = Pill.box.w, Pill.box.h
  Pill.box.x = math.max(0, math.min(Pill.ww - w, Pill.box.x))
  Pill.box.y = math.max(0, math.min(Pill.wh - h, Pill.box.y))
end

-- Filled rounded rectangle (corner circles + rects).
function Pill.fillRound(bm, x, y, w, h, rad, color, a)
  rad = math.min(rad, math.floor(h / 2) - 1, math.floor(w / 2) - 1)
  if rad < 1 then r.JS_LICE_FillRect(bm, x, y, w, h, color, a, ''); return end
  local FC = r.JS_LICE_FillCircle
  FC(bm, x + rad,         y + rad,         rad, color, a, '', true)
  FC(bm, x + w - rad - 1, y + rad,         rad, color, a, '', true)
  FC(bm, x + w - rad - 1, y + h - rad - 1, rad, color, a, '', true)
  FC(bm, x + rad,         y + h - rad - 1, rad, color, a, '', true)
  r.JS_LICE_FillRect(bm, x + rad, y,         w - 2 * rad, h,           color, a, '')
  r.JS_LICE_FillRect(bm, x,       y + rad,   rad,         h - 2 * rad, color, a, '')
  r.JS_LICE_FillRect(bm, x + w - rad, y + rad, rad,       h - 2 * rad, color, a, '')
end

function Pill.drawBitmap()
  local w, h = Pill.box.w, Pill.box.h
  if Pill.bitmap then r.JS_LICE_DestroyBitmap(Pill.bitmap) end
  Pill.bitmap = r.JS_LICE_CreateBitmap(true, w, h)
  r.JS_LICE_Clear(Pill.bitmap, 0x00000000)

  local A = 0xFF000000
  local rad = math.floor(h / 2)  -- fully rounded → pill shape
  Pill.fillRound(Pill.bitmap, 0, 0, w, h, rad, K.PILL_BG | A, 1)
  r.JS_LICE_RoundRect(Pill.bitmap, 0, 0, w - 1, h - 1, rad, K.PILL_BORDER | A, 1, '', true)

  -- Accent dot
  local dotR = math.max(3, h // 5)
  local dotCx = 7 + dotR
  r.JS_LICE_FillCircle(Pill.bitmap, dotCx, h // 2, dotR, K.PILL_ACCENT | A, 1, '', true)

  -- Font
  if not Pill.font then Pill.font = r.JS_LICE_CreateFont() end
  local fsize = math.max(9, math.floor(h * 0.55))
  if fsize ~= Pill.fontSize then
    Pill.fontSize = fsize
    local gdi = r.JS_GDI_CreateFont(fsize, 0, 0, 0, 0, 0, 'Arial')
    r.JS_LICE_SetFontFromGDI(Pill.font, gdi, '')
    r.JS_GDI_DeleteObject(gdi)
  end
  r.JS_LICE_SetFontBkColor(Pill.font, 0)
  r.JS_LICE_SetFontColor(Pill.font, K.PILL_TEXT | A)
  local tx = dotCx + dotR + 6
  local ty = (h - fsize) // 2 - 1
  r.JS_LICE_DrawText(Pill.bitmap, Pill.font, Pill.text, #Pill.text, tx, ty, w, h)
end

function Pill.startIntercepts()
  if Pill.intercepting or not Pill.hwnd then return end
  for _, msg in ipairs(K.PILL_MSGS) do
    r.JS_WindowMessage_Intercept(Pill.hwnd, msg, false)
  end
  Pill.intercepting = true
end

function Pill.endIntercepts()
  if not Pill.intercepting then return end
  if Pill.hwnd and r.ValidatePtr(Pill.hwnd, 'HWND*') then
    for _, msg in ipairs(K.PILL_MSGS) do
      r.JS_WindowMessage_Release(Pill.hwnd, msg)
    end
  end
  for _, msg in ipairs(K.PILL_MSGS) do Pill.ts[msg] = 0 end
  Pill.intercepting = false
end

function Pill.teardown()
  Pill.endIntercepts()
  if Pill.hwnd and r.ValidatePtr(Pill.hwnd, 'HWND*') then
    if Pill.bitmap and r.JS_Composite_Unlink then
      pcall(r.JS_Composite_Unlink, Pill.hwnd, Pill.bitmap, true)
    end
    pcall(r.JS_Composite_Delay, Pill.hwnd, 0, 0, 0)
    local b = Pill.lastRect
    if b then
      r.JS_Window_InvalidateRect(Pill.hwnd, b.x - 2, b.y - 2,
        b.x + b.w + 2, b.y + b.h + 2, false)
    end
  end
  if Pill.bitmap then r.JS_LICE_DestroyBitmap(Pill.bitmap); Pill.bitmap = nil end
  if Pill.font then r.JS_LICE_DestroyFont(Pill.font); Pill.font = nil end
  Pill.hwnd = nil
  Pill.composited = false
  Pill.lastRect = nil
  Pill.drag = nil
  Pill.fontSize = nil
end

function Pill.openMenu()
  local canSync = state.boundProductionId and not state.syncInProgress
  local syncItem = (canSync and '' or '#') ..
    (state.syncInProgress and 'Syncing...' or 'Sync comments')
  local showLabel = state.windowVisible and 'Close main window' or 'Open main window'
  local menuStr = syncItem .. '|Change project...|' .. showLabel ..
    '|Detach (use floating pill)'

  local sx, sy = r.GetMousePosition()
  gfx.init('cueport_pill_menu', 0, 0, 0, sx, sy)
  local mh = r.JS_Window_Find('cueport_pill_menu', true)
  if mh then
    r.JS_Window_SetOpacity(mh, 'ALPHA', 0)
    if not isWindows() then pcall(r.JS_Window_Show, mh, 'HIDE') end
  end
  gfx.x, gfx.y = 0, 0
  local sel = gfx.showmenu(menuStr)
  gfx.quit()

  Pill.menuTime = r.time_precise()
  Pill.drag = nil

  if sel == 1 then
    if canSync then doSync() end
  elseif sel == 2 then
    state.windowVisible = true
    state.showPickerOverride = true
  elseif sel == 3 then
    state.windowVisible = not state.windowVisible
  elseif sel == 4 then
    setGlobalExt('pill_attach', '0')
    Pill.teardown()
  end
end

function Pill.finishDrag()
  if Pill.drag and Pill.drag.moved then
    setGlobalExt('pill_box', table.concat(
      {Pill.box.x, Pill.box.y, Pill.box.w, Pill.box.h}, ','))
  end
  Pill.drag = nil
end

function Pill.peek(mcx, mcy)
  for _, msg in ipairs(K.PILL_MSGS) do
    local ret, _, time = r.JS_WindowMessage_Peek(Pill.hwnd, msg)
    if ret and time ~= (Pill.ts[msg] or 0) then
      Pill.ts[msg] = time
      if msg == 'WM_SETCURSOR' then
        if K.PILL_MOVE_CURSOR then r.JS_Mouse_SetCursor(K.PILL_MOVE_CURSOR) end
      elseif msg == 'WM_LBUTTONDOWN' then
        -- Ignore clicks right after a menu closed (avoids reopening)
        if not (Pill.menuTime and r.time_precise() < Pill.menuTime + 0.05) then
          Pill.drag = {mx = mcx, my = mcy, bx = Pill.box.x, by = Pill.box.y, moved = false}
        end
      elseif msg == 'WM_LBUTTONUP' then
        if Pill.drag then
          local was_click = not Pill.drag.moved
          Pill.finishDrag()
          if was_click then Pill.openMenu() end
        end
      elseif msg == 'WM_RBUTTONUP' then
        Pill.openMenu()
      end
    end
  end
end

function Pill.update()
  if not Pill.attachActive() then
    if Pill.hwnd or Pill.bitmap then Pill.teardown() end
    return
  end

  -- Reset position request from Settings → re-init the box to its default.
  if state.pillResetPos then
    state.pillResetPos = false
    setGlobalExt('pill_box', '')
    Pill.box = {}
    Pill.composited = false
  end

  -- (Re)acquire the transport window (throttled).
  local now = r.time_precise()
  if not Pill.hwnd or not r.ValidatePtr(Pill.hwnd, 'HWND*') then
    if not Pill.lastFind or now > Pill.lastFind + 0.5 then
      Pill.lastFind = now
      Pill.hwnd = r.JS_Window_Find(K.PILL_TRANSPORT_TITLE, true)
      Pill.composited = false
      -- Fresh window → we hold no intercepts on it yet.
      Pill.intercepting = false
      for _, msg in ipairs(K.PILL_MSGS) do Pill.ts[msg] = 0 end
    end
    if not Pill.hwnd then return end
  end
  if not r.JS_Window_IsVisible(Pill.hwnd) then return end

  local _, ww, wh = r.JS_Window_GetClientSize(Pill.hwnd)
  Pill.ww, Pill.wh = ww, wh

  -- Initialise the box on first run (restore saved position if any).
  if not Pill.box.x then
    local saved = getGlobalExt('pill_box')
    local bx, by, bw, bh = saved:match('([%-%d]+),([%-%d]+),(%d+),(%d+)')
    if bx then
      Pill.box = {x = tonumber(bx), y = tonumber(by), w = tonumber(bw), h = tonumber(bh)}
    else
      local bw2, bh2 = 118, 24
      Pill.box = {x = 8, y = math.max(0, (wh - bh2) // 2), w = bw2, h = bh2}
    end
    Pill.needDraw = true
    Pill.composited = false
  end

  Pill.clamp()

  -- Text (rebuild bitmap when it changes).
  local text = state.syncInProgress and 'CuePort  syncing...' or 'CuePort'
  if text ~= Pill.text then Pill.text = text; Pill.needDraw = true end

  if Pill.needDraw or not Pill.bitmap then
    Pill.drawBitmap()
    Pill.needDraw = false
    Pill.composited = false
  end

  -- Composite when first shown or the box moved.
  if not Pill.composited or Pill.box.x ~= Pill.cx or Pill.box.y ~= Pill.cy then
    r.JS_Composite_Delay(Pill.hwnd, 0.03, 0.045, 2)
    r.JS_Composite(Pill.hwnd, Pill.box.x, Pill.box.y, Pill.box.w, Pill.box.h,
      Pill.bitmap, 0, 0, Pill.box.w, Pill.box.h)
    local lr = Pill.lastRect
    if lr then
      r.JS_Window_InvalidateRect(Pill.hwnd, lr.x - 2, lr.y - 2,
        lr.x + lr.w + 2, lr.y + lr.h + 2, false)
    end
    r.JS_Window_InvalidateRect(Pill.hwnd, Pill.box.x - 2, Pill.box.y - 2,
      Pill.box.x + Pill.box.w + 2, Pill.box.y + Pill.box.h + 2, false)
    Pill.cx, Pill.cy = Pill.box.x, Pill.box.y
    Pill.lastRect = {x = Pill.box.x, y = Pill.box.y, w = Pill.box.w, h = Pill.box.h}
    Pill.composited = true
  end

  -- Mouse: only intercept while hovering the pill (or mid-drag), so the rest
  -- of the transport keeps working normally.
  local sx, sy = r.GetMousePosition()
  local hover_hwnd = r.JS_Window_FromPoint(sx, sy)
  local mcx, mcy = r.JS_Window_ScreenToClient(Pill.hwnd, sx, sy)
  local overBox = mcx >= Pill.box.x and mcx <= Pill.box.x + Pill.box.w
             and mcy >= Pill.box.y and mcy <= Pill.box.y + Pill.box.h
  local overPill = overBox and hover_hwnd == Pill.hwnd

  if overPill or Pill.drag then
    Pill.startIntercepts()
    Pill.peek(mcx, mcy)
  else
    Pill.endIntercepts()
  end

  -- Drag-move.
  if Pill.drag then
    if r.JS_Mouse_GetState(1) & 1 == 1 then
      if math.abs(mcx - Pill.drag.mx) + math.abs(mcy - Pill.drag.my) > 3 then
        Pill.drag.moved = true
      end
      Pill.box.x = Pill.drag.bx + (mcx - Pill.drag.mx)
      Pill.box.y = Pill.drag.by + (mcy - Pill.drag.my)
      Pill.clamp()
    else
      -- Button released without us peeking the UP message.
      Pill.finishDrag()
    end
  end
end

function Pill.renderFloating()
  if not state.floatingMenuEnabled then return end
  if not state.token then return end
  -- When attached to the transport, the composited pill replaces this window.
  if Pill.attachActive() then return end

  local NoTitle  = ImGui.WindowFlags_NoTitleBar      and ImGui.WindowFlags_NoTitleBar()      or 0
  local NoResz   = ImGui.WindowFlags_NoResize        and ImGui.WindowFlags_NoResize()        or 0
  local AutoSize = ImGui.WindowFlags_AlwaysAutoResize and ImGui.WindowFlags_AlwaysAutoResize() or 0
  local NoFocus  = ImGui.WindowFlags_NoFocusOnAppearing and ImGui.WindowFlags_NoFocusOnAppearing() or 0
  local NoColl   = ImGui.WindowFlags_NoCollapse      and ImGui.WindowFlags_NoCollapse()      or 0
  local NoNav    = ImGui.WindowFlags_NoNav           and ImGui.WindowFlags_NoNav()           or 0
  local NoMove   = ImGui.WindowFlags_NoMove          and ImGui.WindowFlags_NoMove()          or 0
  local pillFlags = UI.windowFlags(NoTitle | NoResz | AutoSize | NoFocus | NoColl | NoNav)
  local menuFlags = UI.windowFlags(NoTitle | NoResz | AutoSize | NoFocus | NoColl | NoNav | NoMove)

  ImGui.SetNextWindowPos(ctx, 60, 60, ImGui.Cond_FirstUseEver())

  -- Shared CuePort theme for the pill
  local pillSc, pillSv = UI.pushTheme()

  local pillX, pillY, pillH = 0, 0, 0
  local pillToggleRequested = false

  local visible = ImGui.Begin(ctx, '##cueportFloat', false, pillFlags)
  if visible then
    -- ── Pill content: logo + "CuePort Sync" + optional "syncing…" hint ────
    local img = UI.logoImage()
    if img and r.ImGui_Image then
      pcall(r.ImGui_Image, ctx, img, 16, 16)
      ImGui.SameLine(ctx)
    else
      ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
      ImGui.Text(ctx, '●')
      ImGui.PopStyleColor(ctx)
      ImGui.SameLine(ctx)
    end
    ImGui.Text(ctx, 'CuePort Sync')
    if state.syncInProgress then
      ImGui.SameLine(ctx)
      ImGui.TextDisabled(ctx, '· syncing…')
    end

    -- ── Click-vs-drag detection on the pill ──────────────────────────────
    -- We toggle `state.floatMenuOpen` ourselves instead of using an ImGui
    -- popup, because ImGui popups auto-close on MenuItem click and when the
    -- user clicks outside the popup — behaviours the user explicitly does
    -- not want here.
    local isHover = r.ImGui_IsWindowHovered and
      r.ImGui_IsWindowHovered(ctx, (r.ImGui_HoveredFlags_RootWindow and r.ImGui_HoveredFlags_RootWindow() or 0))
      or false
    local released = r.ImGui_IsMouseReleased and r.ImGui_IsMouseReleased(ctx, 0) or false
    if isHover and released then
      local dx, dy = 0, 0
      if r.ImGui_GetMouseDragDelta then
        local a, b = r.ImGui_GetMouseDragDelta(ctx, 0)
        dx = a or 0; dy = b or 0
      end
      if (math.abs(dx) + math.abs(dy)) < 4 then
        pillToggleRequested = true
      end
    end

    pillX, pillY = ImGui.GetWindowPos(ctx)
    pillH = ImGui.GetWindowHeight(ctx)

    ImGui.End(ctx)
  end
  UI.popTheme(pillSc, pillSv)

  if pillToggleRequested then
    state.floatMenuOpen = not state.floatMenuOpen
  end

  -- ── Menu window (separate, persistent until the pill is clicked again) ──
  if state.floatMenuOpen then
    -- Align flush under the pill (1 px overlap hides the double-border seam)
    ImGui.SetNextWindowPos(ctx, pillX, pillY + pillH - 1)
    local menuSc, menuSv = UI.pushTheme()
    local mVisible = ImGui.Begin(ctx, '##cueportFloatMenu', false, menuFlags)
    if mVisible then
      if state.boundProduction then
        ImGui.TextDisabled(ctx, (state.boundProduction.artist_name or '') ..
          ' · ' .. (state.boundProduction.title or ''))
        ImGui.Separator(ctx)
      end

      -- Use Selectables (not MenuItems) — Selectables DO NOT auto-close
      -- anything, so the menu stays open across action clicks.
      local canSync = state.boundProductionId and not state.syncInProgress
      local syncLabel = state.syncInProgress and 'Syncing…' or 'Sync comments'
      if canSync then
        if ImGui.Selectable(ctx, syncLabel, false) then doSync() end
      else
        ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.textDim)
        ImGui.Selectable(ctx, syncLabel, false,
          ImGui.SelectableFlags_Disabled and ImGui.SelectableFlags_Disabled() or 0)
        ImGui.PopStyleColor(ctx)
      end

      if ImGui.Selectable(ctx, 'Change project…', false) then
        state.windowVisible = true
        state.showPickerOverride = true
      end

      ImGui.Separator(ctx)

      local showLabel = state.windowVisible and 'Close main window' or 'Open main window'
      if ImGui.Selectable(ctx, showLabel, false) then
        state.windowVisible = not state.windowVisible
      end

      if state.lastSyncAt then
        ImGui.Separator(ctx)
        local diff = os.time() - state.lastSyncAt
        local rel
        if diff < 60 then rel = 'just now'
        elseif diff < 3600 then rel = string.format('%d min ago', math.floor(diff/60))
        else rel = string.format('%d h ago', math.floor(diff/3600)) end
        ImGui.TextDisabled(ctx, 'Last sync: ' .. rel)
      end

      ImGui.End(ctx)
    end
    UI.popTheme(menuSc, menuSv)
  end
end

local function loop()
  -- Single-instance: if another invocation wrote a newer heartbeat, this
  -- instance has been superseded → exit quietly.
  if state.supersededCheck then
    -- heartbeat is ours if it's within threshold AND was written by us.
    -- We track our own last-written value to detect takeover.
    local hbStr = r.GetExtState(K.EXT_NS, K.INSTANCE_HB_KEY)
    if hbStr ~= state.lastHbWritten and hbStr ~= '' then
      -- Someone else took over
      state.running = false
    end
  end

  -- Honor "show window" requests from other invocations of this action
  if consumeShowWindowRequest() then
    state.windowVisible = true
  end

  -- Refresh heartbeat
  local hbVal = string.format('%.3f', r.time_precise())
  r.SetExtState(K.EXT_NS, K.INSTANCE_HB_KEY, hbVal, false)
  state.lastHbWritten = hbVal
  state.supersededCheck = true

  -- Keep the per-project binding in sync. This instance runs persistently in
  -- the background, so instead of trying to detect *how* the project changed
  -- (tab switch, File > Open into the same tab — which keeps the same project
  -- pointer! — or a project that finished loading after auto-start), we simply
  -- re-read the stored binding periodically and follow it. Whatever the active
  -- project's ProjExtState says wins.
  do
    local nowT = r.time_precise()
    if not state.lastBindingCheck or nowT > state.lastBindingCheck + 0.25 then
      state.lastBindingCheck = nowT
      local pid = getProjExt('production_id')
      if pid ~= state.boundProductionId then
        state.boundProductionId = pid
        state.boundProduction = nil
        if pid and state.productions then
          for _, p in ipairs(state.productions) do
            if p.id == pid then state.boundProduction = p; break end
          end
        end
        state.waveform = nil
        state.waveformForId = nil
        state.pendingSeekAt = nil
        -- Version identity belongs to the old binding — it must not leak into
        -- the new one, or the A/B cache key would point at the wrong audio.
        state.versionFilename = nil
        state.versionId = nil
        -- ...and so does the version list and the choice within it: both are
        -- per project, so they are re-read from the project we just moved to.
        state.versions, state.versionsForId = nil, nil
        state.versionSwitchFrom, state.pendingTrackType = nil, nil
        local vid = getProjExt(K.VERSION_KEY)
        state.selectedVersionId = (vid ~= '' and vid) or nil
        state.replyTo, state.replyText, state.replyStatus = nil, '', nil
  state.delArm, state.delPending = nil, nil
  state.replyFocus = false
        state.replyPending = nil
        -- A new project's binding differs from the last → drop any A/B ref
        -- flags so the compare UI reflects the new production, not the old one.
        state.showPickerOverride = false
      end
      -- Put the markers back. They are taken off the ruler when the script
      -- exits, so a bound project starts each session without them -- and the
      -- comments they are made from are cached in the project itself, so this
      -- is local work, no request. Keyed on the production rather than on the
      -- comparison above, because that one does not fire at startup: loadState
      -- has already read the same id, so old and new agree on the first frame.
      -- Skipped mid-sync, which is about to place them anyway.
      if pid and pid ~= '' and state.markersPlacedFor ~= pid and not state.syncInProgress
         and Markers.wanted() then
        -- Set first: without a cache there is nothing to place, and retrying
        -- every quarter second would not conjure one.
        state.markersPlacedFor = pid
        realignMarkers(true)
      end
    end
  end

  -- ── A/B housekeeping ─────────────────────────────────────────────────────
  -- A save (dirty → clean) is the moment our reference audio becomes something
  -- the .rpp on disk depends on, and the moment a queued file stops being
  -- referenced. Both are handled off that single transition.
  do
    local dirty = r.IsProjectDirty(0)
    if state.lastDirty == 1 and dirty == 0 then pcall(AB.onProjectSaved) end
    state.lastDirty = dirty
  end

  -- Sweep out reference tracks from earlier runs (a project that was saved
  -- while A/B was loaded brings its hidden track back on open). Throttled —
  -- this walks every track in the project.
  do
    local nowT = r.time_precise()
    if not state.lastStrayCheck or nowT > state.lastStrayCheck + 1.0 then
      state.lastStrayCheck = nowT
      pcall(AB.cleanupStrays)
    end
  end

  -- Poll pairing if active
  if state.screen == 'pairing' then pollPairing() end

  -- A queued reply. Sent here rather than in the click, for the same reason the
  -- sync is: the request blocks for as long as curl takes. Afterwards the
  -- comments are pulled again -- the reply is only really there once the server
  -- has it, and that round trip is also what gives it its id.
  if state.replyPending then UI.flushReply() end
  if state.delPending then UI.flushDelete() end

  -- A freshly picked production syncs itself, so its current version is in the
  -- player straight away. One frame late on purpose: the pick paints first.
  if state.syncRequested then
    state.syncRequested = false
    if state.boundProductionId and not state.syncInProgress then doSync() end
  end

  -- Cover art: start what is missing, one frame after the list asked for it, so
  -- that list has been painted once first. One curl call for all of them, and it
  -- runs detached -- the window keeps its frame rate while they come down.
  if state.art and state.art.pending then
    state.art.pending = false
    pcall(Art.syncFromList)
  end
  -- ...and pick the files up once the detached curl is done with them. Costs a
  -- single io.open four times a second, and only while one is running.
  if state.art and state.art.job then pcall(Art.poll) end

  -- Updates: asks GitHub at most once a day, watches our own file the rest of
  -- the time, and carries out a restart the UI asked for. All of it detached or
  -- a single short read, so it costs the frame rate nothing.
  pcall(Upd.poll)

  -- An upload in flight advances by exactly one step per frame: one part, then
  -- back to the loop. Each step still blocks while curl runs, but between them
  -- the window redraws and says how far along it is -- one call for the whole
  -- file would be a minute in which Reaper looks hung.
  if Up.busy() then
    if state.upload.frameShown then pcall(Up.step)
    else state.upload.frameShown = true end
  end
  -- The render, armed by the button and run here so the "Rendering..." frame
  -- gets painted first. It blocks while it runs, which is exactly why it must
  -- not run inside the frame that is being drawn.
  if state.up and state.up.pending then pcall(UI.uploadPump) end

  -- A/B deferred load: let one "loading…" frame paint, THEN run the blocking
  -- download + track build (curl can freeze the UI for a couple of seconds).
  if state.ab.pendingLoad then
    if state.ab.frameShown then
      state.ab.pendingLoad = false
      state.ab.frameShown = false
      AB.doLoad()
    else
      state.ab.frameShown = true
    end
  end

  ImGui.PushFont(ctx, FONT, K.FONT_SIZE)

  -- Hover tooltip is always on and runs even when the main window is hidden —
  -- that way users still get comment info while the GUI is out of the way.
  UI.hoverTip()
  Pill.update()
  Pill.renderFloating()

  if state.windowVisible then
    -- Apply a pending dock change (from the Settings toggle or startup restore)
    -- exactly once, so the rest of the time the user can freely drag the window
    -- in/out of a docker without us re-forcing it every frame.
    if state.pendingDock ~= nil and ImGui.SetNextWindowDockID then
      ImGui.SetNextWindowDockID(ctx, state.pendingDock)
      state.pendingDock = nil
    end
    -- Fixed window size only while floating — NoResize prevents user drag-resize
    -- and Cond_Always re-applies size every frame so it can't drift. When docked
    -- the docker controls the size, so we must not force it (and allow resize).
    -- Floating: 520x600 the first time, then whatever the user drags it to.
    -- ImGui persists the size in its own .ini, so it survives the session.
    -- (Until v1.6.8 this was re-applied every frame with Cond_Always plus
    -- NoResize, which is what made the window unresizable.) A minimum keeps the
    -- waveform and the production list from being squashed into nothing.
    -- The first-use size, not a limit. It matches the floor rather than sitting
    -- under it: at 520 the constraint below silently pulled a brand new window
    -- up to the floor anyway, so the two numbers only looked independent.
    local MAIN_W, MAIN_H = K.MAIN_MIN_W, 600
    if not state.mainDocked then
      local firstUse = ImGui.Cond_FirstUseEver and ImGui.Cond_FirstUseEver() or 0
      ImGui.SetNextWindowSize(ctx, MAIN_W, MAIN_H, firstUse)
      if ImGui.SetNextWindowSizeConstraints then
        -- Floors, not ceilings: how small the window may get, with no limit on
        -- how large. The height floor is what the content measured last frame,
        -- so it cannot be squashed into scrolling; the width floor keeps the
        -- settings groups wide enough to stay tiles instead of stripes.
        -- The height floor is capped so a long screen can never demand more
        -- room than a laptop display has.
        local minH = 320
        if state.bodyHeight and state.headerH then
          minH = math.max(320, math.min(K.MAIN_MIN_H_CAP,
                                        state.headerH + state.bodyHeight + 24))
        end
        ImGui.SetNextWindowSizeConstraints(ctx, K.MAIN_MIN_W, minH, 4096, 4096)
      end
    end
    local sc, sv = UI.pushTheme()
    -- No horizontal padding on the *window*: the margins are made from the
    -- inside instead (header indents, body indents). That lets the scrolling
    -- region below run edge to edge, which is where the scrollbar wants to be —
    -- without anything sticking out past the window, which is what made the
    -- whole view slide sideways in v1.7.7.
    local padVar = ImGui.StyleVar_WindowPadding and ImGui.StyleVar_WindowPadding() or nil
    if padVar then ImGui.PushStyleVar(ctx, padVar, 0, 10) end
    -- Main window is dockable (no NoDocking flag) and resizable either way.
    --
    -- No title bar: the strip Reaper drew above the header carried a collapse
    -- arrow, the script name a second time, and a close box -- all of which the
    -- header already says or can say. The close box moves into the header
    -- (UI.closeButton) and the header becomes the drag handle, which is what
    -- ConfigVar_WindowsMoveFromTitleBarOnly = 0 above is for. Docked, this
    -- changes nothing: there the docker draws the tab, not ImGui.
    local extra = (ImGui.WindowFlags_NoTitleBar and ImGui.WindowFlags_NoTitleBar()) or 0
    local visible, open = ImGui.Begin(ctx, 'CuePort Sync##cpmain', true, extra)
    -- Begin has taken its copy of the padding; drop it again right away so no
    -- other window inherits it.
    if padVar then ImGui.PopStyleVar(ctx, 1) end
    if visible then
      -- Track dock state so next frame picks the right flags/size, and persist
      -- the docker id so the window reopens where the user left it.
      --
      -- The dock id is the single source of truth (ReaImGui: 0 = undocked,
      -- -1..-16 = a REAPER docker, > 0 = an ImGui dockspace). Reading "am I
      -- docked?" from IsWindowDocked as well meant two answers to one question,
      -- and they can disagree — after dragging the window out of a docker by
      -- hand the flag stayed true, so the Settings toggle showed "docked" for a
      -- floating window and could then only ever request "undock".
      local curDock = ImGui.GetWindowDockID and ImGui.GetWindowDockID(ctx) or 0
      -- Measured in Reaper (v1.6.4 diagnostics): docked reads id -1 while
      -- Reaper reports docker index 0, floating reads id 0 while Reaper reports
      -- -1. The two agree, so asking Reaper separately — a window-list walk
      -- twice a second — bought nothing and is gone again. The id is enough,
      -- and it also carries the case Reaper cannot see at all: docked inside
      -- another ImGui window.
      state.mainDocked = curDock ~= 0
      if curDock ~= state.dockId then
        state.dockId = curDock
        if curDock ~= 0 then state.lastDockId = curDock end
        setGlobalExt('main_dock_id', tostring(curDock))
      end

      -- First thing inside the window, so it lands on the background and
      -- everything else lands on top of it.
      UI.backdrop()

      UI.header()
      -- Where the header ends is how tall it is; the body measures itself
      -- below. Together they are the tallest the window ever needs to be.
      state.headerH = ImGui.GetCursorPosY(ctx)

      -- Everything below the header scrolls in its own region, so the brand and
      -- the Settings button stay put however far down you are.
      --
      -- The scrollbar shows only when there is something to scroll, it never
      -- shifts the content sideways, and it sits *inside* the right-hand
      -- margin so both margins stay equal.
      --
      -- Two nested regions do that. The outer one fills the window edge to
      -- edge — the window carries no horizontal padding of its own — so ImGui
      -- draws the bar at the very edge, inside the margin rather than beside
      -- it. The inner one then makes both margins itself: an indent on the
      -- left, a gutter on the right.
      --   no bar: gutter = pad          -> content ends one pad in
      --   bar:    gutter = gap          -> ImGui already took the bar's width
      -- and pad = bar + gap, so the content edge does not move either way.
      if ImGui.BeginChild(ctx, 'cpbody', 0, 0, 0, 0) then
        local scrolls = (ImGui.GetScrollMaxY and ImGui.GetScrollMaxY(ctx) or 0) > 0
        local gutter  = scrolls and K.SCROLL_GAP or K.WINDOW_PAD_X
        ImGui.Indent(ctx, K.WINDOW_PAD_X)
        -- The comment list takes a column on the left when it is open and
        -- there is room for it. Below K.COMMENTS_MIN_ROOM it steps aside
        -- rather than squeezing the waveform down to something you cannot aim
        -- at -- the setting stays on, so it comes back when the window grows.
        local roomHere, roomDown = ImGui.GetContentRegionAvail(ctx)
        -- How tall the body really is, taken here and not one level deeper.
        -- `cpbodyin` auto-resizes to its content, so inside it "the height
        -- available" is the height of whatever has been laid out so far --
        -- ask a child there for the rest of the region and it grows the
        -- parent, which grows the region, which grows the child. This value
        -- comes from the window instead, so nothing feeds back into it.
        if roomDown and roomDown > 0 then state.bodyAvailH = roomDown end
        -- The column belongs to the production screen and to nothing else.
        -- Settings, About, the picker, login, pairing -- none of them is about
        -- a track, so a column of comments beside them belongs to nothing on
        -- screen. Written as "where does it belong", not as a list of pages to
        -- leave out: that list grew by one for About and by two more the same
        -- day, which is the same shape of mistake the height floor made.
        --
        -- None of this changes the size of the window. The width floor is a
        -- constant and the height floor is only ever built from the production
        -- screen, so the column stepping aside costs no pixels either way.
        local wantList = state.commentsOpen and state.boundProductionId
          and state.screen == 'main' and not UI.showingPicker()
          and roomHere and roomHere >= K.COMMENTS_MIN_ROOM
        -- Cleared here, before the list gets its turn to answer. If it is not
        -- drawn at all -- switched off, or the window too narrow -- nothing
        -- would ever clear it, and a pin would stay lit from the last time the
        -- column was open.
        state.hoverRowCommentId = nil
        if wantList then
          -- Height 0 = fill the region, so the list is as tall as the body and
          -- scrolls inside itself instead of stretching the window.
          UI.commentList(K.COMMENT_LIST_W, 0)
          ImGui.SameLine(ctx, 0, 12)
        end
        local innerFlags = ImGui.ChildFlags_AutoResizeY and ImGui.ChildFlags_AutoResizeY() or 0
        if ImGui.ChildFlags_AlwaysAutoResize then
          innerFlags = innerFlags | ImGui.ChildFlags_AlwaysAutoResize()
        end
        if ImGui.BeginChild(ctx, 'cpbodyin', -gutter, 0, innerFlags, 0) then
          -- Cleared before the dispatch, not after the picker: only UI.main can
          -- turn it on, and a flag left standing from the last frame would go
          -- on suppressing the height measurement on every other screen.
          state.pickerShowing = false
          -- Nothing on the page may be pressed while an update is running: a
          -- second click on the same button would start a second job.
          local busy = UI.busy()
              and (ImGui.BeginDisabled and ImGui.EndDisabled) and true or false
          if busy then ImGui.BeginDisabled(ctx, true) end
          if state.screen == 'login'       then UI.login()
          elseif state.screen == 'pairing'  then UI.pairing()
          elseif state.screen == 'settings' then UI.settings()
          elseif state.screen == 'about'    then UI.about()
          elseif state.screen == 'upload'   then UI.upload()
          elseif state.screen == 'deps'     then UI.deps()
          elseif state.screen == 'main'     then UI.main()
          end

          if busy then ImGui.EndDisabled(ctx) end
          -- Footer only on the "working" screens — the settings screen has its
          -- own back button so no footer is needed there.
          if state.screen ~= 'settings' then
            ImGui.Dummy(ctx, 0, 10)
            UI.footer()
          end
          -- The inner region auto-resizes to its content, so its height is the
          -- content height — the number the window's ceiling is built from.
          --
          -- Not while the picker is up. That screen ends in a list that is
          -- *meant* to fill the window and scroll inside itself, so its content
          -- height is the window height by construction; feeding that back into
          -- a floor that says "the window must be at least as tall as its
          -- content" makes the two chase each other upwards. The floor exists
          -- for screens whose content is finite, and the last such measurement
          -- is the right one to keep.
          -- ...and only there. Settings, About, login and pairing are pages
          -- that scroll perfectly well, and any of them rebuilding the floor
          -- drags the window taller the moment it opens -- and leaves it that
          -- way, because a floor only holds downwards. Written as "which
          -- screen builds it", not as a list of screens to leave out: that
          -- list grew by one the first time a human opened About, and then by
          -- one again for Settings.
          --
          -- And not on the frame a screen change lands on. `cpbodyin` resizes
          -- itself to its content, and ImGui gives such a window the size it
          -- worked out from the PREVIOUS frame -- so the first frame back on
          -- the production screen still reports the height of the page you
          -- just left. Coming from About that is a very tall number, and it
          -- went straight into the floor: the window grew on the way back
          -- rather than on the way in. Measure only once the same screen has
          -- been up for two frames; one frame of lag is not visible.
          local floorKey = tostring(state.screen) ..
                           (state.pickerShowing and '+picker' or '')
          if ImGui.GetWindowSize and state.screen == 'main'
             and not state.pickerShowing and floorKey == state.prevFloorKey then
            local _, bh = ImGui.GetWindowSize(ctx)
            if bh and bh > 0 then state.bodyHeight = bh end
          end
          state.prevFloorKey = floorKey
          ImGui.EndChild(ctx)
        end
        ImGui.Unindent(ctx, K.WINDOW_PAD_X)
        ImGui.EndChild(ctx)
      end
      -- Last thing in the window, so it covers everything that was drawn.
      if UI.busy() then UI.busyOverlay() end
      ImGui.End(ctx)
    end
    UI.popTheme(sc, sv)
    if not open then
      -- User closed the window → go to background mode (keep hover running).
      state.windowVisible = false
    end
  end

  ImGui.PopFont(ctx)

  if state.running then
    r.defer(loop)
  end
end

-- Cleanup on any kind of exit (manual Beenden, Reaper shutdown, script replace)
r.atexit(function()
  pcall(clearInstanceHeartbeat)
  -- Remove the composited transport pill + release any mouse intercepts.
  pcall(Pill.teardown)
  -- A/B reference is temporary — remove the hidden track + unmute master so we
  -- never leave the project in a muted/odd state after the script stops. The
  -- audio stays (see AB.remove): the next run reuses it instead of downloading
  -- the same version all over again.
  pcall(AB.remove, true)
  -- So are the comment markers: they belong to the script, not to the project.
  -- Nothing is lost -- the comments themselves stay in the project's
  -- ProjExtState, and the binding check puts the markers back on the next run.
  -- Deliberately *not* the render start marker: that one is the ruler origin
  -- the user set by hand, and it is theirs to keep.
  pcall(Markers.remove)
  -- Die temporaeren curl-Dateien gehoeren diesem Lauf. Der Cover-Job ist
  -- der einzige, der laenger lebt als sein Aufruf: er wird losgeloest
  -- gestartet und liegt beim Beenden womoeglich noch da. Seine
  -- Konfigurationsdatei traegt den Anmeldekopf, also raeumt sie hier weg,
  -- statt sie unbegrenzt liegen zu lassen.
  pcall(function()
    local job = state.art and state.art.job
    if not job then return end
    deleteFile(job.cfg); deleteFile(job.sh)
    deleteFile(job.out); deleteFile(job.done)
  end)
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- BOOTSTRAP
-- ══════════════════════════════════════════════════════════════════════════════

do
  -- Required deps — if missing, show a message box and abort
  local missing = missingRequiredDeps()
  if #missing > 0 then
    local msg = 'CuePort Sync requires the following extension(s):\n\n'
    for _, d in ipairs(missing) do
      msg = msg .. '• ' .. d.name .. '\n   ' .. d.install
                 .. (d.url and ('\n   ' .. d.url) or '') .. '\n'
    end
    msg = msg .. '\nPlease install and restart Reaper.'
    r.MB(msg, 'CuePort Sync · Missing dependency', 0)
    return
  end

  -- Single-instance: if another recent heartbeat is present, just signal
  -- "show window" to it and exit this invocation without starting a GUI.
  -- ...unless we are the restart. The instance that asked for it is on its way
  -- out and its heartbeat may still be warm; handing it a "show window" and
  -- exiting would end with no window at all.
  if isOtherInstanceAlive() and not Upd.restartPending() then
    signalShowWindow()
    return
  end

  state.instanceId = string.format('%x', math.floor(r.time_precise() * 1000) % 0xFFFFFF)
  state.running = true

  -- If a previous run died between disabling and re-enabling the ReaPack
  -- repository, its note is still here and the repository is still off. Put it
  -- back before anything else happens.
  pcall(Upd.repairRepo)

  -- "Start in background" decides this on its own. It used to be OR-ed with
  -- "did the auto-start shim launch us", which meant that for anyone with
  -- auto-start on the switch did nothing at all: the shim's true always won,
  -- and the setting could only ever add to it. The switch in Settings said one
  -- thing and the script did another.
  --
  -- The old behaviour is preserved for people who already had auto-start on and
  -- never touched the switch: their first run under this version writes it on,
  -- so nothing changes for them and the switch now shows what is actually
  -- happening. From then on it is theirs to set.
  if getGlobalExt('start_minimized') == '' and _G.CUEPORT_STARTUP == true then
    setGlobalExt('start_minimized', '1')
  end
  -- The GUI is opened by running the same action again (the single-instance
  -- handshake sets `show_window_req`, which the running loop consumes).
  state.windowVisible = (getGlobalExt('start_minimized') ~= '1')
  -- ...unless we are the other half of a restart the user just asked for: they
  -- pressed a button and should see the result, whatever the setting says.
  if Upd.restartPending() then
    setGlobalExt(K.UPD_SHOW_KEY, '')
    state.windowVisible = true
  end
  state.floatingMenuEnabled = (getGlobalExt('floating_menu') == '1')

  -- Restore the docked position from a previous session (0 = floating).
  local savedDock = tonumber(getGlobalExt('main_dock_id')) or 0
  if savedDock ~= 0 then
    state.dockId = savedDock
    state.lastDockId = savedDock
    state.pendingDock = savedDock  -- applied on the first frame the window shows
  end

  loadState()
  -- A render that Reaper died in the middle of leaves our output folder and our
  -- format in the producer's render dialog. The note is written before the first
  -- write and worked off here, into the project it names and no other.
  Rnd.repairIfNeeded()
  -- Starting in the background only makes sense once there is a token: without
  -- one the pill cannot draw either, so a hidden instance would show nothing
  -- whatsoever — and there is nothing to stay quiet about, since no production
  -- can be synced until the user has paired.
  if not state.token then state.windowVisible = true end
  UI.initialScreen()
  r.defer(loop)
end
