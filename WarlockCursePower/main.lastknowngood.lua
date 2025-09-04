-- Warlock Curse Power - main.lua (Classic Era 1.15.7)
-- AceComm sync, borderless modern UI, chat-safe announce with raid icons,
-- streamlined notify lines, bottom-anchored centered control row,
-- borderless dropdowns (first-click), and ESC to close without blocking input.

local ADDON_NAME, COMM_PREFIX = "WarlockCursePower", "WCP1"

local AceGUI        = LibStub("AceGUI-3.0")
local AceDB         = LibStub("AceDB-3.0")
local AceSerializer = LibStub("AceSerializer-3.0")
local AceComm       = LibStub("AceComm-3.0")

local Addon = {}
AceComm:Embed(Addon)

-- ======================= Saved Vars / Utils =======================
local defaults = {
  profile = {
    assignments = {},            -- [playerName] = { curse = "<key>", banish = "<key>" }
    debug = false,
    frame = { width = 720, height = 380, point = "CENTER", x = 0, y = 0 },
  }
}
Addon.db = AceDB:New("CursePowerDB", defaults, true)

local function debugf(fmt, ...)
  if Addon.db.profile.debug then
    DEFAULT_CHAT_FRAME:AddMessage("|cffb48ef7[WCP]|r " .. string.format(fmt, ...))
  end
end

local function now() return time() end

local function shallowCopy(t)
  local o = {}
  for k, v in pairs(t or {}) do
    if type(v) == "table" then
      local i = {}
      for k2, v2 in pairs(v) do i[k2] = v2 end
      o[k] = i
    else
      o[k] = v
    end
  end
  return o
end

local function safeAmbiguate(name) return Ambiguate and Ambiguate(name, "none") or name end

-- Strip UI escapes from chat; optionally keep {rt#} tokens so icons render in chat
local function toChatSafe(s, keepRaidTokens)
  if type(s) ~= "string" then s = tostring(s or "") end
  s = s:gsub("|T.-|t", "")
       :gsub("|H.-|h(.-)|h", "%1")
       :gsub("|c%x%x%x%x%x%x%x%x", "")
       :gsub("|r", "")
  if not keepRaidTokens then s = s:gsub("{rt[1-8]}", "") end
  s = s:gsub("|", "")
  return s
end

-- ============================ Roster ==============================
local function classIsWarlock(unit) local _, c = UnitClass(unit); return c == "WARLOCK" end

local function eachOnlineGroupMember(cb)
  local counted = 0
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local u = "raid" .. i
      if UnitExists(u) then
        local n, online = UnitName(u), UnitIsConnected(u)
        debugf("RAID slot %d: exists=%s online=%s name=%s", i, tostring(UnitExists(u)), tostring(online), tostring(n))
        if online and n and not UnitIsUnit(u, "player") then counted = counted + 1; cb(n, u) end
      end
    end
  elseif IsInGroup() then
    for i = 1, GetNumGroupMembers() do
      local u = "party" .. i
      if UnitExists(u) then
        local n, online = UnitName(u), UnitIsConnected(u)
        debugf("PARTY slot %d: exists=%s online=%s name=%s", i, tostring(UnitExists(u)), tostring(online), tostring(n))
        if online and n then counted = counted + 1; cb(n, u) end
      end
    end
  end
  debugf("eachOnlineGroupMember total=%d", counted)
end

local function playerListWarlocks()
  local names = {}
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local u = "raid" .. i
      if UnitExists(u) and UnitIsPlayer(u) and classIsWarlock(u) then local n = UnitName(u); if n then names[#names+1] = n end end
    end
  elseif IsInGroup() then
    for i = 1, GetNumGroupMembers() do
      local u = "party" .. i
      if UnitExists(u) and UnitIsPlayer(u) and classIsWarlock(u) then local n = UnitName(u); if n then names[#names+1] = n end end
    end
    if classIsWarlock("player") then names[#names+1] = UnitName("player") end
  else
    if classIsWarlock("player") then names[#names+1] = UnitName("player") end
  end
  if (#names == 0) and Addon.ui and Addon.ui.rows then for name,_ in pairs(Addon.ui.rows) do names[#names+1] = name end end
  table.sort(names, function(a,b) return (a or "") < (b or "") end)
  return names
end

-- ===================== Assignment model ==========================
local CURSE_CHOICES = {
  NONE = "-",
  COE  = "Curse of Elements",
  COS  = "Curse of Shadow",
  COR  = "Curse of Recklessness",
  COW  = "Curse of Weakness",
  COA  = "Curse of Agony",
  COD  = "Curse of Doom",
  COT  = "Curse of Tongues",
}

-- UI labels with icons (for dropdowns)
local BANISH_CHOICES = {
  NONE = "-",
  RT1  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t Star",
  RT2  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_2:0|t Circle",
  RT3  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_3:0|t Diamond",
  RT4  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_4:0|t Triangle",
  RT5  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_5:0|t Moon",
  RT6  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_6:0|t Square",
  RT7  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_7:0|t Cross",
  RT8  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:0|t Skull",
}
-- Plain names for chat output
local BANISH_NAMES = {
  NONE = "-",
  RT1  = "Star",
  RT2  = "Circle",
  RT3  = "Diamond",
  RT4  = "Triangle",
  RT5  = "Moon",
  RT6  = "Square",
  RT7  = "Cross",
  RT8  = "Skull",
}
-- Raid token strings for chat icons
local BANISH_TOKENS = {
  NONE = "",
  RT1  = "{rt1}",
  RT2  = "{rt2}",
  RT3  = "{rt3}",
  RT4  = "{rt4}",
  RT5  = "{rt5}",
  RT6  = "{rt6}",
  RT7  = "{rt7}",
  RT8  = "{rt8}",
}

local function getAssignment(name)
  local a = Addon.db.profile.assignments[name]
  if not a then a = { curse = "NONE", banish = "NONE" }; Addon.db.profile.assignments[name] = a end
  return a
end

local function setAssignment(name, curseKey, banishKey)
  local a = getAssignment(name)
  if curseKey  then a.curse  = curseKey  end
  if banishKey then a.banish = banishKey end
end

local function clearAssignments() Addon.db.profile.assignments = {} end

-- ============================== Sync (AceComm) ==============================
function Addon:OnCommReceived(prefix, message, distribution, sender)
  if prefix ~= COMM_PREFIX then return end
  local me   = safeAmbiguate(UnitName("player"))
  local from = safeAmbiguate(sender or "")
  debugf("OnCommReceived: from=%s dist=%s bytes=%d", from, tostring(distribution), type(message)=="string" and #message or 0)
  if from == me then return end

  local ok, decoded = AceSerializer:Deserialize(message)
  if not ok or type(decoded) ~= "table" then debugf("Deserialize FAILED from %s", from); return end

  local incomingT = tonumber(decoded.t) or 0
  if incomingT <= (Addon._lastSync or 0) then debugf("Ignored older/equal sync from %s (t=%s <= %s).", from, tostring(incomingT), tostring(Addon._lastSync or 0)); return end
  Addon._lastSync = incomingT

  if decoded.op == "set" and type(decoded.name) == "string" then
    local a = getAssignment(decoded.name)
    if decoded.curse  then a.curse  = decoded.curse  end
    if decoded.banish then a.banish = decoded.banish end
    debugf("Applied %s update from %s for %s.", decoded.curse and "curse" or "banish", from, decoded.name)
    if Addon.RebuildRows then Addon:RebuildRows() end
    return
  end

  if decoded.op == "full" and type(decoded.data) == "table" then
    Addon.db.profile.assignments = shallowCopy(decoded.data)
    debugf("Applied full table from %s.", from)
    if Addon.RebuildRows then Addon:RebuildRows() end
    return
  end
end

Addon:RegisterComm(COMM_PREFIX)

local function sendComm(distribution, serialized, target)
  local size = (type(serialized) == "string") and #serialized or 0
  if type(serialized) ~= "string" or size == 0 then
    debugf("SendCommMessage aborted: bad serialized payload (dist=%s, target=%s)", tostring(distribution), tostring(target))
    return false
  end
  if target then
    debugf("SendCommMessage → %s WHISPER %s (%d bytes)", COMM_PREFIX, tostring(target), size)
    local ok, err = pcall(function() Addon:SendCommMessage(COMM_PREFIX, serialized, distribution, target, "NORMAL") end)
    if not ok then debugf("SendCommMessage WHISPER error: %s", tostring(err)); return false end
  else
    debugf("SendCommMessage → %s %s (%d bytes)", COMM_PREFIX, tostring(distribution), size)
    local ok, err = pcall(function() Addon:SendCommMessage(COMM_PREFIX, serialized, distribution, nil, "NORMAL") end)
    if not ok then debugf("SendCommMessage %s error: %s", tostring(distribution), tostring(err)); return false end
  end
  return true
end

local function broadcastPayload(payload, reason)
  debugf("Serialize payload (%s): op=%s", reason or "update", tostring(payload.op))
  local serialized = AceSerializer:Serialize(payload)
  if type(serialized) ~= "string" or #serialized == 0 then debugf("Serialize FAILED (type=%s)", type(serialized)); return end

  Addon._lastSync = payload.t

  local inRaid, inGroup, members = IsInRaid(), IsInGroup(), GetNumGroupMembers()
  debugf("Group state: IsInRaid=%s IsInGroup=%s members=%s", tostring(inRaid), tostring(inGroup), tostring(members))

  local chan = inRaid and "RAID" or (inGroup and "PARTY" or nil)
  if chan then sendComm(chan, serialized); debugf("Broadcast (%s) via %s: requested", reason or "update", chan) else debugf("Broadcast (%s): not grouped, skipping PARTY/RAID.", reason or "update") end

  local targets = {}
  eachOnlineGroupMember(function(name)
    name = safeAmbiguate(name)
    if sendComm("WHISPER", serialized, name) then targets[#targets + 1] = name end
  end)
  if #targets > 0 then debugf("WHISPER fan-out: %s", table.concat(targets, ", ")) else debugf("WHISPER fan-out: no online party/raid targets") end
end

local function broadcastSet(name, field, key)
  local p = { t = now(), op = "set", name = name }; p[field] = key
  debugf("broadcastSet: name=%s field=%s key=%s", tostring(name), tostring(field), tostring(key))
  broadcastPayload(p, "set-" .. field)
end

local function broadcastFull(reason) debugf("broadcastFull: sending full table"); broadcastPayload({ t = now(), op = "full", data = Addon.db.profile.assignments }, reason or "full") end

-- =============================== UI =================================
Addon.ui = { frame = nil, rowsGroup = nil, rows = {} }

local function stripFrameBorders(frame)
  local regs = { frame:GetRegions() }
  for i = 1, #regs do
    local r = regs[i]
    if r and r.GetObjectType and r:GetObjectType() == "Texture" then
      r:SetTexture(nil); r:Hide()
    end
  end
end

local function ensureBackdrop(frame, alpha)
  if frame.__wcp_bg then frame.__wcp_bg:SetAlpha(alpha or 0.5); return end
  local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  bg:SetColorTexture(0, 0, 0, alpha or 0.5)
  bg:SetPoint("TOPLEFT", 8, -8); bg:SetPoint("BOTTOMRIGHT", -8, 8)
  frame.__wcp_bg = bg
  frame:HookScript("OnSizeChanged", function(self)
    if self.__wcp_bg then
      self.__wcp_bg:ClearAllPoints()
      self.__wcp_bg:SetPoint("TOPLEFT", 8, -8)
      self.__wcp_bg:SetPoint("BOTTOMRIGHT", -8, 8)
    end
  end)
end

local function makeHeader()
  local header = AceGUI:Create("SimpleGroup")
  header:SetFullWidth(true); header:SetHeight(28); header:SetLayout("Flow")

  local l1 = AceGUI:Create("Label"); l1:SetText("|cffffd100Warlock:|r"); l1:SetRelativeWidth(0.33); header:AddChild(l1)
  local l2 = AceGUI:Create("Label"); l2:SetText("|cffffd100Curse Assignment:|r"); l2:SetRelativeWidth(0.34); header:AddChild(l2)
  local l3 = AceGUI:Create("Label"); l3:SetText("|cffffd100Banish Assignment:|r"); l3:SetRelativeWidth(0.33); header:AddChild(l3)
  return header
end

-- ---------- Dropdown skinning (deep & first-click) ----------
local WHITE8 = "Interface\\Buttons\\WHITE8x8"

local function stripTexturesDeep(frame, depth)
  if not frame or depth <= 0 then return end
  local regs = { frame:GetRegions() }
  for i = 1, #regs do
    local r = regs[i]
    if r and r.GetObjectType and r:GetObjectType() == "Texture" then r:SetTexture(nil); r:Hide() end
  end
  if frame.DisableDrawLayer then pcall(frame.DisableDrawLayer, frame, "BORDER") end
  if frame.NineSlice then frame.NineSlice:Hide() end
  if frame.SetBackdrop then pcall(frame.SetBackdrop, frame, nil) end
  if frame.SetBackdropColor then pcall(frame.SetBackdropColor, frame, 0, 0, 0, 0) end
  if frame.SetBackdropBorderColor then pcall(frame.SetBackdropBorderColor, frame, 0, 0, 0, 0) end
  for _, child in ipairs({ frame:GetChildren() }) do stripTexturesDeep(child, depth - 1) end
end

local function applyFlatBG(frame, alpha, inset)
  if not frame then return end
  if frame.SetBackdrop then
    pcall(frame.SetBackdrop, frame, { bgFile = WHITE8, edgeFile = nil, tile = false, tileSize = 0, edgeSize = 0, insets = { left = 0, right = 0, top = 0, bottom = 0 } })
    pcall(frame.SetBackdropColor, frame, 0, 0, 0, alpha or 0.35)
    if frame.DisableDrawLayer then pcall(frame.DisableDrawLayer, frame, "BORDER") end
  else
    if not frame.__wcp_bg then
      local bg = frame:CreateTexture(nil, "BACKGROUND")
      bg:SetColorTexture(0, 0, 0, alpha or 0.35)
      inset = inset or 2
      bg:SetPoint("TOPLEFT", inset, -inset)
      bg:SetPoint("BOTTOMRIGHT", -inset, inset)
      frame.__wcp_bg = bg
    else
      frame.__wcp_bg:SetAlpha(alpha or 0.35)
    end
  end
end

local function skinPulloutFrame(pf)
  if not pf then return end
  stripTexturesDeep(pf, 3)
  applyFlatBG(pf, 0.45, 3)
  for _, child in ipairs({ pf:GetChildren() }) do
    stripTexturesDeep(child, 2)
    applyFlatBG(child, 0, 0) -- item rows transparent bg, no borders
  end
end

local function skinDropdown(widget)
  if not widget or not widget.frame then return end
  stripTexturesDeep(widget.frame, 2)
  applyFlatBG(widget.frame, 0.35, 2)

  if widget.button then
    stripTexturesDeep(widget.button, 2)
    applyFlatBG(widget.button, 0.25, 1)
    local hl = widget.button:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.08)
    widget.button:SetHighlightTexture(hl)
  end

  -- Hook pullout Open so first click is already skinned
  local function hookPulloutOpen()
    if widget.pullout and widget.pullout.Open and not widget.pullout.__wcp_hooked then
      widget.pullout.__wcp_hooked = true
      hooksecurefunc(widget.pullout, "Open", function(self) skinPulloutFrame(self.frame) end)
    end
  end
  hookPulloutOpen()

  local function flattenNow()
    hookPulloutOpen()
    if widget.pullout and widget.pullout.frame then skinPulloutFrame(widget.pullout.frame) end
  end

  if widget.button then
    widget.button:HookScript("OnClick", function()
      if C_Timer and C_Timer.After then C_Timer.After(0, flattenNow) else flattenNow() end
    end)
  end
  if widget.pullout and widget.pullout.frame and widget.pullout.frame:HasScript("OnShow") then
    widget.pullout.frame:HookScript("OnShow", flattenNow)
  end
end
-- -------------------------------------------------------

local function dropdownFromChoices(choices, initialKey, width, onChange)
  local d = AceGUI:Create("Dropdown")
  local list, order = {}, {}
  for k, t in pairs(choices) do list[k] = t; order[#order + 1] = k end
  table.sort(order, function(a, b) if a == "NONE" then return true elseif b == "NONE" then return false else return a < b end end)
  d:SetList(list, order); d:SetValue(initialKey or "NONE")
  if width then d:SetWidth(width) end
  if onChange then d:SetCallback("OnValueChanged", function(_, _, k) onChange(k) end) end
  skinDropdown(d)
  return d
end

-- Helper: add a frame to UISpecialFrames (Esc closes it) without duplicates
local function addToUISpecialFrames(frame)
  if not frame then return end
  local name = frame:GetName()
  if not name then return end
  for i = 1, #UISpecialFrames do if UISpecialFrames[i] == name then return end end
  table.insert(UISpecialFrames, name)
end

function Addon:BuildWindow()
  if self.ui.frame then return end
  local f = AceGUI:Create("Frame")
  f:SetTitle("Warlock Curse and Banish Assignments")
  f:SetWidth(self.db.profile.frame.width); f:SetHeight(self.db.profile.frame.height)
  f:SetLayout("List"); f:EnableResize(true)
  stripFrameBorders(f.frame); ensureBackdrop(f.frame, 0.5)

  -- ESC to close (robust) without blocking input
  addToUISpecialFrames(f.frame)
  f.frame:EnableKeyboard(true)
  if f.frame.SetPropagateKeyboardInput then f.frame:SetPropagateKeyboardInput(true) end  -- << allow WASD/chat while open
  f.frame:HookScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" then self:Hide() end
  end)

  f:SetCallback("OnClose", function(widget)
    self.db.profile.frame.width  = widget.frame:GetWidth()
    self.db.profile.frame.height = widget.frame:GetHeight()
    self.ui.frame, self.ui.rowsGroup = nil, nil
  end)

  local a = self.db.profile.frame
  f.frame:ClearAllPoints(); f.frame:SetPoint(a.point or "CENTER", UIParent, a.point or "CENTER", a.x or 0, a.y or 0)
  if f.frame.SetMinResize then f.frame:SetMinResize(680, 320) end
  f:SetCallback("OnDragStop", function(widget)
    local p, _, _, x, y = widget.frame:GetPoint(1)
    self.db.profile.frame.point = p; self.db.profile.frame.x = x; self.db.profile.frame.y = y
  end)

  -- Header + rows
  f:AddChild(makeHeader())
  local rows = AceGUI:Create("SimpleGroup"); rows:SetFullWidth(true); rows:SetLayout("List"); f:AddChild(rows)

  -- Bottom controls
  local bottomHolder = CreateFrame("Frame", nil, f.frame)
  bottomHolder:SetHeight(34)
  bottomHolder:SetPoint("BOTTOM", f.frame, "BOTTOM", 0, 42)
  bottomHolder:SetPoint("LEFT",  f.frame, "LEFT",  12, 0)
  bottomHolder:SetPoint("RIGHT", f.frame, "RIGHT", -12, 0)
  f.frame:HookScript("OnSizeChanged", function()
    bottomHolder:SetPoint("LEFT",  f.frame, "LEFT",  12, 0)
    bottomHolder:SetPoint("RIGHT", f.frame, "RIGHT", -12, 0)
  end)

  local bottom = AceGUI:Create("SimpleGroup")
  bottom:SetLayout("Flow"); bottom.frame:SetParent(bottomHolder); bottom.frame:SetAllPoints(); bottom:SetFullWidth(true)

  local spacerL = AceGUI:Create("Label"); spacerL:SetRelativeWidth(0.28); bottom:AddChild(spacerL)

  local notify = AceGUI:Create("Button"); notify:SetText("Notify"); notify:SetWidth(140)
  notify:SetCallback("OnClick", function() Addon:AnnounceAssignments() end); bottom:AddChild(notify)

  local gap = AceGUI:Create("Label"); gap:SetWidth(12); bottom:AddChild(gap)

  local clear = AceGUI:Create("Button"); clear:SetText("Clear"); clear:SetWidth(140)
  clear:SetCallback("OnClick", function() clearAssignments(); Addon:RebuildRows(); broadcastFull("clear") end); bottom:AddChild(clear)

  local gap2 = AceGUI:Create("Label"); gap2:SetWidth(16); bottom:AddChild(gap2)

  local dbg = AceGUI:Create("CheckBox"); dbg:SetLabel("Debug Mode"); dbg:SetWidth(140)
  dbg:SetValue(self.db.profile.debug)
  dbg:SetCallback("OnValueChanged", function(_, _, v) self.db.profile.debug = not not v; debugf("Debug Mode %s", v and "ON" or "OFF") end)
  bottom:AddChild(dbg)

  local spacerR = AceGUI:Create("Label"); spacerR:SetRelativeWidth(0.28); bottom:AddChild(spacerR)

  self.ui.frame = f; self.ui.rowsGroup = rows
  self:RebuildRows()
end

function Addon:ReleaseRows()
  if not self.ui.rowsGroup then return end
  self.ui.rowsGroup:ReleaseChildren()
  wipe(self.ui.rows)
end

function Addon:RebuildRows()
  if not self.ui.rowsGroup then return end
  self:ReleaseRows()
  for _, name in ipairs(playerListWarlocks()) do
    local row = AceGUI:Create("SimpleGroup"); row:SetFullWidth(true); row:SetLayout("Flow"); row:SetHeight(28)
    local nameLbl = AceGUI:Create("Label"); nameLbl:SetRelativeWidth(0.33); nameLbl:SetText(string.format("|cffffff00%s|r", name)); row:AddChild(nameLbl)
    local a = getAssignment(name)
    local curse = dropdownFromChoices(CURSE_CHOICES, a.curse, nil, function(newK) setAssignment(name, newK, nil); debugf("Set curse for %s -> %s", name, CURSE_CHOICES[newK] or newK); broadcastSet(name, "curse", newK) end); curse:SetRelativeWidth(0.34); row:AddChild(curse)
    local ban   = dropdownFromChoices(BANISH_CHOICES, a.banish, nil, function(newK) setAssignment(name, nil, newK); debugf("Set banish for %s -> %s", name, BANISH_NAMES[newK] or newK); broadcastSet(name, "banish", newK) end); ban:SetRelativeWidth(0.33); row:AddChild(ban)
    self.ui.rowsGroup:AddChild(row)
    self.ui.rows[name] = { group = row, nameLabel = nameLbl, curseDrop = curse, banishDrop = ban }
  end
end

-- ============================ Announce ===========================
local function pickChat() if IsInRaid() then return "RAID" elseif IsInGroup() then return "PARTY" else return "SAY" end end

function Addon:AnnounceAssignments()
  local wl = playerListWarlocks()
  debugf("Announce: warlocks found=%d", #wl)

  local chan = pickChat()
  SendChatMessage(toChatSafe("Warlock assignments:", true), chan)

  local lines = 0
  for _, name in ipairs(wl) do
    local a = getAssignment(name)
    local hasCurse  = a.curse  and a.curse  ~= "NONE"
    local hasBanish = a.banish and a.banish ~= "NONE"
    if hasCurse or hasBanish then
      local parts = { name }
      if hasCurse then parts[#parts+1] = CURSE_CHOICES[a.curse] or "-" end
      if hasBanish then
        local btok  = BANISH_TOKENS[a.banish] or ""
        local bname = BANISH_NAMES[a.banish]  or "-"
        parts[#parts+1] = ("Banish: %s %s"):format(btok, bname)
      end
      local msg = table.concat(parts, "  ")
      SendChatMessage(toChatSafe(msg, true), chan)
      lines = lines + 1
    end
  end

  if lines == 0 then debugf("Announce: no lines emitted (no active assignments).") end
end

-- ===================== Lifecycle & Diagnostics ===================
local ef = CreateFrame("Frame")
ef:RegisterEvent("PLAYER_LOGIN"); ef:RegisterEvent("GROUP_ROSTER_UPDATE"); ef:RegisterEvent("PLAYER_ROLES_ASSIGNED")
ef:SetScript("OnEvent", function(_, evt)
  if evt == "PLAYER_LOGIN" then Addon:RegisterComm(COMM_PREFIX); debugf("PLAYER_LOGIN: RegisterComm(%s) done", COMM_PREFIX)
  else if Addon.ui.frame then Addon:RebuildRows() end end
end)

-- Slash: /wcp (toggle) and /wcp test
SLASH_WCP1 = "/wcp"
SlashCmdList["WCP"] = function(msg)
  msg = msg and msg:lower() or ""
  if msg == "test" then
    local payload = { t = now(), op = "set", name = UnitName("player"), curse = "TEST" }
    debugf("Manual test: sending TEST payload"); broadcastPayload(payload, "manual-test"); return
  end
  if Addon.ui.frame then Addon.ui.frame:Hide(); Addon.ui.frame = nil else Addon:BuildWindow() end
end

-- =================== Compact Assignment Summary Window ===================
Addon.compactUI = { frame = nil }

-- Abbreviated curse icons (16x16) for compact display
local CURSE_ICONS = {
  COE = "Interface\\Icons\\Spell_Shadow_ChillTouch",           -- Curse of Elements
  COS = "Interface\\Icons\\Spell_Shadow_CurseOfAchimonde",     -- Curse of Shadow
  COR = "Interface\\Icons\\Spell_Shadow_UnholyStrength",       -- Curse of Recklessness
  COW = "Interface\\Icons\\Spell_Shadow_CurseOfMannoroth",     -- Curse of Weakness
  COA = 136139,         -- Curse of Agony
  COD = "Interface\\Icons\\Spell_Shadow_AuraOfDarkness",       -- Curse of Doom
  COT = "Interface\\Icons\\Spell_Shadow_CurseOfTounges",       -- Curse of Tongues
  NONE = nil,
}

local function getCurseIconOrAbbr(key)
  local icon = CURSE_ICONS[key]
  if icon then
    return "|T" .. icon .. ":16:16:0:0:64:64:4:60:4:60|t"
  end
  return key or "-"
end

local function getBanishIcon(key)
  local icons = {
    RT1  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:16|t",
    RT2  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_2:16|t",
    RT3  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_3:16|t",
    RT4  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_4:16|t",
    RT5  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_5:16|t",
    RT6  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_6:16|t",
    RT7  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_7:16|t",
    RT8  = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:16|t",
    NONE = "",
  }
  return icons[key] or ""
end

function Addon:ShowCompactWindow()
  if self.compactUI.frame then
    self.compactUI.frame:Show()
    self:UpdateCompactRows()
    return
  end

  local f = AceGUI:Create("Frame")
  f:SetTitle("WCP Assignments")
  f:SetWidth(220); f:SetHeight(180)
  f:SetLayout("List")
  f:EnableResize(false)
  stripFrameBorders(f.frame)
  ensureBackdrop(f.frame, 0.5) -- Match main window theme

  -- Do NOT close with ESC
  -- (Do not add to UISpecialFrames, do not hook OnKeyDown)

  -- Assignment rows
  local rows = AceGUI:Create("SimpleGroup")
  rows:SetFullWidth(true)
  rows:SetLayout("List")
  f:AddChild(rows)

  function Addon:UpdateCompactRows()
    rows:ReleaseChildren()
    for _, name in ipairs(playerListWarlocks()) do
      local a = getAssignment(name)
      local curseIcon = getCurseIconOrAbbr(a.curse)
      local curseText = CURSE_CHOICES[a.curse] or "-"
      local banishIcon = getBanishIcon(a.banish)
      local row = AceGUI:Create("InteractiveLabel")
      -- Show both icon and text for curse assignment
      row:SetText(string.format("|cffffff00%s|r  %s %s  %s", name, curseIcon, curseText, banishIcon))
      row:SetFullWidth(true)
      rows:AddChild(row)
    end
  end

  self.compactUI.frame = f
  self:UpdateCompactRows()
end

-- Show/hide compact window automatically based on assignments
local function hasAnyAssignments()
  for _, name in ipairs(playerListWarlocks()) do
    local a = getAssignment(name)
    if a and ((a.curse and a.curse ~= "NONE") or (a.banish and a.banish ~= "NONE")) then
      return true
    end
  end
  return false
end

function Addon:AutoCompactWindow()
  if hasAnyAssignments() then
    Addon:ShowCompactWindow()
  elseif self.compactUI.frame then
    self.compactUI.frame:Hide()
  end
end

-- Hook assignment changes to auto-show/hide compact window
hooksecurefunc(Addon, "RebuildRows", function(self)
  self:AutoCompactWindow()
end)

-- Remove broken hooksecurefunc for setAssignment (local function, not global)
-- Instead, update setAssignment to call AutoCompactWindow when changed:
local oldSetAssignment = setAssignment
setAssignment = function(name, curseKey, banishKey)
  local a = getAssignment(name)
  local changed = false
  if curseKey and a.curse ~= curseKey then a.curse = curseKey; changed = true end
  if banishKey and a.banish ~= banishKey then a.banish = banishKey; changed = true end
  if changed then Addon:AutoCompactWindow() end
end

-- Also check on login and group changes
local ef2 = CreateFrame("Frame")
ef2:RegisterEvent("PLAYER_LOGIN")
ef2:RegisterEvent("GROUP_ROSTER_UPDATE")
ef2:RegisterEvent("PLAYER_ROLES_ASSIGNED")
ef2:SetScript("OnEvent", function(_, evt)
  if evt == "PLAYER_LOGIN" or evt == "GROUP_ROSTER_UPDATE" or evt == "PLAYER_ROLES_ASSIGNED" then
    Addon:AutoCompactWindow()
  end
  if evt == "PLAYER_LOGIN" then
    Addon:RegisterComm(COMM_PREFIX)
    debugf("PLAYER_LOGIN: RegisterComm(%s) done", COMM_PREFIX)
  else
    if Addon.ui.frame then Addon:RebuildRows() end
  end
end)

-- Slash command to toggle compact window
SLASH_WCPSUMMARY1 = "/wcpsummary"
SlashCmdList["WCPSUMMARY"] = function()
  if Addon.compactUI.frame and Addon.compactUI.frame:IsShown() then
    Addon.compactUI.frame:Hide()
  else
    Addon:ShowCompactWindow()
  end
end

if not AceGUI or not AceSerializer or not AceDB or not AceComm then
  print("|cffff0000[WCP]|r Missing required libraries. Check your installation.")
end