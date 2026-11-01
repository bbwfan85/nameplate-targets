local ADDON, ns = ...

local PT = CreateFrame("Frame")
ns.PT = PT

---------------------------------------------------------------------------
-- Defaults
---------------------------------------------------------------------------
ns.defaults = {
	enabled        = true,
	font           = "Friz Quadrata TT",
	fontSize       = 12,
	outline        = "OUTLINE",      -- NONE, OUTLINE, THICKOUTLINE
	shadow         = false,
	position       = "BELOW",        -- BELOW or ABOVE the health bar
	offsetX        = 0,
	offsetY        = -2,
	anchorMode     = "AUTO",         -- AUTO (find health bar) or PLATE (raw nameplate frame)
	format         = "> NAME <",     -- NAME is replaced by the target's name
	nameMode       = "FIRST",        -- FIRST (first name only) or FULL (with surname / realm)
	factionIcon    = true,           -- Horde/Alliance icon before player names
	factionIconSize = 0,             -- 0 = match text height
	youMode        = "TEXT",         -- TEXT (custom text) or NAME (your own name)
	youText        = ">> YOU <<",
	youColor       = { r = 1, g = 0.2, b = 0.2 },
	youUseColor    = true,
	showNPCTargets = true,
	npcColor       = { r = 1, g = 1, b = 1 },
	showEnemy      = true,
	showFriendly   = true,
}

---------------------------------------------------------------------------
-- Fonts (built-ins, plus anything registered with LibSharedMedia)
---------------------------------------------------------------------------
local BUILTIN_FONTS = {
	["Friz Quadrata TT"] = "Fonts\\FRIZQT__.TTF",
	["Arial Narrow"]     = "Fonts\\ARIALN.TTF",
	["Morpheus"]         = "Fonts\\MORPHEUS.TTF",
	["Skurri"]           = "Fonts\\SKURRI.TTF",
}

local function GetLSM()
	return LibStub and LibStub("LibSharedMedia-3.0", true)
end

function ns.GetFontList()
	local list, seen = {}, {}
	for name in pairs(BUILTIN_FONTS) do
		list[#list + 1] = name
		seen[name] = true
	end
	local LSM = GetLSM()
	if LSM then
		for _, name in ipairs(LSM:List("font")) do
			if not seen[name] then list[#list + 1] = name end
		end
	end
	table.sort(list)
	return list
end

local function GetFontPath(name)
	local LSM = GetLSM()
	local path = LSM and LSM:Fetch("font", name, true)
	return path or BUILTIN_FONTS[name] or STANDARD_TEXT_FONT
end

---------------------------------------------------------------------------
-- Secret-value helpers (Midnight / Forever API can hide some unit info
-- in restricted content; never branch on or index with a secret value)
---------------------------------------------------------------------------
local function IsSecret(v)
	return issecretvalue and issecretvalue(v) or false
end

-- Returns true / false, or nil when the answer is unknown (secret or error).
local function SafeBool(fn, ...)
	local ok, v = pcall(fn, ...)
	if not ok or IsSecret(v) then return nil end
	return v and true or false
end

---------------------------------------------------------------------------
-- Per-plate text holders
---------------------------------------------------------------------------
local holders = setmetatable({}, { __mode = "k" }) -- plate frame -> holder
local active = {}                                  -- unit token -> holder
local testMode = false

local fmtPrefix, fmtSuffix = "", ""

local function ParseFormat()
	local fmt = PT.db.format or ""
	local s, e = string.find(fmt, "NAME", 1, true)
	if s then
		fmtPrefix, fmtSuffix = fmt:sub(1, s - 1), fmt:sub(e + 1)
	else
		fmtPrefix, fmtSuffix = "", ""
	end
end

local function StyleFontString(fs)
	local db = PT.db
	local flags = db.outline ~= "NONE" and db.outline or ""
	if not fs:SetFont(GetFontPath(db.font), db.fontSize, flags) then
		fs:SetFont(STANDARD_TEXT_FONT, db.fontSize, flags)
	end
	if db.shadow then
		fs:SetShadowColor(0, 0, 0, 1)
		fs:SetShadowOffset(1, -1)
	else
		fs:SetShadowOffset(0, 0)
	end
end

local function ApplyFont(h)
	StyleFontString(h.text)
	StyleFontString(h.you)
end

local function GetHolder(plate)
	local h = holders[plate]
	if not h then
		h = CreateFrame("Frame", nil, plate)
		h:SetSize(1, 1)
		-- h.text shows the target's name; h.you shows the "targeting you" text.
		-- Two strings let a secret UnitIsUnit result pick between them via
		-- SetAlphaFromBoolean without the addon ever reading the value.
		h.text = h:CreateFontString(nil, "OVERLAY")
		h.text:SetWordWrap(false)
		h.you = h:CreateFontString(nil, "OVERLAY")
		h.you:SetWordWrap(false)
		holders[plate] = h
		ApplyFont(h)
	end
	return h
end

---------------------------------------------------------------------------
-- Anchor detection: Blizzard, ElvUI, EllesmereUI and other custom plates
---------------------------------------------------------------------------
-- Other addons may drive their frames with secret alpha/shown states; treat
-- anything we can't read as visible rather than erroring on the comparison.
local function Visible(f)
	if not f then return false end
	local ok, shown, alpha = pcall(function() return f:IsShown(), f:GetAlpha() end)
	if not ok then return false end
	if IsSecret(shown) or IsSecret(alpha) then return true end
	return shown and alpha > 0.01
end

local HEALTH_KEYS = { "Health", "health", "healthBar", "HealthBar", "healthbar", "HP", "hp" }

local function HealthFromKeys(frame)
	for _, key in ipairs(HEALTH_KEYS) do
		local bar = frame[key]
		if type(bar) == "table" and bar.IsObjectType and bar:IsObjectType("Frame") and Visible(bar) then
			return bar
		end
	end
	local hc = frame.HealthBarsContainer
	if type(hc) == "table" and hc.healthBar then return hc.healthBar end
end

-- Topmost visible StatusBar under a frame (health bars sit above cast bars).
local function FindStatusBar(frame, depth, best)
	if depth > 3 then return best end
	for _, child in ipairs({ frame:GetChildren() }) do
		if not child:IsForbidden() and Visible(child) then
			if child:IsObjectType("StatusBar") then
				local top, bestTop = child:GetTop(), best and best:GetTop()
				if top and not IsSecret(top) and (not bestTop or top > bestTop) then best = child end
			end
			best = FindStatusBar(child, depth + 1, best)
		end
	end
	return best
end

-- Returns the region to attach to, plus a short label for /ptarget debug.
local function ResolveAnchor(plate)
	if PT.db.anchorMode == "PLATE" then return plate, "nameplate frame (forced)" end

	-- ElvUI (oUF) plates live on plate.unitFrame
	local elv = plate.unitFrame
	if type(elv) == "table" and elv ~= plate.UnitFrame and Visible(elv) then
		local bar = HealthFromKeys(elv)
		if bar then return bar, "ElvUI health bar" end
	end

	-- Any other addon frame parented to the plate (EllesmereUI, Plater, ...)
	local blizz = plate.UnitFrame
	for _, child in ipairs({ plate:GetChildren() }) do
		if child ~= blizz and child ~= holders[plate] and not child:IsForbidden() and Visible(child) then
			local bar = HealthFromKeys(child) or FindStatusBar(child, 1)
			if bar then return bar, "addon health bar (" .. (child:GetName() or "unnamed") .. ")" end
		end
	end

	-- Default Blizzard plate
	if Visible(blizz) then
		local bar = HealthFromKeys(blizz)
		if bar then return bar, "Blizzard health bar" end
		return blizz, "Blizzard unit frame"
	end

	return plate, "nameplate frame (fallback)"
end

local function Anchor(h, plate)
	local anchor, kind = ResolveAnchor(plate)
	local db = PT.db
	h.anchorKind = kind
	h:ClearAllPoints()
	h:SetAllPoints(anchor)
	h:SetFrameStrata(anchor:GetFrameStrata())
	h:SetFrameLevel(anchor:GetFrameLevel() + 10)
	for _, fs in ipairs({ h.text, h.you }) do
		fs:ClearAllPoints()
		if db.position == "ABOVE" then
			fs:SetPoint("BOTTOM", h, "TOP", db.offsetX, db.offsetY)
		else
			fs:SetPoint("TOP", h, "BOTTOM", db.offsetX, db.offsetY)
		end
	end
end

---------------------------------------------------------------------------
-- Text update
---------------------------------------------------------------------------
local function ClassColor(unit)
	local ok, _, class = pcall(UnitClass, unit)
	if ok and not IsSecret(class) and class then
		local c = (C_ClassColor and C_ClassColor.GetClassColor(class)) or RAID_CLASS_COLORS[class]
		if c then return c.r, c.g, c.b end
	end
	return 1, 1, 1
end

local FACTION_ICONS = {
	Horde    = "Interface\\FriendsFrame\\PlusManz-Horde",
	Alliance = "Interface\\FriendsFrame\\PlusManz-Alliance",
}

-- Inline texture for the unit's faction, or "" (neutral, unknown, disabled).
local function FactionIcon(unit)
	if not PT.db.factionIcon then return "" end
	local ok, faction = pcall(UnitFactionGroup, unit)
	if not ok or IsSecret(faction) or not FACTION_ICONS[faction] then return "" end
	local size = PT.db.factionIconSize -- 0 = match text height
	return ("|T%s:%d:%d|t "):format(FACTION_ICONS[faction], size, size)
end

-- Forever replaces realm suffixes with surnames ("First Last"); retail
-- still has realms ("Name-Realm").
local function NameSeparator()
	local flag = RegionalUniqueNamesEnabled
	local ok, unique = pcall(function()
		if type(flag) == "function" then return flag() end
		return flag
	end)
	-- Unknown (flag missing on older builds): assume a surname-style space.
	return (ok and unique == false) and "-" or " "
end

-- UnitName returns first name, then surname (Forever) or realm (retail).
-- Either may be secret, so only string.format touches them.
local function GetDisplayName(unit)
	local ok, first, last = pcall(UnitName, unit)
	if not ok then return end
	if PT.db.nameMode ~= "FULL" then return first end
	local okCheck, hasLast = pcall(function() return last ~= nil and last ~= "" end)
	if okCheck and not hasLast then return first end
	local okFull, full = pcall(string.format, "%s%s%s", first, NameSeparator(), last)
	return okFull and full or first
end

local function SetName(h, name, icon)
	-- `..` is not allowed on secret strings, but string.format is (it returns
	-- a secret string that SetText can still display).
	local ok = pcall(function()
		h.text:SetText(string.format("%s%s%s%s", fmtPrefix, icon or "", name, fmtSuffix))
	end)
	if not ok then pcall(h.text.SetText, h.text, name) end
end

local function StyleYou(h)
	local db = PT.db
	h.you:SetText(db.youText)
	local c = db.youUseColor and db.youColor
	if c then h.you:SetTextColor(c.r, c.g, c.b) else h.you:SetTextColor(ClassColor("player")) end
end

-- isYou is true, false, or a secret boolean we may not read.
local function ShowYou(h, isYou)
	if IsSecret(isYou) then
		h.text:Show()
		h.you:Show()
		local ok1 = pcall(h.you.SetAlphaFromBoolean, h.you, isYou, 1, 0)
		local ok2 = pcall(h.text.SetAlphaFromBoolean, h.text, isYou, 0, 1)
		if ok1 and ok2 then return end
		isYou = false -- API missing: just show the name
	end
	h.text:SetAlpha(1)
	h.you:SetAlpha(1)
	h.text:SetShown(not isYou)
	h.you:SetShown(isYou and true or false)
end

local function UpdateTest(h, index)
	StyleYou(h)
	SetName(h, GetDisplayName("player"), FactionIcon("player"))
	h.text:SetTextColor(ClassColor("player"))
	ShowYou(h, index % 2 == 0 and PT.db.youMode == "TEXT")
	h:Show()
end

local function UpdateUnit(unit)
	local h = active[unit]
	if not h then return end
	local db = PT.db

	if not db.enabled or (h.friendly == true and not db.showFriendly) or (h.friendly == false and not db.showEnemy) then
		h:Hide()
		return
	end

	if testMode then
		UpdateTest(h, tonumber(unit:match("%d+")) or 1)
		return
	end

	local tunit = unit .. "target"
	if SafeBool(UnitExists, tunit) == false then
		h:Hide()
		return
	end

	local isPlayer = SafeBool(UnitIsPlayer, tunit)
	if isPlayer == false and not db.showNPCTargets then
		h:Hide()
		return
	end

	local name = GetDisplayName(tunit)
	if not IsSecret(name) and not name then
		h:Hide()
		return
	end

	SetName(h, name, isPlayer ~= false and FactionIcon(tunit) or "")
	if isPlayer == false then
		local c = db.npcColor
		h.text:SetTextColor(c.r, c.g, c.b)
	else
		h.text:SetTextColor(ClassColor(tunit))
	end

	-- UnitIsUnit on "nameplateNtarget" can come back secret in restricted
	-- content; ShowYou handles that without reading it.
	local isYou = false
	if db.youMode == "TEXT" then
		local okYou, v = pcall(UnitIsUnit, tunit, "player")
		if okYou then isYou = v end
		StyleYou(h)
	end
	ShowYou(h, isYou)
	h:Show()
end

function PT:UpdateAll()
	for unit in pairs(active) do UpdateUnit(unit) end
end

-- Re-apply font/anchor after a setting changes.
function PT:Refresh()
	ParseFormat()
	for unit, h in pairs(active) do
		ApplyFont(h)
		local plate = C_NamePlate.GetNamePlateForUnit(unit)
		if plate then Anchor(h, plate) end
	end
	self:UpdateAll()
end

function PT:SetTestMode(on)
	testMode = on
	self:UpdateAll()
end

function PT:IsTestMode() return testMode end

---------------------------------------------------------------------------
-- Nameplate lifecycle
---------------------------------------------------------------------------
local function OnPlateAdded(unit)
	local plate = C_NamePlate.GetNamePlateForUnit(unit)
	if not plate or plate:IsForbidden() then return end
	local h = GetHolder(plate)
	h.friendly = SafeBool(UnitIsFriend, "player", unit)
	active[unit] = h
	Anchor(h, plate)
	UpdateUnit(unit)
	-- Custom nameplate addons often build their frame on this same event;
	-- re-anchor next frame so we pick up their health bar.
	C_Timer.After(0, function()
		if active[unit] == h and plate:IsShown() then
			Anchor(h, plate)
			UpdateUnit(unit)
		end
	end)
end

local function OnPlateRemoved(unit)
	local h = active[unit]
	if h then
		h:Hide()
		active[unit] = nil
	end
end

PT:SetScript("OnEvent", function(self, event, arg1)
	if event == "UNIT_TARGET" then
		if active[arg1] then UpdateUnit(arg1) end
	elseif event == "NAME_PLATE_UNIT_ADDED" then
		OnPlateAdded(arg1)
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		OnPlateRemoved(arg1)
	elseif event == "ADDON_LOADED" and arg1 == ADDON then
		PlateTargetDB = PlateTargetDB or {}
		for k, v in pairs(ns.defaults) do
			if PlateTargetDB[k] == nil then
				PlateTargetDB[k] = type(v) == "table" and CopyTable(v) or v
			end
		end
		self.db = PlateTargetDB
		ParseFormat()
		self:RegisterEvent("NAME_PLATE_UNIT_ADDED")
		self:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
		self:RegisterEvent("UNIT_TARGET")
		-- NPCs don't always fire UNIT_TARGET when swapping; poll lightly as backup.
		C_Timer.NewTicker(0.15, function() self:UpdateAll() end)
		if ns.CreateOptions then ns.CreateOptions() end
		self:UnregisterEvent("ADDON_LOADED")
	end
end)
PT:RegisterEvent("ADDON_LOADED")

-- /ptarget debug: report which APIs this client has and what your current
-- target's nameplate looks like, so problems on Forever are easy to diagnose.
function PT:Debug()
	local function Say(...) print("|cff33ff99PlateTarget|r", ...) end
	local version, build, _, iface = GetBuildInfo()
	Say(("client %s (%s), interface %s"):format(version, build, tostring(iface)))
	Say("secret values API:", issecretvalue and "yes" or "no",
		"| SetAlphaFromBoolean:", (UIParent.SetAlphaFromBoolean and "yes" or "no"),
		"| Settings panel:", (Settings and Settings.RegisterCanvasLayoutCategory) and "yes" or "no")

	local plate = C_NamePlate.GetNamePlateForUnit("target")
	if not plate then
		Say("target something with a visible nameplate for plate details.")
		return
	end
	local unit
	for u, h in pairs(active) do
		if holders[plate] == h then unit = u end
	end
	local _, kind = ResolveAnchor(plate)
	Say("target plate:", unit or "untracked", "| anchored to:", kind)
	if unit then
		local tunit = unit .. "target"
		local _, name = pcall(UnitName, tunit)
		local _, isYou = pcall(UnitIsUnit, tunit, "player")
		local _, _, class = pcall(UnitClass, tunit)
		Say("its target's name secret:", IsSecret(name) and "yes" or "no",
			"| class secret:", IsSecret(class) and "yes" or "no",
			"| is-you secret:", IsSecret(isYou) and "yes" or "no")
	end
end

function PT:ResetDefaults()
	wipe(self.db)
	for k, v in pairs(ns.defaults) do
		self.db[k] = type(v) == "table" and CopyTable(v) or v
	end
	self:Refresh()
end
