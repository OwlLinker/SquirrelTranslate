# SquirrelTranslate

A translation and quick-lookup panel for Squirrel (Rime) on macOS. It provides candidate translations, IP and phone-region lookup, date/time and unit conversion, and color tools.

Languages: [简体中文](./README.md) · [繁體中文](./README.zh-Hant.md) · [English](./README.en.md) · [한국어](./README.ko.md) · [日本語](./README.ja.md)

## Highlights

- Translate Rime candidates and show available phonetics.
- Open the `u` panel outside editable fields for translations and quick tools.
- Look up IP geolocation and local phone-number regions; convert dates, times, units, and colors.
- Use Google, Bing, DeepL API, and the macOS Dictionary for translations.

## Panel language

Type one of these commands in the `u` panel. The panel switches immediately, displays a confirmation, and remembers the choice:

| Command | Language |
| --- | --- |
| `ulangzh` | Simplified Chinese |
| `ulangtw` | Traditional Chinese |
| `ulangen` | English |
| `ulangko` | Korean |
| `ulangja` | Japanese |

Type `ulang` to see the available options. This changes interface labels and help text, not candidate translations or returned lookup data.

## Quick examples

| Input | Result |
| --- | --- |
| `uip8.8.8.8` | IP region and network provider |
| `u132...` or `uphone...` | Mainland China phone-number region lookup |
| `udate20261002` | Date difference from today |
| `utime1727683200` | Convert a Unix timestamp |
| `uconv1000pa` | Unit conversion, including pressure |
| `ucolorRRGGBB` | Convert HEX/RGB/HSL/HSV color formats |
| `umaxwidth600` | Set the panel maximum width |

## Install and compatibility

See the detailed [installation instructions](./README.md#安装-u-面板), compatibility matrix, permissions, provider configuration, and troubleshooting in the Chinese README. The project currently documents a specific tested macOS, Squirrel, and Rime configuration; do not assume other combinations are supported.

The current public edition requires Squirrel on macOS and Accessibility permission for the Squirrel app. Color sampling does not require Screen Recording permission. Online features require network access.
