# SquirrelTranslate

面向 macOS 上鼠须管（Squirrel）的候选翻译与跨应用 `u` 查询面板。公开版包含进程内查询面板，以及四种翻译提供者：macOS 系统词典、Google、Bing、DeepL 官方 API。

## 鼠须管普通候选面板

在鼠须管候选面板出现时，可使用以下操作；普通文本输入仍由鼠须管和当前 Rime 方案处理：

| 快捷键 | 功能 |
| --- | --- |
| `⌃T` | 开启／关闭候选翻译 |
| `⌃P` | 朗读当前候选的译文；译文尚不可用时不朗读源词 |
| `⌃Y` | 将当前候选的译文上屏 |
| `⇧^` | 展开／收起当前候选的完整释义和对应音标 |
| `⌃⇧P` | 开启／关闭音标显示 |
| `⌃G` / `⌃B` | 用当前默认／第二搜索引擎搜索高亮候选 |
| `⌃N` | 在系统默认浏览器中打开新闻扩展并搜索高亮候选 |
| `⌘,` | 打开／关闭快捷键帮助 |

中文候选默认翻译为英文，英文候选翻译为中文；英文结果有音标时一并显示。Emoji 名称使用本机数据，不发送给在线翻译服务。候选编号和翻页按键由鼠须管当前输入方案决定。默认搜索引擎为 Google，第二搜索引擎为 Bing。搜索 URL 可通过 Rime 方案配置；也可在 U 面板输入 `u<引擎>1` 设置 `⌃G`，输入 `u<引擎>2` 设置 `⌃B`，例如 `ubing1`、`ugoogle2`、`ubaidu2`。支持 Google、Bing、百度、DuckDuckGo、Yahoo、Brave、搜狗和 Yandex；更改会保存在用户配置中。

## `u` 查询面板

在鼠须管简体输入源下、焦点不在可编辑输入框时，输入小写 `u` 打开查询面板，再输入拼音或工具命令。编辑框内会放行按键，不改变正常输入。输入行会显示完整的 `u` 前缀，如 `uni hao`、`uconv5`；前缀仅是模式标识，不加入拼音、搜索或复制内容。面板使用 Rime 候选；停止输入约 300ms 后异步查询候选翻译和音标。翻译顺序为 macOS 系统词典优先，然后按配置顺序尝试启用的在线提供者，取第一个成功结果。

### 面板通用操作

| 快捷键 | 功能 |
| --- | --- |
| `↑` / `↓` | 移动选择；到页边缘时自动跨页 |
| `←` / `→`、`PageUp` / `PageDown` | 翻页 |
| 当前方案的翻页键 | 沿用可识别的 `key_binder/bindings`；`-` 和 `=` 不用作 U 面板翻页 |
| `⌘C` | 复制当前高亮项的结果信息 |
| 空格 | 复制当前候选词；取色模式中用于选色／重新取色 |
| `⌘V` | 将剪贴板文本追加到查询输入 |
| `⌘,` 或右下角 `ⓘ` | 打开／关闭帮助；帮助中左右翻页、上下选择 |
| `Esc` | 关闭帮助；取色时先关闭放大镜，放大镜关闭后再关闭面板 |
| 退格 | 删除最后一个输入字符 |

U 面板中数字和标点直接作为查询内容输入，不会选择候选；有效的 8 位日期可直接进入日期查询。工具结果每页最多 9 条。候选词保持完整单行，译文／结果栏可换行；面板自动调整宽高，默认最大宽度 400 pt。输入 `umaxwidth数字` 可设置最大宽度（200–2000 pt），约停顿 1 秒后保存。

### 查询命令

所有命令均以 `u` 开头，命令名后直接接参数，不使用冒号或等号。可用退格修正，长内容也可用 `⌘V` 粘贴。

| 输入示例 | 功能与结果 |
| --- | --- |
| `unihao` | 按当前查询会话的默认 Rime 方案显示中文候选及翻译、音标 |
| `ucolor`、`uyanse` | 打开系统取色放大镜和结果面板；方向键逐物理像素移动取样点，按空格或点击确认颜色并关闭放大镜，再按空格重新取色。该操作不使用屏幕录制权限；系统放大镜倍率由 macOS 控制。 |
| `ucolorRRGGBB`、`ucolor#RRGGBB` | 将颜色转换为 HEX、无 `#` HEX、带透明度 HEX、RGB(A)、HSL(A)、HSV(A) 等格式；支持 `rgb(255,0,0)`、`rgba(255,0,0,0.5)`。方向键选择格式，`⌘C` 复制对应颜色值。 |
| `utime` | 显示输入时刻的本地时间、UTC 和 Unix 时间戳；结果固定为本次输入时的快照。 |
| `utime1727683200`、`utime1727683200000` | 将 Unix 秒或毫秒时间戳转换为日期时间。 |
| `utimeAsia/Tokyo` | 显示该时区当前时间；也支持有效时区名。 |
| `udate20261002`、`udate2026-10-02` | 显示过去天数／剩余天数／今天，并列出开始日期和结束日期。 |
| `udate20261001.20261002` | 显示两个日期相差天数及开始、结束日期；日期间可用一个点、连字符或空格。 |
| `uconv5`、`uconv5.5` | 显示常用长度、质量、温度、体积、压力和电气量换算快捷列表；没有指定单位时不会猜测输入单位。 |
| `uconv5mi`、`uconv72f`、`uconv5kg` | 按指定单位显示所属类别换算。支持长度、质量、体积、温度；例如 `mi` 英里、`f` 华氏度、`kg` 千克。 |
| `uconv1000pa`、`uconv1kpa`、`uconv1mpa`、`uconv760mmhg`、`uconv1kgf/cm2` | 压力换算，列出 Pa、kPa、MPa、毫米汞柱和公斤力／平方厘米。裸 `kg` 是质量单位，不是压力单位。 |
| `uconv220v`、`uconv2a`、`uconv500w`、`uconv10kohm`、`uconv1kwh`、`uconv60hz`、`uconv100uf` | 电压、电流、功率、电阻、电能、频率、电容、电感、电荷的同量纲换算；不根据电路公式推算其他量。单位别名通常不区分大小写；`mW`/`MW`、`mWh`/`MWh` 等 SI 符号按大小写区分。 |
| `uconv100rmb`、`uconv100usa`、`uconv100jp`、`uconv100uk` | 以人民币、美元、日元、英镑等常见币种换算。显示带日期的每日参考汇率，不是实时交易报价；网络请求只发送币种代码，不发送输入金额。支持 `rmb/cn`、`usa/us`、`jp`、`uk` 等别名。 |
| `uip` | 显示本机局域网地址，并查询公网 IP、地区和 ISP；需要网络，会向 IP 查询服务发送本机公网 IP。 |
| `uip8.8.8.8` | 输入完整 IPv4 后停顿片刻，查询其大致地区和网络服务商；目标 IP 会发送给查询服务。 |
| `u132...`、`uphone132...` | 输入手机号前三位后自动识别号段；完整 11 位大陆手机号显示本地号段归属地和运营商。号段不能表示号码持有人的实时位置或当前运营商。 |
| `u+86 171 6772 6019`、`u+86 (21) 6349 3582` | 查询从 iPhone 电话中复制的国际格式手机号／座机号；支持空格、连字符及中英文括号。也支持 `u021-20422661`、`u02120422661`、`u（021）20422661`、`u(021)20422661`。查询仅使用本地号段／区号数据，不上传号码；格式错误或超长会提示“号码格式不正确”。 |
| `umaxwidth600` | 将面板最大宽度设为 600 pt。范围 200–2000 pt，默认 400 pt；实际宽度仍受显示器可用空间限制。 |
| `ugoogle1`、`ubing1`、`ubaidu2` | 设置 `⌃G` 使用的默认搜索引擎或 `⌃B` 使用的第二搜索引擎；支持 Google、Bing、百度、DuckDuckGo、Yahoo、Brave、搜狗、Yandex。设置保存在用户配置中。 |

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

### 各功能的适配条件

下表区分“能够调用功能”和“已验证兼容”：未注明已验证的方案组合，不应视为已支持。

| 功能 | 适配条件与边界 |
| --- | --- |
| 唤起 U 面板 | 必须使用上表指定的鼠须管简体输入源，并在非可编辑区域输入小写 `u`；需要为 Squirrel 授予辅助功能权限。编辑框内会放行按键，不会强行弹出面板。 |
| 普通拼音候选、候选翻译 | 使用独立 Rime 查询会话和用户 `default.yaml` 指定的默认方案；当前临时切换到其他方案时，不保证候选、拼音编码或 Lua 翻译过滤与活动方案一致。当前没有对具名第三方方案完成端到端验证。 |
| 方向键、方案翻页键 | 面板自带的方向键及 PageUp／PageDown 用于面板导航；方案自定义翻页键只有在查询会话能读取到对应方案绑定时才适用，非默认方案的绑定不作保证。 |
| 日期、时间、单位、颜色格式、面板宽度、手机号／座机号段 | 面板成功唤起后由查询桥处理，不依赖特定 Rime 词库或 Lua 翻译器；但仍受鼠须管版本、macOS 版本及输入源前提限制。取色依赖系统颜色选择器；不用屏幕录制权限。 |
| IP 查询、汇率换算、在线翻译、网页搜索 | 需要网络的项目受网络可用性及对应服务影响；在线翻译还需在 `translation.providers.yaml` 启用并配置提供者。搜索需系统可打开相应网页的浏览器。 |

因此，切换到其他 Rime 方案不一定影响所有工具，但不能据此推断普通拼音候选、翻译或方案快捷键也兼容。要声明某方案受支持，需记录方案名称／版本，并实测面板唤起、候选、翻译、工具输入及翻页。

**不要把“可编译”当作“兼容”。** 未列为已验证的系统、鼠须管／librime 版本或输入方案，请先在测试账户或可恢复的系统上验证，不要直接安装到日常输入环境。安装会重新签名并重启 Squirrel；macOS 辅助功能授权可能需要重新确认。

当前公开版已验证干净构建和解析单元测试；这不等于新公开翻译服务已在鼠须管进程内完成键盘端到端验收。发布前请用上表精确版本及明确记录的默认方案完成实际安装测试；未记录的组合均视为未验证。

## 安装 `u` 面板

按下面顺序安装公开版进程内面板。安装会重新签名并重启鼠须管；先保存其他应用中的工作。不要用项目中其他安装脚本替代这里的 `install_query_bridge.sh`。

### 1. 确认环境符合支持条件

- 已安装与本项目验证版本相符的鼠须管，默认路径为 `/Library/Input Methods/Squirrel.app`。只有在应用装于其他位置时才需要设置 `SQUIRREL_APP`。
- 构建目标为 macOS 13.0 及以上、arm64／x86_64 Universal；当前记录的端到端验证环境仅限前文兼容性表所列组合。部署目标不等于所有系统版本均已验证。
- 已安装 Xcode Command Line Tools、CMake、Homebrew Boost。构建脚本会在首次构建时下载并固定使用 librime 1.17.0 源码。
- 仓库已检出到本机，以下命令均从项目根目录运行。

可先检查构建工具是否就绪：

```bash
xcode-select -p
brew --version
cmake --version
brew list --versions boost
```

缺少 Xcode Command Line Tools 时运行 `xcode-select --install`；缺少 CMake 或 Boost 时运行 `brew install cmake boost`。

### 2. 准备稳定的本地代码签名身份

Squirrel 必须用稳定身份签名，才能避免每次重装都因签名变化而破坏辅助功能授权。本项目不会替你创建证书，也不会使用临时 ad-hoc 签名。若钥匙串中还没有本地签名身份，可按以下步骤创建自签名代码签名证书：

1. 按 `⌘Space`，搜索并打开 **钥匙串访问（Keychain Access）**。确认该应用处于前台。
2. 从屏幕顶部菜单栏选择 **钥匙串访问 → 证书助理（Certificate Assistant）→ 创建证书（Create a Certificate）…**。此命令在应用菜单栏中，不在钥匙串主窗口侧栏或工具栏中。
3. 名称填写 `SquirrelTranslate Local Code Signing`；身份类型选择 **自签名根证书（Self Signed Root）**，证书类型选择 **代码签名（Code Signing）**，然后继续创建并完成向导。其他字段保持默认即可。
4. 在钥匙串访问中找到刚创建的证书，确认它位于“登录”钥匙串且关联有同名私钥。双击证书并展开“信任”；如果验证仍显示不受信任，在“使用此证书时”选择“始终信任”，关闭窗口并在本机确认更改。只对自己刚创建的这个登录钥匙串证书做此设置。
5. 在终端验证身份：

```bash
security find-identity -v -p codesigning
```

继续前，确认目标身份列在 `Valid identities` 下。只有 `Matching identities`、带 `CSSMERR_TP_NOT_TRUSTED`，或显示 `0 valid identities found` 都不够；这种情况下回到钥匙串访问检查证书信任设置、登录钥匙串是否已解锁及证书是否关联私钥。安装时使用证书的完整名称；系统若询问是否允许 `codesign` 使用登录钥匙串中的密钥，请在本机完成验证并选择允许。不要把钥匙串密码或私钥发给任何人。

此自签名身份仅供本机稳定签署和保留辅助功能授权使用；它不是 Apple Developer ID 证书，不会为应用提供 Apple 公证，也不适用于公开分发。详见 [Apple：创建自签名证书](https://support.apple.com/guide/keychain-access/kyca8916/mac) 和 [Apple：更改证书信任设置](https://support.apple.com/guide/keychain-access/kyca11871/mac)。

### 3. 停止旧的独立输入栏（如果曾安装）

进程内面板与旧独立输入栏不要同时运行：

```bash
./native/scripts/input_bar.sh stop
```

没有安装过独立输入栏时，这一步可以跳过。

### 4. 构建公开面板

```bash
./native/scripts/build.sh
```

脚本构建进程内查询桥、公开翻译提供者和新闻 URL 辅助程序，产物位于 `native/build/out/`。如果鼠须管不在默认位置，构建时也指定其完整路径：

```bash
SQUIRREL_APP="/完整路径/Squirrel.app" ./native/scripts/build.sh
```

### 5. 安装、签名并重启鼠须管

将下方名称替换为第 2 步显示的有效身份名称：

```bash
SQUIRREL_SIGN_IDENTITY="SquirrelTranslate Local Code Signing" \
  ./native/scripts/install_query_bridge.sh
```

如果鼠须管使用非默认路径，安装时传入相同路径：

```bash
SQUIRREL_APP="/完整路径/Squirrel.app" \
SQUIRREL_SIGN_IDENTITY="SquirrelTranslate Local Code Signing" \
  ./native/scripts/install_query_bridge.sh
```

安装器会先检查应用、构建产物、数据文件和签名身份；然后安装查询桥、手机号／座机归属地数据及浏览器 URL 辅助程序，启用查询桥标记；仅当 `~/Library/Rime/translation.providers.yaml` 尚不存在时才复制默认配置，不覆盖已有设置。写入鼠须管应用目录时，终端可能请求管理员密码；签名时 macOS 也可能要求解锁登录钥匙串。之后为 Squirrel 重新签名并自动重启，等待旧进程退出并确认新进程启动。安装完成会报告 `Installed and enabled the in-process query bridge.`。若退出超时，脚本会报错停止，不会假称安装成功。默认会自动重启；仅在你明确要手动重启时才设置 `RESTART_SQUIRREL=0`。

### 6. 授予辅助功能权限

首次安装或 macOS 要求时，打开“系统设置 → 隐私与安全性 → 辅助功能”，允许 **Squirrel**。权限属于鼠须管，而不是终端、Finder 或单独的翻译应用。保持该授权开启；撤销后全局按键监听会停止。不要为取色功能授予“屏幕录制”权限，本项目不需要该权限。

### 7. 选择输入源并验证

1. 从 macOS 输入法菜单切换到 **Squirrel - Simplified**（输入源 ID：`im.rime.inputmethod.Squirrel.Hans`）。
2. 确认使用中文 Rime 默认方案；本查询会话读取 `~/Library/Rime/default.yaml`，不保证继承临时切换的其他方案。
3. 在 Finder 等非可编辑区域输入小写 `u`。面板出现后试用 `unihao` 或 `uconv5`；普通编辑框中输入 `u` 仍按原方式传递，不会强行弹出查询面板。
4. 面板没有出现时，确认 Squirrel 正在运行、辅助功能授权仍开启，并且安装输出包含成功提示。不要反复撤销／重新授予权限；先再次运行第 5 步的安装命令，让脚本检查组件并受控重启 Squirrel。

### 8. 配置翻译服务

编辑 `~/Library/Rime/translation.providers.yaml` 可调整在线提供者开关及顺序、配置 DeepL 官方 API Key。配置在查询桥启动时读取，修改后需重新启动 Squirrel 才生效。具体字段及网络数据流见下一节和 [`native/README.md`](./native/README.md)。

如需安装到非默认位置，`SQUIRREL_APP` 必须同时传给构建和安装脚本。若只想构建、不安装，可运行第 4 步并跳过后续步骤；若安装时报告签名无效，请先修复 Keychain 中的身份，不能通过 ad-hoc 签名绕过检查。

## 翻译服务配置

安装后可编辑 `~/Library/Rime/translation.providers.yaml`。安装程序不会覆盖已有文件；新安装的示例配置会启用 macOS 系统词典、Google、Bing 和 DeepL。优先顺序为：先查 macOS 系统词典，再按 `provider_order` 依次尝试 Google、Bing、DeepL；拿到第一个有效译文即停止，不会合并多个来源。Google、Bing 和配置了密钥的 DeepL 会在前序来源没有结果时自动查询，并把待翻译候选发送给对应服务；每个在线提供者可用 `enabled: false` 关闭。DeepL 需要自行填写官方 API Key（空密钥时会跳过），密钥只保存在本机配置中，严禁提交。旧的本机配置会被保留；如果其中在线提供者是 `false`，需手动改为 `true` 才会启用。

查询桥在 Squirrel 进程启动时读取提供者配置；编辑后重新启动 Squirrel 才会生效。完整公开配置示例见 [`rime/translation.providers.public.yaml.example`](./rime/translation.providers.public.yaml.example)。Google／Bing 网页接口可能限流或变化；IP 地理查询会把目标 IP 或请求方公网 IP 发送到代码中指定的服务，具体行为见面板说明及 [`native/README.md`](./native/README.md)。

## 公开提供者库

`native/src/public_translation_providers.cc` 公开了系统词典、Google、Bing、DeepL API 的实现。只构建提供者库和解析测试、不构建鼠须管查询桥：

```bash
BUILD_PUBLIC_PROVIDERS_ONLY=1 ./native/scripts/build.sh
ctest --test-dir native/build/out --output-on-failure
```

该模式产物是供其他宿主集成的动态库，不是独立可安装的 Rime 插件。公开发布仅包含上述四种提供者。

## 许可

项目代码按 GPL-3.0-only 发布，见 [`LICENSE`](./LICENSE)；第三方数据及组件归属见 [`THIRD-PARTY-NOTICES.md`](./THIRD-PARTY-NOTICES.md)。
