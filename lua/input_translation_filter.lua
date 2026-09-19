local state = require("input_translation_state")

local HOME = os.getenv("HOME") or ""
local RUNTIME_DIR = HOME .. "/Library/Rime"
local REQUEST_FILE = RUNTIME_DIR .. "/input_translation.requests.tsv"
local CACHE_FILE = RUNTIME_DIR .. "/input_translation.cache.tsv"
local PROVIDER_CONFIG_FILE = RUNTIME_DIR .. "/translation.providers.yaml"
local EMOJI_REQUEST_FILE = RUNTIME_DIR .. "/input_translation.emoji.requests.tsv"
local EMOJI_CACHE_FILE = RUNTIME_DIR .. "/input_translation.emoji.cache.tsv"
local EMOJI_MAP_FILE = HOME .. "/Library/Rime/others/emoji-map.txt"
local REVEALED_PROPERTY = "_translation_revealed_candidates"
local REVEALED_SEPARATOR = string.char(31)
local MAX_REVEALED = 32

local requested = {}
local online_requested = {}
local phonetic_requested = {}
local socket_ok, socket = pcall(require, "socket")
local retry_interval = 1.5
local max_requested = 256

local function clock()
    if socket_ok and socket and socket.gettime then return socket.gettime() end
    return os.time()
end

local function mark_request(map, key, current)
    local last = map[key]
    if last and current - last < retry_interval then return false end
    map[key] = current

    local count = 0
    local oldest_key, oldest_time
    for item, timestamp in pairs(map) do
        count = count + 1
        if not oldest_time or timestamp < oldest_time then
            oldest_key, oldest_time = item, timestamp
        end
    end
    if count > max_requested then map[oldest_key] = nil end
    return true
end

local function has_cjk(text)
    return text and text:match("[\228-\233][\128-\191][\128-\191]") ~= nil
end

local function is_english(text)
    return text and text:match("^[A-Za-z][A-Za-z0-9%s%-%'%.]*$") ~= nil
end

local function translation_target_for(text, configured_target)
    if is_english(text) then return "zh-CN" end
    return configured_target
end

local function local_dictionary_enabled()
    local file = io.open(PROVIDER_CONFIG_FILE, "r")
    if not file then return false end
    local in_provider = false
    for line in file:lines() do
        if line:match("^%s*mac_dictionary:%s*$") then
            in_provider = true
        elseif in_provider and line:match("^%S") then
            in_provider = false
        elseif in_provider then
            local value = line:match("^%s+enabled:%s*(%S+)")
            if value then
                file:close()
                return value == "true"
            end
        end
    end
    file:close()
    return false
end

local emoji_chinese
local function load_emoji_chinese()
    if emoji_chinese then return emoji_chinese end
    emoji_chinese = {}
    local file = io.open(EMOJI_MAP_FILE, "r")
    if not file then return emoji_chinese end
    for line in file:lines() do
        local emoji, names = line:match("^(%S+)%s+(.+)$")
        local chinese = names and names:match("^(%S+)")
        if emoji and chinese and emoji ~= "#" then emoji_chinese[emoji] = chinese end
    end
    file:close()
    return emoji_chinese
end

local function is_emoji(text)
    if not text then return false end
    if load_emoji_chinese()[text] then return true end
    for _, codepoint in utf8.codes(text) do
        if codepoint >= 0x1F000
            or (codepoint >= 0x2600 and codepoint <= 0x27FF)
            or (codepoint >= 0xFE00 and codepoint <= 0xFE0F) then
            return true
        end
    end
    return false
end

local function load_emoji_cache()
    local result = {}
    local file = io.open(EMOJI_CACHE_FILE, "r")
    if not file then return result end
    for line in file:lines() do
        local emoji, english = line:match("^(.-)\t(.*)$")
        if emoji and english and emoji ~= "" and english ~= "" then result[emoji] = english end
    end
    file:close()
    return result
end

local emoji_requested = {}
local function request_emoji_name(emoji)
    local current = clock()
    if not mark_request(emoji_requested, emoji, current) then return end
    local file = io.open(EMOJI_REQUEST_FILE, "a")
    if not file then return end
    file:write((emoji:gsub("[\r\n\t]", " ")), "\t", tostring(current), "\n")
    file:close()
end

local function load_cache()
    local result = {}
    local file = io.open(CACHE_FILE, "r")
    if not file then return result end

    for line in file:lines() do
        local target, word, translation, phonetic, provider =
            line:match("^(.-)\t(.-)\t(.-)\t(.-)\t(.*)$")
        if not target then
            target, word, translation, phonetic =
                line:match("^(.-)\t(.-)\t(.-)\t(.*)$")
        end
        if not target then
            word, translation = line:match("^(.-)\t(.*)$")
            target = "en"
        end
        if word and translation and word ~= "" and translation ~= "" then
            result[target] = result[target] or {}
            result[target][word] = {
                text = translation,
                phonetic = phonetic,
                provider = provider,
            }
        end
    end
    file:close()
    return result
end

local function request_translation(word, target_language, allow_online_fallback, phonetic_only)
    local request_key = target_language .. "\0" .. word
    local current = clock()
    local request_map
    if phonetic_only then
        request_map = phonetic_requested
    else
        request_map = allow_online_fallback and online_requested or requested
    end
    if not mark_request(request_map, request_key, current) then return end
    local file = io.open(REQUEST_FILE, "a")
    if not file then return end
    file:write((word:gsub("[\r\n\t]", " ")), "\t", target_language,
               "\t", tostring(current), "\t",
               allow_online_fallback == false and "0" or "1",
               phonetic_only and "\tphonetic" or "", "\n")
    file:close()
end

local function append_comment(base, value, separator)
    base = base or ""
    separator = separator or " · "
    if base == "" then return separator .. value end
    return base .. separator .. value
end

local function append_translation(base, value)
    local comment = append_comment(base, value, "\t")
    if comment:sub(1, 1) ~= "\t" then comment = "\t" .. comment end
    return comment
end

local function format_translation(translation, phonetic)
    if not phonetic or phonetic == "" then return translation end
    if phonetic:sub(1, 1) == "/" then
        return translation .. " " .. phonetic
    end
    return translation .. " /" .. phonetic .. "/"
end

local function load_revealed(context)
    local revealed = {}
    local order = {}
    local value = context:get_property(REVEALED_PROPERTY) or ""
    for text in value:gmatch("[^" .. REVEALED_SEPARATOR .. "]+") do
        if text ~= "" and not revealed[text] then
            revealed[text] = true
            order[#order + 1] = text
        end
    end
    return revealed, order
end

local function remember_revealed(revealed, order, text)
    if not text or text == "" or revealed[text] then return false end
    revealed[text] = true
    order[#order + 1] = text
    if #order > MAX_REVEALED then
        local removed = table.remove(order, 1)
        revealed[removed] = nil
    end
    return true
end

local function save_revealed(context, order)
    context:set_property(REVEALED_PROPERTY, table.concat(order, REVEALED_SEPARATOR))
end

local function filter(input, env)
    local enabled = state.is_enabled()
    local phonetic_enabled = enabled and state.is_phonetic_enabled()
    local mac_dictionary = enabled and local_dictionary_enabled()
    local target_language = "en"
    local candidate_count = 1
    local show_hints = true
    local config = env.engine.schema.config
    if config then
        local language = config:get_string("translation/target_language")
        if language and language ~= "" then target_language = language end
        local configured_count = config:get_int("translation/candidate_count")
        if configured_count then
            candidate_count = math.min(9, math.max(1, configured_count))
        end
        local configured_show_hints = config:get_bool("translation/show_hints")
        if configured_show_hints ~= nil then show_hints = configured_show_hints end
    end
    local cache = enabled and load_cache() or {}
    local emoji_cache = enabled and load_emoji_cache() or {}
    local emoji_names = load_emoji_chinese()
    local selected_text = env.engine.context:get_property("_translation_refresh_selected_text")
    if selected_text == "" then selected_text = nil end
    if not selected_text then
        selected_text = env.engine.context:get_property("_translation_selected_text")
        if selected_text == "" then selected_text = nil end
    end
    if enabled and env.engine.context:has_menu() and not selected_text then
        local selected_candidate = env.engine.context:get_selected_candidate()
        selected_text = selected_candidate and selected_candidate.text or nil
    end
    local revealed, revealed_order = load_revealed(env.engine.context)
    local revealed_changed = false
    if mac_dictionary then
        revealed_changed = remember_revealed(revealed, revealed_order, selected_text)
    end
    local hint_index = 9
    if config then
        local configured_page_size = config:get_int("menu/page_size")
        if configured_page_size and configured_page_size > 0 then
            hint_index = configured_page_size
        end
    end

    -- Put the currently highlighted candidate at the front of the request
    -- queue.  The normal candidate order otherwise requests candidate 1
    -- before the selected candidate, which makes the result appear one move
    -- late when the network is slow.
    if mac_dictionary and selected_text and (has_cjk(selected_text) or is_english(selected_text)) then
        local selected_target = translation_target_for(selected_text, target_language)
        local selected_entry = (cache[selected_target] or {})[selected_text]
        local selected_translation = type(selected_entry) == "table" and selected_entry.text or selected_entry
        local selected_phonetic = type(selected_entry) == "table" and selected_entry.phonetic or nil
        if not selected_translation or selected_translation == selected_text then
            request_translation(selected_text, selected_target, true)
        elseif phonetic_enabled and (not selected_phonetic or selected_phonetic == "") then
            -- Rime may lazily stop iterating before a lower selected candidate.
            -- Request its phonetic here so arrow navigation never depends on
            -- the candidate loop reaching that row.
            request_translation(selected_text, selected_target, true, true)
        end
    end

    local index = 0
    for candidate in input:iter() do
        index = index + 1
        local output = candidate
        if enabled then
            local comment = candidate.comment or ""
            local show_current
            if mac_dictionary then
                show_current = (selected_text and selected_text == candidate.text) or
                    (not selected_text and index == 1)
            else
                show_current = index == 1
            end
            local is_configured_candidate = mac_dictionary or index <= candidate_count
            if is_configured_candidate then
                revealed_changed = remember_revealed(revealed, revealed_order,
                                                       candidate.text) or revealed_changed
            end
            if mac_dictionary and show_current then
                revealed_changed = remember_revealed(revealed, revealed_order,
                                                       candidate.text) or revealed_changed
            end
            if mac_dictionary then
                revealed_changed = remember_revealed(revealed, revealed_order,
                                                       candidate.text) or revealed_changed
            end
            local show_translation = mac_dictionary and revealed[candidate.text] == true or
                (not mac_dictionary and index == 1)
            local should_request = mac_dictionary or index == 1
            local allow_online_fallback = not mac_dictionary or show_current
            local target = translation_target_for(candidate.text, target_language)

            if is_emoji(candidate.text) and show_translation then
                local chinese = emoji_names[candidate.text]
                local english = emoji_cache[candidate.text]
                if chinese then comment = append_translation(comment, chinese) end
                if english then
                    comment = append_translation(comment, english)
                elseif mac_dictionary or show_current then
                    request_emoji_name(candidate.text)
                end
            elseif is_emoji(candidate.text) and show_current then
                request_emoji_name(candidate.text)
            elseif show_translation and (has_cjk(candidate.text) or is_english(candidate.text)) then
                local target_cache = cache[target] or {}
                local entry = target_cache[candidate.text]
                local translation = type(entry) == "table" and entry.text or entry
                -- Ignore stale entries where a provider returned the Chinese
                -- source unchanged instead of an English translation.
                if target == "en" and translation == candidate.text then
                    translation = nil
                end
                -- 已展开候选的音标与译文一起保留；对已显示的候选补查缺失音标。
                -- 已取得的音标始终保留显示；只有第一候选或当前选中项补查音标。
                local phonetic_candidate = index == 1 or show_current
                local show_phonetic = phonetic_enabled and show_translation
                local phonetic = show_phonetic and type(entry) == "table" and entry.phonetic or nil
                if translation then
                    comment = append_translation(comment,
                                                  format_translation(translation, phonetic))
                    if should_request and phonetic_candidate and not phonetic then
                        request_translation(candidate.text, target, allow_online_fallback, true)
                    end
                elseif should_request then
                    request_translation(candidate.text, target, allow_online_fallback)
                end
            end

            if comment ~= (candidate.comment or "") then
                output = candidate:to_shadow_candidate(candidate.type, candidate.text, comment)
            end
            if show_hints and index == hint_index then
                local hint = string.char(30) .. "⌃P 朗读 · ⌃Y 上屏 · ⌃⇧P 音标" ..
                    (phonetic_enabled and "✓" or "×") .. string.char(31)
                local hint_gap = "\t\t"
                local hinted_comment = comment == "" and hint_gap .. hint or comment .. hint_gap .. hint
                output = candidate:to_shadow_candidate(candidate.type, candidate.text, hinted_comment)
            end
        end
        -- Rime 按需拉取候选，可能在 filter 末尾前停止迭代；在产出首个
        -- 候选前保存已展开集合，避免下一次重算丢失之前显示的译文。
        if revealed_changed then
            save_revealed(env.engine.context, revealed_order)
            revealed_changed = false
        end
        yield(output)
    end
end

return filter
