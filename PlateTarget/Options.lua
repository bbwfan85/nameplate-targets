local ADDON, ns = ...
local PT = ns.PT

local refreshers = {}

local function DB() return PT.db end

local function Changed()
	PT:Refresh()
end

local function Label(parent, text, x, y, template)
	local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontNormal")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

local function Checkbox(parent, text, key, x, y)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", x, y)
	local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(text)
	cb:SetScript("OnClick", function(self)
		DB()[key] = self:GetChecked() and true or false
		Changed()
	end)
	refreshers[#refreshers + 1] = function() cb:SetChecked(DB()[key]) end
	return cb
end

local function Slider(parent, text, key, minV, maxV, step, x, y)
	Label(parent, text, x, y, "GameFontHighlight")
	local s = CreateFrame("Slider", nil, parent, "BackdropTemplate")
	s:SetPoint("TOPLEFT", x, y - 18)
	s:SetSize(200, 16)
	s:SetOrientation("HORIZONTAL")
	s:SetBackdrop({
		bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
		edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
		tile = true, tileSize = 8, edgeSize = 8,
		insets = { left = 3, right = 3, top = 6, bottom = 6 },
	})
	s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	s:SetMinMaxValues(minV, maxV)
	s:SetValueStep(step)
	s:SetObeyStepOnDrag(true)

	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetPoint("LEFT", s, "RIGHT", 12, 0)
	box:SetSize(40, 20)
	box:SetAutoFocus(false)
	box:SetJustifyH("CENTER")

	local updating
	s:SetScript("OnValueChanged", function(_, v)
		if updating then return end
		v = math.floor(v / step + 0.5) * step
		box:SetText(v)
		DB()[key] = v
		Changed()
	end)
	box:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText())
		if v then
			v = math.max(minV, math.min(maxV, v))
			s:SetValue(v)
		end
		self:ClearFocus()
	end)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	refreshers[#refreshers + 1] = function()
		updating = true
		s:SetValue(DB()[key])
		box:SetText(DB()[key])
		updating = false
	end
	return s
end

local function TextInput(parent, text, key, x, y)
	Label(parent, text, x, y, "GameFontHighlight")
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetPoint("TOPLEFT", x + 6, y - 16)
	box:SetSize(200, 22)
	box:SetAutoFocus(false)
	local function Commit(self)
		DB()[key] = self:GetText()
		Changed()
	end
	box:SetScript("OnEnterPressed", function(self) Commit(self); self:ClearFocus() end)
	box:SetScript("OnEditFocusLost", Commit)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	refreshers[#refreshers + 1] = function() box:SetText(DB()[key] or "") end
	return box
end

-- choices: function returning a list of { value, label } pairs
local function Dropdown(parent, text, key, choices, x, y)
	Label(parent, text, x, y, "GameFontHighlight")
	local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
	if ok and dd and dd.SetupMenu then
		dd:SetPoint("TOPLEFT", x, y - 16)
		dd:SetWidth(200)
		dd:SetupMenu(function(_, root)
			root:SetScrollMode(400)
			for _, c in ipairs(choices()) do
				root:CreateRadio(c[2],
					function() return DB()[key] == c[1] end,
					function() DB()[key] = c[1]; Changed() end)
			end
		end)
		refreshers[#refreshers + 1] = function() dd:GenerateMenu() end
		return dd
	end

	-- Fallback: a button that cycles through the choices.
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetPoint("TOPLEFT", x, y - 16)
	b:SetSize(200, 22)
	local function Sync()
		for _, c in ipairs(choices()) do
			if c[1] == DB()[key] then b:SetText(c[2]) return end
		end
		b:SetText(tostring(DB()[key]))
	end
	b:SetScript("OnClick", function()
		local list, idx = choices(), 0
		for i, c in ipairs(list) do if c[1] == DB()[key] then idx = i end end
		DB()[key] = list[idx % #list + 1][1]
		Sync()
		Changed()
	end)
	refreshers[#refreshers + 1] = Sync
	return b
end

local function ColorSwatch(parent, text, key, x, y)
	local b = CreateFrame("Button", nil, parent)
	b:SetPoint("TOPLEFT", x + 4, y)
	b:SetSize(18, 18)
	local border = b:CreateTexture(nil, "BACKGROUND")
	border:SetPoint("TOPLEFT", -1, 1)
	border:SetPoint("BOTTOMRIGHT", 1, -1)
	border:SetColorTexture(0.8, 0.8, 0.8)
	local tex = b:CreateTexture(nil, "ARTWORK")
	tex:SetAllPoints()
	local fs = b:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	fs:SetPoint("LEFT", b, "RIGHT", 6, 0)
	fs:SetText(text)

	local function Sync()
		local c = DB()[key]
		tex:SetColorTexture(c.r, c.g, c.b)
	end
	local function Set(r, g, bl)
		local c = DB()[key]
		c.r, c.g, c.b = r, g, bl
		Sync()
		Changed()
	end
	b:SetScript("OnClick", function()
		local c = DB()[key]
		local orig = { c.r, c.g, c.b }
		local function OnPick() Set(ColorPickerFrame:GetColorRGB()) end
		local function OnCancel() Set(unpack(orig)) end
		if ColorPickerFrame.SetupColorPickerAndShow then
			ColorPickerFrame:SetupColorPickerAndShow({
				r = c.r, g = c.g, b = c.b,
				swatchFunc = OnPick,
				cancelFunc = OnCancel,
			})
		else
			-- Older color picker API
			ColorPickerFrame.hasOpacity = false
			ColorPickerFrame.func = OnPick
			ColorPickerFrame.cancelFunc = OnCancel
			ColorPickerFrame:SetColorRGB(c.r, c.g, c.b)
			ColorPickerFrame:Hide()
			ColorPickerFrame:Show()
		end
	end)
	refreshers[#refreshers + 1] = Sync
	return b
end

local function FontChoices()
	local out = {}
	for _, name in ipairs(ns.GetFontList()) do out[#out + 1] = { name, name } end
	return out
end

function ns.CreateOptions()
	local panel = CreateFrame("Frame")
	panel.name = "PlateTarget"

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("PlateTarget")
	Label(panel, "Shows who each nameplate is targeting, in their class color.", 16, -40, "GameFontHighlightSmall")

	local L, R = 16, 300

	-- Left column: appearance
	Label(panel, "Appearance", L, -70)
	Dropdown(panel, "Font", "font", FontChoices, L, -92)
	Slider(panel, "Font size", "fontSize", 6, 32, 1, L, -142)
	Dropdown(panel, "Outline", "outline", function()
		return { { "NONE", "None" }, { "OUTLINE", "Outline" }, { "THICKOUTLINE", "Thick outline" } }
	end, L, -186)
	Checkbox(panel, "Text shadow", "shadow", L, -234)

	Label(panel, "Position", L, -270)
	Dropdown(panel, "Side of nameplate", "position", function()
		return { { "BELOW", "Below" }, { "ABOVE", "Above" } }
	end, L, -292)
	Slider(panel, "Vertical offset", "offsetY", -100, 100, 1, L, -342)
	Slider(panel, "Horizontal offset", "offsetX", -150, 150, 1, L, -386)
	Dropdown(panel, "Anchor to", "anchorMode", function()
		return { { "AUTO", "Health bar (auto-detect)" }, { "PLATE", "Nameplate frame" } }
	end, L, -430)

	-- Right column: text
	Label(panel, "Text", R, -70)
	TextInput(panel, "Format (NAME = target's name)", "format", R, -92)
	Dropdown(panel, "Player names", "nameMode", function()
		return { { "FIRST", "First name only" }, { "FULL", "Full name (with surname)" } }
	end, R, -136)
	Checkbox(panel, "Faction icon before player names", "factionIcon", R, -182)
	Slider(panel, "Faction icon size (0 = match text)", "factionIconSize", 0, 32, 1, R, -214)
	Checkbox(panel, "Show NPC targets (pets, NPCs)", "showNPCTargets", R, -258)
	ColorSwatch(panel, "NPC target color", "npcColor", R + 4, -288)

	Label(panel, "When targeting you", R, -322)
	Dropdown(panel, "Show", "youMode", function()
		return { { "TEXT", "Custom text" }, { "NAME", "My name" } }
	end, R, -344)
	TextInput(panel, "Custom text", "youText", R, -394)
	Checkbox(panel, "Use custom color (otherwise class color)", "youUseColor", R, -436)
	ColorSwatch(panel, "Targeting-you color", "youColor", R + 4, -466)

	Label(panel, "Filters", L, -500)
	Checkbox(panel, "Enabled", "enabled", L, -520)
	Checkbox(panel, "Enemy nameplates", "showEnemy", L + 140, -520)
	Checkbox(panel, "Friendly nameplates", "showFriendly", L + 320, -520)

	local test = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	test:SetPoint("TOPLEFT", L, -560)
	test:SetSize(140, 24)
	local function SyncTest() test:SetText(PT:IsTestMode() and "Stop test" or "Test mode") end
	test:SetScript("OnClick", function() PT:SetTestMode(not PT:IsTestMode()); SyncTest() end)
	refreshers[#refreshers + 1] = SyncTest

	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetPoint("LEFT", test, "RIGHT", 10, 0)
	reset:SetSize(140, 24)
	reset:SetText("Reset to defaults")
	reset:SetScript("OnClick", function()
		PT:ResetDefaults()
		for _, fn in ipairs(refreshers) do fn() end
	end)

	panel:SetScript("OnShow", function()
		for _, fn in ipairs(refreshers) do fn() end
	end)

	if Settings and Settings.RegisterCanvasLayoutCategory then
		local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
		Settings.RegisterAddOnCategory(category)
		PT.category = category
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)
	end
	PT.panel = panel
end

local function OpenOptions()
	if PT.category then
		Settings.OpenToCategory(PT.category:GetID())
	elseif InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory(PT.panel)
		InterfaceOptionsFrame_OpenToCategory(PT.panel)
	end
end

SLASH_PLATETARGET1 = "/platetarget"
SLASH_PLATETARGET2 = "/ptarget"
SlashCmdList.PLATETARGET = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "test" then
		PT:SetTestMode(not PT:IsTestMode())
		print("|cff33ff99PlateTarget|r test mode " .. (PT:IsTestMode() and "on" or "off"))
	elseif msg == "reset" then
		PT:ResetDefaults()
		print("|cff33ff99PlateTarget|r settings reset.")
	elseif msg == "debug" then
		PT:Debug()
	else
		OpenOptions()
	end
end
