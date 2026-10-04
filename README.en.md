# SquirrelTranslate

A translation and quick-lookup panel for Squirrel (Rime) on macOS. It provides candidate translations, IP and phone-region lookup, date/time and unit conversion, and color tools.

Languages: [简体中文](./README.md) · [繁體中文](./README.zh-Hant.md) · [English](./README.en.md) · [한국어](./README.ko.md) · [日本語](./README.ja.md)

Product website: [SquirrelTranslate](https://owllinker.github.io/SquirrelTranslate/)

## Core feature demos

These illustrative animations follow the U panel design and are not live recordings. Phone numbers and local/public IP addresses are masked; the specified-IP example shows the lookup for `8.8.8.8`.

**Candidate translation:** Enter `u` followed by Pinyin to see candidates, translations, and available phonetics.

![Candidate translation demo](./docs/assets/translation.gif)

**IP lookup:** Enter `uip` and a complete IPv4 address to look up its region and network provider.

![IP lookup demo](./docs/assets/ip-lookup.gif)

**Phone region:** Enter a phone number to show local prefix-region and carrier data; the demo number is masked.

![Phone region demo](./docs/assets/phone-region.gif)

## Squirrel candidate panel

These shortcuts work while the Squirrel candidate panel is visible. Normal text input remains controlled by Squirrel and the active Rime schema.

| Shortcut | Action |
| --- | --- |
| `⌃T` | Toggle candidate translation |
| `⌃P` | Speak the selected translation; does nothing if it is not ready |
| `⌃Y` | Commit the selected candidate's translation |
| `⇧^` | Expand or collapse the full definition and phonetics |
| `⇧P` | Toggle phonetic display |
| `⌃G` / `⌃B` | Search the selected candidate with the default / secondary engine |
| `⌃N` | Search the selected candidate in the news extension via the default browser |
| `⌘,` | Toggle shortcut help |

Chinese candidates translate to English and English candidates to Chinese; phonetics appear when available. Emoji names come from local data and are not sent to online translation services. Candidate numbering and paging follow the active Squirrel schema. Google and Bing are the default and secondary search engines. Configure engines with `u<engine>1` for `⌃G` and `u<engine>2` for `⌃B` (for example, `ubing1`, `ugoogle2`, `ubaidu2`). Supported engines: Google, Bing, Baidu, DuckDuckGo, Yahoo, Brave, Sogou, and Yandex. Settings are saved locally.

## `u` lookup panel

With the Squirrel Simplified Chinese input source active and focus outside an editable field, type lowercase `u` to open the panel, then enter Pinyin or a tool command. Keys pass through unchanged inside editable fields. The input line shows the complete prefix (`uni hao`, `uconv5`); the prefix marks the mode and is excluded from Pinyin, searches, and copied content. Results use a Rime session. About 300 ms after typing stops, candidate translation and phonetics are queried. Translation priority is the macOS Dictionary first, followed by enabled online providers in configured order; the first successful result is used.

### Panel controls

| Shortcut | Action |
| --- | --- |
| `↑` / `↓` | Move selection; cross pages at the edge |
| `←` / `→`, `PageUp` / `PageDown` | Change page |
| Active schema paging keys | Recognized `key_binder/bindings` are honored; `-` and `=` are not used for panel paging |
| `⌘C` | Copy result information for the selected row |
| Space | Copy the selected candidate; in color mode, confirm or resume sampling |
| `⌘V` | Append clipboard text to the query |
| `⌘,` or lower-right `ⓘ` | Toggle help; use arrows to page/select within help |
| `Esc` | Close help; in color mode close the magnifier first, then the panel |
| Backspace | Delete the last query character |

Digits and punctuation are query input, not candidate-selection keys. A valid 8-digit date starts date conversion automatically. Tool results show up to 9 rows per page. Candidate labels stay on one line while result text wraps; the panel sizes itself and has a default maximum width of 400 pt. Set it with `umaxwidth<number>` (200–2000 pt); it saves after about one second of inactivity.

### Commands

All commands begin with `u`. Type parameters directly after the keyword, without `:` or `=`. Use Backspace to edit or `⌘V` to paste longer input.

| Example | Function and result |
| --- | --- |
| `unihao` | Show Chinese candidates, translations, and phonetics using the query session's default Rime schema |
| `ucolor`, `uyanse` | Open the system color magnifier and results panel. Arrow keys move the sample point by one physical pixel; Space or click confirms the color and closes the magnifier. Space can resume sampling. No Screen Recording permission is used; macOS controls magnifier zoom. |
| `ucolorRRGGBB`, `ucolor#RRGGBB` | Convert to HEX (with/without `#`), HEX with alpha, RGB(A), HSL(A), HSV(A); also accepts `rgb(255,0,0)` and `rgba(255,0,0,0.5)`. Arrows select a format; `⌘C` copies its value. |
| `utime` | Show the time for the city/time zone configured on this Mac (for example, Beijing time or Tokyo time), UTC, and Unix timestamps, fixed to the instant the query was entered |
| `utime1727683200`, `utime1727683200000` | Convert Unix seconds or milliseconds to date and time |
| `utimeAsia/Tokyo` | Show the current time in a valid time zone |
| `utimeniuyue`, `utimedongjing` | Look up New York or Tokyo time using city pinyin. The panel also shows this Mac's local city/time-zone time, with a named label such as Beijing time. City input accepts pinyin only; valid IANA time-zone IDs are also accepted. Other pinyin aliases include `lundun`, `luoshanji`, `jiujinshan`, `zhijiage`, `bali`, `shouer`, `xinjiapo`, `xianggang`, `taibei`, `xini`, `aokelan`, `beijing`, `shanghai`, and `dibai`. |
| `udate20261002`, `udate2026-10-02` | Show days ago, days remaining, or today, plus start and end dates |
| `udate20261001.20261002` | Show the day difference and start/end dates; separate dates with one `.`, `-`, or space |
| `uconv5`, `uconv5.5` | Show common length, mass, temperature, volume, pressure, and electrical conversions; no source unit is guessed |
| `uconv5mi`, `uconv72f`, `uconv5kg` | Convert within the specified unit category, such as length, mass, volume, or temperature |
| `uconv1000pa`, `uconv1kpa`, `uconv1mpa`, `uconv760mmhg`, `uconv1kgf/cm2` | Pressure results include floor estimate, floor-height setting, and static-pressure settings. Floors are calculated directly from pressure and floor height without subtracting static pressure; this is not a fire-water supply prediction. A suffix `1` after `mp`/`mpa` means class I high-rise; `2` means class II high-rise/multistory; missing or other numeric suffixes mean other buildings (3). Only an explicit numeric suffix adds the category label to the estimate. |
| `uconv3mH2O`, `uconv3floor` | Convert water-column height or floor count to theoretical pressure; default floor height is 3.0 m. This is not a prediction of a building's actual water supply. |
| `uconv220v`, `uconv2a`, `uconv500w`, `uconv10kohm`, `uconv1kwh`, `uconv60hz`, `uconv100uf` | Convert voltage, current, power, resistance, energy, frequency, capacitance, inductance, and charge within each same-dimension category. No circuit formulas are inferred. SI symbols such as `mW`/`MW` and `mWh`/`MWh` remain case-sensitive. |
| `uconv100rmb`, `uconv100usa`, `uconv100jp`, `uconv100uk` | Convert common currencies. Daily reference rates include dates and are not live trading quotes. Network requests send currency codes, not the entered amount. Aliases include `rmb/cn`, `usa/us`, `jp`, and `uk`. |
| `uip` | Show local IP and look up public IP, region, and ISP. Requires network access and sends the public IP to the lookup service. |
| `uip8.8.8.8` | After a short pause, look up approximate region and provider for the IPv4 address; the target IP is sent to the lookup service. |
| `u132...`, `uphone132...` | Identify mainland China phone-number prefixes; a full 11-digit number shows local prefix region and carrier. Prefix data does not identify a person's live location or current carrier. |
| `u+86 171 6772 6019`, `u+86 (21) 6349 3582` | Look up iPhone-copied international mobile/landline formats, including spaces, hyphens, and Chinese/English parentheses. Also supports `u021-20422661`, `u02120422661`, `u（021）20422661`, and `u(021)20422661`. Uses local numbering data only; numbers are not uploaded. Invalid or overlong input is rejected. |
| `umaxwidth600` | Set maximum panel width to 600 pt (range 200–2000; default 400), subject to screen space |
| `ufloorheight3.2` | Floor height setting: `ufloorheight3.2 (3.2: floor height; configurable range 2–12 m; default 3 m)` |
| `ufiredefault1-0.15` | Set category 1's fire static-pressure reference to 0.15 MPa. Categories are 1–3; values must be >0 and ≤2.4 MPa. Category 3's 0.01 MPa is a user reference, not a universal code value. |
| `ulangzh`, `ulangtw`, `ulangen`, `ulangko`, `ulangja` | Switch the U panel to Simplified Chinese, Traditional Chinese, English, Korean or Japanese. Feature labels, result descriptions, help, errors and status messages follow the selected language; enter `ulang` to see options. |

### Compatibility and boundaries

This is an in-process Squirrel plugin, not a general-purpose text-entry replacement. The documented target is macOS 26.6.2, Squirrel 1.1.2 with bundled librime 1.17.0, and the Simplified Chinese input source `im.rime.inputmethod.Squirrel.Hans`. The build target is macOS 13+ and Universal arm64/x86_64, but other macOS versions have not passed end-to-end verification. Candidate lookup uses the default schema in `~/Library/Rime/default.yaml`; no named third-party schema has been independently verified. Do not assume support for other Squirrel/Rime versions, input sources, or schemas.

| Feature | Compatibility conditions |
| --- | --- |
| Open the `u` panel | Requires the specified Simplified Chinese Squirrel input source, lowercase `u` outside editable fields, and Accessibility permission for Squirrel. |
| Pinyin candidates and translations | Uses a separate Rime session and the default schema in `default.yaml`. The active temporary schema is not guaranteed to carry over; no named third-party schema has been verified. |
| Arrow and schema paging keys | Panel arrows and PageUp/PageDown navigate the panel. Custom schema paging keys work only when the query session can read those bindings; non-default schema bindings are not guaranteed. |
| Date/time, unit, color-format, width, and phone/landline tools | Handled by the query bridge after the panel opens; still subject to the Squirrel/macOS/input-source requirements above. Color picking uses the system color picker and needs no Screen Recording permission. |
| IP, exchange rates, online translation, and web search | Depend on network availability and the corresponding service; online translations also require provider configuration. |

Passing a build or unit test does not establish end-to-end compatibility on an unlisted environment.

## Install

### Prebuilt preview v0.1.0-preview.2

[Download the macOS Universal package](https://github.com/OwlLinker/SquirrelTranslate/releases/download/v0.1.0-preview.2/SquirrelTranslate-v0.1.0-preview.2-macos-universal-preview.zip) (arm64 / x86_64, 3.06 MB). It includes the public query bridge, URL helper, installation scripts, documentation, and prebuilt outputs; private translation integration is excluded.

This package is not signed with an Apple Developer ID or notarized. macOS may show security warnings. Installation requires a valid, stable local code-signing identity and may require Accessibility permission for Squirrel. It was built on macOS 26.6.2 (Apple Silicon) and checked with Squirrel 1.1.2. Although the package includes arm64 and x86_64 binaries, other macOS, Squirrel, and Rime schema combinations have not completed end-to-end testing. The public build, unit conversion tests, and public provider parser tests passed.

SHA-256: `3639568e53f809a933b8c48068639ae6470bc7652d71e3fa61b48c260d3cd733`

**Installation flow:** Download and unzip the package, then follow the detailed [Chinese installation guide](./README.md#安装-u-面板): confirm compatibility, prepare your signing identity, and stop the legacy input bar if installed; skip build-tool setup and step 4 (build), then perform step 5 (install) and the permission and verification steps. Run commands from the extracted project folder. The preview package skips building only—it is not a one-click installer.
