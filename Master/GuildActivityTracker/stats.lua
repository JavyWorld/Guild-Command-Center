local addonName = ...
local GAT = _G[addonName]

local SNAPSHOT_INTERVAL = 600 
local MIN_SNAPSHOT_DELAY = 60 

GAT.LastSnapshotTime = 0

function GAT:InitStats()
    if GAT.StatsActive then return end
    GAT.StatsActive = true

    if not GAT.db.stats then GAT.db.stats = {} end
    
    if not GAT:IsInTargetGuild() then return end

    GAT:ScheduleNextSnapshot()
    
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_ENTERING_WORLD") 
    f:RegisterEvent("PLAYER_LOGOUT")
    f:RegisterEvent("GUILD_ROSTER_UPDATE")
    
    f:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_ENTERING_WORLD" then
            C_Timer.After(5, function() GAT:TakeActivitySnapshot(true, false) end)
        elseif event == "PLAYER_LOGOUT" then
            GAT:TakeActivitySnapshot(true, true)
        elseif event == "GUILD_ROSTER_UPDATE" then
            local now = time()
            if (now - GAT.LastSnapshotTime > MIN_SNAPSHOT_DELAY) then
                C_Timer.After(2, function() GAT:TakeActivitySnapshot(false, false) end)
            end
        end
    end)
    
    print("|cff00ff00[GAT]|r Tracker V31 (Full Roster): ACTIVO")
end

function GAT:ScheduleNextSnapshot()
    if GAT.SnapshotTimer then GAT.SnapshotTimer:Cancel() end
    local now = time()
    local targetTime = (GAT.LastSnapshotTime or 0) + SNAPSHOT_INTERVAL
    local delay = math.max(10, targetTime - now)
    
    GAT.SnapshotTimer = C_Timer.NewTimer(delay, function()
        GAT:TakeActivitySnapshot(false, false)
    end)
end

function GAT:TakeActivitySnapshot(force, immediate)
    if not GAT:IsInTargetGuild() then return end
    if GAT.Sync_ShouldCollectStats and not GAT:Sync_ShouldCollectStats() then return end

    local now = time()
    if not force and (now - GAT.LastSnapshotTime < MIN_SNAPSHOT_DELAY) then return end

    local function SaveData()
        -- Reiniciamos tablas temporales
        GAT.db.mythic = {} 
        GAT.db.roster = {} -- NUEVO: Tabla para el roster completo
        
        local numMembers = GetNumGuildMembers()
        local countOnline = 0
        local totalOnlineStats = 0

        -- print("|cff00ffff[GAT]|r Escaneando Roster Completo (" .. numMembers .. ")...")

        for i = 1, numMembers do
            local status, err = pcall(function()
                -- Leemos datos básicos
                local name, rank, rankIndex, level, class, zone, note, officernote, isOnline, status, classFileName, _, _, _, _, _, guid = GetGuildRosterInfo(i)
                
                if name then
                    local fullName = Ambiguate(name, "none")
                    
                    -- 1. GUARDAR ROSTER COMPLETO (Sea online u offline)
                    -- Esto es vital para que la Web sepa quién existe todavía.
                    GAT.db.roster[fullName] = {
                        rank = rank or "Desconocido",
                        level = level or 0,
                        class = classFileName or "UNKNOWN",
                        is_online = isOnline -- Guardamos si está on para la web (opcional)
                    }

                    if isOnline then 
                        totalOnlineStats = totalOnlineStats + 1 
                        countOnline = countOnline + 1
                        
                        -- 2. LÓGICA M+ (Solo Online y con GUID)
                        if guid then
                            local summary = C_PlayerInfo.GetPlayerMythicPlusRatingSummary(guid)
                            local score = 0
                            if summary and summary.currentSeasonScore then
                                score = summary.currentSeasonScore
                            end

                            -- Guardamos Míticas solo si hay datos relevantes
                            if score > 0 then
                                GAT.db.mythic[fullName] = {
                                    score = score,
                                    class = classFileName or "UNKNOWN",
                                    spec = "Desconocido"
                                }
                            end
                        end
                    end
                end
            end)
        end
        
        -- Guardar Stats Generales (Timestamp)
        local timestamp = time()
        if GAT.db.stats then
            GAT.db.stats[timestamp] = totalOnlineStats
            if GAT.Sync_RecordDelta_Stats then
                GAT:Sync_RecordDelta_Stats(timestamp, totalOnlineStats)
            end
        end
        
        GAT.LastSnapshotTime = timestamp
        GAT:ScheduleNextSnapshot()
    end

    if immediate then
        SaveData()
    else
        C_GuildInfo.GuildRoster()
        C_Timer.After(2, SaveData)
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function() if GAT.InitStats then GAT:InitStats() end end)
