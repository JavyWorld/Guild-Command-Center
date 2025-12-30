local addonName = ...
local GAT = _G[addonName]

GAT.db = GAT.db or _G.GuildActivityTrackerDB or {}
_G.GuildActivityTrackerDB = GAT.db
GAT.db.settings = GAT.db.settings or {}

local function EnsureDefaults()
    if GAT.db.settings.enableAutoArchive == nil then GAT.db.settings.enableAutoArchive = false end
    if GAT.db.settings.autoArchiveDays == nil or GAT.db.settings.autoArchiveDays < 7 then 
        GAT.db.settings.autoArchiveDays = 30 
    end
    if GAT.db.settings.autoRosterRefresh == nil then GAT.db.settings.autoRosterRefresh = true end
    if GAT.db.settings.autoRosterIntervalMin == nil then GAT.db.settings.autoRosterIntervalMin = 10 end
end

function GAT:CreateOptionsPanel()
    EnsureDefaults()

    if GAT.OptionsPanel then return end

    local panel = CreateFrame("Frame", "GATOptionsPanel", UIParent)
    panel.name = "Guild Activity Tracker"

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Guild Activity Tracker - Settings")

    -- Checkbox Auto Archive
    local cb = CreateFrame("CheckButton", "GAT_AutoArchiveCB", panel, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -20)
    cb.Text:SetText("Activar Ventana Deslizante (Rolling Window)")
    cb:SetChecked(GAT.db.settings.enableAutoArchive)
    cb:SetScript("OnClick", function(self)
        GAT.db.settings.enableAutoArchive = self:GetChecked() and true or false
    end)

    -- Slider Auto Archive
    local slider = CreateFrame("Slider", "GAT_AutoArchiveDaysSlider", panel, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 6, -30)
    slider:SetMinMaxValues(7, 365)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider:SetWidth(240)
    
    _G[slider:GetName() .. "Low"]:SetText("7")
    _G[slider:GetName() .. "High"]:SetText("365")
    _G[slider:GetName() .. "Text"]:SetText("Historial visible: " .. tostring(GAT.db.settings.autoArchiveDays) .. " días")
    
    slider:SetValue(math.max(7, GAT.db.settings.autoArchiveDays))

    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        if value < 7 then value = 7 end
        GAT.db.settings.autoArchiveDays = value
        _G[self:GetName() .. "Text"]:SetText("Historial visible: " .. tostring(value) .. " días")
    end)
    
    local sliderInfo = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sliderInfo:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -5)
    sliderInfo:SetText("Mensajes anteriores a este periodo se borrarán al iniciar.")

    -- Auto Refresh
    local autoRosterCB = CreateFrame("CheckButton", "GAT_AutoRosterCB", panel, "InterfaceOptionsCheckButtonTemplate")
    autoRosterCB:SetPoint("TOPLEFT", sliderInfo, "BOTTOMLEFT", -10, -28)
    autoRosterCB.Text:SetText("Auto-refresh roster mientras UI abierta")
    autoRosterCB:SetChecked(GAT.db.settings.autoRosterRefresh)
    autoRosterCB:SetScript("OnClick", function(self)
        GAT.db.settings.autoRosterRefresh = self:GetChecked() and true or false
        if GAT.UpdateAutoRefreshFromSettings then GAT:UpdateAutoRefreshFromSettings() end
    end)

    -- Info
    local info = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    info:SetPoint("TOPLEFT", autoRosterCB, "BOTTOMLEFT", 4, -30)
    info:SetWidth(500)
    info:SetJustifyH("LEFT")
    info:SetText("Nota: Si los rangos no aparecen, pulsa 'Sync' en la ventana principal.")

    GAT.OptionsPanel = panel

    -- REGISTRO DE CATEGORÍA
    -- Prioridad absoluta al sistema moderno Settings (10.0+)
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
        GAT.OptionsCategoryID = category:GetID()
    else
        -- Fallback Legacy
        if InterfaceOptions_AddCategory then
            InterfaceOptions_AddCategory(panel)
        end
    end
end

function GAT:OpenOptions()
    -- Aseguramos que el panel exista antes de intentar abrirlo
    if not GAT.OptionsPanel then GAT:CreateOptionsPanel() end

    -- Intento 1: API Moderna (Retail) por ID
    if Settings and Settings.OpenToCategory then
        if GAT.OptionsCategoryID then
            Settings.OpenToCategory(GAT.OptionsCategoryID)
        else
            -- Si falló el ID, intentamos por nombre (menos seguro pero a veces funciona)
            pcall(function() Settings.OpenToCategory(GAT.OptionsPanel.name) end)
        end
        return
    end

    -- Intento 2: API Legacy (Classic/Old)
    if InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(GAT.OptionsPanel)
        InterfaceOptionsFrame_OpenToCategory(GAT.OptionsPanel) -- Doble llamada para expandir el árbol
    end
end