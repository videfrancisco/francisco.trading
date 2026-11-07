#!/usr/bin/env bash
# Shared helpers for the francisco.trading plugin.
#
# Hyprland 0.56+ quirk: `hyprctl dispatch` only accepts Lua dispatcher
# objects (hl.dsp.*). Cursor moves and window focus go through the Lua API;
# the actual mouse click goes through ydotool (button events are not
# affected by pointer acceleration, so the click lands where the cursor is).

TRADING_CONFIG="${TRADING_CONFIG:-$HOME/.config/omarchy/trading.json}"

trading_notify() {
  # trading_notify <urgency: low|normal|critical> <summary> <body>
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send -a "Trading" -u "$1" "$2" "$3" 2>/dev/null || true
}

trading_die() {
  # trading_die <summary> <body>
  echo "error: $2" >&2
  trading_notify critical "$1" "$2"
  exit 1
}

trading_platform_json() {
  # trading_platform_json <platform-id> -> compact platform object (or "")
  jq -c --arg id "$1" '.platforms[$id] // empty' "$TRADING_CONFIG" 2>/dev/null
}

trading_platform_enabled() {
  # trading_platform_enabled <platform-id> -> returns 0 when enabled.
  # A missing "enabled" field means enabled (older configs stay valid).
  jq -e --arg id "$1" '.platforms[$id] | . != null and .enabled != false' "$TRADING_CONFIG" >/dev/null 2>&1
}

trading_flow_enabled() {
  # trading_flow_enabled <flow-id> -> returns 0 when enabled.
  jq -e --arg id "$1" '(.flows // {})[$id] | . != null and .enabled != false' "$TRADING_CONFIG" >/dev/null 2>&1
}

trading_field() {
  # trading_field <platform-json> <jq-path> <default>
  local json="$1" path="$2" default="${3:-}"
  local v
  v=$(jq -r "$path // empty" <<<"$json" 2>/dev/null) || v=""
  printf '%s' "${v:-$default}"
}

trading_find_window() {
  # trading_find_window <class-substring> -> window address (or "")
  local cls
  cls=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  hyprctl clients -j 2>/dev/null | jq -r --arg cls "$cls" '
    [.[] | select(((.class // "") | ascii_downcase | contains($cls)))]
    | sort_by(.focusHistoryID) | (.[0].address // empty)'
}

trading_focus_window() {
  # trading_focus_window <address>
  hyprctl dispatch "hl.dsp.focus({window = 'address:$1'})" >/dev/null 2>&1
}

trading_window_at() {
  # trading_window_at <address> -> "x y" (or "")
  hyprctl clients -j 2>/dev/null | jq -r --arg a "$1" '
    .[] | select(.address == $a) | "\(.at[0]) \(.at[1])"' | head -n1
}

trading_ensure_window() {
  # trading_ensure_window <class-substring> <launch-command> <timeout-sec>
  # -> address (launches the app and waits when not running)
  local cls="$1" launch="$2" timeout="$3" addr waited=0
  addr=$(trading_find_window "$cls")
  if [[ -z $addr && -n $launch ]]; then
    nohup sh -c "$launch" >/dev/null 2>&1 &
    disown
    while [[ -z $addr && $waited -lt $((timeout * 2)) ]]; do
      sleep 0.5
      waited=$((waited + 1))
      addr=$(trading_find_window "$cls")
    done
  fi
  printf '%s' "$addr"
}

trading_move_cursor() {
  # trading_move_cursor <x> <y> — verifies the cursor actually got there,
  # so a click is never fired at a stale position. Returns non-zero otherwise.
  local x="$1" y="$2" pos cx cy
  hyprctl dispatch "hl.dsp.cursor.move({x = $x, y = $y})" >/dev/null 2>&1
  sleep 0.08
  pos=$(hyprctl cursorpos 2>/dev/null) || return 1
  cx=${pos%, *}
  cy=${pos#*, }
  ((cx >= x - 2 && cx <= x + 2 && cy >= y - 2 && cy <= y + 2))
}

trading_click() {
  # trading_click <times> [interval-seconds]
  local times="${1:-1}" interval="${2:-0.09}" i
  for ((i = 0; i < times; i++)); do
    ydotool click 0xC0 || {
      echo "error: ydotool click failed (is ydotoold running? systemctl --user status ydotool)" >&2
      return 1
    }
    ((i < times - 1)) && sleep "$interval"
  done
  return 0
}
