local M = {
    visible_property = "_translation_show_all_shortcuts",
    input_property = "_translation_show_all_shortcuts_input",
    page_property = "_translation_help_page",
    entries = {
        { "⌃T", "开启或关闭候选翻译" },
        { "⌃P", "朗读当前候选的译文" },
        { "⌃Y", "上屏当前候选的译文" },
        { "⇧^", "展开或收起当前候选的完整翻译" },
        { "⇧P", "开启或关闭音标显示" },
        { "⌃G", "用默认搜索引擎搜索当前候选" },
        { "⌃B", "用第二搜索引擎搜索当前候选" },
        { "1–9", "选择对应序号的候选词" },
        { "↑ / ↓", "在帮助视图中翻阅条目页" },
        { "PageUp / PageDown", "翻阅快捷键帮助" },
        { "⌘,", "关闭快捷键帮助" },
        { "Esc", "返回原候选列表" },
        { "点击 ⓘ", "打开或关闭本帮助" },
    },
}

function M.page_count(page_size)
    page_size = math.max(1, tonumber(page_size) or 9)
    return math.max(1, math.ceil(#M.entries / page_size))
end

return M
