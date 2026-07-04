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

-- Lua download sources (same set LuaTools used). Hubcap needs the API key
-- (auth). The others are free/keyless. "{appid}" is substituted per request.
local SOURCES = {
    { id = "hubcap",    name = "Hubcap",          auth = true  },  -- url from api_base
    { id = "ryuu",      name = "Ryuu",            auth = false, url = "http://167.235.229.108/{appid}" },
    { id = "twentytwo", name = "TwentyTwo Cloud", auth = false, url = "https://api.twentytwocloud.com/download?appid={appid}" },
    { id = "sushi",     name = "Sushi",           auth = false, url = "https://raw.githubusercontent.com/sushi-dev55-alt/sushitools-games-repo-alt/refs/heads/main/{appid}.zip" },
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

-- Loader selection: which tool reads the luas, which decides the folder.
--   steamidra (default) -> config/stplug-in   |   ost -> config/lua
local LOADER_DIR = { steamidra = "stplug-in", ost = "lua" }
local function loader_id(cfg)
    local l = cfg and cfg.loader
    if l == "ost" or l == "steamidra" then return l end
    return "steamidra"
end
local function loader_dir_name(cfg) return LOADER_DIR[loader_id(cfg)] end

local function lua_dir_candidates()
    local s = steam_dir()
    local cfg = read_config()
    local primary = loader_dir_name(cfg)
    local out = { fs.join(s, "config", primary) }
    for _, n in ipairs({ "stplug-in", "lua", "hubcap-lua" }) do
        if n ~= primary then out[#out + 1] = fs.join(s, "config", n) end
    end
    return out
end

-- Path to SteaMidra's global update-override, and helpers to keep a pinned depot
-- out of its auto-update list (otherwise LumaCore skips the pin).
local function override_path() return fs.join(steam_dir(), "config", "stplug-in", "00_LetUpdate_override.lua") end
local function midra_unlist_depot(depot)
    local p = override_path()
    if not fs.exists(p) then return end
    local c = m_utils.read_file(p); if not c then return end
    local new, changed = luaedit.override_remove_depot(c, depot)
    if changed then pcall(m_utils.write_file, p, new) end
end
local function midra_depot_in_override(depot)
    local p = override_path()
    if not fs.exists(p) then return false end
    return luaedit.override_has_depot(m_utils.read_file(p) or "", depot)
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

-- ── webkit injection ─────────────────────────────────────────────────────────

local function copy_and_inject_webkit()
    local s = steam_dir()
    local target = fs.join(s, "steamui", "webkit")
    if not fs.exists(target) then pcall(fs.create_directories, target) end
    local src = fs.join(plugin_dir(), "public", "ostlua.js")
    if fs.exists(src) then
        local c = m_utils.read_file(src)
        if c then m_utils.write_file(fs.join(target, "ostlua.js"), c) end
    end
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
        local loader = loader_id(read_config())
        -- pinned = "updates blocked". OST uses pinApp; SteaMidra = main depot has an
        -- active manifest AND isn't force-updated by the 00_LetUpdate override.
        local pinned
        if loader == "steamidra" then
            pinned = (depot ~= nil and depot.current ~= nil and md ~= nil and not midra_depot_in_override(md)) or false
        else
            pinned = luaedit.is_pinned(content, appid)
        end
        return { success = true, installed = true, luaPath = glua, mainDepot = md, depot = depot,
                 loader = loader, pinned = pinned }
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
        -- SteaMidra: make sure the depot isn't force-updated by the override
        if loader_id(read_config()) == "steamidra" then midra_unlist_depot(depot) end
        log("freeze appid=" .. appid .. " depot=" .. depot .. " -> " .. target .. " (" .. tostring(msg) .. ")")
        return { success = true, changed = changed, message = msg, depot = depot, manifest = target }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- Pin = block updates. OST: pinApp(appid). SteaMidra: pin the main depot to its
-- shipped manifest (active setManifestid) and drop it from the update-override.
function HubcapPin(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local appid = tostring(p.appid or "")
        local glua = find_game_lua(appid)
        if not glua then return { success = false, error = "game lua not installed" } end
        local content = m_utils.read_file(glua)
        if not content then return { success = false, error = "failed to read lua" } end
        if loader_id(read_config()) == "steamidra" then
            local md = luaedit.main_depot(content, appid)
            if not md then return { success = false, error = "no main depot found" } end
            local gid = luaedit.shipped_manifest(content, md)
            if not gid then return { success = false, error = "no manifest to pin to" } end
            local newc, changed, msg = luaedit.freeze(content, md, gid)
            if changed then m_utils.write_file(glua, newc) end
            midra_unlist_depot(md)
            log("pin(midra) appid=" .. appid .. " depot=" .. md .. " -> " .. gid)
            return { success = true, changed = true, message = "Pinned", pinned = true }
        end
        local newc, changed, msg = luaedit.pin_app(content, appid)
        if changed then m_utils.write_file(glua, newc) end
        log("pin appid=" .. appid .. " (" .. tostring(msg) .. ")")
        return { success = true, changed = changed, message = msg, pinned = true }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

function HubcapUnpin(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local appid = tostring(p.appid or "")
        local glua = find_game_lua(appid)
        if not glua then return { success = false, error = "game lua not installed" } end
        local content = m_utils.read_file(glua)
        if not content then return { success = false, error = "failed to read lua" } end
        if loader_id(read_config()) == "steamidra" then
            -- allow updates: fully remove the pin so LumaCore pulls the latest manifest
            local md = luaedit.main_depot(content, appid)
            local newc, changed = content, false
            if md then newc, changed = luaedit.clear_pins(content, md) end
            if changed then m_utils.write_file(glua, newc) end
            log("unpin(midra) appid=" .. appid .. " depot=" .. tostring(md))
            return { success = true, changed = changed, message = "Updates allowed", pinned = false }
        end
        local newc, changed, msg = luaedit.unpin_app(content, appid)
        if changed then m_utils.write_file(glua, newc) end
        log("unpin appid=" .. appid .. " (" .. tostring(msg) .. ")")
        return { success = true, changed = changed, message = msg, pinned = false }
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
        if loader_id(read_config()) == "steamidra" then midra_unlist_depot(depot) end
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
        local loaders = { { id = "steamidra", name = "Steam Midra" }, { id = "ost", name = "OpenSteamTool" } }
        return { success = true, hasKey = #key > 0, apiKeyMasked = masked, apiBase = cfg.api_base or "",
                 sources = srcs, mainSource = cfg.main_source or "hubcap", fallback = cfg.fallback == true,
                 loaders = loaders, loader = loader_id(cfg) }
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
        if not cfg.loader then cfg.loader = "steamidra" end
        m_utils.write_file(fs.join(backend_dir(), "config.json"), cjson.encode(cfg))
        return { success = true, cleared = (key == "") }
    end)
    if not ok then return json_err(res) end
    return json_ok(res)
end

-- save the chosen loader (steamidra / ost) into config.json
function HubcapSetLoader(contentScriptQuery, payload)
    local ok, res = pcall(function()
        local p = parse_payload(payload)
        local id = tostring(p.loader or "")
        if id ~= "steamidra" and id ~= "ost" then return { success = false, error = "invalid loader" } end
        local cfg = read_config()
        cfg.loader = id
        m_utils.write_file(fs.join(backend_dir(), "config.json"), cjson.encode(cfg))
        return { success = true, loader = id }
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

-- ── lifecycle ────────────────────────────────────────────────────────────────

-- First run: write config.json with defaults so nobody has to create it by hand
-- and the install helper always finds one. The API key / source are set in the UI.
local function ensure_config()
    local p = fs.join(backend_dir(), "config.json")
    if fs.exists(p) then return end
    local defaults = { loader = "steamidra", api_base = "https://hubcapmanifest.com/api/v1",
                       api_key = "", main_source = "hubcap", fallback = false }
    pcall(function() m_utils.write_file(p, cjson.encode(defaults)) end)
end

local function on_load()
    log("Bootstrapping OSTLua, millennium " .. tostring(select(2, pcall(millennium.version))))
    ensure_config()
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
