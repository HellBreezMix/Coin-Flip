--------------------------------------------------
-- CoinFlip Casino — установщик
-- install.lua
--------------------------------------------------
-- Использование (на компьютере с интернет-картой):
--   wget -f https://raw.githubusercontent.com/HellBreezMix/BlackJack/main/install.lua
--   lua install.lua
--
-- Скрипт создаст папку /BlackJack и скачает в неё main.lua и config.lua.
-- Если config.lua уже существует — он НЕ перезаписывается (чтобы не затереть
-- твои настройки админки), качается только main.lua.
--------------------------------------------------

local component = require("component")
local filesystem = require("filesystem")
local shell = require("shell")

if not component.isAvailable("internet") then
    io.stderr:write("ОШИБКА: не найдена интернет-карта. Подключи Internet Card к компьютеру.\n")
    return
end

local internet = component.internet

-- Базовый URL репозитория (raw-файлы). Поменяй ветку/репозиторий здесь,
-- если форкнул проект к себе.
local REPO_RAW = "https://raw.githubusercontent.com/HellBreezMix/BlackJack/main/"

local INSTALL_DIR = "/BlackJack/"

local FILES = {
    { name = "main.lua",   dest = INSTALL_DIR .. "main.lua",   overwrite = true  },
    { name = "config.lua", dest = INSTALL_DIR .. "config.lua", overwrite = false },
}

local function ensureDir(path)
    local dir = filesystem.path(path)
    if dir and dir ~= "" and not filesystem.exists(dir) then
        filesystem.makeDirectory(dir)
    end
end

local function download(url)
    local handle, reason = internet.request(url)
    if not handle then
        return nil, "не удалось открыть соединение: " .. tostring(reason)
    end

    -- ждём заголовки/готовность соединения
    local ok, why
    while true do
        ok, why = handle.finishConnect()
        if ok then break end
        if ok == nil then
            handle.close()
            return nil, "ошибка соединения: " .. tostring(why)
        end
        os.sleep(0.05)
    end

    local chunks = {}
    while true do
        local chunk, err = handle.read(math.huge)
        if not chunk then
            if err then
                handle.close()
                return nil, "ошибка чтения: " .. tostring(err)
            end
            break
        end
        table.insert(chunks, chunk)
    end
    handle.close()

    local data = table.concat(chunks)
    if not data or data == "" then
        return nil, "пустой ответ сервера"
    end
    return data
end

local function saveFile(path, data)
    ensureDir(path)
    local f, err = io.open(path, "w")
    if not f then
        return false, "не удалось открыть файл на запись: " .. tostring(err)
    end
    f:write(data)
    f:close()
    return true
end

print("========================================")
print(" CoinFlip Casino — установка")
print("========================================")

ensureDir(INSTALL_DIR .. "x") -- гарантированно создаст /BlackJack/

local hadError = false

for _, file in ipairs(FILES) do
    if not file.overwrite and filesystem.exists(file.dest) then
        print("• " .. file.name .. " уже есть, пропускаю (чтобы не затереть настройки)")
    else
        io.write("• Скачиваю " .. file.name .. " ... ")
        local data, err = download(REPO_RAW .. file.name)
        if not data then
            print("ОШИБКА")
            io.stderr:write("  " .. tostring(err) .. "\n")
            hadError = true
        else
            local okSave, saveErr = saveFile(file.dest, data)
            if okSave then
                print("готово (" .. #data .. " байт)")
            else
                print("ОШИБКА ЗАПИСИ")
                io.stderr:write("  " .. tostring(saveErr) .. "\n")
                hadError = true
            end
        end
    end
end

print("----------------------------------------")
if hadError then
    print("Установка завершена С ОШИБКАМИ. Проверь сообщения выше.")
else
    print("Установка завершена успешно!")
    print("Запуск:  lua /BlackJack/main.lua")
    print("Не забудь настроить config.lua (админы, стороны транспозера/ME).")
end
