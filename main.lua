--------------------------------------------------
-- CoinFlip Casino v1.0
-- main.lua
-- Автор: hellbreez
-- (основан на скелете BlackJack Casino, репозиторий: HellBreezMix/Coin-Flip)
--------------------------------------------------

-- пути поиска config.lua
package.path = "/CoinFlip/?.lua;/home/CoinFlip/?.lua;" .. (package.path or "")

local function safeRequire(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    error("Не найден модуль: " .. tostring(name) .. " (" .. tostring(mod) .. ")")
end

local component     = safeRequire("component")
local event         = safeRequire("event")
local filesystem    = safeRequire("filesystem")
local serialization = safeRequire("serialization")
local term          = safeRequire("term")
local unicode       = safeRequire("unicode")
local keyboard      = safeRequire("keyboard")
local computer      = safeRequire("computer")

-- GPU: primary или первый доступный
local gpu = nil
if component.isAvailable and component.isAvailable("gpu") then
    gpu = component.getPrimary and component.getPrimary("gpu") or component.gpu
else
    for addr in component.list("gpu") do
        gpu = component.proxy(addr)
        break
    end
end
if not gpu then
    print("ОШИБКА: GPU не найден. Подключите монитор и видеокарту.")
    return
end


local okCfg, config = pcall(require, "config")
if not okCfg or not config then
    print("ОШИБКА config.lua: " .. tostring(config))
    print("Положи config.lua в /CoinFlip/config.lua")
    return
end

-- Тёмно-серая тема (жёстко, не зависит от config)
config.colors.background  = 0x1B1B1B
config.colors.feltDark    = 0x161616
config.colors.feltPattern = 0x232323
config.colors.panel       = 0x202020
config.colors.panelLight  = 0x2B2B2B
config.colors.header      = 0x141414
config.colors.textDark    = 0x8A8A8A
config.colors.button      = 0x2E2E2E
config.colors.tableGreen  = 0x1B1B1B

--------------------------------------------------
-- УТИЛИТЫ
--------------------------------------------------
local function ensureDir(path)
    local dir = filesystem.path(path)
    if dir and dir ~= "" and not filesystem.exists(dir) then
        filesystem.makeDirectory(dir)
    end
end

local function loadDB(path)
    if not filesystem.exists(path) then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return nil end
    local ok, data = pcall(serialization.unserialize, content)
    return ok and data or nil
end

local function saveDB(path, data)
    ensureDir(path)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(serialization.serialize(data))
    f:close()
    return true
end

local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = deepCopy(v) end
    return r
end

--------------------------------------------------
-- ВРЕМЯ (Москва, UTC+3)
--------------------------------------------------
local function moscowNow()
    -- real-time unix; Москва UTC+3
    local t = os.time()
    if type(t) ~= "number" or t < 100000 then
        -- fallback если os.time недоступен
        t = math.floor(computer.uptime() + 1700000000)
    end
    return t + 3 * 3600
end

local function moscowDate(fmt, t)
    fmt = fmt or "%Y-%m-%d %H:%M:%S"
    t = t or moscowNow()
    local ok, s = pcall(os.date, "!" .. fmt, t)
    if ok and s then return s end
    ok, s = pcall(os.date, fmt, t)
    if ok and s then return s end
    return "?"
end

--------------------------------------------------
-- ЛОГИ
--------------------------------------------------
local Logs = { entries = {} }

local LOG_KEEP = {
    ["ПОПОЛНЕНИЕ"] = true,
    ["ВЫВОД"] = true,
    ["ВЫИГРЫШ"] = true,
    ["ПРОИГРЫШ"] = true,
    ["ОШИБКА"] = true,
}

local function log(kind, player, text)
    kind = kind or "INFO"
    -- в UI/файл только важные события
    if not LOG_KEEP[kind] then return end
    local entry = {
        time   = moscowNow(),
        kind   = kind,
        player = player or "-",
        text   = text or ""
    }
    table.insert(Logs.entries, 1, entry)
    while #Logs.entries > 100 do table.remove(Logs.entries) end
    ensureDir(config.paths.log)
    local f = io.open(config.paths.log, "a")
    if f then
        local ts = moscowDate("%Y-%m-%d %H:%M:%S", entry.time)
        f:write(string.format("[%s] %s | %s | %s\n", ts, entry.kind, entry.player, entry.text))
        f:close()
    end
end

local function loadLogsFromFile()
    if not filesystem.exists(config.paths.log) then return end
    local f = io.open(config.paths.log, "r")
    if not f then return end
    local lines = {}
    for line in f:lines() do table.insert(lines, line) end
    f:close()
    local start = math.max(1, #lines - 80)
    for i = #lines, start, -1 do
        local line = lines[i]
        local ts, kind, player, text = line:match("%[(.-)%] (.-) | (.-) | (.+)")
        if ts and kind and LOG_KEEP[kind] then
            table.insert(Logs.entries, {
                time = 0, kind = kind, player = player or "-", text = text or line, raw = line
            })
        end
    end
end

--------------------------------------------------
-- ИГРОКИ
--------------------------------------------------
local Players = { data = {} }

function Players.load()
    Players.data = loadDB(config.paths.players) or {}
end

function Players.save()
    saveDB(config.paths.players, Players.data)
end

function Players.get(name)
    if not name then return nil end
    if not Players.data[name] then
        Players.data[name] = { balance = 0, totalPlayed = 0, totalWon = 0, games = 0, wins = 0 }
        Players.save()
    end
    local p = Players.data[name]
    p.totalPlayed = p.totalPlayed or 0
    p.totalWon = p.totalWon or 0
    return p
end

local function roundMoney(v)
    v = tonumber(v) or 0
    -- до 4 знаков, убираем float-хвосты (0.099999999)
    return math.floor(v * 10000 + 0.5) / 10000
end

local function fmtMoney(v)
    v = roundMoney(v)
    if math.abs(v - math.floor(v + 1e-9)) < 1e-9 then
        return tostring(math.floor(v + 1e-9))
    end
    local s = string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", "")
    return s
end

function Players.addBalance(name, amount)
    local p = Players.get(name)
    p.balance = math.max(0, roundMoney((p.balance or 0) + (tonumber(amount) or 0)))
    if amount and amount > 0 then p.totalWon = roundMoney((p.totalWon or 0) + amount) end
    Players.save()
    return p.balance
end

function Players.addPlayed(name, amount)
    local p = Players.get(name)
    p.totalPlayed = (p.totalPlayed or 0) + amount
    Players.save()
end

function Players.getTop(n)
    n = n or 15
    local list = {}
    for name, data in pairs(Players.data) do
        table.insert(list, { name = name, total = data.totalPlayed or 0, balance = data.balance or 0 })
    end
    table.sort(list, function(a, b) return a.total > b.total end)
    local result = {}
    for i = 1, math.min(n, #list) do result[i] = list[i] end
    return result
end

--------------------------------------------------
-- ИСТОРИЯ ПОДБРОСОВ (общая лента, таблица как в казино)
--------------------------------------------------
local History = { entries = {} }
local HISTORY_KEEP = 20  -- сколько храним; на экране показываем сколько влезает

function History.load()
    local raw = loadDB(config.paths.history) or {}
    -- отсекаем записи в старом формате (без choice/result/amount) —
    -- остались от более ранней версии истории
    local clean = {}
    for _, e in ipairs(raw) do
        if type(e) == "table" and e.choice and e.result and e.amount ~= nil then
            table.insert(clean, e)
        end
    end
    History.entries = clean
end

function History.save()
    saveDB(config.paths.history, History.entries)
end

-- choice: что выбрал игрок, result: что выпало, win: угадал ли, amount: сумма ставки/выигрыша
function History.add(choice, result, win, amount)
    table.insert(History.entries, 1, {
        choice = choice, result = result,
        win = win and true or false,
        amount = math.floor((tonumber(amount) or 0) + 0.5)
    })
    while #History.entries > HISTORY_KEEP do table.remove(History.entries) end
    History.save()
end

--------------------------------------------------
-- НАСТРОЙКИ
--------------------------------------------------
local Settings = { data = {} }

local function normalizeBuyPrices(raw)
    local result = {}
    if not raw then return result end
    for k, v in pairs(raw) do
        if type(v) == "number" then
            local short = k:match("([^:]+)$") or k
            result[k] = { price = v, label = short }
        elseif type(v) == "table" then
            result[k] = {
                price = tonumber(v.price) or 1,
                label = v.label or (k:match("([^:]+)$") or k)
            }
        end
    end
    return result
end

function Settings.load()
    local def = {
        minBet = config.bet.min,
        maxBet = config.bet.max,
        buyPrices = normalizeBuyPrices(config.buyPrices),
        payoutItem = nil,
        winPayout = config.game.winPayout or 2.0,
        houseEdge = 0,
        sessionSeconds = 40
    }
    local loaded = loadDB(config.paths.settings)
    if loaded then
        Settings.data = loaded
        Settings.data.minBet = Settings.data.minBet or config.bet.min
        Settings.data.maxBet = Settings.data.maxBet or config.bet.max
        Settings.data.buyPrices = normalizeBuyPrices(Settings.data.buyPrices or config.buyPrices)
        Settings.data.winPayout = Settings.data.winPayout or config.game.winPayout or 2.0
        Settings.data.houseEdge = tonumber(Settings.data.houseEdge) or 0
        Settings.data.sessionSeconds = tonumber(Settings.data.sessionSeconds) or 40
        -- поля от блэкджека больше не используются
        Settings.data.bjPayout = nil
        Settings.data.decks = nil
        Settings.data.hitSoft17 = nil
        Settings.data.reshuffleAt = nil
        Settings.data.shuffleEvery = nil
        Settings.data.dealerProtect = nil
        Settings.data.lessBJ = nil
        Settings.data.pushLoses = nil
    else
        Settings.data = def
    end
end

function Settings.save()
    saveDB(config.paths.settings, Settings.data)
end

function Settings.getPrice(itemId)
    local e = Settings.data.buyPrices and Settings.data.buyPrices[itemId]
    return e and e.price or nil
end

function Settings.getLabel(itemId)
    local e = Settings.data.buyPrices and Settings.data.buyPrices[itemId]
    if e and e.label then return e.label end
    return itemId:match("([^:]+)$") or itemId
end

--------------------------------------------------
-- ЖЕЛЕЗО
--------------------------------------------------
local Hardware = { transposer = nil, me = nil }

function Hardware.init()
    if component.isAvailable("transposer") then Hardware.transposer = component.transposer end
    if component.isAvailable("me_interface") then Hardware.me = component.me_interface end
end

-- Все предметы в сундуке ставки (все слоты), сгруппированные по name
function Hardware.getDepositItems()
    if not Hardware.transposer then return {} end
    local side = config.hardware.transposerSide
    local size = 27
    local okS, invSize = pcall(Hardware.transposer.getInventorySize, side)
    if okS and invSize then size = invSize end

    local groups = {}  -- name -> {name, label, damage, size, slots={}}
    for slot = 1, size do
        local ok, stack = pcall(Hardware.transposer.getStackInSlot, side, slot)
        if ok and stack and stack.size and stack.size > 0 then
            local n = stack.name
            if not groups[n] then
                groups[n] = {
                    name = n,
                    label = stack.label or n,
                    damage = stack.damage or 0,
                    size = 0,
                    slots = {}
                }
            end
            groups[n].size = groups[n].size + stack.size
            table.insert(groups[n].slots, { slot = slot, size = stack.size })
        end
    end
    local list = {}
    for _, g in pairs(groups) do table.insert(list, g) end
    return list
end

-- совместимость: первый стак
function Hardware.getDepositItem()
    local list = Hardware.getDepositItems()
    if #list == 0 then return nil end
    -- предпочитаем предмет из скупки
    for _, g in ipairs(list) do
        if Settings.getPrice(g.name) then return g end
    end
    return list[1]
end

-- Забрать count предметов name из всех слотов сундука
function Hardware.consumeDeposit(itemName, count)
    if not Hardware.transposer then return 0 end
    local side = config.hardware.transposerSide
    count = math.floor(count or 0)
    if count <= 0 then return 0 end

    local taken = 0
    local size = 27
    local okS, invSize = pcall(Hardware.transposer.getInventorySize, side)
    if okS and invSize then size = invSize end

    for slot = 1, size do
        if taken >= count then break end
        local ok, stack = pcall(Hardware.transposer.getStackInSlot, side, slot)
        if ok and stack and stack.name == itemName and stack.size and stack.size > 0 then
            local need = math.min(stack.size, count - taken)
            -- в ME
            local moved = false
            if Hardware.me and Hardware.me.importItem then
                local ok2 = pcall(Hardware.me.importItem, side, slot, need)
                if ok2 then moved = true; taken = taken + need end
            end
            if not moved then
                local ok3 = pcall(Hardware.transposer.transferItem, side, 0, need, slot)
                if ok3 then taken = taken + need end
            end
        end
    end
    return taken
end

function Hardware.exportPayout(itemName, count)
    if not Hardware.me then return 0, "ME Interface не найден" end
    if not itemName or count <= 0 then return 0, "Нет предмета" end
    count = math.floor(count)

    local sidesLib = nil
    pcall(function() sidesLib = require("sides") end)

    local function countInNetwork()
        local total, list = 0, {}
        local ok, res = pcall(function()
            return Hardware.me.getItemsInNetwork({ name = itemName })
        end)
        if not ok or not res or #res == 0 then
            ok, res = pcall(function() return Hardware.me.getItemsInNetwork() end)
            res = (ok and res) or {}
            local f = {}
            for _, it in ipairs(res) do
                if tostring(it.name or it.id) == tostring(itemName) then table.insert(f, it) end
            end
            res = f
        end
        for _, it in ipairs(res or {}) do
            total = total + (tonumber(it.size) or tonumber(it.qty) or 0)
            table.insert(list, it)
        end
        return total, list
    end

    local available, items = countInNetwork()
    if available < 1 then
        return 0, "В ME нет: " .. tostring(itemName)
    end
    if count > available then count = available end

    local stack = items[1]
    local name = tostring(stack.name or itemName)
    local dmg = tonumber(stack.damage) or 0

    -- варианты fingerprint
    local fingerprints = {
        { id = name, name = name, damage = dmg, dmg = dmg },
        { id = name, damage = dmg },
        { name = name, damage = dmg },
        { name = name },
        { id = name },
    }
    if type(stack.fingerprint) == "table" then
        table.insert(fingerprints, 1, stack.fingerprint)
    end
    -- иногда AE2 принимает сам объект из сети (без size)
    local clean = {}
    for k, v in pairs(stack) do
        if k ~= "size" and k ~= "isCraftable" and k ~= "qty" then
            clean[k] = v
        end
    end
    if not clean.id then clean.id = name end
    if not clean.name then clean.name = name end
    table.insert(fingerprints, 1, clean)

    -- стороны: сундук СВЕРХУ интерфейса
    local sideList = {}
    if sidesLib then
        table.insert(sideList, sidesLib.top or sidesLib.up or 1)
    end
    for _, s in ipairs({ 1, "UP", "up", "top", 0, "DOWN" }) do
        table.insert(sideList, s)
    end
    if config.hardware.meSide then
        table.insert(sideList, 1, config.hardware.meSide)
    end

    local function tryExport(fp, side, batch)
        local ok, result = pcall(function()
            return Hardware.me.exportItem(fp, side, batch)
        end)
        if not ok then return 0, tostring(result) end
        local n = tonumber(result)
        if n and n > 0 then return n, nil end
        -- некоторые версии возвращают true
        if result == true then return batch, nil end
        return 0, "return=" .. tostring(result)
    end

    local totalMoved = 0
    local lastErr = "неизвестно"
    local successSide = nil
    local successFp = nil

    while totalMoved < count do
        local batch = math.min(64, count - totalMoved)
        local before = countInNetwork()
        local moved = 0

        -- если уже нашли рабочую пару side+fp — используем её
        if successSide and successFp then
            local m, err = tryExport(successFp, successSide, batch)
            if m > 0 then
                moved = m
            else
                -- проверяем по факту в сети
                local after = countInNetwork()
                moved = math.max(0, before - after)
                if moved <= 0 then lastErr = err or lastErr; break end
            end
        else
            -- поиск рабочей комбинации
            for _, fp in ipairs(fingerprints) do
                if moved > 0 then break end
                for _, side in ipairs(sideList) do
                    local m, err = tryExport(fp, side, batch)
                    lastErr = err or lastErr
                    if m > 0 then
                        moved = m
                        successSide = side
                        successFp = fp
                        break
                    end
                    -- дельта в сети
                    local after = countInNetwork()
                    local delta = before - after
                    if delta > 0 then
                        moved = delta
                        successSide = side
                        successFp = fp
                        break
                    end
                    before = after -- на случай частичного
                end
            end
        end

        if moved <= 0 then
            -- финальная проверка
            local after = countInNetwork()
            moved = math.max(0, before - after)
        end

        if moved <= 0 then
            if lastErr and lastErr:find("fingerprint") then
                lastErr = "fingerprint: " .. lastErr
            elseif lastErr == "return=0" or lastErr == "return=nil" then
                lastErr = "сундук полон или неверная сторона ME"
            end
            break
        end
        totalMoved = totalMoved + moved
    end

    if totalMoved > 0 then
        if totalMoved < count then
            return totalMoved, "частично " .. totalMoved .. "/" .. count
        end
        return totalMoved, nil
    end
    return 0, lastErr or "не удалось выдать"
end

--------------------------------------------------
-- МОНЕТА
--------------------------------------------------
local Coin = {}
Coin.sides = { "ОРЁЛ", "РЕШКА" }

-- Подбрасывает монету с учётом выбора игрока и перевеса дома (houseEdge %).
-- С вероятностью houseEdge% результат намеренно противоположен выбору игрока,
-- иначе честный бросок 50/50.
function Coin.flip(choice, houseEdge)
    houseEdge = tonumber(houseEdge) or 0
    if houseEdge > 0 and math.random(100) <= houseEdge then
        return (choice == "ОРЁЛ") and "РЕШКА" or "ОРЁЛ"
    end
    return (math.random(2) == 1) and "ОРЁЛ" or "РЕШКА"
end

--------------------------------------------------
local Game = {
    state = "idle",  -- idle | flipping | result
    bet = 0, choice = nil, result = nil, win = false
}

function Game.reset()
    Game.state = "idle"
    Game.bet = 0; Game.choice = nil; Game.result = nil; Game.win = false
end

-- Определяет исход раунда (вызывается перед анимацией, чтобы анимация
-- завершилась показом уже готового результата)
function Game.decide(choice)
    Game.choice = choice
    local edge = tonumber(Settings.data.houseEdge) or 0
    Game.result = Coin.flip(choice, edge)
    Game.win = (Game.result == choice)
    return Game.result
end

function Game.finish()
    Game.state = "result"
end

function Game.payoutMultiplier()
    if Game.win then return tonumber(Settings.data.winPayout) or config.game.winPayout or 2.0 end
    return 0
end

--------------------------------------------------
-- UI
--------------------------------------------------
local UI = {
    w = 0, h = 0, screen = "main",
    playerName = nil, authorized = false,
    sessionLeft = 40, timerId = nil,
    betAmount = config.bet.default,
    choice = "ОРЁЛ",
    buttons = {}, message = nil, messageColor = config.colors.text, messageUntil = 0,
    withdraw = { active = false },
    adminTab = "bets", logScroll = 0, pendingAuth = false, alert = nil, animTimer = nil,
    anim = nil,  -- {w, side} текущий кадр анимации монеты
    editItem = { name = nil, label = "", price = "1", mode = "add", target = "buy" },
    input = { active = false, title = "", value = "", callback = nil, maxLen = 40 }
}

function UI.setMessage(text, color, seconds)
    UI.message = text
    UI.messageColor = color or config.colors.text
    UI.messageUntil = computer.uptime() + (seconds or 4)
end

function UI.clearButtons() UI.buttons = {} end

function UI.addButton(x, y, w, h, text, bg, fg, callback)
    table.insert(UI.buttons, {
        x = x, y = y, w = w, h = h,
        text = text, bg = bg, fg = fg or config.colors.text,
        cb = callback,
        -- невидимая зона клика (не перерисовывает фон)
        hitbox = (text == "" or text == nil) and (bg == 0x000000 or bg == 0)
    })
end

function UI.drawButton(b)
    if b.hitbox then return end  -- только клик, без заливки
    gpu.setBackground(b.bg); gpu.setForeground(b.fg)
    gpu.fill(b.x, b.y, b.w, b.h, " ")
    local label = b.text or ""
    local tx = b.x + math.floor((b.w - unicode.len(label)) / 2)
    local ty = b.y + math.floor((b.h - 1) / 2)
    gpu.set(tx, ty, label)
end

function UI.checkButtons(x, y)
    for _, b in ipairs(UI.buttons) do
        if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
            if b.cb then b.cb() end
            return true
        end
    end
    return false
end

function fill(x, y, w, h, color)
    gpu.setBackground(color)
    gpu.fill(x, y, w, h, " ")
end

function text(x, y, str, fg, bg)
    if bg then gpu.setBackground(bg) end
    if fg then gpu.setForeground(fg) end
    gpu.set(x, y, tostring(str))
end

function centerText(y, str, fg, bg, width)
    width = width or UI.w
    local x = math.floor((width - unicode.len(tostring(str))) / 2) + 1
    text(x, y, str, fg, bg)
end

function drawBox(x, y, w, h, borderColor, fillColor)
    fill(x, y, w, h, fillColor or config.colors.panel)
    gpu.setForeground(borderColor or config.colors.textBlue)
    gpu.setBackground(fillColor or config.colors.panel)
    for i = 0, w - 1 do
        gpu.set(x + i, y, "─"); gpu.set(x + i, y + h - 1, "─")
    end
    for i = 0, h - 1 do
        gpu.set(x, y + i, "│"); gpu.set(x + w - 1, y + i, "│")
    end
    gpu.set(x, y, "┌"); gpu.set(x + w - 1, y, "┐")
    gpu.set(x, y + h - 1, "└"); gpu.set(x + w - 1, y + h - 1, "┘")
end

-- Фон стола: статичная картинка (тёмно-серая панель + тонкая рамка)
local FELT_BASE = 0x1B1B1B
local TABLE_RAIL = 0x2E2E2E
local TABLE_RAIL_DARK = 0x141414
local _screenBuf = nil
local _tableBuf = nil   -- снимок: фон + рамка
local _tableReady = false
local _tableMw = 0
local _tableVer = 0
local TABLE_CACHE_VER = 12  -- bump = пересобрать фон
local _welcomeReady = false

function paintFeltToActive(w, h)
    fill(1, 1, w, h, FELT_BASE)
end

function paintRailToActive(mw)
    if mw < 10 then return end
    fill(1, 2, mw, 1, TABLE_RAIL)
    fill(1, UI.h, mw, 1, TABLE_RAIL)
    fill(1, 2, 1, UI.h - 1, TABLE_RAIL)
    fill(mw, 2, 1, UI.h - 1, TABLE_RAIL)
    fill(2, 3, mw - 2, 1, TABLE_RAIL_DARK)
    fill(2, UI.h - 1, mw - 2, 1, TABLE_RAIL_DARK)
    fill(2, 3, 1, UI.h - 3, TABLE_RAIL_DARK)
    fill(mw - 1, 3, 1, UI.h - 3, TABLE_RAIL_DARK)
end

-- Один раз: фон + рамка → картинка в буфере
function ensureTableCache(mw)
    mw = mw or (UI.w - (config.ui.sidebarWidth or 28))
    if _tableReady and _tableBuf and _tableMw == mw and _tableVer == TABLE_CACHE_VER then
        return true
    end
    -- сброс старого снимка
    if _tableBuf and gpu.freeBuffer then
        pcall(gpu.freeBuffer, _tableBuf)
    end
    _tableBuf = nil
    _tableReady = false

    if not (gpu.allocateBuffer and gpu.setActiveBuffer and gpu.bitblt) then
        return false
    end
    local ok, id = pcall(gpu.allocateBuffer, UI.w, UI.h)
    if not ok or not id then return false end
    _tableBuf = id
    if not pcall(gpu.setActiveBuffer, _tableBuf) then
        pcall(gpu.freeBuffer, _tableBuf)
        _tableBuf = nil
        return false
    end
    paintFeltToActive(UI.w, UI.h)
    paintRailToActive(mw)
    pcall(gpu.setActiveBuffer, 0)
    _tableReady = true
    _tableMw = mw
    _tableVer = TABLE_CACHE_VER
    return true
end

-- Быстро: положить картинку стола на экран (игровая зона)
function blitTable(mw)
    mw = mw or (UI.w - (config.ui.sidebarWidth or 28))
    pcall(gpu.setActiveBuffer, 0)
    if ensureTableCache(mw) and _tableBuf then
        pcall(gpu.bitblt, 0, 1, 1, mw, UI.h, _tableBuf, 1, 1)
        return true
    end
    -- fallback
    paintFeltToActive(mw, UI.h)
    paintRailToActive(mw)
    return false
end

-- Double-buffer для полного UI (кнопки без мигания)
function ensureScreenBuf()
    if _screenBuf then return true end
    if not _tableBuf then ensureTableCache() end
    if not (gpu.allocateBuffer and gpu.bitblt) then return false end
    local ok, id = pcall(gpu.allocateBuffer, UI.w, UI.h)
    if ok and id then _screenBuf = id; return true end
    return false
end

local _inFrame = false

function beginFrame()
    if ensureScreenBuf() and _screenBuf and pcall(gpu.setActiveBuffer, _screenBuf) then
        _inFrame = true
        return true
    end
    _inFrame = false
    pcall(gpu.setActiveBuffer, 0)
    return false
end

function present()
    if _inFrame and _screenBuf then
        pcall(gpu.setActiveBuffer, 0)
        pcall(gpu.bitblt, 0, 1, 1, UI.w, UI.h, _screenBuf, 1, 1)
    end
    _inFrame = false
    pcall(gpu.setActiveBuffer, 0)
end

-- совместимость со старыми именами
function ensureFeltCache() return ensureTableCache() end
function blitFeltArea(mw) return blitTable(mw) end
function drawTableRail(mw)
    -- окантовка уже в картинке _tableBuf; fallback если нет кэша
    if not (_tableReady and _tableBuf and _tableMw == mw) then
        paintRailToActive(mw)
    end
end

function drawScreen()
    UI.clearButtons()
    local mw = UI.w - (config.ui.sidebarWidth or 28)

    -- Админ / ввод / alert: без полной перерисовки узора — solid + double-buffer
    local isAdmin = (UI.screen == "admin" or UI.screen == "admin_add_item"
        or UI.screen == "admin_edit_item")

    beginFrame()
    local dstActive = _inFrame

    if isAdmin or UI.alert or UI.input.active or UI.withdraw.active then
        -- быстрый фон игровой зоны (без bitblt узора = меньше мигания вкладок)
        fill(1, 1, mw, UI.h, FELT_BASE)
    else
        if dstActive and _tableBuf and ensureTableCache(mw) then
            pcall(gpu.bitblt, _screenBuf, 1, 1, mw, UI.h, _tableBuf, 1, 1)
        else
            blitTable(mw)
        end
    end

    fill(mw + 1, 1, UI.w - mw, UI.h, config.colors.panel)
    UI.drawHeader()
    UI.drawSidebar()

    if UI.alert then
        UI.drawAlert()
    elseif UI.input.active then
        UI.drawInputModal()
    elseif UI.withdraw.active then
        UI.drawWithdrawModal()
    else
        UI.drawMainArea()
    end

    for _, b in ipairs(UI.buttons) do UI.drawButton(b) end

    if UI.message and computer.uptime() < (UI.messageUntil or 0) then
        local msg = tostring(UI.message)
        local barW = math.min(mw - 4, math.max(30, unicode.len(msg) + 4))
        local bx = math.floor((mw - barW) / 2) + 1
        fill(bx, UI.h - 1, barW, 1, 0x262626)
        centerText(UI.h - 1, msg, UI.messageColor or config.colors.text, 0x262626, mw)
    end

    present()
end



local COIN_W, COIN_H = 33, 15
local COIN_GOLD  = 0xE8C158

-- Эллиптическая маска монеты: используется как трафарет для отрисовки
-- и для анимации вращения (показываем только центральные `w` колонок —
-- монета визуально «поворачивается», сжимаясь и раскрываясь по горизонтали).
local function buildEllipseMask(w, h, shrink)
    shrink = shrink or 0
    local shape = {}
    local rx = (w - 1) / 2 - shrink
    local ry = (h - 1) / 2 - shrink
    local cyc = (h + 1) / 2
    for row = 1, h do
        local hw = 0
        if ry > 0 then
            local ny = (row - cyc) / ry
            if ny >= -1 and ny <= 1 then hw = rx * math.sqrt(1 - ny * ny) end
        elseif row == math.floor(cyc + 0.5) then
            hw = rx
        end
        local pad = math.max(0, math.floor((w - 1) / 2 - hw + 0.5))
        local hashLen = math.max(0, w - pad * 2)
        shape[row] = string.rep(".", pad) .. string.rep("#", hashLen) .. string.rep(".", pad)
    end
    return shape
end
local COIN_SHAPE = buildEllipseMask(COIN_W, COIN_H, 0)

-- Позиция монеты в игровой зоне (общая для главного экрана и экрана броска)
function UI.coinPos()
    local mw = UI.w - config.ui.sidebarWidth
    local cx = math.floor(mw / 2)
    return cx - math.floor(COIN_W / 2), 2, mw, cx
end

function eraseCoin(x, y)
    gpu.setBackground(FELT_BASE)
    gpu.fill(x, y, COIN_W, COIN_H, " ")
end

-- w: видимая ширина монеты в текущем кадре (1..COIN_W) — эмуляция вращения.
-- side: "ОРЁЛ"/"РЕШКА" — слово показывается целиком, когда монета почти "анфас" (w велико).
function drawCoin(x, y, w, side)
    w = math.max(1, math.min(COIN_W, math.floor(w)))
    local left = math.floor((COIN_W - w) / 2) + 1
    gpu.setForeground(COIN_GOLD)
    gpu.setBackground(FELT_BASE)
    for row = 1, COIN_H do
        local line = COIN_SHAPE[row]
        for col = left, left + w - 1 do
            if line:sub(col, col) == "#" then
                gpu.set(x + col - 1, y + row - 1, "█")
            end
        end
    end
    if side and w >= math.floor(COIN_W * 0.6) then
        local textBg = COIN_GOLD
        text(x + math.floor((COIN_W - unicode.len(side)) / 2), y + math.floor(COIN_H / 2), side, 0x3A2A00, textBg)
    end
end

-- Таблица истории — как в казино: результат, выбор > выпало, сумма
function UI.drawHistoryList(x, y, mw, maxRows)
    maxRows = math.min(maxRows or 10, 10)
    local n = #History.entries
    local rows = math.min(maxRows, n)
    local boxW = math.max(38, math.min(mw - x - 2, 44))
    local boxH = (n == 0) and 5 or (rows + 4)

    drawBox(x, y, boxW, boxH, config.colors.textDark, config.colors.panel)
    text(x + 2, y, " Последние 10 бросков ", config.colors.textBlue, config.colors.panel)

    if n == 0 then
        text(x + 2, y + 2, "Пока нет результатов", config.colors.textDark, config.colors.panel)
        return
    end

    text(x + 8,  y + 1, "СТАВКА", config.colors.textDark, config.colors.panel)
    text(x + 17, y + 1, "ВЫПАЛО", config.colors.textDark, config.colors.panel)
    text(x + 27, y + 1, "СУММА", config.colors.textDark, config.colors.panel)

    for i = 1, rows do
        local e = History.entries[i]
        local ry = y + 2 + i
        local tag = e.win and "WIN" or "LOSS"
        local tagCol = e.win and config.colors.textGreen or config.colors.textRed
        local choiceCol = (e.choice == "ОРЁЛ") and config.colors.textGold or config.colors.textBlue
        local resultCol = (e.result == "ОРЁЛ") and config.colors.textGold or config.colors.textBlue
        local sign = e.win and "+" or "-"
        local amtCol = e.win and config.colors.textGreen or config.colors.textRed
        text(x + 2, ry, tag, tagCol, config.colors.panel)
        text(x + 8, ry, tostring(e.choice), choiceCol, config.colors.panel)
        text(x + 17, ry, ">" .. tostring(e.result), resultCol, config.colors.panel)
        text(x + 27, ry, sign .. tostring(e.amount or 0) .. " " .. config.currency.symbol, amtCol, config.colors.panel)
    end
end

--------------------------------------------------
-- ВВОД (Unicode / кириллица)
--------------------------------------------------
function UI.openInput(title, default, callback, maxLen)
    UI.input.active = true
    UI.input.title = title or "Ввод"
    UI.input.value = tostring(default or "")
    UI.input.callback = callback
    UI.input.maxLen = maxLen or 40
    UI.draw()
end

function UI.closeInput(submit)
    local val, cb = UI.input.value, UI.input.callback
    UI.input.active = false; UI.input.callback = nil
    if cb then if submit then cb(val) else cb(nil) end end
end

function UI.drawInputModal()
    local mw = UI.w - config.ui.sidebarWidth
    local boxW = math.min(52, mw - 4)
    local boxH = 10
    local bx = math.floor((mw - boxW) / 2) + 1
    local by = math.floor((UI.h - boxH) / 2)
    fill(1, 2, mw, UI.h - 1, 0x0F0F0F)
    drawBox(bx, by, boxW, boxH, config.colors.textBlue, config.colors.panel)
    centerText(by + 1, UI.input.title, config.colors.textBlue, config.colors.panel, mw)
    local fieldX, fieldW = bx + 2, boxW - 4
    fill(fieldX, by + 3, fieldW, 1, 0x1A1A1A)
    local display = UI.input.value
    if unicode.len(display) > fieldW - 2 then display = unicode.sub(display, -(fieldW - 2)) end
    text(fieldX + 1, by + 3, display .. "▌", config.colors.textGold, 0x1A1A1A)
    text(bx + 2, by + 5, "Enter — ОК  |  Esc — отмена", config.colors.textDark, config.colors.panel)
    UI.addButton(bx + 2, by + 7, 12, 2, "ОК", config.colors.buttonGreen, 0xFFFFFF, function() UI.closeInput(true) end)
    UI.addButton(bx + 16, by + 7, 12, 2, "ОТМЕНА", config.colors.button, config.colors.text, function() UI.closeInput(false) end)
end

function UI.handleKey(char, code)
    if not UI.input.active then return false end
    if code == keyboard.keys.enter then UI.closeInput(true); UI.draw(); return true end
    if code == keyboard.keys.escape then UI.closeInput(false); UI.draw(); return true end
    if code == keyboard.keys.back then
        if unicode.len(UI.input.value) > 0 then
            UI.input.value = unicode.sub(UI.input.value, 1, -2); UI.draw()
        end
        return true
    end
    if char and char > 0 and char ~= 127 then
        local ch
        if char < 128 then
            if char < 32 then return true end
            ch = string.char(char)
        else
            local ok, res = pcall(unicode.char, char)
            ch = ok and res or nil
        end
        if ch and unicode.len(UI.input.value) < UI.input.maxLen then
            UI.input.value = UI.input.value .. ch; UI.draw()
        end
    end
    return true
end

--------------------------------------------------
-- САЙДБАР
--------------------------------------------------
function UI.drawHeader()
    fill(1, 1, UI.w, 1, config.colors.header)
    centerText(1, "CASINO COINFLIP", config.colors.textBlue, config.colors.header)
end

function UI.drawSidebar()
    local sx = UI.w - config.ui.sidebarWidth + 1
    local sw = config.ui.sidebarWidth
    fill(sx, 2, sw, UI.h - 1, config.colors.panel)

    if not UI.authorized then
        UI.addButton(sx + 1, 3, sw - 2, 4, "АВТОРИЗАЦИЯ", config.colors.buttonGreen, 0xFFFFFF, function()
            UI.pendingAuth = true
            UI.setMessage("Коснитесь экрана своим ником", config.colors.textGold, 5)
            UI.draw()
        end)
        text(sx + 2, 9, "Нажмите кнопку", config.colors.textDark, config.colors.panel)
        text(sx + 2, 10, "для авторизации", config.colors.textDark, config.colors.panel)
    else
        UI.addButton(sx + 1, 3, sw - 2, 4, "ВЫХОД", config.colors.buttonRed, 0xFFFFFF, function() UI.logout() end)

        drawBox(sx + 1, 8, sw - 2, 5, config.colors.textDark, config.colors.panelLight)
        text(sx + 3, 9, UI.playerName or "?", config.colors.textGreen, config.colors.panelLight)
        local p = Players.get(UI.playerName)
        text(sx + 3, 10, string.format("%s %s", fmtMoney(p.balance or 0), config.currency.symbol), config.colors.textGold, config.colors.panelLight)
        text(sx + 3, 11, "Выход через: " .. UI.sessionLeft .. "с", config.colors.textDark, config.colors.panelLight)

        -- Пополнить + Вывод — на одном уровне, впритык, как одна кнопка из двух половин
        local halfW = math.floor((sw - 2) / 2)
        UI.addButton(sx + 1, 15, halfW, 4, "ПОПОЛНИТЬ", config.colors.buttonGreen, 0xFFFFFF, function() UI.doDeposit() end)
        UI.addButton(sx + 1 + halfW, 15, (sw - 2) - halfW, 4, "ВЫВОД", config.colors.buttonBlue, 0xFFFFFF, function() UI.doWithdraw() end)

        if config.admins[UI.playerName] then
            UI.addButton(sx + 1, 20, sw - 2, 4, "АДМИН ПАНЕЛЬ", config.colors.buttonBlue, 0xFFFFFF, function()
                UI.screen = "admin"; UI.adminTab = "bets"; UI.draw()
            end)
        end
    end

    local y = UI.authorized and (config.admins[UI.playerName] and 26 or 21) or 13
    if y > UI.h - 10 then y = UI.h - 10 end

    text(sx + 1, y, "СКУПКА ПРЕДМЕТОВ:", config.colors.textBlue, config.colors.panel); y = y + 1
    local sorted = {}
    for id, info in pairs(Settings.data.buyPrices or {}) do
        table.insert(sorted, { label = info.label or id, price = info.price or 0 })
    end
    table.sort(sorted, function(a, b) return a.label < b.label end)
    local count = 0
    for _, entry in ipairs(sorted) do
        count = count + 1
        if count > 6 or y >= UI.h - 8 then break end
        local short = entry.label
        if unicode.len(short) > 14 then short = unicode.sub(short, 1, 12) .. ".." end
        local priceStr = tostring(entry.price)
        local line = string.format("%s 1 шт - %s %s", short, priceStr, config.currency.symbol)
        if unicode.len(line) > sw - 2 then
            line = string.format("%s - %s %s", short, priceStr, config.currency.symbol)
        end
        text(sx + 1, y, line, config.colors.text, config.colors.panel)
        y = y + 1
    end
    if count == 0 then text(sx + 1, y, "Нет предметов", config.colors.textDark, config.colors.panel); y = y + 1 end

    y = y + 1
    text(sx + 1, y, "ТОП 15:", config.colors.textBlue, config.colors.panel); y = y + 1
    for i, entry in ipairs(Players.getTop(15)) do
        if y >= UI.h - 1 then break end
        local name = entry.name
        if unicode.len(name) > 11 then name = unicode.sub(name, 1, 9) .. ".." end
        local bal = entry.total
        local balStr = bal >= 1000 and string.format("%.1fk", bal / 1000) or tostring(bal)
        text(sx + 1, y, string.format("%d. %s", i, name), config.colors.text, config.colors.panel)
        text(sx + sw - unicode.len(balStr) - 3, y, balStr, config.colors.textGold, config.colors.panel)
        y = y + 1
    end

    -- подпись внизу правого столбца
    local credit = "by hellbreez"
    local cy = UI.h
    local cx = sx + math.floor((sw - unicode.len(credit)) / 2)
    if cx < sx + 1 then cx = sx + 1 end
    gpu.setBackground(config.colors.panel)
    gpu.setForeground(0x000000)
    gpu.set(cx, cy, credit)
end

--------------------------------------------------
function UI.drawRules(mw, startY)
    local y = startY or 22
    local winX = tonumber(Settings.data.winPayout) or 2.0
    local winStr = (winX == math.floor(winX)) and tostring(math.floor(winX)) or string.format("%.2f", winX):gsub("0+$", ""):gsub("%.$", "")
    centerText(y, "ПРАВИЛА", config.colors.textBlue, config.colors.background, mw); y = y + 1
    centerText(y, "Угадайте сторону монеты: Орёл или Решка", config.colors.text, config.colors.background, mw); y = y + 1
    centerText(y, "Угадали: x" .. winStr .. "   |   Не угадали: ставка сгорает", config.colors.textGold, config.colors.background, mw)
end

function UI.drawMainArea()
    local mw = UI.w - config.ui.sidebarWidth
    local cx = math.floor(mw / 2)
    local coinX = cx - math.floor(COIN_W / 2)
    local coinY = 2

    if UI.screen == "main" then
        drawCoin(coinX, coinY, COIN_W, UI.choice)

        local infoY = coinY + COIN_H + 1
        if UI.authorized then
            local bal = fmtMoney(Players.get(UI.playerName).balance)
            centerText(infoY, "Ваш баланс: " .. bal .. " " .. config.currency.symbol, config.colors.text, config.colors.background, mw)
        else
            centerText(infoY, "Авторизуйтесь через боковую панель, чтобы играть", config.colors.textGold, config.colors.background, mw)
        end

        centerText(infoY + 2, "ВЫБЕРИТЕ СТОРОНУ", config.colors.textBlue, config.colors.background, mw)
        local sideY = infoY + 2
        local orelBg  = (UI.choice == "ОРЁЛ") and config.colors.buttonBlue or config.colors.button
        local reshkaBg = (UI.choice == "РЕШКА") and config.colors.buttonBlue or config.colors.button
        UI.addButton(cx - 21, sideY, 20, 3, "ОРЁЛ", orelBg, 0xFFFFFF, function() UI.choice = "ОРЁЛ"; UI.draw() end)
        UI.addButton(cx + 1, sideY, 20, 3, "РЕШКА", reshkaBg, 0xFFFFFF, function() UI.choice = "РЕШКА"; UI.draw() end)

        local betLabelY = sideY + 3
        centerText(betLabelY, "СТАВКА (нажми чтобы ввести)", config.colors.textBlue, config.colors.background, mw)
        local betBoxY = betLabelY + 1
        drawBox(cx - 10, betBoxY, 20, 3, config.colors.textGold, config.colors.panelLight)
        text(cx - 8, betBoxY + 1, tostring(UI.betAmount) .. " " .. config.currency.symbol, config.colors.textGold, config.colors.panelLight)
        UI.addButton(cx - 10, betBoxY, 20, 3, "", 0x000000, 0x000000, function()
            UI.openInput("Ставка (целое число)", tostring(UI.betAmount), function(val)
                if not val then UI.draw(); return end
                local n = tonumber(val)
                if not n then UI.setMessage("Только число", config.colors.textRed, 3); UI.draw(); return end
                n = math.floor(n + 1e-9)
                if n < Settings.data.minBet or n > Settings.data.maxBet then
                    UI.setMessage("Лимит " .. Settings.data.minBet .. "–" .. Settings.data.maxBet, config.colors.textRed, 3)
                    UI.draw(); return
                end
                UI.betAmount = n
                UI.draw()
            end, 8)
        end)

        -- Быстрые кнопки ставки: МИН -100 -50 -10 +10 +50 +100 МАКС
        local steps = {
            { label = "МИН",  fn = function() return Settings.data.minBet end },
            { label = "-100", fn = function() return UI.betAmount - 100 end },
            { label = "-50",  fn = function() return UI.betAmount - 50 end },
            { label = "-10",  fn = function() return UI.betAmount - 10 end },
            { label = "+10",  fn = function() return UI.betAmount + 10 end },
            { label = "+50",  fn = function() return UI.betAmount + 50 end },
            { label = "+100", fn = function() return UI.betAmount + 100 end },
            { label = "МАКС", fn = function() return Settings.data.maxBet end },
        }
        local stepsY = betBoxY + 3
        local nSteps = #steps
        local gap = 1
        local stepW = 7
        local totalW = nSteps * stepW + (nSteps - 1) * gap
        if totalW > mw - 6 then
            stepW = math.max(4, math.floor((mw - 6 - (nSteps - 1) * gap) / nSteps))
            totalW = nSteps * stepW + (nSteps - 1) * gap
        end
        local stepX = cx - math.floor(totalW / 2)
        for i, s in ipairs(steps) do
            local bx = stepX + (i - 1) * (stepW + gap)
            UI.addButton(bx, stepsY, stepW, 2, s.label, config.colors.button, config.colors.text, function()
                local n = math.floor(s.fn())
                if n < Settings.data.minBet then n = Settings.data.minBet end
                if n > Settings.data.maxBet then n = Settings.data.maxBet end
                UI.betAmount = n
                UI.draw()
            end)
        end

        local limitY = stepsY + 2
        text(cx - 10, limitY, "Мин: " .. Settings.data.minBet .. "   Макс: " .. Settings.data.maxBet, config.colors.textDark, config.colors.background)

        local actionY = limitY + 2
        if UI.authorized then
            UI.addButton(cx - 10, actionY, 20, 3, "ИГРАТЬ", config.colors.buttonGreen, 0xFFFFFF, function() UI.startGame() end)
        else
            centerText(actionY + 1, "Нажмите АВТОРИЗАЦИЯ для входа", config.colors.textGold, config.colors.background, mw)
        end

        local historyY = actionY + 3
        local maxRows = math.max(3, math.min(12, UI.h - historyY - 2))
        UI.drawHistoryList(4, historyY, mw, maxRows)

    elseif UI.screen == "playing" or UI.screen == "result" then
        if UI.anim then
            drawCoin(coinX, coinY, UI.anim.w, UI.anim.side)
        elseif UI.screen == "result" then
            drawCoin(coinX, coinY, COIN_W, Game.result)
        end

        local infoY = coinY + COIN_H + 1
        centerText(infoY, "Ваш выбор: " .. tostring(Game.choice) .. "   Ставка: " .. Game.bet .. " " .. config.currency.symbol,
            config.colors.text, config.colors.background, mw)

        local statusY = infoY + 2
        local historyGap = 3

        if UI.screen == "playing" then
            centerText(statusY, "Подбрасываем монету...", config.colors.textGold, config.colors.background, mw)
        elseif UI.screen == "result" then
            local resText = Game.win and "ПОБЕДА!" or "ПРОИГРЫШ"
            local resCol = Game.win and config.colors.textGreen or config.colors.textRed
            centerText(statusY, "Выпало: " .. tostring(Game.result) .. "  —  " .. resText, resCol, config.colors.background, mw)
            local winAmount = math.floor(Game.bet * Game.payoutMultiplier() + 0.5)
            if winAmount > 0 then
                centerText(statusY + 1, "+" .. winAmount .. " " .. config.currency.symbol, config.colors.textGreen, config.colors.background, mw)
            end
            UI.addButton(cx - 8, statusY + 3, 16, 3, "ЕЩЁ РАЗ", config.colors.buttonGreen, 0xFFFFFF, function()
                UI.screen = "main"; Game.reset(); UI.draw()
            end)
            historyGap = 8
        end

        local historyY = statusY + historyGap
        local maxRows = math.max(3, math.min(12, UI.h - historyY - 2))
        UI.drawHistoryList(4, historyY, mw, maxRows)

    elseif UI.screen == "admin" then UI.drawAdmin(mw)
    elseif UI.screen == "admin_add_item" then UI.drawAdminAddItem(mw)
    elseif UI.screen == "admin_edit_item" then UI.drawAdminEditItem(mw)
    end

    if UI.message and computer.uptime() < UI.messageUntil then
        -- полоска по центру, не режет крайние элементы
        local barW = math.min(mw - 4, math.max(30, unicode.len(UI.message) + 4))
        local bx = math.floor((mw - barW) / 2) + 1
        fill(bx, UI.h - 1, barW, 1, 0x262626)
        centerText(UI.h - 1, UI.message, UI.messageColor, 0x262626, mw)
    end
end

--------------------------------------------------
-- АДМИН
--------------------------------------------------
function UI.drawAdmin(mw)
    centerText(3, "АДМИН-ПАНЕЛЬ", config.colors.textBlue, config.colors.background, mw)

    local tabs = {
        { id = "bets", title = "СТАВКИ" },
        { id = "buy", title = "СКУПКА" },
        { id = "payout", title = "ВЫПЛАТА" },
        { id = "logs", title = "ЛОГИ" },
        { id = "odds", title = "ВЕРОЯТН." },
    }
    local tx = 3
    for _, tab in ipairs(tabs) do
        local tw = unicode.len(tab.title) + 2
        UI.addButton(tx, 5, tw, 2, tab.title,
            UI.adminTab == tab.id and config.colors.buttonBlue or config.colors.button, 0xFFFFFF, function()
                UI.adminTab = tab.id; UI.logScroll = 0; UI.draw() end)
        tx = tx + tw + 1
    end

    if UI.adminTab == "bets" then UI.drawAdminBets(mw)
    elseif UI.adminTab == "buy" then UI.drawAdminBuy(mw)
    elseif UI.adminTab == "payout" then UI.drawAdminPayout(mw)
    elseif UI.adminTab == "logs" then UI.drawAdminLogs(mw)
    elseif UI.adminTab == "odds" then UI.drawAdminOdds(mw) end

    UI.addButton(4, UI.h - 3, 14, 2, "◄ НАЗАД", config.colors.button, config.colors.text, function()
        UI.screen = "main"; UI.adminTab = "bets"; UI.draw() end)
end

function UI.drawAdminBets(mw)
    text(4, 9, "Минимальная ставка (нажми на поле):", config.colors.textDark, config.colors.background)
    drawBox(4, 10, 22, 3, config.colors.textGold, config.colors.panelLight)
    text(6, 11, tostring(Settings.data.minBet) .. " " .. config.currency.symbol, config.colors.textGold, config.colors.panelLight)
    UI.addButton(4, 10, 22, 3, "", 0x000000, 0x000000, function()
        UI.openInput("Мин. ставка", tostring(Settings.data.minBet), function(val)
            local n = tonumber(val)
            if n and n >= 1 then
                Settings.data.minBet = math.floor(n)
                if Settings.data.minBet > Settings.data.maxBet then Settings.data.maxBet = Settings.data.minBet end
                Settings.save()
            end
            UI.draw()
        end, 8)
    end)

    text(4, 14, "Максимальная ставка (нажми на поле):", config.colors.textDark, config.colors.background)
    drawBox(4, 15, 22, 3, config.colors.textGold, config.colors.panelLight)
    text(6, 16, tostring(Settings.data.maxBet) .. " " .. config.currency.symbol, config.colors.textGold, config.colors.panelLight)
    UI.addButton(4, 15, 22, 3, "", 0x000000, 0x000000, function()
        UI.openInput("Макс. ставка", tostring(Settings.data.maxBet), function(val)
            local n = tonumber(val)
            if n and n >= Settings.data.minBet then
                Settings.data.maxBet = math.floor(n); Settings.save()
            end
            UI.draw()
        end, 8)
    end)
end

function UI.drawAdminBuy(mw)
    text(4, 8, "Предметы для скупки:", config.colors.textBlue, config.colors.background)
    local y, list = 10, {}
    for name, info in pairs(Settings.data.buyPrices or {}) do
        table.insert(list, { name = name, label = info.label or name, price = info.price or 0 })
    end
    table.sort(list, function(a, b) return a.label < b.label end)
    for _, entry in ipairs(list) do
        if y > UI.h - 8 then break end
        local short = entry.label
        if unicode.len(short) > 20 then short = unicode.sub(short, 1, 18) .. ".." end
        text(4, y, short, config.colors.text, config.colors.background)
        text(28, y, tostring(entry.price) .. " " .. config.currency.symbol, config.colors.textGold, config.colors.background)
        UI.addButton(42, y, 3, 1, "×", config.colors.buttonRed, 0xFFFFFF, function()
            Settings.data.buyPrices[entry.name] = nil; Settings.save(); UI.draw() end)
        y = y + 1
    end
    if #list == 0 then text(4, 10, "Список пуст", config.colors.textDark, config.colors.background) end
    UI.addButton(4, UI.h - 6, 22, 2, "+ ДОБАВИТЬ ПРЕДМЕТ", config.colors.buttonGreen, 0xFFFFFF, function()
        UI.screen = "admin_add_item"
        UI.editItem = { name = nil, label = "", price = "1", mode = "add", target = "buy" }
        UI.draw()
    end)
end

function UI.drawAdminPayout(mw)
    text(4, 8, "Предмет выигрыша / вывода:", config.colors.textBlue, config.colors.background)
    text(4, 9, "(выдаётся из ME в правый сундук)", config.colors.textDark, config.colors.background)
    local pi = Settings.data.payoutItem
    if pi and pi.name then
        text(4, 12, "Предмет: " .. (pi.label or pi.name), config.colors.text, config.colors.background)
        text(4, 13, "ID: " .. pi.name, config.colors.textDark, config.colors.background)
        text(4, 14, "1 шт = " .. tostring(pi.value or 1) .. " " .. config.currency.symbol, config.colors.textGold, config.colors.background)
        UI.addButton(4, 17, 18, 2, "ИЗМЕНИТЬ", config.colors.buttonBlue, 0xFFFFFF, function()
            UI.screen = "admin_add_item"
            UI.editItem = { name = pi.name, label = pi.label or pi.name, price = tostring(pi.value or 1), mode = "edit", target = "payout" }
            UI.draw()
        end)
        UI.addButton(24, 17, 14, 2, "УДАЛИТЬ", config.colors.buttonRed, 0xFFFFFF, function()
            Settings.data.payoutItem = nil; Settings.save(); UI.draw() end)
    else
        text(4, 12, "Не настроен", config.colors.textRed, config.colors.background)
        text(4, 13, "Без него выигрыш только на балансе", config.colors.textDark, config.colors.background)
        UI.addButton(4, 17, 24, 2, "+ НАСТРОИТЬ ПРЕДМЕТ", config.colors.buttonGreen, 0xFFFFFF, function()
            UI.screen = "admin_add_item"
            UI.editItem = { name = nil, label = "", price = "1", mode = "add", target = "payout" }
            UI.draw()
        end)
    end
end

function UI.drawAdminLogs(mw)
    text(4, 8, "Последние действия:", config.colors.textBlue, config.colors.background)
    local y = 10
    local start = 1 + (UI.logScroll or 0)
    local shown = 0
    for i = start, #Logs.entries do
        local e = Logs.entries[i]
        if e and LOG_KEEP[e.kind] then
            local ts
            if e.time and e.time > 100000 then
                ts = moscowDate("%Y-%m-%d %H:%M:%S", e.time)
            elseif e.raw then
                ts = e.raw:match("^%[(.-)%]") or ""
            else
                ts = ""
            end
            local kindCol = config.colors.text
            if e.kind == "ВЫИГРЫШ" then kindCol = config.colors.textGreen
            elseif e.kind == "ПРОИГРЫШ" then kindCol = config.colors.textRed
            elseif e.kind == "ПОПОЛНЕНИЕ" then kindCol = config.colors.textGold
            elseif e.kind == "ВЫВОД" then kindCol = config.colors.textBlue
            elseif e.kind == "ОШИБКА" then kindCol = config.colors.textRed end

            local line = string.format("[%s] %s | %s", ts, e.kind, e.player)
            if unicode.len(line) > mw - 6 then line = unicode.sub(line, 1, mw - 8) .. ".." end
            text(4, y, line, kindCol, config.colors.background)
            y = y + 1
            if e.text and e.text ~= "" then
                local t2 = "  " .. e.text
                if unicode.len(t2) > mw - 6 then t2 = unicode.sub(t2, 1, mw - 8) .. ".." end
                text(4, y, t2, config.colors.textDark, config.colors.background)
                y = y + 1
            end
            shown = shown + 1
            if y > UI.h - 5 then break end
        end
    end
    if shown == 0 then
        text(4, 10, "Логов пока нет", config.colors.textDark, config.colors.background)
    end
    -- стрелки справа от кнопки «НАЗАД»
    UI.addButton(20, UI.h - 3, 5, 2, "▲", config.colors.button, config.colors.text, function()
        UI.logScroll = math.max(0, (UI.logScroll or 0) - 2); UI.draw()
    end)
    UI.addButton(26, UI.h - 3, 5, 2, "▼", config.colors.button, config.colors.text, function()
        UI.logScroll = math.min(math.max(0, #Logs.entries - 1), (UI.logScroll or 0) + 2); UI.draw()
    end)
end


function UI.drawAdminOdds(mw)
    text(4, 7, "Выплата:", config.colors.textBlue, config.colors.background)

    text(4, 9, "Угадал x:", config.colors.textDark, config.colors.background)
    drawBox(4, 10, 12, 3, config.colors.textGold, config.colors.panelLight)
    text(6, 11, tostring(Settings.data.winPayout or 2.0), config.colors.textGold, config.colors.panelLight)
    UI.addButton(4, 10, 12, 3, "", 0x000000, 0x000000, function()
        UI.openInput("Угадал x", tostring(Settings.data.winPayout or 2.0), function(val)
            local n = tonumber(val)
            if n and n >= 1 and n <= 10 then Settings.data.winPayout = n; Settings.save() end
            UI.draw()
        end, 6)
    end)

    text(4, 14, "Перевес казино:", config.colors.textRed, config.colors.background)
    text(4, 16, "Перевес дома % (0-15):", config.colors.textDark, config.colors.background)
    drawBox(4, 17, 12, 3, config.colors.textGold, config.colors.panelLight)
    text(6, 18, tostring(Settings.data.houseEdge or 0), config.colors.textGold, config.colors.panelLight)
    UI.addButton(4, 17, 12, 3, "", 0x000000, 0x000000, function()
        UI.openInput("Перевес %", tostring(Settings.data.houseEdge or 0), function(val)
            local n = tonumber(val)
            if n then n = math.floor(n); if n >= 0 and n <= 15 then Settings.data.houseEdge = n; Settings.save() end end
            UI.draw()
        end, 2)
    end)
    text(4, 21, "(шанс, что выпадет сторона против игрока)", config.colors.textDark, config.colors.background)

    text(4, 24, "Сессия:", config.colors.textBlue, config.colors.background)
    text(4, 26, "Автовыход через, сек:", config.colors.textDark, config.colors.background)
    drawBox(4, 27, 12, 3, config.colors.textGold, config.colors.panelLight)
    text(6, 28, tostring(Settings.data.sessionSeconds or 40), config.colors.textGold, config.colors.panelLight)
    UI.addButton(4, 27, 12, 3, "", 0x000000, 0x000000, function()
        UI.openInput("Автовыход, сек", tostring(Settings.data.sessionSeconds or 40), function(val)
            local n = tonumber(val)
            if n then n = math.floor(n); if n >= 10 and n <= 600 then Settings.data.sessionSeconds = n; Settings.save() end end
            UI.draw()
        end, 4)
    end)
    text(4, 31, "(10-600 секунд бездействия)", config.colors.textDark, config.colors.background)
end

function UI.drawAdminAddItem(mw)
    local title = UI.editItem.target == "payout" and "ПРЕДМЕТ ВЫПЛАТЫ" or "ДОБАВЛЕНИЕ ПРЕДМЕТА"
    centerText(5, title, config.colors.textBlue, config.colors.background, mw)
    centerText(9, "Положи предмет в левый сундук", config.colors.text, config.colors.background, mw)
    centerText(10, "(транспозер сверху) и нажми ОК", config.colors.textDark, config.colors.background, mw)
    UI.addButton(math.floor(mw/2) - 8, 14, 16, 3, "ОК", config.colors.buttonGreen, 0xFFFFFF, function()
        local item = Hardware.getDepositItem()
        if not item then UI.setMessage("Сундук пуст!", config.colors.textRed, 4); UI.draw(); return end
        UI.editItem.name = item.name
        UI.editItem.label = tostring(item.label or item.name or "")  -- русское имя из игры
        UI.editItem.price = UI.editItem.price or "1"
        UI.screen = "admin_edit_item"; UI.draw()
    end)
    UI.addButton(math.floor(mw/2) - 8, 18, 16, 3, "ОТМЕНА", config.colors.button, config.colors.text, function()
        UI.screen = "admin"
        UI.adminTab = UI.editItem.target == "payout" and "payout" or "buy"
        UI.draw()
    end)
end

function UI.drawAdminEditItem(mw)
    centerText(4, "НАСТРОЙКА ПРЕДМЕТА", config.colors.textBlue, config.colors.background, mw)
    text(4, 7, "ID: " .. (UI.editItem.name or "?"), config.colors.textDark, config.colors.background)

    text(4, 10, "Отображаемое имя (можно на русском):", config.colors.textDark, config.colors.background)
    drawBox(4, 11, 44, 3, config.colors.textGold, config.colors.panelLight)
    local lbl = UI.editItem.label
    if not lbl or lbl == "" then lbl = "(нажми чтобы ввести)" end
    text(6, 12, lbl, config.colors.textGold, config.colors.panelLight)
    UI.addButton(4, 11, 44, 3, "", 0x000000, 0x000000, function()
        UI.openInput("Имя предмета", UI.editItem.label, function(val)
            if val and val ~= "" then UI.editItem.label = val end; UI.draw()
        end, 40)
    end)

    local priceLabel = UI.editItem.target == "payout"
        and ("Ценность 1 шт в " .. config.currency.symbol .. ":")
        or ("Цена скупки в " .. config.currency.symbol .. ":")
    text(4, 15, priceLabel, config.colors.textDark, config.colors.background)
    drawBox(4, 16, 20, 3, config.colors.textGold, config.colors.panelLight)
    local pr = UI.editItem.price
    if not pr or pr == "" then pr = "1" end
    text(6, 17, pr, config.colors.textGold, config.colors.panelLight)
    UI.addButton(4, 16, 20, 3, "", 0x000000, 0x000000, function()
        UI.openInput("Цена", UI.editItem.price, function(val)
            if val and tonumber(val) and tonumber(val) >= 0 then UI.editItem.price = val end; UI.draw()
        end, 12)
    end)

    UI.addButton(4, 21, 16, 3, "СОХРАНИТЬ", config.colors.buttonGreen, 0xFFFFFF, function()
        local price = tonumber(UI.editItem.price)
        if not price or price < 0 then UI.setMessage("Некорректная цена", config.colors.textRed, 3); UI.draw(); return end
        if not UI.editItem.name then UI.setMessage("Нет предмета", config.colors.textRed, 3); UI.draw(); return end
        if UI.editItem.target == "payout" then
            Settings.data.payoutItem = { name = UI.editItem.name, label = UI.editItem.label, value = price }
            Settings.save()
            UI.setMessage("Предмет выплаты сохранён", config.colors.textGreen, 3)
            UI.screen = "admin"; UI.adminTab = "payout"
        else
            Settings.data.buyPrices = Settings.data.buyPrices or {}
            Settings.data.buyPrices[UI.editItem.name] = { price = price, label = UI.editItem.label }
            Settings.save()
            UI.setMessage("Добавлено: " .. UI.editItem.label, config.colors.textGreen, 3)
            UI.screen = "admin"; UI.adminTab = "buy"
        end
        UI.draw()
    end)
    UI.addButton(22, 21, 14, 3, "ОТМЕНА", config.colors.button, config.colors.text, function()
        UI.screen = "admin"
        UI.adminTab = UI.editItem.target == "payout" and "payout" or "buy"
        UI.draw()
    end)
end

function UI.draw()
    drawScreen()
end

--------------------------------------------------
-- ДЕЙСТВИЯ
--------------------------------------------------
function UI.login(name)
    if not name or name == "" then return end
    UI.pendingAuth = false
    UI.playerName = name
    UI.authorized = true
    UI.sessionLeft = tonumber(Settings.data.sessionSeconds) or 40
    UI.screen = "main"
    _welcomeReady = false
    if gpu.setActiveBuffer then pcall(gpu.setActiveBuffer, 0) end

    local minB = tonumber(Settings.data.minBet) or config.bet.min or 1
    local maxB = tonumber(Settings.data.maxBet) or config.bet.max or 1000
    -- по умолчанию ставка = текущий минимум (следует за настройками админки)
    UI.betAmount = math.max(minB, math.min(maxB, minB))

    pcall(Players.get, name)
    UI.setMessage("Добро пожаловать, " .. tostring(name), config.colors.textGreen, 3)
    pcall(UI.startSessionTimer)

    local ok, err = pcall(UI.draw)
    if not ok then
                pcall(log, "ОШИБКА", name, "login draw: " .. tostring(err))
    end
    pcall(log, "ВХОД", name, "Авторизация")
end

function UI.logout()
    UI.stopAnim()
    UI.stopSessionTimer()
    -- кэш welcome валиден — карты снова без мигания
    if UI.playerName then log("ВЫХОД", UI.playerName, "Выход") end
    UI.authorized = false; UI.playerName = nil; UI.screen = "main"
    Game.reset(); UI.draw()
end

function UI.updateSessionLabel()
    if not UI.authorized or not UI.playerName then return end
    if UI.input.active or UI.alert then return end
    local sx = UI.w - config.ui.sidebarWidth + 1
    local sw = config.ui.sidebarWidth
    -- только строка таймера, без полной перерисовки (убирает мигание)
    gpu.setBackground(config.colors.panelLight)
    gpu.fill(sx + 2, 11, sw - 4, 1, " ")
    gpu.setForeground(config.colors.textDark)
    gpu.set(sx + 3, 11, "Выход через: " .. tostring(UI.sessionLeft) .. "с")
end

function UI.startSessionTimer()
    UI.stopSessionTimer()
    UI.timerId = event.timer(1, function()
        if not UI.authorized then return end
        UI.sessionLeft = UI.sessionLeft - 1
        if UI.sessionLeft <= 0 then UI.logout(); return end
        UI.updateSessionLabel()
    end, math.huge)
end

function UI.stopSessionTimer()
    if UI.timerId then event.cancel(UI.timerId); UI.timerId = nil end
end

function UI.doDeposit()
    if not UI.authorized then return end
    local groups = Hardware.getDepositItems()
    if #groups == 0 then
        UI.setMessage("Положите предметы в левый сундук", config.colors.textRed, 4)
        UI.draw(); return
    end

    local totalCredit = 0
    local details = {}
    for _, g in ipairs(groups) do
        local price = Settings.getPrice(g.name)
        if price then
            local taken = Hardware.consumeDeposit(g.name, g.size)
            if taken > 0 then
                local sum = price * taken
                totalCredit = totalCredit + sum
                table.insert(details, string.format("%s(x%d)", Settings.getLabel(g.name), taken))
            end
        end
    end

    if totalCredit <= 0 then
        UI.setMessage("Нет скупаемых предметов в сундуке", config.colors.textRed, 4)
        UI.draw(); return
    end

    Players.addBalance(UI.playerName, totalCredit)
    UI.setMessage("+" .. fmtMoney(totalCredit) .. " " .. config.currency.symbol, config.colors.textGreen, 4)
    log("ПОПОЛНЕНИЕ", UI.playerName, string.format("Сдано: %s Зачислено: %s %s",
        table.concat(details, ", "), fmtMoney(totalCredit), config.currency.symbol))
    UI.draw()
end

function UI.doWithdraw()
    if not UI.authorized then return end
    local pi = Settings.data.payoutItem
    if not (pi and pi.name) then
        UI.showAlert("Настройте предмет выплаты в админке")
        return
    end
    UI.withdraw.active = true
    UI.draw()
end

-- Собственно списание + выдача через ME (используется и пресетами, и «ВСЁ»)
function UI.performWithdraw(amount)
    UI.withdraw.active = false
    local pi = Settings.data.payoutItem
    if not (pi and pi.name) then
        UI.showAlert("Настройте предмет выплаты в админке")
        return
    end
    local p = Players.get(UI.playerName)
    local avail = roundMoney(p.balance or 0)
    local n = math.floor(math.min(amount, avail) + 1e-9)
    if n <= 0 then
        UI.setMessage("Недостаточно средств на балансе", config.colors.textRed, 3)
        UI.draw(); return
    end
    local value = tonumber(pi.value) or 1
    if value <= 0 then value = 1 end
    local count = math.floor(n / value + 1e-9)
    if count <= 0 then
        UI.setMessage("Мин. сумма вывода: " .. value .. " " .. config.currency.symbol, config.colors.textRed, 4)
        UI.draw(); return
    end

    local moved, err = Hardware.exportPayout(pi.name, count)
    if moved and moved > 0 then
        local deduct = roundMoney(moved * value)
        Players.addBalance(UI.playerName, -deduct)
        log("ВЫВОД", UI.playerName, string.format(
            "Выдал %s(x%d) в сундук | списано %s %s",
            pi.label or pi.name, moved, fmtMoney(deduct), config.currency.symbol
        ))
        if moved < count then
            UI.setMessage("Выведено " .. moved .. "/" .. count .. " (сундук полон?)", config.colors.textGold, 5)
        else
            UI.setMessage("Выведено: " .. moved .. "x " .. (pi.label or pi.name), config.colors.textGreen, 4)
        end
    else
        UI.setMessage("Не удалось вывести (" .. (err or "?") .. ")", config.colors.textRed, 5)
    end
    UI.draw()
end

function UI.drawWithdrawModal()
    local mw = UI.w - config.ui.sidebarWidth
    fill(1, 2, mw, UI.h - 1, 0x0F0F0F)

    local boxW, boxH = 46, 15
    local bx = math.floor((mw - boxW) / 2) + 1
    local by = math.floor((UI.h - boxH) / 2)
    drawBox(bx, by, boxW, boxH, config.colors.textGold, config.colors.panel)

    local p = Players.get(UI.playerName)
    local avail = roundMoney(p and p.balance or 0)

    local title = "ОБНАЛИЧИТЬ"
    text(bx + math.floor((boxW - unicode.len(title)) / 2), by + 1, title, config.colors.textGold, config.colors.panel)
    local sub = "Доступно: " .. fmtMoney(avail) .. " " .. config.currency.symbol
    text(bx + math.floor((boxW - unicode.len(sub)) / 2), by + 2, sub, config.colors.textDark, config.colors.panel)

    local presets = { 100, 500, 1000, 2000 }
    local innerW = boxW - 4
    local gap = 1
    local btnW = math.floor((innerW - (#presets - 1) * gap) / #presets)
    local rowX = bx + 2
    for i, amount in ipairs(presets) do
        local px = rowX + (i - 1) * (btnW + gap)
        UI.addButton(px, by + 4, btnW, 3, amount .. " " .. config.currency.symbol,
            config.colors.button, config.colors.text, function() UI.performWithdraw(amount) end)
    end

    local halfW = math.floor((innerW - 1) / 2)
    UI.addButton(bx + 2, by + 9, halfW, 3, "ВСЁ (" .. fmtMoney(avail) .. " " .. config.currency.symbol .. ")",
        config.colors.buttonYellow, 0x1A1400, function() UI.performWithdraw(avail) end)
    UI.addButton(bx + 3 + halfW, by + 9, innerW - halfW - 1, 3, "ОТМЕНА",
        config.colors.buttonRed, 0xFFFFFF, function() UI.withdraw.active = false; UI.draw() end)
end

function UI.showAlert(title, callback)
    UI.alert = { title = title or "Сообщение", cb = callback }
    UI.draw()
end

function UI.drawAlert()
    if not UI.alert then return end
    local mw = UI.w - config.ui.sidebarWidth
    -- затемнение игровой зоны
    fill(1, 2, mw, UI.h - 1, 0x0F0F0F)
    local boxW, boxH = 40, 11
    local bx = math.floor((mw - boxW) / 2) + 1
    local by = math.floor((UI.h - boxH) / 2)
    drawBox(bx, by, boxW, boxH, config.colors.textRed, config.colors.panel)
    -- заголовок
    local title = UI.alert.title or "Сообщение"
    local tx = bx + math.floor((boxW - unicode.len(title)) / 2)
    text(tx, by + 3, title, config.colors.textRed, config.colors.panel)
    -- кнопка ОК по центру окна
    local bw = 14
    local bxbtn = bx + math.floor((boxW - bw) / 2)
    UI.addButton(bxbtn, by + 6, bw, 3, "ОК", config.colors.buttonGreen, 0xFFFFFF, function()
        local cb = UI.alert and UI.alert.cb
        UI.alert = nil
        if cb then cb() end
        UI.draw()
    end)
end

function UI.stopAnim()
    if UI.animTimer then
        pcall(event.cancel, UI.animTimer)
        UI.animTimer = nil
    end
end

function UI.schedule(delay, fn)
    UI.stopAnim()
    UI.animTimer = event.timer(delay, function()
        UI.animTimer = nil
        fn()
    end, 1)
end

-- Кадры анимации вращения монеты: последовательность видимых ширин (эмуляция
-- вращения вокруг вертикальной оси), с показом текущей "видимой" стороны
-- в моменты, когда монета развёрнута почти анфас.
-- Кадры анимации вращения: доли от полной ширины монеты (не ниже ~24%,
-- чтобы не превращалось в «флагшток», и обязательно доходит до 100% —
-- иначе монета всегда выглядит сплюснутой).
local FLIP_FRACTIONS = { 1.0, 0.78, 0.55, 0.35, 0.24, 0.35, 0.55, 0.78 }

function UI.startFlipAnim()
    -- Итог раунда уже известен заранее (Game.decide вызван в UI.startGame),
    -- анимация — чисто визуальная, «докручивает» монету до готового результата.
    local frames = {}
    local otherSide = (Game.choice == "ОРЁЛ") and "РЕШКА" or "ОРЁЛ"
    local spins = 2
    for spin = 1, spins do
        local faceSide = (spin % 2 == 1) and Game.choice or otherSide
        for _, f in ipairs(FLIP_FRACTIONS) do
            local w = math.max(3, math.floor(COIN_W * f + 0.5))
            table.insert(frames, { w = w, side = (f >= 0.6) and faceSide or nil })
        end
    end
    table.insert(frames, { w = COIN_W, side = Game.result })

    local coinX, coinY = UI.coinPos()

    local i = 0
    local function step()
        i = i + 1
        if i > #frames then
            Game.finish()
            UI.anim = nil
            UI.schedule(0.6, function() UI.resolveGame(); UI.draw() end)
            return
        end
        UI.anim = frames[i]
        -- Лёгкий кадр: обновляем только саму монету (не весь экран) —
        -- иначе частая полная перерисовка сайдбара/истории/кнопок
        -- на каждый тик анимации создаёт заметное мигание и просадки.
        pcall(gpu.setActiveBuffer, 0)
        eraseCoin(coinX, coinY)
        drawCoin(coinX, coinY, UI.anim.w, UI.anim.side)
        UI.schedule(0.06, step)
    end
    step()
end

function UI.startGame()
    if not UI.authorized then return end
    if Game.state == "flipping" then return end
    local p = Players.get(UI.playerName)
    if roundMoney(p.balance or 0) < UI.betAmount then
        UI.showAlert("Недостаточно средств")
        return
    end
    if UI.betAmount < Settings.data.minBet or UI.betAmount > Settings.data.maxBet then
        UI.showAlert("Ставка вне лимитов " .. Settings.data.minBet .. "–" .. Settings.data.maxBet)
        return
    end
    Players.addBalance(UI.playerName, -UI.betAmount)
    Players.addPlayed(UI.playerName, UI.betAmount)
    Game.reset()
    Game.bet = UI.betAmount
    Game.decide(UI.choice)
    Game.state = "flipping"
    UI.screen = "playing"
    UI.anim = nil
    _welcomeReady = false
    UI.draw()
    UI.startFlipAnim()
end

function UI.resolveGame()
    local winAmount = Game.win and math.floor(Game.bet * Game.payoutMultiplier() + 0.5) or 0
    History.add(Game.choice, Game.result, Game.win, Game.win and winAmount or Game.bet)

    if Game.win then
        local win = winAmount
        if win > 0 then
            -- Выигрыш: только в правый сундук из ME (не на баланс)
            local pi = Settings.data.payoutItem
            if pi and pi.name then
                local value = tonumber(pi.value) or 1
                if value <= 0 then value = 1 end
                local count = math.max(1, math.floor(win / value + 1e-9))

                local moved, err = Hardware.exportPayout(pi.name, count)
                if moved and moved > 0 then
                    log("ВЫИГРЫШ", UI.playerName, string.format(
                        "Выдал %s(x%d) в сундук | ставка %d | выигрыш %d %s",
                        pi.label or pi.name, moved, Game.bet, win, config.currency.symbol
                    ))
                    if moved < count then
                        UI.setMessage("Выдано " .. moved .. "/" .. count .. " из ME", config.colors.textGold, 5)
                    end
                else
                    -- Если ME пуст/ошибка — не оставляем игрока без выигрыша
                    Players.addBalance(UI.playerName, win)
                    log("ОШИБКА", UI.playerName, "Выигрыш в сундук: " .. (err or "ME") .. " | +" .. win .. " на баланс")
                    UI.setMessage("ME не выдал (" .. (err or "?") .. ") → на баланс", config.colors.textRed, 6)
                end
            else
                Players.addBalance(UI.playerName, win)
                log("ВЫИГРЫШ", UI.playerName, string.format("+%d %s на баланс (нет предмета выплаты)", win, config.currency.symbol))
                UI.setMessage("Настройте предмет выплаты в админке", config.colors.textGold, 5)
            end
        end
    else
        log("ПРОИГРЫШ", UI.playerName, string.format("Ставка %d %s | выпало %s", Game.bet, config.currency.symbol, tostring(Game.result)))
    end

    local p = Players.get(UI.playerName)
    p.games = (p.games or 0) + 1
    if Game.win then p.wins = (p.wins or 0) + 1 end
    Players.save()
    UI.screen = "result"
end

--------------------------------------------------
local function boot()
        pcall(function()
        if gpu.maxDepth then gpu.setDepth(gpu.maxDepth()) end
    end)

    local maxW, maxH = 80, 25
    pcall(function()
        maxW, maxH = gpu.maxResolution()
    end)
    local targetW = math.min(160, maxW or 80)
    local targetH = math.min(50, maxH or 25)
    if targetW < 60 then targetW = maxW or 80 end
    if targetH < 20 then targetH = maxH or 25 end
    pcall(gpu.setResolution, targetW, targetH)

    UI.w, UI.h = 80, 25
    pcall(function()
        UI.w, UI.h = gpu.getResolution()
    end)
    if not UI.w or UI.w < 1 then UI.w = 80 end
    if not UI.h or UI.h < 1 then UI.h = 25 end

    _tableReady = false
    _tableBuf = nil
    _tableMw = 0
    _tableVer = 0
    _screenBuf = nil
    _welcomeReady = false
    _inFrame = false

    pcall(gpu.setBackground, FELT_BASE or 0x1B1B1B)
    pcall(gpu.fill, 1, 1, UI.w, UI.h, " ")
    -- сразу снимок стола (сукно + окантовка)
    pcall(function()
        local mw = UI.w - (config.ui.sidebarWidth or 28)
        ensureTableCache(mw)
    end)

        ensureDir(config.paths.data)
    Players.load()
    Settings.load()
    History.load()
    Hardware.init()
    pcall(loadLogsFromFile)

    local seed = computer.uptime() * 1000
    pcall(function()
        local a = computer.address()
        if a and a.byte then seed = seed + (a:byte(1) or 0) end
    end)
    math.randomseed(math.floor(seed))

    pcall(log, "СИСТЕМА", "-", "CoinFlip start " .. UI.w .. "x" .. UI.h)

        local okDraw, drawErr = pcall(UI.draw)
    if not okDraw then
        error("UI.draw: " .. tostring(drawErr))
    end
    
    while true do
        local okEv, ev1, ev2, ev3, ev4, ev5, ev6 = pcall(event.pull, 0.5)
        if not okEv then
            -- игнорируем сбои event
        else
            local e = ev1
            if e == "key_down" then
                pcall(UI.handleKey, ev3, ev4)
            elseif e == "touch" then
                local x, y, player = ev3, ev4, ev6
                local okTouch, tErr = pcall(function()
                    if UI.alert then
                        UI.checkButtons(x, y)
                    elseif UI.input.active then
                        UI.checkButtons(x, y)
                    elseif UI.withdraw.active then
                        UI.checkButtons(x, y)
                    elseif not UI.authorized then
                        UI.checkButtons(x, y)
                        if UI.pendingAuth and player and player ~= "" then
                            UI.pendingAuth = false
                            UI.login(player)
                        end
                    else
                        UI.sessionLeft = tonumber(Settings.data.sessionSeconds) or 40
                        UI.checkButtons(x, y)
                    end
                end)
                if not okTouch then
                    pcall(log, "ОШИБКА", "-", "touch: " .. tostring(tErr))
                end
            elseif e == "interrupted" then
                -- Ctrl+C отключён: игроки не могут выключить программу
            end
        end
    end
end

local ok, err = pcall(boot)
if not ok then
    pcall(function()
        if term and term.clear then term.clear() end
    end)
    print("========================================")
    print("Ошибка CoinFlip:")
    print(tostring(err))
    print("========================================")
    pcall(log, "ОШИБКА", "-", tostring(err))
end
