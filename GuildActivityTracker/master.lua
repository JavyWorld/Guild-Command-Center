-- master.lua
-- Este archivo EXISTE solo en la instalación del GM.
-- Tener este archivo = Master (sin comandos / sin toggles).

local addonName = ...
local GAT = _G[addonName]
if not GAT then return end

GAT.IS_MASTER_BUILD = true

-- Admin UI toggle: "Ayudantes" <-> "Chats"
local function EnsureSyncDB()
    if not GAT.db then return end
    GAT.db._sync = GAT.db._sync or {}
    GAT.db._sync.viewMode = GAT.db._sync.viewMode or "chat" -- chat | helpers
end

function GAT:IsHelpersView()
    EnsureSyncDB()
    return (GAT.db and GAT.db._sync and GAT.db._sync.viewMode == "helpers")
end

function GAT:SetHelpersView(on)
    EnsureSyncDB()
    if not GAT.db or not GAT.db._sync then return end
    GAT.db._sync.viewMode = on and "helpers" or "chat"
    if GAT.AdminToggleBtn then
        GAT.AdminToggleBtn:SetText(on and "Chats" or "Ayudantes")
    end
    if GAT.RefreshUI then GAT:RefreshUI() end
end

-- Hook GetSortedActivity to swap the list data
local _origGetSorted = nil
local function InstallListHook()
    if _origGetSorted then return end
    if not GAT.GetSortedActivity then return end
    _origGetSorted = GAT.GetSortedActivity

    function GAT:GetSortedActivity(...)
        if self:IsHelpersView() and self.Sync_GetHelpersForUI then
            return self:Sync_GetHelpersForUI()
        end
        return _origGetSorted(self, ...)
    end
end

-- Prevent accidental deletes in helper view
local _origReset = nil
local function InstallResetHook()
    if _origReset then return end
    if not GAT.ResetPlayer then return end
    _origReset = GAT.ResetPlayer
    function GAT:ResetPlayer(name)
        if self:IsHelpersView() then
            self:Print("En vista Ayudantes no se borra data (cambia a Chats).")
            return
        end
        return _origReset(self, name)
    end
end

-- Install admin button on main window
function GAT:InstallAdminButton()
    if not self.MainWindow then return end
    if self.AdminToggleBtn then return end

    local f = self.MainWindow
    local btnY = -30
    local btnW = 95
    local btnH = 24

    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(btnW, btnH)
    b:SetPoint("TOPLEFT", 355, btnY) -- coloca en la fila de botones sin tocar los existentes
    b:SetText("Ayudantes")
    b:SetScript("OnClick", function()
        local isOn = self:IsHelpersView()
        self:SetHelpersView(not isOn)
    end)

    self.AdminToggleBtn = b
    -- sync initial label
    if self:IsHelpersView() then
        b:SetText("Chats")
    end
end

-- Hook CreateMainWindow to install button after UI builds
local function HookUI()
    if not GAT.CreateMainWindow then return end
    local orig = GAT.CreateMainWindow
    function GAT:CreateMainWindow(...)
        orig(self, ...)
        InstallListHook()
        InstallResetHook()
        self:InstallAdminButton()
    end
end

-- If UI was already created before this file loads (rare), still install
local function LateInstall()
    InstallListHook()
    InstallResetHook()
    if GAT.MainWindow then
        GAT:InstallAdminButton()
    end
end

HookUI()
C_Timer.After(1, LateInstall)
