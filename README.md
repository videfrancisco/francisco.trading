# francisco.trading

Omarchy shell plugin: BUY and SELL buttons in the bar that jump to the active
trading platform and click its calibrated position (TradingView, Profit,
Rocket Trader or any other). Panels show pulsing circles over saved positions.

## Features

- **BUY / SELL buttons** — one click focuses the platform window and clicks the
  calibrated position (stored relative to the window, so it follows the window
  even if it moves or resizes).
- **Platforms** — add the focused window as a platform, switch with
  right-click, enable/disable, rename (short label of up to 4 characters).
- **Flows** — ordered multi-platform steps (e.g. `profit:buy → rocket:sell`)
  with an optional Super+Alt+<key> shortcut.
- **Stand by** — the panel header has a power button next to the close button:
  putting Trading on stand by collapses the bar to a single `Trading OFF`
  text (arrows and platform short label hidden), removes the flow shortcuts
  and blocks BUY/SELL until turned back on.

## Files

- `BarWidget.qml` — bar widget (platform label, BUY/SELL arrows, `Trading OFF` in stand by)
- `Panel.qml` — panel (platforms, calibration, flows, stand by toggle)
- `scripts/trade.sh` — CLI: buy/sell/focus, platform and flow management, stand by
- `scripts/calibrate.sh` — records BUY/SELL positions for a platform

## Install

Copy or clone this folder into `~/.config/omarchy/plugins/francisco.trading`
and reload the shell. Calibration and CLI details are in the script headers.

## Config

State lives in `~/.config/omarchy/trading.json`; flow shortcuts are synced
with Hyprland on shell start via `trade.sh binds-apply`.

## License

MIT
