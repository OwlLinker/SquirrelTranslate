# 原生查询桥

`src/squirrel_query_bridge.m` 与 `src/query_translation_service.cc` 实现 Squirrel 进程内 `u` 查询面板。桥接层复用已初始化的 Rime 引擎和独立 Rime 会话，自绘不激活的候选面板；翻译服务链接公开的 [`public_translation_providers.cc`](src/public_translation_providers.cc)，不依赖未公开的通用翻译刷新器。

## 公开发布文件

- 面板、快捷键、颜色／IP／手机号工具：`src/squirrel_query_bridge.m`。
- 额外本地工具：`ucolor:#HEX`／`rgb(...)` 格式转换，`utime:` 时间戳／时区转换，`udate:` 日期间隔，`uconv:` 常见单位转换；不请求网络。
- 查询专用异步调度、去重、取消和有界缓存：`src/query_translation_service.cc`、`src/query_translation_service.h`。
- macOS 系统词典、Google、Bing、DeepL 官方 API：`src/public_translation_providers.cc`、`src/public_translation_providers.h`、`src/json_string.h`。
- 新闻扩展 URL 启动辅助程序：`src/squirrel_open_url.m`。
- 号段数据及其许可：`resources/phone-region-phone.dat`、`resources/phone-region-LICENSE.txt`。
- 构建与安装：`CMakeLists.txt`、`scripts/build.sh`、`scripts/install_query_bridge.sh`、`scripts/sign_squirrel.sh`。

安装器只在用户尚无 `~/Library/Rime/translation.providers.yaml` 时安装示例，不会覆盖已有配置或 API Key。公开版只包含系统词典、Google、Bing、DeepL 官方 API；一般 Rime 候选翻译的完整后台刷新器及旧的私有提供者不属于此发行包。

## 兼容范围

- macOS 26.6.2 是当前唯一记录的构建／测试主机；13.0 仅为编译部署最低目标，不代表已支持其他系统版本。构建为 arm64 与 x86_64 Universal。
- 已验证的宿主版本：Squirrel 1.1.2，随附 librime 1.17.0。其他版本未列为支持版本。
- 运行入口限制为输入源 `im.rime.inputmethod.Squirrel.Hans`。繁体输入源、ABC 等其他输入法不会触发查询面板。
- 查询会话读取用户 Rime 默认方案。仓库没有捆绑方案，且尚无具名第三方方案完成独立端到端验收；因此当前不对任何特定第三方方案／版本作兼容承诺。查询会话是独立会话，不保证继承鼠须管当前临时切换到的非默认方案。
- 13.0+ 是编译部署目标，不代表每个 macOS 次版本都完成端到端键盘验收。当前公开翻译服务只验证了干净构建和解析测试，尚未在鼠须管进程中完成该服务的实际键盘验收。正式发布前需记录 macOS、Squirrel、librime、默认方案 ID／版本，并实际验收输入源、候选、翻译、Esc 和授权撤销行为。

完整验证条件及限制见项目根目录 [`README.md`](../README.md)。

## 构建、配置和安装

在项目根目录运行：

```bash
BUILD_PRIVATE_TRANSLATION_INTEGRATION=OFF ./native/scripts/build.sh
```

该命令在公开检出中构建查询桥、四种公开提供者和 URL helper，并使用 librime 1.17.0 头文件。需要 CMake、Xcode Command Line Tools、Homebrew Boost 和已安装的匹配版 Squirrel。

配置文件 `~/Library/Rime/translation.providers.yaml` 支持以下四类提供者。系统词典默认开启并优先；Google、Bing、DeepL 默认关闭。在线服务按 `provider_order` 依次回退。查询桥在 Squirrel 启动时载入配置，修改后需要重启 Squirrel。DeepL API Key 只保存在本机配置，禁止提交。

安装：

```bash
SQUIRREL_SIGN_IDENTITY="你的稳定代码签名身份" \
  ./native/scripts/install_query_bridge.sh
```

脚本要求 Keychain 中已有有效、稳定的代码签名身份；拒绝 ad-hoc 重签。它安装组件、重新签名并重启 Squirrel。之后必须在“系统设置 > 隐私与安全性 > 辅助功能”允许 Squirrel。该全局按键功能需要此权限，不应关闭它来测试。

取色使用 macOS 系统的点选取色器；取色期间方向键按一个物理像素移动采样点，不自行读取屏幕帧，也不申请屏幕录制权限。IP 地理查询会向桥接代码指定的服务发送目标 IP 或请求方公网 IP；手机号归属地查询使用随项目发布的号段数据库，不上传手机号。

卸载查询桥：移除 `~/Library/Rime/input_translation.query_bridge.enabled`，删除 Squirrel 插件目录中的 `libsquirrel-query-bridge.dylib`、`phone-region-phone.dat`、`phone-region-LICENSE.txt`，再重启 Squirrel。`squirrel-open-url` 若不再需要，可删除 `~/Library/Rime/bin/squirrel-open-url`。
