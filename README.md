# SquirrelTranslate 公共翻译提供者

面向 macOS 的翻译提供者实现，包含：系统本地词典、Google 翻译、Bing 翻译和 DeepL 官方 API。项目许可为 GPL-3.0-only，详见 [LICENSE](./LICENSE)。

## 内容

- `native/src/public_translation_providers.cc`：四种提供者的实现。
- `native/src/public_translation_providers.h`：C++ 调用接口。
- `native/tests/public_provider_test.cc`：JSON 字符串解析回归测试。
- `rime/translation.providers.public.yaml.example`：供集成程序参考的配置示例。

本仓库公开的提供者库不包含 Rime 处理器、候选面板或请求调度器；它不是可直接安装到 Squirrel 的完整输入法插件。宿主集成需调用头文件中的 `Fetch`，并负责配置解析、请求调度与结果展示。

## 提供者行为

- `mac_dictionary`：通过 macOS Dictionary Services 按系统活动词典顺序查询；无需网络。
- `google`：使用 Google 翻译网页公开接口；无需 API Key，服务端接口可能变化或限流。
- `bing`：使用 Bing 翻译网页接口；无需 API Key，临时网页凭据会在进程内短暂缓存，接口可能变化或限流。
- `deepl`：调用 DeepL 官方翻译 API，需要 API Key。

Google 和 Bing 的免 Key 接口并非稳定的公开 API。使用前请遵守各服务的条款与访问限制。

## 构建与测试

需要 macOS、CMake 和 Xcode Command Line Tools。只构建公共提供者库及测试，不下载 librime，也不需要安装 Squirrel：

```bash
BUILD_PUBLIC_PROVIDERS_ONLY=1 ./native/scripts/build.sh
ctest --test-dir native/build/out --output-on-failure
```

构建产物为 `native/build/out/librime-public-translation-providers.dylib`（arm64 与 x86_64 Universal）。它供其他集成层链接，不是可独立加载的 Rime 插件。

## 配置参考

复制 `./rime/translation.providers.public.yaml.example` 到 `~/Library/Rime/translation.providers.yaml`，再按需启用服务。配置示例按 `provider_order` 列出本地词典、Google、Bing、DeepL；DeepL API Key 只保存在本机配置中，**不要提交密钥或钥匙串导出文件**。

该 YAML 是供宿主集成采用的示例；公共提供者库本身不读取 YAML。每个提供者由调用方通过 `ProviderConfig` 传入 endpoint 和 API Key。`Request.target` 指目标语言，例如 `en` 或 `zh-CN`；请求可选携带代次令牌，以便调用方取消过期查询。

## 许可与第三方归属

本项目按 GPL-3.0-only 发布，完整条款见 [LICENSE](./LICENSE)。
