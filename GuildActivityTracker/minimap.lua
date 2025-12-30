local addonName = ...
local GAT = _G[addonName]

-- Botón (lo creamos una vez)
local iconFrame

local function EnsureDB()
    -- Asegura SavedVariables global
    GuildActivityTrackerDB = GuildActivityTrackerDB or {}

    -- Enlaza DB al addon si todavía no está
    GAT.db = GAT.db or GuildActivityTrackerDB

    -- Defaults
    GAT.db.minimap = GAT.db.minimap or { angle = 180 }
end

local function UpdateButtonPosition()
    if not iconFrame or not GAT.db or not GAT.db.minimap then return end

    local angle = GAT.db.minimap.angle or 180
    local radius = 80

    -- En WoW: cos/sin usan grados, atan2 devuelve grados (perfecto con 180)
    local x = cos(angle) * radius
    local y = sin(angle) * radius

    iconFrame:ClearAllPoints()
    iconFrame:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMinimapButton()
    if iconFrame then return end
    EnsureDB()

    iconFrame = CreateFrame("Button", "GAT_MinimapButton", Minimap)
    iconFrame:SetSize(32, 32)
    iconFrame:SetFrameStrata("MEDIUM")

    iconFrame:SetNormalTexture("Interface\\AddOns\\GuildActivityTracker\\media\\minimap")
    iconFrame:GetNormalTexture():SetTexCoord(0, 1, 0, 1)
    iconFrame:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    UpdateButtonPosition()

    -- Drag behavior
    iconFrame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            self.isDragging = true
        end
    end)

    iconFrame:SetScript("OnMouseUp", function(self)
        self.isDragging = false
    end)

    iconFrame:SetScript("OnUpdate", function(self)
        if self.isDragging then
            EnsureDB()

            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()

            px, py = px / scale, py / scale

            local angle = atan2(py - my, px - mx) -- grados
            GAT.db.minimap.angle = angle
            UpdateButtonPosition()
        end
    end)

    -- Click actions
    iconFrame:SetScript("OnClick", function(_, button)
        if button == "LeftButton" then
            if GAT.ToggleUI then GAT:ToggleUI() end
        elseif button == "RightButton" then
            -- Settings nuevo (DF/TWW) con fallback a UI vieja
            if Settings and Settings.OpenToCategory and GAT.OptionsCategoryID then
                Settings.OpenToCategory(GAT.OptionsCategoryID)
            elseif InterfaceOptionsFrame_OpenToCategory and GAT.OptionsPanel then
                InterfaceOptionsFrame_OpenToCategory(GAT.OptionsPanel)
                InterfaceOptionsFrame_OpenToCategory(GAT.OptionsPanel)
            end
        end
    end)

    -- Tooltip
    iconFrame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff00ff00Guild Activity Tracker|r")
        GameTooltip:AddLine("Left-click: Open UI")
        GameTooltip:AddLine("Right-click: Options")
        GameTooltip:Show()
    end)

    iconFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- Crear cuando el addon esté listo (por si core inicializa la DB tarde)
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")

loader:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 ~= addonName then return end
    EnsureDB()
    CreateMinimapButton()
end)
