-- Rime 候选翻译桥接。
-- Rime Lua 负责候选和状态；本模块只消费请求、调用系统翻译并维护本地缓存。

local M = {}

local timerRegistry = require("utils.timerRegistry")
local translator = require("utils.translatePopup")

local RIME_DIR = (os.getenv("HOME") or "") .. "/Library/Rime"
local REQUEST_FILE = RIME_DIR .. "/input_translation.requests.tsv"
local CACHE_FILE = RIME_DIR .. "/input_translation.cache.tsv"
local EMOJI_REQUEST_FILE = RIME_DIR .. "/input_translation.emoji.requests.tsv"
local EMOJI_CACHE_FILE = RIME_DIR .. "/input_translation.emoji.cache.tsv"
local SYSTEM_PYTHON = "/usr/bin/python3"
local TIMER_PREFIX = "rimeTranslation:"
local POLL_INTERVAL = 0.25
local CACHE_LIMIT = 400
local MAX_PENDING = 32
local MAX_SEEN = 512

local seen = {}
local seenOrder = {}
local cache = {}
local cacheOrder = {}
local cacheRecords = {}
local queue = {}
local pending = {}
local activeKey = nil
local requestOffset = 0
local busy = false
local activeHandle = nil
local emojiSeen = {}
local emojiSeenOrder = {}
local emojiCache = {}
local emojiOrder = {}
local emojiQueue = {}
local emojiPending = {}
local emojiRequestOffset = 0
local emojiBusy = false
local activeEmojiTask = nil
local processNext

local function trim(value)
    return (value or ""):gsub("^%s*(.-)%s*$", "%1")
end

local function clean(value)
    return trim(value):gsub("[\r\n\t]", " ")
end

local function cacheKey(word, target)
    return target .. "\0" .. word
end

local function loadCache()
    cache = {}
    cacheOrder = {}
    cacheRecords = {}
    local file = io.open(CACHE_FILE, "r")
    if not file then return end

    for line in file:lines() do
        local target, word, translation, phonetic = line:match("^(.-)\t(.-)\t(.-)\t(.*)$")
        if not target then
            target, word, translation = line:match("^(.-)\t(.-)\t(.*)$")
        end
        if not target then
            word, translation = line:match("^(.-)\t(.*)$")
            target = "en"
        end
        target = clean(target)
        word = clean(word)
        translation = clean(translation)
        phonetic = clean(phonetic)
        local key = cacheKey(word, target)
        if word ~= "" and target ~= "" and translation ~= "" and not cache[key] then
            cache[key] = { text = translation, phonetic = phonetic }
            cacheRecords[key] = { target = target, word = word }
            cacheOrder[#cacheOrder + 1] = key
        end
    end
    file:close()
end

local function loadEmojiCache()
    emojiCache = {}
    emojiOrder = {}
    local file = io.open(EMOJI_CACHE_FILE, "r")
    if not file then return end
    for line in file:lines() do
        local emoji, english = line:match("^(.-)\t(.*)$")
        if emoji and english and emoji ~= "" and english ~= "" then
            emojiCache[emoji] = clean(english)
            emojiOrder[#emojiOrder + 1] = emoji
        end
    end
    file:close()
end

local function rememberSeen(map, order, key)
    if map[key] then return false end
    map[key] = true
    order[#order + 1] = key
    if #order > MAX_SEEN then
        map[table.remove(order, 1)] = nil
    end
    return true
end

local function readAppended(path, offset, handler)
    local file = io.open(path, "r")
    if not file then return offset end

    local size = file:seek("end") or 0
    if size < offset then offset = 0 end
    file:seek("set", offset)
    for line in file:lines() do handler(line) end
    local newOffset = file:seek() or size
    file:close()
    return newOffset
end

local function enqueueLine(line)
    local word, target, requestId = line:match("^(.-)\t([%w_%-]+)\t(.+)$")
    if not word then word, target = line:match("^(.-)\t([%w_%-]+)$") end
    word = clean(word or line)
    target = clean(target or "en")
    requestId = clean(requestId or (word .. "\t" .. target))
    if word == "" then return end

    local key = cacheKey(word, target)
    local seenKey = key .. "\0" .. requestId
    if not rememberSeen(seen, seenOrder, seenKey) then return end
    if not cache[key] and not pending[key] and activeKey ~= key then
        -- 候选请求持续追加；优先处理最新输入，避免旧请求阻塞当前面板。
        table.insert(queue, 1, { word = word, target = target })
        pending[key] = true
        while #queue > MAX_PENDING do
            local dropped = table.remove(queue)
            pending[cacheKey(dropped.word, dropped.target)] = nil
        end
    end
end

local function loadSeenRequests()
    seen = {}
    seenOrder = {}
    queue = {}
    pending = {}
    requestOffset = readAppended(REQUEST_FILE, 0, enqueueLine)
end

local function writeCache()
    local tempFile = CACHE_FILE .. ".tmp"
    local file = io.open(tempFile, "w")
    if not file then return end

    local first = math.max(1, #cacheOrder - CACHE_LIMIT + 1)
    for index = first, #cacheOrder do
        local key = cacheOrder[index]
        local entry = cache[key]
        local record = cacheRecords[key]
        if record and entry and entry.text and entry.text ~= "" then
            file:write(record.target, "\t", record.word, "\t", entry.text)
            if entry.phonetic and entry.phonetic ~= "" then file:write("\t", entry.phonetic) end
            file:write("\n")
        end
    end
    file:close()
    os.rename(tempFile, CACHE_FILE)
end

local function saveTranslation(request, translation, phonetic)
    local word = clean(request.word)
    local target = clean(request.target)
    translation = clean(translation)
    phonetic = clean(phonetic)
    if word == "" or target == "" or translation == "" then return end

    local key = cacheKey(word, target)
    if not cache[key] then cacheOrder[#cacheOrder + 1] = key end
    cache[key] = { text = translation, phonetic = phonetic }
    cacheRecords[key] = { target = target, word = word }

    while #cacheOrder > CACHE_LIMIT do
        local oldest = table.remove(cacheOrder, 1)
        cache[oldest] = nil
        cacheRecords[oldest] = nil
    end
    writeCache()
end

local function collectRequests()
    requestOffset = readAppended(REQUEST_FILE, requestOffset, enqueueLine)
end

local function enqueueEmojiLine(line)
    local emoji, requestId = line:match("^(.-)\t(.+)$")
    emoji = clean(emoji or line)
    requestId = clean(requestId or emoji)
    if emoji == "" then return end

    local seenKey = emoji .. "\0" .. requestId
    if not rememberSeen(emojiSeen, emojiSeenOrder, seenKey) then return end
    if emojiCache[emoji] or emojiPending[emoji] then return end
    table.insert(emojiQueue, 1, emoji)
    emojiPending[emoji] = true
    while #emojiQueue > MAX_PENDING do
        local dropped = table.remove(emojiQueue)
        emojiPending[dropped] = nil
    end
end

local function loadEmojiRequests()
    emojiSeen = {}
    emojiSeenOrder = {}
    emojiQueue = {}
    emojiPending = {}
    emojiRequestOffset = readAppended(EMOJI_REQUEST_FILE, 0, enqueueEmojiLine)
end

local function collectEmojiRequests()
    emojiRequestOffset = readAppended(EMOJI_REQUEST_FILE, emojiRequestOffset, enqueueEmojiLine)
end

local function writeEmojiCache()
    local tempFile = EMOJI_CACHE_FILE .. ".tmp"
    local file = io.open(tempFile, "w")
    if not file then return end
    for _, emoji in ipairs(emojiOrder) do
        local english = emojiCache[emoji]
        if english and english ~= "" then file:write(emoji, "\t", english, "\n") end
    end
    file:close()
    os.rename(tempFile, EMOJI_CACHE_FILE)
end

local function saveEmojiName(emoji, english)
    english = clean(english)
    if emoji == "" or english == "" then return end
    if not emojiCache[emoji] then emojiOrder[#emojiOrder + 1] = emoji end
    emojiCache[emoji] = english
    while #emojiOrder > CACHE_LIMIT do
        local oldest = table.remove(emojiOrder, 1)
        emojiCache[oldest] = nil
    end
    writeEmojiCache()
end

local function processEmojiNext()
    if emojiBusy or #emojiQueue == 0 then return false end
    if not hs.task or type(hs.task.new) ~= "function" then return false end

    local emoji = table.remove(emojiQueue, 1)
    emojiPending[emoji] = nil
    if emojiCache[emoji] then return true end
    local script = [=[
import sys, unicodedata

names = []
for char in sys.argv[1]:
    name = unicodedata.name(char, "")
    if name and "VARIATION SELECTOR" not in name and "ZERO WIDTH JOINER" not in name and "EMOJI MODIFIER" not in name:
        names.append(name)
print(", ".join(names))
]=]
    emojiBusy = true
    activeEmojiTask = hs.task.new(SYSTEM_PYTHON, function(exitCode, stdout, _)
        activeEmojiTask = nil
        emojiBusy = false
        if exitCode == 0 and stdout and stdout ~= "" then
            saveEmojiName(emoji, stdout)
        end
        processNext()
    end, { "-c", script, emoji })
    if not activeEmojiTask then
        emojiBusy = false
        return false
    end
    activeEmojiTask:start()
    return true
end

local function processTextNext()
    if busy or #queue == 0 then return end

    local request = table.remove(queue, 1)
    local key = cacheKey(request.word, request.target)
    pending[key] = nil
    activeKey = key
    if cache[key] then
        activeKey = nil
        processNext()
        return
    end
    if not translator or type(translator.translateAsync) ~= "function" then
        activeKey = nil
        return
    end

    busy = true
    local source = request.target == "zh-CN" and "en" or "zh-CN"
    activeHandle = translator.translateAsync(request.word, source, request.target, function(result, err, _, _, phonetic)
        activeHandle = nil
        activeKey = nil
        busy = false
        if result and not err then saveTranslation(request, result, phonetic) end
        processNext()
    end)
end

processNext = function()
    if busy or emojiBusy then return end
    if processEmojiNext() then return end
    processTextNext()
end

function M.stop()
    timerRegistry.stopByPrefix(TIMER_PREFIX)
    if activeHandle and activeHandle.cancel then activeHandle.cancel() end
    activeHandle = nil
    activeKey = nil
    if activeEmojiTask and activeEmojiTask.terminate then pcall(function() activeEmojiTask:terminate() end) end
    activeEmojiTask = nil
    queue = {}
    pending = {}
    busy = false
    emojiQueue = {}
    emojiPending = {}
    emojiBusy = false
end

function M.init()
    M.stop()
    loadCache()
    loadEmojiCache()
    loadSeenRequests()
    loadEmojiRequests()
    timerRegistry.every(TIMER_PREFIX .. "poll", POLL_INTERVAL, function()
        collectRequests()
        collectEmojiRequests()
        processNext()
    end)
end

return M
