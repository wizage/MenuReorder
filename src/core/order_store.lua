-- Saved verb order and hidden-verb set per target, cached in memory so each key
-- only hits PersistentDB once per session.
local OrderStore = {}

local ORDER_PREFIX = "mr_order_"
local HIDDEN_PREFIX = "mr_hidden_"
local NEVER_SAVED = {} -- marks a key we've read and found empty, so we don't re-read it
local memo = {}

-- Read a value for a storage key, caching the result (including "nothing").
local function readValue(storageKey)
    local cached = memo[storageKey]
    if cached == nil then
        local value = PersistentDB:GetStructuredData(storageKey)
        cached = value or NEVER_SAVED
        memo[storageKey] = cached
    end
    if cached == NEVER_SAVED then
        return nil
    end
    return cached
end

-- Save a value and update the cache.
local function writeValue(storageKey, value)
    value = value or {}
    memo[storageKey] = value
    PersistentDB:SetStructuredData(storageKey, value)
end

-- Remove a saved value.
local function deleteValue(storageKey)
    memo[storageKey] = NEVER_SAVED
    pcall(function()
        PersistentDB:Delete(storageKey)
    end)
end

-- ----- saved order -----

---@param targetKey string
---@return string[]|nil order verb list top-to-bottom, or nil when never saved
function OrderStore.get(targetKey)
    return readValue(ORDER_PREFIX .. targetKey)
end

---@param targetKey string
---@param order string[] verb list top-to-bottom
function OrderStore.set(targetKey, order)
    writeValue(ORDER_PREFIX .. targetKey, order)
end

---@param targetKey string
function OrderStore.clear(targetKey)
    deleteValue(ORDER_PREFIX .. targetKey)
end

-- ----- hidden verbs -----

---@param targetKey string
---@return string[] hiddenVerbs the verbs hidden for this target (empty when none)
function OrderStore.getHidden(targetKey)
    return readValue(HIDDEN_PREFIX .. targetKey) or {}
end

---@param targetKey string
---@param hiddenVerbs string[]
function OrderStore.setHidden(targetKey, hiddenVerbs)
    writeValue(HIDDEN_PREFIX .. targetKey, hiddenVerbs)
end

return OrderStore
