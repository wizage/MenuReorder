-- Safe wrappers around the game client, which can throw on reads and callbacks.
local Guard = {}

local PREFIX = "[MenuReorder]"
local seenFailures = {}

-- Print a failure message, but only the first time we see it.
---@param label string
---@param message string
function Guard.logOnce(label, message)
    if seenFailures[label] then
        return
    end
    seenFailures[label] = true
    print(string.format("%s %s", PREFIX, message))
end

-- Read a field off a client object, returning nil if it's absent or the read throws.
-- Shared accessor passed to pcall, so Guard.read allocates no closure per call
-- (this runs hundreds of times per tick on a crowded menu).
local function index(object, fieldName)
    return object[fieldName]
end

---@param object any
---@param fieldName string
---@return any value
function Guard.read(object, fieldName)
    if object == nil then
        return nil
    end
    local ok, value = pcall(index, object, fieldName)
    if not ok then
        return nil
    end
    return value
end

-- Wrap a callback the client invokes so an error in it can't crash the client.
---@param label string a short name used in error logs
---@param callback function
---@return function wrapped
function Guard.wrap(label, callback)
    return function(...)
        local ok, result = pcall(callback, ...)
        if not ok then
            Guard.logOnce(
                label .. "::" .. tostring(result),
                string.format("error in %s: %s", label, tostring(result))
            )
            return nil
        end
        return result
    end
end

-- Run a function, catching and logging any error. Returns whether it succeeded.
---@param fn function
---@return boolean ok
function Guard.try(fn)
    local ok, err = pcall(fn)
    if not ok then
        Guard.logOnce(
            "try::" .. tostring(err),
            string.format("guarded call failed: %s", tostring(err))
        )
    end
    return ok
end

return Guard
