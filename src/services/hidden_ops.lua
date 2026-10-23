-- HiddenOps: truly remove verbs from the native menu for entries backed by a
-- Hides menu options by marking their component op hidden, and restores them.
local Guard = require("src/util/guard")
local Text = require("src/util/text")

local HiddenOps = {}

-- Hide diagnostics. Off by default; toggle with MenuReorderHideDebug(true).
HiddenOps.debug = false

local function dbg(...)
    if HiddenOps.debug then
        print("[MenuReorder][hide] " .. table.concat({ ... }, " "))
    end
end

-- Components we have hidden ops on, keyed by identity, so we can restore them.
local touched = {}

local function opConfigOf(component)
    return Guard.read(component, "opConfig")
end

local function componentOf(entry)
    local cd = Guard.read(entry, "componentData")
    return Guard.read(cd, "component")
end

local function opIndexOf(entry)
    local cd = Guard.read(entry, "componentData")
    local idx = Guard.read(cd, "opIndex")
    if type(idx) == "number" then
        return math.tointeger(idx) or idx
    end
    return nil
end

local function identityOf(component)
    local i = Guard.read(component, "interfaceID") or Guard.read(component, "interfaceId")
    local s = Guard.read(component, "staticID") or Guard.read(component, "staticId")
    local d = Guard.read(component, "dynamicID") or Guard.read(component, "dynamicId")
    if i == nil or s == nil then
        return nil
    end
    return string.format("%s:%s:%s", tostring(i), tostring(s), tostring(d))
end

local function clear(opConfig)
    return pcall(function()
        opConfig:ClearHiddenOps()
    end)
end

-- Read an op's name at a given opConfig index, stripped. nil/"" when absent.
local function opNameAt(opConfig, index)
    local ok, name = pcall(function()
        return opConfig:GetOpName(index)
    end)
    if not ok or type(name) ~= "string" or name == "" then
        return nil
    end
    return Text.strip(name)
end

-- Find the opConfig index whose op name matches `verb`. We match by name rather
-- than the entry's opIndex, which is wrong for some entry types.
local function findOpIndexByName(opConfig, verb)
    for index = 1, 10 do
        if opNameAt(opConfig, index) == verb then
            return index
        end
    end
    return nil
end

-- Which of a group's verbs can actually be hidden (i.e. have a named op).
-- Reserved ops like "Use"/"Examine" have no name and can only be sunk.
---@param miniMenu table
---@param indexes integer[] client entry indexes for one target group
---@return table<string, boolean> hideable stripped verb -> true when removable
function HiddenOps.hideableVerbs(miniMenu, indexes)
    local hideable = {}
    for _, entryIndex in ipairs(indexes) do
        local entry = miniMenu.entries[entryIndex]
        local verb = Text.strip(Guard.read(entry, "verbText"))
        local component = componentOf(entry)
        local opConfig = component ~= nil and opConfigOf(component) or nil
        if opConfig ~= nil and findOpIndexByName(opConfig, verb) ~= nil then
            hideable[verb] = true
        end
    end
    return hideable
end

-- Hide every entry in this group whose verb is in `hiddenVerbs`, by finding the
-- matching op on its component. Clears each opConfig once so shared components
-- aren't raced.
---@param miniMenu table
---@param indexes integer[] client entry indexes to consider (one target group)
---@param hiddenVerbs table<string, boolean> stripped verb -> true
function HiddenOps.applyMenu(miniMenu, indexes, hiddenVerbs)
    local toHide = {} -- list of { opConfig, opIndex, identity, verb }
    local configsByIdentity = {} -- identity -> opConfig (distinct)

    if HiddenOps.debug then
        local wanted = {}
        for w in pairs(hiddenVerbs) do
            wanted[#wanted + 1] = "'" .. w .. "'"
        end
        dbg("=== applyMenu wanted:", table.concat(wanted, ","), "===")
    end

    for _, entryIndex in ipairs(indexes) do
        local entry = miniMenu.entries[entryIndex]
        local verb = Text.strip(Guard.read(entry, "verbText"))
        if hiddenVerbs[verb] then
            local component = componentOf(entry)
            local opConfig = component ~= nil and opConfigOf(component) or nil
            -- Match by name; the entry's own opIndex is unreliable here.
            local realIndex = opConfig ~= nil and findOpIndexByName(opConfig, verb) or nil
            if opConfig ~= nil and realIndex ~= nil then
                local identity = identityOf(component) or component
                configsByIdentity[identity] = opConfig
                toHide[#toHide + 1] = {
                    opConfig = opConfig,
                    opIndex = realIndex,
                    identity = identity,
                    verb = verb,
                }
                dbg("hide verb '" .. verb .. "' resolved opConfig index", tostring(realIndex),
                    "(entry opIndex was", tostring(opIndexOf(entry)) .. ")")
            else
                dbg("CANNOT hide '" .. verb .. "' - no named op matched",
                    "(entry opIndex", tostring(opIndexOf(entry)),
                    "opConfig:", tostring(opConfig ~= nil) .. ")")
            end
        end
    end

    -- Clear each distinct opConfig once, from a clean slate.
    for _, opConfig in pairs(configsByIdentity) do
        clear(opConfig)
    end

    -- Apply the hides at the name-resolved indices.
    for _, h in ipairs(toHide) do
        local ok = pcall(function()
            h.opConfig:SetOpIDHidden(h.opIndex, true)
        end)
        if ok then
            touched[h.identity] = h.opConfig
        end
        if HiddenOps.debug then
            local took
            pcall(function()
                took = h.opConfig:TestOpIsHidden(h.opIndex)
            end)
            dbg("  SetOpIDHidden(" .. tostring(h.opIndex) .. ") '" .. h.verb .. "'",
                "setOk=" .. tostring(ok), "TestOpIsHidden=" .. tostring(took))
        end
    end
end

-- Restore every op we hid (called on shutdown).
function HiddenOps.restoreAll()
    for identity, opConfig in pairs(touched) do
        clear(opConfig)
        touched[identity] = nil
    end
end

-- Restore this entry's component if we hid something on it earlier.
---@param entry table a mini-menu entry
function HiddenOps.restoreEntry(entry)
    local component = componentOf(entry)
    if component == nil then
        return
    end
    local identity = identityOf(component) or component
    local opConfig = touched[identity]
    if opConfig ~= nil then
        clear(opConfig)
        touched[identity] = nil
    end
end

-- Whether we have any hidden ops applied right now.
---@return boolean
function HiddenOps.hasTouched()
    return next(touched) ~= nil
end

return HiddenOps
