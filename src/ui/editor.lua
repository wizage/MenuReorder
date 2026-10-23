-- Editor: a small overlay listing a target's menu verbs. Click a row to pick it
-- A small overlay listing a target's menu options. Click one to pick it up,
-- click again to drop it, use Hide/Show to toggle hiding, then Save or Cancel.
local Guard = require("src/util/guard")
local OrderStore = require("src/core/order_store")

local Editor = {}

-- Layout (interface units).
local ROW_H_SINGLE = 26 -- row height for a one-line label
local ROW_H_WRAP = 44 -- row height when labels wrap to two lines
local PAD = 6
local TITLE_H = 24
local HINT_H = 20
local BUTTON_H = 26
local HIDE_BTN_W = 46 -- width of the per-row Hide/Show toggle
local MIN_WIDTH = 200
local MAX_WIDTH = 420 -- beyond this we wrap the label instead of widening
local MAX_LABEL_LINES = 2

-- Horizontal space a row reserves around its label (insets + hide button).
local LABEL_CHROME = PAD * 2 + PAD + HIDE_BTN_W + PAD

-- Set per open to fit the longest label.
local winWidth = MIN_WIDTH
local rowHeight = ROW_H_SINGLE

-- Colours.
local COL_BG = Vector4.new(0.10, 0.10, 0.12, 0.98)
local COL_TITLE = Vector4.new(1.0, 0.82, 0.35, 1.0)
local COL_ROW = Vector4.new(0.18, 0.18, 0.22, 1.0)
local COL_ROW_ALT = Vector4.new(0.23, 0.23, 0.28, 1.0)
local COL_ROW_PICKED = Vector4.new(0.32, 0.46, 0.66, 1.0)
local COL_ROW_HIDDEN = Vector4.new(0.14, 0.12, 0.12, 1.0)
local COL_TEXT = Vector4.new(1.0, 1.0, 1.0, 1.0)
local COL_TEXT_HIDDEN = Vector4.new(0.55, 0.52, 0.52, 1.0)
local COL_HINT = Vector4.new(0.7, 0.7, 0.75, 1.0)

local LABEL_FONT = id.Font.MUSEO_SANS_15PT_REGULAR

-- Rough pixel width per character, a fallback when the measure API is absent.
local CHAR_PX = 10

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

-- Live editor state. Only one editor exists at a time.
local window = nil
local rowComponents = {} -- slot -> { bg, text, hideButton }
local verbs = {} -- current working order, top-to-bottom
local hiddenSet = {} -- verb -> true for verbs marked hidden
local hideableSet = {} -- verb -> true when the verb can truly be op-hidden
local targetKey = nil
local onClosed = nil
local pickedSlot = nil -- the slot currently "picked up", or nil

local function font()
    return LABEL_FONT
end

-- Paint one row's background + text for its current state.
local function paintRow(slot)
    local row = rowComponents[slot]
    if row == nil then
        return
    end
    local verb = verbs[slot]
    local hidden = hiddenSet[verb] == true
    local colour
    if slot == pickedSlot then
        colour = COL_ROW_PICKED
    elseif hidden then
        colour = COL_ROW_HIDDEN
    elseif slot % 2 == 0 then
        colour = COL_ROW_ALT
    else
        colour = COL_ROW
    end
    Guard.try(function()
        row.bg.colour = colour
        row.text.colour = hidden and COL_TEXT_HIDDEN or COL_TEXT
        row.text.content = hidden and ("(hidden) " .. verb) or verb
        local canHide = hideableSet[verb] == true
        if row.hideButton ~= nil then
            row.hideButton.hidden = not canHide
            row.hideButton.label = hidden and "Show" or "Hide"
        end
        if row.marker ~= nil then
            row.marker.hidden = canHide
        end
    end)
end

-- Reposition and relabel every row to match the current `verbs` order.
local function layoutRows()
    for slot, row in ipairs(rowComponents) do
        local y = TITLE_H + PAD + (slot - 1) * rowHeight
        Guard.try(function()
            row.bg:SetPos(PAD, y)
            row.text:SetPos(PAD * 2, y)
            if row.hideButton ~= nil then
                row.hideButton:SetPos(winWidth - PAD - HIDE_BTN_W, y)
            end
            if row.marker ~= nil then
                row.marker:SetPos(winWidth - PAD - HIDE_BTN_W, y)
            end
        end)
        paintRow(slot)
    end
end

-- Move a verb from one slot to another, shifting the rest.
local function moveVerb(fromSlot, toSlot)
    if fromSlot == toSlot then
        return
    end
    local verb = table.remove(verbs, fromSlot)
    table.insert(verbs, toSlot, verb)
end

function Editor.IsOpen()
    return window ~= nil
end

function Editor.Close()
    if window ~= nil then
        local w = window
        window = nil
        Guard.try(function()
            w:Destroy()
        end)
    end
    rowComponents = {}
    verbs = {}
    hiddenSet = {}
    targetKey = nil
    pickedSlot = nil
    local cb = onClosed
    onClosed = nil
    if cb ~= nil then
        Guard.try(cb)
    end
end

-- Persist the current working order AND the hidden-verb set, then close.
local function save()
    if targetKey ~= nil then
        OrderStore.set(targetKey, verbs)
        local hiddenList = {}
        for _, verb in ipairs(verbs) do
            if hiddenSet[verb] then
                hiddenList[#hiddenList + 1] = verb
            end
        end
        OrderStore.setHidden(targetKey, hiddenList)
    end
    Editor.Close()
end

-- Toggle the hidden state of the verb at `slot`. Only verbs that can truly be
-- op-hidden are toggleable; reserved ops are ignored.
local function toggleHide(slot)
    local verb = verbs[slot]
    if verb == nil or not hideableSet[verb] then
        return
    end
    if hiddenSet[verb] then
        hiddenSet[verb] = nil
    else
        hiddenSet[verb] = true
    end
    paintRow(slot)
end

-- Handle a click on row `slot`: pick it up, drop onto it, or put it back.
local function onRowClick(slot)
    if pickedSlot == nil then
        pickedSlot = slot
    elseif pickedSlot == slot then
        pickedSlot = nil -- clicking the picked row again cancels the pick
    else
        moveVerb(pickedSlot, slot)
        pickedSlot = nil
    end
    layoutRows()
end

-- Build one clickable row component with a Hide/Show toggle on the right.
local function buildRow(slot)
    local y = TITLE_H + PAD + (slot - 1) * rowHeight

    -- The strip spans the full row; the Hide button sits on top of it.
    local bg = ui.Rectangle.new(window)
    bg:SetSize(-(PAD * 2), rowHeight - 2, 1.0, 0)
    bg:SetPos(PAD, y)
    bg.fill = true
    bg.colour = (slot % 2 == 0) and COL_ROW_ALT or COL_ROW
    Guard.try(function()
        bg.clickthrough = false
        bg.enabled = true
    end)

    local text = ui.Text.new(window)
    text:SetSize(-(PAD * 3 + HIDE_BTN_W + PAD), rowHeight - 2, 1.0, 0)
    text:SetPos(PAD * 2, y)
    text.content = verbs[slot]
    text.font = font()
    text.colour = COL_TEXT
    -- Let long labels wrap onto a second line instead of clipping.
    Guard.try(function()
        text.maxLines = MAX_LABEL_LINES
    end)
    Guard.try(function()
        text.clickthrough = true -- let clicks fall through to the row behind
    end)
    Guard.try(function()
        text:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    end)

    -- Click to pick up / drop. ONCLICK needs a per-row subscription key here.
    Guard.try(function()
        bg:Subscribe(
            ui.Hook.ONCLICK,
            "menu_reorder_row_" .. slot,
            Guard.wrap("editorRowClick", function()
                onRowClick(slot)
            end)
        )
    end)

    -- Each row has a Hide/Show button and a dimmed "--" marker; paintRow shows
    -- whichever fits the verb currently in this slot (verbs can be reordered).
    local hideButton = ui.Button.new(window)
    Guard.try(function()
        hideButton.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    end)
    hideButton:SetSize(HIDE_BTN_W, rowHeight - 2, 0, 0)
    hideButton:SetPos(winWidth - PAD - HIDE_BTN_W, y)
    Guard.try(function()
        hideButton.label = "Hide"
    end)
    Guard.try(function()
        hideButton:Subscribe(ui.Hook.ONBUTTONPRESSED, Guard.wrap("editorHideToggle", function()
            toggleHide(slot)
        end))
    end)

    local marker = ui.Text.new(window)
    marker:SetSize(HIDE_BTN_W, rowHeight - 2, 0, 0)
    marker:SetPos(winWidth - PAD - HIDE_BTN_W, y)
    marker.content = "--"
    marker.font = font()
    marker.colour = COL_TEXT_HIDDEN
    Guard.try(function()
        marker.clickthrough = true
    end)
    Guard.try(function()
        marker:AlignTo(ui.AlignMode.CENTRE, ui.AlignMode.CENTRE)
    end)

    rowComponents[slot] = { bg = bg, text = text, hideButton = hideButton, marker = marker }
end

-- Open the editor for `verbList` at screen position (x, y).
---@param key string the target key orders are saved under
---@param verbList string[] distinct verbs top-to-bottom, already in saved order
---@param hiddenList string[]|nil verbs currently marked hidden for this target
---@param hideable table<string, boolean>|nil verbs that can truly be op-hidden
---@param x number screen x in interface units
---@param y number screen y in interface units
---@param displayName string|nil title shown at the top
---@param closedCallback fun()|nil run after the editor closes
function Editor.Open(key, verbList, hiddenList, hideable, x, y, displayName, closedCallback)
    Editor.Close()

    targetKey = key
    onClosed = closedCallback
    pickedSlot = nil
    verbs = {}
    for i, v in ipairs(verbList) do
        verbs[i] = v
    end
    hiddenSet = {}
    if hiddenList ~= nil then
        for _, v in ipairs(hiddenList) do
            hiddenSet[v] = true
        end
    end
    hideableSet = hideable or {}

    local parent = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    if parent == nil then
        Guard.logOnce("editorParent", "could not find plugin build layer; editor not shown")
        return
    end

    local rowCount = #verbs

    -- Size the window to fit the widest label, title, and hint; labels wider
    -- than MAX_WIDTH wrap to two lines instead.
    winWidth = MIN_WIDTH
    rowHeight = ROW_H_SINGLE

    local titleStr = displayName and ("Reorder: " .. displayName) or "Reorder menu"
    local hintStr = "Click a row to move it"

    local needed = math.max(
        measureWidth(titleStr) + PAD * 3,
        measureWidth(hintStr) + PAD * 3,
        MIN_WIDTH
    )

    local widest = 0
    for _, verb in ipairs(verbs) do
        local label = hiddenSet[verb] and ("(hidden) " .. verb) or verb
        local w = measureWidth(label)
        if w > widest then
            widest = w
        end
    end

    local rowNeeded = widest + LABEL_CHROME
    if rowNeeded <= MAX_WIDTH then
        needed = math.max(needed, rowNeeded)
    else
        -- Widest row label will wrap; cap width and make rows taller.
        needed = math.max(needed, MAX_WIDTH)
        if widest > (MAX_WIDTH - LABEL_CHROME) then
            rowHeight = ROW_H_WRAP
        end
    end

    winWidth = math.max(MIN_WIDTH, math.min(MAX_WIDTH, math.floor(needed)))

    local height = TITLE_H + PAD + rowCount * rowHeight + PAD + HINT_H + BUTTON_H + PAD

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

    -- Background fill.
    local bg = ui.Rectangle.new(window)
    bg:SetSize(0, 0, 1.0, 1.0)
    bg:SetPos(0, 0)
    bg.fill = true
    bg.colour = COL_BG

    -- Title.
    local title = ui.Text.new(window)
    title:SetSize(-(PAD * 2), TITLE_H, 1.0, 0)
    title:SetPos(PAD, 2)
    title.content = displayName and ("Reorder: " .. displayName) or "Reorder menu"
    title.font = font()
    title.colour = COL_TITLE
    Guard.try(function()
        title:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    end)

    for slot = 1, rowCount do
        buildRow(slot)
    end

    -- Hint line above the buttons.
    local hintY = TITLE_H + PAD + rowCount * rowHeight
    local hint = ui.Text.new(window)
    hint:SetSize(-(PAD * 2), HINT_H, 1.0, 0)
    hint:SetPos(PAD, hintY)
    hint.content = "Click a row to move it"
    hint.font = font()
    hint.colour = COL_HINT
    Guard.try(function()
        hint:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    end)

    -- Save / Cancel buttons on the bottom row.
    local buttonY = hintY + HINT_H
    local halfW = (winWidth - PAD * 3) / 2

    local saveButton = ui.Button.new(window)
    Guard.try(function()
        saveButton.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    end)
    saveButton:SetSize(halfW, BUTTON_H, 0, 0)
    saveButton:SetPos(PAD, buttonY)
    Guard.try(function()
        saveButton.label = "Save"
    end)
    Guard.try(function()
        saveButton:Subscribe(ui.Hook.ONBUTTONPRESSED, Guard.wrap("editorSave", function()
            save()
        end))
    end)

    local cancelButton = ui.Button.new(window)
    Guard.try(function()
        cancelButton.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    end)
    cancelButton:SetSize(halfW, BUTTON_H, 0, 0)
    cancelButton:SetPos(PAD * 2 + halfW, buttonY)
    Guard.try(function()
        cancelButton.label = "Cancel"
    end)
    Guard.try(function()
        cancelButton:Subscribe(ui.Hook.ONBUTTONPRESSED, Guard.wrap("editorCancel", function()
            Editor.Close()
        end))
    end)

    layoutRows()
end

return Editor
