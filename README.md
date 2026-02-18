# Wi-Fi List Plugin for KOReader

This plugin adds a dedicated **Wi-Fi list** entry to KOReader's **Network** menu while keeping the existing menu style unchanged.

## What It Does

- Adds a menu item: `Wi-Fi list`.
- Shows the connected SSID in the menu label when available:
  - `Wi-Fi list: <SSID>`
- Reuses KOReader's native Wi-Fi list UI (`networksetting`) for connect/edit/forget actions.
- Scans nearby networks on demand when the user opens the Wi-Fi list.

## Installation

Place this folder in KOReader's plugins directory:

- `plugins/wifilist.koplugin/`

## Notes

- Works normally on Kindle Paperwhite 11th gen (PW5). 