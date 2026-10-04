local state = require("input_translation_state")
local shortcut_help = require("input_translation_help")
local kAccepted, kNoop = 1, 2

local HOME = os.getenv("HOME") or ""
local RUNTIME_DIR = HOME .. "/Library/Rime"
local CACHE_FILE = RUNTIME_DIR .. "/input_translation.cache.tsv"
local SEARCH_ENGINES_FILE = RUNTIME_DIR .. "/input_translation.search-engines"
local SPEECH_REQUEST_FILE = RUNTIME_DIR .. "/input_translation.speech.requests.tsv"
local OPEN_URL_HELPER = RUNTIME_DIR .. "/bin/squirrel-open-url"
local SHOW_ALL_HINTS_PROPERTY = shortcut_help.visible_property
local SHOW_ALL_HINTS_INPUT_PROPERTY = shortcut_help.input_property
local HELP_PAGE_PROPERTY = shortcut_help.page_property
local QUERY_CLIENT_APP = "org.owllinker.SquirrelTranslate.InputBar"

local function is_english(text)
    return text and text:match("^[A-Za-z][A-Za-z0-9%s%-%'%.]*$") ~= nil
end

local function translation_target(text, configured_target)
    if is_english(text) then return "zh-CN" end
    return configured_target
end

local function load_translation(text, target)
    local file = io.open(CACHE_FILE, "r")
    if not file then return nil end
    for line in file:lines() do
        local cached_target, word, translation = line:match("^(.-)\t(.-)\t(.-)\t.*$")
        if not cached_target then
            cached_target, word, translation = line:match("^(.-)\t(.-)\t(.*)$")
        end
        if cached_target == target and word == text and translation and translation ~= "" then
            file:close()
            return translation
        end
    end
    file:close()
    return nil
end

local function request_speech(text)
    local file = io.open(SPEECH_REQUEST_FILE, "a")
    if not file then return false end
    file:write((text:gsub("[\r\n\t]", " ")), "\n")
    file:close()
    return true
end

local function url_encode(text)
    return (text:gsub("([^A-Za-z0-9%-._~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

local function valid_search_url(value)
    return value and value:match("^https?://[^/%s?#]+") and
        not value:find("%s") and value:find("{query}", 1, true)
end

local function search_engine_override(slot)
    local file = io.open(SEARCH_ENGINES_FILE, "r")
    if not file then return nil end
    local key = slot == "secondary" and "secondary" or "default"
    local result
    for line in file:lines() do
        local name, value = line:match("^([^=]+)=(.-)%s*$")
        if name == key and valid_search_url(value) then
            result = value
            break
        end
    end
    file:close()
    return result
end

local function shell_quote(text)
    return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function open_url(url)
    local command = shell_quote(OPEN_URL_HELPER) .. " " .. shell_quote(url) ..
        " >/dev/null 2>&1 &"
    local ok = os.execute(command)
    return ok == true or ok == 0
end

local function is_escape_key(key)
    local repr = key:repr()
    return repr == "Escape" or repr == "Esc"
end

local function canonical_key_repr(repr)
    local modifiers = {}
    local key_name
    for token in repr:gmatch("[^+]+") do
        local lower = token:lower()
        if lower == "shift" or lower == "control" or lower == "alt" or lower == "super" then
            modifiers[#modifiers + 1] = lower
        else
            key_name = lower
        end
    end
    table.sort(modifiers)
    if not key_name then return repr:lower() end
    return table.concat(modifiers, "+") .. ( #modifiers > 0 and "+" or "") .. key_name
end

local function key_matches(key, configured_repr)
    local repr = key:repr()
    return repr == configured_repr or canonical_key_repr(repr) == canonical_key_repr(configured_repr)
end

local function clear_composition(context)
    context:clear()
    -- 某些 Rime 方案会先关闭 menu，再保留未确认组合；再次调用专用
    -- 接口确保发送给应用的 marked text 也同步清除。
    if context.clear_non_confirmed_composition then
        context:clear_non_confirmed_composition()
    end
end

local function settings(env)
    if env.input_translation_settings then
        return env.input_translation_settings
    end
    local result = {
        toggle_key = "Control+t",
        speak_key = "Control+p",
        commit_translation_key = "Control+y",
        phonetic_toggle_key = "Shift+p",
        search_key = "Control+g",
        search_url = "https://www.google.com/search?q={query}",
        secondary_search_key = "Control+b",
        secondary_search_url = "https://www.bing.com/search?q={query}",
        news_key = "Control+n",
        show_all_hints_key = "Super+comma",
        target_language = "en",
    }
    local config = env.engine.schema.config
    if config then
        result.toggle_key = config:get_string("translation/toggle_key") or result.toggle_key
        result.speak_key = config:get_string("translation/speak_key") or result.speak_key
        result.commit_translation_key = config:get_string("translation/commit_translation_key") or result.commit_translation_key
        result.phonetic_toggle_key = config:get_string("translation/phonetic_toggle_key") or result.phonetic_toggle_key
        result.search_key = config:get_string("translation/search_key") or result.search_key
        result.secondary_search_key = config:get_string("translation/secondary_search_key") or
            result.secondary_search_key
        local search_urls = config:get_list("translation/search_url")
        local search_url
        if search_urls then
            local first = search_urls.size > 0 and search_urls:get_value_at(0)
            search_url = first and first.value or nil
        else
            -- Keep existing single-address configuration working.
            search_url = config:get_string("translation/search_url")
        end
        if search_url and search_url:match("^https?://[^/%s?#]+") and
            not search_url:find("%s") and
            search_url:find("{query}", 1, true) then
            result.search_url = search_url
        end
        local secondary_search_url = config:get_string("translation/secondary_search_url")
        if valid_search_url(secondary_search_url) then
            result.secondary_search_url = secondary_search_url
        end
        result.news_key = config:get_string("translation/news_key") or result.news_key
        result.show_all_hints_key = config:get_string("translation/show_all_hints_key") or result.show_all_hints_key
        result.target_language = config:get_string("translation/target_language") or result.target_language
    end
    result.search_url = search_engine_override("default") or result.search_url
    result.secondary_search_url = search_engine_override("secondary") or
        result.secondary_search_url
    env.input_translation_settings = result
    return result
end

local function processor(key, env)
    local configured = settings(env)
    local toggle_key = configured.toggle_key
    local speak_key = configured.speak_key
    local commit_translation_key = configured.commit_translation_key
    local phonetic_toggle_key = configured.phonetic_toggle_key
    local search_key = configured.search_key
    local news_key = configured.news_key
    local show_all_hints_key = configured.show_all_hints_key
    local target_language = configured.target_language

    local context = env.engine.context
    context:set_property("_translation_search_default_url", configured.search_url)
    context:set_property("_translation_search_secondary_url",
                         configured.secondary_search_url)
    -- Only the transparent query client has a launch prefix. Keep native u
    -- candidates until the next letter, then replace u inside this same Rime
    -- transaction: no IMK cancel/discard race and no extra synthetic key.
    if context:get_property("client_app") == QUERY_CLIENT_APP then
        local input = context.input or ""
        local repr = key:repr()
        if not key:release() and not context:get_option("ascii_mode") then
            if input == "" and repr == "u" then
                env.input_bar_prefix_pending = true
                -- Keep the query prefix inside the same Rime composition.
                -- Passing the first u through the normal schema can commit it
                -- immediately, which makes the native candidate panel flash
                -- and disappear before the next letter arrives.
                context:push_input("u")
                context:refresh_non_confirmed_composition()
                context:set_property("_refresh_ui", "1")
                state.set_composition_visible(context:has_menu())
                return kAccepted
            elseif env.input_bar_prefix_pending then
                local letter = repr:match("^([A-Za-z])$") or repr:match("^Shift%+([A-Za-z])$")
                if input == "u" and letter then
                    env.input_bar_prefix_pending = false
                    context:clear()
                    context:push_input(letter)
                    state.set_composition_visible(context:has_menu())
                    return kAccepted
                elseif input ~= "u" or is_escape_key(key) then
                    env.input_bar_prefix_pending = false
                end
            end
        end
    else
        env.input_bar_prefix_pending = false
    end
    state.set_composition_visible(context:has_menu())
    local help_input = context:get_property(SHOW_ALL_HINTS_INPUT_PROPERTY) or ""
    if help_input ~= "" and
        (help_input ~= (context.input or "") or not context:has_menu()) then
        context:set_property(SHOW_ALL_HINTS_PROPERTY, "")
        context:set_property(SHOW_ALL_HINTS_INPUT_PROPERTY, "")
        context:set_property(HELP_PAGE_PROPERTY, "0")
    end
    local help_visible = context:get_property(SHOW_ALL_HINTS_PROPERTY) == "1" and
        context:get_property(SHOW_ALL_HINTS_INPUT_PROPERTY) == (context.input or "")
    if help_visible then
        if key:release() then return kAccepted end
        local repr = key:repr()
        if repr == show_all_hints_key then
            context:set_property(SHOW_ALL_HINTS_PROPERTY, "")
            context:set_property(SHOW_ALL_HINTS_INPUT_PROPERTY, "")
            context:set_property(HELP_PAGE_PROPERTY, "0")
        elseif is_escape_key(key) then
            context:set_property(SHOW_ALL_HINTS_PROPERTY, "")
            context:set_property(SHOW_ALL_HINTS_INPUT_PROPERTY, "")
            context:set_property(HELP_PAGE_PROPERTY, "0")
        elseif repr == "Page_Up" or repr == "Prior" or repr == "Up" then
            local page = tonumber(context:get_property(HELP_PAGE_PROPERTY)) or 0
            context:set_property(HELP_PAGE_PROPERTY, tostring(math.max(0, page - 1)))
        elseif repr == "Page_Down" or repr == "Next" or repr == "Down" then
            local config = env.engine.schema.config
            local page_size = config and config:get_int("menu/page_size") or 9
            local page = tonumber(context:get_property(HELP_PAGE_PROPERTY)) or 0
            local last_page = shortcut_help.page_count(page_size) - 1
            context:set_property(HELP_PAGE_PROPERTY,
                tostring(math.min(last_page, page + 1)))
        else
            return kAccepted
        end
        context:refresh_non_confirmed_composition()
        return kAccepted
    end
    if is_escape_key(key) and key:release() then
        return kAccepted
    end
    -- Consume Escape while Rime is composing or showing candidates.  Clearing
    -- here preserves the normal Rime cancel behavior without forwarding Esc
    -- to the foreground application.
    if is_escape_key(key) and context:has_menu() then
        clear_composition(context)
        context:set_property(SHOW_ALL_HINTS_PROPERTY, "")
        context:set_property(SHOW_ALL_HINTS_INPUT_PROPERTY, "")
        context:set_property(HELP_PAGE_PROPERTY, "0")
        state.set_composition_visible(false)
        return kAccepted
    end

    if key_matches(key, toggle_key) then
        if key:release() then return kAccepted end
        state.toggle()
        context:refresh_non_confirmed_composition()
        return kAccepted
    end

    if key_matches(key, phonetic_toggle_key) then
        if key:release() then return kAccepted end
        state.toggle_phonetic()
        context:refresh_non_confirmed_composition()
        return kAccepted
    end

    if not context:has_menu() then return kNoop end
    local candidate = context:get_selected_candidate()
    if not candidate or not candidate.text or candidate.text == "" then return kNoop end

    if key:repr() == show_all_hints_key and key:release() then
        return kAccepted
    end

    if key:repr() == show_all_hints_key then
        context:set_property(SHOW_ALL_HINTS_PROPERTY, "1")
        context:set_property(SHOW_ALL_HINTS_INPUT_PROPERTY, context.input or "")
        context:set_property(HELP_PAGE_PROPERTY, "0")
        context:refresh_non_confirmed_composition()
        return kAccepted
    end

    if key_matches(key, search_key) then
        if key:release() then return kAccepted end
        local query = url_encode(candidate.text)
        local template = search_engine_override("default") or configured.search_url
        local url = template:gsub("{query}", function() return query end)
        open_url(url)
        return kAccepted
    end

    if key_matches(key, configured.secondary_search_key) then
        if key:release() then return kAccepted end
        local query = url_encode(candidate.text)
        local template = search_engine_override("secondary") or
            configured.secondary_search_url
        local url = template:gsub("{query}", function() return query end)
        open_url(url)
        return kAccepted
    end

    if key_matches(key, news_key) then
        -- Consume both key-down and key-up so the foreground app cannot also
        -- act on the same shortcut. Trigger the URL only once, on key-down.
        if key:release() then return kAccepted end
        local url = "chrome-extension://ggdjphniobpobmofgoimigpdcefmljed/news/news.html?q=" ..
            url_encode(candidate.text)
        open_url(url)
        return kAccepted
    end

    if key_matches(key, speak_key) then
        if key:release() then return kAccepted end
        local target = translation_target(candidate.text, target_language)
        local translation = load_translation(candidate.text, target)
        if not translation then return kAccepted end
        request_speech(translation)
        return kAccepted
    end

    if key_matches(key, commit_translation_key) then
        if key:release() then return kAccepted end
        local target = translation_target(candidate.text, target_language)
        local translation = load_translation(candidate.text, target)
        if not translation then return kAccepted end
        env.engine:commit_text(translation)
        context:clear()
        state.set_composition_visible(false)
        return kAccepted
    end

    return kNoop
end

return processor
