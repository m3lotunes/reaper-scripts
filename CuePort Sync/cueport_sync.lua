-- @description CuePort Sync
-- @version 2.4.0
-- @author CuePort
-- @website https://cueport.app
-- @about
--   # CuePort Sync
--
--   Pulls top-level artist feedback for the active version of a production from
--   CuePort (cueport.app) and drops each comment as an empty media item on an
--   "Artist Comments" track.
--
--   Requires ReaImGui and curl (Win 10+/macOS/Linux have curl by default).
--
--   Usage: run from the Actions list, log in once, bind a production per .rpp,
--   then "Kommentare synchronisieren" for subsequent updates.
-- @changelog
--   v2.4.0 - Honour Reaper's project start offset when placing markers.
--            Users can now set "0:00 to current edit cursor" at the render
--            start (Right-click ruler → Change start time/measure) and the
--            synced markers land at the correct ruler positions. A short
--            how-to is shown on the bound-project screen with a live
--            indicator of the detected offset.
--   v2.3.2 - Floating menu is now a separate persistent window (not an ImGui
--            popup). Pill click toggles the menu open/closed cleanly;
--            action rows use Selectables so the menu stays open across
--            clicks. Menu sits flush under the pill (1 px overlap to hide
--            the seam). Artist name removed from the pill.
--   v2.3.1 - Floating menu popup now appears directly under the pill (not at
--            the mouse cursor). Clicking the pill a second time closes the
--            popup (we gate the open check on the previous-frame popup
--            state, so ImGui's click-outside-to-close does not trigger a
--            same-interaction reopen).
--   v2.3.0 - Floating menu rewritten Gridbox-style: tiny persistent pill
--            (logo + "CuePort Sync" + state hint) is fully draggable from
--            anywhere on its surface. A short click opens a native-style
--            popup menu with the actions; dragging moves the window. Click
--            detection uses a 4 px drag threshold so a real window drag
--            does not also trigger the popup.
--   v2.2.1 - Floating menu: header is no longer a big clickable selectable
--            so the whole body can be grabbed and dragged like Reaper's Grid
--            popup. A small chevron button on the right handles collapse.
--   v2.2.0 - Settings button + "signed in" indicator moved to the header's
--            top-right. Version no longer in header (shown in Settings).
--            Production picker has a "Back to current project" button when
--            the user opens it from a bound state. Floating menu is now
--            narrower (auto-sizes to its widest label) and collapsible by
--            clicking the header row; header shows "CuePort Sync" instead
--            of the production name.
--   v2.1.0 - Production picker grouped by artist with collapsible rows.
--            Settings moved to their own screen with a Back button.
--   v2.0.1 - Title bar now uses the CuePort dark color (was ImGui default
--            blue); fixed main window size (520x600, NoResize); smaller
--            checkboxes via tighter FramePadding.
--   v2.0.0 - Major UI rework: full English UI, CuePort theme applied to
--            every window (main, floating menu, hover tooltip, dependency
--            modal), opaque backgrounds, non-dockable, logo in header.
--   v1.6.0 - Floating menu restyled like Reaper's native popup menus (Grid-
--            dropdown aesthetic): vertical selectable items, dark neutral
--            surface, subtle hover highlight, separators, rounded corners.
--            "Projekt wechseln" + sync progress + last-sync hint inline.
--   v1.5.1 - Fix floating-menu toggle crash (setFloatingMenuEnabled upvalue)
--   v1.5.0 - Floating quick-access menu (opt-in in Einstellungen). Tiny
--            always-visible window with the bound production name + Sync /
--            Open buttons. Drag to position, ImGui remembers placement.
--   v1.4.2 - Fix checkCurl upvalue crash: parseExecOutput was declared below
--            checkCurl, so the call resolved to nil global. Inlined the tiny
--            parse logic to drop the dependency.
--   v1.4.1 - curl is now a required dependency checked at startup. Missing
--            curl → same friendly MessageBox as missing ReaImGui (no more
--            cryptic "curl failed (exit -999)" on first login).
--   v1.4.0 - Background mode: window close hides GUI but hover tooltip stays
--            active. Dedicated "Skript beenden" button to actually exit.
--            Single-instance detection via ExtState heartbeat — running the
--            action twice just re-opens the GUI of the first instance.
--            Auto-start toggle: writes a managed block into Reaper's
--            Scripts/__startup.lua so the script launches on Reaper startup
--            (hidden by default). Removed the LICE overlay + hover toggle
--            (hover is always-on now; LICE doesn't fit the marker model).
--            New dependency-check modal lists ReaImGui/SWS/JS_ReaScriptAPI
--            with install hints; required deps block startup with a message
--            box if missing.
--   v1.3.1 - Shorter marker names ("CP @Author: MM:SS"); full comment text
--            stored in ProjExtState and looked up on hover. Robust mouse→time
--            via SWS BR_PositionAtMouseCursor (JS_ReaScriptAPI fallback).
--            Sync rebuilds markers from scratch (delete ours, recreate).
--   v1.3.0 - Switch to project markers instead of items on a track. All
--            CuePort markers get a uniform purple color. Hover tooltip
--            works on markers (mouse X → project time, 8px tolerance).
--            Legacy items from earlier versions are auto-migrated (removed
--            from the Comments track) on first sync; empty track is deleted.
--   v1.2.1 - Fix hover crash on Einstellungen click (upvalue scope order) +
--            convert mouse coords through ImGui_PointConvertNative so tooltip
--            appears under the cursor on macOS/Retina + multi-display setups.
--   v1.2.0 - Hover tooltip: floating ReaImGui window shows comment text big
--            under the mouse when hovering a comment item (default ON).
--            Much more reliable than LICE overlay; no extra deps.
--   v1.1.1 - Drop JS_LICE_SetFontBgColor call (not in all JS_ReaScriptAPI
--            versions); background is already drawn via FillRect.
--   v1.1.0 - Optional LICE text overlay: draws comment text big on items
--            (requires JS_ReaScriptAPI). Toggle in Einstellungen.
--   v1.0.6 - Default Comments track height 100px for readable notes overlay
--   v1.0.5 - Fix pairing countdown (string.format %d needs math.floor on Lua 5.4)
--   v1.0.4 - Fix JSON parser next_char (number vs boolean compare never matched)
--   v1.0.3 - Use absolute curl path on macOS/Linux (Reaper doesn't inherit shell PATH)
--   v1.0.2 - Fix PushFont signature for newer ReaImGui (size required as 3rd arg)
--   v1.0.1 - Add ReaPack metadata header so the action registers automatically
--   v1.0.0 - Initial release

local VERSION = '2.4.0'
local API_PROD    = 'https://melotunes-upload.m3lotunes.workers.dev'
local API_PREVIEW = 'https://melotunes-preview.m3lotunes.workers.dev'

local EXT_NS                 = 'CuePort'
local COMMENTS_TRACK_NAME    = 'Artist Comments'
local TRACK_MARKER_EXT_KEY   = 'P_EXT:cueport_track'
local ITEM_FB_ID_EXT_KEY     = 'P_EXT:cueport_feedback_id'
local MAX_ITEM_LENGTH        = 2.0
local COMMENT_ITEM_COLOR     = 0x7B45C8

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

-- Detect optional helpers. Used by the dependency-check banner; also feed
-- the hover-detection fallback chain. curl is verified lazily via the first
-- HTTP call — no static check here.
local HAS_SWS = r.APIExists('BR_PositionAtMouseCursor')
local HAS_JS  = r.APIExists('JS_Window_FindChildByID')

-- ══════════════════════════════════════════════════════════════════════════════
-- MINIMAL JSON PARSER (based on rxi/json.lua, MIT)
-- ══════════════════════════════════════════════════════════════════════════════
local json = {}
do
  local escape_chars = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

  local function decode_error(str, idx, msg)
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

local function getGlobalExt(key)    return r.GetExtState(EXT_NS, key) end
local function setGlobalExt(key, v) r.SetExtState(EXT_NS, key, v or '', true) end
local function delGlobalExt(key)    r.DeleteExtState(EXT_NS, key, true) end

local function getProjExt(key)
  local ok, val = r.GetProjExtState(0, EXT_NS, key)
  return ok == 1 and val ~= '' and val or nil
end
local function setProjExt(key, v) r.SetProjExtState(0, EXT_NS, key, v or '') end

-- ══════════════════════════════════════════════════════════════════════════════
-- HTTP (via curl through reaper.ExecProcess — cross-platform)
-- ══════════════════════════════════════════════════════════════════════════════

local function isWindows() return r.GetOS():find('Win') ~= nil end

local function tmpPath(suffix)
  -- Use /tmp on Unix (no spaces, reliable), Reaper resource dir on Windows
  if isWindows() then
    local dir = r.GetResourcePath()
    return dir .. '\\cueport_tmp_' .. suffix
  else
    return '/tmp/cueport_tmp_' .. suffix
  end
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

-- Check whether curl is callable from Reaper's ExecProcess context. Runs
-- "curl --version" once and caches the result (exec is not free, ~50-200ms).
-- Returns: ok (bool), versionLine (string or nil)
local _curlCheck = nil
local function checkCurl(force)
  if _curlCheck ~= nil and not force then return _curlCheck.ok, _curlCheck.version end
  local bin = curlBinary()
  local cmd
  if isWindows() then
    cmd = bin .. ' --version'
  else
    cmd = '"' .. bin .. '" --version'
  end
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

-- Perform an HTTP request using a curl config file (avoids shell-escape hell).
-- Returns: status_code (number), body (string), error (string or nil)
local function httpRequest(method, url, headers, bodyStr)
  local cfgPath  = tmpPath('req.cfg')
  local bodyPath = tmpPath('req.body')
  local respPath = tmpPath('resp.body')

  -- Write body if present
  if bodyStr and #bodyStr > 0 then
    if not writeFile(bodyPath, bodyStr) then
      return nil, nil, 'Failed to write body temp file'
    end
  end

  -- Build curl config file
  local cfg = { '--silent', '--show-error', '--connect-timeout 10', '--max-time 30' }
  cfg[#cfg+1] = '--request ' .. method
  for k, v in pairs(headers or {}) do
    cfg[#cfg+1] = 'header = "' .. k .. ': ' .. v:gsub('"', '\\"') .. '"'
  end
  if bodyStr and #bodyStr > 0 then
    cfg[#cfg+1] = 'data-binary = "@' .. bodyPath .. '"'
  end
  -- Write status code on its own line at the end of the body file
  cfg[#cfg+1] = 'output = "' .. respPath .. '"'
  cfg[#cfg+1] = 'write-out = "\\n__CUEPORT_STATUS__:%{http_code}"'
  cfg[#cfg+1] = 'url = "' .. url .. '"'

  if not writeFile(cfgPath, table.concat(cfg, '\n')) then
    return nil, nil, 'Failed to write curl config'
  end

  -- Execute curl
  local curlCmd = curlBinary() .. ' --config "' .. cfgPath .. '"'
  local raw = r.ExecProcess(curlCmd, 35000)
  local exitCode, curlOut = parseExecOutput(raw)

  local body = readFile(respPath) or ''
  -- Status code was appended to stdout (write-out), not the output file
  local status = curlOut:match('__CUEPORT_STATUS__:(%d+)')
  status = tonumber(status)

  -- Cleanup
  deleteFile(cfgPath)
  if bodyStr then deleteFile(bodyPath) end
  deleteFile(respPath)

  if not status then
    local hint = curlOut ~= '' and (' ' .. curlOut) or ''
    return nil, body, 'curl failed (exit ' .. tostring(exitCode) .. ')' .. hint
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
-- HOVER TOOLTIP STATE (declared early so renderFooter/renderHoverTip both see
-- it as an upvalue; Lua resolves function-body references at function-creation
-- time, so the local must exist before any function body that references it).
-- ══════════════════════════════════════════════════════════════════════════════

local hover = { enabled = true }
do
  local v = getGlobalExt('hover_enabled')
  if v == '0' then hover.enabled = false end
end

local function hoverSetEnabled(v)
  hover.enabled = v and true or false
  setGlobalExt('hover_enabled', v and '1' or '0')
end

-- ══════════════════════════════════════════════════════════════════════════════
-- APPLICATION STATE
-- ══════════════════════════════════════════════════════════════════════════════

local state = {
  screen = 'init',  -- init, login, pairing, main, error

  -- API / auth
  apiUrl = API_PROD,
  isPreview = false,
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

  -- Binding (from current project)
  boundProductionId = nil,
  boundProduction = nil,

  -- Sync
  syncInProgress = false,
  syncStatus = '',
  lastSyncResult = nil,
  lastSyncAt = nil,

  -- Error
  errorMsg = nil,

  -- UI
  showDebug = false,
}

-- Load persisted state
local function loadState()
  -- API preview override
  if getGlobalExt('use_preview') == '1' then
    state.apiUrl = API_PREVIEW
    state.isPreview = true
  else
    state.apiUrl = API_PROD
    state.isPreview = false
  end

  -- Token (per-host — prod and preview have separate tokens)
  local tokenKey = state.isPreview and 'token_preview' or 'token_prod'
  state.token = getGlobalExt(tokenKey)
  if state.token == '' then state.token = nil end

  -- Project binding
  state.boundProductionId = getProjExt('production_id')
end

local function saveToken(tok)
  local tokenKey = state.isPreview and 'token_preview' or 'token_prod'
  if tok then setGlobalExt(tokenKey, tok) else delGlobalExt(tokenKey) end
  state.token = tok
end

local function setPreviewMode(enable)
  setGlobalExt('use_preview', enable and '1' or '0')
  loadState()
end

-- ══════════════════════════════════════════════════════════════════════════════
-- API WRAPPERS (calls against /reaper/* endpoints)
-- ══════════════════════════════════════════════════════════════════════════════

local function authHeaders()
  if not state.token then return {} end
  return { ['Authorization'] = 'Bearer ' .. state.token }
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

local function apiProductions()
  local status, body, err = httpGET(state.apiUrl .. '/reaper/productions', authHeaders())
  if not status then return nil, err end
  if status == 401 then return nil, 'unauthorized' end
  if status ~= 200 then return nil, 'HTTP ' .. status end
  local parsed = json.decode(body)
  if not parsed or not parsed.productions then return nil, 'Bad response' end
  return parsed.productions
end

local function apiComments(productionId)
  local url = state.apiUrl .. '/reaper/comments?production_id=' .. productionId
  local status, body, err = httpGET(url, authHeaders())
  if not status then return nil, err end
  if status == 401 then return nil, 'unauthorized' end
  if status == 404 then return nil, 'production not found' end
  if status ~= 200 then return nil, 'HTTP ' .. status end
  return json.decode(body)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- REAPER TRACK & ITEM HELPERS
-- ══════════════════════════════════════════════════════════════════════════════

-- Find existing comments track (via P_EXT marker). Returns track or nil.
local function findCommentsTrack()
  for i = 0, r.CountTracks(0) - 1 do
    local t = r.GetTrack(0, i)
    local _, marker = r.GetSetMediaTrackInfo_String(t, TRACK_MARKER_EXT_KEY, '', false)
    if marker == '1' then return t end
  end
  return nil
end

-- Find or create the comments track. Returns the track.
local function getOrCreateCommentsTrack()
  local t = findCommentsTrack()
  if t then return t end
  -- Create new track at the top
  r.InsertTrackAtIndex(0, true)
  t = r.GetTrack(0, 0)
  r.GetSetMediaTrackInfo_String(t, 'P_NAME', COMMENTS_TRACK_NAME, true)
  r.GetSetMediaTrackInfo_String(t, TRACK_MARKER_EXT_KEY, '1', true)
  -- Color: Cueport purple
  r.SetMediaTrackInfo_Value(t, 'I_CUSTOMCOLOR', COMMENT_ITEM_COLOR | 0x1000000)
  -- Set track height taller so notes are easily readable
  r.SetMediaTrackInfo_Value(t, 'I_HEIGHTOVERRIDE', 100)
  r.TrackList_AdjustWindows(false)
  return t
end

-- Get feedback_id of an item, or nil if not ours.
local function getItemFeedbackId(item)
  local _, id = r.GetSetMediaItemInfo_String(item, ITEM_FB_ID_EXT_KEY, '', false)
  if id == nil or id == '' then return nil end
  return id
end

-- Create a new empty item on the comments track for a single comment.
local function createCommentItem(track, comment, nextTimestamp)
  local item = r.AddMediaItemToTrack(track)
  local length = MAX_ITEM_LENGTH
  if nextTimestamp and nextTimestamp > comment.timestamp then
    length = math.min(MAX_ITEM_LENGTH, nextTimestamp - comment.timestamp - 0.05)
  end
  if length < 0.1 then length = 0.1 end
  r.SetMediaItemInfo_Value(item, 'D_POSITION', comment.timestamp)
  r.SetMediaItemInfo_Value(item, 'D_LENGTH', length)
  r.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR', COMMENT_ITEM_COLOR | 0x1000000)

  -- Add an empty take so the item has a visible name
  local take = r.AddTakeToMediaItem(item)
  local label = '@' .. (comment.author or 'Artist') .. ': ' .. (comment.text or '')
  r.GetSetMediaItemTakeInfo_String(take, 'P_NAME', label, true)

  -- Mark with feedback_id for future diffs
  r.GetSetMediaItemInfo_String(item, ITEM_FB_ID_EXT_KEY, comment.id, true)
  -- Also put text in item notes for easy inspection
  r.GetSetMediaItemInfo_String(item, 'P_NOTES', label, true)
  return item
end

-- Update an existing item to match the given comment (position, length, text).
local function updateCommentItem(item, comment, nextTimestamp)
  local length = MAX_ITEM_LENGTH
  if nextTimestamp and nextTimestamp > comment.timestamp then
    length = math.min(MAX_ITEM_LENGTH, nextTimestamp - comment.timestamp - 0.05)
  end
  if length < 0.1 then length = 0.1 end
  r.SetMediaItemInfo_Value(item, 'D_POSITION', comment.timestamp)
  r.SetMediaItemInfo_Value(item, 'D_LENGTH', length)

  local take = r.GetActiveTake(item)
  if not take then take = r.AddTakeToMediaItem(item) end
  local label = '@' .. (comment.author or 'Artist') .. ': ' .. (comment.text or '')
  r.GetSetMediaItemTakeInfo_String(take, 'P_NAME', label, true)
  r.GetSetMediaItemInfo_String(item, 'P_NOTES', label, true)
end

-- Sync comments onto the comments track. Returns summary table.
local function syncCommentsToTrack(comments)
  r.Undo_BeginBlock()
  local track = getOrCreateCommentsTrack()

  -- Build map: feedback_id → existing item
  local existing = {}
  for i = 0, r.CountTrackMediaItems(track) - 1 do
    local item = r.GetTrackMediaItem(track, i)
    local fid = getItemFeedbackId(item)
    if fid then existing[fid] = item end
  end

  -- Sort comments by timestamp (for length calculation)
  table.sort(comments, function(a, b) return (a.timestamp or 0) < (b.timestamp or 0) end)

  local created, updated, deleted = 0, 0, 0
  local seen = {}

  for i, c in ipairs(comments) do
    if c.timestamp ~= nil and c.id then
      local nextTs = comments[i+1] and comments[i+1].timestamp or nil
      local item = existing[c.id]
      if item then
        updateCommentItem(item, c, nextTs)
        updated = updated + 1
      else
        createCommentItem(track, c, nextTs)
        created = created + 1
      end
      seen[c.id] = true
    end
  end

  -- Remove items whose feedback_id is no longer in API response
  for fid, item in pairs(existing) do
    if not seen[fid] then
      r.DeleteTrackMediaItem(track, item)
      deleted = deleted + 1
    end
  end

  r.UpdateArrange()
  r.Undo_EndBlock('CuePort: Sync artist comments', -1)
  return { created = created, updated = updated, deleted = deleted }
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PROJECT MARKER SYNC (v1.3+)
-- ══════════════════════════════════════════════════════════════════════════════
-- Stores feedback as project markers on the ruler. Marker names are short
-- ("CP @Author: MM:SS") so the ruler stays scannable; the full comment text
-- lives in ProjExtState and is looked up on hover. We identify "our" markers
-- by name prefix + uniform color.

local CP_MARKER_NAME_PREFIX = 'CP '

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

-- Enumerate all markers that belong to us (by uniform color + name prefix).
local function enumerateCueportMarkers()
  local list = {}
  local expectedColor = cpMarkerColor()
  local i = 0
  while true do
    local retval, isrgn, pos, _, name, idx, color = r.EnumProjectMarkers3(0, i)
    if retval == 0 then break end
    if not isrgn
       and name and name:sub(1, #CP_MARKER_NAME_PREFIX) == CP_MARKER_NAME_PREFIX
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
local COMMENTS_CACHE_KEY = 'comments_cache'

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

local function saveCommentsCache(comments, offset)
  local stripped = {}
  for _, c in ipairs(comments or {}) do
    stripped[#stripped+1] = {
      id = c.id,
      timestamp = c.timestamp,                       -- ruler-relative, as returned by the API
      markerPos = (c.timestamp or 0) + (offset or 0), -- internal Reaper position where the marker lives
      author = c.author,
      text = c.text,
    }
  end
  setProjExt(COMMENTS_CACHE_KEY, json.encode(stripped))
end

local function loadCommentsCache()
  local raw = getProjExt(COMMENTS_CACHE_KEY)
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
-- without our ITEM_FB_ID_EXT_KEY marker). Deletes the track entirely if it
-- ends up empty afterwards.
local function cleanupLegacyItems()
  local track = findCommentsTrack()
  if not track then return 0 end
  local removed = 0
  local i = r.CountTrackMediaItems(track) - 1
  while i >= 0 do
    local item = r.GetTrackMediaItem(track, i)
    local _, fid = r.GetSetMediaItemInfo_String(item, ITEM_FB_ID_EXT_KEY, '', false)
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

  table.sort(comments, function(a, b) return (a.timestamp or 0) < (b.timestamp or 0) end)

  -- Honour Reaper's project start offset so comments at timestamp T end up
  -- at ruler 0:00 + T (not at internal time T which would show at T-offset
  -- once the user has moved the ruler origin).
  local offset = getProjectStartOffset()

  -- Rebuild strategy: delete all our existing CP markers, then create fresh
  -- from the current API payload. Simpler than diffing and keeps the marker
  -- ruler in lock-step with the server without carrying stable IDs in names.
  local existing = enumerateCueportMarkers()
  local previouslyCount = #existing
  for i = #existing, 1, -1 do
    r.DeleteProjectMarker(0, existing[i].idx, false)
  end

  local color = cpMarkerColor()
  local created = 0
  local validComments = {}
  for _, c in ipairs(comments) do
    if c.timestamp ~= nil and c.id then
      local name = formatCueportMarkerName(c)
      local markerPos = c.timestamp + offset
      r.AddProjectMarker2(0, false, markerPos, 0, name, -1, color)
      created = created + 1
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

local function openUrl(url)
  if isWindows() then
    r.ExecProcess('cmd.exe /c start "" "' .. url .. '"', 0)
  elseif r.GetOS():find('OSX') or r.GetOS():find('macOS') then
    r.ExecProcess('/usr/bin/open ' .. url, 0)
  else
    r.ExecProcess('xdg-open ' .. url, 0)
  end
end

local function clipboardSet(text)
  if r.CF_SetClipboard then r.CF_SetClipboard(text) end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- FLOW CONTROLLERS (kick off async sub-flows; polled via defer loop)
-- ══════════════════════════════════════════════════════════════════════════════

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
  -- Auto-open browser
  if state.verificationUrl then openUrl(state.verificationUrl) end
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

local function logout()
  saveToken(nil)
  state.productions = nil
  state.boundProduction = nil
  state.screen = 'login'
end

-- ══════════════════════════════════════════════════════════════════════════════
-- DEPENDENCY CHECK
-- ══════════════════════════════════════════════════════════════════════════════

local function getDependencies()
  local curlOk, curlVer = checkCurl()
  return {
    { name = 'ReaImGui',         required = true,  ok = r.APIExists('ImGui_CreateContext'),
      install = 'Extensions → ReaPack → Browse packages → "ReaImGui"' },
    { name = 'curl',             required = true,  ok = curlOk,
      detail  = curlVer,
      install = 'Normalerweise vorinstalliert (Win 10+/macOS/Linux).\n   Falls nicht: https://curl.se/download.html' },
    { name = 'SWS Extension',    required = false, ok = r.APIExists('BR_PositionAtMouseCursor'),
      install = 'Download: sws-extension.org  oder via ReaPack' },
    { name = 'JS_ReaScriptAPI',  required = false, ok = r.APIExists('JS_Window_FindChildByID'),
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

local AUTOSTART_BEGIN = '-- BEGIN CuePort Sync auto-start --'
local AUTOSTART_END   = '-- END CuePort Sync auto-start --'

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
  return AUTOSTART_BEGIN .. '\n'
      .. 'do\n'
      .. '  _G.CUEPORT_STARTUP = true\n'
      .. '  local ok, err = pcall(dofile, ' .. string.format('%q', selfPath) .. ')\n'
      .. '  _G.CUEPORT_STARTUP = nil\n'
      .. '  if not ok then reaper.ShowConsoleMsg("CuePort auto-start error: " .. tostring(err) .. "\\n") end\n'
      .. 'end\n'
      .. AUTOSTART_END
end

local function isAutostartEnabled()
  local content = readFile(getStartupScriptPath()) or ''
  return content:find(AUTOSTART_BEGIN, 1, true) ~= nil
end

local function setAutostart(enable)
  local path = getStartupScriptPath()
  local content = readFile(path) or ''
  local pattern = escLuaPat(AUTOSTART_BEGIN) .. '.-' .. escLuaPat(AUTOSTART_END)
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

local INSTANCE_HB_KEY       = 'instance_hb'
local SHOW_WINDOW_REQ_KEY   = 'show_window_req'
local INSTANCE_ALIVE_WIN_SEC = 5

local function isOtherInstanceAlive()
  local hbStr = r.GetExtState(EXT_NS, INSTANCE_HB_KEY)
  local hb = tonumber(hbStr)
  if not hb then return false end
  return (r.time_precise() - hb) < INSTANCE_ALIVE_WIN_SEC
end

local function signalShowWindow()
  r.SetExtState(EXT_NS, SHOW_WINDOW_REQ_KEY, '1', false)
end

local function consumeShowWindowRequest()
  local v = r.GetExtState(EXT_NS, SHOW_WINDOW_REQ_KEY)
  if v == '1' then
    r.DeleteExtState(EXT_NS, SHOW_WINDOW_REQ_KEY, false)
    return true
  end
  return false
end

local function updateInstanceHeartbeat()
  r.SetExtState(EXT_NS, INSTANCE_HB_KEY, string.format('%.3f', r.time_precise()), false)
end

local function clearInstanceHeartbeat()
  r.DeleteExtState(EXT_NS, INSTANCE_HB_KEY, false)
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
  -- Refresh bound production info
  if state.boundProductionId then
    for _, p in ipairs(list) do
      if p.id == state.boundProductionId then state.boundProduction = p; break end
    end
    if not state.boundProduction then
      state.boundProduction = { id = state.boundProductionId, title = '(nicht gefunden)', artist_name = '' }
    end
  end
end

local function bindProduction(prod)
  setProjExt('production_id', prod.id)
  state.boundProductionId = prod.id
  state.boundProduction = prod
  state.showPickerOverride = false  -- leave the picker after a successful pick
end

local function unbindProduction()
  setProjExt('production_id', '')
  state.boundProductionId = nil
  state.boundProduction = nil
end

local function doSync()
  if not state.boundProductionId or state.syncInProgress then return end
  state.syncInProgress = true
  state.syncStatus = 'Loading comments...'
  local resp, err = apiComments(state.boundProductionId)
  state.syncInProgress = false
  if err == 'unauthorized' then
    state.errorMsg = 'Token is no longer valid — please reconnect.'
    logout()
    return
  end
  if err or not resp or not resp.ok then
    state.syncStatus = 'Error: ' .. (err or (resp and resp.error) or 'Unknown')
    return
  end
  local comments = resp.comments or {}
  local summary = syncCommentsToMarkers(comments)
  state.lastSyncResult = summary
  state.lastSyncAt = os.time()
  local v = resp.version
  local vLabel = v and (v.label or '?') or '?'
  local extra = ''
  if summary.legacyItemsRemoved and summary.legacyItemsRemoved > 0 then
    extra = string.format('  · %d legacy items migrated', summary.legacyItemsRemoved)
  end
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

local FONT_SIZE = 14
local ctx = ImGui.CreateContext('CuePort Sync')
local FONT = ImGui.CreateFont('sans-serif', FONT_SIZE)
ImGui.Attach(ctx, FONT)

-- ══════════════════════════════════════════════════════════════════════════════
-- LOGO LOADING
-- ══════════════════════════════════════════════════════════════════════════════
-- The PNG is shipped alongside the script via the ReaPack manifest
-- (<source file="cueport_icon.png">). We find it next to the running script
-- and hand the path to ImGui_CreateImage. Images must be cached — creating
-- one per frame leaks memory. The result is drawn in every window header.

local _logoImage = nil
local _logoImageChecked = false

local function getScriptDir()
  local src = debug.getinfo(1, 'S').source or ''
  if src:sub(1,1) == '@' then src = src:sub(2) end
  return src:match('^(.-)[^/\\]+$') or ''
end

local function getLogoImage()
  if _logoImageChecked then return _logoImage end
  _logoImageChecked = true
  if not r.APIExists('ImGui_CreateImage') then return nil end
  local path = getScriptDir() .. 'cueport_icon.png'
  local f = io.open(path, 'rb')
  if not f then return nil end
  f:close()
  local ok, img = pcall(r.ImGui_CreateImage, path, 0)
  if ok and img then
    -- Attach image to context so it persists across frames
    if r.ImGui_Attach then pcall(r.ImGui_Attach, ctx, img) end
    _logoImage = img
  end
  return _logoImage
end

-- ══════════════════════════════════════════════════════════════════════════════
-- CUEPORT THEME — shared styling for every script window (main + floating +
-- tooltip). Dark neutral surface, purple accents, subtle borders, rounded
-- corners, compact padding. Matches the cueport.app web UI.
-- ══════════════════════════════════════════════════════════════════════════════

local CP_COLORS = {
  accent       = 0xB088E0FF,  -- highlight purple (brand)
  accentStrong = 0x7B45C8FF,
  bg           = 0x18181CFF,  -- fully opaque dark surface
  border       = 0x3A3A3DFF,
  text         = 0xE8E8EAFF,
  textDim      = 0x8B8B92FF,
  hover        = 0x2E2E33FF,
  active       = 0x3D3D44FF,
  success      = 0x4ADE80FF,
  warn         = 0xFFA500FF,
  danger       = 0xFF4F6DFF,
}

-- Apply full CuePort theme to the next ImGui window. Returns (numColors,
-- numVars) so the caller can pop them after ImGui_End().
local function pushCueportTheme()
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
  pushVar(v_('WindowPadding'),      10, 10)
  pushVar(v_('WindowBorderSize'),   1)
  pushVar(v_('FramePadding'),       7, 4)
  pushVar(v_('FrameRounding'),      5)
  pushVar(v_('ItemSpacing'),        6, 5)
  pushVar(v_('ItemInnerSpacing'),   6, 4)
  pushVar(v_('ScrollbarRounding'),  6)
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

  -- Buttons
  pushCol(c_('Button'),             CP_COLORS.hover)
  pushCol(c_('ButtonHovered'),      CP_COLORS.accentStrong)
  pushCol(c_('ButtonActive'),       CP_COLORS.accent)

  -- Selectables (menu rows)
  pushCol(c_('Header'),             0x00000000)
  pushCol(c_('HeaderHovered'),      CP_COLORS.hover)
  pushCol(c_('HeaderActive'),       CP_COLORS.active)

  -- Inputs
  pushCol(c_('FrameBg'),            0x24242AFF)
  pushCol(c_('FrameBgHovered'),     0x2E2E34FF)
  pushCol(c_('FrameBgActive'),      0x333339FF)

  -- Checkboxes
  pushCol(c_('CheckMark'),          CP_COLORS.accent)

  -- Scrollbars
  pushCol(c_('ScrollbarBg'),        0x1D1D20FF)
  pushCol(c_('ScrollbarGrab'),      0x3A3A3DFF)
  pushCol(c_('ScrollbarGrabHovered'), 0x4A4A4DFF)
  pushCol(c_('ScrollbarGrabActive'), 0x5A5A5DFF)

  return sc, sv
end

local function popCueportTheme(sc, sv)
  if sc and sc > 0 then ImGui.PopStyleColor(ctx, sc) end
  if sv and sv > 0 then ImGui.PopStyleVar(ctx, sv) end
end

-- Window flags shared by all our windows: non-dockable, so the user can
-- position these anywhere without them snapping into Reaper's dock zones.
local function cueportWindowFlags(extra)
  local f = extra or 0
  local nd = ImGui.WindowFlags_NoDocking and ImGui.WindowFlags_NoDocking() or 0
  return f | nd
end

-- Draw the CuePort logo + wordmark at the top of a window. Uses the PNG when
-- available, falls back to a simple styled dot + text.
local function renderBrand()
  local img = getLogoImage()
  if img and r.ImGui_Image then
    pcall(r.ImGui_Image, ctx, img, 22, 22)
    ImGui.SameLine(ctx)
  else
    ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
    ImGui.Text(ctx, '●')
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
  end
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
  ImGui.Text(ctx, 'CuePort')
  ImGui.PopStyleColor(ctx)
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, 'Sync')
  if state.isPreview then
    ImGui.SameLine(ctx)
    ImGui.TextColored(ctx, CP_COLORS.warn, '[PREVIEW]')
  end

  -- Right-aligned: Settings + signed-in indicator (except on the Settings
  -- screen itself, where we show a Back link instead — handled in renderSettings).
  if state.screen ~= 'settings' then
    local winW = ImGui.GetWindowWidth(ctx)
    -- Reserve roughly 140px on the right for button + label
    local rightBlockW = 150
    ImGui.SameLine(ctx)
    ImGui.SetCursorPosX(ctx, math.max(0, winW - rightBlockW))
    if state.token then
      ImGui.TextDisabled(ctx, 'signed in  ·')
      ImGui.SameLine(ctx)
    end
    if ImGui.SmallButton(ctx, 'Settings##hdrset') then
      state.previousScreen = state.screen
      state.screen = 'settings'
    end
  end

  ImGui.Separator(ctx)
end

local function formatRelTime(ts)
  if not ts then return 'never' end
  local diff = os.time() - ts
  if diff < 60 then return 'just now' end
  if diff < 3600 then return math.floor(diff / 60) .. ' min' end
  if diff < 86400 then return math.floor(diff / 3600) .. ' h' end
  return math.floor(diff / 86400) .. ' d'
end

-- Legacy renderHeader kept as a thin shim so callers keep working; the new
-- branded header is renderBrand() defined further up.
local function renderHeader()
  renderBrand()
end

-- Forward-defined here (before renderFooter) so the upvalue resolves; the
-- full implementation is paired with renderFloatingMenu further below.
local function setFloatingMenuEnabled(v)
  state.floatingMenuEnabled = v and true or false
  setGlobalExt('floating_menu', v and '1' or '0')
end

local function renderSettings()
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.textDim)
  if ImGui.SmallButton(ctx, '‹ Back') then
    state.screen = state.previousScreen or 'main'
  end
  ImGui.PopStyleColor(ctx)
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, 'Settings')
  ImGui.Separator(ctx)
  ImGui.Dummy(ctx, 0, 4)

  -- Preview worker
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
  ImGui.Text(ctx, 'API')
  ImGui.PopStyleColor(ctx)
  local changed, val = ImGui.Checkbox(ctx, 'Use preview worker', state.isPreview)
  if changed then setPreviewMode(val) end
  ImGui.TextDisabled(ctx, state.apiUrl)

  ImGui.Dummy(ctx, 0, 10)
  ImGui.Separator(ctx)
  ImGui.Dummy(ctx, 0, 4)

  -- Auto-start
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
  ImGui.Text(ctx, 'Startup')
  ImGui.PopStyleColor(ctx)
  local asEnabled = isAutostartEnabled()
  local asChanged, asVal = ImGui.Checkbox(ctx, 'Auto-start with Reaper', asEnabled)
  if asChanged then
    local ok = setAutostart(asVal)
    if not ok then
      state.errorMsg = 'Could not enable auto-start (file permissions?).'
    end
  end
  ImGui.TextDisabled(ctx, 'Runs in the background — open the GUI any time via the Actions list.')

  ImGui.Dummy(ctx, 0, 10)
  ImGui.Separator(ctx)
  ImGui.Dummy(ctx, 0, 4)

  -- Floating menu
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
  ImGui.Text(ctx, 'Quick access')
  ImGui.PopStyleColor(ctx)
  local fmChanged, fmVal = ImGui.Checkbox(ctx, 'Show floating menu', state.floatingMenuEnabled)
  if fmChanged then setFloatingMenuEnabled(fmVal) end
  ImGui.TextDisabled(ctx, 'Small quick-access window with Sync + Open buttons.')

  ImGui.Dummy(ctx, 0, 10)
  ImGui.Separator(ctx)
  ImGui.Dummy(ctx, 0, 4)

  -- Dependencies / version / quit
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
  ImGui.Text(ctx, 'Diagnostics')
  ImGui.PopStyleColor(ctx)
  if ImGui.SmallButton(ctx, 'Check dependencies') then
    state.showDeps = true
  end
  ImGui.TextDisabled(ctx, 'Version: v' .. VERSION)
  ImGui.TextDisabled(ctx, 'Instance ID: ' .. (state.instanceId or '?'))

  ImGui.Dummy(ctx, 0, 10)
  ImGui.Separator(ctx)
  ImGui.Dummy(ctx, 0, 4)

  -- Account + quit
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
  ImGui.Text(ctx, 'Account')
  ImGui.PopStyleColor(ctx)
  if state.token and ImGui.SmallButton(ctx, 'Log out') then logout() end
  if state.token then ImGui.SameLine(ctx) end
  if ImGui.SmallButton(ctx, 'Quit script') then
    state.running = false
  end
end

-- Footer has been collapsed into the header (Settings + signed-in indicator
-- live there now). Kept as a no-op shim so the loop can still call it.
local function renderFooter() end

-- ══════════════════════════════════════════════════════════════════════════════
-- DEPENDENCIES MODAL
-- ══════════════════════════════════════════════════════════════════════════════

local function renderDepsModal()
  if not state.showDeps then return end
  ImGui.SetNextWindowSize(ctx, 500, 360, ImGui.Cond_Always and ImGui.Cond_Always() or 0)
  local sc, sv = pushCueportTheme()
  local nc = ImGui.WindowFlags_NoCollapse and ImGui.WindowFlags_NoCollapse() or 0
  local flags = cueportWindowFlags(nc)
  local visible, open = ImGui.Begin(ctx, 'CuePort · Dependencies##cpdeps', true, flags)
  if visible then
    ImGui.TextWrapped(ctx, 'CuePort Sync uses a few Reaper extensions. Required = mandatory, Recommended = for best experience.')
    ImGui.Separator(ctx)
    for _, d in ipairs(getDependencies()) do
      if d.ok then
        ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.success)
        ImGui.Text(ctx, '✓ ' .. d.name)
        ImGui.PopStyleColor(ctx)
      else
        ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.danger)
        ImGui.Text(ctx, (d.required and '✗ ' or '○ ') .. d.name .. (d.required and ' (required)' or ' (recommended)'))
        ImGui.PopStyleColor(ctx)
      end
      ImGui.Indent(ctx)
      if d.detail and d.ok then
        ImGui.TextDisabled(ctx, d.detail)
      else
        ImGui.TextDisabled(ctx, d.install)
      end
      ImGui.Unindent(ctx)
      ImGui.Dummy(ctx, 0, 4)
    end
    ImGui.Separator(ctx)
    if ImGui.Button(ctx, 'Close') then state.showDeps = false end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'Re-check') then
      -- API checks are static during a Reaper session; a restart reveals changes
      ImGui.TextDisabled(ctx, 'Restart Reaper for a fresh scan.')
    end
    ImGui.End(ctx)
  end
  popCueportTheme(sc, sv)
  if not open then state.showDeps = false end
end

local function renderLogin()
  ImGui.TextWrapped(ctx,
    'Connect this Reaper to a CuePort studio to display artist comments ' ..
    'as project markers with hover tooltips.')
  ImGui.Dummy(ctx, 0, 8)
  if ImGui.Button(ctx, 'Connect to CuePort', 220, 0) then
    startPairing()
  end
  if state.errorMsg then
    ImGui.Dummy(ctx, 0, 8)
    ImGui.TextColored(ctx, CP_COLORS.danger, state.errorMsg)
  end
end

local function renderPairing()
  ImGui.TextWrapped(ctx,
    'A browser window should have opened. Log in to the studio portal ' ..
    'and confirm the code below.')
  ImGui.Dummy(ctx, 0, 8)
  ImGui.Text(ctx, 'Your code:')
  ImGui.SameLine(ctx)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
  ImGui.Text(ctx, state.userCode or '----')
  ImGui.PopStyleColor(ctx)
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, 'Copy') then clipboardSet(state.userCode or '') end
  ImGui.Dummy(ctx, 0, 8)
  if state.verificationUrl and ImGui.Button(ctx, 'Reopen browser', 200, 0) then
    openUrl(state.verificationUrl)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Cancel', 120, 0) then cancelPairing() end

  local remaining = math.max(0, state.pairingExpiresAt - r.time_precise())
  ImGui.Dummy(ctx, 0, 8)
  ImGui.TextDisabled(ctx, string.format('Waiting for approval... (valid for %d more sec)', math.floor(remaining)))

  if state.errorMsg then
    ImGui.Dummy(ctx, 0, 6)
    ImGui.TextColored(ctx, CP_COLORS.danger, state.errorMsg)
  end
end

local function renderProductionPicker()
  -- Cancel row — only shown when there's an existing binding we could return
  -- to. Lets the user back out of a "Change project..." click without losing
  -- their current binding.
  if state.boundProductionId and state.boundProduction then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.textDim)
    if ImGui.SmallButton(ctx, '‹ Back to current project') then
      state.showPickerOverride = false
    end
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
    local bp = state.boundProduction
    ImGui.TextDisabled(ctx, (bp.artist_name or '') .. ' — ' .. (bp.title or ''))
    ImGui.Dummy(ctx, 0, 4)
  end

  ImGui.Text(ctx, 'Choose a production:')
  local ch, val = ImGui.InputTextWithHint(ctx, '##filter', 'Search...', state.filterText)
  if ch then state.filterText = val end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Refresh') then loadProductions() end

  if state.productionsFetching then
    ImGui.TextDisabled(ctx, 'Loading productions...')
    return
  end
  if state.productionsError then
    ImGui.TextColored(ctx, CP_COLORS.danger, 'Error: ' .. state.productionsError)
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

  ImGui.BeginChild(ctx, 'prodlist', 0, 360, 1)

  if totalMatches == 0 then
    ImGui.TextDisabled(ctx, filter == '' and 'No productions.' or 'No matches.')
  else
    for _, a in ipairs(order) do
      local matched = perArtist[a]
      if matched then
        -- Auto-expand when a filter is active so the user sees matches immediately
        local open = (filter ~= '') or state.expandedArtists[a]
        local arrow = open and '▼ ' or '▶ '
        local label = string.format('%s%s   (%d)', arrow, a, #matched)

        -- Artist row: slightly stronger text to distinguish from productions
        ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
        if ImGui.Selectable(ctx, label .. '##cpart_' .. a, false, 0, 0, 0) then
          state.expandedArtists[a] = not (state.expandedArtists[a])
        end
        ImGui.PopStyleColor(ctx)

        if open then
          ImGui.Indent(ctx, 16)
          for _, p in ipairs(matched) do
            local plabel = '· ' .. (p.title or '?')
            if p.feat and p.feat ~= '' then
              plabel = plabel .. '  (feat. ' .. p.feat .. ')'
            end
            if ImGui.Selectable(ctx, plabel .. '##cpprod_' .. p.id, false) then
              bindProduction(p)
            end
          end
          ImGui.Unindent(ctx, 16)
        end
      end
    end
  end

  ImGui.EndChild(ctx)
end

local function renderBound()
  local p = state.boundProduction
  ImGui.Text(ctx, 'Connected to:')
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
  ImGui.Text(ctx, (p.artist_name or '-') .. ' — ' .. (p.title or '?'))
  ImGui.PopStyleColor(ctx)
  if p.feat and p.feat ~= '' then
    ImGui.TextDisabled(ctx, 'feat. ' .. p.feat)
  end
  ImGui.Dummy(ctx, 0, 8)

  if state.syncInProgress then
    ImGui.TextDisabled(ctx, state.syncStatus or 'Syncing...')
  else
    if ImGui.Button(ctx, 'Sync comments', 260, 0) then
      doSync()
    end
  end

  if state.lastSyncResult then
    ImGui.Dummy(ctx, 0, 4)
    ImGui.TextDisabled(ctx, state.syncStatus or '')
    ImGui.TextDisabled(ctx, 'Last sync: ' .. formatRelTime(state.lastSyncAt))
  end

  -- Time-alignment hint: explain Reaper's project start offset trick so the
  -- user does not have to align their mix to project-time 0:00 manually.
  ImGui.Dummy(ctx, 0, 14)
  ImGui.Separator(ctx)
  ImGui.Dummy(ctx, 0, 6)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text(), CP_COLORS.accent)
  ImGui.Text(ctx, 'Align markers with your render')
  ImGui.PopStyleColor(ctx)
  if ImGui.PushTextWrapPos then ImGui.PushTextWrapPos(ctx, 460) end
  ImGui.TextDisabled(ctx,
    'Comments are placed relative to the start of the rendered audio. If ' ..
    'your mix does not begin at 0:00 on the Reaper timeline:')
  ImGui.TextDisabled(ctx,
    '  1. Move the edit cursor to the exact render start.')
  ImGui.TextDisabled(ctx,
    '  2. Right-click the ruler → Change start time/measure → ' ..
    '"Set 0:00 to current edit cursor".')
  ImGui.TextDisabled(ctx,
    '  3. Press Sync comments again. Markers will now line up with the audio.')
  if ImGui.PopTextWrapPos then ImGui.PopTextWrapPos(ctx) end
  local curOffset = getProjectStartOffset()
  if math.abs(curOffset) > 0.001 then
    ImGui.Dummy(ctx, 0, 4)
    ImGui.TextColored(ctx, CP_COLORS.success,
      string.format('Project start offset detected: %.2fs', curOffset))
  end

  ImGui.Dummy(ctx, 0, 12)
  if ImGui.SmallButton(ctx, 'Choose different production') then
    -- Don't unbind yet — just surface the picker. The user can Cancel back
    -- to the current binding if they change their mind.
    state.showPickerOverride = true
  end
end

local function renderMain()
  if not state.productions and not state.productionsFetching and not state.productionsError then
    loadProductions()
  end
  -- Show the bound view unless the user has explicitly asked to pick another
  -- production (via "Change project..." in either the main window or the
  -- floating menu). The override keeps the existing binding intact so the
  -- user can Cancel back to it without losing their choice.
  local showPicker = (not state.boundProductionId) or state.showPickerOverride
  if showPicker then
    renderProductionPicker()
  else
    renderBound()
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN LOOP
-- ══════════════════════════════════════════════════════════════════════════════

local function decideInitialScreen()
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
-- so that renderFooter's upvalue resolution picks up the correct local.

-- Get project time at the mouse cursor. Prefers SWS's BR_PositionAtMouseCursor
-- which handles Retina/multi-display/ruler-vs-arrange automatically. Falls
-- back to manual math via JS_ReaScriptAPI only if SWS isn't installed.
local function mouseTimeAtCursor()
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

local function findCueportMarkerNearMouse()
  local t = mouseTimeAtCursor()
  if not t then return nil end
  local pxPerSec = r.GetHZoomLevel()
  if not pxPerSec or pxPerSec <= 0 then pxPerSec = 100 end
  local tolSec = 10 / pxPerSec  -- ±10 screen pixels
  local markers = enumerateCueportMarkers()
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

local function renderHoverTip()
  if not hover.enabled then return end
  local mx, my = r.GetMousePosition()
  if not mx or not my then return end

  local author, text, pos
  local foundSource = nil

  -- First: check CuePort markers near mouse X (primary data source in v1.3+).
  -- Marker name only contains "CP @Author: MM:SS" — full text lives in the
  -- ProjExtState cache, looked up by position.
  local m = findCueportMarkerNearMouse()
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
        local _, tmark = r.GetSetMediaTrackInfo_String(track, TRACK_MARKER_EXT_KEY, '', false)
        local _, fid = r.GetSetMediaItemInfo_String(item, ITEM_FB_ID_EXT_KEY, '', false)
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
  local flags = cueportWindowFlags(baseFlags)
  local tsc, tsv = pushCueportTheme()

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
  popCueportTheme(tsc, tsv)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- FLOATING MENU — small persistent quick-access bar (always visible when on)
-- ══════════════════════════════════════════════════════════════════════════════
-- Tiny ImGui window with Sync + Show buttons and the bound production name.
-- Opt-in via settings. Persisted in global ExtState. Position handled by
-- ImGui's own layout state (drag to move, ImGui remembers it across sessions
-- via its built-in .ini storage in the Reaper resource folder).

-- Tiny helper: truncate a string to max `n` characters adding an ellipsis.
local function truncate(s, n)
  s = s or ''
  if #s <= n then return s end
  return s:sub(1, n - 1) .. '…'
end

local function renderFloatingMenu()
  if not state.floatingMenuEnabled then return end
  if not state.token then return end

  local NoTitle  = ImGui.WindowFlags_NoTitleBar      and ImGui.WindowFlags_NoTitleBar()      or 0
  local NoResz   = ImGui.WindowFlags_NoResize        and ImGui.WindowFlags_NoResize()        or 0
  local AutoSize = ImGui.WindowFlags_AlwaysAutoResize and ImGui.WindowFlags_AlwaysAutoResize() or 0
  local NoFocus  = ImGui.WindowFlags_NoFocusOnAppearing and ImGui.WindowFlags_NoFocusOnAppearing() or 0
  local NoColl   = ImGui.WindowFlags_NoCollapse      and ImGui.WindowFlags_NoCollapse()      or 0
  local NoNav    = ImGui.WindowFlags_NoNav           and ImGui.WindowFlags_NoNav()           or 0
  local NoMove   = ImGui.WindowFlags_NoMove          and ImGui.WindowFlags_NoMove()          or 0
  local pillFlags = cueportWindowFlags(NoTitle | NoResz | AutoSize | NoFocus | NoColl | NoNav)
  local menuFlags = cueportWindowFlags(NoTitle | NoResz | AutoSize | NoFocus | NoColl | NoNav | NoMove)

  ImGui.SetNextWindowPos(ctx, 60, 60, ImGui.Cond_FirstUseEver())

  -- Shared CuePort theme for the pill
  local pillSc, pillSv = pushCueportTheme()

  local pillX, pillY, pillH = 0, 0, 0
  local pillToggleRequested = false

  local visible = ImGui.Begin(ctx, '##cueportFloat', false, pillFlags)
  if visible then
    -- ── Pill content: logo + "CuePort Sync" + optional "syncing…" hint ────
    local img = getLogoImage()
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
  popCueportTheme(pillSc, pillSv)

  if pillToggleRequested then
    state.floatMenuOpen = not state.floatMenuOpen
  end

  -- ── Menu window (separate, persistent until the pill is clicked again) ──
  if state.floatMenuOpen then
    -- Align flush under the pill (1 px overlap hides the double-border seam)
    ImGui.SetNextWindowPos(ctx, pillX, pillY + pillH - 1)
    local menuSc, menuSv = pushCueportTheme()
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
    popCueportTheme(menuSc, menuSv)
  end
end

local function loop()
  -- Single-instance: if another invocation wrote a newer heartbeat, this
  -- instance has been superseded → exit quietly.
  if state.supersededCheck then
    -- heartbeat is ours if it's within threshold AND was written by us.
    -- We track our own last-written value to detect takeover.
    local hbStr = r.GetExtState(EXT_NS, INSTANCE_HB_KEY)
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
  r.SetExtState(EXT_NS, INSTANCE_HB_KEY, hbVal, false)
  state.lastHbWritten = hbVal
  state.supersededCheck = true

  -- Poll pairing if active
  if state.screen == 'pairing' then pollPairing() end

  ImGui.PushFont(ctx, FONT, FONT_SIZE)

  -- Hover tooltip is always on and runs even when the main window is hidden —
  -- that way users still get comment info while the GUI is out of the way.
  renderHoverTip()
  renderFloatingMenu()

  if state.windowVisible then
    -- Fixed window size — NoResize prevents user drag-resize, Cond_Always
    -- re-applies size every frame so it can't drift.
    local MAIN_W, MAIN_H = 520, 600
    ImGui.SetNextWindowSize(ctx, MAIN_W, MAIN_H, ImGui.Cond_Always and ImGui.Cond_Always() or 0)
    local sc, sv = pushCueportTheme()
    local noResize = ImGui.WindowFlags_NoResize and ImGui.WindowFlags_NoResize() or 0
    local flags = cueportWindowFlags(noResize)
    local visible, open = ImGui.Begin(ctx, 'CuePort Sync##cpmain', true, flags)
    if visible then
      renderHeader()

      if state.screen == 'login'       then renderLogin()
      elseif state.screen == 'pairing'  then renderPairing()
      elseif state.screen == 'settings' then renderSettings()
      elseif state.screen == 'main'     then renderMain()
      end

      -- Footer only on the "working" screens — the settings screen has its
      -- own back button so no footer is needed there.
      if state.screen ~= 'settings' then
        ImGui.Dummy(ctx, 0, 10)
        renderFooter()
      end
      ImGui.End(ctx)
    end
    popCueportTheme(sc, sv)
    renderDepsModal()
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
      msg = msg .. '• ' .. d.name .. '\n   ' .. d.install .. '\n'
    end
    msg = msg .. '\nPlease install and restart Reaper.'
    r.MB(msg, 'CuePort Sync · Missing dependency', 0)
    return
  end

  -- Single-instance: if another recent heartbeat is present, just signal
  -- "show window" to it and exit this invocation without starting a GUI.
  if isOtherInstanceAlive() then
    signalShowWindow()
    return
  end

  state.instanceId = string.format('%x', math.floor(r.time_precise() * 1000) % 0xFFFFFF)
  state.running = true

  -- When triggered by the auto-start shim in __startup.lua, begin hidden.
  -- User opens the GUI by running the same action again (single-instance
  -- handshake sets `show_window_req` which the running loop consumes).
  state.windowVisible = not (_G.CUEPORT_STARTUP == true)
  state.floatingMenuEnabled = (getGlobalExt('floating_menu') == '1')

  loadState()
  decideInitialScreen()
  r.defer(loop)
end
