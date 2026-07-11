local ADDON_NAME = "GuildRadar"
local PREFIX = "HSGuildRadar"
local PROTOCOL_VERSION = "2"
local LEGACY_PROTOCOL_VERSION = "1"
local FIELD_SEPARATOR = string.char(31)

local SEND_INTERVAL = 2
local HEARTBEAT_INTERVAL = 8
local STALE_TIMEOUT = 20
local MAP_REFRESH_INTERVAL = 0.25
local POSITION_THRESHOLD = 0.0015
local MAX_MAP_HIERARCHY_DEPTH = 8
local MAX_POSITIONS_PER_SNAPSHOT = 32
local TOOLTIP_HEALTH_BAR_WIDTH = 150
local TOOLTIP_HEALTH_BAR_HEIGHT = 12
-- Texto invisível de largura constante usado apenas para reservar a coluna
-- da barra. A vida real é desenhada dentro da StatusBar.
local TOOLTIP_HEALTH_PLACEHOLDER = "000.000.000 / 000.000.000"

local addon = CreateFrame("Frame")
local players = {}
local pins = {}

local playerName
local sendElapsed = 0
local mapElapsed = 0
local lastBroadcastAt = 0
local lastUnavailableAt = 0
local lastSnapshot
local broadcastSequence = 0
local isScanningMap = false
local lastBroadcastHealth
local lastBroadcastMaxHealth
local tooltipHealthBar

local CLASS_ICON_TCOORDS = {
    WARRIOR     = { 0, 0.25, 0, 0.25 },
    MAGE        = { 0.25, 0.49609375, 0, 0.25 },
    ROGUE       = { 0.49609375, 0.7421875, 0, 0.25 },
    DRUID       = { 0.7421875, 0.98828125, 0, 0.25 },
    HUNTER      = { 0, 0.25, 0.25, 0.5 },
    SHAMAN      = { 0.25, 0.49609375, 0.25, 0.5 },
    PRIEST      = { 0.49609375, 0.7421875, 0.25, 0.5 },
    WARLOCK     = { 0.7421875, 0.98828125, 0.25, 0.5 },
    PALADIN     = { 0, 0.25, 0.5, 0.75 },
    DEATHKNIGHT = { 0.25, 0.49609375, 0.5, 0.75 },
}

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff55aaffGuildRadar:|r " .. tostring(message))
end

local function Trim(text)
    return (string.gsub(text or "", "^%s*(.-)%s*$", "%1"))
end

local function StripRealm(name)
    if not name then
        return nil
    end

    return string.match(name, "^[^-]+") or name
end

local function CleanField(value, maximumLength)
    local text = tostring(value or "")
    text = string.gsub(text, FIELD_SEPARATOR, " ")
    text = string.gsub(text, "[%c]", " ")
    text = string.gsub(text, "|", "")
    text = Trim(text)

    if maximumLength and string.len(text) > maximumLength then
        text = string.sub(text, 1, maximumLength)
    end

    return text
end

local function SplitFields(message)
    local fields = {}
    local startPosition = 1

    while true do
        local separatorPosition = string.find(message, FIELD_SEPARATOR, startPosition, true)

        if not separatorPosition then
            table.insert(fields, string.sub(message, startPosition))
            break
        end

        table.insert(fields, string.sub(message, startPosition, separatorPosition - 1))
        startPosition = separatorPosition + 1
    end

    return fields
end


local function GetCurrentMapFile()
    local mapFile = GetMapInfo()

    if mapFile and mapFile ~= "" then
        return mapFile
    end

    local continent = GetCurrentMapContinent and GetCurrentMapContinent() or nil
    local cosmicID = WORLDMAP_COSMIC_ID or -1
    local worldID = WORLDMAP_WORLD_ID or 0

    if continent == cosmicID then
        return "Cosmic"
    end

    if continent == worldID then
        return "World"
    end

    return nil
end

local function PositionKey(mapFile, floor)
    return tostring(mapFile or "") .. ":" .. tostring(tonumber(floor) or 0)
end

local function IsValidPosition(x, y)
    return x
        and y
        and x >= 0
        and x <= 1
        and y >= 0
        and y <= 1
        and not (x == 0 and y == 0)
end

local function GetMapIdentity()
    return table.concat({
        tostring(GetCurrentMapContinent and GetCurrentMapContinent() or ""),
        tostring(GetCurrentMapZone and GetCurrentMapZone() or ""),
        tostring(GetCurrentMapDungeonLevel and GetCurrentMapDungeonLevel() or 0),
        tostring(GetCurrentMapFile() or ""),
    }, ":")
end

local function SaveMapView()
    return {
        areaID = GetCurrentMapAreaID and GetCurrentMapAreaID() or nil,
        continent = GetCurrentMapContinent and GetCurrentMapContinent() or nil,
        zone = GetCurrentMapZone and GetCurrentMapZone() or nil,
        floor = GetCurrentMapDungeonLevel and GetCurrentMapDungeonLevel() or 0,
    }
end

local function RestoreMapView(state)
    if not state then
        return
    end

    local restored = false

    if state.areaID and state.areaID > 0 and SetMapByID then
        SetMapByID(state.areaID)
        restored = true
    end

    if not restored and state.continent ~= nil and SetMapZoom then
        if state.zone and state.zone > 0 then
            SetMapZoom(state.continent, state.zone)
        else
            SetMapZoom(state.continent)
        end
    end

    local numberOfLevels = GetNumDungeonMapLevels and GetNumDungeonMapLevels() or 0

    if state.floor and state.floor > 0 and numberOfLevels > 0 and SetDungeonMapLevel then
        SetDungeonMapLevel(state.floor)
    end
end

local function StoreCurrentPosition(snapshot, floor)
    local mapFile = GetCurrentMapFile()
    local x, y = GetPlayerMapPosition("player")

    if not mapFile or not IsValidPosition(x, y) then
        return
    end

    floor = tonumber(floor) or 0
    local key = PositionKey(mapFile, floor)

    if not snapshot.positions[key] then
        table.insert(snapshot.order, key)
    end

    snapshot.positions[key] = {
        mapFile = mapFile,
        floor = floor,
        x = x,
        y = y,
    }
end

local function CollectCurrentMapLayers(snapshot)
    local originalFloor = GetCurrentMapDungeonLevel and GetCurrentMapDungeonLevel() or 0
    local numberOfLevels = GetNumDungeonMapLevels and GetNumDungeonMapLevels() or 0

    if numberOfLevels > 0 and SetDungeonMapLevel then
        for floor = 1, numberOfLevels do
            SetDungeonMapLevel(floor)
            StoreCurrentPosition(snapshot, floor)
        end

        if originalFloor >= 1 and originalFloor <= numberOfLevels then
            SetDungeonMapLevel(originalFloor)
        end
    else
        StoreCurrentPosition(snapshot, originalFloor)
    end
end

local function CollectAllPositionSnapshots()
    -- Nunca altere o mapa enquanto ele estiver visível. Toda a varredura da
    -- hierarquia acontece somente com o WorldMapFrame fechado.
    if WorldMapFrame and WorldMapFrame:IsShown() then
        return nil
    end

    local snapshot = {
        positions = {},
        order = {},
    }

    local savedView = SaveMapView()

    isScanningMap = true

    -- Começa exatamente na zona em que o personagem está e percorre somente
    -- os layers-pai dessa zona. Nenhuma outra zona do continente é visitada.
    SetMapToCurrentZone()

    for _ = 1, MAX_MAP_HIERARCHY_DEPTH do
        local beforeIdentity = GetMapIdentity()
        CollectCurrentMapLayers(snapshot)

        if not IsZoomOutAvailable
            or not IsZoomOutAvailable()
            or not ZoomOut
        then
            break
        end

        -- O mapa está fechado neste ponto, portanto a troca não é visível.
        ZoomOut()

        if GetMapIdentity() == beforeIdentity then
            break
        end
    end

    -- Restaura o estado interno antes que o usuário abra novamente o mapa.
    RestoreMapView(savedView)
    isScanningMap = false

    if #snapshot.order == 0 then
        return nil
    end

    return snapshot
end

local function CloneSnapshot(snapshot)
    if not snapshot then
        return nil
    end

    local clone = {
        positions = {},
        order = {},
    }

    for _, key in ipairs(snapshot.order or {}) do
        local position = snapshot.positions and snapshot.positions[key]

        if position then
            clone.positions[key] = {
                mapFile = position.mapFile,
                floor = position.floor,
                x = position.x,
                y = position.y,
            }
            table.insert(clone.order, key)
        end
    end

    return clone
end

local function InitializeDatabase()
    if type(HellstormGuildMapDB) ~= "table" then
        HellstormGuildMapDB = {}
    end

    if HellstormGuildMapDB.enabled == nil then
        HellstormGuildMapDB.enabled = true
    end

    if type(HellstormGuildMapDB.markerSize) ~= "number" then
        HellstormGuildMapDB.markerSize = 18
    end

    if HellstormGuildMapDB.markerSize < 12 then
        HellstormGuildMapDB.markerSize = 12
    elseif HellstormGuildMapDB.markerSize > 32 then
        HellstormGuildMapDB.markerSize = 32
    end
end

local function IsEnabled()
    return HellstormGuildMapDB and HellstormGuildMapDB.enabled
end

local function GetLocalizedClassName(classToken)
    if LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classToken] then
        return LOCALIZED_CLASS_NAMES_MALE[classToken]
    end

    return classToken or "Desconhecida"
end

local function HideAllPins()
    for _, pin in pairs(pins) do
        pin:Hide()
    end
end

local function UpdatePinAppearance(pin, data)
    local size = HellstormGuildMapDB.markerSize or 18
    pin:SetWidth(size)
    pin:SetHeight(size)

    local coordinates = CLASS_ICON_TCOORDS[data.classToken]

    if coordinates then
        pin.icon:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
        pin.icon:SetTexCoord(coordinates[1], coordinates[2], coordinates[3], coordinates[4])
    else
        pin.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        pin.icon:SetTexCoord(0, 1, 0, 1)
    end

    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[data.classToken]

    if color then
        pin:SetBackdropBorderColor(color.r, color.g, color.b, 1)
    else
        pin:SetBackdropBorderColor(0.8, 0.8, 0.8, 1)
    end
end

local function FormatHealthNumber(value)
    value = math.max(0, math.floor(tonumber(value) or 0))
    local reversed = string.reverse(tostring(value))
    reversed = string.gsub(reversed, "(%d%d%d)", "%1.")

    local formatted = string.reverse(reversed)

    if string.sub(formatted, 1, 1) == "." then
        formatted = string.sub(formatted, 2)
    end

    return formatted
end

local function EnsureTooltipHealthBar()
    if tooltipHealthBar then
        return tooltipHealthBar
    end

    local bar = CreateFrame("StatusBar", nil, GameTooltip)
    bar:SetWidth(TOOLTIP_HEALTH_BAR_WIDTH)
    bar:SetHeight(TOOLTIP_HEALTH_BAR_HEIGHT)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetFrameLevel(GameTooltip:GetFrameLevel() + 10)

    bar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    bar:SetBackdropColor(0, 0, 0, 0.90)
    bar:SetBackdropBorderColor(0.65, 0.65, 0.65, 1)

    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bar.text:SetPoint("CENTER", bar, "CENTER", 0, 0)
    bar.text:SetTextColor(1, 1, 1, 1)

    bar:Hide()
    tooltipHealthBar = bar

    GameTooltip:HookScript("OnHide", function()
        bar:Hide()
    end)

    return bar
end

local function GetHealthDisplay(data)
    local health = tonumber(data.health)
    local maxHealth = tonumber(data.maxHealth)

    if not health or not maxHealth or maxHealth <= 0 then
        return "Vida desconhecida"
    end

    health = math.max(0, math.min(health, maxHealth))
    return FormatHealthNumber(health) .. " / " .. FormatHealthNumber(maxHealth)
end

local function ShowTooltipHealthBar(data)
    local bar = EnsureTooltipHealthBar()
    local health = tonumber(data.health)
    local maxHealth = tonumber(data.maxHealth)
    local healthText = GetHealthDisplay(data)
    local rightLine = GameTooltipTextRight1

    -- A barra nunca depende da largura do número da vida. O FontString da
    -- direita usa um placeholder fixo, portanto 50/50 e 1.000/1.000 ocupam
    -- exatamente a mesma coluna e não deslocam a barra.
    bar:SetWidth(TOOLTIP_HEALTH_BAR_WIDTH)
    bar:SetHeight(TOOLTIP_HEALTH_BAR_HEIGHT)
    bar:ClearAllPoints()

    if rightLine then
        rightLine:SetWidth(TOOLTIP_HEALTH_BAR_WIDTH)
        rightLine:SetTextColor(1, 1, 1, 0)
        bar:SetPoint("CENTER", rightLine, "CENTER", 0, 0)
    else
        bar:SetPoint("TOPRIGHT", GameTooltip, "TOPRIGHT", -10, -10)
    end

    if health and maxHealth and maxHealth > 0 then
        health = math.max(0, math.min(health, maxHealth))
        local percentage = health / maxHealth

        bar:SetMinMaxValues(0, maxHealth)
        bar:SetValue(health)

        if percentage > 0.50 then
            bar:SetStatusBarColor(0.10, 0.80, 0.10, 1)
        elseif percentage > 0.25 then
            bar:SetStatusBarColor(0.90, 0.70, 0.10, 1)
        else
            bar:SetStatusBarColor(0.85, 0.10, 0.10, 1)
        end
    else
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0)
        bar:SetStatusBarColor(0.35, 0.35, 0.35, 1)
    end

    bar.text:SetText(healthText)
    bar:Show()
end

local function CreatePin(name)
    local pin = CreateFrame("Button", nil, WorldMapButton)
    pin:SetWidth(18)
    pin:SetHeight(18)
    pin:SetFrameLevel(WorldMapButton:GetFrameLevel() + 20)
    pin:EnableMouse(true)

    pin:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    pin:SetBackdropColor(0, 0, 0, 0.90)

    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetPoint("TOPLEFT", pin, "TOPLEFT", 2, -2)
    pin.icon:SetPoint("BOTTOMRIGHT", pin, "BOTTOMRIGHT", -2, 2)

    pin:SetScript("OnEnter", function(self)
        local data = self.data

        if not data then
            return
        end

        local x = self:GetCenter()
        local parentX = WorldMapButton:GetCenter()

        if x and parentX and x > parentX then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        else
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        end

        local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[data.classToken]

        if classColor then
            GameTooltip:AddDoubleLine(
                data.name,
                TOOLTIP_HEALTH_PLACEHOLDER,
                classColor.r,
                classColor.g,
                classColor.b,
                1, 1, 1
            )
        else
            GameTooltip:AddDoubleLine(
                data.name,
                TOOLTIP_HEALTH_PLACEHOLDER,
                1, 1, 1,
                1, 1, 1
            )
        end

        GameTooltip:AddDoubleLine(
            "Nível",
            tostring(data.level or "?"),
            0.85, 0.85, 0.85,
            1, 1, 1
        )

        GameTooltip:AddDoubleLine(
            "Classe",
            GetLocalizedClassName(data.classToken),
            0.85, 0.85, 0.85,
            1, 1, 1
        )

        GameTooltip:AddDoubleLine(
            "Rank na guilda",
            data.rankName ~= "" and data.rankName or "Desconhecido",
            0.85, 0.85, 0.85,
            1, 1, 1
        )

        -- Reserva uma coluna de largura invariável antes de o tooltip
        -- calcular seu tamanho final.
        if GameTooltipTextRight1 then
            GameTooltipTextRight1:SetWidth(TOOLTIP_HEALTH_BAR_WIDTH)
            GameTooltipTextRight1:SetTextColor(1, 1, 1, 0)
        end

        GameTooltip:Show()
        ShowTooltipHealthBar(data)
    end)

    pin:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    pins[name] = pin
    return pin
end

local function FloorsMatch(remoteFloor, currentFloor)
    remoteFloor = tonumber(remoteFloor) or 0
    currentFloor = tonumber(currentFloor) or 0

    return remoteFloor == currentFloor
end

local function RefreshPins()
    if isScanningMap then
        return
    end

    if not IsEnabled()
        or not WorldMapFrame
        or not WorldMapFrame:IsShown()
        or not WorldMapButton
        or not WorldMapButton:IsShown()
    then
        HideAllPins()
        return
    end

    local currentMap = GetCurrentMapFile()
    local currentFloor = GetCurrentMapDungeonLevel() or 0
    local currentPositionKey = PositionKey(currentMap, currentFloor)
    local now = GetTime()
    local expiredNames = {}

    for name, data in pairs(players) do
        if now - data.lastSeen > STALE_TIMEOUT then
            table.insert(expiredNames, name)
        else
            local pin = pins[name]

            if not pin then
                pin = CreatePin(name)
            end

            local position = data.positions and data.positions[currentPositionKey]

            if currentMap
                and position
                and FloorsMatch(position.floor, currentFloor)
                and position.x >= 0
                and position.x <= 1
                and position.y >= 0
                and position.y <= 1
            then
                pin.data = data
                UpdatePinAppearance(pin, data)
                pin:ClearAllPoints()
                pin:SetPoint(
                    "CENTER",
                    WorldMapButton,
                    "TOPLEFT",
                    position.x * WorldMapButton:GetWidth(),
                    -position.y * WorldMapButton:GetHeight()
                )
                pin:Show()

                if GameTooltip:IsShown() and GameTooltip:GetOwner() == pin then
                    ShowTooltipHealthBar(data)
                end
            else
                pin:Hide()
            end
        end
    end

    for _, name in ipairs(expiredNames) do
        players[name] = nil

        if pins[name] then
            pins[name]:Hide()
        end
    end
end

local function SendRawMessage(message)
    local guildName = GetGuildInfo("player")

    if not guildName then
        return false
    end

    SendAddonMessage(PREFIX, message, "GUILD")
    return true
end

local function SendUnavailable(force)
    local now = GetTime()

    if not force and now - lastUnavailableAt < HEARTBEAT_INTERVAL then
        return
    end

    if SendRawMessage(table.concat({ "X", PROTOCOL_VERSION }, FIELD_SEPARATOR)) then
        lastUnavailableAt = now
    end
end

local function GetPositionSnapshot()
    local mapIsOpen = WorldMapFrame and WorldMapFrame:IsShown()

    -- Enquanto o mapa estiver aberto, apenas reutilizamos a última coleta.
    -- Nenhuma função que troque zona, floor ou zoom é executada nesse estado.
    if mapIsOpen then
        if lastSnapshot then
            local cached = CloneSnapshot(lastSnapshot)
            cached.cached = true
            return cached
        end

        return nil, true
    end

    local snapshot = CollectAllPositionSnapshots()

    if snapshot then
        return snapshot, false
    end

    if lastSnapshot then
        local cached = CloneSnapshot(lastSnapshot)
        cached.cached = true
        return cached, false
    end

    return nil, false
end

local function PositionChanged(current, previous)
    if not previous then
        return true
    end

    if #(current.order or {}) ~= #(previous.order or {}) then
        return true
    end

    for _, key in ipairs(current.order or {}) do
        local currentPosition = current.positions and current.positions[key]
        local previousPosition = previous.positions and previous.positions[key]

        if not currentPosition or not previousPosition then
            return true
        end

        if math.abs(currentPosition.x - previousPosition.x) >= POSITION_THRESHOLD then
            return true
        end

        if math.abs(currentPosition.y - previousPosition.y) >= POSITION_THRESHOLD then
            return true
        end
    end

    return false
end

local function BroadcastPosition(force)
    if not IsEnabled() then
        return
    end

    local guildName, rankName, rankIndex = GetGuildInfo("player")

    if not guildName then
        return
    end

    local snapshot, pausedForVisibleMap = GetPositionSnapshot()

    if not snapshot then
        -- O mapa aberto nunca deve causar ZoomIn/ZoomOut, mudança de floor nem
        -- uma falsa mensagem de posição indisponível para os outros membros.
        if pausedForVisibleMap then
            return
        end

        SendUnavailable(force)
        return
    end

    local now = GetTime()
    local currentHealth = math.max(0, UnitHealth("player") or 0)
    local currentMaxHealth = math.max(1, UnitHealthMax("player") or 1)
    local changed = PositionChanged(snapshot, lastSnapshot)
    local healthChanged = currentHealth ~= lastBroadcastHealth
        or currentMaxHealth ~= lastBroadcastMaxHealth

    if not force
        and not changed
        and not healthChanged
        and now - lastBroadcastAt < HEARTBEAT_INTERVAL
    then
        return
    end

    local _, classToken = UnitClass("player")
    local level = UnitLevel("player") or 0
    local total = #snapshot.order

    if total < 1 then
        SendUnavailable(force)
        return
    end

    broadcastSequence = broadcastSequence + 1

    if broadcastSequence > 999999 then
        broadcastSequence = 1
    end

    local allSent = true

    for index, key in ipairs(snapshot.order) do
        local position = snapshot.positions[key]
        local message = table.concat({
            "P",
            PROTOCOL_VERSION,
            tostring(broadcastSequence),
            tostring(index),
            tostring(total),
            CleanField(position.mapFile, 64),
            tostring(position.floor or 0),
            string.format("%.4f", position.x),
            string.format("%.4f", position.y),
            tostring(level),
            CleanField(classToken, 16),
            tostring(rankIndex or -1),
            CleanField(rankName or "", 48),
            tostring(currentHealth),
            tostring(currentMaxHealth),
        }, FIELD_SEPARATOR)

        if not SendRawMessage(message) then
            allSent = false
            break
        end
    end

    if allSent then
        lastBroadcastAt = now
        lastUnavailableAt = 0
        lastBroadcastHealth = currentHealth
        lastBroadcastMaxHealth = currentMaxHealth

        if not snapshot.cached then
            lastSnapshot = CloneSnapshot(snapshot)
        end
    end
end

local function HandlePositionMessage(sender, fields, hasHealth)
    if fields[2] ~= PROTOCOL_VERSION then
        return
    end

    local sequence = tonumber(fields[3])
    local index = tonumber(fields[4])
    local total = tonumber(fields[5])
    local mapFile = CleanField(fields[6], 64)
    local floor = tonumber(fields[7])
    local x = tonumber(fields[8])
    local y = tonumber(fields[9])
    local level = tonumber(fields[10])
    local classToken = CleanField(fields[11], 16)
    local rankIndex = tonumber(fields[12])
    local rankName = CleanField(fields[13], 48)
    local health = hasHealth and tonumber(fields[14]) or nil
    local maxHealth = hasHealth and tonumber(fields[15]) or nil

    if not sequence
        or not index
        or not total
        or total < 1
        or total > MAX_POSITIONS_PER_SNAPSHOT
        or index < 1
        or index > total
        or mapFile == ""
        or not floor
        or not IsValidPosition(x, y)
        or not level
        or level < 1
        or level > 255
    then
        return
    end

    if hasHealth
        and (not health
            or not maxHealth
            or health < 0
            or maxHealth < 1
            or health > maxHealth)
    then
        return
    end

    local data = players[sender]

    if not data then
        data = {
            name = sender,
            positions = {},
        }
        players[sender] = data
    end

    if data.pendingSequence ~= sequence then
        data.pendingSequence = sequence
        data.pendingTotal = total
        data.pendingCount = 0
        data.pendingIndexes = {}
        data.pendingPositions = {}
    elseif data.pendingTotal ~= total then
        return
    end

    local key = PositionKey(mapFile, floor)

    data.pendingPositions[key] = {
        mapFile = mapFile,
        floor = floor,
        x = x,
        y = y,
    }

    if not data.pendingIndexes[index] then
        data.pendingIndexes[index] = true
        data.pendingCount = data.pendingCount + 1
    end

    data.pendingLevel = level
    data.pendingClassToken = classToken
    data.pendingRankIndex = rankIndex or -1
    data.pendingRankName = rankName
    data.pendingHealth = health
    data.pendingMaxHealth = maxHealth
    data.lastSeen = GetTime()

    if data.pendingCount >= data.pendingTotal then
        data.positions = data.pendingPositions
        data.sequence = data.pendingSequence
        data.level = data.pendingLevel
        data.classToken = data.pendingClassToken
        data.rankIndex = data.pendingRankIndex
        data.rankName = data.pendingRankName
        data.health = data.pendingHealth
        data.maxHealth = data.pendingMaxHealth

        data.pendingSequence = nil
        data.pendingTotal = nil
        data.pendingCount = nil
        data.pendingIndexes = nil
        data.pendingPositions = nil
        data.pendingLevel = nil
        data.pendingClassToken = nil
        data.pendingRankIndex = nil
        data.pendingRankName = nil
        data.pendingHealth = nil
        data.pendingMaxHealth = nil

        RefreshPins()
    end
end

local function HandleLegacyPositionMessage(sender, fields)
    if fields[2] ~= LEGACY_PROTOCOL_VERSION then
        return
    end

    local mapFile = CleanField(fields[3], 64)
    local floor = tonumber(fields[4])
    local x = tonumber(fields[5])
    local y = tonumber(fields[6])
    local level = tonumber(fields[7])
    local classToken = CleanField(fields[8], 16)
    local rankIndex = tonumber(fields[9])
    local rankName = CleanField(fields[10], 48)

    if mapFile == ""
        or not floor
        or not IsValidPosition(x, y)
        or not level
        or level < 1
        or level > 255
    then
        return
    end

    local key = PositionKey(mapFile, floor)

    players[sender] = {
        name = sender,
        positions = {
            [key] = {
                mapFile = mapFile,
                floor = floor,
                x = x,
                y = y,
            },
        },
        level = level,
        classToken = classToken,
        rankIndex = rankIndex or -1,
        rankName = rankName,
        lastSeen = GetTime(),
        legacy = true,
    }

    RefreshPins()
end

local function HandleAddonMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX or channel ~= "GUILD" or type(message) ~= "string" then
        return
    end

    sender = StripRealm(sender)

    if not sender or sender == playerName then
        return
    end

    local fields = SplitFields(message)
    local messageType = fields[1]

    if messageType == "X" then
        players[sender] = nil

        if pins[sender] then
            pins[sender]:Hide()
        end

        return
    end

    if messageType == "P" then
        if fields[2] == PROTOCOL_VERSION and #fields >= 13 then
            HandlePositionMessage(sender, fields, #fields >= 15)
        elseif fields[2] == LEGACY_PROTOCOL_VERSION and #fields >= 10 then
            HandleLegacyPositionMessage(sender, fields)
        end
    end
end

local function SetEnabled(enabled)
    if enabled then
        HellstormGuildMapDB.enabled = true
        Print("compartilhamento ativado.")
        BroadcastPosition(true)
    else
        SendUnavailable(true)
        HellstormGuildMapDB.enabled = false
        players = {}
        HideAllPins()
        Print("compartilhamento desativado.")
    end
end

local function SetMarkerSize(size)
    size = tonumber(size)

    if not size then
        Print("use /gr tamanho 12-32.")
        return
    end

    size = math.floor(size)

    if size < 12 or size > 32 then
        Print("o tamanho deve ficar entre 12 e 32.")
        return
    end

    HellstormGuildMapDB.markerSize = size

    for _, pin in pairs(pins) do
        pin:SetWidth(size)
        pin:SetHeight(size)
    end

    RefreshPins()
    Print("tamanho dos marcadores alterado para " .. size .. ".")
end

local function ShowStatus()
    local active = 0
    local now = GetTime()

    for _, data in pairs(players) do
        if now - data.lastSeen <= STALE_TIMEOUT then
            active = active + 1
        end
    end

    Print(IsEnabled() and "ativado." or "desativado.")
    Print(active .. " membro(s) com posição recebida nos últimos " .. STALE_TIMEOUT .. " segundos.")
    Print("tamanho dos marcadores: " .. (HellstormGuildMapDB.markerSize or 18) .. ".")
end

SLASH_HELLSTORMGUILDMAP1 = "/gr"
SLASH_HELLSTORMGUILDMAP2 = "/guildradar"

SlashCmdList["HELLSTORMGUILDMAP"] = function(message)
    message = string.lower(Trim(message))

    if message == "on" or message == "ativar" then
        SetEnabled(true)
    elseif message == "off" or message == "desativar" then
        SetEnabled(false)
    elseif message == "status" then
        ShowStatus()
    elseif string.find(message, "^tamanho%s+") then
        SetMarkerSize(string.match(message, "^tamanho%s+(%d+)$"))
    elseif string.find(message, "^size%s+") then
        SetMarkerSize(string.match(message, "^size%s+(%d+)$"))
    else
        Print("comandos:")
        Print("/gr on - ativa o compartilhamento.")
        Print("/gr off - desativa o compartilhamento.")
        Print("/gr status - mostra o estado do addon.")
        Print("/gr tamanho 18 - altera o marcador entre 12 e 32.")
    end
end

addon:RegisterEvent("ADDON_LOADED")
addon:RegisterEvent("PLAYER_LOGIN")
addon:RegisterEvent("PLAYER_ENTERING_WORLD")
addon:RegisterEvent("PLAYER_GUILD_UPDATE")
addon:RegisterEvent("ZONE_CHANGED")
addon:RegisterEvent("ZONE_CHANGED_INDOORS")
addon:RegisterEvent("ZONE_CHANGED_NEW_AREA")
addon:RegisterEvent("WORLD_MAP_UPDATE")
addon:RegisterEvent("CHAT_MSG_ADDON")

addon:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...

        if loadedAddon ~= ADDON_NAME then
            return
        end

        InitializeDatabase()

        if RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(PREFIX)
        end

        if WorldMapFrame_Update then
            hooksecurefunc("WorldMapFrame_Update", RefreshPins)
        end

        return
    end

    if event == "PLAYER_LOGIN" then
        playerName = StripRealm(UnitName("player"))
        Print("carregado. Use /gr para ver os comandos.")
        BroadcastPosition(true)
        return
    end

    if event == "CHAT_MSG_ADDON" then
        HandleAddonMessage(...)
        return
    end

    if event == "WORLD_MAP_UPDATE" then
        RefreshPins()
        return
    end

    if event == "PLAYER_GUILD_UPDATE" then
        BroadcastPosition(true)
        return
    end

    if event == "PLAYER_ENTERING_WORLD"
        or event == "ZONE_CHANGED"
        or event == "ZONE_CHANGED_INDOORS"
        or event == "ZONE_CHANGED_NEW_AREA"
    then
        if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
            lastSnapshot = nil
        end

        BroadcastPosition(true)
        RefreshPins()
    end
end)

addon:SetScript("OnUpdate", function(self, elapsed)
    sendElapsed = sendElapsed + elapsed

    if sendElapsed >= SEND_INTERVAL then
        sendElapsed = 0
        BroadcastPosition(false)
    end

    if WorldMapFrame and WorldMapFrame:IsShown() then
        mapElapsed = mapElapsed + elapsed

        if mapElapsed >= MAP_REFRESH_INTERVAL then
            mapElapsed = 0
            RefreshPins()
        end
    else
        mapElapsed = 0
    end
end)
