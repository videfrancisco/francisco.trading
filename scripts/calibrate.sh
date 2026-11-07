#!/usr/bin/env bash
# francisco.trading — calibrate a buy/sell click position.
#
# Usage:
#   calibrate.sh <platform-id|active> <buy|sell>          interactive (terminal)
#   calibrate.sh calibrate <id> <buy|sell> [wait-seconds] headless (panel/IPC)
#
# Interactive gives you a countdown in the terminal; headless focuses the
# platform window, notifies you on screen, waits, then captures. Both store
# the cursor position relative to the window's top-left corner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=trade-lib.sh
source "$SCRIPT_DIR/trade-lib.sh"

usage() {
  echo "usage: calibrate.sh <platform-id|active> <buy|sell>" >&2
  echo "       calibrate.sh calibrate <platform-id> <buy|sell> [wait-seconds]" >&2
  exit 1
}

MODE="interactive"
if [[ ${1:-} == calibrate ]]; then
  MODE="headless"
  shift
fi

id="${1:-}"
action="${2:-}"
case $action in
  buy) action_label="BUY" ;;
  sell) action_label="SELL" ;;
  *) usage ;;
esac

[[ $id == active || -z $id ]] && id=$(jq -r '.activePlatform // empty' "$TRADING_CONFIG" 2>/dev/null)
[[ -n $id ]] || trading_die "Trading" "No active platform. Edit $TRADING_CONFIG"
platform_json=$(trading_platform_json "$id")
[[ -n $platform_json ]] || trading_die "Trading" "Unknown platform: '$id'"

label=$(trading_field "$platform_json" '.label' "$id")
class=$(trading_field "$platform_json" '.windowClass' "")
launch=$(trading_field "$platform_json" '.launch' "")
launch_timeout=$(jq -r '.launchTimeoutSec // 25' "$TRADING_CONFIG" 2>/dev/null)

addr=$(trading_ensure_window "$class" "$launch" "$launch_timeout")
[[ -n $addr ]] || trading_die "Trading — $label" "Window not found (class: '$class') and no launch command."

trading_focus_window "$addr"

if [[ $MODE == headless ]]; then
  wait_seconds="${3:-${TRADING_CALIBRATE_WAIT:-5}}"
  sleep 0.6
  trading_notify low "Calibrate $action_label · $label" \
    "Hover the $action_label button in the window — ${wait_seconds}s"
  echo "calibrating $action_label of '$label' — hover the button for ${wait_seconds}s"
  sleep "$wait_seconds"
else
  wait_seconds="${TRADING_CALIBRATE_WAIT:-5}"
  sleep 0.5
  echo "Calibrating $action_label · $label"
  echo "Hover the $action_label button in the $label window."
  trading_notify low "Calibrate $action_label · $label" "Hover the button — you have ${wait_seconds}s"
  for ((s = wait_seconds; s > 0; s--)); do
    echo "  $s..."
    sleep 1
  done
fi

cursor=$(hyprctl cursorpos 2>/dev/null) || trading_die "Trading" "Could not read the cursor position (hyprctl)."
cx=${cursor%, *}
cy=${cursor#*, }

at=$(trading_window_at "$addr")
[[ -n $at ]] || trading_die "Trading — $label" "Window disappeared during calibration."
ax=${at% *}
ay=${at#* }

rel_x=$((cx - ax))
rel_y=$((cy - ay))

tmp=$(mktemp)
jq --arg id "$id" --arg action "$action" \
  --argjson x "$rel_x" --argjson y "$rel_y" \
  '.platforms[$id].positions[$action] = {x: $x, y: $y}' \
  "$TRADING_CONFIG" >"$tmp" && mv "$tmp" "$TRADING_CONFIG"

# If the platform has no windowClass yet, record the one we just used.
if [[ -z $class ]]; then
  detected=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" '.[] | select(.address == $a) | .class' | head -n1)
  if [[ -n $detected ]]; then
    tmp=$(mktemp)
    jq --arg id "$id" --arg cls "$detected" '.platforms[$id].windowClass = $cls' \
      "$TRADING_CONFIG" >"$tmp" && mv "$tmp" "$TRADING_CONFIG"
    class=$detected
  fi
fi

trading_notify normal "$action_label calibrated · $label" "window offset: ($rel_x, $rel_y)"
echo "OK: $action_label of '$label' calibrated at ($rel_x, $rel_y) relative to the window (class: ${class:-n/a})"
