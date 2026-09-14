-- ============================================================
--  GENERIC OPTION CONTROL SYSTEM  (optimised)
--  Perf pass: script-indexed refresh buckets (was O(n) full-array
--  scan per checkbox toggle, now O(k) over just that script's
--  links), a weak combo-&gt;link cache for linked preset combos (was
--  O(n) scan per OnChange), record-cache reuse instead of raw
--  AddressList lookups, and de-duplicated Eraz3r helpers.
-- ============================================================

if OptionToggleLinks == nil then OptionToggleLinks = {} end
if OptionTrackBarLinks == nil then OptionTrackBarLinks = {} end
if OptionCheckboxLinks == nil then OptionCheckboxLinks = {} end
if OptionEditLinks == nil then OptionEditLinks = {} end
if OptionLinksByForm == nil then OptionLinksByForm = {} end
if OptionLinksByScript == nil then OptionLinksByScript = {} end

-- Cache CE AddressList / MemoryRecord lookups.
local CE_AL = getAddressList()
local CE_RecordCache = {}

-- Weak cache for control -&gt; form resolution (eliminates repeated 12-deep walks)
local FormCache = setmetatable({}, {__mode = "k"})

-- Weak cache for combo -&gt; link resolution (eliminates repeated full-array scans)
local ComboToLink = setmetatable({}, {__mode = "k"})

-- LOCALIZED GLOBALS (performance critical)
local math_abs = math.abs
local math_floor = math.floor
local string_format = string.format
local string_gmatch = string.gmatch
local string_gsub = string.gsub
local string_lower = string.lower
local string_upper = string.upper
local string_match = string.match
local table_insert = table.insert
local table_concat = table.concat
local table_sort = table.sort
local os_clock = os.clock
local pcall = pcall
local tonumber = tonumber
local tostring = tostring
local type = type
local ipairs = ipairs
local pairs = pairs
local next = next
local setmetatable = setmetatable

-- ============================================================
-- FORM RESOLUTION
-- ============================================================
local function CE_ResolveOwnerForm(ctrl)
  if ctrl == nil then return nil end
  local cached = FormCache[ctrl]
  if cached ~= nil then return cached end
  local o = ctrl
  for _ = 1, 12 do
    if o == nil then FormCache[ctrl] = nil; return nil end
    local ok, cn = pcall(function() return o.ClassName end)
    if ok and cn ~= nil then
      local s = tostring(cn)
      if s:find("Form", 1, true) then
        FormCache[ctrl] = o
        return o
      end
    end
    local nxt = nil
    pcall(function() nxt = o.Owner end)
    o = nxt
  end
  FormCache[ctrl] = nil
  return nil
end

local function CE_IndexLinkByForm(form, kind, link)
  if form == nil or link == nil then return end
  local bucket = OptionLinksByForm[form]
  if bucket == nil then
    bucket = { toggles = {}, trackbars = {}, checkboxes = {}, edits = {} }
    OptionLinksByForm[form] = bucket
  end
  local t = bucket[kind]
  t[#t+1] = link
  link.form = form
end

local function CE_IndexLinkByScript(scriptMr, kind, link)
  if scriptMr == nil or link == nil then return end
  local bucket = OptionLinksByScript[scriptMr]
  if bucket == nil then
    bucket = { toggles = {}, trackbars = {}, checkboxes = {}, edits = {} }
    OptionLinksByScript[scriptMr] = bucket
  end
  local t = bucket[kind]
  t[#t+1] = link
end

-- ============================================================
-- MEMORY RECORD HELPERS
-- ============================================================
local function CE_GetRecord(idOrDescription)
  local key = type(idOrDescription) .. ":" .. tostring(idOrDescription)
  local cached = CE_RecordCache[key]
  if cached ~= nil then return cached end
  local mr
  if type(idOrDescription) == "number" then
    mr = CE_AL.getMemoryRecordByID(idOrDescription)
  else
    mr = CE_AL.getMemoryRecordByDescription(idOrDescription)
  end
  if mr ~= nil then CE_RecordCache[key] = mr end
  return mr
end

-- ============================================================
-- STRING / VALUE HELPERS
-- ============================================================
local TRIM_L = "^%s+"
local TRIM_R = "%s+$"
local function CE_Trim(s)
  return string_gsub(string_gsub(tostring(s or ""), TRIM_L, ""), TRIM_R, "")
end

local function CE_GetNumericValue(value)
  if value == nil then return nil end
  local s = CE_Trim(value)
  local n = tonumber(s)
  if n ~= nil then return n end
  return tonumber(s, 16)
end

local function CE_ValuesEqual(a, b)
  if a == b then return true end
  if a == nil or b == nil then return false end
  local sa, sb = tostring(a), tostring(b)
  if sa == sb then return true end
  local na, nb = tonumber(sa), tonumber(sb)
  if na and nb then return math_abs(na - nb) &lt; 0.0001 end
  na, nb = tonumber(sa, 16), tonumber(sb, 16)
  if na and nb then return math_abs(na - nb) &lt; 0.0001 end
  return false
end

-- ============================================================
-- DROPDOWN PARSER
-- ============================================================
local function CE_ParseDropDown(mr)
  local list = {}
  local dd = mr.DropDownList
  if dd == nil then return list end
  local lines = {}
  local ok, count = pcall(function() return dd.Count end)
  if ok and count then
    for i = 0, count - 1 do
      local ok2, line = pcall(function() return dd[i] end)
      if ok2 and line then lines[#lines+1] = line end
    end
  end
  if #lines == 0 then
    local text = dd.Text or ""
    for line in string_gmatch(text, "[^\r\n]+") do lines[#lines+1] = line end
  end
  for i = 1, #lines do
    local line = lines[i]
    if line ~= "" then
      local value, label = string_match(line, "^(.-):(.*)$")
      if value then list[#list+1] = {value = value, label = label} end
    end
  end
  return list
end

-- ============================================================
-- COMBOBOX HELPERS
-- ============================================================
local function CE_IsEditableComboStyle(style)
  if style == nil then return false end
  if style == 0 then return true end
  local s = string_lower(string_gsub(string_gsub(tostring(style), "^%s+", ""), "%s+$", ""))
  return s == "0" or s == "csdropdown" or s == "dropdown"
end

local function CE_ControlHasFocus(control)
  if control == nil then return false end
  local ok, focused = pcall(function() return control.Focused end)
  return ok and focused == true
end

local function CE_FindComboItem(link, current)
  local currentNum = tonumber(current) or tonumber(current, 16)
  local items = link.items
  for i = 1, #items do
    local item = items[i]
    if item.value ~= nil then
      if currentNum ~= nil and item.numeric ~= nil then
        if math_abs(item.numeric - currentNum) &lt; 0.0001 then return i, item end
      elseif CE_ValuesEqual(item.value, current) then
        return i, item
      end
    end
  end
  return nil, nil
end

local function CE_RemoveRawComboItem(link)
  if link == nil or link.combo == nil then return end
  local combo = link.combo
  if link.rawItemIndex ~= nil then
    local index = link.rawItemIndex
    if index &gt;= 0 and index &lt; combo.Items.Count then
      local okText, text = pcall(function() return combo.Items[index] end)
      if okText and link.rawItemText ~= nil and tostring(text) == tostring(link.rawItemText) then
        link.updating = true
        pcall(function() combo.Items.Delete(index) end)
        link.updating = false
      end
    end
  end
  link.rawItemIndex = nil
  link.rawItemText = nil
end

local function CE_ShowRawComboValue(link, current)
  if link == nil or link.combo == nil then return end
  local combo = link.combo
  CE_RemoveRawComboItem(link)
  local text = tostring(current)
  link.updating = true
  combo.Items.Add(text)
  local index = combo.Items.Count - 1
  combo.ItemIndex = index
  link.rawItemIndex = index
  link.rawItemText = text
  link.updating = false
end

local function CE_ShowEditableComboValue(link, current)
  if link == nil or link.combo == nil then return end
  link.updating = true
  link.combo.ItemIndex = -1
  link.combo.Text = tostring(current)
  link.updating = false
end

-- ============================================================
-- COMMIT EDITABLE COMBOBOX
-- ============================================================
local function CE_CommitEditableCombo(link)
  if link == nil or link.combo == nil or link.record == nil then return end
  if link.updating then return end
  if not link.editable then return end
  if link.script ~= nil and not link.script.Active then return end
  local text = CE_Trim(link.combo.Text)
  if text == "" then return end
  local value = nil
  for i = 1, #link.items do
    local item = link.items[i]
    if (item.labelTrim or CE_Trim(item.label)) == text then
      value = item.value
      break
    end
  end
  if value == nil then value = CE_GetNumericValue(text) end
  if value == nil then return end
  link.pendingValue = value
  link.pendingUntil = os_clock() + 1.0
  pcall(function() link.record.Value = tostring(value) end)
  local matchedIndex = nil
  for i = 1, #link.items do
    if link.items[i].value ~= nil and CE_ValuesEqual(link.items[i].value, value) then
      matchedIndex = i
      break
    end
  end
  link.updating = true
  if matchedIndex ~= nil then
    CE_RemoveRawComboItem(link)
    link.combo.ItemIndex = matchedIndex - 1
  else
    CE_RemoveRawComboItem(link)
    link.combo.ItemIndex = -1
    link.combo.Text = tostring(value)
  end
  link.updating = false
end

-- ============================================================
-- REFRESH ONE COMBOBOX
-- ============================================================
function RefreshOptionToggle(link, forceEditable)
  if link == nil then return end
  local combo = link.combo
  local record = link.record
  local script = link.script
  if combo == nil or record == nil or script == nil then return end
  forceEditable = forceEditable == true
  if link.editable and not forceEditable then return end
  if link.editable and not link.forceRefresh then
    if link.editing or CE_ControlHasFocus(combo) then return end
  end
  if link.interacting and not forceEditable then return end
  local pending = link.pendingValue
  local pendingUntil = link.pendingUntil
  if pending ~= nil and pendingUntil ~= nil then
    if os_clock() &lt; pendingUntil then
      link.updating = true
      local matchedIndex = CE_FindComboItem(link, pending)
      if matchedIndex ~= nil then
        local target = matchedIndex - 1
        if combo.ItemIndex ~= target then combo.ItemIndex = target end
      elseif link.editable then
        local text = tostring(pending)
        if combo.ItemIndex ~= -1 or tostring(combo.Text or "") ~= text then
          combo.ItemIndex = -1
          combo.Text = text
        end
      end
      link.updating = false
      return
    else
      link.pendingValue = nil
      link.pendingUntil = nil
    end
  end
  link.updating = true
  if not script.Active then
    CE_RemoveRawComboItem(link)
    combo.Enabled = false
    if link.editable then
      combo.ItemIndex = -1
      combo.Text = ""
    else
      combo.ItemIndex = link.placeholderIndex
    end
    link.updating = false
    return
  end
  combo.Enabled = true
  local ok, current = pcall(function() return record.Value end)
  if not ok or current == nil then
    link.updating = false
    return
  end
  local matchedIndex = CE_FindComboItem(link, current)
  if matchedIndex ~= nil then
    CE_RemoveRawComboItem(link)
    local target = matchedIndex - 1
    if combo.ItemIndex ~= target then combo.ItemIndex = target end
  elseif link.editable then
    local text = tostring(current)
    if combo.ItemIndex ~= -1 or tostring(combo.Text or "") ~= text then
      combo.ItemIndex = -1
      combo.Text = text
    end
  else
    local text = tostring(current)
    if link.rawItemIndex == nil or link.rawItemText ~= text then
      CE_ShowRawComboValue(link, current)
    elseif combo.ItemIndex ~= link.rawItemIndex then
      combo.ItemIndex = link.rawItemIndex
    end
  end
  link.updating = false
end

-- ============================================================
-- REFRESH ALL CONTROLS
-- ============================================================
function RefreshOptionEditEnabled(link)
  if link == nil or link.edit == nil then return end
  local active = link.script ~= nil and link.script.Active == true
  if link._lastEnabled == active then return end
  link._lastEnabled = active
  if not active then
    link.edit.Enabled = false
    link.edit.Text = ""
  else
    link.edit.Enabled = true
  end
end

function RefreshAllOptionEditEnabled()
  for i = 1, #OptionEditLinks do
    pcall(RefreshOptionEditEnabled, OptionEditLinks[i])
  end
end

-- Now uses the per-script index instead of a full scan of every
-- registered link on every one of the four global arrays.
function RefreshOptionLinksForScript(scriptMr, forceEditable)
  if scriptMr == nil then return end
  local force = forceEditable == true
  local bucket = OptionLinksByScript[scriptMr]
  if bucket == nil then return end
  local toggles = bucket.toggles
  for i = 1, #toggles do pcall(RefreshOptionToggle, toggles[i], force) end
  local trackbars = bucket.trackbars
  for i = 1, #trackbars do pcall(RefreshOptionTrackBar, trackbars[i]) end
  local checkboxes = bucket.checkboxes
  for i = 1, #checkboxes do pcall(RefreshOptionCheckbox, checkboxes[i]) end
  local edits = bucket.edits
  for i = 1, #edits do
    local link = edits[i]
    link._lastEnabled = nil
    if force then link.forceRefresh = true end
    pcall(RefreshOptionEdit, link)
    if force then link.forceRefresh = false end
  end
end

function RefreshAllOptionToggles(forceEditable)
  forceEditable = forceEditable == true
  for i = 1, #OptionToggleLinks do
    pcall(RefreshOptionToggle, OptionToggleLinks[i], forceEditable)
  end
  RefreshAllOptionTrackBars()
  RefreshAllOptionEditEnabled()
  RefreshAllOptionCheckboxes()
end

-- ============================================================
-- SHARED COMBOBOX LINK FINALIZATION
-- ============================================================
local function CE_FinalizeComboLink(combo, mr, scriptMr, items)
  local editable = CE_IsEditableComboStyle(combo.Style)
  if editable then
    pcall(function() combo.AutoComplete = false end)
    pcall(function() combo.ReadOnly = false end)
  end
  for i = 1, #items do
    local item = items[i]
    if item.value ~= nil then
      item.numeric = tonumber(item.value) or tonumber(item.value, 16)
    end
    if item.label ~= nil then
      item.labelTrim = CE_Trim(item.label)
    end
  end
  local link = {
    combo = combo, record = mr, script = scriptMr, items = items,
    placeholderIndex = -1, updating = false, interacting = false,
    editing = false, pendingValue = nil, pendingUntil = nil,
    editable = editable, rawItemIndex = nil, rawItemText = nil,
    forceRefresh = false
  }
  OptionToggleLinks[#OptionToggleLinks+1] = link
  CE_IndexLinkByForm(CE_ResolveOwnerForm(combo), "toggles", link)
  CE_IndexLinkByScript(scriptMr, "toggles", link)
  ComboToLink[combo] = link

  combo.OnChange = function(sender)
    if link.updating then return end
    if not link.script.Active then return end

    local idx = sender.ItemIndex

    if link.editable then
      -- Mouse-wheel / keyboard selection of a predefined item must still write.
      -- Only free-typed text (ItemIndex == -1) is treated as an in-progress edit.
      if idx ~= nil and idx &gt;= 0 and idx &lt; #link.items then
        local value = link.items[idx + 1].value
        if value ~= nil then
          link.pendingValue = value
          link.pendingUntil = os_clock() + 1.0
          pcall(function() link.record.Value = tostring(value) end)
          link.editing = false
        end
      else
        link.editing = true
      end
      return
    end

    -- csDropDownList path (unchanged)
    if idx ~= nil and idx &gt;= 0 and idx &lt; #link.items then
      local value = link.items[idx + 1].value
      if value ~= nil then
        link.pendingValue = value
        link.pendingUntil = os_clock() + 1.0
        pcall(function() link.record.Value = tostring(value) end)
      end
    end
  end

  if editable then
    combo.OnEnter = function(sender) link.editing = true end
    combo.OnExit = function(sender)
      CE_CommitEditableCombo(link)
      link.editing = false
    end
    combo.OnKeyDown = function(sender, key)
      link.editing = true
      if key == 13 then
        CE_CommitEditableCombo(link)
        link.editing = false
      end
    end
    combo.OnKeyUp = function(sender, key)
      link.editing = true
    end
  end

  local previousDropDown = combo.OnDropDown
  combo.OnDropDown = function(sender)
    link.interacting = true
    if previousDropDown ~= nil then pcall(previousDropDown, sender) end
  end

  local previousCloseUp = combo.OnCloseUp
  combo.OnCloseUp = function(sender)
    link.interacting = false
    if previousCloseUp ~= nil then pcall(previousCloseUp, sender) end
    if not link.editable then RefreshOptionToggle(link, true) end
  end

  RefreshOptionToggle(link, true)
  return link
end

-- ============================================================
-- REGISTER GENERIC COMBOBOX
-- ============================================================
function RegisterOptionToggle(combo, recordIdOrDesc, scriptIdOrDesc)
  if combo == nil then
    print("RegisterOptionToggle: combo control is NIL for record -&gt; " .. tostring(recordIdOrDesc))
    return nil
  end
  local mr = CE_GetRecord(recordIdOrDesc)
  local scriptMr = CE_GetRecord(scriptIdOrDesc)
  if mr == nil then
    print("RegisterOptionToggle: record not found -&gt; " .. tostring(recordIdOrDesc))
    return nil
  end
  if scriptMr == nil then
    print("RegisterOptionToggle: script not found -&gt; " .. tostring(scriptIdOrDesc))
    return nil
  end
  local items = CE_ParseDropDown(mr)
  combo.Items.Clear()
  for i = 1, #items do combo.Items.Add(items[i].label) end
  return CE_FinalizeComboLink(combo, mr, scriptMr, items)
end

-- ============================================================
-- REGISTER MAPPED COMBOBOX
-- ============================================================
function RegisterMappedOptionCombo(combo, recordIdOrDesc, scriptIdOrDesc, labelToValue)
  if combo == nil then
    print("RegisterMappedOptionCombo: combo is NIL for record -&gt; " .. tostring(recordIdOrDesc))
    return nil
  end
  local mr = CE_GetRecord(recordIdOrDesc)
  local scriptMr = CE_GetRecord(scriptIdOrDesc)
  if mr == nil or scriptMr == nil then
    print("RegisterMappedOptionCombo: missing record/script -&gt; " .. tostring(recordIdOrDesc) .. " / " .. tostring(scriptIdOrDesc))
    return nil
  end
  local items = {}
  local normalizedMap = {}
  for k, v in pairs(labelToValue) do
    normalizedMap[tostring(k):gsub("^%s+", ""):gsub("%s+$", ""):upper()] = v
  end
  for i = 0, combo.Items.Count - 1 do
    local label = combo.Items[i]
    local value = labelToValue[label]
    if value == nil then
      value = normalizedMap[tostring(label):gsub("^%s+", ""):gsub("%s+$", ""):upper()]
    end
    items[#items+1] = {value = value, label = label}
  end
  return CE_FinalizeComboLink(combo, mr, scriptMr, items)
end

-- ============================================================
-- GENERIC EDIT OPTION SYSTEM
-- ============================================================
function RefreshOptionEdit(link)
  local edit = link.edit
  if edit == nil then return end
  if link.editing and not link.forceRefresh then return end
  local formVisible = true
  if not link.forceRefresh then
    local form = link.form
    if form ~= nil then
      local vis = nil
      pcall(function() vis = form.Visible end)
      if vis == false then formVisible = false end
    else
      local owner = nil
      pcall(function() owner = edit.Owner end)
      if owner ~= nil then
        local vis = nil
        pcall(function() vis = owner.Visible end)
        if vis == false then formVisible = false end
      end
    end
  end
  link.updating = true
  local active = link.script ~= nil and link.script.Active == true
  if not active then
    edit.Enabled = false
    edit.Text = ""
    link.updating = false
    return
  end
  edit.Enabled = true
  if not formVisible then
    link.updating = false
    return
  end
  local ok, current = pcall(function() return link.record.Value end)
  if not ok or current == nil then
    edit.Text = ""
    link.updating = false
    return
  end
  local n = tonumber(current)
  if n == nil then
    edit.Text = tostring(current)
  elseif link.format == "integer" then
    edit.Text = string_format("%d", math_floor(n + 0.5))
  elseif link.format == "float" then
    edit.Text = string_format("%.6g", n)
  else
    edit.Text = tostring(current)
  end
  link.updating = false
end

function RefreshAllOptionEdits()
  for i = 1, #OptionEditLinks do
    pcall(RefreshOptionEdit, OptionEditLinks[i])
  end
end

function RegisterOptionEdit(edit, recordIdOrDesc, scriptIdOrDesc, format)
  if edit == nil then
    print("RegisterOptionEdit: edit control is NIL for record -&gt; " .. tostring(recordIdOrDesc))
    return nil
  end
  local mr = CE_GetRecord(recordIdOrDesc)
  local scriptMr = CE_GetRecord(scriptIdOrDesc)
  if mr == nil then
    print("RegisterOptionEdit: record not found -&gt; " .. tostring(recordIdOrDesc))
    return nil
  end
  if scriptMr == nil then
    print("RegisterOptionEdit: script not found -&gt; " .. tostring(scriptIdOrDesc))
    return nil
  end
  local link = {
    edit = edit, record = mr, script = scriptMr,
    format = format or "float",
    updating = false, editing = false, forceRefresh = false
  }
  OptionEditLinks[#OptionEditLinks+1] = link
  CE_IndexLinkByForm(CE_ResolveOwnerForm(edit), "edits", link)
  CE_IndexLinkByScript(scriptMr, "edits", link)
  edit.OnEnter = function(sender) link.editing = true end
  edit.OnExit = function(sender)
    link.editing = false
    RefreshOptionEdit(link)
  end
  edit.OnChange = function(sender)
    if link.updating then return end
    link.editing = true
    if not link.script.Active then
      RefreshOptionEdit(link)
      return
    end
    local value = tonumber(tostring(sender.Text or ""))
    if value ~= nil then
      link.record.Value = tostring(value)
    end
  end
  RefreshOptionEdit(link)
  return link
end

-- ============================================================
-- GENERIC CHECKBOX OPTION SYSTEM
-- ============================================================
function RefreshOptionCheckbox(link)
  if link == nil or link.checkbox == nil or link.record == nil or link.script == nil then return end
  if link.updating then return end
  if link.interacting then return end
  local active = (link.script.Active == true)
  link.updating = true
  if not active then
    link.checkbox.Checked = false
    link.checkbox.Enabled = false
    link.updating = false
    return
  end
  link.checkbox.Enabled = true
  local ok, current = pcall(function() return link.record.Value end)
  if ok then
    link.checkbox.Checked = (tonumber(current) == 1)
  end
  link.updating = false
end

function RefreshAllOptionCheckboxes()
  if OptionCheckboxLinks == nil then return end
  for i = 1, #OptionCheckboxLinks do
    pcall(RefreshOptionCheckbox, OptionCheckboxLinks[i])
  end
end

function RegisterOptionCheckbox(checkbox, recordIdOrDesc, scriptIdOrDesc)
  if checkbox == nil then
    print("RegisterOptionCheckbox: checkbox is NIL for record -&gt; " .. tostring(recordIdOrDesc))
    return nil
  end
  local mr = CE_GetRecord(recordIdOrDesc)
  local scriptMr = CE_GetRecord(scriptIdOrDesc)
  if mr == nil or scriptMr == nil then
    print("RegisterOptionCheckbox: missing record/script -&gt; " .. tostring(recordIdOrDesc) .. " / " .. tostring(scriptIdOrDesc))
    return nil
  end
  local link = {
    checkbox = checkbox, record = mr, script = scriptMr,
    updating = false, interacting = false
  }
  OptionCheckboxLinks[#OptionCheckboxLinks+1] = link
  CE_IndexLinkByForm(CE_ResolveOwnerForm(link.checkbox), "checkboxes", link)
  CE_IndexLinkByScript(scriptMr, "checkboxes", link)
  checkbox.OnMouseDown = function(sender, button, x, y) link.interacting = true end
  checkbox.OnMouseUp = function(sender, button, x, y) link.interacting = false end
  checkbox.OnChange = function(sender)
    if link.updating then return end
    if not link.script.Active then
      RefreshOptionCheckbox(link)
      return
    end
    link.record.Value = sender.Checked and 1 or 0
  end
  RefreshOptionCheckbox(link)
  return link
end

-- ============================================================
-- GENERIC TRACKBAR OPTION SYSTEM
-- ============================================================
local TRACKBAR_STEP_POSITION = 1
local TRACKBAR_VALUE_SCALE = 1

function RefreshOptionTrackBar(link)
  local bar = link.bar
  local active = link.script ~= nil and link.script.Active == true
  link.updating = true
  if not active then
    bar.Enabled = false
    bar.Position = bar.Min
    link.updating = false
    return
  end
  bar.Enabled = true
  local ok, current = pcall(function() return link.record.Value end)
  local value = ok and tonumber(current) or nil
  if value == nil then
    bar.Position = bar.Min
    link.updating = false
    return
  end
  local position = math_floor(value * TRACKBAR_VALUE_SCALE + 0.5)
  if position &lt; bar.Min then position = bar.Min end
  if position &gt; bar.Max then position = bar.Max end
  position = math_floor(position / TRACKBAR_STEP_POSITION + 0.5) * TRACKBAR_STEP_POSITION
  if position &lt; bar.Min then position = bar.Min end
  if position &gt; bar.Max then position = bar.Max end
  if bar.Position ~= position then bar.Position = position end
  link.updating = false
end

function RefreshAllOptionTrackBars()
  for i = 1, #OptionTrackBarLinks do
    pcall(RefreshOptionTrackBar, OptionTrackBarLinks[i])
  end
end

function RegisterOptionTrackBar(bar, recordID, scriptID)
  if bar == nil then
    print("RegisterOptionTrackBar: TrackBar is NIL for record -&gt; " .. tostring(recordID))
    return nil
  end
  local mr = CE_GetRecord(recordID)
  local scriptMr = CE_GetRecord(scriptID)
  if mr == nil then
    print("RegisterOptionTrackBar: record not found -&gt; " .. tostring(recordID))
    return nil
  end
  if scriptMr == nil then
    print("RegisterOptionTrackBar: script not found -&gt; " .. tostring(scriptID))
    return nil
  end
  local link = { bar = bar, record = mr, script = scriptMr, updating = false }
  OptionTrackBarLinks[#OptionTrackBarLinks+1] = link
  CE_IndexLinkByForm(CE_ResolveOwnerForm(link.bar), "trackbars", link)
  CE_IndexLinkByScript(scriptMr, "trackbars", link)
  bar.OnChange = function(sender)
    if link.updating then return end
    if not link.script.Active then
      RefreshOptionTrackBar(link)
      return
    end
    local position = tonumber(sender.Position) or 0
    local snapped = math_floor(position / TRACKBAR_STEP_POSITION + 0.5) * TRACKBAR_STEP_POSITION
    if snapped &lt; sender.Min then snapped = sender.Min end
    if snapped &gt; sender.Max then snapped = sender.Max end
    if sender.Position ~= snapped then
      link.updating = true
      sender.Position = snapped
      link.updating = false
    end
    local value = snapped / TRACKBAR_VALUE_SCALE
    link.record.Value = tostring(value)
  end
  RefreshOptionTrackBar(link)
  return link
end

-- ============================================================
-- SAFE WIRING
-- ============================================================
local function TryWire(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    print("[OptionToggle wiring error] " .. tostring(err))
  end
end

-- ============================================================
-- TRAINER FORM SETUP
-- ============================================================
local function findFormByName(name)
  local n = getFormCount()
  for i = 0, n - 1 do
    local f = getForm(i)
    if f ~= nil and f.Name == name then return f end
  end
  return nil
end

local trainerForm = findFormByName("TrainerForm")
if trainerForm ~= nil then
  trainerForm.Width = 1096
  trainerForm.Height = 640
  trainerForm.Position = poScreenCenter
  trainerForm.WindowState = wsNormal
  trainerForm.Visible = true
  trainerForm.Show()
  trainerForm.BringToFront()
end

PROCESS_NAME = "REResistance.exe"

-- ============================================================
-- CHECKBOX ATTACHMENT STATE  (must be defined before the timer)
-- ============================================================
local trainerCheckboxes = {}

local function RegisterTrainerCheckbox(checkbox, recordID)
  if checkbox == nil then return end
  trainerCheckboxes[#trainerCheckboxes+1] = { checkbox = checkbox, recordID = recordID }
end

local function IsGameRunning()
  local currentPid = getOpenedProcessID()
  if currentPid == 0 then return false end
  local livePid = getProcessIDFromProcessName(PROCESS_NAME)
  return livePid ~= nil and livePid == currentPid
end

local function RefreshTrainerCheckboxes()
  local attached = IsGameRunning()
  if not attached then
    for i = 1, #trainerCheckboxes do
      local entry = trainerCheckboxes[i]
      local cb = entry.checkbox
      local mr = CE_GetRecord(entry.recordID)
      if mr ~= nil and mr.Active then mr.Active = false end
      cb.Checked = false
      cb.Enabled = false
    end
    for i = 1, #OptionToggleLinks do
      local link = OptionToggleLinks[i]
      CE_RemoveRawComboItem(link)
      link.combo.Enabled = false
      link.editing = false
      link.pendingValue = nil
      link.pendingUntil = nil
      if link.editable then
        link.combo.ItemIndex = -1
        link.combo.Text = ""
      else
        link.combo.ItemIndex = link.placeholderIndex
      end
    end
    for i = 1, #OptionTrackBarLinks do
      local link = OptionTrackBarLinks[i]
      link.bar.Enabled = false
      link.bar.Position = link.bar.Min
    end
    for i = 1, #OptionCheckboxLinks do
      local link = OptionCheckboxLinks[i]
      link.checkbox.Enabled = false
      link.checkbox.Checked = false
    end
    for i = 1, #OptionEditLinks do
      local link = OptionEditLinks[i]
      link.edit.Enabled = false
      link.edit.Text = ""
    end
    if RestartForm ~= nil and RestartForm.RestartSwitch ~= nil then
      RestartForm.RestartSwitch.Enabled = false
    end
    if HK_SetFormEnabled ~= nil then
      HK_SetFormEnabled(PushToTalkForm, false)
      HK_SetFormEnabled(FPSForm, false)
    end
    return
  end
  for i = 1, #trainerCheckboxes do
    trainerCheckboxes[i].checkbox.Enabled = true
  end
  RefreshAllOptionToggles()
  RefreshRestartSwitch()
  if RefreshAllHotkeyUI ~= nil then RefreshAllHotkeyUI() end
end

-- ============================================================
-- Merged auto-attach + attach-state timer
-- ============================================================
local lastAttachState = nil
local autoAttachTimer = createTimer(nil)
autoAttachTimer.Interval = 1000
autoAttachTimer.OnTimer = function(timer)
  local targetPid = getProcessIDFromProcessName(PROCESS_NAME)
  if targetPid ~= nil then
    local currentPid = getOpenedProcessID()
    if currentPid == 0 or currentPid ~= targetPid then
      openProcess(PROCESS_NAME)
    end
  end
  local attached = IsGameRunning()
  if attached ~= lastAttachState then
    lastAttachState = attached
    RefreshTrainerCheckboxes()
  end
end

-- ============================================================
-- RP BOOSTER STATUS (GAME-OWNED POINTER)
-- ============================================================
-- This control is intentionally NOT registered with RegisterOptionToggle.
-- Its address is a game pointer which is invalid for a short time after
-- attach/startup, so the generic Value-based refresher must not touch it.
local RPBOOSTER_SCRIPT_ID = 1337122096
local RPBOOSTER_STATUS_ID = 1337121301
local rpBoosterStatusLink = nil
local rpBoosterStatusTimer = nil
local rpBoosterStatusInteracting = false

local function StopRPBoosterStatusTimer()
  if rpBoosterStatusTimer ~= nil then
    pcall(function()
      rpBoosterStatusTimer.Enabled = false
      rpBoosterStatusTimer.destroy()
    end)
    rpBoosterStatusTimer = nil
  end
end

local function ResetRPBoosterStatus()
  local combo = RPBoosterOptionsForm and RPBoosterOptionsForm.Status
  if combo == nil then return end
  combo.Enabled = false
  combo.ItemIndex = -1
  combo.Text = ""
end

local function ReadRPBoosterStatusValue()
  local mr = rpBoosterStatusLink
  if mr == nil then return nil end

  local ok, address, value = pcall(function()
    local a = mr.CurrentAddress
    if a == nil or a == 0 then return nil, nil end
    return a, readBytes(a, 1, false)
  end)

  if not ok or address == nil or address == 0 then return nil end
  if value ~= 0 and value ~= 1 then return nil end
  return value
end

local function RefreshRPBoosterStatus()
  local combo = RPBoosterOptionsForm and RPBoosterOptionsForm.Status
  local scriptMr = CE_GetRecord(RPBOOSTER_SCRIPT_ID)
  if combo == nil or scriptMr == nil then return end

  if scriptMr.Active ~= true then
    StopRPBoosterStatusTimer()
    ResetRPBoosterStatus()
    return
  end

  if RPBoosterOptionsForm.Visible ~= true then return end
  if rpBoosterStatusInteracting then return end

  local value = ReadRPBoosterStatusValue()
  if value == nil then
    combo.Enabled = false
    combo.ItemIndex = -1
    combo.Text = ""
    return
  end

  combo.Enabled = true
  local index = (value == 1) and 0 or 1
  if combo.ItemIndex ~= index then
    combo.ItemIndex = index
  end
end

local function StartRPBoosterStatusTimer()
  local combo = RPBoosterOptionsForm and RPBoosterOptionsForm.Status
  local scriptMr = CE_GetRecord(RPBOOSTER_SCRIPT_ID)
  local statusMr = rpBoosterStatusLink
  if combo == nil or scriptMr == nil or statusMr == nil then
    return
  end

  if scriptMr.Active ~= true or RPBoosterOptionsForm.Visible ~= true then
    StopRPBoosterStatusTimer()
    ResetRPBoosterStatus()
    return
  end

  RefreshRPBoosterStatus()

  if rpBoosterStatusTimer == nil then
    rpBoosterStatusTimer = createTimer(nil)
    rpBoosterStatusTimer.Interval = 200
    rpBoosterStatusTimer.OnTimer = function()
      if RPBoosterOptionsForm == nil or RPBoosterOptionsForm.Visible ~= true then
        StopRPBoosterStatusTimer()
        return
      end
      RefreshRPBoosterStatus()
    end
  end

  rpBoosterStatusTimer.Enabled = true
end

local function ApplyRPBoosterStatus(sender)
  local combo = RPBoosterOptionsForm and RPBoosterOptionsForm.Status
  local scriptMr = CE_GetRecord(RPBOOSTER_SCRIPT_ID)
  local statusMr = rpBoosterStatusLink
  if combo == nil or scriptMr == nil or statusMr == nil then return end

  if scriptMr.Active ~= true then
    ResetRPBoosterStatus()
    return
  end

  local value
  if sender.ItemIndex == 0 then
    value = 1
  elseif sender.ItemIndex == 1 then
    value = 0
  else
    RefreshRPBoosterStatus()
    return
  end

  pcall(function()
    statusMr.Value = tostring(value)
  end)
end

if RPBoosterOptionsForm ~= nil and RPBoosterOptionsForm.Status ~= nil then
  rpBoosterStatusLink = CE_GetRecord(RPBOOSTER_STATUS_ID)
  local statusCombo = RPBoosterOptionsForm.Status

  statusCombo.OnDropDown = function(sender)
    rpBoosterStatusInteracting = true
  end

  statusCombo.OnCloseUp = function(sender)
    rpBoosterStatusInteracting = false
    RefreshRPBoosterStatus()
  end

  statusCombo.OnChange = function(sender)
    ApplyRPBoosterStatus(sender)
  end

  ResetRPBoosterStatus()
end

-- ============================================================
-- MAIN TRAINER CHECKBOX HANDLERS
-- ============================================================
function TrainerForm_ChkCustomRPChange(sender)
  local mr = CE_GetRecord(1337121300)
  mr.Active = sender.Checked
end

function TrainerForm_chkCustomQuickChange(sender)
  local mr = CE_GetRecord(1337122096)
  mr.Active = sender.Checked
  RefreshOptionLinksForScript(mr, true)

  if sender.Checked then
    if RPBoosterOptionsForm ~= nil and RPBoosterOptionsForm.Visible == true then
      StartRPBoosterStatusTimer()
    else
      ResetRPBoosterStatus()
    end
  else
    StopRPBoosterStatusTimer()
    ResetRPBoosterStatus()
  end
end

function TrainerForm_chkRebalanceChange(sender)
  local mr = CE_GetRecord(1337167032)
  mr.Active = sender.Checked
  RefreshOptionLinksForScript(mr, true)
end

function TrainerForm_chkEraz3rChange(sender)
  local mr = CE_GetRecord(1337122681)
  mr.Active = sender.Checked
  RefreshOptionLinksForScript(mr, true)
  RefreshAllEraz3rLinks()
end

function TrainerForm_chkFSChange(sender)
  local mr = CE_GetRecord(1337122834)
  mr.Active = sender.Checked
end

function TrainerForm_chkCustomizationChange(sender)
  local mr = CE_GetRecord(1337167530)
  mr.Active = sender.Checked
  RefreshOptionLinksForScript(mr, true)
  local active = sender.Checked
  local btns = {
    "btnCustomizationPresetMenu", "btnCustomizationPresetMMSelect",
    "btnCustomizationPresetMMCustomize", "btnCustomizationPresetMap",
    "btnCustomizationPresetSVMain", "btnCustomizationPresetRS",
    "btnCustomizationPresetShop", "btnCustomizationPresetShopOpen",
    "btnCustomizationPresetPreset",
  }
  for i = 1, #btns do
    local b = CustomizationForm[btns[i]]
    if b ~= nil then b.Enabled = active end
  end
end

function TrainerForm_chkBGMChange(sender)
  local mr = CE_GetRecord(1337125896)
  mr.Active = sender.Checked
  RefreshOptionLinksForScript(mr, true)
end

function TrainerForm_chkMicChange(sender)
  local mr = CE_GetRecord(1337125883)
  mr.Active = sender.Checked
  RefreshOptionLinksForScript(mr, true)
  if RefreshAllHotkeyUI ~= nil then RefreshAllHotkeyUI() end
end

function TrainerForm_chk3pmChange(sender)
  local mr = CE_GetRecord(1337107913)
  mr.Active = sender.Checked
  RefreshOptionLinksForScript(mr, true)
end

function TrainerForm_chkPracticeChange(sender)
  local mr = CE_GetRecord(1337167441)
  mr.Active = sender.Checked
  RefreshOptionLinksForScript(mr, true)
end

function TrainerForm_chkFPSChange(sender)
  local mr = CE_GetRecord(1337145693)
  mr.Active = sender.Checked
  RefreshOptionLinksForScript(mr, true)
  if RefreshAllHotkeyUI ~= nil then RefreshAllHotkeyUI() end
end

function TrainerForm_chkRestartChange(sender)
  local mr = CE_GetRecord(1337145691)
  mr.Active = sender.Checked
  RefreshOptionLinksForScript(mr, true)
  RefreshRestartSwitch()
end

-- ============================================================
-- REGISTER MAIN TRAINER CHECKBOXES
-- ============================================================
RegisterTrainerCheckbox(TrainerForm.chkCustomRP, 1337121300)
RegisterTrainerCheckbox(TrainerForm.chkCustomQuick, 1337122096)
RegisterTrainerCheckbox(TrainerForm.chkRebalance, 1337167032)
RegisterTrainerCheckbox(TrainerForm.chkEraz3r, 1337122681)
RegisterTrainerCheckbox(TrainerForm.chkFS, 1337122834)
RegisterTrainerCheckbox(TrainerForm.chkCustomization, 1337167530)
RegisterTrainerCheckbox(TrainerForm.chkBGM, 1337125896)
RegisterTrainerCheckbox(TrainerForm.chkMic, 1337125883)
RegisterTrainerCheckbox(TrainerForm.chk3pm, 1337107913)
RegisterTrainerCheckbox(TrainerForm.chkPractice, 1337167441)
RegisterTrainerCheckbox(TrainerForm.chkFPS, 1337145693)
RegisterTrainerCheckbox(TrainerForm.chkRestart, 1337145691)

-- ============================================================
-- CLOSE TRAINER
-- ============================================================
function TrainerForm_FormClose(sender)
  if autoAttachTimer ~= nil then
    autoAttachTimer.destroy()
    autoAttachTimer = nil
  end
  StopRPBoosterStatusTimer()
  closeCE()
  return caHide
end

-- ============================================================
-- OPTIONS BUTTONS
-- ============================================================
function TrainerForm_RPBoosterStatusClick(sender)
  RPBoosterOptionsForm.Left = TrainerForm.Left + TrainerForm.Width + 10
  RPBoosterOptionsForm.Top = TrainerForm.Top
  RPBoosterOptionsForm.show()
end

function TrainerForm_RebalanceOptionsClick(sender)
  RebalanceOptionsForm.Left = TrainerForm.Left + TrainerForm.Width + 5
  RebalanceOptionsForm.Top = TrainerForm.Top + 90
  RebalanceOptionsForm.show()
end

function TrainerForm_btnEraz3rClick(sender)
  Eraz3rForm.Left = TrainerForm.Left + TrainerForm.Width + 5
  Eraz3rForm.Top = TrainerForm.Top
  Eraz3rForm.show()
end

function Eraz3rForm_btnEraz3rSharedACListClick(sender)
  DetectedList.Left = Eraz3rForm.Left + Eraz3rForm.Width + 5
  DetectedList.Top = Eraz3rForm.Top
  DetectedList.show()
end

function TrainerForm_btnCustomizationClick(sender)
  CustomizationForm.Left = TrainerForm.Left + TrainerForm.Width + 5
  CustomizationForm.Top = TrainerForm.Top
  CustomizationForm.show()
end

function TrainerForm_btnBGMClick(sender)
  BGMForm.Left = TrainerForm.Left + TrainerForm.Width + 5
  BGMForm.Top = TrainerForm.Top + 90
  BGMForm.show()
end

function TrainerForm_btnPushClick(sender)
  PushToTalkForm.Left = TrainerForm.Left + TrainerForm.Width + 5
  PushToTalkForm.Top = TrainerForm.Top + 180
  PushToTalkForm.show()
end

function TrainerForm_btn3pmClick(sender)
  TPMForm.Left = TrainerForm.Left + TrainerForm.Width + 5
  TPMForm.Top = TrainerForm.Top
  TPMForm.show()
end

function TrainerForm_btnPracticeClick(sender)
  PracticeForm.Left = TrainerForm.Left + TrainerForm.Width + 5
  PracticeForm.Top = TrainerForm.Top + 90
  PracticeForm.show()
end

function TrainerForm_btnFPSClick(sender)
  FPSForm.Left = TrainerForm.Left + TrainerForm.Width + 5
  FPSForm.Top = TrainerForm.Top + 180
  FPSForm.show()
end

function TrainerForm_btnRestartClick(sender)
  RestartForm.Left = TrainerForm.Left + TrainerForm.Width + 5
  RestartForm.Top = TrainerForm.Top + 270
  RestartForm.show()
end

-- Customization - Camera Presets
function CustomizationForm_btnCustomizationPresetMenuClick(sender)
  CustomizationCameraMainMenuForm.Left = CustomizationForm.Left + CustomizationForm.Width + 5
  CustomizationCameraMainMenuForm.Top = CustomizationForm.Top
  CustomizationCameraMainMenuForm.show()
end

function CustomizationForm_btnCustomizationPresetMMSelectClick(sender)
  CustomizationCameraMMSelectForm.Left = CustomizationForm.Left + CustomizationForm.Width + 5
  CustomizationCameraMMSelectForm.Top = CustomizationForm.Top
  CustomizationCameraMMSelectForm.show()
end

function CustomizationForm_btnCustomizationPresetMMCustomizeClick(sender)
  CustomizationCameraMMCustomizeForm.Left = CustomizationForm.Left + CustomizationForm.Width + 5
  CustomizationCameraMMCustomizeForm.Top = CustomizationForm.Top
  CustomizationCameraMMCustomizeForm.show()
end

function CustomizationForm_btnCustomizationPresetMapClick(sender)
  CustomizationCameraMapForm.Left = CustomizationForm.Left + CustomizationForm.Width + 5
  CustomizationCameraMapForm.Top = CustomizationForm.Top
  CustomizationCameraMapForm.show()
end

function CustomizationForm_btnCustomizationPresetSVMainClick(sender)
  CustomizationCameraSVMainForm.Left = CustomizationForm.Left + CustomizationForm.Width + 5
  CustomizationCameraSVMainForm.Top = CustomizationForm.Top
  CustomizationCameraSVMainForm.show()
end

function CustomizationForm_btnCustomizationPresetRSClick(sender)
  CustomizationCameraRSForm.Left = CustomizationForm.Left + CustomizationForm.Width + 5
  CustomizationCameraRSForm.Top = CustomizationForm.Top
  CustomizationCameraRSForm.show()
end

function CustomizationForm_btnCustomizationPresetShopClick(sender)
  CustomizationCameraShopForm.Left = CustomizationForm.Left + CustomizationForm.Width + 5
  CustomizationCameraShopForm.Top = CustomizationForm.Top
  CustomizationCameraShopForm.show()
end

function CustomizationForm_btnCustomizationPresetShopOpenClick(sender)
  CustomizationCameraShopOpenForm.Left = CustomizationForm.Left + CustomizationForm.Width + 5
  CustomizationCameraShopOpenForm.Top = CustomizationForm.Top
  CustomizationCameraShopOpenForm.show()
end

function CustomizationForm_btnCustomizationPresetPresetClick(sender)
  CustomizationCameraPresetForm.Left = CustomizationForm.Left + CustomizationForm.Width + 5
  CustomizationCameraPresetForm.Top = CustomizationForm.Top
  CustomizationCameraPresetForm.show()
end

-- ============================================================
-- MISC OPTION FORMS
-- ============================================================
TryWire(RegisterOptionToggle, TPMForm.CEComboBox1, 1337107912, 1337107913)

-- ============================================================
-- PRACTICE MODE (data-driven wiring)
-- ============================================================
local PRACTICE_SCRIPT = 1337167441

TryWire(RegisterOptionCheckbox, PracticeForm.chkPESVInfinite, 1337167457, PRACTICE_SCRIPT)
TryWire(RegisterOptionCheckbox, PracticeForm.chkWalkThroughWalls, 1337167459, PRACTICE_SCRIPT)

local practiceToggles = {
  {PracticeForm.PETimerFreeze, 1337167443},
  {PracticeForm.PEOvertimeMode, 1337167447},
  {PracticeForm.PEInfectionMode, 1337167451},
  {PracticeForm.PEInfectionChange, 1337167452},
  {PracticeForm.PESizeMode, 1337167453},
  {PracticeForm.PECharXMode, 1337167462},
  {PracticeForm.PECharYMode, 1337167467},
  {PracticeForm.PECharZMode, 1337167472},
  {PracticeForm.PEFOVMode, 1337167478},
  {PracticeForm.PECameraMode, 1337167481},
  {PracticeForm.PECameraXMode, 1337167483},
  {PracticeForm.PECameraYMode, 1337167488},
  {PracticeForm.PECameraZMode, 1337167493},
  {PracticeForm.PEHUDTimer, 1337167501},
  {PracticeForm.PEHUDCharIcons, 1337167502},
  {PracticeForm.PEHUDObjective, 1337167503},
  {PracticeForm.PEHUDPrompts, 1337167504},
  {PracticeForm.PEHUDSVHP, 1337167506},
  {PracticeForm.PEHUDSVSkills, 1337167507},
  {PracticeForm.PEHUDSVWeapon, 1337167508},
  {PracticeForm.PEHUDSVReticle, 1337167509},
  {PracticeForm.PEHUDMMBio, 1337167511},
  {PracticeForm.PEHUDMMDeck, 1337167512},
  {PracticeForm.PEHUDMMCameraInfo, 1337167513},
  {PracticeForm.PEHUDMMCameraEffect, 1337167514},
  {PracticeForm.PEHUDMMCameraEdges, 1337167515},
  {PracticeForm.PEHUDMMCreatureControl, 1337167516},
  {PracticeForm.PEHUDMMBOWControl, 1337167517},
  {PracticeForm.PEHUDMMEISPrompts, 1337167518},
  {PracticeForm.PEHUDMMEISInfo, 1337167519},
  {PracticeForm.PEHUDMMMap, 1337167520},
  {PracticeForm.PEHUDMMControls, 1337167521},
  {PracticeForm.PESwapVal, 1337167523},
  {PracticeForm.PESwapJan, 1337167524},
  {PracticeForm.PESwapTy, 1337167525},
  {PracticeForm.PESwapSam, 1337167526},
  {PracticeForm.PESwapAnnetteMode, 1337167528},
  {PracticeForm.PESwapAnnette, 1337167529},
}
for i = 1, #practiceToggles do
  local v = practiceToggles[i]
  TryWire(RegisterOptionToggle, v[1], v[2], PRACTICE_SCRIPT)
end

local practiceEdits = {
  {PracticeForm.PETimerChange, 1337167444, "float"},
  -- PETimerAddCount is registered specially below (deferred commit)
  {PracticeForm.PETimerAdd, 1337167446, "float"},
  {PracticeForm.PEOvertimeTimerChange, 1337167448, "float"},
  {PracticeForm.PESizeX, 1337167454, "float"},
  {PracticeForm.PESizeY, 1337167455, "float"},
  {PracticeForm.PESizeZ, 1337167456, "float"},
  {PracticeForm.PECharXChange, 1337167463, "float"},
  {PracticeForm.PECharXAdd, 1337167464, "float"},
  {PracticeForm.PECharXMul, 1337167465, "float"},
  {PracticeForm.PECharYChange, 1337167468, "float"},
  {PracticeForm.PECharYAdd, 1337167469, "float"},
  {PracticeForm.PECharYMul, 1337167470, "float"},
  {PracticeForm.PECharZChange, 1337167473, "float"},
  {PracticeForm.PECharZAdd, 1337167474, "float"},
  {PracticeForm.PECharZMul, 1337167475, "float"},
  {PracticeForm.PEFOVChange, 1337167479, "float"},
  {PracticeForm.PECameraXChange, 1337167484, "float"},
  {PracticeForm.PECameraXAdd, 1337167485, "float"},
  {PracticeForm.PECameraXMultiply, 1337167486, "float"},
  {PracticeForm.PECameraYChange, 1337167489, "float"},
  {PracticeForm.PECameraYAdd, 1337167490, "float"},
  {PracticeForm.PECameraYMultiply, 1337167491, "float"},
  {PracticeForm.PECameraZChange, 1337167494, "float"},
  {PracticeForm.PECameraZAdd, 1337167495, "float"},
  {PracticeForm.PECameraZMultiply, 1337167496, "float"},
}
for i = 1, #practiceEdits do
  local v = practiceEdits[i]
  TryWire(RegisterOptionEdit, v[1], v[2], PRACTICE_SCRIPT, v[3])
end

-- PETimerAddCount: deferred commit (write only on Exit / Enter).
-- The assembly script decrements this value every tick down to 0.
-- Immediate OnChange writes would fight the countdown and leave the
-- edit showing a stale typed value.
do
  local edit = PracticeForm.PETimerAddCount
  if edit ~= nil then
    local mr = CE_GetRecord(1337167445)
    local scriptMr = CE_GetRecord(PRACTICE_SCRIPT)
    if mr ~= nil and scriptMr ~= nil then
      local link = {
        edit = edit, record = mr, script = scriptMr,
        format = "integer",
        updating = false, editing = false, forceRefresh = false
      }
      OptionEditLinks[#OptionEditLinks+1] = link
      CE_IndexLinkByForm(CE_ResolveOwnerForm(edit), "edits", link)
      CE_IndexLinkByScript(scriptMr, "edits", link)

      local function commitTimerAddCount()
        if link.updating then return end
        if not link.script.Active then
          RefreshOptionEdit(link)
          return
        end
        local text = CE_Trim(tostring(edit.Text or ""))
        if text == "" then
          link.editing = false
          RefreshOptionEdit(link)
          return
        end
        local value = tonumber(text)
        if value ~= nil then
          value = math_floor(value + 0.5)
          pcall(function() link.record.Value = tostring(value) end)
        end
        link.editing = false
        RefreshOptionEdit(link)
      end

      edit.OnEnter = function(sender) link.editing = true end
      edit.OnExit = function(sender) commitTimerAddCount() end
      edit.OnKeyDown = function(sender, key)
        link.editing = true
        if key == 13 then  -- Enter
          commitTimerAddCount()
        end
      end
      edit.OnChange = function(sender)
        -- Intentionally do NOT write while typing.
        if link.updating then return end
        link.editing = true
      end
      RefreshOptionEdit(link)
    else
      print("PETimerAddCount: record/script not found")
    end
  end
end

-- Live read-only displays (already ReadOnly in the form designer)
-- Updated by the existing _TimerCoordSync.
local practiceAxisCache = {}
local practiceLiveLinks = {
  {PracticeForm.PEFOVDefault, 1337167477},
  {PracticeForm.PECameraAxisX, 1337167482},
  {PracticeForm.PECameraAxisY, 1337167487},
  {PracticeForm.PECameraAxisZ, 1337167492},
  {PracticeForm.PECharAxisX, 1337167461},
  {PracticeForm.PECharAxisY, 1337167466},
  {PracticeForm.PECharAxisZ, 1337167471},
}
for i = 1, #practiceLiveLinks do
  local entry = practiceLiveLinks[i]
  local ctrl = entry[1]
  local mr = CE_GetRecord(entry[2])
  if ctrl ~= nil and mr ~= nil then
    ctrl.OnChange = nil
    practiceAxisCache[#practiceAxisCache+1] = {ctrl = ctrl, mr = mr}
  else
    print("Practice live display wiring failed for ID " .. tostring(entry[2]))
  end
end

TryWire(RegisterMappedOptionCombo, PracticeForm.PEHUDMode, 1337167498, PRACTICE_SCRIPT, {
  ["Everything Visible"] = 0,
  ["Everything Hidden"] = 3,
  ["Modify through Options"] = 2,
  ["Only Options Hidden"] = 1
})

-- ============================================================
-- FPS
-- ============================================================
TryWire(RegisterOptionToggle, FPSForm.CEComboBox1, 1337145694, 1337145693)

if FPSForm.CEComboBox2 ~= nil then
  FPSForm.CEComboBox2.Items.Clear()
  FPSForm.CEComboBox2.Items.Add("30")
  FPSForm.CEComboBox2.Items.Add("45")
  FPSForm.CEComboBox2.Items.Add("60")
  FPSForm.CEComboBox2.Items.Add("120")
end

pcall(function()
  if FPSForm.CEComboBox2 ~= nil then
    FPSForm.CEComboBox2.Style = 0
    pcall(function() FPSForm.CEComboBox2.AutoComplete = false end)
    pcall(function() FPSForm.CEComboBox2.ReadOnly = false end)
  end
end)

TryWire(RegisterMappedOptionCombo, FPSForm.CEComboBox2, 1337145695, 1337145693, {
  ["30"] = 30, ["45"] = 45, ["60"] = 60, ["120"] = 120
})

-- ============================================================
-- RESTART
-- ============================================================
local RESTART_SCRIPT_ID = 1337145691
local RESTART_TRIGGER_ID = 1337145692

function RefreshRestartSwitch()
  if RestartForm == nil or RestartForm.RestartSwitch == nil then return end
  local scriptMr = CE_GetRecord(RESTART_SCRIPT_ID)
  local active = scriptMr ~= nil and scriptMr.Active == true
  RestartForm.RestartSwitch.Enabled = active
end

if RestartForm ~= nil and RestartForm.RestartSwitch ~= nil then
  RestartForm.RestartSwitch.OnClick = function(sender)
    local scriptMr = CE_GetRecord(RESTART_SCRIPT_ID)
    if scriptMr == nil or not scriptMr.Active then return end
    local mr = CE_GetRecord(RESTART_TRIGGER_ID)
    if mr ~= nil then pcall(function() mr.Value = "1" end) end
  end
  RefreshRestartSwitch()
end

-- ============================================================
-- CUSTOMIZATION
-- ============================================================
local CUSTOMIZATION_SCRIPT = 1337167530

local customizationComboMap = {
  {"CustomizeBottomButton", 1337167532}, {"CustomizeBottomButtonBorder", 1337157612}, {"CustomizeLeftBlackBorder", 1337167531},
  {"CustomizeFOVMainMode", 1337167535}, {"CustomizeFOVSVMode", 1337167537},
  {"CustomizeCamMainPreset", 1337167540}, {"CustomizeCamMainDOF", 1337167742},
  {"CustomizeCamMMSelectPreset", 1337167744}, {"CustomizeCamMMSelectDOF", 1337167802},
  {"CustomizeCamMMCustomizePreset", 1337167804}, {"CustomizeCamMMCustomizeDOF", 1337167862},
  {"CustomizeCamMapPreset", 1337167864}, {"CustomizeCamMapDOF", 1337167922},
  {"CustomizeCamSVMainPreset", 1337168187}, {"CustomizeCamSVMainDOF", 1337168188},
  {"CustomizeCamSVSkinsPreset", 1337168189}, {"CustomizeCamSVSkinsDOF", 1337168190},
  {"CustomizeCamSVSkillPreset", 1337168191}, {"CustomizeCamSVSkillDOF", 1337168192},
  {"CustomizeCamSVSpraysPreset", 1337168193}, {"CustomizeCamSVSpraysDOF", 1337168194},
  {"CustomizeCamSVWeaponSkinsPreset", 1337168195}, {"CustomizeCamSVWeaponSkinsDOF", 1337168196},
  {"CustomizeCamLoadingPreset", 1337168184}, {"CustomizeCamRSPreset", 1337167924}, {"CustomizeCamRSDOF", 1337168004},
  {"CustomizeCamShopPreset", 1337168007}, {"CustomizeCamShopDOF", 1337168064},
  {"CustomizeCamShopOpenPreset", 1337168066}, {"CustomizeCamShopOpenDOF", 1337168123},
  {"CustomizeCamPresetPreset", 1337168125}, {"CustomizeCamPresetDOF", 1337168182},
  {"CustomizeQMode", 1337168967}, {"CustomizeQAdditional", 1337168968}, {"CustomizeQFrame", 1337157616},
  {"CustomizeQTeamPlayMode", 1337168969}, {"CustomizeQTeamPlayChosen", 1337168970},
  {"CustomizeQCameraPreset", 1337168972}, {"CustomizeQDoF", 1337168971},
  {"CustomizeSVLobbyUIMainBorder", 1337168662}, {"CustomizeSVLobbyUICustomizeMain", 1337168663},
  {"CustomizeSVLobbyUICustomizeBorder", 1337157609}, {"CustomizeSVLobbyUICustomizeSelect", 1337157613},
  {"CustomizeSVLobbyUIEquipmentMain", 1337168664}, {"CustomizeSVLobbyUIEquipmentBorder", 1337157610},
  {"CustomizeSVLobbyUIEquipmentSelect", 1337157614}, {"CustomizeSVLobbyUICosmeticsMain", 1337168665},
  {"CustomizeSVLobbyUICosmeticsBorder", 1337157611}, {"CustomizeSVLobbyUICosmeticsSelect", 1337157615},
  {"CustomizeSVDarkModeAssets", 1337168667}, {"CustomizeSVDarkModeLightning", 1337168668},
  {"CustomizeSVDarkModeOverlapFix", 1337168669}, {"CustomizeSVDarkModeOverlapAdjustment", 1337168670},
  {"CustomizeSVCoordinatesModeSwitch", 1337168716},
  {"CustomizeSVSlot1ModeSwitch", 1337168718}, {"CustomizeSVSlot1PositionSwitch", 1337168719},
  {"CustomizeSVSlot2ModeSwitch", 1337168729}, {"CustomizeSVSlot2PositionSwitch", 1337168730},
  {"CustomizeSVSlot3ModeSwitch", 1337168740}, {"CustomizeSVSlot3PositionSwitch", 1337168741},
  {"CustomizeSVSlot4ModeSwitch", 1337168751}, {"CustomizeSVSlot4PositionSwitch", 1337168752},
  {"CustomizeSVAssetMain", 1337168672}, {"CustomizeSVAssetBoxVisibility", 1337168674},
  {"CustomizeSVAssetBoxMode", 1337168675}, {"CustomizeSVAssetAlternateBoxVisibility", 1337168684},
  {"CustomizeSVAssetAlternateBoxMode", 1337168685}, {"CustomizeSVAssetBBVisibility", 1337168697},
  {"CustomizeSVBBMode", 1337168698}, {"CustomizeSVAssetSBVisibility", 1337168706},
  {"CustomizeSVSBMode", 1337168707}, {"CustomizeSVAssetSBSizeZ", 1337168711},
  {"CustomizeSVAssetLW1", 1337168694}, {"CustomizeSVAssetLW2", 1337168695},
}
for i = 1, #customizationComboMap do
  local mapping = customizationComboMap[i]
  TryWire(RegisterOptionToggle, CustomizationForm[mapping[1]], mapping[2], CUSTOMIZATION_SCRIPT)
end

TryWire(RegisterOptionToggle, CustomizationForm.CustomizeSVPoseModeSwitch, 1337168762, CUSTOMIZATION_SCRIPT)

-- Share-with-main combos
TryWire(RegisterOptionToggle, CustomizationForm.CustomizationCamMMSelectMenu, 1337167745, CUSTOMIZATION_SCRIPT)
TryWire(RegisterOptionToggle, CustomizationForm.CustomizationCamMMCustomizeMenu, 1337167805, CUSTOMIZATION_SCRIPT)
TryWire(RegisterOptionToggle, CustomizationForm.CustomizationCamMapMenu, 1337167865, CUSTOMIZATION_SCRIPT)
TryWire(RegisterOptionToggle, CustomizationForm.CameraTransitionMode, 1337168974, CUSTOMIZATION_SCRIPT)

-- Emote Mode 1
local customizationEmote1 = {
  {"S1", 1337145696, 1337145697, 1337168765, 1337168766},
  {"S2", 1337168768, 1337168769, 1337168770, 1337168771},
  {"S3", 1337168773, 1337168774, 1337168775, 1337168776},
  {"S4", 1337168778, 1337168779, 1337168780, 1337168781},
}
for i = 1, #customizationEmote1 do
  local m = customizationEmote1[i]
  local pre = "CustomizeSVEmote1" .. m[1]
  TryWire(RegisterOptionToggle, CustomizationForm[pre .. "Mode"], m[2], CUSTOMIZATION_SCRIPT)
  TryWire(RegisterOptionToggle, CustomizationForm[pre .. "TPose"], m[3], CUSTOMIZATION_SCRIPT)
  TryWire(RegisterOptionToggle, CustomizationForm[pre .. "Pose"], m[4], CUSTOMIZATION_SCRIPT)
  TryWire(RegisterOptionToggle, CustomizationForm[pre .. "Emote"], m[5], CUSTOMIZATION_SCRIPT)
end

-- Emote Mode 2
local customizationEmote2 = {
  {"Val", 1337168784, 1337168785, 1337168786, 1337168787},
  {"Jan", 1337168789, 1337168790, 1337168791, 1337168792},
  {"Ty", 1337168799, 1337168800, 1337168801, 1337168802},
  {"Sam", 1337168794, 1337168795, 1337168796, 1337168797},
  {"Martin", 1337168804, 1337168805, 1337168806, 1337168807},
  {"Becca", 1337168809, 1337168810, 1337168811, 1337168812},
  {"Jill", 1337168814, 1337168815, 1337168816, 1337168817},
}
for i = 1, #customizationEmote2 do
  local m = customizationEmote2[i]
  local pre = "CustomizeSVEmote2" .. m[1]
  TryWire(RegisterOptionToggle, CustomizationForm[pre .. "Mode"], m[2], CUSTOMIZATION_SCRIPT)
  TryWire(RegisterOptionToggle, CustomizationForm[pre .. "TPose"], m[3], CUSTOMIZATION_SCRIPT)
  TryWire(RegisterOptionToggle, CustomizationForm[pre .. "Pose"], m[4], CUSTOMIZATION_SCRIPT)
  TryWire(RegisterOptionToggle, CustomizationForm[pre .. "Emote"], m[5], CUSTOMIZATION_SCRIPT)
end

-- Emote Mode 3
local customizationEmote3 = {
  {"Val", {1337168821, 1337168826, 1337168831, 1337168836}},
  {"Jan", {1337168842, 1337168847, 1337168852, 1337168857}},
  {"Ty", {1337168863, 1337168868, 1337168873, 1337168878}},
  {"Sam", {1337168884, 1337168889, 1337168894, 1337168899}},
  {"Martin", {1337168905, 1337168910, 1337168915, 1337168920}},
  {"Becca", {1337168926, 1337168931, 1337168936, 1337168941}},
  {"Jill", {1337168947, 1337168952, 1337168957, 1337168962}},
}
for i = 1, #customizationEmote3 do
  local character = customizationEmote3[i]
  for slot = 1, 4 do
    local first = character[2][slot]
    local prefix = "CustomizeSVEmote3" .. character[1] .. tostring(slot)
    TryWire(RegisterOptionToggle, CustomizationForm[prefix .. "Mode"], first, CUSTOMIZATION_SCRIPT)
    TryWire(RegisterOptionToggle, CustomizationForm[prefix .. "TPose"], first + 1, CUSTOMIZATION_SCRIPT)
    local poseControl = CustomizationForm[prefix .. "Pose"]
    if character[1] == "Becca" and slot == 1 then
      poseControl = CustomizationForm.CustomizeSVEmote1Becca1Pose
    end
    TryWire(RegisterOptionToggle, poseControl, first + 2, CUSTOMIZATION_SCRIPT)
    TryWire(RegisterOptionToggle, CustomizationForm[prefix .. "Emote"], first + 3, CUSTOMIZATION_SCRIPT)
  end
end

-- ============================================================
-- CUSTOMIZATION EDITABLE COMBOBOXES
-- ============================================================
local customizationEditableComboMap = {
  {"CustomizeSVSlot1Rotation", 1337168721}, {"CustomizeSVSlot1XChange", 1337168722},
  {"CustomizeSVSlot1YChange", 1337168724}, {"CustomizeSVSlot1ZChange", 1337168726},
  {"CustomizeSVSlot2Rotation", 1337168732}, {"CustomizeSVSlot2XChange", 1337168733},
  {"CustomizeSVSlot2YChange", 1337168735}, {"CustomizeSVSlot2ZChange", 1337168737},
  {"CustomizeSVSlot3Rotation", 1337168743}, {"CustomizeSVSlot3XChange", 1337168744},
  {"CustomizeSVSlot3YChange", 1337168746}, {"CustomizeSVSlot3ZChange", 1337168748},
  {"CustomizeSVSlot4Rotation", 1337168754}, {"CustomizeSVSlot4XChange", 1337168755},
  {"CustomizeSVSlot4YChange", 1337168757}, {"CustomizeSVSlot4ZChange", 1337168759},
  {"CustomizeSVAssetBoxSizeX", 1337168677}, {"CustomizeSVAssetBoxSizeY", 1337168678}, {"CustomizeSVAssetBoxSizeZ", 1337168679},
  {"CustomizeSVAssetBoxCoorX", 1337168680}, {"CustomizeSVAssetBoxCoorY", 1337168681}, {"CustomizeSVAssetBoxCoorZ", 1337168682},
  {"CustomizeSVAssetAlternateBoxSizeX", 1337168687}, {"CustomizeSVAssetAlternateBoxSizeY", 1337168688}, {"CustomizeSVAssetAlternateBoxSizeZ", 1337168689},
  {"CustomizeSVAssetAlternateBoxCoorX", 1337168690}, {"CustomizeSVAssetAlternateBoxCoorY", 1337168691}, {"CustomizeSVAssetAlternateBoxCoorZ", 1337168692},
  {"CustomizeSVAssetBBSizeX", 1337168700}, {"CustomizeSVAssetBBSizeY", 1337168701}, {"CustomizeSVAssetBBSizeZ", 1337168702},
  {"CustomizeSVAssetBBCoorX", 1337168703}, {"CustomizeSVAssetBBCoorY", 1337168704}, {"CustomizeSVAssetBBCoorZ", 1337168705},
  {"CustomizeSVAssetSBSizeX", 1337168709}, {"CustomizeSVAssetSBSizeY", 1337168710},
  {"CustomizeSVAssetSBCoorX", 1337168712}, {"CustomizeSVAssetSBCoorY", 1337168713}, {"CustomizeSVAssetSBCoorZ", 1337168714},
}
for i = 1, #customizationEditableComboMap do
  local mapping = customizationEditableComboMap[i]
  TryWire(RegisterOptionToggle, CustomizationForm[mapping[1]], mapping[2], CUSTOMIZATION_SCRIPT)
end

-- ============================================================
-- CUSTOMIZATION EDITS
-- ============================================================
local customizationEditMap = {
  {"CustomizeFOVMainChange", 1337167536, "float"}, {"CustomizeFOVSVChange", 1337167538, "float"}, {"CustomizeCamLoadingInstant", 1337168185, "integer"},
}
for i = 1, #customizationEditMap do
  local mapping = customizationEditMap[i]
  TryWire(RegisterOptionEdit, CustomizationForm[mapping[1]], mapping[2], CUSTOMIZATION_SCRIPT, mapping[3])
end

-- ============================================================
-- CUSTOMIZATION CAMERA PRESETS (lazy wire on first open)
-- ============================================================
local function WireCameraPreset(form, startEdit, recordIDs)
  if form == nil then return end
  for i = 1, 10 do
    local edit = form["CEEdit" .. (startEdit + i - 1)]
    if edit ~= nil and recordIDs[i] ~= nil then
      TryWire(RegisterOptionEdit, edit, recordIDs[i], CUSTOMIZATION_SCRIPT, "float")
    end
  end
end

local CameraPresetSpecs = {
  [CustomizationCameraMainMenuForm] = {
    {1, {1337167590,1337167591,1337167592,1337167593,1337167594,1337167595,1337167596,1337167597,1337167598,1337167599}},
    {21, {1337167601,1337167602,1337167603,1337167604,1337167605,1337167606,1337167607,1337167608,1337167609,1337167610}},
    {31, {1337167612,1337167613,1337167614,1337167615,1337167616,1337167617,1337167618,1337167619,1337167620,1337167621}},
    {41, {1337167623,1337167624,1337157698,1337167625,1337167626,1337167627,1337167628,1337167629,1337167630,1337167631}},
    {51, {1337157702,1337157701,1337157700,1337157703,1337157704,1337157705,1337157706,1337157707,1337157708,1337157709}},
    {61, {1337167633,1337167634,1337167635,1337167636,1337167637,1337167638,1337167639,1337167640,1337167641,1337167642}},
    {71, {1337167644,1337167645,1337167646,1337167647,1337167648,1337167649,1337167650,1337167651,1337167652,1337167653}},
    {81, {1337167655,1337167656,1337167657,1337167658,1337167659,1337167660,1337167661,1337167662,1337167663,1337167664}},
    {91, {1337167666,1337167667,1337167668,1337167669,1337167670,1337167671,1337167672,1337167673,1337167674,1337167675}},
    {101, {1337167677,1337167678,1337167679,1337167680,1337167681,1337167682,1337167683,1337167684,1337167685,1337167686}},
    {111, {1337167688,1337167689,1337167690,1337167691,1337167692,1337167693,1337167694,1337167695,1337167696,1337167697}},
    {121, {1337167699,1337167700,1337167701,1337167702,1337167703,1337167704,1337167705,1337167706,1337167707,1337167708}},
    {131, {1337167710,1337167711,1337167712,1337167713,1337167714,1337167715,1337167716,1337167717,1337167718,1337167719}},
    {141, {1337167721,1337167722,1337167723,1337167724,1337167725,1337167726,1337167727,1337167728,1337167729,1337167730}},
    {151, {1337167732,1337167733,1337167734,1337167735,1337167736,1337167737,1337167738,1337167739,1337167740,1337167741}},
    {161, {1337167545,1337167546,1337157672,1337167547,1337167548,1337167549,1337167550,1337167551,1337167552,1337167553}},
    {171, {1337167555,1337167556,1337167557,1337167558,1337167559,1337167560,1337167561,1337167562,1337167563,1337167564}},
    {181, {1337157676,1337157675,1337157711,1337157677,1337157678,1337157679,1337157680,1337157681,1337157682,1337157683}},
    {191, {1337157687,1337157686,1337157696,1337157710,1337157689,1337157690,1337157691,1337157692,1337157693,1337157694}},
    {201, {1337167567,1337167568,1337167569,1337167570,1337167571,1337167572,1337167573,1337167574,1337167575,1337167576}},
    {211, {1337167578,1337167579,1337167580,1337167581,1337167582,1337167583,1337167584,1337167585,1337167586,1337167587}},
  },
  [CustomizationCameraMMSelectForm] = {
    {201, {1337167748,1337167749,1337167750,1337167751,1337167752,1337167753,1337167754,1337167755,1337167756,1337167757}},
    {211, {1337167759,1337167760,1337167761,1337167762,1337167763,1337167764,1337167765,1337167766,1337167767,1337167768}},
    {221, {1337167770,1337167771,1337167772,1337167773,1337167774,1337167775,1337167776,1337167777,1337167778,1337167779}},
    {231, {1337167781,1337167782,1337167783,1337167784,1337167785,1337167786,1337167787,1337167788,1337167789,1337167790}},
    {241, {1337167792,1337167793,1337167794,1337167795,1337167796,1337167797,1337167798,1337167799,1337167800,1337167801}},
  },
  [CustomizationCameraMMCustomizeForm] = {
    {201, {1337167808,1337167809,1337167810,1337167811,1337167812,1337167813,1337167814,1337167815,1337167816,1337167817}},
    {211, {1337167819,1337167820,1337167821,1337167822,1337167823,1337167824,1337167825,1337167826,1337167827,1337167828}},
    {221, {1337167830,1337167831,1337167832,1337167833,1337167834,1337167835,1337167836,1337167837,1337167838,1337167839}},
    {231, {1337167841,1337167842,1337167843,1337167844,1337167845,1337167846,1337167847,1337167848,1337167849,1337167850}},
    {241, {1337167852,1337167853,1337167854,1337167855,1337167856,1337167857,1337167858,1337167859,1337167860,1337167861}},
  },
  [CustomizationCameraMapForm] = {
    {201, {1337167868,1337167869,1337167870,1337167871,1337167872,1337167873,1337167874,1337167875,1337167876,1337167877}},
    {211, {1337167879,1337167880,1337167881,1337167882,1337167883,1337167884,1337167885,1337167886,1337167887,1337167888}},
    {221, {1337167890,1337167891,1337167892,1337167893,1337167894,1337167895,1337167896,1337167897,1337167898,1337167899}},
    {231, {1337167901,1337167902,1337167903,1337167904,1337167905,1337167906,1337167907,1337167908,1337167909,1337167910}},
    {241, {1337167912,1337167913,1337167914,1337167915,1337167916,1337167917,1337167918,1337167919,1337167920,1337167921}},
  },
  [CustomizationCameraRSForm] = {
    {201, {1337167927,1337167928,1337167929,1337167930,1337167931,1337167932,1337167933,1337167934,1337167935,1337167936}},
    {211, {1337167938,1337167939,1337167940,1337167941,1337167942,1337167943,1337167944,1337167945,1337167946,1337167947}},
    {221, {1337167949,1337167950,1337167951,1337167952,1337167953,1337167954,1337167955,1337167956,1337167957,1337167958}},
    {231, {1337167961,1337167962,1337167963,1337167964,1337167965,1337167966,1337167967,1337167968,1337167969,1337167970}},
    {241, {1337167972,1337167973,1337167974,1337167975,1337167976,1337167977,1337167978,1337167979,1337167980,1337167981}},
    {251, {1337167983,1337167984,1337167985,1337167986,1337167987,1337167988,1337167989,1337167990,1337167991,1337167992}},
    {261, {1337167994,1337167995,1337167996,1337167997,1337167998,1337167999,1337168000,1337168001,1337168002,1337168003}},
  },
  [CustomizationCameraShopForm] = {
    {201, {1337168010,1337168011,1337168012,1337168013,1337168014,1337168015,1337168016,1337168017,1337168018,1337168019}},
    {211, {1337168021,1337168022,1337168023,1337168024,1337168025,1337168026,1337168027,1337168028,1337168029,1337168030}},
    {221, {1337168032,1337168033,1337168034,1337168035,1337168036,1337168037,1337168038,1337168039,1337168040,1337168041}},
    {231, {1337168043,1337168044,1337168045,1337168046,1337168047,1337168048,1337168049,1337168050,1337168051,1337168052}},
    {241, {1337168054,1337168055,1337168056,1337168057,1337168058,1337168059,1337168060,1337168061,1337168062,1337168063}},
  },
  [CustomizationCameraShopOpenForm] = {
    {201, {1337168069,1337168070,1337168071,1337168072,1337168073,1337168074,1337168075,1337168076,1337168077,1337168078}},
    {211, {1337168080,1337168081,1337168082,1337168083,1337168084,1337168085,1337168086,1337168087,1337168088,1337168089}},
    {221, {1337168091,1337168092,1337168093,1337168094,1337168095,1337168096,1337168097,1337168098,1337168099,1337168100}},
    {231, {1337168102,1337168103,1337168104,1337168105,1337168106,1337168107,1337168108,1337168109,1337168110,1337168111}},
    {241, {1337168113,1337168114,1337168115,1337168116,1337168117,1337168118,1337168119,1337168120,1337168121,1337168122}},
  },
  [CustomizationCameraPresetForm] = {
    {201, {1337168128,1337168129,1337168130,1337168131,1337168132,1337168133,1337168134,1337168135,1337168136,1337168137}},
    {211, {1337168139,1337168140,1337168141,1337168142,1337168143,1337168144,1337168145,1337168146,1337168147,1337168148}},
    {221, {1337168150,1337168151,1337168152,1337168153,1337168154,1337168155,1337168156,1337168157,1337168158,1337168159}},
    {231, {1337168161,1337168162,1337168163,1337168164,1337168165,1337168166,1337168167,1337168168,1337168169,1337168170}},
    {241, {1337168172,1337168173,1337168174,1337168175,1337168176,1337168177,1337168178,1337168179,1337168180,1337168181}},
  },
  [CustomizationCameraSVMainForm] = {
    {1, {1337157659,1337168199,1337168200,1337168201,1337168202,1337168203,1337168204,1337168205,1337168206,1337168207}},
    {21, {1337157671,1337168210,1337168211,1337168212,1337168213,1337168214,1337168215,1337168216,1337168217,1337168218}},
    {31, {1337168220,1337168221,1337168222,1337168223,1337168224,1337168225,1337168226,1337168227,1337168228,1337168229}},
    {41, {1337168231,1337168232,1337168233,1337168234,1337168235,1337168236,1337168237,1337168238,1337168239,1337168240}},
    {51, {1337168242,1337168243,1337168244,1337168245,1337168246,1337168247,1337168248,1337168249,1337168250,1337168251}},
    {61, {1337168253,1337168254,1337168255,1337168256,1337168257,1337168258,1337168259,1337168260,1337168261,1337168262}},
    {71, {1337168264,1337168265,1337168266,1337168267,1337168268,1337168269,1337168270,1337168271,1337168272,1337168273}},
    {81, {1337168275,1337168276,1337168277,1337168278,1337168279,1337168280,1337168281,1337168282,1337168283,1337168284}},
    {91, {1337168286,1337168287,1337168288,1337168289,1337168290,1337168291,1337168292,1337168293,1337168294,1337168295}},
    {101, {1337168297,1337168298,1337168299,1337168300,1337168301,1337168302,1337168303,1337168304,1337168305,1337168306}},
    {111, {1337168308,1337168309,1337168310,1337168311,1337168312,1337168313,1337168314,1337168315,1337168316,1337168317}},
    {121, {1337168319,1337168320,1337168321,1337168322,1337168323,1337168324,1337168325,1337168326,1337168327,1337168328}},
    {131, {1337168330,1337168331,1337168332,1337168333,1337168334,1337168335,1337168336,1337168337,1337168338,1337168339}},
    {141, {1337168341,1337168342,1337168343,1337168344,1337168345,1337168346,1337168347,1337168348,1337168349,1337168350}},
    {151, {1337168352,1337168353,1337168354,1337168355,1337168356,1337168357,1337168358,1337168359,1337168360,1337168361}},
    {221, {1337168363,1337168364,1337168365,1337168366,1337168367,1337168368,1337168369,1337168370,1337168371,1337168372}},
    {11, {1337168374,1337168375,1337168376,1337168377,1337168378,1337168379,1337168380,1337168381,1337168382,1337168383}},
    {231, {1337168385,1337168386,1337168387,1337168388,1337168389,1337168390,1337168391,1337168392,1337168393,1337168394}},
    {241, {1337168396,1337168397,1337168398,1337168399,1337168400,1337168401,1337168402,1337168403,1337168404,1337168405}},
    {251, {1337168407,1337168408,1337168409,1337168410,1337168411,1337168412,1337168413,1337168414,1337168415,1337168416}},
    {261, {1337168418,1337168419,1337168420,1337168421,1337168422,1337168423,1337168424,1337168425,1337168426,1337168427}},
    {271, {1337168429,1337168430,1337168431,1337168432,1337168433,1337168434,1337168435,1337168436,1337168437,1337168438}},
    {281, {1337168440,1337168441,1337168442,1337168443,1337168444,1337168445,1337168446,1337168447,1337168448,1337168449}},
    {291, {1337168451,1337168452,1337168453,1337168454,1337168455,1337168456,1337168457,1337168458,1337168459,1337168460}},
    {301, {1337168462,1337168463,1337168464,1337168465,1337168466,1337168467,1337168468,1337168469,1337168470,1337168471}},
    {311, {1337168473,1337168474,1337168475,1337168476,1337168477,1337168478,1337168479,1337168480,1337168481,1337168482}},
    {321, {1337168484,1337168485,1337168486,1337168487,1337168488,1337168489,1337168490,1337168491,1337168492,1337168493}},
    {331, {1337168495,1337168496,1337168497,1337168498,1337168499,1337168500,1337168501,1337168502,1337168503,1337168504}},
    {341, {1337168506,1337168507,1337168508,1337168509,1337168510,1337168511,1337168512,1337168513,1337168514,1337168515}},
    {351, {1337157695,1337157662,1337157663,1337157664,1337157665,1337157666,1337157667,1337157668,1337157669,1337157670}},
    {161, {1337157658,1337168520,1337168521,1337168522,1337168523,1337168524,1337168525,1337168526,1337168527,1337168528}},
    {171, {1337168530,1337168531,1337168532,1337168533,1337168534,1337168535,1337168536,1337168537,1337168538,1337168539}},
    {181, {1337168541,1337168542,1337168543,1337168544,1337168545,1337168546,1337168547,1337168548,1337168549,1337168550}},
    {191, {1337168552,1337168553,1337168554,1337168555,1337168556,1337168557,1337168558,1337168559,1337168560,1337168561}},
    {211, {1337168563,1337168564,1337168565,1337168566,1337168567,1337168568,1337168569,1337168570,1337168571,1337168572}},
    {361, {1337168574,1337168575,1337168576,1337168577,1337168578,1337168579,1337168580,1337168581,1337168582,1337168583}},
    {371, {1337168585,1337168586,1337168587,1337168588,1337168589,1337168590,1337168591,1337168592,1337168593,1337168594}},
    {381, {1337168596,1337168597,1337168598,1337168599,1337168600,1337168601,1337168602,1337168603,1337168604,1337168605}},
    {391, {1337168607,1337168608,1337168609,1337168610,1337168611,1337168612,1337168613,1337168614,1337168615,1337168616}},
    {401, {1337168618,1337168619,1337168620,1337168621,1337168622,1337168623,1337168624,1337168625,1337168626,1337168627}},
    {411, {1337168629,1337168630,1337168631,1337168632,1337168633,1337168634,1337168635,1337168636,1337168637,1337168638}},
    {421, {1337157645,1337168640,1337168641,1337168642,1337168643,1337168644,1337168645,1337168646,1337168647,1337168648}},
    {431, {1337157635,1337157636,1337157637,1337157638,1337157639,1337157640,1337157641,1337157642,1337157643,1337157644}},
    {441, {1337157657,1337157648,1337157649,1337157650,1337157651,1337157652,1337157653,1337157654,1337157655,1337157656}},
    {201, {1337168650,1337168651,1337168652,1337168653,1337168654,1337168655,1337168656,1337168657,1337168658,1337168659}},
  },
}

local CameraExtraSpecs = {
  [CustomizationCameraMainMenuForm] = {
    {"toggle", CustomizationCameraMainMenuForm.CustomizationCameraMainMenuDynamicPreset, 1337167542},
    {"toggle", CustomizationCameraMainMenuForm.CustomizationCameraMainMenuAdditionPreset, 1337168973},
    {"edit", CustomizationCameraMainMenuForm.CustomizationCameraMainMenuDynamicCycle, 1337167543, "integer"},
  },
  [CustomizationCameraSVMainForm] = {
    {"toggle", CustomizationCameraSVMainForm.CustomizationCameraSVDynamicPreset, 1337168516},
    {"toggle", CustomizationCameraSVMainForm.CustomizationCameraSVAdditionPreset, 1337168516},
    {"edit", CustomizationCameraSVMainForm.CustomizationCameraMainMenuDynamicCycle, 1337168518, "integer"},
  },
}

local cameraFormsWired = {}

local function PairLinkedPresetCombos(comboA, comboB)
  if comboA == nil or comboB == nil then return end
  local function findLink(combo)
    return ComboToLink[combo]
  end
  local function syncFromTo(src, dst)
    if src == nil or dst == nil then return end
    local dstLink = findLink(dst)
    if dstLink ~= nil and dstLink.updating then return end
    if dstLink ~= nil then dstLink.updating = true end
    pcall(function()
      local idx = src.ItemIndex
      if idx ~= nil and idx &gt;= 0 then
        if dst.ItemIndex ~= idx then dst.ItemIndex = idx end
      else
        local text = tostring(src.Text or "")
        if dst.ItemIndex ~= -1 or tostring(dst.Text or "") ~= text then
          dst.ItemIndex = -1
          dst.Text = text
        end
      end
    end)
    if dstLink ~= nil then dstLink.updating = false end
  end
  local prevA = comboA.OnChange
  comboA.OnChange = function(sender)
    if prevA ~= nil then pcall(prevA, sender) end
    syncFromTo(comboA, comboB)
  end
  local prevB = comboB.OnChange
  comboB.OnChange = function(sender)
    if prevB ~= nil then pcall(prevB, sender) end
    syncFromTo(comboB, comboA)
  end
end

local function EnsureCameraFormWired(form)
  if form == nil or cameraFormsWired[form] then return end
  cameraFormsWired[form] = true
  local presets = CameraPresetSpecs[form]
  if presets ~= nil then
    for i = 1, #presets do
      local spec = presets[i]
      WireCameraPreset(form, spec[1], spec[2])
    end
  end
  local extras = CameraExtraSpecs[form]
  if extras ~= nil then
    for i = 1, #extras do
      local spec = extras[i]
      if spec[1] == "toggle" then
        TryWire(RegisterOptionToggle, spec[2], spec[3], CUSTOMIZATION_SCRIPT)
      else
        TryWire(RegisterOptionEdit, spec[2], spec[3], CUSTOMIZATION_SCRIPT, spec[4])
      end
    end
  end
  if form == CustomizationCameraMainMenuForm or form == CustomizationCameraSVMainForm then
    PairLinkedPresetCombos(form.CustomizationCameraSVDynamicPreset, form.CustomizationCameraSVAdditionPreset)
  end
end

-- ============================================================
-- SYNC OPTION FORMS WHEN OPENED
-- ============================================================
local miscOptionForms = {
  TPMForm, PracticeForm, FPSForm, RestartForm, CustomizationForm,
  CustomizationCameraMainMenuForm, CustomizationCameraMMSelectForm,
  CustomizationCameraMMCustomizeForm, CustomizationCameraMapForm,
  CustomizationCameraSVMainForm, CustomizationCameraRSForm,
  CustomizationCameraShopForm, CustomizationCameraShopOpenForm,
  CustomizationCameraPresetForm
}

local function RefreshFormOptionControls(form)
  if form == nil then return end
  local bucket = OptionLinksByForm[form]
  if bucket == nil then
    for i = 1, #OptionToggleLinks do
      local link = OptionToggleLinks[i]
      if link.form == form or (link.combo and CE_ResolveOwnerForm(link.combo) == form) then
        pcall(RefreshOptionToggle, link, true)
      end
    end
    for i = 1, #OptionEditLinks do
      local link = OptionEditLinks[i]
      if link.form == form or (link.edit and CE_ResolveOwnerForm(link.edit) == form) then
        link.forceRefresh = true
        pcall(RefreshOptionEdit, link)
        link.forceRefresh = false
      end
    end
    return
  end
  for i = 1, #bucket.toggles do pcall(RefreshOptionToggle, bucket.toggles[i], true) end
  for i = 1, #bucket.trackbars do pcall(RefreshOptionTrackBar, bucket.trackbars[i]) end
  for i = 1, #bucket.checkboxes do pcall(RefreshOptionCheckbox, bucket.checkboxes[i]) end
  for i = 1, #bucket.edits do
    local link = bucket.edits[i]
    link.forceRefresh = true
    pcall(RefreshOptionEdit, link)
    link.forceRefresh = false
  end
end

for i = 1, #miscOptionForms do
  local form = miscOptionForms[i]
  if form ~= nil then
    local previousOnShow = form.OnShow
    form.OnShow = function(sender)
      if previousOnShow ~= nil then pcall(previousOnShow, sender) end
      if CameraPresetSpecs ~= nil and CameraPresetSpecs[form] ~= nil then
        EnsureCameraFormWired(form)
      end
      RefreshFormOptionControls(form)
      if form == RestartForm then RefreshRestartSwitch() end
      if form == PushToTalkForm or form == FPSForm then
        if RefreshAllHotkeyUI ~= nil then RefreshAllHotkeyUI() end
      end
    end
  end
end

-- ============================================================
-- OPTIONAL GROUPBOX WIRING
-- ============================================================
-- RP Booster Status is handled separately because its game-owned pointer is invalid until initialized.
TryWire(RegisterOptionToggle, RebalanceOptionsForm.Main, 1337167033, 1337167032)
TryWire(RegisterOptionToggle, RebalanceOptionsForm.StartingTime, 1337167035, 1337167032)
TryWire(RegisterOptionToggle, RebalanceOptionsForm.Additional, 1337167034, 1337167032)
TryWire(RegisterOptionToggle, RebalanceOptionsForm.MindOverMatter, 1337167440, 1337167032)

-- ============================================================
-- MENU BGM
-- ============================================================
TryWire(RegisterOptionToggle, BGMForm.BGMMode, 1337125889, 1337125896)

-- ============================================================
-- HOTKEY REBIND + FORM ENABLE (PTT / FPS)
-- ============================================================
local PTT_SCRIPT_ID = 1337125883
local PTT_HOTKEY_RECORD_ID = 1337125885
local PTT_HOTKEY_INDEX = 0
local FPS_SCRIPT_ID = 1337145693
local FPS_HOTKEY_RECORD_ID = 1337145695

local FPS_HOTKEY_DEFS = {
  { value = 30,  index = 0, edit = "edtFPSHotkey30",  btn = "btnFPSHotkey30",  keys = {16, 116} },
  { value = 45,  index = 1, edit = "edtFPSHotkey45",  btn = "btnFPSHotkey45",  keys = {16, 117} },
  { value = 60,  index = 2, edit = "edtFPSHotkey60",  btn = "btnFPSHotkey60",  keys = {16, 118} },
  { value = 120, index = 3, edit = "edtFPSHotkey120", btn = "btnFPSHotkey120", keys = {16, 119} },
}

hotkeyCapture = nil
pttModeIsHold = true
pttCachedKeys = {86}
fpsCachedKeys = {
  [0] = {16, 116}, [1] = {16, 117}, [2] = {16, 118}, [3] = {16, 119},
}

local pttToggleHotkey = nil
local pttCmbUpdating = false

local VK_NAMES = {
  [8]="Backspace",[9]="Tab",[13]="Enter",[16]="Shift",[17]="Ctrl",[18]="Alt",
  [19]="Pause",[20]="CapsLock",[27]="Esc",[32]="Space",
  [33]="PageUp",[34]="PageDown",[35]="End",[36]="Home",
  [37]="Left",[38]="Up",[39]="Right",[40]="Down",
  [45]="Insert",[46]="Delete",
  [48]="0",[49]="1",[50]="2",[51]="3",[52]="4",[53]="5",[54]="6",[55]="7",[56]="8",[57]="9",
  [65]="A",[66]="B",[67]="C",[68]="D",[69]="E",[70]="F",[71]="G",[72]="H",[73]="I",[74]="J",
  [75]="K",[76]="L",[77]="M",[78]="N",[79]="O",[80]="P",[81]="Q",[82]="R",[83]="S",[84]="T",
  [85]="U",[86]="V",[87]="W",[88]="X",[89]="Y",[90]="Z",
  [96]="Num0",[97]="Num1",[98]="Num2",[99]="Num3",[100]="Num4",[101]="Num5",[102]="Num6",
  [103]="Num7",[104]="Num8",[105]="Num9",[106]="Num*",[107]="Num+",[109]="Num-",[110]="Num.",[111]="Num/",
  [112]="F1",[113]="F2",[114]="F3",[115]="F4",[116]="F5",[117]="F6",[118]="F7",[119]="F8",
  [120]="F9",[121]="F10",[122]="F11",[123]="F12",
  [160]="LShift",[161]="RShift",[162]="LCtrl",[163]="RCtrl",[164]="LAlt",[165]="RAlt",
  [186]=";",[187]="=",[188]=",",[189]="-",[190]=".",[191]="/",[192]="`",[219]="[",[220]="\\",[221]="]",[222]="'",
}

local VK_FROM_NAME = {}
for code, name in pairs(VK_NAMES) do
  VK_FROM_NAME[name:upper()] = code
  VK_FROM_NAME["VK_" .. name:upper()] = code
end
VK_FROM_NAME["VK_SHIFT"] = 16
VK_FROM_NAME["VK_CONTROL"] = 17
VK_FROM_NAME["VK_CTRL"] = 17
VK_FROM_NAME["VK_MENU"] = 18
VK_FROM_NAME["VK_ALT"] = 18
VK_FROM_NAME["VK_RETURN"] = 13
VK_FROM_NAME["VK_ESCAPE"] = 27
VK_FROM_NAME["VK_SPACE"] = 32

local MOUSE_VKS = {[1]=true,[2]=true,[4]=true,[5]=true,[6]=true}
local CAPTURE_VKS = {}
local CAPTURE_VK_SEEN = {}
for vk in pairs(VK_NAMES) do
  if not MOUSE_VKS[vk] and vk ~= 13 and vk ~= 27 then CAPTURE_VK_SEEN[vk] = true end
end
for vk in pairs(CAPTURE_VK_SEEN) do CAPTURE_VKS[#CAPTURE_VKS+1] = vk end
table_sort(CAPTURE_VKS)

local function HK_VKName(vk) return VK_NAMES[vk] or ("VK_" .. tostring(vk)) end

local function HK_ParseKeyToken(token)
  if token == nil then return nil end
  token = tostring(token):gsub("^%s+", ""):gsub("%s+$", "")
  if token == "" then return nil end
  local n = tonumber(token)
  if n ~= nil then return n end
  local upper = token:upper()
  if VK_FROM_NAME[upper] ~= nil then return VK_FROM_NAME[upper] end
  local f = upper:match("^F(%d+)$") or upper:match("^VK_F(%d+)$")
  if f ~= nil then
    local fn = tonumber(f)
    if fn ~= nil and fn &gt;= 1 and fn &lt;= 24 then return 111 + fn end
  end
  return nil
end

local function HK_KeysToList(keys)
  local list = {}
  if keys == nil then return list end
  if type(keys) == "number" then
    if not MOUSE_VKS[keys] then list[#list+1] = keys end
    return list
  end
  if type(keys) == "table" then
    for _, v in ipairs(keys) do
      local n = HK_ParseKeyToken(v)
      if n ~= nil and not MOUSE_VKS[n] then list[#list+1] = n end
    end
    if #list == 0 then
      for k, v in pairs(keys) do
        local n = HK_ParseKeyToken(v) or HK_ParseKeyToken(k)
        if n ~= nil and not MOUSE_VKS[n] then list[#list+1] = n end
      end
    end
    return list
  end
  if type(keys) == "string" then
    for part in string_gmatch(keys, "[^,+%s]+") do
      local n = HK_ParseKeyToken(part)
      if n ~= nil and not MOUSE_VKS[n] then list[#list+1] = n end
    end
  end
  return list
end

local function HK_KeysToDisplay(keys)
  local list = HK_KeysToList(keys)
  if #list == 0 then return "" end
  local names = {}
  for i = 1, #list do names[#names+1] = HK_VKName(list[i]) end
  return table_concat(names, "+")
end

local function HK_GetMR(id) return CE_GetRecord(id) end
local function HK_ScriptActive(id)
  local mr = HK_GetMR(id)
  return mr ~= nil and mr.Active == true
end

local function HK_GetHotkey(mr, index)
  if mr == nil then return nil end
  local attempts = {
    function() return mr.getHotkey(index) end,
    function() return mr.Hotkey[index] end,
    function() return mr.Hotkeys[index] end,
  }
  for i = 1, #attempts do
    local ok, hk = pcall(attempts[i])
    if ok and hk ~= nil then return hk end
  end
  return nil
end

local function HK_GetKeys(hk)
  if hk == nil then return {} end
  local rawCandidates = {}
  local function add(v) if v ~= nil then rawCandidates[#rawCandidates+1] = v end end
  pcall(function() add(hk.Keys) end)
  pcall(function() add(hk.keys) end)
  pcall(function() if type(hk.getKeys) == "function" then add(hk.getKeys()) end end)
  pcall(function() add(object_getProperty(hk, "Keys")) end)
  pcall(function()
    local n = hk.Keys.Count or hk.Count
    if type(n) == "number" and n &gt; 0 then
      local t = {}
      for i = 0, n - 1 do
        local ok, v = pcall(function() return hk.Keys[i] or hk.Keys[i + 1] end)
        if ok then t[#t+1] = v end
      end
      add(t)
    end
  end)
  for i = 1, #rawCandidates do
    local list = HK_KeysToList(rawCandidates[i])
    if #list &gt; 0 then return list end
    list = HK_KeysToList(tostring(rawCandidates[i]))
    if #list &gt; 0 then return list end
  end
  return {}
end

local function HK_GetOnlyWhileDown(hk)
  if hk == nil then return nil end
  local ok, v = pcall(function() return hk.OnlyWhileDown end)
  if ok then return (v == true or v == 1 or v == "1") end
  return nil
end

local function HK_SetOnlyWhileDown(hk, value)
  if hk == nil then return end
  pcall(function() hk.OnlyWhileDown = value and true or false end)
end

local function HK_SetKeys(mr, index, keycodes, onlyWhileDown, value, description)
  if mr == nil or keycodes == nil or #keycodes == 0 then return false end
  local hk = HK_GetHotkey(mr, index) or HK_GetHotkey(mr, 0)
  if hk == nil then return false end
  local ok = pcall(function() hk.Keys = keycodes end)
  if not ok then
    local parts = {}
    for i = 1, #keycodes do parts[#parts+1] = tostring(keycodes[i]) end
    ok = pcall(function() hk.Keys = table_concat(parts, ",") end)
  end
  if onlyWhileDown ~= nil then HK_SetOnlyWhileDown(hk, onlyWhileDown) end
  if value ~= nil then pcall(function() hk.Value = tostring(value) end) end
  if description ~= nil then pcall(function() hk.Description = description end) end
  return ok
end

local function HK_FormCtrl(form, name)
  if form == nil or name == nil then return nil end
  local ok, c = pcall(function() return form[name] end)
  if ok then return c end
  return nil
end

function HK_SetFormEnabled(form, enabled)
  if form == nil then return end
  local function isLabel(c)
    if c == nil then return true end
    local cls = ""
    pcall(function() cls = tostring(c.ClassName or "") end)
    return cls:lower():find("label", 1, true) ~= nil
  end
  local count = 0
  pcall(function() count = form.ComponentCount or 0 end)
  for i = 0, count - 1 do
    local c = nil
    pcall(function() c = form.Component[i] end)
    if c ~= nil and not isLabel(c) then
      pcall(function() c.Enabled = enabled end)
    end
  end
end

local function HK_DestroyPttToggleHotkey()
  if pttToggleHotkey == nil then return end
  local h = pttToggleHotkey
  pttToggleHotkey = nil
  pcall(function() h.Enabled = false end)
  pcall(function() h.destroy() end)
end

local function HK_TogglePs2tlk()
  local addr = nil
  pcall(function() addr = getAddress("ps2tlk") end)
  if addr ~= nil and addr ~= 0 then
    local cur = 0
    pcall(function() cur = readBytes(addr, 1, false) or 0 end)
    pcall(function() writeBytes(addr, (cur == 1) and 0 or 1) end)
    return
  end
  local mr = HK_GetMR(PTT_HOTKEY_RECORD_ID)
  if mr == nil then return end
  local cur = 0
  pcall(function() cur = tonumber(mr.Value) or 0 end)
  pcall(function() mr.Value = tostring(cur == 1 and 0 or 1) end)
end

function HK_ApplyPTTMode(keys, forceSetKeys)
  forceSetKeys = (forceSetKeys == true)
  local keyList = HK_KeysToList(keys)
  if #keyList == 0 then keyList = HK_KeysToList(pttCachedKeys) end
  if #keyList == 0 then keyList = {86} end
  pttCachedKeys = keyList
  local mr = HK_GetMR(PTT_HOTKEY_RECORD_ID)
  HK_DestroyPttToggleHotkey()
  local hk = HK_GetHotkey(mr, PTT_HOTKEY_INDEX) or HK_GetHotkey(mr, 0)
  if pttModeIsHold then
    if forceSetKeys then
      pcall(HK_SetKeys, mr, PTT_HOTKEY_INDEX, keyList, true, "1", "Push to talk")
      hk = HK_GetHotkey(mr, PTT_HOTKEY_INDEX) or HK_GetHotkey(mr, 0)
    end
    if hk ~= nil then
      pcall(function()
        HK_SetOnlyWhileDown(hk, true)
        pcall(function() hk.Value = "1" end)
        hk.Active = true
      end)
    end
  else
    if hk ~= nil then
      pcall(function()
        hk.Active = false
        HK_SetOnlyWhileDown(hk, false)
      end)
    end
    if forceSetKeys then
      pcall(HK_SetKeys, mr, PTT_HOTKEY_INDEX, keyList, false, "1", "Push to talk")
      hk = HK_GetHotkey(mr, PTT_HOTKEY_INDEX) or HK_GetHotkey(mr, 0)
      if hk ~= nil then
        pcall(function()
          hk.Active = false
          HK_SetOnlyWhileDown(hk, false)
        end)
      end
    end
    local okH, h = pcall(function()
      return createHotkey(function()
        if not HK_ScriptActive(PTT_SCRIPT_ID) then return end
        if pttModeIsHold then return end
        HK_TogglePs2tlk()
      end, keyList)
    end)
    if okH and h ~= nil then pttToggleHotkey = h end
  end
end

local function HK_IsDown(vk) return isKeyPressed(vk) == true end

local function HK_StopCapture(restore)
  if hotkeyCapture == nil then return end
  if hotkeyCapture.timer ~= nil then
    pcall(function()
      hotkeyCapture.timer.Enabled = false
      hotkeyCapture.timer.destroy()
    end)
  end
  if hotkeyCapture.edit ~= nil and hotkeyCapture.prevOnKeyDown ~= nil then
    pcall(function() hotkeyCapture.edit.OnKeyDown = hotkeyCapture.prevOnKeyDown end)
  elseif hotkeyCapture.edit ~= nil then
    pcall(function() hotkeyCapture.edit.OnKeyDown = nil end)
  end
  if restore and hotkeyCapture.edit ~= nil then
    pcall(function() hotkeyCapture.edit.Text = hotkeyCapture.previousText or "" end)
  end
  hotkeyCapture = nil
end

local function HK_FinishCapture()
  if hotkeyCapture == nil then return end
  if hotkeyCapture.chord == nil or #hotkeyCapture.chord == 0 then
    HK_StopCapture(true)
    return
  end
  local state = hotkeyCapture
  local keys = {}
  for i = 1, #state.chord do keys[#keys+1] = state.chord[i] end
  if state.timer ~= nil then
    pcall(function()
      state.timer.Enabled = false
      state.timer.destroy()
    end)
  end
  if state.edit ~= nil then
    if state.prevOnKeyDown ~= nil then
      pcall(function() state.edit.OnKeyDown = state.prevOnKeyDown end)
    else
      pcall(function() state.edit.OnKeyDown = nil end)
    end
  end
  hotkeyCapture = nil
  if state.kind == "ptt" then
    pttCachedKeys = keys
    HK_ApplyPTTMode(keys, true)
    local edit = HK_FormCtrl(PushToTalkForm, "edtPTTHotkey")
    if edit ~= nil then pcall(function() edit.Text = HK_KeysToDisplay(keys) end) end
  elseif state.kind == "fps" then
    local mr = HK_GetMR(FPS_HOTKEY_RECORD_ID)
    HK_SetKeys(mr, state.hotkeyIndex, keys, false, tostring(state.value), tostring(state.value) .. " FPS")
    fpsCachedKeys[state.hotkeyIndex] = keys
    local edit = HK_FormCtrl(FPSForm, state.editName)
    if edit ~= nil then pcall(function() edit.Text = HK_KeysToDisplay(keys) end) end
  end
end

local function HK_UpdateCaptureText()
  if hotkeyCapture == nil or hotkeyCapture.edit == nil then return end
  local chord = hotkeyCapture.chord or {}
  if #chord == 0 then
    pcall(function() hotkeyCapture.edit.Text = "ESC cancel, ENTER confirm" end)
  else
    pcall(function()
      hotkeyCapture.edit.Text = HK_KeysToDisplay(chord) .. "  |  ESC cancel, ENTER confirm"
    end)
  end
end

local function HK_StartCapture(opts)
  HK_StopCapture(true)
  if opts == nil or opts.edit == nil then return end
  local prev = ""
  pcall(function() prev = tostring(opts.edit.Text or "") end)
  local prevOnKeyDown = nil
  pcall(function() prevOnKeyDown = opts.edit.OnKeyDown end)
  hotkeyCapture = {
    kind = opts.kind, edit = opts.edit, previousText = prev,
    prevOnKeyDown = prevOnKeyDown, hotkeyIndex = opts.hotkeyIndex,
    value = opts.value, editName = opts.editName,
    chord = {}, chordSet = {}, startedAt = os_clock(), timer = nil,
  }
  HK_UpdateCaptureText()
  pcall(function() opts.edit.SetFocus() end)
  opts.edit.OnKeyDown = function(sender, key)
    if hotkeyCapture == nil then return end
    local k = tonumber(key) or 0
    if k == 13 then
      if #hotkeyCapture.chord &gt; 0 then HK_FinishCapture() else HK_StopCapture(true) end
      return
    end
    if k == 27 then HK_StopCapture(true) return end
    if MOUSE_VKS[k] then return end
    local isMod = (k == 16 or k == 17 or k == 18 or k == 160 or k == 161 or k == 162 or k == 163 or k == 164 or k == 165)
    if not isMod then
      local function ensure(code)
        if not hotkeyCapture.chordSet[code] and HK_IsDown(code) then
          hotkeyCapture.chordSet[code] = true
          hotkeyCapture.chord[#hotkeyCapture.chord+1] = code
        end
      end
      if HK_IsDown(17) or HK_IsDown(162) or HK_IsDown(163) then ensure(17) end
      if HK_IsDown(18) or HK_IsDown(164) or HK_IsDown(165) then ensure(18) end
      if HK_IsDown(16) or HK_IsDown(160) or HK_IsDown(161) then ensure(16) end
      if not hotkeyCapture.chordSet[k] then
        hotkeyCapture.chordSet[k] = true
        hotkeyCapture.chord[#hotkeyCapture.chord+1] = k
      end
      HK_UpdateCaptureText()
    end
  end
  local t = createTimer(nil)
  t.Interval = 30
  t.OnTimer = function(timer)
    if hotkeyCapture == nil then timer.Enabled = false return end
    if os_clock() - (hotkeyCapture.startedAt or 0) &lt; 0.20 then return end
    if HK_IsDown(27) then HK_StopCapture(true) return end
    if HK_IsDown(13) then
      if #hotkeyCapture.chord &gt; 0 then HK_FinishCapture() else HK_StopCapture(true) end
      return
    end
    local pressed = {}
    local hasMain = false
    local function pushMod(code, a, b)
      if HK_IsDown(code) or HK_IsDown(a) or HK_IsDown(b) then pressed[#pressed+1] = code end
    end
    pushMod(17, 162, 163)
    pushMod(18, 164, 165)
    pushMod(16, 160, 161)
    for i = 1, #CAPTURE_VKS do
      local vk = CAPTURE_VKS[i]
      if vk ~= 16 and vk ~= 17 and vk ~= 18 and vk ~= 160 and vk ~= 161 and vk ~= 162 and vk ~= 163 and vk ~= 164 and vk ~= 165 then
        if HK_IsDown(vk) then
          pressed[#pressed+1] = vk
          hasMain = true
        end
      end
    end
    if hasMain then
      local changed = false
      for i = 1, #pressed do
        local vk = pressed[i]
        if not hotkeyCapture.chordSet[vk] then
          hotkeyCapture.chordSet[vk] = true
          hotkeyCapture.chord[#hotkeyCapture.chord+1] = vk
          changed = true
        end
      end
      if changed then HK_UpdateCaptureText() end
    end
  end
  hotkeyCapture.timer = t
  t.Enabled = true
end

function RefreshMicActivity()
  local edit = HK_FormCtrl(PushToTalkForm, "edtMicActivity")
  if edit == nil then return end
  if not HK_ScriptActive(PTT_SCRIPT_ID) then
    pcall(function() edit.Text = "" end)
    return
  end
  local value = nil
  pcall(function()
    local addr = getAddress("ps2tlk")
    if addr ~= nil and addr ~= 0 then value = readBytes(addr, 1, false) end
  end)
  if value == nil then
    local mr = HK_GetMR(PTT_HOTKEY_RECORD_ID)
    if mr ~= nil then pcall(function() value = tonumber(mr.Value) end) end
  end
  local text = ""
  if value == 0 then text = "Inactive"
  elseif value == 1 then text = "Active"
  elseif value ~= nil then text = tostring(value) end
  pcall(function() edit.Text = text end)
end

function RefreshPTTHotkeyDisplay()
  if hotkeyCapture ~= nil then return end
  local edit = HK_FormCtrl(PushToTalkForm, "edtPTTHotkey")
  if edit == nil then return end
  local keys = HK_KeysToList(pttCachedKeys)
  if #keys == 0 then
    local mr = HK_GetMR(PTT_HOTKEY_RECORD_ID)
    local hk = HK_GetHotkey(mr, PTT_HOTKEY_INDEX) or HK_GetHotkey(mr, 0)
    keys = HK_GetKeys(hk)
    if #keys &gt; 0 then pttCachedKeys = keys end
  end
  local text = HK_KeysToDisplay(keys)
  if text == "" then text = "(none)" end
  pcall(function()
    edit.ReadOnly = true
    if tostring(edit.Text or "") ~= text then edit.Text = text end
  end)
end

function RefreshFPSHotkeyDisplay()
  if hotkeyCapture ~= nil then return end
  if FPSForm == nil then return end
  local mr = HK_GetMR(FPS_HOTKEY_RECORD_ID)
  for i = 1, #FPS_HOTKEY_DEFS do
    local d = FPS_HOTKEY_DEFS[i]
    local edit = HK_FormCtrl(FPSForm, d.edit)
    if edit ~= nil then
      local hk = HK_GetHotkey(mr, d.index)
      local keys = HK_GetKeys(hk)
      if #keys &gt; 0 then
        fpsCachedKeys[d.index] = keys
      else
        keys = HK_KeysToList(fpsCachedKeys[d.index] or d.keys)
      end
      local text = HK_KeysToDisplay(keys)
      if text == "" then text = "(none)" end
      pcall(function()
        edit.ReadOnly = true
        if tostring(edit.Text or "") ~= text then edit.Text = text end
      end)
    end
  end
end

function RefreshPTTFormEnabled()
  local active = HK_ScriptActive(PTT_SCRIPT_ID)
  HK_SetFormEnabled(PushToTalkForm, active)
  if not active then
    HK_StopCapture(true)
    HK_DestroyPttToggleHotkey()
  end
end

function RefreshFPSFormEnabled()
  local active = HK_ScriptActive(FPS_SCRIPT_ID)
  HK_SetFormEnabled(FPSForm, active)
  if not active then HK_StopCapture(true) end
end

function RefreshAllHotkeyUI()
  if hotkeyCapture ~= nil then return end
  RefreshPTTFormEnabled()
  RefreshFPSFormEnabled()
  RefreshPTTHotkeyDisplay()
  RefreshFPSHotkeyDisplay()
  RefreshMicActivity()
end

function WirePTTHotkeyControls()
  if PushToTalkForm == nil then return end
  local edit = HK_FormCtrl(PushToTalkForm, "edtPTTHotkey")
  local btn = HK_FormCtrl(PushToTalkForm, "btnPTTHotkey")
  local cmb = HK_FormCtrl(PushToTalkForm, "cmbPTTHotkeyMode")
  local mic = HK_FormCtrl(PushToTalkForm, "edtMicActivity")
  if edit ~= nil then pcall(function() edit.ReadOnly = true end) end
  if mic ~= nil then pcall(function() mic.ReadOnly = true end) end
  if cmb ~= nil then
    pttCmbUpdating = true
    pcall(function()
      cmb.Style = 2
      if cmb.Items.Count ~= 2 then
        cmb.Items.Clear()
        cmb.Items.Add("Hold")
        cmb.Items.Add("Toggle")
      end
      cmb.ItemIndex = pttModeIsHold and 0 or 1
    end)
    pttCmbUpdating = false
    cmb.OnChange = nil
    cmb.OnCloseUp = function(sender)
      if pttCmbUpdating then return end
      if not HK_ScriptActive(PTT_SCRIPT_ID) then return end
      if hotkeyCapture ~= nil then return end
      local idx = -1
      local label = ""
      pcall(function()
        idx = sender.ItemIndex or -1
        if idx &gt;= 0 then label = tostring(sender.Items[idx] or "") end
      end)
      local lower = label:lower()
      local newHold
      if lower:find("toggle", 1, true) then newHold = false
      elseif lower:find("hold", 1, true) then newHold = true
      else newHold = (idx ~= 1) end
      if newHold == pttModeIsHold then return end
      pttModeIsHold = newHold
      HK_ApplyPTTMode(pttCachedKeys, false)
      pttCmbUpdating = true
      pcall(function() sender.ItemIndex = pttModeIsHold and 0 or 1 end)
      pttCmbUpdating = false
    end
  end
  if btn ~= nil then
    btn.OnClick = function(sender)
      if not HK_ScriptActive(PTT_SCRIPT_ID) then return end
      HK_StartCapture({ kind = "ptt", edit = edit })
    end
  end
  local mr = HK_GetMR(PTT_HOTKEY_RECORD_ID)
  local hk = HK_GetHotkey(mr, PTT_HOTKEY_INDEX)
  local keys = HK_GetKeys(hk)
  if #keys &gt; 0 then pttCachedKeys = keys end
  local owd = HK_GetOnlyWhileDown(hk)
  if owd == false then pttModeIsHold = false else pttModeIsHold = true end
  RefreshPTTHotkeyDisplay()
  RefreshPTTFormEnabled()
  RefreshMicActivity()
end

function WireFPSHotkeyControls()
  if FPSForm == nil then return end
  for i = 1, #FPS_HOTKEY_DEFS do
    local d = FPS_HOTKEY_DEFS[i]
    local edit = HK_FormCtrl(FPSForm, d.edit)
    local btn = HK_FormCtrl(FPSForm, d.btn)
    local value, index, editName = d.value, d.index, d.edit
    if edit ~= nil then pcall(function() edit.ReadOnly = true end) end
    if btn ~= nil then
      btn.OnClick = function(sender)
        if not HK_ScriptActive(FPS_SCRIPT_ID) then return end
        HK_StartCapture({
          kind = "fps", edit = edit, hotkeyIndex = index,
          value = value, editName = editName,
        })
      end
    end
  end
  local resetBtn = HK_FormCtrl(FPSForm, "btnFPSHotkeysReset")
    or HK_FormCtrl(FPSForm, "btnResetHotkeys")
    or HK_FormCtrl(FPSForm, "ResetToDefault")
  if resetBtn == nil then
    pcall(function()
      for i = 0, (FPSForm.ComponentCount or 0) - 1 do
        local c = FPSForm.Component[i]
        if c ~= nil then
          local cls = tostring(c.ClassName or ""):lower()
          if cls:find("button", 1, true) then
            local cap = tostring(c.Caption or ""):lower()
            if cap:find("reset", 1, true) or cap:find("default", 1, true) then
              resetBtn = c
              break
            end
          end
        end
      end
    end)
  end
  if resetBtn ~= nil then
    resetBtn.OnClick = function(sender)
      if not HK_ScriptActive(FPS_SCRIPT_ID) then return end
      if hotkeyCapture ~= nil then HK_StopCapture(true) end
      local mr = HK_GetMR(FPS_HOTKEY_RECORD_ID)
      for i = 1, #FPS_HOTKEY_DEFS do
        local d = FPS_HOTKEY_DEFS[i]
        HK_SetKeys(mr, d.index, d.keys, false, tostring(d.value), tostring(d.value) .. " FPS")
        fpsCachedKeys[d.index] = d.keys
      end
      RefreshFPSHotkeyDisplay()
    end
  end
  local mr = HK_GetMR(FPS_HOTKEY_RECORD_ID)
  for i = 1, #FPS_HOTKEY_DEFS do
    local d = FPS_HOTKEY_DEFS[i]
    local keys = HK_GetKeys(HK_GetHotkey(mr, d.index))
    if #keys &gt; 0 then fpsCachedKeys[d.index] = keys end
  end
  RefreshFPSHotkeyDisplay()
  RefreshFPSFormEnabled()
end

WirePTTHotkeyControls()
WireFPSHotkeyControls()

local hotkeyUiTimer = createTimer(nil)
hotkeyUiTimer.Interval = 250
hotkeyUiTimer.OnTimer = function(t)
  if getOpenedProcessID() == 0 then return end
  if hotkeyCapture ~= nil then return end
  local pttOpen = PushToTalkForm ~= nil and PushToTalkForm.Visible == true
  local fpsOpen = FPSForm ~= nil and FPSForm.Visible == true
  if not pttOpen and not fpsOpen then return end
  if pttOpen then
    RefreshPTTFormEnabled()
    RefreshPTTHotkeyDisplay()
    RefreshMicActivity()
  end
  if fpsOpen then
    RefreshFPSFormEnabled()
    RefreshFPSHotkeyDisplay()
    if RefreshFormOptionControls ~= nil then
      RefreshFormOptionControls(FPSForm)
    end
  end
end

-- ============================================================
-- PUSH TO TALK
-- ============================================================
TryWire(RegisterOptionToggle, PushToTalkForm.PushToTalkMode, 1337125884, 1337125883)
TryWire(RegisterOptionToggle, PushToTalkForm.VCVolumeMode, 1337141394, 1337125883)
TryWire(RegisterOptionToggle, PushToTalkForm.VCP1Mode, 1337141395, 1337125883)
TryWire(RegisterOptionToggle, PushToTalkForm.VCP2Mode, 1337141397, 1337125883)
TryWire(RegisterOptionToggle, PushToTalkForm.VCP3Mode, 1337141401, 1337125883)
TryWire(RegisterOptionToggle, PushToTalkForm.VCP4Mode, 1337141399, 1337125883)
TryWire(RegisterOptionTrackBar, PushToTalkForm.VCP1Volume, 1337141396, 1337125883)
TryWire(RegisterOptionTrackBar, PushToTalkForm.VCP2Volume, 1337141398, 1337125883)
TryWire(RegisterOptionTrackBar, PushToTalkForm.VCP3Volume, 1337141402, 1337125883)
TryWire(RegisterOptionTrackBar, PushToTalkForm.VCP4Volume, 1337141400, 1337125883)

-- ============================================================
-- FORM ON-SHOW REFRESHES
-- ============================================================
if RPBoosterOptionsForm ~= nil then
  RPBoosterOptionsForm.OnShow = function(sender)
    RefreshFormOptionControls(sender)
    StartRPBoosterStatusTimer()
  end
end
if RebalanceOptionsForm ~= nil then
  RebalanceOptionsForm.OnShow = function(sender) RefreshFormOptionControls(sender) end
end
if BGMForm ~= nil then
  BGMForm.OnShow = function(sender) RefreshFormOptionControls(sender) end
end
if PushToTalkForm ~= nil then
  PushToTalkForm.OnShow = function(sender)
    RefreshFormOptionControls(sender)
    if RefreshAllHotkeyUI ~= nil then RefreshAllHotkeyUI() end
  end
end

-- ============================================================
-- ERAZ3R
-- ============================================================
local ERAZ3R_SCRIPT_ID = 1337122681

if Eraz3rLinks == nil then Eraz3rLinks = {} end
if Eraz3rLinksByForm == nil then Eraz3rLinksByForm = {} end

local function CE_IndexEraz3rLink(link, control)
  local form = CE_ResolveOwnerForm(control)
  link.form = form
  if form ~= nil then
    local bucket = Eraz3rLinksByForm[form]
    if bucket == nil then bucket = {}; Eraz3rLinksByForm[form] = bucket end
    bucket[#bucket+1] = link
  end
end

-- Alias (kept for readability at call sites) rather than a wrapper
-- closure that only re-invokes CE_GetRecord.
local CE_GetRecordEraz3r = CE_GetRecord

local function TryWireEraz3r(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then print("[Eraz3rForm wiring error] " .. tostring(err)) end
end

function RegisterEraz3rCombo(combo, recordID, labelToValue)
  if combo == nil then
    print("RegisterEraz3rCombo: combo is NIL for record -&gt; " .. tostring(recordID))
    return nil
  end
  pcall(function() combo.Style = 2 end)
  local orderedLabels = {}
  local seen = {}
  if combo.Items ~= nil and combo.Items.Count ~= nil then
    for i = 0, combo.Items.Count - 1 do
      local text = tostring(combo.Items[i] or "")
      local value = labelToValue[text]
      if value == nil then
        local norm = text:gsub("^%s+", ""):gsub("%s+$", ""):upper()
        for k, v in pairs(labelToValue) do
          if tostring(k):gsub("^%s+", ""):gsub("%s+$", ""):upper() == norm then
            value = v
            text = tostring(k)
            break
          end
        end
      end
      if value ~= nil and not seen[text] then
        orderedLabels[#orderedLabels+1] = text
        seen[text] = true
      end
    end
  end
  for k, _ in pairs(labelToValue) do
    local key = tostring(k)
    if not seen[key] then
      orderedLabels[#orderedLabels+1] = key
      seen[key] = true
    end
  end
  combo.Items.Clear()
  for i = 1, #orderedLabels do combo.Items.Add(orderedLabels[i]) end
  return RegisterMappedOptionCombo(combo, recordID, ERAZ3R_SCRIPT_ID, labelToValue)
end

function RegisterEraz3rEdit(edit, recordID, displayKind)
  if edit == nil then
    print("RegisterEraz3rEdit: edit is NIL for record -&gt; " .. tostring(recordID))
    return nil
  end
  local mr = CE_GetRecordEraz3r(recordID)
  if mr == nil then
    print("RegisterEraz3rEdit: record not found -&gt; " .. tostring(recordID))
    return nil
  end
  local scriptMr = CE_GetRecordEraz3r(ERAZ3R_SCRIPT_ID)
  local lookup = nil
  if displayKind == "hex" or displayKind == "decimal_lookup" then
    lookup = {}
    for _, item in ipairs(CE_ParseDropDown(mr)) do
      local n
      if displayKind == "hex" then
        n = tonumber(item.value, 16) or tonumber(item.value)
      else
        n = tonumber(item.value)
      end
      if n ~= nil then lookup[n] = item.label end
    end
  end
  local link = {
    kind = "edit", displayKind = displayKind,
    edit = edit, record = mr, script = scriptMr, lookup = lookup
  }
  Eraz3rLinks[#Eraz3rLinks+1] = link
  CE_IndexEraz3rLink(link, edit)
  RefreshEraz3rLink(link)
  return link
end

function RefreshEraz3rLink(link)
  if link == nil or link.kind == "combo" then return end
  local active = (link.script ~= nil and link.script.Active == true)
  local edit = link.edit
  if not active then
    edit.Enabled = false
    edit.Text = ""
    return
  end
  edit.Enabled = true
  local ok, current = pcall(function() return link.record.Value end)
  if not ok or current == nil then
    edit.Text = ""
    return
  end
  current = tonumber(current)
  if current == nil then
    edit.Text = ""
    return
  end
  if link.displayKind == "count" then
    edit.Text = string_format("%d", math_floor(current))
  elseif link.displayKind == "float" then
    edit.Text = string_format("%.0f", current)
  elseif link.displayKind == "ping" then
    local v = math_floor(current)
    if v == 0 then edit.Text = "Fine"
    elseif v == 1 then edit.Text = "Laggy"
    elseif v == 255 then edit.Text = "Unknown"
    else edit.Text = tostring(v) end
  elseif link.displayKind == "hex" then
    local n = math_floor(current)
    local label = link.lookup ~= nil and link.lookup[n]
    edit.Text = label ~= nil and label or string_format("%08X", n)
  elseif link.displayKind == "decimal_lookup" then
    local n = math_floor(current)
    local label = link.lookup ~= nil and link.lookup[n]
    edit.Text = label ~= nil and label or string_format("%d", n)
  end
end

function RefreshAllEraz3rLinks()
  for i = 1, #Eraz3rLinks do pcall(RefreshEraz3rLink, Eraz3rLinks[i]) end
end

-- ============================================================
-- ERAZ3R WIRING
-- ============================================================
TryWireEraz3r(RegisterEraz3rCombo, Eraz3rForm.cmbCheater, 1337122777, {["ON"]=1,["OFF"]=0})
TryWireEraz3r(RegisterEraz3rCombo, Eraz3rForm.cmbProblematic, 1337122778, {["ON"]=1,["OFF"]=0})
TryWireEraz3r(RegisterEraz3rCombo, Eraz3rForm.cmbAC, 1337122690, {
  ["ON - all"]=2, ["ON - only known accounts"]=4, ["OFF"]=0
})
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.MMSection1Block, 1337122684, "hex")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.MMSection1Count, 1337122685, "count")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.MMSection2Block, 1337122687, "hex")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.MMSection2Count, 1337122688, "count")
TryWireEraz3r(RegisterEraz3rCombo, Eraz3rForm.MMLobbyMode, 1337123935, {
  ["OFF"]=0, ["+1 Slot"]=1, ["+2 Slots"]=2, ["x2 Slots"]=3, ["64 Slots"]=4
})
TryWireEraz3r(RegisterEraz3rCombo, Eraz3rForm.MMLobbyCondition, 1337123936, {
  ["4/5"]=0, ["3/5"]=1, ["2/5"]=2, ["1/5"]=3
})
TryWireEraz3r(RegisterEraz3rCombo, Eraz3rForm.SVLobbyDodgeMode, 1337123950, {
  ["OFF"]=0, ["Blocked Players only"]=1, ["Blocked Players &amp; Ghost Lobbies"]=2, ["Ghost Lobbies only"]=3
})
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.LobbyDodgeCount, 1337123951, "count")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.LobbyExitCount, 1337123952, "count")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.Eraz3rLobbyDodgeBlock, 1337123954, "hex")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.Eraz3rLobbyDodgeBlockCount, 1337123955, "count")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.Eraz3rLobbyDodgeGhost, 1337123957, "hex")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.Eraz3rLobbyDodgeGhostCount, 1337123958, "count")
TryWireEraz3r(RegisterEraz3rCombo, Eraz3rForm.DodgePreventionMode, 1337123960, {["ON"]=1,["OFF"]=0})
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.DodgePreventionCount, 1337123961, "count")
TryWireEraz3r(RegisterEraz3rCombo, Eraz3rForm.HostPingMode, 1337123963, {["ON"]=1,["OFF"]=0})
TryWireEraz3r(RegisterEraz3rCombo, Eraz3rForm.MaxPingThreshold, 1337123964, {
  ["150"]=150, ["200"]=200, ["250"]=250, ["300"]=300
})
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.MMPingStatus, 1337123965, "ping")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.MMPingLastAbove, 1337123966, "float")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.MMPingAvgBreach, 1337123967, "float")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.MMPingRTBreach, 1337123968, "float")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.SVPingStatus, 1337123969, "ping")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.SVPingLastAbove, 1337123970, "float")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.SVPingAvgBreach, 1337123971, "float")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.SVPingRTBreach, 1337123972, "float")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.SharedBlock, 1337123974, "hex")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.SharedCount, 1337123975, "count")
TryWireEraz3r(RegisterEraz3rCombo, Eraz3rForm.SharedACBlockMode, 1337124021, {["ON"]=1,["OFF"]=0})
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.SharedACCount, 1337122698, "count")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.SharedACTrigger1, 1337122699, "count")
TryWireEraz3r(RegisterEraz3rEdit, Eraz3rForm.SharedACTrigger2, 1337123941, "count")

-- ============================================================
-- DETECTED LIST
-- ============================================================
local detectedListRecordIDs = {
  1337123943,1337132628,1337123944,1337123945,1337123946,1337123947,
  1337122706,1337122707,1337122708,1337122709,1337122710,1337122711,
  1337122712,1337122713,1337122714,1337122715,1337122716,1337122717,
  1337122718,1337122719,1337122720,1337122721,1337122722,1337122723,
  1337122724,1337122725,1337122726,1337122727,1337122728,1337122729,
  1337122730,1337122731,1337122732,1337122733,1337122734,1337122735,
  1337122736,1337122737,1337122738,1337122739,1337122740,1337122741,
  1337122742,1337122743,1337122744,1337122745,1337122746,1337122747,
  1337122748,1337122749,1337122750,1337122751,1337122752,1337122753,
  1337122754,1337122755,1337122756,1337122757,1337122758,1337122759,
  1337122760,1337122761,1337122762,1337122763,1337122764,1337122765,
  1337122766,1337122767,1337122768,1337122769,1337122770,1337122771,
  1337122772,1337122773,1337122774,1337122775
}

if #detectedListRecordIDs ~= 76 then
  print("DetectedList ERROR: expected 76 record IDs, found " .. tostring(#detectedListRecordIDs))
end

for i = 1, #detectedListRecordIDs do
  local editName = "CEEdit" .. i
  local editControl = DetectedList[editName]
  local recordID = detectedListRecordIDs[i]
  if editControl ~= nil then
    TryWireEraz3r(RegisterEraz3rEdit, editControl, recordID, "decimal_lookup")
  else
    print("DetectedList wiring: '" .. editName .. "' not found")
  end
end

-- ============================================================
-- ERAZ3R FORM REFRESH
-- ============================================================
local eraz3rFormRef = findFormByName("Eraz3rForm")
local detectedListFormRef = findFormByName("DetectedList")

function RefreshEraz3rLinksForForm(form)
  if form == nil then return end
  local bucket = Eraz3rLinksByForm[form]
  if bucket == nil then return end
  for i = 1, #bucket do pcall(RefreshEraz3rLink, bucket[i]) end
end

if eraz3rFormRef ~= nil then
  eraz3rFormRef.OnShow = function(sender)
    RefreshEraz3rLinksForForm(sender)
    if RefreshFormOptionControls ~= nil then RefreshFormOptionControls(sender) end
  end
end

if detectedListFormRef ~= nil then
  detectedListFormRef.OnShow = function(sender)
    RefreshEraz3rLinksForForm(sender)
  end
end

local eraz3rTimer = createTimer(nil)
eraz3rTimer.Interval = 500
eraz3rTimer.OnTimer = function(t)
  if getOpenedProcessID() == 0 then return end
  -- Always refresh all Eraz3r edit links (read-only status/count/ping/hex displays).
  -- Previously only refreshed the visible form's bucket; some controls on TabSheets
  -- could miss indexing via CE_ResolveOwnerForm and therefore never update on the timer.
  RefreshAllEraz3rLinks()
end

-- ============================================================
-- Survivor "Current" Coordinates Sync (read-only live display)
-- ============================================================
local coordCurrentLinks = {
  {"CustomizeSVSlot1XCurrent", 1337168723}, {"CustomizeSVSlot1YCurrent", 1337168725}, {"CustomizeSVSlot1ZCurrent", 1337168727},
  {"CustomizeSVSlot2XCurrent", 1337168734}, {"CustomizeSVSlot2YCurrent", 1337168736}, {"CustomizeSVSlot2ZCurrent", 1337168738},
  {"CustomizeSVSlot3XCurrent", 1337168745}, {"CustomizeSVSlot3YCurrent", 1337168747}, {"CustomizeSVSlot3ZCurrent", 1337168749},
  {"CustomizeSVSlot4XCurrent", 1337168756}, {"CustomizeSVSlot4YCurrent", 1337168758}, {"CustomizeSVSlot4ZCurrent", 1337168760},
}

local coordCache = {}
for i = 1, #coordCurrentLinks do
  local link = coordCurrentLinks[i]
  local ctrl = CustomizationForm[link[1]]
  local mr = CE_AL.getMemoryRecordByID(link[2])
  if ctrl and mr then
    pcall(function() ctrl.ReadOnly = true end)
    ctrl.OnChange = nil -- guard against any stray writable handler
    coordCache[#coordCache+1] = {ctrl = ctrl, mr = mr}
  end
end

local coordSyncScript = CE_GetRecord(CUSTOMIZATION_SCRIPT)
local practiceScriptMrForLive = CE_GetRecord(1337167441)  -- PRACTICE_SCRIPT

if not _TimerCoordSync then
  _TimerCoordSync = createTimer()
  _TimerCoordSync.Interval = 500
end
_TimerCoordSync.OnTimer = function(sender)
  if getOpenedProcessID() == 0 then return end

  -- CustomizationForm current-slot coordinates
  if CustomizationForm ~= nil and CustomizationForm.Visible == true then
    local active = coordSyncScript ~= nil and coordSyncScript.Active == true
    for i = 1, #coordCache do
      local entry = coordCache[i]
      if not active then
        if entry.ctrl.Enabled then entry.ctrl.Enabled = false end
        if entry.ctrl.Text ~= "" then entry.ctrl.Text = "" end
      else
        if not entry.ctrl.Enabled then entry.ctrl.Enabled = true end
        local ok, valStr = pcall(function() return entry.mr.Value end)
        if ok and valStr ~= nil then
          local num = tonumber(valStr)
          -- Display formatting only -- this never touches entry.mr.Value.
          local formatted = num and string_format("%.3f", num) or tostring(valStr)
          if entry.ctrl.Text ~= formatted then entry.ctrl.Text = formatted end
        end
      end
    end
  end

  -- PracticeForm live values (PETimerAddCount countdown + FOV Default + camera axes)
  if PracticeForm ~= nil and PracticeForm.Visible == true then
    local pActive = practiceScriptMrForLive ~= nil and practiceScriptMrForLive.Active == true

    -- PETimerAddCount: refresh while the user is not editing so the countdown is visible
    for i = 1, #OptionEditLinks do
      local link = OptionEditLinks[i]
      if link.edit == PracticeForm.PETimerAddCount then
        if not link.editing then
          link.forceRefresh = true
          pcall(RefreshOptionEdit, link)
          link.forceRefresh = false
        end
        break
      end
    end

    -- FOV Default + Camera axis current read-outs
    for i = 1, #practiceAxisCache do
      local entry = practiceAxisCache[i]
      if not pActive then
        if entry.ctrl.Enabled then entry.ctrl.Enabled = false end
        if entry.ctrl.Text ~= "" then entry.ctrl.Text = "" end
      else
        if not entry.ctrl.Enabled then entry.ctrl.Enabled = true end
        local ok, valStr = pcall(function() return entry.mr.Value end)
        if ok and valStr ~= nil then
          local num = tonumber(valStr)
          local formatted = num and string_format("%.3f", num) or tostring(valStr)
          if entry.ctrl.Text ~= formatted then entry.ctrl.Text = formatted end
        end
      end
    end
  end
end
_TimerCoordSync.Enabled = true

-- ============================================================
-- About Tab
-- ============================================================
function TrainerForm_btnNexusPageClick(sender)
  shellExecute("https://www.nexusmods.com/residentevilresistance/mods/429")
end
function TrainerForm_btnNexusProfileClick(sender)
  shellExecute("https://www.nexusmods.com/profile/TeeBeeJay")
end
function TrainerForm_btnSteamProfileClick(sender)
  shellExecute("https://steamcommunity.com/id/teebeejay/")
end
function TrainerForm_btnDonateClick(sender)
  shellExecute("https://www.paypal.com/donate/?hosted_button_id=Z8PUQ2JZ2S5W6")
end

function TrainerForm_btnDonate2Click(sender)
  shellExecute("https://www.buymeacoffee.com/teebeejay")
end

function RebalanceOptionsForm_btnREBALANCEnotesClick(sender)
  shellExecute("https://docs.google.com/document/d/1xPcsJI8nmisAgmoZDGijMCkuW_txNlRF")
end

-- RedMemo
do
  local t = createTimer(nil)
  t.Interval = 100
  t.OnTimer = function(timer)
    local memo = TrainerForm and TrainerForm.RedMemo
    if memo == nil then return end
    memo.Font.Color = 0x0000FF
    timer.Enabled = false
    timer.destroy()
  end
end