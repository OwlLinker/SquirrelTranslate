# 鼠须管翻译异步刷新扩展

该扩展消费 Rime Lua 写入的 `~/Library/Rime/input_translation.requests.tsv`，在独立
翻译线程按独立配置调用 Google、Bing、Sogou、Youdao 或 DeepL 接口并写入 `input_translation.cache.tsv`；Google/Bing 复用 Hammerspoon 模块的免 Key 请求流程，DeepL 网页版由原生扩展调用同目录的 Python 会话辅助脚本，Emoji 请求使用本机
Python 的 Unicode 名称数据，不请求翻译接口。缓存变化后，扩展在鼠须管主线程对仍在
输入中的 Rime Context 先重算未确认组合，再设置 `_refresh_ui`，让 Nightly 鼠须管重新
读取当前候选并刷新已经打开的面板。

扩展不在 Rime 输入线程请求网络、不轮询文件、不发送键盘事件，也不修改候选排序或上屏内容。

## 构建

依赖：CMake、Homebrew Boost、官方 Nightly Squirrel，以及 `/usr/bin/python3` 的 `websockets` 模块（仅启用 `deepl_web` 时需要）。

```bash
./scripts/build.sh
```

构建脚本会把匹配当前 Squirrel 的 librime 1.17.0 头文件下载到忽略提交的
`build/deps/`，并生成兼容 macOS 13+ 的 arm64/x86_64 Universal dylib。

## 安装

```bash
./scripts/install.sh
```

安装目标是 Squirrel.app 自带的 `Frameworks/rime-plugins`。因为当前 Nightly 使用
ad-hoc 签名，脚本加入 dylib 后会重新执行同类型签名。以后升级 Squirrel 会覆盖
扩展，需要重新运行安装脚本。

## 卸载

```bash
./scripts/uninstall.sh
```
