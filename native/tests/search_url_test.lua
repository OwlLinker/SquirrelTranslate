-- No browser, network, user configuration, clipboard or request-file access.
local phonetic_state
package.preload.input_translation_state = function()
    phonetic_state = { phonetic_toggles = 0 }
    function phonetic_state.set_composition_visible() end
    function phonetic_state.toggle_phonetic()
        phonetic_state.phonetic_toggles = phonetic_state.phonetic_toggles + 1
    end
    return phonetic_state
end
-- Real librime-lua does not define these globals. Do not mask a processor
-- returning nil instead of its explicit consume/pass-through result.
local kAccepted, kNoop = 1, 2
assert(_G.kAccepted == nil and _G.kNoop == nil)
local processor = dofile("lua/input_translation_processor.lua")
local original_execute = os.execute
local original_io_open = io.open
local opened
local search_profile = {}
os.execute = function(command)
    opened = command
    return true
end
io.open = function(path, mode)
    if path:match("input_translation.search%-engines$") then
        local index = 0
        return {
            lines = function()
                return function()
                    index = index + 1
                    return search_profile[index]
                end
            end,
            close = function() end,
        }
    end
    return original_io_open(path, mode)
end

local function environment(url, text, has_menu, secondary_url)
    local reads = {}
    local context = { input = "nihao", candidate = { text = text or "你好 &/?#%" }, properties = {} }
    function context:has_menu() return has_menu ~= false end
    function context:get_selected_candidate() return self.candidate end
    function context:get_property(name) return self.properties[name] or "" end
    function context:set_property(name, value) self.properties[name] = value end
    function context:get_option() return self.ascii_mode or false end
    function context:clear() self.input = "" end
    function context:push_input(value) self.input = self.input .. value end
    function context:refresh_non_confirmed_composition()
        self.refresh_count = (self.refresh_count or 0) + 1
    end
    local config = {}
    function config:get_string(name)
        reads[name] = (reads[name] or 0) + 1
        if name == "translation/search_url" and type(url) ~= "table" then return url end
        if name == "translation/secondary_search_url" then return secondary_url end
    end
    function config:get_int(name)
        if name == "menu/page_size" then return 9 end
    end
    function config:get_list(name)
        reads[name .. "#list"] = (reads[name .. "#list"] or 0) + 1
        if name == "translation/search_url" and type(url) == "table" then
            return {
                size = #url,
                get_value_at = function(_, index)
                    if type(url[index + 1]) == "string" then
                        return { value = url[index + 1] }
                    end
                end,
            }
        end
    end
    return { engine = { schema = { config = config }, context = context } }, reads
end

local function key(repr, released)
    return { repr = function() return repr end, release = function() return released or false end }
end

local encoded = "%E4%BD%A0%E5%A5%BD%20%26%2F%3F%23%25"
local function check(url, expected)
    local env = environment(url)
    opened = nil
    assert(processor(key("Control+g"), env) == kAccepted)
    assert(opened and opened:find("'" .. expected .. "'", 1, true), opened)
end

local google = "https://www.google.com/search?q=" .. encoded
local bing = "https://www.bing.com/search?q=" .. encoded
check(nil, google)
check("https://www.bing.com/search?q={query}", "https://www.bing.com/search?q=" .. encoded)
check("https://duckduckgo.com/?q={query}&ia=web", "https://duckduckgo.com/?q=" .. encoded .. "&ia=web")
check("https://example.com/?q={query}&again={query}", "https://example.com/?q=" .. encoded .. "&again=" .. encoded)
check("", google)
check("https://example.com/?q=", google)
check("javascript:alert('{query}')", google)
check("https:///search?q={query}", google)
check("https://example.com/ bad?q={query}", google)
check("https://?q={query}", google)
check({}, bing)
check("https://www.google.com/search?q={query}", google)
check({ "https://www.google.com/search?q={query}" }, google)
check({ "https://www.bing.com/search?q={query}", "https://www.google.com/search?q={query}" },
    "https://www.bing.com/search?q=" .. encoded)
check({ "https://www.google.com/search?q={query}", "https://www.bing.com/search?q={query}" }, google)
check({ "", "https://www.bing.com/search?q={query}" }, google)
check({ { url = "https://www.bing.com/search?q={query}" } }, google)

local env, reads = environment("https://www.bing.com/search?q={query}", "first")
assert(processor(key("Control+g"), env) == kAccepted)
env.engine.context.candidate.text = "next word"
assert(processor(key("Control+g"), env) == kAccepted)
assert(opened:find("https://www.bing.com/search?q=next%20word", 1, true))
assert(reads["translation/search_url"] == 1, "configuration must not be reread on each key")
assert(reads["translation/search_url#list"] == 1, "list configuration must also be cached")

local list_env, list_reads = environment({ "https://www.bing.com/search?q={query}" }, "first")
assert(processor(key("Control+g"), list_env) == kAccepted)
assert(processor(key("Control+g"), list_env) == kAccepted)
assert(list_reads["translation/search_url#list"] == 1)
assert(list_reads["translation/search_url"] == nil)

local default_second = environment(nil, "默认候选")
opened = nil
assert(processor(key("Control+b"), default_second) == kAccepted)
assert(opened and opened:find("https://www.bing.com/search?q=", 1, true), opened)
local custom_second = environment(nil, "第二候选", true,
    "https://www.baidu.com/s?wd={query}")
opened = nil
assert(processor(key("Control+b"), custom_second) == kAccepted)
assert(opened and opened:find("https://www.baidu.com/s?wd=", 1, true), opened)

search_profile = {
    "default=https://search.brave.com/search?q={query}",
    "secondary=https://www.sogou.com/web?query={query}",
}
opened = nil
assert(processor(key("Control+g"), environment(nil, "覆盖默认")) == kAccepted)
assert(opened and opened:find("https://search.brave.com/search?q=", 1, true), opened)
opened = nil
assert(processor(key("Control+b"), environment(nil, "覆盖第二")) == kAccepted)
assert(opened and opened:find("https://www.sogou.com/web?query=", 1, true), opened)
io.open = original_io_open

opened = nil
assert(processor(key("Control+g"), environment(nil, "你好", false)) == kNoop)
assert(processor(key("a"), environment(nil)) == kNoop)
assert(opened == nil, "search must only run with candidates and its configured shortcut")
assert(processor(key("Control+n"), environment(nil, "你好")) == kNoop,
    "the public processor must not consume the unpublished news shortcut")
assert(opened == nil, "the public processor must not open an unpublished extension")
local phonetic_env = environment(nil)
assert(processor(key("Shift+p"), phonetic_env) == kAccepted,
    "Shift+P should toggle phonetic display")
assert(phonetic_state.phonetic_toggles == 1)
assert(processor(key("Control+Shift+p"), phonetic_env) == kNoop,
    "the old Control+Shift+P shortcut should no longer be active")
assert(phonetic_state.phonetic_toggles == 1)
local help = require("input_translation_help")
assert(help.page_count(9) == 2, "the help list should paginate with the standard page size")
local help_env = environment(nil)
local help_context = help_env.engine.context
assert(processor(key("Control+comma"), help_env) == kAccepted)
assert(help_context.properties[help.visible_property] == "1")
assert(help_context.properties[help.page_property] == "0")
assert(processor(key("Page_Down"), help_env) == kAccepted)
assert(help_context.properties[help.page_property] == "1")
assert(processor(key("Page_Down"), help_env) == kAccepted)
assert(help_context.properties[help.page_property] == "1", "help paging must clamp to the final page")
assert(processor(key("Page_Up"), help_env) == kAccepted)
assert(help_context.properties[help.page_property] == "0")
assert(processor(key("Escape"), help_env) == kAccepted)
assert(help_context.properties[help.visible_property] == "")
assert(help_context.input == "nihao", "leaving help must retain the original composition")
assert(processor(key("Escape", true), help_env) == kAccepted)
assert(help_context.input == "nihao", "Escape release must not cancel the retained composition")
assert(processor(key("Control+comma"), help_env) == kAccepted)
assert(processor(key("Control+comma", true), help_env) == kAccepted,
    "key releases in help mode should not reopen or alter the view")
assert(loadfile("lua/input_translation_filter.lua"))

local query_env = environment(nil)
local query_context = query_env.engine.context
query_context.properties.client_app = "org.owllinker.SquirrelTranslate.InputBar"
local function type_letters(value)
    for letter in value:gmatch(".") do
        local result = processor(key(letter), query_env)
        assert(result == kNoop or result == kAccepted, "processor must never return nil")
        if result == kNoop then query_context:push_input(letter) end
    end
end
query_context.input = ""
type_letters("u")
assert(query_context.input == "u", "lone u must retain its native candidates")
type_letters("nihao")
assert(query_context.input == "nihao", "strip one prefix without losing or duplicating n")
query_context.input = ""
type_letters("ushuru")
assert(query_context.input == "shuru", "the later u must remain ordinary pinyin")
query_context.input = ""
type_letters("uuU")
assert(query_context.input == "uU", "strip only the first u, including repeated u and upper-case U")
query_context.input = ""
type_letters("u")
assert(processor(key("Escape"), query_env) == kAccepted)
assert(query_context.input == "")
type_letters("unihao")
assert(query_context.input == "nihao", "Escape and repeated sessions must not leak the old prefix")
query_context.input = ""
query_context.ascii_mode = true
type_letters("unihao")
assert(query_context.input == "unihao", "English mode must not strip letters")
query_context.ascii_mode = false
query_context.input = ""
query_context.properties.client_app = "org.example.NativeEditor"
type_letters("unihao")
assert(query_context.input == "unihao", "ordinary input fields must not consume a prefix")
assert(_G.kAccepted == nil and _G.kNoop == nil, "constants must stay module-local")
os.execute = original_execute
print("PASS: explicit processor results, retained lone-u candidates, helper-only prefix, intact nihao/shuru/uU, Escape/repeat/English/native-editor guards, ordered engines, query encoding, config cache, candidate gate, unpublished news shortcut omitted")
