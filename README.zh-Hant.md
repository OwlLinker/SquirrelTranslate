# SquirrelTranslate

macOS 上 Squirrel（Rime）的候選翻譯與快速查詢面板，提供候選翻譯、IP 與電話號碼歸屬地查詢、日期／時間／單位轉換及取色工具。

語言版本：[简体中文](./README.md) · [繁體中文](./README.zh-Hant.md) · [English](./README.en.md) · [한국어](./README.ko.md) · [日本語](./README.ja.md)

## 主要功能

- 翻譯 Rime 候選詞，並顯示可用音標。
- 在可編輯欄位之外開啟 `u` 面板，使用翻譯與快速工具。
- 查詢 IP 地區與中國電話號碼歸屬地，轉換日期、時間、單位及顏色格式。
- 使用 macOS 詞典、Google、Bing 與 DeepL API 翻譯。

## 設定面板語言

在 `u` 面板輸入下列指令即可立即切換介面語言、顯示確認提示並保存設定：

| 指令 | 語言 |
| --- | --- |
| `ulangzh` | 簡體中文 |
| `ulangtw` | 繁體中文 |
| `ulangen` | 英文 |
| `ulangko` | 韓文 |
| `ulangja` | 日文 |

輸入 `ulang` 查看選項。此設定只切換介面與說明，不會改寫候選翻譯或查詢資料。

## 使用範例

| 輸入 | 結果 |
| --- | --- |
| `uip8.8.8.8` | IP 地區與網路服務商 |
| `u132...` 或 `uphone...` | 中國大陸電話號碼歸屬地 |
| `udate20261002` | 相對於今天的日期計算 |
| `utime1727683200` | Unix 時間戳轉換 |
| `uconv1000pa` | 壓力等單位轉換 |
| `ucolorRRGGBB` | HEX/RGB/HSL/HSV 色彩格式轉換 |
| `umaxwidth600` | 設定面板最大寬度 |

## 安裝與相容性

詳細[安裝步驟](./README.md#安装-u-面板)、相容性表、權限、翻譯服務設定與疑難排解請參閱簡體中文 README。僅將文件明確列出的 macOS、Squirrel 與 Rime 組合視為已驗證環境。

需要 macOS 與 Squirrel，並須為 Squirrel app 授予輔助使用權限。取色不需要螢幕錄製權限；線上功能需要網路連線。
