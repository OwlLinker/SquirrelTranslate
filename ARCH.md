# 技术设计

## 鼠须管候选翻译

- Rime Lua 过滤器读取 `~/Library/Rime/input_translation.cache.tsv`，没有缓存时追加请求；原生扩展监听请求文件并在独立线程按提供者配置调用翻译接口。
- 翻译成功后立即原子写入缓存并刷新候选；英文单词再调用有道词典接口提取 `usphone`、`ukphone` 或 `phonetic`，补写第四列并再次刷新。
- 音标查询仅限长度不超过 64 字符的英文译文，不阻塞 Rime 输入线程；只为当前选中候选查询，翻译队列最多 32 条，缓存最多 400 条，响应体最多 128 KiB。
- Lua 过滤器负责音标格式化和候选展示，接口失败或空结果不写入占位内容。
- 朗读和输入翻译均由 Rime Lua 处理器触发，原生扩展通过本地请求文件调用系统 `say`；快捷键仅在候选面板激活时处理。
- 音标开关由 Lua 状态文件持久化；关闭时过滤器不显示音标，也不写入新的音标请求。
- 菜单栏指示器通过 `squirrel.custom.yaml` 的 `status_icon/show` 关闭；左 Shift 由 `input_translation_processor.lua` 直接提交当前编码，右 Shift 保留输入方案切换，`default.custom.yaml` 将左 Shift 设为 `noop` 防止重复处理。
- 提供者配置独立于 Rime schema，读取 `~/Library/Rime/translation.providers.yaml`；原生扩展通过 Rime Config 解析 YAML，按 `provider_order` 尝试启用的 Google、Bing、Sogou、`youdao_web`、`youdao_api`、`deepl_web`、`deepl`、`caiyun_web` 或 `caiyun`。`youdao_web` 使用网页端动态密钥和 AES 解密流程，`youdao_api` 独立使用 `api_endpoint/app_key/app_secret` 及 v3 SHA-256 签名；`deepl_web` 由原生扩展调用独立 Python 辅助进程，通过网页端 ITA Protobuf + SignalR MessagePack 建立常驻匿名会话，后续请求复用同一 WebSocket，断线后自动重连，不读取或保存 Cookie、Token；`caiyun_web` 动态读取网页公开授权标识、申请短期 JWT 并只在内存缓存，`caiyun` 使用官方 API 的 Token。当 `caiyun` 启用时，处理器直接跳过 `caiyun_web`，不做网页版到 API 的回退；密钥只存在运行时配置，不写入源码或日志。
- 翻译缓存兼容三列、四列旧格式，并新增第五列 provider 作为内部调试元数据；Lua 过滤器不在候选面板显示提供者图标。
- `translation.providers.yaml` 增加 `providers/mac_dictionary/enabled`。在 macOS 且开关启用时，Lua 为所有可见候选写入本地查询请求，原生扩展先通过 DictionaryServices 查询本机已启用词典，并将结果以 `mac_dictionary` 写入缓存；本地无结果的非选中候选直接结束，不进入网络队列。当前选中候选的本地查询请求带有在线补充标记，本地无结果时才按 `provider_order` 调用在线提供者。
- 本地词典关闭时，Lua 恢复单候选策略，仅第一个候选自动发起请求和显示翻译；请求文件第四列 `allow_online_fallback` 用于区分“选中项可联网补充”和“非选中项仅本地查询”。
- 本地查询与在线补充使用独立的 Lua 去重状态；若候选先进入本地查询队列，之后被选中时，原生扩展会升级排队请求，或在正在执行的本地查询返回空结果后自动重排一次在线请求。
- 本地译文保存后立即触发候选刷新，不在同一个翻译 worker 中同步查询音标；Lua 下一轮保留第一候选音标，并在移动选择后仅为当前选中候选补发音标请求，其他候选不触发在线音标查询。
- 音标请求使用独立去重表，不与同一候选的译文请求共享节流状态，保证译文到达后能及时补查音标；移动到其他候选时只补查新的当前选中项。
- 请求文件第五列可标记 `phonetic`，避免短语、数字或标点导致 Lua 的英文判断跳过音标请求；原生扩展对该请求使用本地英文词典优先、在线音标补充的顺序。
- macOS 本地词典模式下，英文译文再次通过 DictionaryServices 查询词条并提取 `/.../` 音标；选中候选的译文保存后由原生 worker 异步补查，优先使用本地音标，本地无音标才调用有道音标接口，非选中候选不补查。
- Bing 凭据页单独允许最多 1 MiB 的受控响应缓冲；其他系统命令和翻译响应仍保持默认 128 KiB 上限，避免网页凭据页截断导致解析失败。
- 过滤器读取选中项时依次采用“刷新期间临时选中项、原生扩展记忆的箭头选中项、Context 当前选中项”，避免候选菜单重建时 Context 短暂回到第 1 项并覆盖真实选中项；在迭代候选前直接检查选中项缓存，已有本地译文但缺少音标时立即发起专用音标请求，不依赖 Rime 的惰性候选迭代是否到达该行。已存在缓存的候选译文和音标继续保留显示，仅对当前候选发起新查询。箭头导航由原生扩展保存候选文字和索引，并在整个“RefreshNonConfirmedComposition 重跑 Lua filter、Context::Highlight 恢复原生选中状态、最后写回 selected_index”过程保持临时选中保护；异步缓存刷新期间临时保存当前候选。
- 已展开候选集合在每次 filter 产出候选前写回 Context 属性；候选列表按需迭代时即使没有执行到 filter 末尾，也不会丢失之前已经显示的译文。
- 异步重算可能把上一轮的 ShadowCandidate 再次送入过滤器；更新译文或音标前先移除其末尾旧翻译 TAB 列，再以最新缓存重建同一列，避免新音标落到第二个 TAB 列而无法显示。
- 异步缓存刷新重建 menu 后恢复保存的 selected_index；已展开候选的音标与译文一起保留，仅对当前候选补查缺失音标。
- 最后一行操作提示通过不可见控制标记传递给鼠须管前端，由 `SquirrelPanel` 仅对标记范围应用 50% 的 comment 字号，避免缩小候选词、译文和音标。
- 鼠须管前端源码保存在 `~/projects/SquirrelFrontend`，对应补丁为 `native/patches/squirrel-candidate-hint-font.patch`；扩展项目本身不替换鼠须管应用。
- Lua filter 从当前方案的 `translation/candidate_count` 读取自动翻译数量并钳制到 1–9，默认及当前运行配置均为 1，因此初始仅第一个候选查询翻译并补充音标。`translation/show_hints` 控制底部提示开关，默认开启。候选数量配置只扩大初始自动查询范围，箭头当前选中项仍单独加入已展开集合。
- 翻译、Emoji 和朗读请求文件采用追加写入；扩展启动时将读取偏移初始化到现有文件尾，只消费本次运行后新增的请求，避免重启时重复翻译或重复朗读历史请求。
