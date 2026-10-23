-- Rich-text tag handling, with a cache so each string is only stripped once.
local Text = {}

local UNKNOWN = "unknown"
local strippedCache = {}

-- Strip colour/formatting tags from a verb so it compares and displays cleanly.
---@param text string|nil
---@return string stripped tags removed; "unknown" when there is no text
function Text.strip(text)
    if text == nil or text == "" then
        return UNKNOWN
    end
    local cached = strippedCache[text]
    if cached ~= nil then
        return cached
    end
    -- Skip the gsub unless the string actually has a tag.
    local stripped
    if string.find(text, "<", 1, true) == nil then
        stripped = text
    else
        stripped = (string.gsub(text, "<[^>]*>", ""))
    end
    strippedCache[text] = stripped
    return stripped
end

-- Wrap text in a colour tag so the client renders it in that colour.
---@param text string
---@param colourHex string six hex digits, no leading hash
---@return string
function Text.colour(text, colourHex)
    return string.format("<col=%s>%s</col>", colourHex, text)
end

return Text
