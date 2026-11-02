local ADDON, ns = ...

local PT = CreateFrame("Frame")
ns.PT = PT

---------------------------------------------------------------------------
-- Defaults
---------------------------------------------------------------------------
ns.defaults = {
	enabled        = true,
	font           = "Friz Quadrata TT",
	fontSize       = 16,
	outline        = "OUTLINE",      -- NONE, OUTLINE, THICKOUTLINE
	shadow         = true,
	position       = "BELOW",        -- BELOW or ABOVE the health bar
	offsetX        = 0,
	offsetY        = -2,
	anchorMode     = "AUTO",         -- AUTO (find health bar) or PLATE (raw nameplate frame)
	avoidBars      = true,           -- move past cast/power bars on the same side
	smoothStack    = true,           -- slide instead of snapping when they appear
	format         = "> NAME <",     -- NAME is replaced by the target's name
	nameMode       = "FIRST",        -- FIRST (first name only) or FULL (with surname / realm)
	factionIcon    = true,           -- Horde/Alliance icon before player names
	factionIconSize = 0,             -- 0 = match text height
	factionOnlyEnemy = true,         -- icon only for the opposite faction
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
		h.strings = { h.text, h.you }
		-- Recheck the anchor as soon as we're shown again (see AnchorStale).
		h:SetScript("OnShow", function(self) self.recheckIn = 0 end)
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

-- First visible StatusBar under a frame. Midnight forbids measuring
-- nameplate regions, so we can't compare positions to pick the top one.
local function FindStatusBar(frame, depth)
	if depth > 3 then return end
	for _, child in ipairs({ frame:GetChildren() }) do
		if not child:IsForbidden() and Visible(child) then
			if child:IsObjectType("StatusBar") then return child end
			local bar = FindStatusBar(child, depth + 1)
			if bar then return bar end
		end
	end
end

-- Returns the region to attach to, a short label for /ptarget debug, and
-- whether it's only a fallback (no health bar found yet).
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
		return blizz, "Blizzard unit frame", true
	end

	return plate, "nameplate frame (fallback)", true
end

---------------------------------------------------------------------------
-- Bar stacking: when a cast bar shows up on the same side of the health bar
-- as the text, slide the text past it.
--
-- Midnight forbids measuring nameplate regions (GetTop/GetBottom/... throw
-- "Can't measure restricted regions"), so this never reads screen positions.
-- It finds cast bars by the names nameplate addons give them, and works out
-- the distance from the bar's own height plus how it's attached.
---------------------------------------------------------------------------
-- EllesmereUI: plate.cast | ElvUI: unitFrame.Castbar
local CAST_KEYS = { "cast", "castBar", "castbar", "Castbar", "CastBar" }

-- Each tracked cast bar is { show = frame whose visibility means "casting",
-- size = frame whose height is the space taken, gap = space between it and
-- the health bar }.
local function FindCastBars(anchor, plate)
	local bars, seen = {}, {}
	if anchor == plate then return bars end
	local owner = anchor:GetParent()
	for _ = 1, 2 do
		if not owner or owner == plate then break end
		-- Default UI: UnitFrame.CastBarsContainer holds the bar plus the spell
		-- name line under it, and sits castBarToHealthBarSpacing below health.
		local container = owner.CastBarsContainer
		if type(container) == "table" and type(container.castBar) == "table" and not seen[container.castBar] then
			local opts = NamePlateSetupOptions
			local gap = type(opts) == "table" and tonumber(opts.castBarToHealthBarSpacing) or 0
			bars[#bars + 1] = { show = container.castBar, size = container, gap = gap }
			seen[container.castBar] = true
		end
		for _, key in ipairs(CAST_KEYS) do
			local bar = owner[key]
			if type(bar) == "table" and bar ~= anchor and not seen[bar]
				and bar.IsObjectType and bar:IsObjectType("Frame") then
				bars[#bars + 1] = { show = bar, size = bar, gap = 0 }
				seen[bar] = true
			end
		end
		owner = owner:GetParent()
	end
	return bars
end

local function Readable(v)
	return v ~= nil and not IsSecret(v)
end

-- Whether a cast bar is currently drawn (cast bars fade out before hiding).
local function BarShowing(entry)
	local bar = entry.show
	local shown = bar:IsVisible()
	if not Readable(shown) or not shown then return false end
	local alpha = bar.GetEffectiveAlpha and bar:GetEffectiveAlpha() or bar:GetAlpha()
	return Readable(alpha) and alpha > 0.05
end

-- Distance (in the holder's units) the text must move to clear a cast bar,
-- or nil when the text is above the health bar. Midnight forbids measuring
-- nameplate regions (positions and GetPoint), so cast bars are assumed to
-- hang under the health bar, as they do in EllesmereUI, ElvUI and the
-- default UI; only size and scale are read.
local function ClearanceFor(h, entry, below)
	if not below then return end
	local frame = entry.size
	local height = frame:GetHeight()
	if not Readable(height) then return end
	local barScale, ourScale = frame:GetEffectiveScale(), h:GetEffectiveScale()
	local ratio = (Readable(barScale) and Readable(ourScale) and ourScale > 0) and barScale / ourScale or 1
	return math.max(0, height + entry.gap) * ratio
end

-- Extra distance needed to clear whichever tracked cast bars are showing.
local function StackOffset(h)
	if not PT.db.avoidBars or not h.bars then return 0 end
	local below = PT.db.position ~= "ABOVE"
	local extra = 0
	for _, entry in ipairs(h.bars) do
		if BarShowing(entry) then
			local need = ClearanceFor(h, entry, below)
			if need and need > extra then extra = need end
		end
	end
	return extra
end

local function PlaceText(h, extra)
	local db = PT.db
	for _, fs in ipairs(h.strings) do
		fs:ClearAllPoints()
		if db.position == "ABOVE" then
			fs:SetPoint("BOTTOM", h, "TOP", db.offsetX, db.offsetY + extra)
		else
			fs:SetPoint("TOP", h, "BOTTOM", db.offsetX, db.offsetY - extra)
		end
	end
end

local STACK_POLL = 0.05  -- seconds between bar checks
local STACK_SPEED = 18   -- higher = faster slide
local ANCHOR_RECHECK = 0.25 -- seconds between anchor sanity checks

local function IsUnder(f, ancestor)
	while f do
		if f == ancestor then return true end
		f = f:GetParent()
	end
	return false
end

local Anchor

-- Custom plates (EllesmereUI queues its frame) can attach after we first
-- anchor, and pooled frames get handed to other units. Re-anchor if we only
-- found a fallback, or our anchor left this plate or went invisible.
local function AnchorStale(h)
	return h.fallback or not IsUnder(h.anchor, h.plate) or not Visible(h.anchor)
end

-- Run fn, keeping the text working if the client rejects a frame query
-- (Midnight restrictions); the error is kept for /ptarget debug.
local function Guarded(h, fn, ...)
	local ok, result = pcall(fn, ...)
	if ok then return result end
	h.lastError = tostring(result)
end

-- Stack offset, or 0 when it can't be worked out.
local function SafeStackOffset(h)
	local v = Guarded(h, StackOffset, h)
	if type(v) ~= "number" or IsSecret(v) then return 0 end
	return v
end

local function Recheck(h)
	if AnchorStale(h) then
		Anchor(h, h.plate)
	else
		-- Bars can be added after we anchor (lazily built cast bars).
		h.bars = FindCastBars(h.anchor, h.plate)
	end
end

local function StackOnUpdate(h, elapsed)
	h.recheckIn = (h.recheckIn or 0) - elapsed
	if h.recheckIn <= 0 then
		h.recheckIn = ANCHOR_RECHECK
		if h.plate then Guarded(h, Recheck, h) end
	end
	h.pollIn = (h.pollIn or 0) - elapsed
	if h.pollIn <= 0 then
		h.pollIn = STACK_POLL
		h.stackTarget = SafeStackOffset(h)
	end
	local target, cur = h.stackTarget or 0, h.stack or 0
	if cur == target then return end
	if PT.db.smoothStack then
		cur = cur + (target - cur) * math.min(1, elapsed * STACK_SPEED)
		if math.abs(target - cur) < 0.3 then cur = target end
	else
		cur = target
	end
	h.stack = cur
	PlaceText(h, cur)
end

function Anchor(h, plate)
	-- Install the updater first so a later failure can't stop rechecks.
	h:SetScript("OnUpdate", StackOnUpdate)
	local anchor, kind, fallback = ResolveAnchor(plate)
	h.anchorKind = kind
	h.anchor = anchor
	h.plate = plate
	h.fallback = fallback
	h:ClearAllPoints()
	h:SetAllPoints(anchor)
	h:SetFrameStrata(anchor:GetFrameStrata())
	h:SetFrameLevel(anchor:GetFrameLevel() + 10)
	-- Place the text before any bar math, so a failure there can't leave it
	-- without a position.
	h.stack = 0
	PlaceText(h, 0)
	h.bars = Guarded(h, FindCastBars, anchor, plate) or {}
	h.stackTarget = SafeStackOffset(h)
	h.stack = h.stackTarget -- snap on (re)anchor; only live changes slide
	PlaceText(h, h.stack)
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

-- Class-color a font string. In instances the class of "nameplateNtarget"
-- is secret: we can't index tables with it, but C_ClassColor may accept it
-- and hand back a color whose channels are secret, which SetTextColor can
-- still display. Returns how it was colored, for /ptarget debug.
local function ApplyClassColor(fs, unit)
	local ok, _, class = pcall(UnitClass, unit)
	if ok and not IsSecret(class) then
		fs:SetTextColor(ClassColor(unit))
		return "class"
	end
	if ok and C_ClassColor then
		local okC, c = pcall(C_ClassColor.GetClassColor, class)
		if okC and type(c) == "table" and pcall(fs.SetTextColor, fs, c.r, c.g, c.b) then
			return "secret class"
		end
	end
	fs:SetTextColor(1, 1, 1)
	return "white (class unavailable)"
end

-- Whether `unit`'s target is the player: true, false, or a secret boolean.
-- Comparing a chained token ("nameplate1target") to "player" can be blocked
-- in instances; then fall back to threat, whose isTanking is true when this
-- unit's main target is you.
local function TargetIsYou(unit, tunit)
	local ok, v = pcall(UnitIsUnit, tunit, "player")
	if ok and (IsSecret(v) or v ~= nil) then return v, "UnitIsUnit" end
	local okT, isTanking = pcall(UnitDetailedThreatSituation, "player", unit)
	if okT then
		if IsSecret(isTanking) then return isTanking, "threat" end
		return isTanking and true or false, "threat"
	end
	return false, "unavailable"
end

local FACTION_ICONS = {
	Horde    = "Interface\\FriendsFrame\\PlusManz-Horde",
	Alliance = "Interface\\FriendsFrame\\PlusManz-Alliance",
}

-- Inline texture for the unit's faction, or "" (neutral, unknown, disabled).
local OPPOSITE_FACTION = { Horde = "Alliance", Alliance = "Horde" }

local function IconFor(faction)
	local size = PT.db.factionIconSize -- 0 = match text height
	return ("|T%s:%d:%d|t "):format(FACTION_ICONS[faction], size, size)
end

local function FactionIcon(unit)
	if not PT.db.factionIcon then return "" end
	local ok, faction = pcall(UnitFactionGroup, unit)
	if not ok or IsSecret(faction) or not FACTION_ICONS[faction] then return "" end
	-- Same-faction targets are the norm, so by default only flag the other side.
	-- A neutral player (no faction picked yet) still sees both.
	if PT.db.factionOnlyEnemy and faction == UnitFactionGroup("player") then return "" end
	return IconFor(faction)
end

-- Test mode preview: show the icon a real target would get.
local function TestFactionIcon()
	if not PT.db.factionIcon then return "" end
	local mine = UnitFactionGroup("player")
	local faction = PT.db.factionOnlyEnemy and OPPOSITE_FACTION[mine] or mine
	return FACTION_ICONS[faction] and IconFor(faction) or ""
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
		local ok1, err1 = pcall(h.you.SetAlphaFromBoolean, h.you, isYou, 1, 0)
		local ok2, err2 = pcall(h.text.SetAlphaFromBoolean, h.text, isYou, 0, 1)
		if ok1 and ok2 then return end
		h.lastError = tostring(err1 or err2)
		isYou = false -- API missing or refused: just show the name
	end
	h.text:SetAlpha(1)
	h.you:SetAlpha(1)
	h.text:SetShown(not isYou)
	h.you:SetShown(isYou and true or false)
end

local function UpdateTest(h, index)
	StyleYou(h)
	SetName(h, GetDisplayName("player"), TestFactionIcon())
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
		ApplyClassColor(h.text, tunit)
	end

	-- The answer can be secret in restricted content; ShowYou handles that
	-- without reading it.
	local isYou = false
	if db.youMode == "TEXT" then
		isYou = TargetIsYou(unit, tunit)
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
	local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
	Say(("v%s | client %s (%s), interface %s"):format(
		getMeta and getMeta(ADDON, "Version") or "?", version, build, tostring(iface)))
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
	local h = holders[plate]
	local _, fresh = ResolveAnchor(plate)
	Say("target plate:", unit or "untracked", "| using:", h and h.anchorKind or "none", "| would pick:", fresh)
	-- Any value may be secret, so only tostring() touches them.
	local function S(f, method)
		local ok, v = pcall(f[method], f)
		if not ok then return "err" end
		if IsSecret(v) then return "secret" end
		return type(v) == "number" and ("%.2f"):format(v):gsub("%.?0+$", "") or tostring(v)
	end
	if h and h.bars then
		Say(("cast bars tracked: %d | push past bars: %.1f"):format(#h.bars, h.stack or 0))
		for i, bar in ipairs(h.bars) do
			local okShow, showing = pcall(BarShowing, bar)
			local okNeed, need = pcall(ClearanceFor, h, bar, PT.db.position ~= "ABOVE")
			Say(("  bar %d: showing=%s height=%s gap=%s needs=%s"):format(i,
				okShow and tostring(showing) or "err", S(bar.size, "GetHeight"), tostring(bar.gap),
				okNeed and tostring(need and ("%.1f"):format(need) or "other side") or ("err: " .. tostring(need))))
		end
	end
	if h and h.lastError then Say("last error:", h.lastError) end
	local function Describe(label, f)
		if not f then return end
		Say(("%s: shown=%s visible=%s alpha=%s strata=%s level=%s scale=%s W=%s H=%s"):format(
			label, S(f, "IsShown"), S(f, "IsVisible"), S(f, "GetAlpha"),
			f.GetFrameStrata and S(f, "GetFrameStrata") or "n/a",
			f.GetFrameLevel and S(f, "GetFrameLevel") or "n/a",
			S(f, "GetEffectiveScale"), S(f, "GetWidth"), S(f, "GetHeight")))
	end
	if h then
		Describe("anchor", h.anchor)
		Describe("holder", h)
		for _, pair in ipairs({ { "name text", h.text }, { "you text", h.you } }) do
			local label, fs = pair[1], pair[2]
			local ok, txt = pcall(fs.GetText, fs)
			Say(("%s: shown=%s alpha=%s string=%s"):format(label, S(fs, "IsShown"), S(fs, "GetAlpha"),
				ok and (IsSecret(txt) and "secret" or tostring(txt)) or "err"))
		end
	end
	if unit then
		local tunit = unit .. "target"
		local _, name = pcall(UnitName, tunit)
		local okIs, isYouRaw = pcall(UnitIsUnit, tunit, "player")
		local _, _, class = pcall(UnitClass, tunit)
		Say("its target's name secret:", IsSecret(name) and "yes" or "no",
			"| class secret:", IsSecret(class) and "yes" or "no",
			"| UnitIsUnit:", okIs and (IsSecret(isYouRaw) and "secret" or tostring(isYouRaw)) or ("error: " .. tostring(isYouRaw)))
		local isYou, via = TargetIsYou(unit, tunit)
		Say("targeting you:", IsSecret(isYou) and "secret" or tostring(isYou), "(via " .. via .. ")",
			"| name color:", h and ApplyClassColor(h.text, tunit) or "n/a")
	end
end

function PT:ResetDefaults()
	wipe(self.db)
	for k, v in pairs(ns.defaults) do
		self.db[k] = type(v) == "table" and CopyTable(v) or v
	end
	self:Refresh()
end
