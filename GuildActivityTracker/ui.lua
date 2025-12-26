local addonName = ...
local GAT = _G[addonName]

function GAT:ShowMissingPlayersWindow()
    if GAT.MissingWindow then
        GAT.MissingWindow:Show()
        GAT:RefreshMissingList()
        return
    end

    local f = CreateFrame("Frame", addonName .. "MissingFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(400, 500)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    
    f.Title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.Title:SetPoint("CENTER", f.TitleBg, "CENTER", 0, 0)
    f.Title:SetText("Jugadores Faltantes (No en Guild)")

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -30)
    scroll:SetPoint("BOTTOMRIGHT", -30, 10)

    local content = CreateFrame("Frame")
    content:SetSize(360, 450)
    scroll:SetScrollChild(content)
    f.Content = content
    f.Content.rows = {}

    GAT.MissingWindow = f
    GAT:RefreshMissingList()
end

function GAT:RefreshMissingList()
    local f = GAT.MissingWindow
    if not f or not f:IsShown() then return end
    for _, r in ipairs(f.Content.rows) do r:Hide() end
    f.Content.rows = {}

    local guildMembers = {}
    local numMembers = GetNumGuildMembers()
    if numMembers == 0 then if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end end

    for i = 1, numMembers do
        local fullName = GetGuildRosterInfo(i)
        if fullName then
            guildMembers[Ambiguate(fullName, "none")] = true
            guildMembers[Ambiguate(fullName, "short")] = true
        end
    end

    local missing = {}
    if GAT.db and GAT.db.data then
        for name, _ in pairs(GAT.db.data) do
            local dbFull = Ambiguate(name, "none")
            local dbShort = Ambiguate(name, "short")
            if not guildMembers[dbFull] and not guildMembers[dbShort] then
                table.insert(missing, name)
            end
        end
    end
    table.sort(missing)

    local y = 0
    for i, name in ipairs(missing) do
        local row = CreateFrame("Frame", nil, f.Content)
        row:SetSize(360, 20)
        row:SetPoint("TOPLEFT", 0, y)
        local txt = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        txt:SetPoint("LEFT", 5, 0)
        txt:SetText(name)
        -- Botón Eliminar (solo MASTER)

        if GAT and GAT.IS_MASTER_BUILD then

            local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")

            delBtn:SetSize(60, 18)

            delBtn:SetPoint("RIGHT", -5, 0)

            delBtn:SetText("Eliminar")

            delBtn:SetScript("OnClick", function()

                if GAT.DeletePlayer then
                    GAT:DeletePlayer(name)
                end

                -- No spamear: este print es útil, pero solo MASTER lo ve y es por acción manual.

                print("|cff00ffff[GAT]|r Eliminado: " .. name)

                GAT:RefreshMissingList()

                if GAT.RefreshUI then

                    GAT:RefreshUI()

                end

            end)

        end
        table.insert(f.Content.rows, row)
        y = y - 22
    end
    f.Content:SetHeight(math.max(450, (#missing * 22) + 20))
end

function GAT:CreateMainWindow()
    if GAT.MainWindow then return end

    local f = CreateFrame("Frame", addonName .. "Window", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(660, 520) 
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    
    -- === AQUI ESTA LA MAGIA DEL SNAPSHOT AL ABRIR ===
    f:SetScript("OnShow", function() 
        if GAT.OnUIShown then GAT:OnUIShown() end 
        -- Intentar tomar foto al abrir (Stats.lua decidirá si ha pasado suficiente tiempo)
        if GAT.TakeActivitySnapshot then GAT:TakeActivitySnapshot(false) end
    end)
    
    f:SetScript("OnHide", function() if GAT.OnUIHidden then GAT:OnUIHidden() end end)

    f.Title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.Title:SetPoint("CENTER", f.TitleBg, "CENTER", 0, 0)
    f.Title:SetText("Guild Activity Tracker Elite")

    f.Logo = f:CreateTexture(nil, "OVERLAY", nil, 7)
    f.Logo:SetSize(72, 72)
    f.Logo:SetPoint("TOPLEFT", f, "TOPLEFT", -10, 10)
    f.Logo:SetTexture("Interface\\AddOns\\GuildActivityTracker\\media\\logo.tga")

    local btnY = -30 
    local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refreshBtn:SetSize(80, 22)
    refreshBtn:SetPoint("TOPLEFT", 95, btnY) 
    refreshBtn:SetText("Refresh")
    refreshBtn:SetScript("OnClick", function() if GAT.RefreshUI then GAT:RefreshUI() end end)
    
    local syncBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    syncBtn:SetSize(80, 22)
    syncBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 5, 0)
    syncBtn:SetText("Sync")
    syncBtn:SetScript("OnClick", function()
        if GAT.Sync_Manual then
            GAT:Sync_Manual()
        end
    end)

    local missingBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    missingBtn:SetSize(90, 22)
    missingBtn:SetPoint("LEFT", syncBtn, "RIGHT", 5, 0)
    missingBtn:SetText("Faltantes")
    missingBtn:SetScript("OnClick", function() GAT:ShowMissingPlayersWindow() end)

    local optBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    optBtn:SetSize(80, 22)
    optBtn:SetPoint("TOPRIGHT", -15, btnY)
    optBtn:SetText("Opciones")
    optBtn:SetScript("OnClick", function() if GAT.OpenOptions then GAT:OpenOptions() else print("Error Opciones") end end)

    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetSize(80, 22)
    exportBtn:SetPoint("RIGHT", optBtn, "LEFT", -5, 0)
    exportBtn:SetText("Exportar")
    exportBtn:SetScript("OnClick", function() if GAT.ShowExportWindow then GAT:ShowExportWindow() else print("Error Export") end end)

    GAT.MainWindow = f
    if GAT.CreateTable then GAT:CreateTable(f) end
end
