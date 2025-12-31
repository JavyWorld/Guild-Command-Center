local addonName = ...
local GAT = _G[addonName]

local HELPERS_PANEL_HEIGHT = 120

local function FormatAgo(sec)
    if not sec or sec <= 0 then return "—" end
    if sec < 60 then return sec .. "s" end
    if sec < 3600 then return math.floor(sec / 60) .. "m" end
    return math.floor(sec / 3600) .. "h"
end

local function FormatSyncAgo(ts)
    if not ts or ts <= 0 then return "—" end
    local delta = math.max(0, time() - ts)
    return "hace " .. FormatAgo(delta)
end

-- Helper para sorting
function GAT:SortBy(newMode)
    GAT.db = GAT.db or {}
    GAT.db.settings = GAT.db.settings or {}
    
    local currentMode = GAT.db.settings.sortMode or "count"
    local currentDir = GAT.db.settings.sortDir or "desc"

    if currentMode == newMode then
        -- Si es la misma columna, invertimos dirección
        GAT.db.settings.sortDir = (currentDir == "desc") and "asc" or "desc"
    else
        -- Nueva columna: default a Descendente (mayor a menor)
        GAT.db.settings.sortMode = newMode
        GAT.db.settings.sortDir = "desc"
    end

    if GAT.RefreshUI then GAT:RefreshUI() end
end

function GAT:CreateTable(parent)
    local topMargin = -65 
    local helperPanelHeight = (GAT:IsMasterBuild() and HELPERS_PANEL_HEIGHT) or 0

    -- Buscador
    local searchLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    searchLabel:SetPoint("TOPLEFT", 12, topMargin)
    searchLabel:SetText("Buscar:")

    local searchBox = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    searchBox:SetSize(180, 22)
    searchBox:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetScript("OnTextChanged", function() if GAT.RefreshUI then GAT:RefreshUI() end end)
    parent.SearchBox = searchBox

    local clearBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    clearBtn:SetSize(22, 22)
    clearBtn:SetPoint("LEFT", searchBox, "RIGHT", 4, 0)
    clearBtn:SetText("X")
    clearBtn:SetScript("OnClick", function()
        if parent.SearchBox then parent.SearchBox:SetText(""); parent.SearchBox:ClearFocus() end
        if GAT.RefreshUI then GAT:RefreshUI() end
    end)

    local resultsFS = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    resultsFS:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, topMargin - 25)
    resultsFS:SetWidth(250)
    resultsFS:SetJustifyH("LEFT")
    resultsFS:SetText("Resultados: 0 / Total: 0")
    parent.ResultsFS = resultsFS

    local rosterFS = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    rosterFS:SetPoint("LEFT", resultsFS, "RIGHT", 10, 0)
    rosterFS:SetWidth(300)
    rosterFS:SetJustifyH("RIGHT")
    rosterFS:SetText("Roster: —")
    parent.RosterStatusFS = rosterFS

    -- ==========================================
    -- Cabeceras (Headers)
    -- ==========================================
    local headerY = topMargin - 50 

    -- #
    local hRank = parent:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    hRank:SetPoint("TOPLEFT", 15, headerY + 4)
    hRank:SetText("#")
    
    -- JUGADOR
    local btnName = CreateFrame("Button", nil, parent)
    btnName:SetSize(140, 20)
    btnName:SetPoint("TOPLEFT", 40, headerY + 4)
    local txtName = btnName:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    txtName:SetPoint("LEFT", 0, 0)
    txtName:SetText("Jugador")
    btnName:SetFontString(txtName)
    btnName:SetScript("OnClick", function() GAT:SortBy("online") end)
    parent.HeaderName = btnName

    -- MENSAJES
    local btnCount = CreateFrame("Button", nil, parent)
    btnCount:SetSize(80, 20)
    btnCount:SetPoint("TOPLEFT", 190, headerY + 4)
    local txtCount = btnCount:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    txtCount:SetPoint("LEFT", 0, 0)
    txtCount:SetText("Mensajes")
    btnCount:SetFontString(txtCount)
    btnCount:SetScript("OnClick", function() GAT:SortBy("count") end)
    parent.HeaderCount = btnCount

    -- RANGO
    local btnRank = CreateFrame("Button", nil, parent)
    btnRank:SetSize(100, 20)
    btnRank:SetPoint("TOPLEFT", 280, headerY + 4)
    local txtRank = btnRank:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    txtRank:SetPoint("LEFT", 0, 0)
    txtRank:SetText("Rango")
    btnRank:SetFontString(txtRank)
    btnRank:SetScript("OnClick", function() GAT:SortBy("rank") end)
    parent.HeaderRank = btnRank

    -- ULTIMO VISTO
    local btnRecent = CreateFrame("Button", nil, parent)
    btnRecent:SetSize(140, 20)
    btnRecent:SetPoint("TOPLEFT", 390, headerY + 4)
    local txtRecent = btnRecent:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    txtRecent:SetPoint("LEFT", 0, 0)
    txtRecent:SetText("Últ. Visto")
    btnRecent:SetFontString(txtRecent)
    btnRecent:SetScript("OnClick", function() GAT:SortBy("recent") end)
    parent.HeaderRecent = btnRecent

    -- Línea divisoria
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.5, 0.5, 0.5, 0.3)
    line:SetSize(620, 1)
    line:SetPoint("TOPLEFT", 10, headerY - 18)
    
    -- =========================
    -- Scroll / Lista
    -- =========================
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, headerY - 22)
    scroll:SetPoint("BOTTOMRIGHT", -30, 12 + helperPanelHeight)

    local content = CreateFrame("Frame")
    content:SetSize(620, 400)
    scroll:SetScrollChild(content)
    parent.Content = content

    if helperPanelHeight > 0 then
        GAT:CreateHelpersPanel(parent, helperPanelHeight)
    end
end

local helperColumns = {
    { key = "name", label = "Ayudante", x = 10, width = 150 },
    { key = "char", label = "Personaje actual", x = 170, width = 170 },
    { key = "role", label = "Rol", x = 350, width = 80 },
    { key = "sync", label = "Último sync (hace X)", x = 440, width = 160 },
}

local function ensureHelperRow(panel, idx)
    panel.rows = panel.rows or {}
    local row = panel.rows[idx]
    if not row then
        row = CreateFrame("Frame", nil, panel)
        row:SetSize(600, 16)

        row.Name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.Name:SetPoint("LEFT", helperColumns[1].x, 0)
        row.Name:SetWidth(helperColumns[1].width)
        row.Name:SetJustifyH("LEFT")

        row.Char = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.Char:SetPoint("LEFT", helperColumns[2].x, 0)
        row.Char:SetWidth(helperColumns[2].width)
        row.Char:SetJustifyH("LEFT")

        row.Role = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.Role:SetPoint("LEFT", helperColumns[3].x, 0)
        row.Role:SetWidth(helperColumns[3].width)
        row.Role:SetJustifyH("LEFT")

        row.Sync = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.Sync:SetPoint("LEFT", helperColumns[4].x, 0)
        row.Sync:SetWidth(helperColumns[4].width)
        row.Sync:SetJustifyH("LEFT")

        panel.rows[idx] = row
    end
    row:SetPoint("TOPLEFT", 0, -24 - ((idx - 1) * 18))
    return row
end

function GAT:CreateHelpersPanel(parent, height)
    if parent.HelpersPanel then return end

    local panel = CreateFrame("Frame", nil, parent)
    panel:SetPoint("BOTTOMLEFT", 10, 10)
    panel:SetPoint("BOTTOMRIGHT", -10, 10)
    panel:SetHeight(height)

    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.15)

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText("Ayudantes (GM)")

    local line = panel:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.5, 0.5, 0.5, 0.4)
    line:SetSize(620, 1)
    line:SetPoint("TOPLEFT", 0, -18)

    for _, h in ipairs(helperColumns) do
        local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", h.x, -20)
        fs:SetWidth(h.width)
        fs:SetJustifyH("LEFT")
        fs:SetText(h.label)
    end

    panel.EmptyFS = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.EmptyFS:SetPoint("TOPLEFT", helperColumns[1].x, -28)
    panel.EmptyFS:SetText("Sin ayudantes todavía.")
    panel.EmptyFS:Hide()

    panel.rows = {}
    parent.HelpersPanel = panel
end

function GAT:RefreshHelpersUI()
    local f = GAT.MainWindow
    if not f or not f:IsShown() then return end
    local panel = f.HelpersPanel
    if not panel then return end

    if not GAT:IsMasterBuild() then
        panel:Hide()
        return
    end
    panel:Show()

    for _, row in ipairs(panel.rows or {}) do
        row:Hide()
    end

    local helpers = (GAT.Sync_GetHelpersForUI and GAT:Sync_GetHelpersForUI()) or {}
    local idx = 0
    for _, h in ipairs(helpers) do
        if not h.isMaster then
            idx = idx + 1
            local row = ensureHelperRow(panel, idx)

            local nameText = GAT:DisplayName(h.name)
            row.Name:SetText(nameText)
            if h.online then
                row.Name:SetTextColor(0, 1, 0, 1)
            else
                row.Name:SetTextColor(0.7, 0.7, 0.7, 1)
            end

            row.Char:SetText(GAT:DisplayName(h.lastChar))

            local roleText = h.role or "—"
            row.Role:SetText(roleText)

            local syncText = FormatSyncAgo(h.lastSyncTS)
            row.Sync:SetText(syncText)
            row.Sync:SetTextColor(h.online and 1 or 0.8, h.online and 1 or 0.8, h.online and 1 or 0.8, 1)

            row:Show()
        end
    end

    if panel.EmptyFS then
        if idx == 0 then
            panel.EmptyFS:Show()
        else
            panel.EmptyFS:Hide()
        end
    end
end

function GAT:RefreshUI()
    local f = GAT.MainWindow
    if not f or not f:IsShown() then return end

    local content = f.Content
    if not content then return end

    if content.rows then
        for _, r in ipairs(content.rows) do r:Hide() end
    end
    content.rows = {}

    local sorted = GAT:GetSortedActivity()
    local settings = (GAT.db and GAT.db.settings) or {}
    local mode = settings.sortMode or "count"
    local dir = settings.sortDir or "desc"

    -- =============================================================
    -- ACTUALIZACIÓN VISUAL DE CABECERAS (Amarillo + Grande)
    -- =============================================================
    local headers = {
        { btn = f.HeaderName,   key = "online", label = "Jugador" },
        { btn = f.HeaderCount,  key = "count",  label = "Mensajes" },
        { btn = f.HeaderRank,   key = "rank",   label = "Rango" },
        { btn = f.HeaderRecent, key = "recent", label = "Últ. Visto" },
    }

    for _, h in ipairs(headers) do
        if h.btn and h.btn:GetFontString() then
            local fs = h.btn:GetFontString()
            fs:SetText(h.label) -- Ponemos el nombre limpio (sin flechas)
            
            if mode == h.key then
                -- ESTILO ACTIVO: Amarillo y Grande
                fs:SetFontObject("GameFontNormalLarge") 
                fs:SetTextColor(1, 1, 0, 1) 
            else
                -- ESTILO INACTIVO: Blanco y Normal
                fs:SetFontObject("GameFontWhite")
                fs:SetTextColor(1, 1, 1, 1)
            end
        end
    end

    -- =============================================================
    -- RENDER DE LISTA
    -- =============================================================
    local query = ""
    if f.SearchBox and f.SearchBox.GetText then
        query = string.lower(f.SearchBox:GetText() or "")
    end

    local totalCount = #sorted
    local shownCount = 0
    local y = 0

    for i, data in ipairs(sorted) do
        local fullName = data.name or ""
        local shortName = GAT:DisplayName(fullName)
        local match = true
        if query ~= "" then
            local a = string.lower(shortName)
            local b = string.lower(fullName)
            match = (a:find(query, 1, true) or b:find(query, 1, true))
        end

        if match then
            shownCount = shownCount + 1

            local row = CreateFrame("Frame", nil, content)
            row:SetSize(620, 20)
            row:SetPoint("TOPLEFT", 0, y)

            -- #
            local rankFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            rankFS:SetPoint("LEFT", 15, 0)
            rankFS:SetWidth(25)
            rankFS:SetJustifyH("LEFT")
            rankFS:SetText(i .. ".")

            -- Nombre (Verde=Online, Blanco=Offline)
            local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            nameFS:SetPoint("LEFT", 40, 0)
            nameFS:SetWidth(140)
            nameFS:SetJustifyH("LEFT")
            nameFS:SetText(shortName)

            if GAT.IsOnline and GAT:IsOnline(data.name) then
                nameFS:SetTextColor(0, 1, 0, 1) 
            else
                nameFS:SetTextColor(1, 1, 1, 1) 
            end

            -- Mensajes
            local countFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            countFS:SetPoint("LEFT", 190, 0)
            countFS:SetWidth(80)
            countFS:SetJustifyH("LEFT")
            countFS:SetText(data.count)

            -- RANGO
            local rkName = data.rankName or "—"
            local rankColFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            rankColFS:SetPoint("LEFT", 280, 0)
            rankColFS:SetWidth(100)
            rankColFS:SetJustifyH("LEFT")
            rankColFS:SetText(rkName)

            -- Última Vez
            local lastFS = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            lastFS:SetPoint("LEFT", 390, 0)
            lastFS:SetWidth(170)
            lastFS:SetJustifyH("LEFT")
            lastFS:SetText((data.lastSeen and data.lastSeen ~= "") and data.lastSeen or "—")

            -- Botón Delete (solo MASTER y solo en vista de chats)
            if GAT and GAT.IS_MASTER_BUILD and not (GAT.IsHelpersView and GAT:IsHelpersView()) then
                local delete = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                delete:SetSize(40, 18)
                delete:SetPoint("RIGHT", -6, 0)
                delete:SetText("Del")
                delete:SetScript("OnClick", function()
                    if GAT.DeletePlayer then
                        GAT:DeletePlayer(data.name)
                    end
                end)


            end
            table.insert(content.rows, row)
            y = y - 22
        end
    end

    if content.SetHeight then
        content:SetHeight(math.max(400, (shownCount * 22) + 24))
    end

    if f.ResultsFS then
        f.ResultsFS:SetText("Resultados: " .. shownCount .. " / Total: " .. totalCount)
    end
    if f.RosterStatusFS and GAT.BuildRosterStatusText then
        f.RosterStatusFS:SetText(GAT:BuildRosterStatusText())
    end
    if GAT.RefreshHelpersUI then
        GAT:RefreshHelpersUI()
    end
end

-- =========================================================
-- Helpers
-- =========================================================
function GAT:ToggleUI()
    if not GAT.MainWindow then GAT:CreateMainWindow() end
    if GAT.MainWindow:IsShown() then GAT.MainWindow:Hide() else GAT.MainWindow:Show(); GAT:RefreshUI() end
end

function GAT:DisplayName(fullName)
    if not fullName then return "" end
    if Ambiguate then return Ambiguate(fullName, "short") end
    return fullName:match("^[^-]+") or fullName
end

function GAT:BuildRosterStatusText()
    local upd = (GAT.GetRosterLastUpdateAt and GAT:GetRosterLastUpdateAt()) or 0

    local sync = (GAT.Sync_GetStatusLine and GAT:Sync_GetStatusLine()) or ""
    local rosterText = string.format("Actualización de roster: %s", FormatSyncAgo(upd))
    if sync ~= "" then
        return rosterText .. " | " .. sync
    end
    return rosterText
end

function GAT:StartAutoRosterRefresh()
    if GAT._statusTicker then GAT._statusTicker:Cancel() end
    if C_Timer and C_Timer.NewTicker then
        GAT._statusTicker = C_Timer.NewTicker(1, function()
            if GAT.MainWindow and GAT.MainWindow:IsShown() and GAT.MainWindow.RosterStatusFS then
                GAT.MainWindow.RosterStatusFS:SetText(GAT:BuildRosterStatusText())
            end
            if GAT.MainWindow and GAT.MainWindow:IsShown() and GAT.RefreshHelpersUI then
                GAT:RefreshHelpersUI()
            end
        end)
    end
end

function GAT:StopAutoRosterRefresh()
    if GAT._statusTicker then GAT._statusTicker:Cancel() end
end

function GAT:OnUIShown()
    GAT:StartAutoRosterRefresh()
    GAT:RefreshUI()
end

function GAT:OnUIHidden()
    GAT:StopAutoRosterRefresh()
end

function GAT:UpdateAutoRefreshFromSettings()
    if GAT.MainWindow and GAT.MainWindow:IsShown() then
        GAT:StartAutoRosterRefresh()
    end
end
