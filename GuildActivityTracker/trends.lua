local addonName = ...
local GAT = _G[addonName]

function GAT:CreateTrendsUI(parent)
    if GAT.TrendsPanel then return end

    local f = CreateFrame("Frame", nil, parent)
    f:SetPoint("TOPLEFT", 10, -50)
    f:SetSize(400, 400)
    f:Hide()

    GAT.TrendsPanel = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText("Tendencias de Actividad")

    f.Summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.Summary:SetPoint("TOPLEFT", 0, -30)
    f.Summary:SetWidth(380)
end

function GAT:RefreshTrends()
    if not GAT.TrendsPanel then return end

    local totals = {}
    for name, data in pairs(GAT.db.data) do
        for d, amount in pairs(data.daily or {}) do
            totals[d] = (totals[d] or 0) + amount
        end
    end

    local sortedDays = {}
    for d, _ in pairs(totals) do
        table.insert(sortedDays, d)
    end
    table.sort(sortedDays)

    local text = "|cff00ff00Resumen de actividad por día|r\n\n"
    for _, d in ipairs(sortedDays) do
        text = text .. "|cffffff00" .. d .. "|r → " .. totals[d] .. " mensajes\n"
    end

    GAT.TrendsPanel.Summary:SetText(text)
end
