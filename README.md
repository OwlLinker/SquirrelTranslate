# SquirrelTranslate

鼠须管候选词异步翻译扩展。

## 结构

- `lua/`：Rime Lua 处理器、过滤器和翻译状态。
- `native/`：鼠须管 librime 原生扩展，负责后台请求、缓存和 `_refresh_ui`。
- `legacy/hammerspoon/`：旧版 Hammerspoon 翻译桥接，仅作迁移参考，不再加载。

翻译请求由 Lua 写入 `~/Library/Rime/`，原生扩展优先调用 macOS 本地词典，查不到时再调用配置中的网络翻译服务，成功后写入缓存并刷新当前候选面板。英文单词的译文先显示，随后通过有道词典补充音标并再次刷新。项目源码位于可见目录 `/Users/pancake/projects/SquirrelTranslate`。Emoji 英文名称使用本机 Unicode 数据，不请求翻译接口。

## 翻译提供者

提供者配置独立存放在 `~/Library/Rime/translation.providers.yaml`。可复制 `./rime/translation.providers.yaml.example` 后填写参数；只有 `enabled: true` 且认证参数完整的提供者才会参与请求，按 `provider_order` 顺序失败回退。支持 `google`、`bing`、`sogou`、`youdao_web`、`youdao_api`、`deepl_web`、`deepl`、`caiyun_web` 和 `caiyun`。缓存命中时不会访问网络，配置文件在每次新请求时读取，修改后无需重新编译。

Google 和 Bing 复用 Hammerspoon 翻译模块的免 Key 请求流程，默认地址分别为 `https://translate.google.com/translate_a/single` 和 `https://cn.bing.com/translator`；Bing 会自动获取并短暂缓存网页临时凭据。`youdao_web` 使用 Hammerspoon 网页翻译流程；`youdao_api` 使用 `api_endpoint`、`app_key`、`app_secret` 调用开放平台接口。`deepl_web` 使用 DeepL 当前网页端的 ITA Protobuf + SignalR MessagePack 会话流程，不需要 API Key、Cookie 或手工 Token；每次请求只在内存中建立短期会话，可能触发网页端限流或受协议变更影响；`deepl` 使用 `api_key` 调用官方 API。`caiyun_web` 会自动读取网页当前版本的公开授权标识、申请短期 JWT 并在内存中缓存，不需要手动配置 Token；`caiyun` 使用彩云官方翻译 API 的 `token`。当 `caiyun` 启用时，程序会跳过 `caiyun_web`，不会发生网页版到 API 的回退。真实配置文件已被忽略，不应提交到仓库。

候选面板只显示译文和音标，不在译文前添加提供者图标。

## 安装

先将 `lua/` 下的三个文件复制到 `~/Library/Rime/lua/`，确认 Rime 配置已挂载：

```yaml
patch:
  "engine/processors/@before 1": lua_processor@*input_translation_processor
  "engine/processors/@before 2": translation_refresh_processor
  "engine/filters/@next": lua_filter@*input_translation_filter
```

然后构建并安装原生扩展：

```bash
cd native
./scripts/build.sh
./scripts/install.sh
```

安装后重新部署或重启鼠须管。翻译开关默认是 `Control+t`；候选面板激活且已有译文时，`Control+p` 朗读译文，`Control+y` 输入当前候选词的翻译结果；`Control+Shift+p` 切换音标查询和显示。快捷键说明以 `⌃P 朗读 · ⌃Y 上屏 · ⌃⇧P 音标✓/×` 附加在当前候选页最后一项的 comment 中，并用多个 TAB 推向右侧，不新增候选项且继承当前主题的 comment 颜色。可在 Rime 配置的 `translation/toggle_key`、`translation/speak_key`、`translation/commit_translation_key` 和 `translation/phonetic_toggle_key` 修改。

可在当前方案的 custom 配置（例如 `rime_ice.custom.yaml`）中设置 `translation/candidate_count`（默认 `1`，自动限制在 `1`–`9`）控制自动查询的候选数量；当前运行配置为 `1`，因此初始仅第一个候选显示翻译和音标。当前箭头选中的候选仍会单独触发查询。`translation/show_hints`（默认 `true`）控制是否显示候选面板底部的使用说明。

鼠须管菜单栏图标在 `squirrel.custom.yaml` 中配置；当前关闭菜单栏图标。候选面板有未确认编码时，左 Shift 由 Lua 直接上屏原始编码，右 Shift 保留输入方案切换；可在 `translation/raw_commit_key` 修改上屏按键。

## 性能约束

网络请求不运行在 Rime 输入线程；翻译队列最多 32 条，缓存最多 400 条，单次响应最多读取 128 KiB，缓存和 UI 刷新事件均会合并。
