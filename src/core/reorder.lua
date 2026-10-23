-- Works out which target each right-click menu entry belongs to and applies the
-- saved verb order with Swap calls.

local Text = require("src/util/text")
local Guard = require("src/util/guard")
local OrderStore = require("src/core/order_store")

local Reorder = {}

local WALK_HERE = "Walk here"
local PINNED = { ["Cancel"] = true } -- always stays at the bottom

-- True for entries a plugin added to the menu (ours or another's).
local function isPluginAdded(entry)
    return tonumber(Guard.read(entry, "actionType")) == 2138
end

-- Whether we're allowed to move this entry (skips plugin entries and pinned verbs).
---@param entry table
---@return boolean
local function isReorderable(entry)
    if entry == nil or isPluginAdded(entry) then
        return false
    end
    return not PINNED[Text.strip(Guard.read(entry, "verbText"))]
end

-- A stable key for the interface component an entry belongs to.
local function componentKey(entry)
    local cd = Guard.read(entry, "componentData")
    local component = Guard.read(cd, "component")
    local interfaceId = Guard.read(component, "interfaceID")
        or Guard.read(component, "interfaceId")
    local staticId = Guard.read(component, "staticID")
        or Guard.read(component, "staticId")
    if interfaceId ~= nil and staticId ~= nil then
        return string.format("c:%s:%s", tostring(interfaceId), tostring(staticId))
    end
    return nil
end

local function npcKey(entry)
    local npc = Guard.read(entry, "npcData")
    local entity = Guard.read(npc, "entity")
    local configId = Guard.read(entity, "configID") or Guard.read(entity, "configId")
    if configId ~= nil then
        return string.format("n:%s", tostring(configId))
    end
    return nil
end

local function objKey(entry)
    local obj = Guard.read(entry, "objData")
    local config = Guard.read(obj, "config")
    local id = Guard.read(config, "id")
    if id == nil then
        local cd = Guard.read(entry, "componentData")
        local objConfig = Guard.read(cd, "objConfig")
        id = Guard.read(objConfig, "id")
    end
    if id ~= nil then
        return string.format("o:%s", tostring(id))
    end
    return nil
end

local function locKey(entry)
    local loc = Guard.read(entry, "locData")
    local config = Guard.read(loc, "config")
    local id = Guard.read(config, "id")
    if id ~= nil then
        return string.format("l:%s", tostring(id))
    end
    return nil
end

-- Every player shares one key, since a per-player order would be pointless.
local PLAYER_KEY = "p:player"

-- Verbs that only show up when right-clicking another player.
local PLAYER_VERBS = {
    ["Follow"] = true,
    ["Trade with"] = true,
    ["Attack"] = true,
    ["Challenge"] = true,
    ["Req assist"] = true,
    ["Request assist"] = true,
    ["Report abuse"] = true,
    ["Report"] = true,
    ["Add friend"] = true,
    ["Add ignore"] = true,
    ["Message"] = true,
}

local function hasPlayerData(entry)
    return Guard.read(entry, "playerData") ~= nil
        or Guard.read(entry, "playerEntity") ~= nil
end

-- Fallback player check for when there's no player data block: a named subject,
-- no npc/obj/loc data, and a player-only verb. Interface entries (which carry
-- componentData, e.g. chat lines) are excluded so they key by their component.
---@param entry table
---@return boolean
local function looksLikePlayerEntry(entry)
    if Guard.read(entry, "npcData") ~= nil
        or Guard.read(entry, "objData") ~= nil
        or Guard.read(entry, "locData") ~= nil
        or Guard.read(entry, "componentData") ~= nil
    then
        return false
    end
    local subject = Guard.read(entry, "subjectText")
    if type(subject) ~= "string" or subject == "" then
        return false
    end
    local verb = Text.strip(Guard.read(entry, "verbText"))
    return PLAYER_VERBS[verb] == true
end

local function playerKey(entry)
    if hasPlayerData(entry) or looksLikePlayerEntry(entry) then
        return PLAYER_KEY
    end
    return nil
end

-- The key this entry belongs to, trying each target type in priority order.
---@param entry table
---@return string|nil key the identity this single entry belongs to
local function entryKey(entry)
    return npcKey(entry)
        or objKey(entry)
        or locKey(entry)
        or playerKey(entry)
        or componentKey(entry)
end

-- A readable name for the target, used as the picker/editor title.
---@param entry table
---@return string
local function entryDisplayName(entry)
    -- Players share one order, so label them generically.
    if hasPlayerData(entry) or looksLikePlayerEntry(entry) then
        return "Player"
    end

    local npc = Guard.read(entry, "npcData")
    local npcName = Guard.read(Guard.read(npc, "entity"), "displayName")
    if type(npcName) == "string" and npcName ~= "" then
        return Text.strip(npcName)
    end

    local obj = Guard.read(entry, "objData")
    local objName = Guard.read(Guard.read(obj, "config"), "name")
    if type(objName) == "string" and objName ~= "" then
        return Text.strip(objName)
    end

    local cd = Guard.read(entry, "componentData")
    local objConfigName = Guard.read(Guard.read(cd, "objConfig"), "name")
    if type(objConfigName) == "string" and objConfigName ~= "" then
        return Text.strip(objConfigName)
    end

    local loc = Guard.read(entry, "locData")
    local locName = Guard.read(Guard.read(loc, "config"), "name")
    if type(locName) == "string" and locName ~= "" then
        return Text.strip(locName)
    end

    -- Fall back to the entry's subject or full text.
    for _, field in ipairs({ "subjectText", "fullText" }) do
        local value = Guard.read(entry, field)
        if type(value) == "string" and value ~= "" then
            return Text.strip(value)
        end
    end
    return "Target"
end

---@param miniMenu table
---@return string|nil targetKey the identity the order is saved under (first found)
local function resolveTargetKey(miniMenu)
    local count = miniMenu.entryCount
    for i = 1, count do
        local key = entryKey(miniMenu.entries[i])
        if key ~= nil then
            return key
        end
    end
    return nil
end

---@class MenuReorderTargetGroup
---@field key string persistence key shared by this target's entries
---@field displayName string readable label for the picker and editor title
---@field indexes integer[] reorderable client entry indexes ascending (bottom to top)
---@field verbByIndex table<integer,string> stripped verb per index

-- Split the menu's reorderable entries into one group per target. A right-click
-- on a stack produces entries for several targets, each with its own order.
---@param miniMenu table
---@return MenuReorderTargetGroup[] groups
local function getTargetGroups(miniMenu)
    local byKey = {}
    local groups = {}
    -- Walk top-to-bottom so group order matches what the user reads.
    for i = miniMenu.entryCount, 1, -1 do
        local entry = miniMenu.entries[i]
        if isReorderable(entry) then
            local key = entryKey(entry)
            if key ~= nil then
                local group = byKey[key]
                if group == nil then
                    group = {
                        key = key,
                        displayName = entryDisplayName(entry),
                        indexes = {},
                        verbByIndex = {},
                    }
                    byKey[key] = group
                    groups[#groups + 1] = group
                end
                group.indexes[#group.indexes + 1] = i
                group.verbByIndex[i] = Text.strip(Guard.read(entry, "verbText"))
            end
        end
    end
    -- apply expects indexes ascending.
    for _, group in ipairs(groups) do
        table.sort(group.indexes)
    end
    return groups
end

-- Distinct verbs for a group, top-to-bottom.
---@param group MenuReorderTargetGroup
---@return string[]
local function groupDistinctVerbs(group)
    local verbs = {}
    local seen = {}
    for pos = #group.indexes, 1, -1 do
        local verb = group.verbByIndex[group.indexes[pos]]
        if not seen[verb] then
            seen[verb] = true
            verbs[#verbs + 1] = verb
        end
    end
    return verbs
end

-- Collect the reorderable entry indexes and their verbs in one pass. The client
-- stores entries bottom-to-top, so index 1 is the lowest row.
---@param miniMenu table
---@return integer[] indexes reorderable entry indexes, ascending (bottom to top)
---@return table<integer,string> verbByIndex stripped verb per index
---@return integer distinctVerbCount
local function scan(miniMenu)
    local indexes = {}
    local verbByIndex = {}
    local seen = {}
    local distinct = 0
    for i = 1, miniMenu.entryCount do
        local entry = miniMenu.entries[i]
        if isReorderable(entry) then
            local verb = Text.strip(Guard.read(entry, "verbText"))
            indexes[#indexes + 1] = i
            verbByIndex[i] = verb
            if not seen[verb] then
                seen[verb] = true
                distinct = distinct + 1
            end
        end
    end
    return indexes, verbByIndex, distinct
end

Reorder.WALK_HERE = WALK_HERE
Reorder.scan = scan
Reorder.resolveTargetKey = resolveTargetKey
Reorder.isReorderable = isReorderable
Reorder.getTargetGroups = getTargetGroups
Reorder.groupDistinctVerbs = groupDistinctVerbs
Reorder.entryDisplayName = entryDisplayName

-- Reorder the live menu to match a saved verb order. Swap(a, b) exchanges the
-- verbs at two positions, so we fill the top positions one verb at a time.
---@param miniMenu table
---@param indexes integer[] reorderable entry indexes ascending (bottom to top)
---@param verbByIndex table<integer,string>
---@param savedOrder string[] top-to-bottom verb list
function Reorder.apply(miniMenu, indexes, verbByIndex, savedOrder)
    local slotCount = #indexes
    if slotCount < 2 or savedOrder == nil or #savedOrder == 0 then
        return
    end

    -- Positions top-to-bottom = client indexes descending.
    local posTopToBottom = {}
    for slot = 1, slotCount do
        posTopToBottom[slot] = indexes[slotCount - slot + 1]
    end

    -- Track the verb at each position so our model mirrors each Swap.
    local liveVerb = {}
    for _, idx in ipairs(indexes) do
        liveVerb[idx] = verbByIndex[idx]
    end

    local fill = 1 -- next top position to fill
    for _, rawVerb in ipairs(savedOrder) do
        if fill > slotCount then
            break
        end
        local verb = Text.strip(rawVerb)
        -- Place every remaining copy of this verb so duplicates stay together.
        local placedAny = true
        while placedAny and fill <= slotCount do
            placedAny = false
            local targetPos = posTopToBottom[fill]
            if liveVerb[targetPos] == verb then
                fill = fill + 1
                placedAny = true
            else
                for search = fill + 1, slotCount do
                    local srcPos = posTopToBottom[search]
                    if liveVerb[srcPos] == verb then
                        miniMenu:Swap(srcPos, targetPos)
                        liveVerb[srcPos], liveVerb[targetPos] =
                            liveVerb[targetPos], liveVerb[srcPos]
                        fill = fill + 1
                        placedAny = true
                        break
                    end
                end
            end
        end
    end
end

return Reorder
