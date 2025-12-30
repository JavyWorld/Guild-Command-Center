local addonName = ...
local GAT = _G[addonName]

-- Función para limpiar comas en los mensajes (para no romper el CSV)
local function CleanCSV(text)
    if not text then return "" end
    return string.gsub(tostring(text), ",", " ")
end

function GAT:ShowExportWindow()
    if GAT.ExportWindow then
        GAT.ExportWindow:Show()
        GAT:GenerateExportString()
        return
    end

    local f = CreateFrame("Frame", addonName .. "ExportFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(600, 400)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    
    f.Title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.Title:SetPoint("CENTER", f.TitleBg, "CENTER", 0, 0)
    f.Title:SetText("Exportar Datos (CSV para Excel/Sheets)")

    -- Instrucciones
    local instr = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    instr:SetPoint("TOPLEFT", 15, -30)
    instr:SetText("Presiona Ctrl+A para seleccionar todo, luego Ctrl+C para copiar.")

    -- Scroll y EditBox
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 15, -50)
    scroll:SetPoint("BOTTOMRIGHT", -35, 15)

    local editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true)
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetWidth(530)
    scroll:SetScrollChild(editBox)
    
    editBox:SetScript("OnEscapePressed", function() f:Hide() end)

    f.EditBox = editBox
    GAT.ExportWindow = f

    GAT:GenerateExportString()
end

function GAT:GenerateExportString()
    if not GAT.ExportWindow or not GAT.db or not GAT.db.data then return end

    local exportLines = {}
    -- Cabecera del Excel
    table.insert(exportLines, "Jugador,Rango,Mensajes,UltimaVez,UltimoMensaje")

    for name, entry in pairs(GAT.db.data) do
        -- Solo exportamos si es una tabla válida
        if type(entry) == "table" then
            local rank = CleanCSV(entry.rankName or "—")
            local count = entry.total or 0
            local lastSeen = entry.lastSeen or ""
            local lastMsg = CleanCSV(entry.lastMessage or "")
            
            -- Formato: Nombre,Rango,Total,Fecha,Mensaje
            local line = string.format("%s,%s,%d,%s,%s", name, rank, count, lastSeen, lastMsg)
            table.insert(exportLines, line)
        end
    end

    local finalString = table.concat(exportLines, "\n")
    GAT.ExportWindow.EditBox:SetText(finalString)
    GAT.ExportWindow.EditBox:HighlightText() -- Auto-seleccionar todo
    GAT.ExportWindow.EditBox:SetFocus()
end