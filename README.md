# SquirrelTranslate

面向 macOS 上鼠须管（Squirrel）的候选翻译与跨应用 `u` 查询面板。仓库包含可公开构建的进程内查询面板，以及仅供查询面板调用的四种翻译提供者：macOS 系统词典、Google、Bing、DeepL 官方 API。完整的通用 Rime 翻译刷新集成不在公开版中。

## `u` 查询面板

在鼠须管简体输入源下、确认焦点不在可编辑输入框时，输入小写 `u` 打开查询面板，再输入拼音或查询内容。进入编辑框时会放行 `u`，不改变正常输入。面板复用 Rime 候选，并在查询暂停约 300ms 后异步翻译最多 9 条候选；译文优先从系统词典读取，缺失时按配置顺序尝试已启用的在线提供者。英文译文可从系统词典补充音标。

面板还提供：

- `Ctrl+G` / `Ctrl+B`：分别使用默认／第二搜索引擎；`Ctrl+N`：打开新闻扩展。
- `Command+C` 复制当前结果信息；空格复制当前候选；数字 `1`–`9` 选择可见候选。
- `ucolor` / `uyanse`：调用 macOS 系统取色器；取色时可用方向键按一个物理像素微调采样点，点击确认后查看多种颜色格式。
- `ucolor:RRGGBB`、`ucolor:rgb(255,0,0)` 或 `ucolor:rgba(255,0,0,0.5)`：本地转换 HEX／RGB／RGBA，并列出多种格式；HEX 可省略 `#`。方向键选格式，`Command+C` 复制对应颜色值。
- `utime:1727683200`、`utime:Asia/Tokyo`：转换 Unix 秒／毫秒或查看指定时区时间；`udate:2026-01-01..2026-09-30` 计算日期间隔。
- `uconv:5mi`、`uconv:72°F`：本地换算长度、质量、体积或温度，不联网。
- `uip`、完整 IPv4、手机号：显示本机／公网 IP 信息、指定 IP 信息或中国大陆号段归属地。IP 查询会联系外部地理信息服务；手机号仅使用随项目提供的号段数据。
- 右下角帮助图标显示快捷键和操作说明；支持退格和 `Command+V`。

这是 Squirrel 进程内插件，不是完整的文本输入替代器。它依赖辅助功能事件监听和鼠须管 Rime 会话；只在兼容的鼠须管输入源与中文默认方案下声明支持。

## 兼容性与验证边界

| 项目 | 本项目构建目标／验证记录 |
| --- | --- |
| macOS | 唯一记录的构建／测试主机为 macOS 26.6.2；macOS 13.0 是编译部署最低目标，不代表已支持。其他 macOS 版本均未完成端到端验收。 |
| 鼠须管 | 验证对象为 Squirrel 1.1.2；仅此版本列为已验证。其他版本即使能加载，也不在支持承诺内。 |
| librime | 鼠须管随附 librime 1.17.0；头文件按 1.17.0 构建。其他 ABI 版本未验证。 |
| 架构 | 构建为 arm64 + x86_64 Universal；实际键盘验收不等于两个架构都完成验收。 |
| 输入源 | 目标为鼠须管简体输入源 `im.rime.inputmethod.Squirrel.Hans`。繁体输入源、ABC／其他输入法不属于已验证运行条件。 |
| Rime 输入方案 | 查询会话使用 `~/Library/Rime/default.yaml` 的默认方案；仓库未捆绑方案，也没有完成任何具名第三方方案的独立端到端验收。因此目前不对雾凇拼音、双拼、仓颉或其他具体方案作兼容承诺。临时切换的非默认方案不保证被查询会话继承。 |

**不要把“可编译”当作“兼容”。** 未列为已验证的系统、鼠须管／librime 版本或输入方案，请先在测试账户或可恢复的系统上验证，不要直接安装到日常输入环境。安装会重新签名并重启 Squirrel；macOS 辅助功能授权可能需要重新确认。

当前公开版已验证干净构建和解析单元测试；这不等于新公开翻译服务已在鼠须管进程内完成键盘端到端验收。发布前请用上表精确版本及明确记录的默认方案完成实际安装测试；未记录的组合均视为未验证。

## 构建与安装 `u` 面板

需要 macOS 13+、Xcode Command Line Tools、CMake、Homebrew Boost，以及与目标版本匹配的 Squirrel。公开构建显式关闭私有完整翻译集成：

```bash
BUILD_PRIVATE_TRANSLATION_INTEGRATION=OFF ./native/scripts/build.sh
```

该命令会获取 librime 1.17.0 头文件并构建公开查询桥、翻译提供者及 URL 辅助程序。安装需要一个有效且稳定的本地代码签名身份；它不会创建证书，也不会 ad-hoc 重签：

```bash
SQUIRREL_SIGN_IDENTITY="你的代码签名身份名称" ./native/scripts/install_query_bridge.sh
```

安装脚本会停止旧的独立输入栏（如果存在）、安装公开面板及号段数据、只在本机配置不存在时复制公开提供者配置、重新签名并重启 Squirrel。之后在“系统设置 > 隐私与安全性 > 辅助功能”允许 Squirrel。不要关闭 Squirrel 的辅助功能授权来测试；授权撤销会让全局按键监听停止。

## 翻译服务配置

安装后编辑 `~/Library/Rime/translation.providers.yaml`。安装程序不会覆盖已有文件。示例文件为 [`rime/translation.providers.public.yaml.example`](./rime/translation.providers.public.yaml.example)。默认只启用 macOS 系统词典；Google、Bing、DeepL 默认关闭。将需要的提供者设为 `enabled: true`，并调整 `provider_order`；本地词典始终优先。DeepL 官方 API 需要自己填写 API Key，只保存在本机配置中，严禁提交密钥。

查询桥在 Squirrel 进程启动时读取提供者配置；编辑后重新启动 Squirrel 才会生效。Google／Bing 网页接口可能限流或变化；IP 地理查询会把目标 IP 或请求方公网 IP 发送到代码中指定的服务，具体行为见面板说明及 [`native/README.md`](./native/README.md)。

## 公开提供者库

`native/src/public_translation_providers.cc` 公开了系统词典、Google、Bing、DeepL API 的实现。只构建提供者库和解析测试、不构建鼠须管查询桥：

```bash
BUILD_PUBLIC_PROVIDERS_ONLY=1 ./native/scripts/build.sh
ctest --test-dir native/build/out --output-on-failure
```

该模式产物是供其他宿主集成的动态库，不是独立可安装的 Rime 插件。完整翻译刷新集成及其他未列入上述四类的旧提供者仍保持私有，不包含在公开发布中。

## 许可

项目代码按 GPL-3.0-only 发布，见 [`LICENSE`](./LICENSE)；第三方数据及组件归属见 [`THIRD-PARTY-NOTICES.md`](./THIRD-PARTY-NOTICES.md)。
