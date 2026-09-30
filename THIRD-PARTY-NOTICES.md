# Third-party notices

本项目包含或构建时使用以下第三方项目。它们的源代码和许可证应以各自仓库中的最新文件为准。

## Squirrel

- 项目：[rime/squirrel](https://github.com/rime/squirrel)
- 许可证：GPL-3.0-or-later
- 本仓库保留 `./SquirrelFrontend/` 中的前端源码及其上游许可证文件。

## librime

- 项目：[rime/librime](https://github.com/rime/librime)
- 用途：鼠须管前端构建依赖
- 获取方式：执行 `./scripts/setup-frontend-deps.sh`

## plum

- 项目：[rime/plum](https://github.com/rime/plum)
- 用途：鼠须管前端构建依赖
- 获取方式：执行 `./scripts/setup-frontend-deps.sh`

## Sparkle

- 项目：[sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle)
- 用途：鼠须管前端构建依赖
- 获取方式：执行 `./scripts/setup-frontend-deps.sh`

构建依赖目录默认被 `.gitignore` 排除，不随本项目源码发布；发布二进制时应同时遵守各依赖项目的许可证和再分发要求。

## 中国大陆手机号归属地数据

- 项目：[EeeMt/phone-number-geo](https://github.com/EeeMt/phone-number-geo)
- 文件：`./native/resources/phone-region-phone.dat`，数据版本 2025-02
- 许可证：MIT，版权声明 © 2020 EeeMt；全文见 `./native/resources/phone-region-LICENSE.txt`。
- 数据上游：[xluohome/phonedata](https://github.com/xluohome/phonedata)。号码段信息可能过时；携号转网后运营商字段可能不准确。
