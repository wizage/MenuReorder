-- Picker: when a right-click menu covers several targets at once (a stack -
-- When a right-click covers several targets (a stack), this overlay asks which
-- one to reorder, then runs a callback with the chosen group.
local Guard = require("src/util/guard")

local Picker = {}

-- Layout (interface units).
local ROW_H_SINGLE = 26
local ROW_H_WRAP = 44
local PAD = 6
local TITLE_H = 24
local MIN_WIDTH = 200
local MAX_WIDTH = 420
local MAX_LABEL_LINES = 2
local LABEL_CHROME = PAD * 2 + PAD -- left inset + right pad
local CHAR_PX = 10

local winWidth = MIN_WIDTH
local rowHeight = ROW_H_SINGLE

-- Colours.
local COL_BG = Vector4.new(0.10, 0.10, 0.12, 0.98)
local COL_TITLE = Vector4.new(1.0, 0.82, 0.35, 1.0)
local COL_ROW = Vector4.new(0.18, 0.18, 0.22, 1.0)
local COL_ROW_ALT = Vector4.new(0.23, 0.23, 0.28, 1.0)
local COL_TEXT = Vector4.new(1.0, 1.0, 1.0, 1.0)

local window = nil

local LABEL_FONT = id.Font.MUSEO_SANS_15PT_REGULAR

local function font()
    return LABEL_FONT
end

-- Measure a string's pixel width, falling back to a character-count estimate.
local function measureWidth(s)
    if type(s) ~= "string" or s == "" then
        return 0
    end
    local estimate = #s * CHAR_PX
    local ok, w = pcall(function()
        local f = config.Font.FromID and config.Font.FromID(LABEL_FONT)
            or config.Font.MUSEO_SANS_15PT_REGULAR
        return f:GetStringWidth(s, false)
    end)
    if ok and type(w) == "number" and w > 0 then
        return w
    end
    return estimate
end

function Picker.IsOpen()
    return window ~= nil
end

function Picker.Close()
    if window ~= nil then
        local w = window
        window = nil
        Guard.try(function()
            w:Destroy()
        end)
    end
end

-- Show the picker for `groups` at (x, y); `onPick(group)` runs on selection.
---@param groups table[] each { key, displayName, ... }
---@param x number
---@param y number
---@param onPick fun(group: table)
function Picker.Open(groups, x, y, onPick)
    Picker.Close()

    local parent = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    if parent == nil then
        Guard.logOnce("pickerParent", "could not find plugin build layer; picker not shown")
        return
    end

    local rowCount = #groups

    -- Size to the longest target name and the title; wrap past MAX_WIDTH.
    winWidth = MIN_WIDTH
    rowHeight = ROW_H_SINGLE
    local needed = math.max(measureWidth("Reorder which?") + PAD * 3, MIN_WIDTH)
    local widest = 0
    for _, group in ipairs(groups) do
        local w = measureWidth(group.displayName or "")
        if w > widest then
            widest = w
        end
    end
    local rowNeeded = widest + LABEL_CHROME
    if rowNeeded <= MAX_WIDTH then
        needed = math.max(needed, rowNeeded)
    else
        needed = math.max(needed, MAX_WIDTH)
        if widest > (MAX_WIDTH - LABEL_CHROME) then
            rowHeight = ROW_H_WRAP
        end
    end

    winWidth = math.max(MIN_WIDTH, math.min(MAX_WIDTH, math.floor(needed)))

    local height = TITLE_H + PAD + rowCount * rowHeight + PAD

    window = ui.GroupBox.new(parent)
    Guard.try(function()
        window.stylesheetID = id.StyleSheet.DEFAULT
    end)
    Guard.try(function()
        window.clickthrough = false
        window.enabled = true
    end)
    Guard.try(function()
        window.headerText.content = ""
        window:SetHeaderLayout(0, 0, 0, 0, ui.GroupBoxHeaderAlignMode.CENTRE)
    end)

    local winX = math.floor(x)
    local winY = math.floor(y)

    -- Nudge the window back on screen if it would spill off the edge.
    local areaW, areaH = nil, nil
    Guard.try(function()
        local area = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
        if area ~= nil then
            areaW = area.width
            areaH = area.height
        end
    end)
    if type(areaW) == "number" and areaW > 0 then
        if winX + winWidth > areaW then
            winX = areaW - winWidth
        end
        if winX < 0 then
            winX = 0
        end
    end
    if type(areaH) == "number" and areaH > 0 then
        if winY + height > areaH then
            winY = areaH - height
        end
        if winY < 0 then
            winY = 0
        end
    end

    window:SetSize(winWidth, height)
    window:SetPos(winX, winY)

    local bg = ui.Rectangle.new(window)
    bg:SetSize(0, 0, 1.0, 1.0)
    bg:SetPos(0, 0)
    bg.fill = true
    bg.colour = COL_BG

    local title = ui.Text.new(window)
    title:SetSize(-(PAD * 2), TITLE_H, 1.0, 0)
    title:SetPos(PAD, 2)
    title.content = "Reorder which?"
    title.font = font()
    title.colour = COL_TITLE
    Guard.try(function()
        title:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    end)

    for slot = 1, rowCount do
        local group = groups[slot]
        local rowY = TITLE_H + PAD + (slot - 1) * rowHeight

        local rowBg = ui.Rectangle.new(window)
        rowBg:SetSize(-(PAD * 2), rowHeight - 2, 1.0, 0)
        rowBg:SetPos(PAD, rowY)
        rowBg.fill = true
        rowBg.colour = (slot % 2 == 0) and COL_ROW_ALT or COL_ROW
        Guard.try(function()
            rowBg.clickthrough = false
            rowBg.enabled = true
        end)

        local rowText = ui.Text.new(window)
        rowText:SetSize(-(PAD * 3), rowHeight - 2, 1.0, 0)
        rowText:SetPos(PAD * 2, rowY)
        rowText.content = group.displayName
        rowText.font = font()
        rowText.colour = COL_TEXT
        Guard.try(function()
            rowText.maxLines = MAX_LABEL_LINES
        end)
        Guard.try(function()
            rowText.clickthrough = true -- let clicks fall through to the row
        end)
        Guard.try(function()
            rowText:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
        end)

        Guard.try(function()
            rowBg:Subscribe(
                ui.Hook.ONCLICK,
                "menu_reorder_pick_" .. slot,
                Guard.wrap("pickerRowClick", function()
                    Picker.Close()
                    if onPick ~= nil then
                        Guard.try(function()
                            onPick(group)
                        end)
                    end
                end)
            )
        end)
    end
end

return Picker
