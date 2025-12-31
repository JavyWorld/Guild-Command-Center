local addonName = ...
local GAT = _G[addonName]

function GAT:CreateFiltersUI(parent)
    if GAT.FiltersPanel then return end

    local f = CreateFrame("Frame", nil, parent)
    f:SetPoint("TOPLEFT", 10, -50)
    f:SetSize(400, 400)
    f:Hide()

    GAT.FiltersPanel = f

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText("Filtros activos")

    -- Scroll
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -30)
    scroll:SetPoint("BOTTOMRIGHT", -30, 40)

    local content = CreateFrame("Frame")
    content:SetSize(350, 300)
    scroll:SetScrollChild(content)
    f.Content = content

    -- Input box
    local edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    edit:SetSize(200, 25)
    edit:SetPoint("BOTTOMLEFT", 0, 0)
    edit:SetAutoFocus(false)
    f.AddBox = edit

    -- Button Add
    local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addBtn:SetSize(80, 25)
    addBtn:SetPoint("BOTTOMLEFT", edit, "BOTTOMRIGHT", 10, 0)
    addBtn:SetText("Añadir")
    addBtn:SetScript("OnClick", function()
        local name = edit:GetText()
        if name and name ~= "" then
            GAT.db.filters[name] = true
            edit:SetText("")
            GAT:RefreshFiltersUI()
        end
    end)
end

function GAT:RefreshFiltersUI()
    if not GAT.FiltersPanel then return end
    local content = GAT.FiltersPanel.Content

    if content.rows then
        for _, r in ipairs(content.rows) do
            r:Hide()
        end
    end

    content.rows = {}

    local y = -5
    for name, _ in pairs(GAT.db.filters) do
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(300, 20)
        row:SetPoint("TOPLEFT", 0, y)

        local txt = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        txt:SetPoint("LEFT", 5, 0)
        txt:SetText(name)

        local del = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        del:SetSize(40, 18)
        del:SetPoint("RIGHT", -5, 0)
        del:SetText("Del")
        del:SetScript("OnClick", function()
            GAT.db.filters[name] = nil
            GAT:RefreshFiltersUI()
        end)

        table.insert(content.rows, row)
        y = y - 22
    end
end
