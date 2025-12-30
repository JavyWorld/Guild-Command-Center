local addonName = ...
local GAT = _G[addonName]

function GAT:CreateGraphUI(parent)
    if GAT.GraphPanel then return end

    local f = CreateFrame("Frame", nil, parent)
    f:SetPoint("TOPLEFT", 10, -50)
    f:SetSize(400, 400)
    f:Hide()

    GAT.GraphPanel = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText("Gráfico de Actividad")

    f.lines = {}
    f.points = {}
    f.labels = {}
end

function GAT:RefreshGraph()
    local f = GAT.GraphPanel
    if not f then return end

    -- Clean up old lines and points
    for _, line in ipairs(f.lines) do line:Hide() end
    f.lines = {}

    for _, point in ipairs(f.points) do point:Hide() end
    f.points = {}

    for _, label in ipairs(f.labels) do label:Hide() end
    f.labels = {}

    if not (GAT.db and GAT.db.data) then
        local noData = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        noData:SetPoint("CENTER")
        noData:SetText("No hay datos para mostrar")
        table.insert(f.labels, noData)
        return
    end

    -- Prepare data (daily totals)
    local totals = {}
    for _, data in pairs(GAT.db.data) do
        for d, amount in pairs(data.daily or {}) do
            totals[d] = (totals[d] or 0) + (tonumber(amount) or 0)
        end
    end

    local dayList = {}
    for d, v in pairs(totals) do
        table.insert(dayList, { day = d, value = v })
    end

    if #dayList == 0 then
        local noData = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        noData:SetPoint("CENTER")
        noData:SetText("No hay datos para mostrar")
        table.insert(f.labels, noData)
        return
    end

    table.sort(dayList, function(a, b) return a.day < b.day end)

    local maxValue = 0
    for _, d in ipairs(dayList) do
        if d.value > maxValue then maxValue = d.value end
    end
    if maxValue <= 0 then maxValue = 1 end

    -- Draw graph
    local graphWidth, graphHeight = 380, 300
    local margin = 40
    local pointSize = 6

    -- Axis
    local axisColor = { 0.8, 0.8, 0.8, 0.5 }

    local xAxis = f:CreateLine()
    xAxis:SetColorTexture(unpack(axisColor))
    xAxis:SetThickness(1)
    xAxis:SetStartPoint("BOTTOMLEFT", margin, margin)
    xAxis:SetEndPoint("BOTTOMRIGHT", -margin, margin)
    table.insert(f.lines, xAxis)

    local yAxis = f:CreateLine()
    yAxis:SetColorTexture(unpack(axisColor))
    yAxis:SetThickness(1)
    yAxis:SetStartPoint("BOTTOMLEFT", margin, margin)
    yAxis:SetEndPoint("TOPLEFT", margin, -margin)
    table.insert(f.lines, yAxis)

    -- Y grid + labels
    local numYTicks = 5
    for i = 0, numYTicks do
        local value = (i / numYTicks) * maxValue
        local y = margin + (i / numYTicks) * (graphHeight - 2 * margin)

        local gridLine = f:CreateLine()
        gridLine:SetColorTexture(0.3, 0.3, 0.3, 0.3)
        gridLine:SetThickness(1)
        gridLine:SetStartPoint("BOTTOMLEFT", margin, y)
        gridLine:SetEndPoint("BOTTOMRIGHT", -margin, y)
        table.insert(f.lines, gridLine)

        local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("RIGHT", f, "BOTTOMLEFT", margin - 8, y)
        label:SetText(string.format("%.0f", value))
        table.insert(f.labels, label)
    end

    -- Points + lines
    local denom = (#dayList > 1) and (#dayList - 1) or 1
    local lastX, lastY

    for i, data in ipairs(dayList) do
        local t = (i - 1) / denom
        if #dayList == 1 then t = 0.5 end

        local x = margin + t * (graphWidth - 2 * margin)
        local y = margin + (data.value / maxValue) * (graphHeight - 2 * margin)

        if lastX then
            local line = f:CreateLine()
            line:SetColorTexture(0, 1, 0, 0.8)
            line:SetThickness(2)
            line:SetStartPoint("BOTTOMLEFT", lastX, lastY)
            line:SetEndPoint("BOTTOMLEFT", x, y)
            table.insert(f.lines, line)
        end

        local point = f:CreateTexture(nil, "OVERLAY")
        point:SetTexture("Interface\\Buttons\\WHITE8X8") -- FIX: backslashes correctos
        point:SetVertexColor(0, 1, 0, 1)
        point:SetSize(pointSize, pointSize)
        point:SetPoint("CENTER", f, "BOTTOMLEFT", x, y)
        table.insert(f.points, point)

        -- X labels (pocas para no ensuciar)
        local showLabel = (#dayList <= 7) or (i == 1) or (i == #dayList) or (i % math.ceil(#dayList / 7) == 0)
        if showLabel then
            local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            label:SetPoint("TOP", f, "BOTTOMLEFT", x, margin - 20)
            label:SetText(data.day)
            label:SetTextColor(1, 1, 1, 0.8)
            table.insert(f.labels, label)
        end

        lastX, lastY = x, y
    end
end
