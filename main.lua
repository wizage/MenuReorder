-- Menu Reorder - efficient right-click menu entry reordering.
-- Menu Reorder: reorder and hide right-click menu options per target.
--
-- On every right-click we apply saved orders. Hold Shift and pick "Reorder
-- menu..." to open an editor where you can reorder and hide options; a stack of
-- several targets asks which one you mean first.

local Guard = require("src/util/guard")
local Text = require("src/util/text")
local Reorder = require("src/core/reorder")
local OrderStore = require("src/core/order_store")
local HiddenOps = require("src/services/hidden_ops")
local Editor = require("src/ui/editor")
local Picker = require("src/ui/picker")

local MENU_KEY = "menu_reorder_mini_menu"
local EDIT_LABEL = "Reorder menu..."

-- Forward declaration; defined once the menu cache state exists below. Called
-- after the editor closes so a save/un-hide takes effect on the next right-click.
local invalidateMenuCache

-- Order a target's verbs by its saved order, with any new verbs appended.
local function startingOrderFor(targetKey, currentVerbs)
    local saved = OrderStore.get(targetKey)
    if saved == nil or #saved == 0 then
        return currentVerbs
    end
    local present = {}
    for _, v in ipairs(currentVerbs) do
        present[v] = true
    end
    local ordered = {}
    local used = {}
    for _, rawVerb in ipairs(saved) do
        local v = Text.strip(rawVerb)
        if present[v] and not used[v] then
            used[v] = true
            ordered[#ordered + 1] = v
        end
    end
    for _, v in ipairs(currentVerbs) do
        if not used[v] then
            used[v] = true
            ordered[#ordered + 1] = v
        end
    end
    return ordered
end

-- Build the order to apply: visible verbs in saved order, then hidden verbs at
-- the bottom (we can only reposition entries, not delete them).
local function effectiveOrder(targetKey, currentVerbs)
    local hiddenList = OrderStore.getHidden(targetKey)
    local saved = OrderStore.get(targetKey)

    -- Nothing configured for this target: skip all the work (the common case,
    -- and what keeps a big unconfigured stack cheap on every tick).
    if (saved == nil or #saved == 0) and #hiddenList == 0 then
        return nil
    end

    local hiddenSet = {}
    for _, v in ipairs(hiddenList) do
        hiddenSet[Text.strip(v)] = true
    end

    local visible = {}
    local used = {}

    -- Saved order first, skipping hidden verbs.
    if saved ~= nil then
        for _, rawVerb in ipairs(saved) do
            local v = Text.strip(rawVerb)
            if not used[v] and not hiddenSet[v] then
                used[v] = true
                visible[#visible + 1] = v
            end
        end
    end
    -- Then any remaining visible verbs.
    for _, v in ipairs(currentVerbs) do
        if not used[v] and not hiddenSet[v] then
            used[v] = true
            visible[#visible + 1] = v
        end
    end

    -- Hidden verbs last.
    local hidden = {}
    for _, v in ipairs(currentVerbs) do
        if hiddenSet[v] then
            hidden[#hidden + 1] = v
        end
    end

    if #visible == 0 and #hidden == 0 then
        return nil
    end
    for _, v in ipairs(hidden) do
        visible[#visible + 1] = v
    end
    return visible
end

-- Open the reorder editor for one target group at the given screen anchor.
local function openEditorForGroup(group, x, y)
    local currentVerbs = Reorder.groupDistinctVerbs(group)
    local hiddenList = OrderStore.getHidden(group.key)

    -- A hidden verb is gone from the live menu, so merge the saved hidden
    -- verbs back in - otherwise you couldn't see them to un-hide them.
    local seen = {}
    for _, v in ipairs(currentVerbs) do
        seen[v] = true
    end
    for _, raw in ipairs(hiddenList) do
        local v = Text.strip(raw)
        if not seen[v] then
            seen[v] = true
            currentVerbs[#currentVerbs + 1] = v
        end
    end

    -- Verbs we can hide: those with a named op, plus anything already hidden
    -- (which we must be able to show again).
    local hideable = {}
    for v in pairs(group.hideable or {}) do
        hideable[v] = true
    end
    for _, raw in ipairs(hiddenList) do
        hideable[Text.strip(raw)] = true
    end

    local startOrder = startingOrderFor(group.key, currentVerbs)
    Editor.Open(group.key, startOrder, hiddenList, hideable, x, y, group.displayName,
        invalidateMenuCache)
end

-- A group is worth editing if it has at least two distinct verbs, counting
-- hidden ones so a target with a hidden verb still opens.
local function reorderableGroups(groups)
    local out = {}
    for _, group in ipairs(groups) do
        local seen = {}
        local count = 0
        for _, v in ipairs(Reorder.groupDistinctVerbs(group)) do
            if not seen[v] then
                seen[v] = true
                count = count + 1
            end
        end
        for _, raw in ipairs(OrderStore.getHidden(group.key)) do
            local v = Text.strip(raw)
            if not seen[v] then
                seen[v] = true
                count = count + 1
            end
        end
        if count >= 2 then
            out[#out + 1] = group
        end
    end
    return out
end

-- Cheap O(1) signature of the menu, to detect when it's unchanged tick-to-tick.
-- We reorder entries with Swap, so include a couple of entry texts, not just the
-- count. When the signature matches the previous call we reuse the cached groups
-- instead of rescanning every entry (the scan is the per-tick cost on a crowded
-- menu like a big ground-item pile).
local sigCount, sigFirst, sigLast = nil, nil, nil
local cachedGroups = nil
local cachedHasWork = false

-- Drop the menu cache so the next right-click re-scans and re-evaluates work.
function invalidateMenuCache()
    sigCount, sigFirst, sigLast = nil, nil, nil
    cachedGroups = nil
    cachedHasWork = false
end

local function menuSignature(miniMenu)
    local count = miniMenu.entryCount
    local first = miniMenu.entries[1]
    local last = miniMenu.entries[count]
    return count,
        Guard.read(first, "verbText"),
        Guard.read(last, "verbText")
end

-- Whether any group in this menu needs per-tick processing: a configured target
-- (saved order or hidden verbs) or a component we still need to restore.
local function computeHasWork(groups)
    if HiddenOps.hasTouched() then
        return true
    end
    for _, group in ipairs(groups) do
        if OrderStore.get(group.key) ~= nil or #OrderStore.getHidden(group.key) > 0 then
            return true
        end
    end
    return false
end

local function onMiniMenuReady(event)
    local miniMenu = event and event.miniMenu
    if miniMenu == nil or miniMenu.entryCount == nil or miniMenu.entryCount < 2 then
        return
    end

    -- Reuse the cached grouping when the menu looks unchanged since last tick.
    local count, first, last = menuSignature(miniMenu)
    local groups
    if count == sigCount and first == sigFirst and last == sigLast and cachedGroups ~= nil then
        groups = cachedGroups
    else
        groups = Reorder.getTargetGroups(miniMenu)
        sigCount, sigFirst, sigLast = count, first, last
        cachedGroups = groups
        cachedHasWork = computeHasWork(groups)
    end
    if #groups == 0 then
        return
    end

    -- Per-group work only runs when something in this menu is configured. For a
    -- big unconfigured pile this is skipped, keeping every hover tick cheap.
    if cachedHasWork then
        for _, group in ipairs(groups) do
            local hiddenList = OrderStore.getHidden(group.key)
            local saved = OrderStore.get(group.key)
            local configured = (saved ~= nil and #saved > 0) or #hiddenList > 0

            if #hiddenList > 0 then
                local hiddenSet = {}
                for _, v in ipairs(hiddenList) do
                    hiddenSet[Text.strip(v)] = true
                end
                Guard.try(function()
                    HiddenOps.applyMenu(miniMenu, group.indexes, hiddenSet)
                end)
            elseif HiddenOps.hasTouched() then
                -- Nothing hidden now; restore anything we hid earlier here.
                for _, idx in ipairs(group.indexes) do
                    Guard.try(function()
                        HiddenOps.restoreEntry(miniMenu.entries[idx])
                    end)
                end
            end

            if configured then
                local currentVerbs = Reorder.groupDistinctVerbs(group)
                local order = effectiveOrder(group.key, currentVerbs)
                if order ~= nil then
                    Reorder.apply(miniMenu, group.indexes, group.verbByIndex, order)
                end
            end
        end
    end

    -- Below here only runs on Shift+right-click, to offer the editor. Reuse the
    -- groups from above - the Swap pass doesn't change group membership.
    if not Keyboard.IsShiftDown() or Editor.IsOpen() or Picker.IsOpen() then
        return
    end

    local editable = reorderableGroups(groups)
    if #editable == 0 then
        return
    end

    -- Record which verbs can be hidden now, while the entries are live - the
    -- editor opens later from a callback when they're gone.
    for _, group in ipairs(editable) do
        group.hideable = HiddenOps.hideableVerbs(miniMenu, group.indexes)
    end

    -- Capture the cursor position now; it drifts before the click callback runs.
    local anchorX = Mouse.IsAvailable() and Mouse.GetX() or 100
    local anchorY = Mouse.IsAvailable() and Mouse.GetY() or 100

    Guard.try(function()
        miniMenu:Add(
            Text.colour(EDIT_LABEL, "ffd24d"),
            Guard.wrap("openEditor", function()
                if #editable == 1 then
                    openEditorForGroup(editable[1], anchorX, anchorY)
                else
                    -- A stack: ask which target first.
                    Picker.Open(editable, anchorX, anchorY, function(group)
                        openEditorForGroup(group, anchorX, anchorY)
                    end)
                end
            end)
        )
    end)
end

Event.MiniMenuReady.Subscribe(MENU_KEY, Guard.wrap("onMiniMenuReady", onMiniMenuReady))

print("[MenuReorder] loaded - Shift + right-click to reorder menu entries")

-- Console toggle for the hide diagnostics.
function MenuReorderHideDebug(on)
    HiddenOps.debug = on ~= false
    print("[MenuReorder] hide diagnostics " .. (HiddenOps.debug and "ON" or "OFF"))
end

-- Lifecycle: tear everything down when the plugin unloads.
function PluginShutdown()
    Guard.try(function()
        Event.MiniMenuReady.Unsubscribe(MENU_KEY)
    end)
    Guard.try(function()
        HiddenOps.restoreAll()
    end)
    Guard.try(function()
        Editor.Close()
    end)
    Guard.try(function()
        Picker.Close()
    end)
end
