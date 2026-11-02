script_name("semipay")
script_author("downil")
script_version("1")

local var_0_0 = require("encoding")
local sampev = require("samp.events")

var_0_0.default = "CP1251"

local var_0_1 = var_0_0.UTF8

local isRunning = false
local SCRIPT_VERSION = "1"
local GITHUB_BASE = "https://raw.githubusercontent.com/downull/semipay/main/"
local latestVersion = nil
local updateAvailable = false
local updateCheckBusy = false
local updateDownloadBusy = false
local MENU_DIALOG_ID = 19001

local function nowMs()
    -- MoonLoader's game timer advances in real elapsed milliseconds, unlike os.clock().
    if type(getGameTimer) == "function" then
        return getGameTimer()
    end
    -- Fallback for environments where getGameTimer is unavailable.
    return math.floor(os.clock() * 1000)
end

-- Accept integer currency amounts only. Separators are treated as thousands
-- separators only when every group is valid; ambiguous decimals are rejected.
local function normalizeIntegerAmount(raw)
    if not raw then return nil end
    raw = tostring(raw):gsub("%s", "")
    if raw:match("^%d+$") then return raw end
    -- Some server dialogs render zero as "0." rather than "0".
    -- Accept this exact trailing-decimal form, but do not strip arbitrary
    -- punctuation from nonzero values (which could change the amount).
    if raw:match("^0%.$") then return "0" end
    if raw:find("[.,]") then
        local separator = raw:match("[.,]")
        if raw:find(separator == "." and "," or ".", 1, true) then return nil end
        local groups = {}
        for group in raw:gmatch("[^%.,]+") do groups[#groups + 1] = group end
        if #groups < 2 or not groups[1]:match("^%d%d?%d?$") or #groups[1] < 1 then return nil end
        for i = 2, #groups do
            if not groups[i]:match("^%d%d%d$") then return nil end
        end
        return table.concat(groups)
    end
    return nil
end

local debugLogPath = getWorkingDirectory() .. "\\semipay_debug.log"
local debugLogReady = false

local function debugLog(text)
    if not debugLogReady then return end
    local file = io.open(debugLogPath, "a")
    if not file then return end
    local stamp = os.date("%H:%M:%S")
    file:write("[", stamp, "] [semipay][DEBUG] ", tostring(text), "\n")
    file:close()
end

local function resetDebugLog()
    local file = io.open(debugLogPath, "w")
    if file then
        file:write("[", os.date("%H:%M:%S"), "] [semipay][DEBUG] Log reset; next /w run will be recorded here.\n")
        file:close()
        debugLogReady = true
        return true
    end
    debugLogReady = false
    return false
end

function main()
	while not isSampAvailable() do
		wait(100)
	end

    -- Show one reminder after SA-MP becomes available.
    wait(5000)
    msg("{FFD966}Не забудь оплатить налоги командой /w.")

	sampRegisterChatCommand("w", function()
        if isRunning then
            msg("{FFAA60}Оплата уже выполняется. Повторный запуск заблокирован.")
            return
        end
        isRunning = true
        resetDebugLog()
        debugLog("START /w v" .. SCRIPT_VERSION .. "; active=" .. tostring(sampIsDialogActive()) .. "; id=" .. tostring(sampIsDialogActive() and sampGetCurrentDialogId() or -1))
        lua_thread.create(function()
            local ok, err = pcall(doPayTaxes)
            isRunning = false
            if not ok then
                debugLog("ERROR: " .. tostring(err))
                msg("{FF6060}Скрипт остановлен из-за ошибки.")
            end
            debugLog("END /w; active=" .. tostring(sampIsDialogActive()) .. "; id=" .. tostring(sampIsDialogActive() and sampGetCurrentDialogId() or -1))
        end)
    end)

    sampRegisterChatCommand("semipay", function()
        showSemiPayMenu()
    end)

    -- Check GitHub shortly after the game becomes available.
    lua_thread.create(function()
        wait(2500)
        checkForUpdates(true)
    end)

	wait(-1)
end

local function toSampEncoding(value)
    value = tostring(value or "")
    -- sampShowDialog expects the game's legacy CP1251 text, while this Lua
    -- source is UTF-8. Convert menu strings before passing them to SA-MP.
    local ok, converted = pcall(function() return var_0_1:decode(value) end)
    if ok and converted then return converted end
    return value
end

function showSemiPayMenu()
    if not isSampAvailable() then return end
    local updateLabel = updateAvailable and "Обновить (доступна новая версия)" or "Обновить (сначала проверить)"
    -- Version is deliberately shown as the first visible row. It is informational
    -- only; the response handler ignores listItem 0. Action indexes are 1, 2, 3.
    local text = "Версия: " .. SCRIPT_VERSION .. "\n"
        .. "Оплатить налоги (/w)\n"
        .. "Проверить обновления\n"
        .. updateLabel
    sampShowDialog(
        MENU_DIALOG_ID,
        toSampEncoding("semipay — главное меню"),
        toSampEncoding(text),
        toSampEncoding("Выбрать"),
        toSampEncoding("Закрыть"),
        2
    )
end

function sampev.onSendDialogResponse(dialogId, button, listItem, inputText)
    if dialogId ~= MENU_DIALOG_ID then return end
    if button ~= 1 then return false end

    -- Row 0 is the displayed version and must never trigger an action.
    if listItem == 0 then
        showSemiPayMenu()
    elseif listItem == 1 then
        lua_thread.create(function()
            if not isRunning then
                isRunning = true
                resetDebugLog()
                debugLog("START /w from semipay menu v" .. SCRIPT_VERSION)
                local ok, err = pcall(doPayTaxes)
                isRunning = false
                if not ok then
                    debugLog("ERROR: " .. tostring(err))
                    msg("{FF6060}Скрипт остановлен из-за ошибки.")
                end
                debugLog("END /w from menu")
            else
                msg("{FFAA60}Оплата уже выполняется.")
            end
        end)
    elseif listItem == 2 then
        -- Check only: this branch never calls installUpdate().
        lua_thread.create(function() checkForUpdates(false) end)
    elseif listItem == 3 then
        -- Install only after an explicit click on the fourth visible row.
        if updateAvailable then
            lua_thread.create(function() installUpdate() end)
        else
            msg("{FFAA60}Сначала проверь обновления. Установка без подтверждения запрещена.")
        end
    end
    return false
end

local function readVersionFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local value = f:read("*a")
    f:close()
    if not value then return nil end
    return value:match("([%d%.]+)")
end

local function versionIsNewer(remote, localVersion)
    local function parts(v)
        local t = {}
        for n in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(n) or 0 end
        return t
    end
    local a, b = parts(remote), parts(localVersion)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end


-- MoonLoader downloadUrlToFile callback reports progress/status events, not HTTP codes.
-- STATUS_ENDDOWNLOADDATA (6) means file data finished; STATUSEX_ENDDOWNLOAD (58)
-- closes the operation. Status 57 is only STARTBINDING and must not be treated as failure.
local moonloaderDownloadStatus = require("moonloader").download_status
local function downloadWithFallback(fileName, destination, callback)
    local finished = false
    local dataFinished = false
    local function finish(ok, detail)
        if finished then return end
        finished = true
        callback(ok, detail)
    end

    local url = GITHUB_BASE .. fileName
    local ok, err = pcall(function()
        downloadUrlToFile(url, destination, function(_, status)
            if status == moonloaderDownloadStatus.STATUS_ENDDOWNLOADDATA then
                dataFinished = true
            elseif status == moonloaderDownloadStatus.STATUSEX_ENDDOWNLOAD then
                -- This is the terminal event. Verify that the destination exists
                -- and contains data; do not compare this callback value to HTTP 200.
                local f = io.open(destination, "rb")
                local hasData = false
                if f then
                    local firstByte = f:read(1)
                    hasData = firstByte ~= nil
                    f:close()
                end
                finish(dataFinished and hasData, dataFinished and "download finished" or "download ended without data")
            end
        end)
    end)
    if not ok then
        finish(false, tostring(err))
    end
end

function checkForUpdates(silent)
    if updateCheckBusy then return end
    if type(downloadUrlToFile) ~= "function" then
        if not silent then msg("{FF6060}В этой сборке MoonLoader недоступна загрузка из интернета.") end
        return
    end
    updateCheckBusy = true
    local versionPath = getWorkingDirectory() .. "/semipay_remote_version.tmp"
    os.remove(versionPath)
    downloadWithFallback("version.txt", versionPath, function(success, detail)
        updateCheckBusy = false
        if not success then
            os.remove(versionPath)
            if not silent then msg("{FF6060}Не удалось проверить GitHub: " .. tostring(detail) .. ".") end
            return
        end
        local remote = readVersionFile(versionPath)
        os.remove(versionPath)
        if not remote then
            if not silent then msg("{FF6060}Не удалось прочитать номер версии с GitHub.") end
            return
        end
        latestVersion = remote
        updateAvailable = versionIsNewer(remote, SCRIPT_VERSION)
        if updateAvailable then
            msg("{FFD966}Доступно обновление semipay v" .. remote .. ". Открой /semipay и выбери «Обновить».")
        elseif not silent then
            msg("{90EE90}Установлена последняя версия semipay v" .. SCRIPT_VERSION .. ".")
        end
    end)
end

function installUpdate()
    if updateDownloadBusy then return end
    if not updateAvailable then
        msg("{FFAA60}Обновлений нет. Сначала выбери проверку обновлений.")
        return
    end
    if type(downloadUrlToFile) ~= "function" then
        msg("{FF6060}Загрузка недоступна в этой сборке MoonLoader.")
        return
    end
    local scriptPath = thisScript().path
    if type(scriptPath) ~= "string" or scriptPath == "" then
        msg("{FF6060}Не удалось определить путь к semipay.lua.")
        return
    end
    updateDownloadBusy = true
    local tempPath = scriptPath .. ".update.tmp"
    os.remove(tempPath)
    downloadWithFallback("semipay.lua", tempPath, function(success, detail)
        updateDownloadBusy = false
        if not success then
            os.remove(tempPath)
            msg("{FF6060}Не удалось скачать обновление: " .. tostring(detail) .. ". Текущая версия не изменена.")
            return
        end
        -- Проверяем содержимое до замены установленного скрипта.
        local f = io.open(tempPath, "r")
        local content = f and f:read("*a") or nil
        if f then f:close() end
        local remoteVersion = content and content:match('SCRIPT_VERSION%s*=%s*"([%d%.]+)"')
        if not content or not content:find('script_name("semipay")', 1, true)
            or not content:find('script_version(', 1, true) or not remoteVersion
            or not versionIsNewer(remoteVersion, SCRIPT_VERSION) then
            os.remove(tempPath)
            msg("{FF6060}Файл обновления не прошёл проверку версии. Текущий скрипт не изменён.")
            return
        end
        -- Без .bak: удаляем старый файл только после полной загрузки и проверки нового.
        if not os.remove(scriptPath) then
            os.remove(tempPath)
            msg("{FF6060}Не удалось заменить semipay.lua. Закрой игру и попробуй позже.")
            return
        end
        if not os.rename(tempPath, scriptPath) then
            os.remove(tempPath)
            msg("{FF6060}Не удалось переместить новый файл на место semipay.lua. Переустанови файл вручную.")
            return
        end
        msg("{90EE90}Обновление semipay до версии " .. remoteVersion .. " установлено. Перезапусти MoonLoader/игру.")
    end)
end

function doPayTaxes()
    debugLog("Step taxes: opening phone")
	sampSendChat("/phone")
	wait(250)
	cefSend("launchedApp|24")

	if not waitForDialog(6565, 5000) then
		msg("{FF6060}Ошибка: телефон не открылся")

		return
	end

	wait(50)
	sampSendDialogResponse(6565, 1, 4, "")

	local var_5_0 = waitForDialogDifferent(6565, 5000)

	if not var_5_0 then
		msg("{FF6060}Ошибка: результат налогов не появился. Повторная оплата не отправлена.")
		return
	end

	wait(50)
	local taxDialogText = sampGetDialogText() or ""
	local taxTextUtf8 = taxDialogText
	local decodeOk, decodedTaxText = pcall(function() return var_0_1:encode(taxDialogText) end)
	if decodeOk and decodedTaxText then taxTextUtf8 = decodedTaxText end
	-- sampGetDialogText() возвращает CP1251 (байты вида \xd3\xc2...).
	-- Для сравнения с UTF-8-строками Lua переводим его через encode(), не decode().
	-- Оставляем проверку исходника тоже: некоторые сборки могут вернуть UTF-8 сразу.
    local function containsNoTaxes(text)
        text = tostring(text):gsub("{%x%x%x%x%x%x}", "")
        -- Avoid string.lower(): Lua's byte-oriented lower() does not lowercase Cyrillic reliably.
        return text:find("ет налогов", 1, true) ~= nil
            or text:find("ЕТ НАЛОГОВ", 1, true) ~= nil
            or text:find("налогов, которые требуется оплатить", 1, true) ~= nil
            or text:find("налогов, которые требуются оплатить", 1, true) ~= nil
            or text:find("НАЛОГОВ, КОТОРЫЕ", 1, true) ~= nil
            or text:find("не требуется оплатить", 1, true) ~= nil
            or text:find("НЕ ТРЕБУЕТСЯ ОПЛАТИТЬ", 1, true) ~= nil
    end
    local noTaxesDue = containsNoTaxes(taxDialogText) or containsNoTaxes(taxTextUtf8)

    debugLog("Tax result dialog=" .. tostring(var_5_0) .. "; noTaxesDue=" .. tostring(noTaxesDue))
    if var_5_0 == 15252 then
        debugLog("Tax payment dialog detected; sending ONE response")
        -- Send the payment action only once. If the CEF-style dialog ignores the
        -- normal SA-MP response, use UI close/Enter fallbacks without resending payment.
        sampSendDialogResponse(15252, 1, 0, "")
        local taxResultChanged = waitForDialogClosedOrDifferent(15252, 500)
        if taxResultChanged == nil or taxResultChanged == 15252 then
            if sampIsDialogActive() and sampGetCurrentDialogId() == 15252 and type(sampCloseCurrentDialogWithButton) == "function" then
                sampCloseCurrentDialogWithButton(1)
                taxResultChanged = waitForDialogClosedOrDifferent(15252, 400)
            end
        end
        if (taxResultChanged == nil or taxResultChanged == 15252) and sampIsDialogActive() and sampGetCurrentDialogId() == 15252 and type(setVirtualKeyDown) == "function" then
            setVirtualKeyDown(0x0D, true)
            wait(120)
            setVirtualKeyDown(0x0D, false)
            taxResultChanged = waitForDialogClosedOrDifferent(15252, 700)
        end
        if taxResultChanged == nil or taxResultChanged == 15252 then
            msg("{FFAA60}Окно оплаты налогов не закрылось. Повторную оплату не отправлял; остановил цепочку. Закрой окно вручную и проверь баланс.")
            return
        end
        msg("{90EE90}Окно оплаты налогов закрылось; запрос отправлен. Проверь баланс для подтверждения списания.")
	elseif noTaxesDue then
		-- Это штатный результат, а не ошибка. На некоторых версиях сервера
		-- окно CEF имеет ID 0 и не закрывается обычным ответом SA-MP.
        if var_5_0 == 0 then
            cefSendRaw({220, 0, 27, 0})
		else
			sampCloseCurrentDialogWithButton(1)
		end
		wait(100)
		msg("{90EE90}Налогов к оплате нет — этап пропущен.")
	else
		if var_5_0 ~= 0 then sampCloseCurrentDialogWithButton(1) end
		msg("{FF6060}Неизвестный ответ по налогам. Дальнейшие действия остановлены.")
		return
	end

	-- Не ждём полный 5-секундный тайм-аут, если результат налогов — ID 0.
	-- Сначала пробуем открыть телефон, затем коротко ждём его настоящий ID.
	if not (sampIsDialogActive() and sampGetCurrentDialogId() == 6565) then
		cefSend("launchedApp|24")
		if not waitForDialog(6565, 900) then
			sampSendChat("/phone")
			wait(120)
			cefSend("launchedApp|24")
			if not waitForDialog(6565, 1800) then
				msg("{FF6060}Ошибка: меню телефона не открылось. Остановлено без повторной оплаты.")
				return
			end
		end
	end

    -- The SA-MP dialog text is returned in the game's legacy encoding, so
    -- comparing it to UTF-8 Russian literals is unreliable. In this menu the
    -- hotel extension action is the final non-empty row; its listitem is
    -- zero-based, therefore the last row index is count - 1.
    wait(60)
    local phoneMenuText = sampGetDialogText() or ""
    local function stripColorTags(value)
        return tostring(value):gsub("{%x+}", ""):gsub("\\r", "")
    end
    local nonEmptyLines = {}
    for line in phoneMenuText:gmatch("[^\r\n]+") do
        local cleanedLine = stripColorTags(line)
        cleanedLine = cleanedLine:gsub("^%s+", ""):gsub("%s+$", "")
        if cleanedLine ~= "" then
            nonEmptyLines[#nonEmptyLines + 1] = cleanedLine
        end
    end

    for i, line in ipairs(nonEmptyLines) do
    end

    -- Expected menu has at least the 4 account actions plus other options.
    -- Select the final row only when the menu shape looks valid.
    if #nonEmptyLines < 10 then
        msg("{FFAA60}Не удалось определить пункт отеля: меню неожиданной длины.")
        return
    end

    local hotelIndex = #nonEmptyLines - 1
    debugLog("Hotel menu selected index=" .. tostring(hotelIndex) .. "; rows=" .. tostring(#nonEmptyLines))
    sampSendDialogResponse(6565, 1, hotelIndex, "")

    if not waitForDialog(26148, 5000) then
        local currentId = sampIsDialogActive() and sampGetCurrentDialogId() or -1
        msg("{FF6060}Ошибка: диалог отеля не появился. Меню оставлено для ручного управления.")
        return
    end

	wait(80)

	local hotelText = sampGetDialogText() or ""

	-- Ищем остаток часов в тексте списка. Не используем резервный срок:
	-- если остаток неизвестен, безопаснее пропустить отель, чем получить отказ
	-- сервера или случайно отправить неверный вариант.
    local hotelTextUtf8 = hotelText
    local hotelDecodeOk, hotelDecoded = pcall(function() return var_0_1:encode(hotelText) end)
    if hotelDecodeOk and hotelDecoded then hotelTextUtf8 = hotelDecoded end
    local hotelPlainText = hotelTextUtf8:gsub("{%x%x%x%x%x%x}", "")

    -- Parse only the explicit remaining-hours label. Never infer hours from an
    -- arbitrary number in the list: if the label cannot be read, skip payment.
    local availableHours = hotelPlainText:match("ПРОДЛИТЬ НА:%s*(%d+)%s*ЧАС")
        or hotelPlainText:match("продлить на:%s*(%d+)%s*час")
        or hotelPlainText:match("МОЖНО ПРОДЛИТЬ НА:%s*(%d+)%s*ЧАС")
        or hotelPlainText:match("можно продлить на:%s*(%d+)%s*час")
    availableHours = availableHours and tonumber(availableHours) or nil

	local hotelOptions = { {hours = 12, index = 0}, {hours = 24, index = 1}, {hours = 48, index = 2}, {hours = 96, index = 3} }
	local selectedHours, selectedIndex = nil, nil
	if availableHours then
		for _, option in ipairs(hotelOptions) do
			if option.hours <= availableHours then
				selectedHours, selectedIndex = option.hours, option.index
			end
		end
	end

	if not selectedHours then
		if availableHours and availableHours < 12 then
			msg("{FFAA60}Продление отеля пропущено: доступно меньше 12 часов.")
		else
			msg("{FFAA60}Не удалось проверить остаток часов отеля. Продление пропущено для безопасности.")
		end
        -- Zero hours is a valid server state after taxes are paid. Close the
        -- hotel options dialog without selecting an extension, trying several
        -- non-payment close methods and verifying the dialog is gone.
        sampSendDialogResponse(26148, 0, -1, "")
        local closed = false
        local closeDeadline = nowMs() + 300
        while nowMs() < closeDeadline do
            wait(50)
            if not sampIsDialogActive() or sampGetCurrentDialogId() ~= 26148 then
                closed = true
                break
            end
        end
        if not closed and sampIsDialogActive() and sampGetCurrentDialogId() == 26148 and type(sampCloseCurrentDialogWithButton) == "function" then
            sampCloseCurrentDialogWithButton(0)
            local deadline = nowMs() + 300
            while nowMs() < deadline do
                wait(50)
                if not sampIsDialogActive() or sampGetCurrentDialogId() ~= 26148 then
                    closed = true
                    break
                end
            end
        end
        if not closed and sampIsDialogActive() and sampGetCurrentDialogId() == 26148 and type(setVirtualKeyDown) == "function" then
            setVirtualKeyDown(0x1B, true)
            wait(80)
            setVirtualKeyDown(0x1B, false)
            local deadline = nowMs() + 350
            while nowMs() < deadline do
                wait(50)
                if not sampIsDialogActive() or sampGetCurrentDialogId() ~= 26148 then
                    closed = true
                    break
                end
            end
        end
        if not closed then
            msg("{FFAA60}Не удалось закрыть окно отеля автоматически. Семейная квартира не открывалась; закрой окно вручную.")
            return
        end
	else
		sampSendDialogResponse(26148, 1, selectedIndex, "")
		local nextDialog = waitForDialogDifferent(26148, 3000)
		if nextDialog == 26149 then
            local confirmText = sampGetDialogText() or ""
            local confirmTextUtf8 = confirmText
            local confirmDecodeOk, confirmDecoded = pcall(function() return var_0_1:encode(confirmText) end)
            if confirmDecodeOk and confirmDecoded then confirmTextUtf8 = confirmDecoded end
            local confirmPlainText = confirmTextUtf8:gsub("{%x%x%x%x%x%x}", "")
            local confirmedHours = confirmPlainText:match("ПРОДЛЕНИЯ:%s*(%d+)%s*ЧАС")
                or confirmPlainText:match("продления:%s*(%d+)%s*час")
                or confirmPlainText:match("(%d+)%s*ЧАСОВ")
                or confirmPlainText:match("(%d+)%s*часов")
                or confirmPlainText:match(":%s*(%d+)%s*$")
            local priceText = confirmPlainText:match(":CASH:%s*([%d%.,]+)")
            if not priceText then priceText = confirmPlainText:match("%$%s*([%d%.,]+)") end
            local normalizedPrice = normalizeIntegerAmount(priceText)
			if tonumber(confirmedHours) == selectedHours and normalizedPrice and tonumber(normalizedPrice) and tonumber(normalizedPrice) > 0 then
                sampSendDialogResponse(26149, 1, -1, "")
                -- Wait longer for the server response; never resend a payment confirmation automatically.
                local deadline = nowMs() + 250
                local changed = false
                while nowMs() < deadline do
                    wait(100)
                    if not sampIsDialogActive() or sampGetCurrentDialogId() ~= 26149 then
                        changed = true
                        break
                    end
                end
                if not changed and sampIsDialogActive() and sampGetCurrentDialogId() == 26149 then
                    -- First response did not close the same confirmation dialog.
                    -- Try the MoonLoader dialog-button helper once; do not repeat
                    -- sampSendDialogResponse and do not issue a second payment packet.
                    if type(sampCloseCurrentDialogWithButton) == "function" then
                        sampCloseCurrentDialogWithButton(1)
                        local fallbackDeadline = nowMs() + 250
                        while nowMs() < fallbackDeadline do
                            wait(100)
                            if not sampIsDialogActive() or sampGetCurrentDialogId() ~= 26149 then
                                changed = true
                                break
                            end
                        end
                    else
                    end
                end
                if not changed and sampIsDialogActive() and sampGetCurrentDialogId() == 26149 then
                    -- The hotel confirmation is rendered as a CEF-style overlay with a visible
                    -- Enter/Return hint on the yellow "ДАЛЕЕ" button. Try the keyboard shortcut
                    -- once instead of sending another payment response packet.
                    if type(setVirtualKeyDown) == "function" then
                        setVirtualKeyDown(0x0D, true)
                        wait(120)
                        setVirtualKeyDown(0x0D, false)
                        local keyDeadline = nowMs() + 400
                        while nowMs() < keyDeadline do
                            wait(100)
                            if not sampIsDialogActive() or sampGetCurrentDialogId() ~= 26149 then
                                changed = true
                                break
                            end
                        end
                    else
                    end
                end
                if changed then
                    msg("{90EE90}Запрос продления отеля на " .. tostring(selectedHours) .. " ч. отправлен. Стоимость: $" .. tostring(normalizedPrice) .. ".")
                else
                    msg("{FFAA60}Подтверждение отеля осталось открытым. Автоматические повторы отключены — проверь окно вручную.")
                    return
                end
			else
				msg("{FFAA60}Не удалось проверить срок или стоимость отеля. Продление пропущено.")
				sampSendDialogResponse(26149, 0, 0, "")
				wait(250)
			end
		else
			msg("{FFAA60}Сервер не открыл подтверждение отеля. Продление пропущено.")
			if sampIsDialogActive() and sampGetCurrentDialogId() == 26148 then
				sampSendDialogResponse(26148, 0, 0, "")
			end
		end
	end

    -- Do not start the family-apartment step while a hotel dialog is still open.
    if sampIsDialogActive() then
        local remainingDialogId = sampGetCurrentDialogId()
        if remainingDialogId == 26148 or remainingDialogId == 26149 then
            msg("{FFAA60}Окно отеля осталось открытым. Семейная квартира не открывалась; закрой окно вручную и запусти /w позже.")
            return
        end
    end

	wait(70)
	cefSendRaw({
		220,
		0,
		27,
		0
	})
	wait(180)
	sampSendChat("/fammenu")
	wait(250)
	cefSend("familyMenu.apart.payTax")

	-- В зависимости от версии CEF/сервера окно налога квартиры может иметь
	local apartmentDialogId = nil
	local apartmentDeadline = nowMs() + 4000
	while nowMs() < apartmentDeadline do
		wait(50)
		if sampIsDialogActive() then
			local currentId = sampGetCurrentDialogId()
			if currentId == 27833 or currentId == 27806 or currentId == 27834 then
				apartmentDialogId = currentId
				break
			end
		end
	end

    debugLog("Apartment tax dialog=" .. tostring(apartmentDialogId))
	if not apartmentDialogId then
		msg("{FF6060}Ошибка: диалог налога квартиры не распознан")
		return
	end

	wait(60)
	local apartmentText = sampGetDialogText() or ""
	local plainApartmentText = apartmentText:gsub("{%x%x%x%x%x%x}", "")

	-- В тексте CEF сумма может идти после цветового кода, поэтому не завязываемся
	-- на русское слово «составляет» (кодировка текста может отличаться).
	-- Первый :CASH: — текущий налог; следующий :CASH: — порог конфискации.
    local taxAmount = plainApartmentText:match(":CASH:%s*([%d%.,]+)")
    if not taxAmount then
        taxAmount = plainApartmentText:match("%$%s*([%d%.,]+)")
    end
    local normalizedTaxAmount = normalizeIntegerAmount(taxAmount)

    debugLog("Apartment tax raw=" .. tostring(taxAmount) .. "; normalized=" .. tostring(normalizedTaxAmount))
	if normalizedTaxAmount and tonumber(normalizedTaxAmount) and tonumber(normalizedTaxAmount) >= 0 then
		local taxAmountNumber = tonumber(normalizedTaxAmount)
		if taxAmountNumber == 0 then
			-- Нулевой налог — штатное состояние. Не отправляем платёж;
			-- пробуем закрыть модальное окно несколькими способами и проверяем результат.
			sampSendDialogResponse(apartmentDialogId, 0, 0, "")
			wait(180)
			if sampIsDialogActive() and sampGetCurrentDialogId() == apartmentDialogId then
				sampCloseCurrentDialogWithButton(0)
				wait(180)
			end
			if sampIsDialogActive() and sampGetCurrentDialogId() == apartmentDialogId then
				cefSendRaw({220, 0, 27, 0})
				wait(220)
			end
			if sampIsDialogActive() and sampGetCurrentDialogId() == apartmentDialogId then
				cefSend("familyMenu.exit")
				wait(250)
			end
			if sampIsDialogActive() and sampGetCurrentDialogId() == apartmentDialogId then
				msg("{FF6060}Налог равен $0, платёж не отправлен, но окно квартиры не удалось закрыть. Повтори попытку позже.")
				return
			end
			msg("{90EE90}Налог на квартиру равен $0 — оплачивать нечего, окно закрыто.")
		else
            sampSendDialogResponse(apartmentDialogId, 1, 0, normalizedTaxAmount)
            local apartmentResultChanged = waitForDialogClosedOrDifferent(apartmentDialogId, 1800)
            if apartmentResultChanged == nil or apartmentResultChanged == apartmentDialogId then
                msg("{FFAA60}Платёж квартиры отправлен, но результат не подтверждён. Не повторяй оплату автоматически; проверь состояние квартиры.")
                return
            end

            -- The server commonly replaces the apartment dialog with a CEF overlay
            -- (SA-MP dialog ID 0). Treat this as a result screen, not as a completed
            -- chain: close it and verify that it is actually gone before continuing.
            if apartmentResultChanged == 0 and sampIsDialogActive() and sampGetCurrentDialogId() == 0 then
                local apartmentResultText = sampGetDialogText() or ""
                cefSendRaw({220, 0, 27, 0})
                local resultClosed = false
                local closeDeadline = nowMs() + 500
                while nowMs() < closeDeadline do
                    wait(35)
                    if not sampIsDialogActive() or sampGetCurrentDialogId() ~= 0 then
                        resultClosed = true
                        break
                    end
                end
                if not resultClosed and sampIsDialogActive() and sampGetCurrentDialogId() == 0 and type(setVirtualKeyDown) == "function" then
                    setVirtualKeyDown(0x1B, true)
                    wait(100)
                    setVirtualKeyDown(0x1B, false)
                    local escapeDeadline = nowMs() + 500
                    while nowMs() < escapeDeadline do
                        wait(35)
                        if not sampIsDialogActive() or sampGetCurrentDialogId() ~= 0 then
                            resultClosed = true
                            break
                        end
                    end
                end
                if not resultClosed then
                    msg("{FFAA60}Ответ сервера по налогу квартиры получен, но окно результата не закрылось. Повторно не оплачивай; закрой окно вручную.")
                    return
                end
            end
            msg("{90EE90}Запрос оплаты налога квартиры отправлен; результатный диалог обработан. Сумма: $" .. normalizedTaxAmount)
		end
	else
		msg("{FF6060}Не удалось распознать сумму налога квартиры. Оплата не отправлена.")
		return
	end

	wait(150)
	cefSend("familyMenu.exit")
	wait(180)
	if sampIsDialogActive() and (sampGetCurrentDialogId() == 27833 or sampGetCurrentDialogId() == 27806 or sampGetCurrentDialogId() == 27834) then
		cefSendRaw({220, 0, 27, 0})
		wait(250)
	end
	if sampIsDialogActive() and (sampGetCurrentDialogId() == 27833 or sampGetCurrentDialogId() == 27806 or sampGetCurrentDialogId() == 27834) then
		msg("{FF6060}Окно семейной квартиры осталось открытым. Автоматическое продолжение остановлено.")
		return
	end
end

function msg(arg_6_0)
    local message = tostring(arg_6_0)
    debugLog("CHAT: " .. message:gsub("{[%x]+}", ""))
    local okPrefix, prefix = pcall(function() return var_0_1:decode("[semipay] ") end)
    local okMessage, decodedMessage = pcall(function() return var_0_1:decode(message) end)
    if okMessage and decodedMessage then message = decodedMessage end
    if okPrefix and prefix then message = prefix .. message else message = "[semipay] " .. message end
    sampAddChatMessage(message, 65280)
end

function waitForDialog(arg_7_0, arg_7_1)
    local var_7_0 = nowMs() + arg_7_1

	while var_7_0 > nowMs() do
		wait(35)

        if sampIsDialogActive() and sampGetCurrentDialogId() == arg_7_0 then
			return true
		end
	end

	return false
end

function waitForDialogDifferent(previousId, timeoutMs)
    local deadline = nowMs() + timeoutMs
    while deadline > nowMs() do
        wait(35)
        if sampIsDialogActive() then
            local currentId = sampGetCurrentDialogId()
            if currentId ~= previousId then
                debugLog("waitForDialogDifferent matched: " .. tostring(previousId) .. " -> " .. tostring(currentId))
                return currentId
            end
        end
    end
	return nil
end

function waitForDialogClosedOrDifferent(previousId, timeoutMs)
    local deadline = nowMs() + timeoutMs
    local inactiveSince = nil
    while deadline > nowMs() do
        wait(35)
        if sampIsDialogActive() then
            local currentId = sampGetCurrentDialogId()
            inactiveSince = nil
            if currentId ~= previousId then
                return currentId
            end
        else
            if not inactiveSince then inactiveSince = nowMs() end
            if nowMs() - inactiveSince >= 200 then
                return 0
            end
        end
    end
    return nil
end

function waitForAnyDialog(arg_8_0)
	local var_8_0 = nowMs() + arg_8_0

	while var_8_0 > nowMs() do
		wait(50)

		if sampIsDialogActive() then
			return sampGetCurrentDialogId()
		end
	end

	return nil
end

function cefSendRaw(arg_9_0)
	local var_9_0 = raknetNewBitStream()

	for iter_9_0, iter_9_1 in ipairs(arg_9_0) do
		raknetBitStreamWriteInt8(var_9_0, iter_9_1)
	end

	raknetSendBitStreamEx(var_9_0, 1, 7, 1)
	raknetDeleteBitStream(var_9_0)
end

function cefSend(arg_10_0)
	local var_10_0 = raknetNewBitStream()

	raknetBitStreamWriteInt8(var_10_0, 220)
	raknetBitStreamWriteInt8(var_10_0, 18)
	raknetBitStreamWriteInt16(var_10_0, string.len(arg_10_0))
	raknetBitStreamWriteString(var_10_0, arg_10_0)
	raknetSendBitStreamEx(var_10_0, 1, 7, 1)
	raknetDeleteBitStream(var_10_0)
end
