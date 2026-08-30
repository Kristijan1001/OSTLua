-- luaedit.lua  (pure string logic, no fs/http — fully unit-testable)
-- Freeze / downgrade a Hubcap game by editing setManifestid lines in its lua.
--
-- Handles every case:
--   * active   setManifestid(D,"O",C)  -> comment as --[HUBCAP-ORIG], add pinned line
--   * commented --setManifestid(D,...) -> leave it, just add a pinned active line
--   * MISSING (no setManifestid at all) -> create a pinned line after addappid(D)
--   * re-pin while frozen -> rewrite the pinned line (no duplicates)
--   * revert -> drop the --[HUBCAP-PIN] line, uncomment any --[HUBCAP-ORIG]

local M = {}

local ORIG_PREFIX = "--[HUBCAP-ORIG] "
local PIN_SUFFIX  = " --[HUBCAP-PIN]"

local function split_lines(s)
    local lines, start = {}, 1
    while true do
        local nl = s:find("\n", start, true)
        if not nl then lines[#lines + 1] = s:sub(start); break end
        lines[#lines + 1] = s:sub(start, nl - 1)
        start = nl + 1
    end
    return lines
end
local function join_lines(lines) return table.concat(lines, "\n") end

-- depot, manifest, tail  (tail = text between the manifest quote and ')', e.g. ', 285975610')
local function parse_line(line)
    return line:match('setManifestid%(%s*(%d+)%s*,%s*"([^"]*)"(.-)%)')
end
local function has_pin(line)  return line:find("%-%-%[HUBCAP%-PIN%]", 1) ~= nil end
local function has_orig(line) return line:find("%-%-%[HUBCAP%-ORIG%]", 1) ~= nil end
local function is_commented(line) return line:match("^%s*%-%-") ~= nil end

-- classify setManifestid lines for a depot -> indices.
-- A commented line NEVER counts as active/pinned (even if it still carries a
-- --[HUBCAP-PIN] marker) — otherwise a commented pin reads as "still frozen".
local function locate(lines, depot)
    local active_i, pin_i, orig_i, commented_i
    for i, line in ipairs(lines) do
        local d = parse_line(line)
        if d == depot then
            if is_commented(line) then
                if has_orig(line) then orig_i = i
                else commented_i = commented_i or i end
            elseif has_pin(line) then pin_i = i
            else active_i = i end
        end
    end
    return active_i, pin_i, orig_i, commented_i
end

-- find the line index of the depot's addappid, to anchor a created setManifestid
local function addappid_index(lines, depot)
    for i, line in ipairs(lines) do
        if line:match("addappid%(%s*" .. depot .. "%s*[,%)]") and not is_commented(line) then
            return i
        end
    end
    return nil
end

local function build_line(depot, manifest, tail, suffix)
    return 'setManifestid(' .. depot .. ', "' .. manifest .. '"' .. (tail or "") .. ')' .. (suffix or "")
end

-- Return the main game depot id for an appid.
-- Priority: appid+1 (Steam convention) -> a depot that has a setManifestid ->
-- a depot that has a decryption key -> first bare non-app addappid. This avoids
-- picking a bare addappid (sub-app / tool / bundle) when the real content depot
-- is the one carrying a key + manifest (common in barebones luas).
function M.main_depot(content, appid)
    appid = tonumber(appid)
    -- match on a lowercased copy so any casing works (we only extract digits)
    local low = content:lower()
    local present = {}
    for id in low:gmatch("addappid%(%s*(%d+)") do present[tonumber(id)] = true end
    for id in low:gmatch("setmanifestid%(%s*(%d+)") do present[tonumber(id)] = true end
    -- 1) Steam convention
    if appid and present[appid + 1] then return tostring(appid + 1) end
    -- 2) a depot that is actually pinned (has a setManifestid)
    local pinned = low:match("setmanifestid%(%s*(%d+)")
    if pinned then return pinned end
    -- 3) a depot with a decryption key: addappid(depot, N, "key")
    local keyed = low:match('addappid%(%s*(%d+)%s*,%s*%d+%s*,%s*"')
    if keyed then return keyed end
    -- 4) fallback: first non-app bare addappid
    for id in low:gmatch("addappid%(%s*(%d+)") do
        if tonumber(id) ~= appid then return id end
    end
    return nil
end

-- Status of one depot: { depot, current, original, frozen, hasLine }
function M.depot_status(content, depot)
    depot = tostring(depot)
    local lines = split_lines(content)
    local active_i, pin_i, orig_i = locate(lines, depot)
    local eff = pin_i or active_i
    local current, original
    if eff then local _, m = parse_line(lines[eff]); current = m end
    if orig_i then local _, m = parse_line(lines[orig_i]); original = m
    elseif active_i then original = current end
    return {
        depot = depot,
        current = current,
        original = original,
        frozen = pin_i ~= nil,
        hasLine = eff ~= nil,
    }
end

-- Freeze/downgrade a depot to manifest `target`. Returns new_content, changed, message.
function M.freeze(content, depot, target)
    depot, target = tostring(depot), tostring(target)
    local lines = split_lines(content)
    local active_i, pin_i, orig_i, commented_i = locate(lines, depot)

    -- request-code tail from any existing line for this depot
    local tail = ""
    for _, idx in ipairs({ active_i, pin_i, commented_i, orig_i }) do
        if idx then local _, _, t = parse_line(lines[idx]); if t and t ~= "" then tail = t; break end end
    end

    if pin_i then
        -- already frozen: rewrite the pinned line (no duplicate)
        local _, cur = parse_line(lines[pin_i])
        if cur == target then return content, false, "Already on " .. target end
        lines[pin_i] = build_line(depot, target, tail, PIN_SUFFIX)
        return join_lines(lines), true, "Set to " .. target
    end

    local pin = build_line(depot, target, tail, PIN_SUFFIX)

    if active_i then
        -- comment the active line as ORIG, add pin right after it
        local _, cur = parse_line(lines[active_i])
        if cur == target then return content, false, "Already on " .. target end
        lines[active_i] = ORIG_PREFIX .. lines[active_i]
        table.insert(lines, active_i + 1, pin)
    elseif commented_i then
        -- original is already disabled; just add our pin after it
        table.insert(lines, commented_i + 1, pin)
    else
        -- no setManifestid at all: create one after addappid(depot), else append
        local ai = addappid_index(lines, depot)
        if ai then table.insert(lines, ai + 1, pin) else lines[#lines + 1] = pin end
    end
    return join_lines(lines), true, "Set to " .. target
end

-- Revert a depot to its original state. Returns new_content, changed, message.
function M.revert(content, depot)
    depot = tostring(depot)
    local lines = split_lines(content)
    local out, changed = {}, false
    for _, line in ipairs(lines) do
        local d = parse_line(line)
        if d == depot and has_pin(line) then
            changed = true  -- drop the pinned line
        elseif d == depot and has_orig(line) then
            out[#out + 1] = line:gsub("^%-%-%[HUBCAP%-ORIG%] ", "", 1)
            changed = true
        else
            out[#out + 1] = line
        end
    end
    if not changed then return content, false, "Nothing to revert" end
    return join_lines(out), true, "Reverted"
end


-- Every depot this lua controls, i.e. that carries a setManifestid line in any
-- state (active, pinned, or commented out by install). Order is file order.
--
-- Pinning only the "main" depot is what produced half-downgraded installs: the
-- other content depots stayed commented, and a commented setManifestid means
-- Steam takes the LATEST manifest for that depot.
function M.all_depots(content)
    local seen, out = {}, {}
    for _, line in ipairs(split_lines(content)) do
        local d = parse_line(line)
        if d and not seen[d] then
            seen[d] = true
            out[#out + 1] = d
        end
    end
    return out
end


-- Any manifest recorded for a depot, preferring the active/pinned line and
-- falling back to a commented one. Used for depots that did NOT change in the
-- chosen build: their manifest is whatever the lua already carries, and pinning
-- that explicitly stops them floating to latest.
function M.any_manifest(content, depot)
    depot = tostring(depot)
    local lines = split_lines(content)
    local active_i, pin_i, orig_i, commented_i = locate(lines, depot)
    local idx = pin_i or active_i or commented_i or orig_i
    if not idx then return nil end
    local _, m = parse_line(lines[idx])
    return m
end


return M
