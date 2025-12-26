local addonName = ...
local GAT = _G[addonName]
if not GAT then return end

-- ============================================================
--  GAT Sync (Multi-client, single-uploader, anti-duplication)
--  Objetivo:
--   - Cuando el MASTER (tu cuenta / tu PC) está online: SOLO el master cuenta chat/snapshots.
--   - Cuando el master está offline: se elige 1 LEADER automáticamente (determinístico).
--     Solo el leader cuenta y acumula deltas.
--   - Cuando el master vuelve: el leader (o su BACKUP) le envía los deltas al master.
--  Nota:
--   - No cambia el formato final de GuildActivityTrackerDB. Solo agrega GuildActivityTrackerDB._sync.
-- ============================================================

local PREFIX = "GAT_SYNC_V1"
local HB_INTERVAL = 5          -- heartbeat cada N segundos
local PRESENCE_TTL = 18        -- si no hay HB en N s, ese peer se considera offline
local MASTER_TTL = 18
local FLUSH_INTERVAL = 10      -- crear delta batch cada N segundos (leader)
local SEND_INTERVAL = 2        -- intentar enviar 1 batch cada N segundos (cuando master está online)
local MAX_PAYLOAD = 220        -- objetivo para no pasar el límite de mensaje (seguro)
local VERSION = 1

local function now() return GetTime() end

local function safe_tostring(x)
    if x == nil then return "" end
    return tostring(x)
end

local function splitTabs(s)
    local t = {}
    local start = 1
    while true do
        local p = string.find(s, "\t", start, true)
        if not p then
            t[#t+1] = string.sub(s, start)
            break
        end
        t[#t+1] = string.sub(s, start, p-1)
        start = p + 1
    end
    return t
end

local function joinTabs(...)
    return table.concat({...}, "\t")
end


local function fnv1a32(str)
    local bxor = (bit and bit.bxor) or (bit32 and bit32.bxor)
    if not bxor then
        return "00000000"
    end
    local h = 2166136261
    for i = 1, #str do
        h = bxor(h, str:byte(i))
        h = (h * 16777619) % 4294967296
    end
    return string.format("%08x", h)
end

local function genClientId()
    -- ID estable por instalación (no perfecto, pero consistente y corto)
    local seed = tostring(UnitGUID("player") or "") .. "|" .. tostring(GetRealmName() or "?") .. "|" .. tostring(time())
    local a = fnv1a32(seed)
    local b = fnv1a32(seed .. "|x")
    return string.sub(a .. b, 1, 12)
end

local function isGuildReady()
    -- Amarra el Sync al mismo filtro de hermandad del addon (Nexonir)
    if GAT and GAT.IsInGuild then
        return GAT:IsInGuild()
    end
    return IsInGuild and IsInGuild()
end

local function sendGuild(msg)
    if not isGuildReady() then return false end
    C_ChatInfo.SendAddonMessage(PREFIX, msg, "GUILD")
    return true
end

local function sendWhisper(target, msg)
    if not target or target == "" then return false end
    C_ChatInfo.SendAddonMessage(PREFIX, msg, "WHISPER", target)
    return true
end

local function isRecent(ts, ttl)
    return (ts ~= nil) and ((now() - ts) <= ttl)
end

local function ensureTable(root, key)
    if not root[key] then root[key] = {} end
    return root[key]
end

-- State (runtime)
GAT.sync = GAT.sync or {}
local S = GAT.sync

-- Persistent state inside DB
local function ensureSyncDB()
    GAT.db = GAT.db or {}
    local sd = ensureTable(GAT.db, "_sync")
    sd.clientId = sd.clientId or genClientId()
    sd.rev = sd.rev or 0
    sd.bcastSeq = sd.bcastSeq or 1
    sd.applied = sd.applied or {}           -- applied[originId][seq]=true
    sd.outbox = sd.outbox or { nextSeq = 1, pending = {} } -- pending[seq]=delta
    sd.replica = sd.replica or {}           -- replica[originId][seq]=delta (backup)
    return sd
end


-- ============================================================
--  Mensajes (no-spam) + colores
-- ============================================================
local C_WHITE  = "FFFFFF"
local C_GRAY   = "9CA3AF"
local C_GREEN  = "22C55E"
local C_RED    = "EF4444"
local C_YELLOW = "FACC15"
local C_BLUE   = "3B82F6"

local function hex(h)
    h = tostring(h or "FFFFFF"):gsub("#","")
    if #h == 8 then h = h:sub(3) end -- AARRGGBB -> RRGGBB
    return h
end

local function color(h, txt)
    return "|cff" .. hex(h) .. tostring(txt) .. "|r"
end

local function syncPrint(key, msg)
    local sd = ensureSyncDB()
    sd._print = sd._print or {}
    if sd._print[key] == msg then return end
    sd._print[key] = msg
    if GAT and GAT.Print then
        GAT:Print(msg)
    else
        print(msg)
    end
end


-- Llamado opcional desde core.lua (si existe). No es obligatorio; el resto se inicializa en PLAYER_ENTERING_WORLD.
function GAT:InitSync()
    local _ = ensureSyncDB()
    S.clientId = GAT.db._sync.clientId
    S.peers = S.peers or {}
end


local function computeMasterAndLeader()
    -- Determina masterOnline y leaderId en base a heartbeats recientes
    local masterId, masterName
    local selfMaster = (S.isMasterAccount == true) and isGuildReady()
    if selfMaster then
        masterId = S.clientId
        masterName = S.selfName
    end
    local leaderId, backupId
    local bestMasterId = masterId
    local bestLeaderId = nil
    local candidates = {}

    for cid, peer in pairs(S.peers or {}) do
        if isRecent(peer.lastHB, PRESENCE_TTL) then
            candidates[#candidates+1] = cid
            if peer.isMaster then
                if (not bestMasterId) or (cid < bestMasterId) then
                    bestMasterId = cid
                    masterId = cid
                    masterName = peer.sender
                end
            end
        end
    end

    -- incluye self como candidato siempre (si está en guild)
    if S.clientId and isGuildReady() then
        candidates[#candidates+1] = S.clientId
    end

    local masterOnline = (masterId ~= nil)

    if not masterOnline then
        -- Leader = menor clientId entre NO-master online (incluye self)
        for _, cid in ipairs(candidates) do
            local p = S.peers[cid]
            local isMasterPeer = (p and p.isMaster) or false
            if cid == S.clientId and S.isMasterAccount then
                isMasterPeer = true
            end

            if not isMasterPeer then
                if (not bestLeaderId) or (cid < bestLeaderId) then
                    bestLeaderId = cid
                end
            end
        end
        leaderId = bestLeaderId

        -- Backup = segundo menor clientId entre NO-master (excluye leader)
        local bestBackup
        for _, cid in ipairs(candidates) do
            if cid ~= leaderId then
                local p = S.peers[cid]
                local isMasterPeer = (p and p.isMaster) or false
                if cid == S.clientId and S.isMasterAccount then
                    isMasterPeer = true
                end
                if not isMasterPeer then
                    if (not bestBackup) or (cid < bestBackup) then
                        bestBackup = cid
                    end
                end
            end
        end
        backupId = bestBackup
    end

    return masterOnline, masterId, masterName, leaderId, backupId
end

local function updateRole()
    local masterOnline, masterId, masterName, leaderId, backupId = computeMasterAndLeader()

    S.masterOnline = masterOnline
    S.masterId = masterId
    S.masterName = masterName
    S.leaderId = leaderId
    S.backupId = backupId

    local prevRole = S.role
    if masterOnline then
        S.role = (S.isMasterAccount and "master") or "follower"
    else
        S.role = (S.clientId == leaderId and "leader") or "follower"
    end

    if prevRole ~= S.role then
        local msg
        if S.isMasterAccount then
            msg = color(C_BLUE, "GM") .. " " .. color(C_GRAY, "(Master)") .. ": " ..
                  color(C_GREEN, "recopilando") .. " + " .. color(C_BLUE, "sincronizando") .. "."
        elseif masterOnline then
            msg = color(C_GRAY, "Ayudante") .. ": " .. color(C_BLUE, "GM online") ..
                  " • " .. color(C_YELLOW, "observando") .. " (no recopila)."
        else
            if S.role == "leader" then
                msg = color(C_GREEN, "Ayudante") .. ": " .. color(C_RED, "GM offline") ..
                      " • " .. color(C_GREEN, "recopilando") .. " (se enviará al GM al volver)."
            elseif S.role == "backup" then
                msg = color(C_YELLOW, "Ayudante") .. ": " .. color(C_RED, "GM offline") ..
                      " • " .. color(C_YELLOW, "backup") .. " (guardando réplicas)."
            else
                msg = color(C_YELLOW, "Ayudante") .. ": " .. color(C_RED, "GM offline") ..
                      " • " .. color(C_YELLOW, "idle") .. " (otro ayudante recopila)."
            end
        end
        syncPrint("sync_role", msg)
    end
end



-- ============================================================
--  Master: mostrar estado de Ayudantes (sin spam)
-- ============================================================
local function updateHelpersOnlineStatus()
    if not S.isMasterAccount then return end
    local nowt = now()
    local names = {}
    for n, p in pairs(S.peers) do
        if p and p.last and (nowt - p.last) <= HB_TIMEOUT and (not p.isMaster) then
            names[#names+1] = n
        end
    end
    table.sort(names)
    local count = #names

    local sd = ensureSyncDB()
    local prev = sd._helpersCount
    local numColor = C_WHITE
    if prev == nil then
        numColor = C_WHITE
    elseif count > prev then
        numColor = C_GREEN
    elseif count < prev then
        numColor = C_RED
    end
    sd._helpersCount = count

    local msg = "Ayudantes online: " .. color(numColor, tostring(count))
    if count > 0 then
        msg = msg .. " " .. color(C_GRAY, "(" .. table.concat(names, ", ") .. ")")
    end
    syncPrint("helpers_online", msg)
end

-- =============== Delta encoding =================

local function encodeDaily(daily)
    if not daily then return "" end
    local parts = {}
    for day, cnt in pairs(daily) do
        parts[#parts+1] = day .. ":" .. tostring(cnt)
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

local function decodeDaily(s)
    local t = {}
    if not s or s == "" then return t end
    for token in string.gmatch(s, "([^|]+)") do
        local day, cnt = string.match(token, "^(%d%d%d%d%-%d%d%-%d%d):(%d+)$")
        if day and cnt then
            t[day] = tonumber(cnt) or 0
        end
    end
    return t
end

local function buildDeltaPayload(delta)
    -- convierte delta a lista de items "name,inc,lastTS,daily"
    local items = {}

    if delta.activity then
        for name, d in pairs(delta.activity) do
            local inc = d.incTotal or 0
            local lastTS = d.lastSeenTS or 0
            local daily = encodeDaily(d.daily)
            local item = table.concat({name, tostring(inc), tostring(lastTS), daily}, ",")
            items[#items+1] = item
        end
    end

    if delta.snapshots then
        for ts, onlineCount in pairs(delta.snapshots) do
            local item = "@" .. tostring(ts) .. "," .. tostring(onlineCount)
            items[#items+1] = item
        end
    end

    table.sort(items)
    return items
end

local function sendDeltaParts(msgType, target, originId, seq, items)
    -- chunk por tamaño
    local parts = {}
    local cur = ""
    local function pushCur()
        if cur ~= "" then
            parts[#parts+1] = cur
            cur = ""
        end
    end

    for _, item in ipairs(items) do
        local add = (cur == "") and item or (cur .. ";" .. item)
        local header = joinTabs(msgType, originId, tostring(seq), "1", "1", "") -- placeholder
        local estimate = #header + #add
        if estimate > MAX_PAYLOAD then
            pushCur()
            cur = item
        else
            cur = add
        end
    end
    pushCur()
    local total = #parts
    for i=1,total do
        local msg = joinTabs(msgType, originId, tostring(seq), tostring(i), tostring(total), parts[i])
        sendWhisper(target, msg)
    end
end


local function sendDeltaPartsGuild(msgType, originId, seq, items)
    -- Igual que sendDeltaParts, pero a canal GUILD (para sincronizar UI de todos)
    local parts = {}
    local cur = ""
    local function pushCur()
        if cur ~= "" then
            parts[#parts+1] = cur
            cur = ""
        end
    end

    for _, item in ipairs(items) do
        local add = (cur == "") and item or (cur .. ";" .. item)
        local header = joinTabs(msgType, originId, tostring(seq), "1", "1", "") -- placeholder
        local estimate = #header + #add
        if estimate > MAX_PAYLOAD then
            pushCur()
            cur = item
        else
            cur = add
        end
    end
    pushCur()
    local total = #parts
    for i=1,total do
        local msg = joinTabs(msgType, originId, tostring(seq), tostring(i), tostring(total), parts[i])
        sendGuild(msg)
    end
end


local function applyDeltaToDB(delta)
    if not GAT.db or not GAT.db.data then return end

    if delta.activity then
        for name, d in pairs(delta.activity) do
            local entry = GAT.db.data[name]
            if not entry then
                entry = { total = 0, lastSeen = "", lastMessage = "", daily = {}, rankIndex = 99, rankName = "—" }
                GAT.db.data[name] = entry
            end

            local inc = tonumber(d.incTotal or 0) or 0
            entry.total = (tonumber(entry.total) or 0) + inc

            local lastTS = tonumber(d.lastSeenTS or 0) or 0
            if lastTS > 0 then
                -- Mantén el formato del addon (texto) sin romper nada
                local newLastSeen = date("%Y-%m-%d %I:%M %p", lastTS)
                if entry.lastSeen == "" or (entry._lastSeenTS and lastTS > entry._lastSeenTS) then
                    entry.lastSeen = newLastSeen
                    entry._lastSeenTS = lastTS -- campo interno, inocuo para uploader
                end
            end

            entry.daily = entry.daily or {}
            if d.daily then
                for day, cnt in pairs(d.daily) do
                    entry.daily[day] = (tonumber(entry.daily[day]) or 0) + (tonumber(cnt) or 0)
                end
            end
        end
    end

    if delta.snapshots then
        GAT.db.stats = GAT.db.stats or {}
        for ts, onlineCount in pairs(delta.snapshots) do
            if not GAT.db.stats[ts] then
                GAT.db.stats[ts] = onlineCount
            end
        end
    end

    -- rev para debug y para futuro state sync
    local sd = ensureSyncDB()
    sd.rev = (sd.rev or 0) + 1
end


local function applyDeleteToDB(name)
    if not name or name == "" then return end
    if not GAT.db or not GAT.db.data then return end

    -- No re-broadcast aquí: el que borra es el master
    if GAT.db.data[name] then
        GAT.db.data[name] = nil
        local sd = ensureSyncDB()
        sd.rev = (sd.rev or 0) + 1
        if GAT.RefreshUI then GAT:RefreshUI() end
    end
end

local function broadcastDelete(name)
    if not name or name == "" then return end
    -- Solo el master build puede emitir deletes
    if not (S and S.isMasterAccount) then return end
    sendGuild(joinTabs("X", name))
end

function GAT:Sync_BroadcastDelete(name)
    broadcastDelete(name)
end

local function broadcastDeltaToGuild(delta)
    if not delta then return end
    local sd = ensureSyncDB()
    local seq = sd.bcastSeq or 1
    sd.bcastSeq = seq + 1
    local items = buildDeltaPayload(delta)
    sendDeltaPartsGuild("U", S.clientId, seq, items)
end


-- Receiver assembly
S.incoming = S.incoming or {} -- incoming[originId][seq] = {total=, parts=, got={}, items={}}

local function onDeltaPart(sender, msgType, originId, seq, part, total, payload)
    S.incoming[originId] = S.incoming[originId] or {}
    local bucket = S.incoming[originId][seq]
    if not bucket then
        bucket = { total = total, got = {}, payloads = {} }
        S.incoming[originId][seq] = bucket
        -- Master: aviso de recepción (1 por batch)
        if (msgType ~= "U") and S.isMasterAccount then
            S._rx = S._rx or {}
            local k = originId .. ":" .. tostring(seq)
            if not S._rx[k] then
                S._rx[k] = now()
                syncPrint("rx_state",
                    color(C_BLUE, "Recibiendo sync") .. " de " .. color(C_GRAY, sender) ..
                    " • " .. color(C_YELLOW, "NO uses /reload") .. ".")
            end
        end
    end
    bucket.total = total
    bucket.got[part] = true
    bucket.payloads[part] = payload or ""

    -- complete?
    for i=1,total do
        if not bucket.got[i] then return end
    end

    -- build items list
    local all = table.concat(bucket.payloads, ";")
    local delta = { activity = {}, snapshots = {} }

    for token in string.gmatch(all, "([^;]+)") do
        if string.sub(token, 1, 1) == "@" then
            local ts, online = string.match(token, "^@(%d+),(%d+)$")
            if ts and online then
                delta.snapshots[tonumber(ts)] = tonumber(online)
            end
        else
            local name, inc, lastTS, daily = string.match(token, "^([^,]+),([^,]*),([^,]*),(.*)$")
            if name then
                local d = { incTotal = tonumber(inc) or 0, lastSeenTS = tonumber(lastTS) or 0, daily = decodeDaily(daily) }
                delta.activity[name] = d
            end
        end
    end

    -- cleanup assembly bucket
    S.incoming[originId][seq] = nil

    -- If this is REPLICA (backup store) just save; if DELTA and I'm master => apply
    local sd = ensureSyncDB()

    if msgType == "R" then
        sd.replica[originId] = sd.replica[originId] or {}
        sd.replica[originId][seq] = delta
        -- ACK replica al sender
        sendWhisper(sender, joinTabs("AR", originId, tostring(seq)))
        return
    end

    if msgType == "U" then
        -- Broadcast de actualizaciones del Master/Líder hacia todos: NO ACK
        local appliedU = sd.appliedU
        if not appliedU then
            appliedU = {}
            sd.appliedU = appliedU
        end
        appliedU[originId] = appliedU[originId] or {}
        if appliedU[originId][seq] then return end
        appliedU[originId][seq] = true

        -- Evita auto-aplicar en caso de recibir tu propio broadcast (por si acaso)
        if originId ~= S.clientId then
            applyDeltaToDB(delta)
            if GAT.RefreshUI then GAT:RefreshUI() end
        end
        return
    end
    if msgType == "D" then
        -- Solo el master aplica
        if not S.isMasterAccount then
            return
        end

        sd.applied[originId] = sd.applied[originId] or {}
        if sd.applied[originId][seq] then
            -- ya aplicado, igual ACK
            sendWhisper(sender, joinTabs("A", originId, tostring(seq)))
            return
        end

        applyDeltaToDB(delta)

        -- Master re-broadcast a la hermandad para sincronizar UI de todos
        if S.isMasterAccount then
            broadcastDeltaToGuild(delta)
            syncPrint("rx_state", color(C_GREEN, "Sync recibido") .. " de " .. color(C_GRAY, sender) .. ".")
        end

        sd.applied[originId][seq] = true

        -- ACK al sender (leader o backup)
        sendWhisper(sender, joinTabs("A", originId, tostring(seq)))

        -- opcional: refrescar UI si está abierta
        if GAT.RefreshUI then
            GAT:RefreshUI()
        end
    end
end

local function markAcked(originId, seq)
    local sd = ensureSyncDB()
    if sd.outbox and sd.outbox.pending then
        sd.outbox.pending[seq] = nil

    -- ¿Quedan batches pendientes?
    local remaining = 0
    for _ in pairs(sd.outbox.pending) do remaining = remaining + 1 end
    if remaining == 0 then
        if S._tx then S._tx.active = false end
        syncPrint("tx_state", color(C_GREEN, "Sync COMPLETADO") .. ": datos entregados al " .. color(C_BLUE, "GM") .. ".")
        syncPrint("tx_warn", "")
    end

    -- ¿Quedan batches pendientes?
    local remaining = 0
    for _ in pairs(sd.outbox.pending) do remaining = remaining + 1 end
    if remaining == 0 then
        if S._tx then S._tx.active = false end
        syncPrint("tx_state", color(C_GREEN, "Sync COMPLETADO") .. ": datos entregados al " .. color(C_BLUE, "GM") .. ".")
        syncPrint("tx_warn", "") -- limpia warning si existía
    end
    end
    -- también quita replicas si eres backup
    if sd.replica and sd.replica[originId] then
        sd.replica[originId][seq] = nil
        if next(sd.replica[originId]) == nil then
            sd.replica[originId] = nil
        end
    end
end

-- ================== Public API used by other files ==================

function GAT:ShouldCountChat()
    -- Master online => solo master cuenta
    if S.masterOnline then
        return S.isMasterAccount
    end
    -- Master offline => solo leader cuenta
    return (S.role == "leader")
end

function GAT:Sync_RecordChat(fullPlayerName, msg, lineId, guid)
    -- Solo guardamos deltas si este cliente está contando (leader)
    if not self:ShouldCountChat() then return end
    local sd = ensureSyncDB()

    S.pending = S.pending or { activity = {}, snapshots = {} }
    local today = date("%Y-%m-%d")
    local a = S.pending.activity[fullPlayerName]
    if not a then
        a = { incTotal = 0, lastSeenTS = 0, daily = {} }
        S.pending.activity[fullPlayerName] = a
    end
    a.incTotal = (a.incTotal or 0) + 1
    a.daily[today] = (a.daily[today] or 0) + 1
    a.lastSeenTS = time()
end

function GAT:Sync_RecordSnapshot(ts, totalOnlineStats)
    if not self:ShouldCountChat() then return end
    S.pending = S.pending or { activity = {}, snapshots = {} }
    S.pending.snapshots[ts] = totalOnlineStats
end

-- ================== Flush & Send loop ==================

local function makeDeltaFromPending()
    if not S.pending then return nil end
    local hasAny = false
    local delta = { activity = {}, snapshots = {} }

    for name, d in pairs(S.pending.activity or {}) do
        delta.activity[name] = d
        hasAny = true
    end
    for ts, val in pairs(S.pending.snapshots or {}) do
        delta.snapshots[ts] = val
        hasAny = true
    end

    if not hasAny then return nil end
    -- reset pending
    S.pending = { activity = {}, snapshots = {} }
    return delta
end

local function enqueueOutbox(delta)
                broadcastDeltaToGuild(delta)
    local sd = ensureSyncDB()
    local seq = sd.outbox.nextSeq or 1
    sd.outbox.nextSeq = seq + 1
    sd.outbox.pending[seq] = delta

    S.sendQueue = S.sendQueue or {}
    S.sendQueue[#S.sendQueue+1] = seq
end

local function getTargetMasterName()
    if not S.masterOnline then return nil end
    return S.masterName
end

local function trySendOneBatch()
    if not S.masterOnline then return end
    if S.isMasterAccount then return end -- master no se manda a sí mismo

    local sd = ensureSyncDB()
    S.sendQueue = S.sendQueue or {}

    -- Si no hay queue, reconstruye a partir de pending en DB (por si reload)
    if #S.sendQueue == 0 then
        local seqs = {}
        for seq, _ in pairs(sd.outbox.pending or {}) do
            seqs[#seqs+1] = seq
        end
        table.sort(seqs)
        for _, seq in ipairs(seqs) do
            S.sendQueue[#S.sendQueue+1] = seq
        end
    end

    local seq = S.sendQueue[1]
    if not seq then return end

    local delta = sd.outbox.pending[seq]
    if not delta then
        table.remove(S.sendQueue, 1)
        return
    end

    -- UX: avisos (sin spam) mientras se envían batches al GM
    S._tx = S._tx or {}
    if not S._tx.active then
        S._tx.active = true
        S._tx.started = now()
        S._tx.warned = false
        syncPrint("tx_state",
            color(C_YELLOW, "Sync INICIADO") .. ": enviando datos al " .. color(C_BLUE, "GM") ..
            " • " .. color(C_YELLOW, "NO uses /reload") .. " hasta terminar.")
    end
    S._tx.lastSent = now()

    local target = getTargetMasterName()
    if not target then return end

    local items = buildDeltaPayload(delta)
    sendDeltaParts("D", target, S.clientId, seq, items)
end

local function replicateToBackupIfNeeded(seq, delta)
    if S.masterOnline then return end
    if S.role ~= "leader" then return end
    if not S.backupId then return end

    local backup = S.peers[S.backupId]
    if not backup or not isRecent(backup.lastHB, PRESENCE_TTL) then return end

    local items = buildDeltaPayload(delta)
    sendDeltaParts("R", backup.sender, S.clientId, seq, items)
end

local function forwardReplicaIfLeaderMissing()
    if not S.masterOnline then return end
    if S.isMasterAccount then return end

    -- Solo si NO hay leader online
    if S.leaderId and S.peers[S.leaderId] and isRecent(S.peers[S.leaderId].lastHB, PRESENCE_TTL) then
        return
    end

    local sd = ensureSyncDB()
    if not sd.replica then return end
    local target = getTargetMasterName()
    if not target then return end

    for originId, batches in pairs(sd.replica) do
        local seqs = {}
        for seq,_ in pairs(batches) do seqs[#seqs+1]=seq end
        table.sort(seqs)
        for _, seq in ipairs(seqs) do
            local delta = batches[seq]
            if delta then
                local items = buildDeltaPayload(delta)
                sendDeltaParts("D", target, originId, seq, items) -- nota: originId original
            end
        end
    end
end

-- ================== Event wiring ==================

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        if prefix ~= PREFIX then return end
        if not msg or msg == "" then return end

        local parts = splitTabs(msg)
        local typ = parts[1]

        if typ == "HB" then
            local cid = parts[2]
            local ver = tonumber(parts[3]) or 0
            local isMaster = (parts[4] == "1")
            local rev = tonumber(parts[5]) or 0

            if not cid or cid == "" then return end
            S.peers = S.peers or {}
            local p = S.peers[cid] or {}
            p.sender = sender
            p.ver = ver
            p.isMaster = isMaster
            p.rev = rev
            p.lastHB = now()
            S.peers[cid] = p

            -- Recalcula role rápido cuando llega HB
            updateRole()
            return
        end

        if typ == "D" or typ == "R" or typ == "U" then
            local originId = parts[2]
            local seq = tonumber(parts[3]) or 0
            local part = tonumber(parts[4]) or 1
            local total = tonumber(parts[5]) or 1
            local payload = parts[6] or ""
            if originId and seq > 0 then
                onDeltaPart(sender, typ, originId, seq, part, total, payload)
            end
            return
        end

        if typ == "A" then
            local originId = parts[2]
            local seq = tonumber(parts[3]) or 0
            if originId and seq > 0 then
                markAcked(originId, seq)
            end
            return
        end

        if typ == "AR" then
            -- ACK replica: no hace falta hacer nada crítico (solo debug)
            return
        end
        if typ == "X" then
            local name = parts[2]
            applyDeleteToDB(name)
            return
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        -- init prefix, peers, tickers
        if S._initialized then return end
        S._initialized = true

        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

        -- Ensure DB & ids
        local sd = ensureSyncDB()
        S.clientId = sd.clientId
        S.selfName = (UnitName("player") or "player") .. "-" .. ((GetRealmName() or "?"):gsub("%s+", ""))

        -- master flag por build (solo el addon con master.lua puede ser Master)
        -- (En followers, GAT.IS_MASTER_BUILD no existe y esto queda false)
        S.isMasterAccount = (GAT.IS_MASTER_BUILD == true)

        -- (Compat) guardamos en settings para debug, pero NO se usa para decidir roles
        GAT.db.settings = GAT.db.settings or {}
        GAT.db.settings.masterAccount = S.isMasterAccount

        S.peers = S.peers or {}

        -- Heartbeat ticker (todos)
        C_Timer.NewTicker(HB_INTERVAL, function()
            if not isGuildReady() then return end
            local isMaster = S.isMasterAccount and "1" or "0"
            local rev = (ensureSyncDB().rev or 0)
            sendGuild(joinTabs("HB", S.clientId, tostring(VERSION), isMaster, tostring(rev)))
        end)

        -- Role maintenance
        C_Timer.NewTicker(3, function()
            if not isGuildReady() then return end
            updateRole()
            updateHelpersOnlineStatus()

            -- si master apareció, intenta forward replica si el leader falta
            forwardReplicaIfLeaderMissing()
        end)

        -- Leader flush ticker
        C_Timer.NewTicker(FLUSH_INTERVAL, function()
            if not isGuildReady() then return end
            updateRole()
            if S.role == "leader" and (not S.masterOnline) then
                local delta = makeDeltaFromPending()
                if delta then
                    local sd2 = ensureSyncDB()
                    local seq = sd2.outbox.nextSeq or 1
                    enqueueOutbox(delta)
                    -- replicate al backup (más robusto si el leader crashea)
                    replicateToBackupIfNeeded(seq, delta)
                end
            end
        
            -- Master también emite deltas a GUILD para que los Ayudantes vean la misma data en vivo
            if S.isMasterAccount and S.masterOnline then
                local delta = makeDeltaFromPending()
                if delta then
                    broadcastDeltaToGuild(delta)
                end
            end

end)

        -- Sender ticker (cuando master online)
        C_Timer.NewTicker(SEND_INTERVAL, function()
            if not isGuildReady() then return end
            updateRole()
            trySendOneBatch()

            -- Si se queda colgado, avisa 1 sola vez (sin spam)
            if S._tx and S._tx.active and S._tx.started and (now() - S._tx.started) > 35 and not S._tx.warned then
                S._tx.warned = true
                syncPrint("tx_warn",
                    color(C_RED, "Sync en progreso...") .. " tardando más de lo normal. " ..
                    color(C_YELLOW, "Evita /reload") .. " y espera. (Si se cortó, el sistema reintenta.)")
            end
        end)

        updateRole()
        return
    end

    if event == "GUILD_ROSTER_UPDATE" then
        -- Ayuda a auto-detect master si rank cambia con el tiempo
        if not GAT.db or not GAT.db.settings then return end
        if GAT.db.settings.masterAccount == false then
            local _, rankName, rankIndex = GetGuildInfo("player")
            if (IsGuildLeader and IsGuildLeader()) or rankIndex == 0 or (rankName == "Emperador") then
                -- solo si el usuario quiere: no forzamos si ya está manualmente en false, lo dejamos.
                -- (si quieres forzarlo, cambia esta condición)
            end
        end
    end
end)

-- Public helper: for debug
function GAT:GetSyncStatus()
    return {
        clientId = S.clientId,
        role = S.role,
        masterOnline = S.masterOnline,
        masterName = S.masterName,
        leaderId = S.leaderId,
        backupId = S.backupId,
        isMasterAccount = S.isMasterAccount,
        rev = (GAT.db and GAT.db._sync and GAT.db._sync.rev) or 0
    }
end
