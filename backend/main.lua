-- Lua — backend entry point (Millennium Lua plugin)
-- All exported functions return JSON strings and take a single `payload`
-- (JSON string of args) to avoid Millennium's alphabetical-arg ordering issues.

local cjson      = require("json")
local m_utils    = require("utils")
local millennium = require("millennium")
local fs         = require("fs")
local logger     = require("logger")
local luaedit    = require("luaedit")
local m_http     = nil
pcall(function() m_http = require("http") end)

-- ── helpers ──────────────────────────────────────────────────────────────────

local function log(msg) pcall(function() logger:info("[OSTLua] " .. tostring(msg)) end) end

local function json_ok(t)
    local ok, s = pcall(cjson.encode, t)
    if ok then return s end
    return '{"success":false,"error":"encode failed"}'
end
local function json_err(m) return json_ok({ success = false, error = tostring(m) }) end

local function parse_payload(payload)
    if type(payload) == "table" then return payload end
    if type(payload) == "string" and payload ~= "" then
        local ok, d = pcall(cjson.decode, payload)
        if ok and type(d) == "table" then return d end
    end
    return {}
end

local function steam_dir()
    local ok, p = pcall(millennium.steam_path)
    if ok and p and p ~= "" then return p end
    return "C:/Program Files (x86)/Steam"
end

local function backend_dir()
    local ok, be = pcall(function() return m_utils.get_backend_path() end)
    if ok and be and be ~= "" then return fs.absolute(be) end
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    if src:sub(1, 1) == "@" then
        local dir = src:sub(2):match("(.*[/\\])")
        if dir then return fs.absolute(dir:sub(1, -2)) end
    end
    return fs.current_path()
end
local function plugin_dir() return fs.absolute(fs.join(backend_dir(), "..")) end

local function read_config()
    local p = fs.join(backend_dir(), "config.json")
    local ok, d = pcall(function() return cjson.decode(m_utils.read_file(p) or "{}") end)
    return (ok and type(d) == "table") and d or {}
end

-- Lua download sources. Hubcap needs the API key (auth); the others are
-- free/keyless. "{appid}" is substituted per request. An unknown saved
-- main_source (e.g. the retired TwentyTwo Cloud) falls back to Hubcap.
local SOURCES = {
    { id = "hubcap",    name = "Hubcap",          auth = true  },  -- url from api_base
    { id = "ryuu",      name = "Ryuu",            auth = false, url = "http://167.235.229.108/{appid}" },
    { id = "sushi",     name = "Sushi",           auth = false, url = "https://raw.githubusercontent.com/sushi-dev55-alt/sushitools-games-repo-alt/refs/heads/main/{appid}.zip" },
    { id = "revobd",    name = "Revo",            auth = false, url = "https://api.luagen.revobd.club/{appid}.zip" },
}

local function source_url(s, appid, cfg)
    if s.id == "hubcap" then
        return (cfg.api_base or "https://hubcapmanifest.com/api/v1") .. "/manifest/" .. appid
    end
    return (s.url:gsub("{appid}", appid))
end

-- Ordered list the installer tries: chosen main source first, then (only if the
-- fallback toggle is on) every other source.
local function build_source_order(appid, cfg)
    local main = cfg.main_source or "hubcap"
    local fallback = cfg.fallback == true
    local order, main_found = {}, false
    for _, s in ipairs(SOURCES) do
        if s.id == main then
            order[#order + 1] = { name = s.name, url = source_url(s, appid, cfg), auth = s.auth }
            main_found = true
        end
    end
    if not main_found then
        local h = SOURCES[1]
        order[1] = { name = h.name, url = source_url(h, appid, cfg), auth = h.auth }
        main = "hubcap"
    end
    if fallback then
        for _, s in ipairs(SOURCES) do
            if s.id ~= main then
                order[#order + 1] = { name = s.name, url = source_url(s, appid, cfg), auth = s.auth }
            end
        end
    end
    return order
end

-- BetterSteamTools reads luas from <Steam>/config/stplug-in (see BST
-- dllmain.cpp: "%s\\config\\stplug-in"). The old OpenSteamTool default was
-- <Steam>/config/lua, so that stays in the candidate list for reads — installs
-- go to whichever folder lua_dir_name points at (stplug-in by default).
local DEFAULT_LUA_DIR = "stplug-in"

local function lua_dir_candidates()
    local s = steam_dir()
    local cfg = read_config()
    local name = cfg.lua_dir_name or DEFAULT_LUA_DIR
    return {
        fs.join(s, "config", name),         -- primary (BST default: config/stplug-in)
        fs.join(s, "config", "stplug-in"),
        fs.join(s, "config", "lua"),        -- legacy OpenSteamTool location
        fs.join(s, "config", "hubcap-lua"), -- legacy Hubcap installs
    }
end

local function find_game_lua(appid)
    for _, d in ipairs(lua_dir_candidates()) do
        local p = fs.join(d, tostring(appid) .. ".lua")
        if fs.exists(p) then return p end
    end
    return nil
end

local function ensure_data_dir()
    local d = fs.join(backend_dir(), "data")
    if not fs.exists(d) then pcall(fs.create_directories, d) end
    return d
end

local function drop_file(path) pcall(fs.remove, path) end

-- data/ holds one-shot scratch files per job (launcher .cmd, the source list,
-- the helper's result, the grabbed clipboard). Nothing re-reads them once the
-- job is done, so they'd otherwise pile up forever — one set per app/depot the
-- user ever touched. Cleared at boot, when nothing can be in flight.
--
-- manifests_*.json is the cached SteamDB version list, so it's kept (it saves a
-- re-scrape) but expired after MANIFEST_CACHE_DAYS. usage_cache.json is the
-- Hubcap quota cache and is always kept.
local MANIFEST_CACHE_DAYS = 14

local function sweep_data_dir()
    local dir = ensure_data_dir()
    local ok, entries = pcall(fs.list, dir)
    if not ok or type(entries) ~= "table" then return end

    -- Only age-expire when the clock really looks like epoch SECONDS; if the
    -- runtime ever hands back ms (or anything odd), skip expiry rather than
    -- nuking the version cache on every boot.
    local now = tonumber(select(2, pcall(m_utils.time))) or 0
    if now < 1600000000 or now > 4000000000 then now = 0 end
    local max_age = MANIFEST_CACHE_DAYS * 86400
    local removed = 0

    for _, entry in ipairs(entries) do
        -- fs.list yields { name, path, is_file, is_directory, ... } per entry
        local name = type(entry) == "table" and entry.name or tostring(entry)
        name = tostring(name):match("([^/\\]+)$") or tostring(name)
        local path = (type(entry) == "table" and entry.path) or fs.join(dir, name)
        local is_file = (type(entry) ~= "table") or (entry.is_file ~= false)
        local transient = is_file and (
            name:match("^run_install_%d+%.cmd$") or
            name:match("^run_grab_%d+%.cmd$")    or
            name:match("^sources_%d+%.json$")    or
            name:match("^install_%d+%.json$")    or
            name:match("^clip_%d+%.txt$")        or
            name == "restart_steam.cmd")

        if transient then
            drop_file(path); removed = removed + 1
        elseif is_file and name:match("^manifests_%d+%.json$") and now > 0 then
            local tok, mtime = pcall(fs.last_write_time, path)
            mtime = tonumber(mtime)
            -- only expire when the timestamp looks like sane epoch seconds
            if tok and mtime and mtime > 0 and (now - mtime) > max_age then
                drop_file(path); removed = removed + 1
            end
        end
    end

    if removed > 0 then log("cleanup: removed " .. removed .. " stale file(s) from data/") end
end

-- ── webkit injection ─────────────────────────────────────────────────────────

-- Millennium >= 3.4.0 loads a plugin's webkit script from a fixed path inside the
-- plugin itself: <plugin>/.millennium/Dist/webkit.js (see plugin_manager.cc,
-- plugin_webkit_path). The old route — copy into <steam>/steamui/webkit and
-- register it with add_browser_js — stopped injecting after 3.4.0's CEF/loopback
-- hook refactor, which is why the UI vanished.
--
-- We keep BOTH: Dist/webkit.js is what 3.4.0+ actually loads, and the steamui
-- copy keeps 3.3.x working. Writing Dist/webkit.js here also self-heals it if the
-- user updates public/ostlua.js by hand.
local function copy_and_inject_webkit()
    local src = fs.join(plugin_dir(), "public", "ostlua.js")
    local content = fs.exists(src) and m_utils.read_file(src) or nil

    -- 1) modern path (Millennium >= 3.4.0)
    if content then
        local dist = fs.join(plugin_dir(), ".millennium", "Dist")
        if not fs.exists(dist) then pcall(fs.create_directories, dist) end
        local wk = fs.join(dist, "webkit.js")
        -- only rewrite when it actually differs, so we don't touch mtime every boot
        if m_utils.read_file(wk) ~= content then
            pcall(m_utils.write_file, wk, content)
        end
    end

    -- 2) legacy path (Millennium <= 3.3.x) — harmless no-op on newer builds
    local s = steam_dir()
    local target = fs.join(s, "steamui", "webkit")
    if not fs.exists(target) then pcall(fs.create_directories, target) end
    if content then pcall(m_utils.write_file, fs.join(target, "ostlua.js"), content) end
    pcall(millennium.add_browser_js, "webkit/ostlua.js")
end

-- ── exported IPC ─────────────────────────────────────────────────────────────

-- status: installed? + the MAIN game depot's freeze info (DLC depots ignored)
function HubcapStatus(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local appid = tostring(p.appid or "")
        local glua = find_game_lua(appid)
        if not glua then
            return { success = true, installed = false }
        end
        local content = m_utils.read_file(glua) or ""
        local md = luaedit.main_depot(content, appid)
        local depot = md and luaedit.depot_status(content, md) or nil
        return { success = true, installed = true, luaPath = glua, mainDepot = md, depot = depot }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- SteamDB scraper storage: the scraper (running on the steamdb tab) posts the
-- manifest list here; the dialog reads it to populate the version dropdown.
local function manifests_path(depot)
    return fs.join(ensure_data_dir(), "manifests_" .. tostring(depot) .. ".json")
end

function HubcapSaveManifests(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local depot = tostring(p.depot or p.depotid or "")
        if depot == "" then return { success = false, error = "no depot" } end
        local list = p.manifests
        if type(list) == "string" then local dok, dd = pcall(cjson.decode, list); if dok then list = dd end end
        if type(list) ~= "table" then list = {} end
        m_utils.write_file(manifests_path(depot), cjson.encode({ depot = depot, manifests = list }))
        return { success = true, count = #list }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function HubcapGetManifests(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local depot = tostring(p.depot or p.depotid or "")
        local pth = manifests_path(depot)
        if not fs.exists(pth) then return { success = true, manifests = {} } end
        local rc = m_utils.read_file(pth)
        if not rc or rc == "" then return { success = true, manifests = {} } end
        rc = rc:gsub("^\239\187\191", "")
        local dok, dd = pcall(cjson.decode, rc)
        if not dok or type(dd) ~= "table" then return { success = true, manifests = {} } end
        return { success = true, manifests = dd.manifests or {} }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

local function install_result_path(appid)
    return fs.join(ensure_data_dir(), "install_" .. tostring(appid) .. ".json")
end

-- install: launch the PowerShell helper via a launcher .cmd (proven pattern),
-- fully detached. The frontend polls HubcapInstallStatus for the result.
function HubcapInstall(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local appid = tostring(p.appid or "")
        if appid == "" or not appid:match("^%d+$") then return { success = false, error = "invalid appid" } end
        log("install: begin appid=" .. appid)
        local s = steam_dir()
        local pd = plugin_dir()
        local script = fs.join(pd, "backend", "scripts", "ostlua_install.ps1")
        local result_file = install_result_path(appid)
        pcall(fs.remove, result_file)
        -- write the ordered source list (main first, then fallbacks if enabled)
        local sources_file = fs.join(ensure_data_dir(), "sources_" .. appid .. ".json")
        m_utils.write_file(sources_file, cjson.encode(build_source_order(appid, read_config())))
        local args = '-AppId ' .. appid .. ' -SteamPath "' .. s .. '" -PluginDir "' .. pd ..
                     '" -ResultFile "' .. result_file .. '" -SourcesFile "' .. sources_file .. '"'
        local launcher = fs.join(ensure_data_dir(), "run_install_" .. appid .. ".cmd")
        local body = "@echo off\r\n" ..
            'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' ..
            script .. '" ' .. args .. "\r\n"
        m_utils.write_file(launcher, body)
        log("install: launcher written, exec-ing")
        m_utils.exec('start /b cmd /C "' .. launcher .. '"')
        log("install: exec returned")
        return { success = true, started = true }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- poll the install result written by the detached PowerShell helper
function HubcapInstallStatus(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local appid = tostring(p.appid or "")
        local result_file = install_result_path(appid)
        if not fs.exists(result_file) then return { success = true, state = "running" } end
        local rc = m_utils.read_file(result_file)
        if not rc or rc == "" then return { success = true, state = "running" } end
        rc = rc:gsub("^\239\187\191", "")  -- strip UTF-8 BOM if present
        log("install: reading result for " .. appid)
        local rok, rd = pcall(cjson.decode, rc)
        if not rok or type(rd) ~= "table" then return { success = true, state = "running" } end
        rd.state = "done"
        log("install: result done success=" .. tostring(rd.success))
        -- job finished: the launcher + source list are never read again. The
        -- result file itself stays until the next install (which clears it) so
        -- a duplicate in-flight poll still resolves instead of hanging.
        drop_file(fs.join(ensure_data_dir(), "run_install_" .. appid .. ".cmd"))
        drop_file(fs.join(ensure_data_dir(), "sources_" .. appid .. ".json"))
        return rd
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- Hubcap daily usage (for the settings UI). api_key passed as query param,
-- matching the pattern the older plugin used successfully.
function HubcapUsage(contentScriptQuery, payload)
    local ok, res = pcall(function()
        if not m_http then return { success = false, error = "http unavailable" } end
        local cfg = read_config()
        local key = tostring(cfg.api_key or "")
        if key == "" then return { success = false, error = "no key" } end
        local base = cfg.api_base or "https://hubcapmanifest.com/api/v1"
        local url = base .. "/user/stats?api_key=" .. key
        local cache_path = fs.join(ensure_data_dir(), "usage_cache.json")
        local function cached_limit()
            local rc = m_utils.read_file(cache_path)
            if rc and rc ~= "" then
                rc = rc:gsub("^\239\187\191", "")
                local dok, dd = pcall(cjson.decode, rc)
                if dok and type(dd) == "table" and dd.daily_limit then return dd.daily_limit end
            end
            return nil
        end

        local hok, resp = pcall(m_http.get, url, { timeout = 8 })
        local status = (hok and resp and resp.status) or nil

        -- Good response: read + cache the numbers.
        if hok and resp and resp.body and resp.body ~= "" then
            local dok, d = pcall(cjson.decode, resp.body)
            if dok and type(d) == "table" then
                local usage, limit = d.daily_usage, d.daily_limit
                if limit == nil and type(d.data) == "table" then usage, limit = d.data.daily_usage, d.data.daily_limit end
                if limit ~= nil then
                    pcall(m_utils.write_file, cache_path, cjson.encode({ daily_limit = limit, daily_usage = usage }))
                    return { success = true, dailyUsage = usage, dailyLimit = limit, status = status }
                end
            end
        end

        -- 429 = daily quota spent (empty body). Report 0 left, using the last known
        -- limit so the counter keeps showing "0 / limit" instead of disappearing.
        if status == 429 then
            local cl = cached_limit()
            if cl ~= nil then return { success = true, dailyUsage = cl, dailyLimit = cl, exhausted = true, status = 429 } end
            return { success = true, exhausted = true, dailyUsage = 0, dailyLimit = 0, status = 429 }
        end
        return { success = false, error = "stats request failed", status = status }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- remove: delete the installed lua (uninstall the game's manifest config)
function HubcapRemove(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local appid = tostring(p.appid or "")
        local glua = find_game_lua(appid)
        if not glua then return { success = false, error = "not installed" } end
        pcall(fs.remove, glua)
        return { success = true, appid = appid, removed = glua }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- freeze / downgrade a depot to a chosen manifest id
function HubcapFreeze(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local appid = tostring(p.appid or "")
        local depot = tostring(p.depotid or p.depot or "")
        local target = tostring(p.manifestid or p.manifest or "")
        if depot == "" or target == "" then return { success = false, error = "depot and manifestid required" } end
        local glua = find_game_lua(appid)
        if not glua then return { success = false, error = "game lua not installed" } end
        local content = m_utils.read_file(glua)
        if not content then return { success = false, error = "failed to read lua" } end
        local newc, changed, msg = luaedit.freeze(content, depot, target)
        if changed then m_utils.write_file(glua, newc) end
        log("freeze appid=" .. appid .. " depot=" .. depot .. " -> " .. target .. " (" .. tostring(msg) .. ")")
        return { success = true, changed = changed, message = msg, depot = depot, manifest = target }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- revert a depot back to the original manifest
function HubcapRevert(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local appid = tostring(p.appid or "")
        local depot = tostring(p.depotid or p.depot or "")
        local glua = find_game_lua(appid)
        if not glua then return { success = false, error = "game lua not installed" } end
        local content = m_utils.read_file(glua)
        if not content then return { success = false, error = "failed to read lua" } end
        local newc, changed, msg = luaedit.revert(content, depot)
        if changed then m_utils.write_file(glua, newc) end
        log("revert appid=" .. appid .. " depot=" .. depot .. " (" .. tostring(msg) .. ")")
        return { success = true, changed = changed, message = msg, depot = depot }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- Grab the clipboard (optionally auto-copying the SteamDB window first) so the
-- version list can be read without the (blocked) browser clipboard API.
local function clip_result_path(depot) return fs.join(ensure_data_dir(), "clip_" .. tostring(depot) .. ".txt") end

function HubcapGrabClipboard(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local depot = tostring(p.depot or p.depotid or "")
        local auto = (p.auto == true or p.auto == 1 or p.auto == "1") and 1 or 0
        local pd = plugin_dir()
        local script = fs.join(pd, "backend", "scripts", "ostlua_grab.ps1")
        local result_file = clip_result_path(depot)
        pcall(fs.remove, result_file)
        local title = "Depot " .. depot
        local launcher = fs.join(ensure_data_dir(), "run_grab_" .. depot .. ".cmd")
        local body = "@echo off\r\n" ..
            'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. script ..
            '" -ResultFile "' .. result_file .. '" -Auto ' .. auto .. ' -Title "' .. title .. '"\r\n'
        m_utils.write_file(launcher, body)
        m_utils.exec('start /b cmd /C "' .. launcher .. '"')
        return { success = true, started = true }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function HubcapGrabResult(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local depot = tostring(p.depot or p.depotid or "")
        local result_file = clip_result_path(depot)
        if not fs.exists(result_file) then return { success = true, state = "running" } end
        local rc = m_utils.read_file(result_file)
        if rc == nil then return { success = true, state = "running" } end
        rc = rc:gsub("^\239\187\191", "")
        -- the grabbed page text can be hundreds of KB; drop it (and the
        -- launcher) now that it's been handed to the frontend.
        drop_file(fs.join(ensure_data_dir(), "run_grab_" .. depot .. ".cmd"))
        drop_file(result_file)
        return { success = true, state = "done", text = rc }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- restart the Steam client. The relauncher is launched via explorer.exe so it
-- reparents to the shell (breaks away from Steam's job object) and survives
-- Steam's shutdown; it then waits for steam.exe to fully exit before relaunching.
function HubcapRestartSteam(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local s = steam_dir():gsub("/", "\\")
        local exe = s .. "\\steam.exe"
        local cmd = table.concat({
            "@echo off",
            'start "" "' .. exe .. '" -shutdown',
            ":wait",
            "ping -n 2 127.0.0.1 >nul",
            'tasklist /fi "imagename eq steam.exe" | find /i "steam.exe" >nul',
            "if not errorlevel 1 goto wait",
            "ping -n 3 127.0.0.1 >nul",
            'start "" "' .. exe .. '"',
            "del \"%~f0\"",
        }, "\r\n") .. "\r\n"
        local f = fs.join(ensure_data_dir(), "restart_steam.cmd")
        m_utils.write_file(f, cmd)
        -- explorer.exe hands the .cmd to the persistent shell process, detaching
        -- it from steamwebhelper so it isn't killed when Steam closes.
        m_utils.exec('explorer.exe "' .. f .. '"')
        return { success = true }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- return config (masked api key) for the settings UI
function HubcapGetConfig(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local cfg = read_config()
        local key = tostring(cfg.api_key or "")
        local masked = ""
        if #key > 12 then masked = key:sub(1, 8) .. "\226\128\166" .. key:sub(-4)
        elseif #key > 0 then masked = "(set)" end
        local srcs = {}
        for _, s in ipairs(SOURCES) do srcs[#srcs + 1] = { id = s.id, name = s.name, keyed = s.auth == true } end
        return { success = true, hasKey = #key > 0, apiKeyMasked = masked, apiBase = cfg.api_base or "",
                 sources = srcs, mainSource = cfg.main_source or "hubcap", fallback = cfg.fallback == true }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- save a new api key into config.json
function HubcapSetApiKey(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local key = tostring(p.apiKey or p.key or ""):gsub("%s+", "")
        local cfg = read_config()
        cfg.api_key = key  -- empty string clears the saved key
        if not cfg.api_base then cfg.api_base = "https://hubcapmanifest.com/api/v1" end
        if not cfg.lua_dir_name then cfg.lua_dir_name = DEFAULT_LUA_DIR end
        m_utils.write_file(fs.join(backend_dir(), "config.json"), cjson.encode(cfg))
        return { success = true, cleared = (key == "") }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- save the chosen main source + fallback toggle into config.json
function HubcapSetSourcePrefs(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local cfg = read_config()
        if p.mainSource ~= nil then
            local id = tostring(p.mainSource)
            local valid = false
            for _, s in ipairs(SOURCES) do if s.id == id then valid = true end end
            if valid then cfg.main_source = id end
        end
        if p.fallback ~= nil then
            cfg.fallback = (p.fallback == true or p.fallback == 1 or p.fallback == "true")
        end
        m_utils.write_file(fs.join(backend_dir(), "config.json"), cjson.encode(cfg))
        return { success = true, mainSource = cfg.main_source or "hubcap", fallback = cfg.fallback == true }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- open a URL (e.g. the SteamDB manifest page) in the default browser
function HubcapOpenUrl(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local url = tostring(p.url or "")
        if not (url:sub(1, 8) == "https://" or url:sub(1, 7) == "http://") then
            return { success = false, error = "invalid url" }
        end
        pcall(m_utils.exec, 'start "" "' .. url .. '"')
        return { success = true }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- ── migration: OpenSteamTool config/lua -> BetterSteamTools config/stplug-in ─
-- BST only reads <Steam>/config/stplug-in, so luas installed by older OSTLua
-- builds (into config/lua) are invisible to it. We never move anything on our
-- own — the frontend asks first, and HubcapMigrateRun only runs on a yes.

local function migrate_flag_path() return fs.join(ensure_data_dir(), "migrated.json") end

local function list_luas(dir)
    local out = {}
    if not fs.exists(dir) then return out end
    local ok, entries = pcall(fs.list, dir)
    if not ok or type(entries) ~= "table" then return out end
    for _, e in ipairs(entries) do
        local name = type(e) == "table" and e.name or tostring(e)
        name = tostring(name):match("([^/\\]+)$") or tostring(name)
        local is_file = (type(e) ~= "table") or (e.is_file ~= false)
        if is_file and name:lower():match("%.lua$") then out[#out + 1] = name end
    end
    return out
end

-- What still needs moving: .lua files present in the old dir but NOT already in
-- the new one (an existing file at the destination always wins — never clobber).
local function migration_plan()
    local s = steam_dir()
    local cfg = read_config()
    local dest_name = cfg.lua_dir_name or DEFAULT_LUA_DIR
    local from = fs.join(s, "config", "lua")
    local to   = fs.join(s, "config", dest_name)
    if from == to then return { from = from, to = to, files = {}, conflicts = {} } end

    local have = {}
    for _, n in ipairs(list_luas(to)) do have[n:lower()] = true end

    local files, conflicts = {}, {}
    for _, n in ipairs(list_luas(from)) do
        if have[n:lower()] then conflicts[#conflicts + 1] = n else files[#files + 1] = n end
    end
    return { from = from, to = to, files = files, conflicts = conflicts }
end

-- pending = how many luas are still stranded in the old folder.
function HubcapMigrateStatus(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = migration_plan()
        local dismissed = fs.exists(migrate_flag_path())
        return { success = true, pending = #p.files, conflicts = #p.conflicts,
                 from = p.from, to = p.to, dismissed = dismissed }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- Remember the user said "not now" so we stop asking on every boot.
function HubcapMigrateDismiss(contentScriptQuery, payload)
    local ok, res = pcall(function()
        pcall(m_utils.write_file, migrate_flag_path(), cjson.encode({ dismissed = true }))
        return { success = true }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function HubcapMigrateRun(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = migration_plan()
        if #p.files == 0 then
            pcall(m_utils.write_file, migrate_flag_path(), cjson.encode({ dismissed = true }))
            return { success = true, moved = 0, failed = 0, skipped = #p.conflicts }
        end
        if not fs.exists(p.to) then pcall(fs.create_directories, p.to) end

        local moved, failed = 0, 0
        for _, name in ipairs(p.files) do
            local src, dst = fs.join(p.from, name), fs.join(p.to, name)
            -- rename first (fast, same volume); fall back to copy+delete
            local rok = pcall(fs.rename, src, dst)
            if not rok or not fs.exists(dst) then
                local content = m_utils.read_file(src)
                if content and pcall(m_utils.write_file, dst, content) and fs.exists(dst) then
                    pcall(fs.remove, src)
                    rok = true
                else
                    rok = false
                end
            end
            if rok then moved = moved + 1 else failed = failed + 1 end
        end

        log("migrate: moved " .. moved .. " lua(s) to " .. p.to ..
            " (skipped " .. #p.conflicts .. ", failed " .. failed .. ")")
        if failed == 0 then
            pcall(m_utils.write_file, migrate_flag_path(), cjson.encode({ dismissed = true }))
        end
        return { success = true, moved = moved, failed = failed, skipped = #p.conflicts, to = p.to }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

-- First run: write config.json with defaults so nobody has to create it by hand
-- and the install helper always finds one. The API key / source are set in the UI.
local function ensure_config()
    local p = fs.join(backend_dir(), "config.json")
    if fs.exists(p) then return end
    local defaults = { lua_dir_name = DEFAULT_LUA_DIR, api_base = "https://hubcapmanifest.com/api/v1",
                       api_key = "", main_source = "hubcap", fallback = false }
    pcall(function() m_utils.write_file(p, cjson.encode(defaults)) end)
end

local function on_load()
    log("Bootstrapping OSTLua, millennium " .. tostring(select(2, pcall(millennium.version))))
    ensure_config()
    pcall(sweep_data_dir)
    copy_and_inject_webkit()
    pcall(millennium.ready)
end

local function on_unload() log("unloading") end
local function on_frontend_loaded() copy_and_inject_webkit() end

return {
    on_load = on_load,
    on_unload = on_unload,
    on_frontend_loaded = on_frontend_loaded,
}
