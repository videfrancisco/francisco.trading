#!/usr/bin/env bash
# francisco.trading — switch to the trading platform and click a calibrated
# buy/sell position. Also runs action flows (ordered multi-platform steps).
#
# Usage:
#   trade.sh buy [platform-id]              click the calibrated buy position
#   trade.sh sell [platform-id]             click the calibrated sell position
#   trade.sh focus [platform-id]            jump to the platform window
#   trade.sh next-platform                  cycle the active platform (enabled only)
#   trade.sh set-active <id>                pick the active platform
#   trade.sh platform-add-active            add a platform from the focused window
#   trade.sh platform-remove <id>           remove a platform
#   trade.sh platform-rename <id> <short> [name]
#                                           rename the short label (max 4 chars) and,
#                                           optionally, the full display name
#   trade.sh platform-enable <id> <true|false>
#                                           enable or disable a platform
#   trade.sh flow <flow-id>                 run a flow's steps in order
#   trade.sh flow-add <steps>               create a flow: "platform:action ..." (buy|sell)
#   trade.sh flow-remove <id>               remove a flow
#   trade.sh flow-rename <id> <name>        rename a flow (up to 40 chars)
#   trade.sh flow-bind <id> <key|off>       shortcut Super+Alt+<key> runs the flow
#                                           (key: 0-9, A-Z or F1-F12; refuses keys
#                                           already used by the system)
#   trade.sh flow-enable <id> <true|false>  enable or disable a flow (its shortcut
#                                           is removed while disabled)
#   trade.sh standby <on|off>               stand by: the bar shows only "Trading OFF",
#                                           flow shortcuts are removed and BUY/SELL
#                                           refuse to run until it is turned back on
#   trade.sh binds-apply                    re-apply flow shortcuts to Hyprland
#   trade.sh points [platform]              JSON with the recorded points in screen coords
#
# Positions are stored relative to the window's top-left corner, so the click
# follows the window even if it is moved or resized. Calibrate with
# calibrate.sh.
#
# "enabled" is optional on platforms and flows; a missing value means enabled.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=trade-lib.sh
source "$SCRIPT_DIR/trade-lib.sh"

usage() {
  echo "usage: trade.sh <buy|sell|focus|next-platform|set-active|platform-add-active|platform-remove|platform-rename|platform-enable|flow|flow-add|flow-remove|flow-rename|flow-bind|flow-enable|standby|binds-apply|points> [arg...]" >&2
  exit 1
}

trade_fail() {
  # trade_fail <summary> <body> — like trading_die but returns instead of exit,
  # so flows can stop without killing the caller.
  trading_notify critical "$1" "$2"
  return 1
}

trading_key_conflict() {
  # trading_key_conflict <key> — prints the description of the existing
  # SUPER+ALT+<key> bind, or nothing if the combo is free.
  #
  # Two sources are checked:
  #   1. `hyprctl binds -j` (runtime truth, including this plugin's dynamic
  #      binds — those are whitelisted via the state file).
  #   2. The lua binding sources, because binds declared with `code:N` and
  #      loop-generated ones (e.g. SUPER+ALT+1..5 = group windows) carry no
  #      usable key name in the runtime JSON.
  local key
  key=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  python3 - "$key" <<'PYEOF'
import glob, json, os, re, subprocess, sys

key = sys.argv[1].upper()
home = os.path.expanduser("~")

# evdev keycodes — what Hyprland's `code:N` refers to
codes = {"1": 10, "2": 11, "3": 12, "4": 13, "5": 14, "6": 15, "7": 16,
         "8": 17, "9": 18, "0": 19,
         "Q": 24, "W": 25, "E": 26, "R": 27, "T": 28, "Y": 29, "U": 30,
         "I": 31, "O": 32, "P": 33, "A": 38, "S": 39, "D": 40, "F": 41,
         "G": 42, "H": 43, "J": 44, "K": 45, "L": 46, "Z": 52, "X": 53,
         "C": 54, "V": 55, "B": 56, "N": 57, "M": 58}
for i in range(1, 11):
    codes["F%d" % i] = 66 + i
codes["F11"] = 95
codes["F12"] = 96
target = codes.get(key)

def conflict(desc):
    print(desc or "system shortcut")
    sys.exit(0)

# keys this plugin already bound dynamically (safe to rebind)
ours = set()
try:
    with open(home + "/.config/omarchy/.trading-binds.state") as f:
        ours = {ln.strip().upper() for ln in f if ln.strip()}
except OSError:
    pass

# 1) runtime binds by keysym name
try:
    out = subprocess.run(["hyprctl", "binds", "-j"], capture_output=True,
                         text=True, timeout=5).stdout
    for b in json.loads(out):
        if (b.get("modmask") != 72 or b.get("submap") or b.get("mouse")
                or b.get("keycode")):
            continue
        if (b.get("key") or "").upper() == key and key not in ours:
            conflict(b.get("description") or "")
except Exception:
    pass

# 2) lua binding sources: static keysym, code:N and dynamic loops
paths = set(glob.glob(home + "/.config/hypr/*.lua"))
paths |= set(glob.glob(home + "/.config/hypr/bindings/*.lua"))
paths |= set(glob.glob("/usr/share/omarchy/default/hypr/bindings/*.lua"))
loop_re = re.compile(r"for\s+(\w+)\s*=\s*(-?\d+)\s*,\s*(-?\d+)")
bind_re = re.compile(r'bind\s*\(\s*"([^"]*)"\s*(?:,\s*"([^"]*)")?')
dyn_re = re.compile(r"tostring\s*\(\s*(\w+)\s*([+\-])\s*(\d+)\s*\)")
for path in sorted(paths):
    try:
        lines = open(path, errors="ignore").read().splitlines()
    except OSError:
        continue
    var = lo = hi = None
    for line in lines:
        m = loop_re.search(line)
        if m:
            var, lo, hi = m.group(1), int(m.group(2)), int(m.group(3))
        if "bind" not in line:
            continue
        for bm in bind_re.finditer(line):
            spec = bm.group(1).replace(" ", "").upper()
            if not spec.startswith("SUPER+ALT+"):
                continue
            tok = spec[10:]
            desc = bm.group(2) or ""
            if tok == key:
                conflict(desc)
            if target is not None and tok == "CODE:%d" % target:
                conflict(desc)
            # loop-generated code binds: expand `for i = a, b` + tostring(i+off)
            if tok.endswith("CODE:") and var is not None:
                dm = dyn_re.search(line, bm.end()) or dyn_re.search(line)
                if dm and dm.group(1) == var:
                    off = int(dm.group(3))
                    if dm.group(2) == "-":
                        off = -off
                    for n in range(lo, hi + 1):
                        if n + off == target:
                            conflict(desc or "system shortcut (window group key)")
PYEOF
}

trading_apply_binds() {
  # Syncs the flow shortcuts Super+Alt+<key> with Hyprland via hl.bind/hl.unbind
  # (hyprctl eval). Idempotent: removes whatever the state file lists, then
  # applies the current trading.json state. Disabled flows get no shortcut.
  local state="$HOME/.config/omarchy/.trading-binds.state"
  local oldkey script_lua bfid bkey
  script_lua="$SCRIPT_DIR/trade.sh"

  if [[ -f $state ]]; then
    while IFS= read -r oldkey; do
      [[ -n $oldkey ]] || continue
      hyprctl eval "hl.unbind(\"SUPER + ALT + $oldkey\")" >/dev/null 2>&1
    done <"$state"
  fi

  : >"$state"
  local count=0
  local skipped=""
  local cdesc

  # Stand by: leave the shortcuts unbound until trading is turned back on.
  if [[ $(jq -r '.standby // false' "$TRADING_CONFIG" 2>/dev/null) == true ]]; then
    echo "binds: standby"
    return 0
  fi

  while IFS=$'\t' read -r bfid bkey rest; do
    [[ -n $bfid && -n $bkey ]] || continue
    grep -qE '^([0-9A-Z]|F([1-9]|1[0-2]))$' <<<"$bkey" || continue
    # A system bind may have appeared after the flow was configured (e.g. an
    # Omarchy update): never override it at startup.
    cdesc=$(trading_key_conflict "$bkey")
    if [[ -n $cdesc ]]; then
      skipped+=" $(jq -r --arg id "$bfid" '(.flows // {})[$id].label // $id' "$TRADING_CONFIG") (Super+Alt+$bkey in use: $cdesc)"
      continue
    fi
    hyprctl eval "hl.bind(\"SUPER + ALT + $bkey\", hl.dsp.exec_cmd(\"$script_lua flow $bfid\"))" >/dev/null 2>&1 &&
      printf '%s\n' "$bkey" >>"$state" && count=$((count + 1))
  done < <(jq -r '(.flows // {}) | to_entries[] | select(.value.key != null and .value.enabled != false) |
    [.key, .value.key, (.value.label // "")] | @tsv' "$TRADING_CONFIG" 2>/dev/null)

  if [[ -n $skipped ]]; then
    trading_notify low "Trading" "Shortcuts not applied — key in use:$skipped"
  fi

  echo "binds: $count active"
}

perform_trade() {
  # perform_trade <platform-id> <buy|sell> — focus the platform and click its
  # calibrated position. Returns non-zero (with a critical notification) on
  # any failure.
  local pid="$1" paction="$2"
  local pjson plabel pclass plaunch paddr
  local ptimeout pdelay pnotify plabel_action pos at ax ay px py tx ty pclicks

  pjson=$(trading_platform_json "$pid")
  [[ -n $pjson ]] || trade_fail "Trading" "Unknown platform: '$pid'" || return 1

  plabel=$(trading_field "$pjson" '.label' "$pid")
  if ! trading_platform_enabled "$pid"; then
    trade_fail "Trading — $plabel" "Platform is disabled. Enable it in the Trading panel first." || return 1
  fi

  if [[ $(jq -r '.standby // false' "$TRADING_CONFIG" 2>/dev/null) == true ]]; then
    trade_fail "Trading — $plabel" "Trading is in stand by (Trading OFF). Turn it back on in the Trading panel." || return 1
  fi

  pclass=$(trading_field "$pjson" '.windowClass' "")
  plaunch=$(trading_field "$pjson" '.launch' "")
  ptimeout=$(jq -r '.launchTimeoutSec // 25' "$TRADING_CONFIG" 2>/dev/null)
  pdelay=$(jq -r '.confirmDelayMs // 150' "$TRADING_CONFIG" 2>/dev/null)
  pnotify=$(jq -r '.notifyOnSuccess // true' "$TRADING_CONFIG" 2>/dev/null)

  paddr=$(trading_ensure_window "$pclass" "$plaunch" "$ptimeout")
  [[ -n $paddr ]] ||
    trade_fail "Trading — $plabel" "Window not found (class: '$pclass') and no launch command." || return 1

  trading_focus_window "$paddr"
  sleep 0.35 # let the workspace switch settle before reading geometry

  plabel_action=$([[ $paction == buy ]] && echo "BUY" || echo "SELL")
  pos=$(jq -c --arg a "$paction" '.positions[$a] // empty' <<<"$pjson")
  if [[ -z $pos || $pos == null ]]; then
    trade_fail "Trading — $plabel" \
      "$plabel_action position not calibrated. Open the Trading panel and calibrate the $plabel_action button for this platform." || return 1
  fi

  at=$(trading_window_at "$paddr")
  [[ -n $at ]] || trade_fail "Trading — $plabel" "Window disappeared before the click." || return 1
  ax=${at% *}
  ay=${at#* }

  px=$(jq -r '.x' <<<"$pos")
  py=$(jq -r '.y' <<<"$pos")
  tx=$((ax + px))
  ty=$((ay + py))

  pclicks=$(trading_field "$pjson" '.clicks // .clickCount' 1)
  pclicks=${pclicks:-1}

  trading_move_cursor "$tx" "$ty" ||
    trade_fail "Trading — $plabel" "Failed to move the cursor to $tx,$ty — click cancelled for safety." || return 1
  sleep "$(jq -n --argjson ms "$pdelay" '$ms / 1000')"
  trading_click "$pclicks" ||
    trade_fail "Trading — $plabel" "Click failed (is ydotoold running?). Check: systemctl --user status ydotool" || return 1

  if [[ $pnotify == true ]]; then
    trading_notify normal "Trading — $plabel_action sent" "$plabel ($pclicks click(s) at $tx,$ty)"
  fi
  echo "$plabel_action: clicked ($tx,$ty) on $plabel"
}

run_flow() {
  # run_flow <flow-id> — execute the flow's steps in order, stopping at the
  # first failure.
  local fid="$1"
  local fjson flabel fcount fdelay i=0 plat act plabel_action
  fjson=$(jq -c --arg id "$fid" '(.flows // {})[$id] // empty' "$TRADING_CONFIG")
  [[ -n $fjson ]] || trading_die "Trading" "Unknown flow: '$fid'"
  flabel=$(trading_field "$fjson" '.label' "$fid")
  if ! trading_flow_enabled "$fid"; then
    trading_die "Trading — $flabel" "Flow is disabled. Enable it in the Trading panel first."
  fi
  if [[ $(jq -r '.standby // false' "$TRADING_CONFIG" 2>/dev/null) == true ]]; then
    trading_die "Trading — $flabel" "Trading is in stand by (Trading OFF). Turn it back on in the Trading panel."
  fi
  fcount=$(jq '.steps | length' <<<"$fjson")
  ((fcount >= 1)) || trading_die "Trading — $flabel" "The flow has no steps."
  fdelay=$(jq -r '.flowStepDelayMs // 600' "$TRADING_CONFIG" 2>/dev/null)

  trading_notify low "Flow: $flabel" "Running $fcount step(s)…"
  echo "flow '$flabel': $fcount step(s)"

  while read -r plat act; do
    [[ -n $plat ]] || continue
    i=$((i + 1))
    if ! perform_trade "$plat" "$act" </dev/null; then
      plabel_action=$([[ $act == buy ]] && echo "BUY" || echo "SELL")
      trading_notify critical "Flow: $flabel — stopped" \
        "Failed at step $i/$fcount ($plabel_action on '$plat'). The remaining steps were not run."
      exit 1
    fi
    ((i < fcount)) && sleep "$(jq -n --argjson ms "$fdelay" '$ms / 1000')"
  done < <(jq -r '.steps[] | "\(.platform) \(.action)"' <<<"$fjson")

  trading_notify normal "Flow: $flabel" "✓ $fcount/$fcount steps done"
  echo "flow '$flabel': done ($fcount/$fcount)"
}

action="${1:-}"
case $action in
  buy | sell | focus | next-platform | set-active | platform-add-active | platform-remove | platform-rename | platform-enable | flow | flow-add | flow-remove | flow-rename | flow-bind | flow-enable | standby | binds-apply | points) ;;
  *) usage ;;
esac

if [[ $action == points ]]; then
  platform="${2:-$(jq -r '.activePlatform // empty' "$TRADING_CONFIG" 2>/dev/null)}"
  [[ -n $platform ]] || trading_die "Trading" "No active platform."
  platform_json=$(trading_platform_json "$platform")
  [[ -n $platform_json ]] || trading_die "Trading" "Unknown platform: '$platform'"
  label=$(trading_field "$platform_json" '.label' "$platform")
  class=$(trading_field "$platform_json" '.windowClass' "")
  addr=$(trading_find_window "$class")
  if [[ -z $addr ]]; then
    jq -cn --arg label "$label" '{open: false, label: $label}'
    exit 0
  fi
  trading_focus_window "$addr"
  sleep 0.35
  monitor=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" '.[] | select(.address == $a) | .monitor')
  monrow=$(hyprctl monitors -j 2>/dev/null | jq -r --arg m "$monitor" '.[] | select((.id | tostring) == $m) | "\(.x) \(.y) \(.name)"' | head -n1)
  monxy=${monrow% *}
  monname=${monrow##* }
  at=$(trading_window_at "$addr")
  [[ -n $at && -n $monxy ]] || trading_die "Trading — $label" "Could not read the window geometry."
  ax=${at% *}
  ay=${at#* }
  mx=${monxy% *}
  my=${monxy#* }
  buy_pos=$(jq -c --arg a buy '.positions[$a] // empty' <<<"$platform_json")
  sell_pos=$(jq -c --arg a sell '.positions[$a] // empty' <<<"$platform_json")
  jq -cn --arg label "$label" --arg screen "$monname" \
    --argjson ax "$ax" --argjson ay "$ay" --argjson mx "$mx" --argjson my "$my" \
    --argjson buy "${buy_pos:-null}" --argjson sell "${sell_pos:-null}" '
    def pt(p):
      if p == null then {calibrated: false}
      else {calibrated: true, screen: $screen, x: ($ax + p.x - $mx), y: ($ay + p.y - $my)} end;
    {open: true, label: $label, buy: pt($buy), sell: pt($sell)}'
  exit 0
fi

if [[ $action == standby ]]; then
  # trade.sh standby <on|off> — puts the plugin on stand by or brings it back.
  # "on" persists .standby = true in trading.json: the bar widget collapses to
  # a single "Trading OFF" text, flows lose their shortcuts and BUY/SELL refuse
  # to run until it is turned back on.
  value="${2:-}"
  [[ -n $value ]] || usage
  case $value in
    on) newv=true ;;
    off) newv=false ;;
    *) trading_die "Trading" "Invalid value '$value' (use on or off)." ;;
  esac
  tmp=$(mktemp)
  jq --argjson v "$newv" '.standby = $v' "$TRADING_CONFIG" >"$tmp" && mv "$tmp" "$TRADING_CONFIG"
  trading_apply_binds
  if [[ $newv == true ]]; then
    trading_notify low "Trading OFF" "Stand by — flow shortcuts removed and BUY/SELL blocked until you turn it back on."
    echo "standby: on"
  else
    trading_notify normal "Trading ON" "Back from stand by — shortcuts re-applied."
    echo "standby: off"
  fi
  exit 0
fi

if [[ $action == set-active ]]; then
  id="${2:-}"
  [[ -n $id ]] || usage
  trading_platform_json "$id" | grep -q . ||
    trading_die "Trading" "Unknown platform: '$id'"
  trading_platform_enabled "$id" ||
    trading_die "Trading" "Platform is disabled: '$id'. Enable it first."
  tmp=$(mktemp)
  jq --arg id "$id" '.activePlatform = $id' "$TRADING_CONFIG" >"$tmp" && mv "$tmp" "$TRADING_CONFIG"
  label=$(jq -r --arg id "$id" '.platforms[$id].label // $id' "$TRADING_CONFIG")
  trading_notify low "Trading" "Active platform: $label"
  echo "active platform: $id"
  exit 0
fi

if [[ $action == next-platform ]]; then
  # Cycles through enabled platforms only, in sorted id order.
  current=$(jq -r '.activePlatform // empty' "$TRADING_CONFIG")
  next=$(jq -r --arg cur "$current" '
    ([.platforms | to_entries[] | select(.value.enabled != false) | .key] | sort) as $keys
    | if ($keys | length) == 0 then empty
      else ($keys | index($cur) // -1) as $i
      | $keys[(($i + 1) % ($keys | length))] end' "$TRADING_CONFIG")
  [[ -n $next ]] || trading_die "Trading" "No enabled platform. Enable one in the Trading panel."
  tmp=$(mktemp)
  jq --arg next "$next" '.activePlatform = $next' "$TRADING_CONFIG" >"$tmp" && mv "$tmp" "$TRADING_CONFIG"
  label=$(jq -r --arg next "$next" '.platforms[$next].label // $next' "$TRADING_CONFIG")
  trading_notify low "Trading" "Active platform: $label"
  echo "active platform: $next"
  exit 0
fi

if [[ $action == platform-add-active ]]; then
  win=$(hyprctl activewindow -j 2>/dev/null) || trading_die "Trading" "Could not read the active window (hyprctl)."
  class=$(jq -r '.class // empty' <<<"$win")
  title=$(jq -r '.title // empty' <<<"$win")
  [[ -n $class ]] || trading_die "Trading" "No active window to capture. Open the platform app first."
  if jq -e --arg cls "$class" '.platforms | to_entries | any(.value.windowClass == $cls)' "$TRADING_CONFIG" >/dev/null; then
    trading_notify low "Trading" "A platform with window class '$class' already exists."
    echo "duplicate: $class"
    exit 0
  fi
  slug=$(printf '%s' "$class" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
  [[ -n $slug ]] || slug="platform"
  id=$slug
  n=2
  while jq -e --arg id "$id" '.platforms | has($id)' "$TRADING_CONFIG" >/dev/null; do
    id="${slug}-${n}"
    n=$((n + 1))
  done
  label=$(printf '%s' "$title" | cut -c1-40)
  [[ -n $label ]] || label="$class"
  short=$(printf '%s' "$label" | tr '[:lower:]' '[:upper:]' | cut -c1-2)
  tmp=$(mktemp)
  jq --arg id "$id" --arg label "$label" --arg short "$short" --arg cls "$class" '
    .platforms[$id] = {
      label: $label,
      shortLabel: $short,
      windowClass: $cls,
      launch: "",
      workspace: 0,
      clicks: 1,
      enabled: true,
      positions: {buy: null, sell: null}
    } | .activePlatform = $id' "$TRADING_CONFIG" >"$tmp" && mv "$tmp" "$TRADING_CONFIG"
  trading_notify normal "Trading" "Platform added and activated: $label ($class)"
  echo "added: $id ($class)"
  exit 0
fi

if [[ $action == platform-remove ]]; then
  id="${2:-}"
  [[ -n $id ]] || usage
  trading_platform_json "$id" | grep -q . ||
    trading_die "Trading" "Unknown platform: '$id'"
  count=$(jq '.platforms | length' "$TRADING_CONFIG")
  ((count > 1)) || trading_die "Trading" "Cannot remove the last platform."
  label=$(jq -r --arg id "$id" '.platforms[$id].label // $id' "$TRADING_CONFIG")
  tmp=$(mktemp)
  # If the active platform goes away, fall back to the first enabled one left.
  jq --arg id "$id" '
    del(.platforms[$id])
    | if .activePlatform == $id
      then .activePlatform = ((.platforms | to_entries | map(select(.value.enabled != false)) | map(.key) | sort | first) // (.platforms | keys | sort | first))
      else . end' \
    "$TRADING_CONFIG" >"$tmp" && mv "$tmp" "$TRADING_CONFIG"
  trading_notify low "Trading" "Platform removed: $label"
  echo "removed: $id"
  exit 0
fi

if [[ $action == platform-rename ]]; then
  # trade.sh platform-rename <id> <short> [name] — short label of 1 to 4
  # characters shows on the bar and panel; the name is the full label (optional).
  id="${2:-}"
  short="${3:-}"
  newlabel="${4:-}"
  [[ -n $id && -n $short ]] || usage
  short=$(printf '%s' "$short" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [[ -z $short ]]; then
    trading_die "Trading" "The short label cannot be empty."
  fi
  if (( ${#short} > 4 )); then
    trading_die "Trading" "The short label must be at most 4 characters (got: ${#short})."
  fi
  trading_platform_json "$id" | grep -q . ||
    trading_die "Trading" "Unknown platform: '$id'"
  oldlabel=$(jq -r --arg id "$id" '.platforms[$id].label // $id' "$TRADING_CONFIG")
  tmp=$(mktemp)
  if [[ -n ${newlabel//[[:space:]]/} ]]; then
    jq --arg id "$id" --arg short "$short" --arg label "$newlabel" '
      .platforms[$id].shortLabel = $short
      | .platforms[$id].label = $label' "$TRADING_CONFIG" >"$tmp" &&
      mv "$tmp" "$TRADING_CONFIG"
    trading_notify low "Trading" "Renamed: $newlabel (short $short)"
    echo "renamed: $id → $newlabel ($short)"
  else
    jq --arg id "$id" --arg short "$short" \
      '.platforms[$id].shortLabel = $short' "$TRADING_CONFIG" >"$tmp" &&
      mv "$tmp" "$TRADING_CONFIG"
    trading_notify low "Trading" "Short label of $oldlabel → $short"
    echo "renamed: $id → short $short"
  fi
  exit 0
fi

if [[ $action == platform-enable ]]; then
  # trade.sh platform-enable <id> <true|false>
  id="${2:-}"
  value="${3:-}"
  [[ -n $id && -n $value ]] || usage
  case $value in
    true | false) ;;
    *) trading_die "Trading" "Invalid value '$value' (use true or false)." ;;
  esac
  trading_platform_json "$id" | grep -q . ||
    trading_die "Trading" "Unknown platform: '$id'"
  label=$(jq -r --arg id "$id" '.platforms[$id].label // $id' "$TRADING_CONFIG")
  tmp=$(mktemp)
  jq --arg id "$id" --argjson v "$value" '.platforms[$id].enabled = $v' \
    "$TRADING_CONFIG" >"$tmp" && mv "$tmp" "$TRADING_CONFIG"
  if [[ $value == false && $(jq -r '.activePlatform' "$TRADING_CONFIG") == "$id" ]]; then
    # Disabling the active platform moves the selection to the next enabled one.
    tmp=$(mktemp)
    jq --arg id "$id" '
      ([.platforms | to_entries[] | select(.value.enabled != false) | .key] | sort) as $keys
      | if ($keys | length) > 0 then .activePlatform = $keys[0] else . end' \
      "$TRADING_CONFIG" >"$tmp" && mv "$tmp" "$TRADING_CONFIG"
  fi
  if [[ $value == true ]]; then
    trading_notify low "Trading" "Platform enabled: $label"
  else
    trading_notify low "Trading" "Platform disabled: $label"
  fi
  echo "platform $id enabled=$value"
  exit 0
fi

if [[ $action == flow ]]; then
  fid="${2:-}"
  [[ -n $fid ]] || usage
  run_flow "$fid"
  exit 0
fi

if [[ $action == flow-add ]]; then
  steps_arg="${2:-}"
  [[ -n $steps_arg ]] || trading_die "Trading" "Provide the steps. Ex.: flow-add 'profit:buy rocket:buy'"
  steps_json="[]"
  for pair in $(printf '%s' "$steps_arg" | tr ',' ' '); do
    plat="${pair%%:*}"
    act="${pair#*:}"
    [[ $plat != "$act" ]] ||
      trading_die "Trading" "Invalid step: '$pair' (format platform:action, e.g. profit:buy)"
    case $act in
      buy | sell) ;;
      *) trading_die "Trading" "Invalid action in step '$pair' (use buy or sell)" ;;
    esac
    trading_platform_json "$plat" | grep -q . ||
      trading_die "Trading" "Unknown platform in step '$pair': '$plat'"
    steps_json=$(jq -c --arg p "$plat" --arg a "$act" '. + [{"platform": $p, "action": $a}]' <<<"$steps_json")
  done
  fcount=$(jq 'length' <<<"$steps_json")
  ((fcount >= 1)) || trading_die "Trading" "No valid step provided."
  id="flow-1"
  n=2
  while jq -e --arg id "$id" '(.flows // {}) | has($id)' "$TRADING_CONFIG" >/dev/null; do
    id="flow-${n}"
    n=$((n + 1))
  done
  label="Flow ${id#flow-}"
  tmp=$(mktemp)
  jq --arg id "$id" --arg label "$label" --argjson steps "$steps_json" '
    .flows = ((.flows // {}) + {($id): {label: $label, steps: $steps, enabled: true}})' \
    "$TRADING_CONFIG" >"$tmp" && mv "$tmp" "$TRADING_CONFIG"
  trading_notify normal "Trading" "Flow created: $label ($fcount step(s))"
  echo "created: $id ($fcount step(s))"
  exit 0
fi

if [[ $action == flow-remove ]]; then
  fid="${2:-}"
  [[ -n $fid ]] || usage
  flabel=$(jq -r --arg id "$fid" '(.flows // {})[$id].label // empty' "$TRADING_CONFIG")
  [[ -n $flabel ]] || trading_die "Trading" "Unknown flow: '$fid'"
  tmp=$(mktemp)
  jq --arg id "$fid" 'del(.flows[$id])' "$TRADING_CONFIG" >"$tmp" && mv "$tmp" "$TRADING_CONFIG"
  trading_notify low "Trading" "Flow removed: $flabel"
  echo "removed: $fid"
  trading_apply_binds
  exit 0
fi

if [[ $action == flow-rename ]]; then
  # trade.sh flow-rename <id> <name> — label shown in the panel.
  fid="${2:-}"
  newlabel="${3:-}"
  [[ -n $fid ]] || usage
  newlabel=$(printf '%s' "$newlabel" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -n $newlabel ]] || trading_die "Trading" "The flow name cannot be empty."
  if (( ${#newlabel} > 40 )); then
    trading_die "Trading" "The flow name must be at most 40 characters."
  fi
  jq -e --arg id "$fid" '(.flows // {}) | has($id)' "$TRADING_CONFIG" >/dev/null ||
    trading_die "Trading" "Unknown flow: '$fid'"
  tmp=$(mktemp)
  jq --arg id "$fid" --arg label "$newlabel" \
    '.flows[$id].label = $label' "$TRADING_CONFIG" >"$tmp" && mv "$tmp" "$TRADING_CONFIG"
  trading_notify low "Trading" "Flow renamed: $newlabel"
  echo "renamed: $fid → $newlabel"
  exit 0
fi

if [[ $action == flow-enable ]]; then
  # trade.sh flow-enable <id> <true|false> — a disabled flow loses its shortcut.
  fid="${2:-}"
  value="${3:-}"
  [[ -n $fid && -n $value ]] || usage
  case $value in
    true | false) ;;
    *) trading_die "Trading" "Invalid value '$value' (use true or false)." ;;
  esac
  jq -e --arg id "$fid" '(.flows // {}) | has($id)' "$TRADING_CONFIG" >/dev/null ||
    trading_die "Trading" "Unknown flow: '$fid'"
  flabel=$(jq -r --arg id "$fid" '.flows[$id].label // $id' "$TRADING_CONFIG")
  tmp=$(mktemp)
  jq --arg id "$fid" --argjson v "$value" '.flows[$id].enabled = $v' \
    "$TRADING_CONFIG" >"$tmp" && mv "$tmp" "$TRADING_CONFIG"
  trading_apply_binds
  if [[ $value == true ]]; then
    trading_notify low "Trading" "Flow enabled: $flabel"
  else
    trading_notify low "Trading" "Flow disabled: $flabel"
  fi
  echo "flow $fid enabled=$value"
  exit 0
fi

if [[ $action == flow-bind ]]; then
  # trade.sh flow-bind <id> <key|off> — Super+Alt+<key> runs the flow.
  # The key accepts letters, digits and function keys (e.g. 1, 2, F5).
  fid="${2:-}"
  key="${3:-}"
  [[ -n $fid ]] || usage
  jq -e --arg id "$fid" '(.flows // {}) | has($id)' "$TRADING_CONFIG" >/dev/null ||
    trading_die "Trading" "Unknown flow: '$fid'"
  key=$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [[ $key == off || -z $key ]]; then
    tmp=$(mktemp)
    jq --arg id "$fid" 'del(.flows[$id].key)' "$TRADING_CONFIG" >"$tmp" &&
      mv "$tmp" "$TRADING_CONFIG"
    trading_apply_binds
    trading_notify low "Trading" "Flow shortcut removed."
    echo "unbound: $fid"
    exit 0
  fi
  key=${key^^}
  if ! [[ $key =~ ^[0-9A-Z]$ ]] && ! [[ $key =~ ^F([1-9]|1[0-2])$ ]]; then
    trading_die "Trading" "Invalid key: '$key' — use 0-9, A-Z or F1-F12 (no modifiers)."
  fi
  owner=$(jq -r --arg id "$fid" --arg key "$key" '
    (.flows // {}) | to_entries[]
    | select(.value.key == $key and .key != $id) | .value.label // .key' "$TRADING_CONFIG" | head -1)
  [[ -z $owner ]] || trading_die "Trading" "The key '$key' is already used by the flow '$owner'."
  cdesc=$(trading_key_conflict "$key")
  if [[ -n $cdesc ]]; then
    trading_die "Trading" "Super+Alt+$key is already used by the system: $cdesc. Choose another key."
  fi
  tmp=$(mktemp)
  jq --arg id "$fid" --arg key "$key" '.flows[$id].key = $key' "$TRADING_CONFIG" >"$tmp" &&
    mv "$tmp" "$TRADING_CONFIG"
  trading_apply_binds
  trading_notify normal "Trading" "Flow shortcut: Super+Alt+$key"
  echo "bound: $fid → Super+Alt+$key"
  exit 0
fi

if [[ $action == binds-apply ]]; then
  # trade.sh binds-apply — syncs the flow shortcuts with Hyprland (run at shell
  # start, by the panel and whenever keys change).
  trading_apply_binds
  exit 0
fi

platform="${2:-$(jq -r '.activePlatform // empty' "$TRADING_CONFIG" 2>/dev/null)}"
[[ -n $platform ]] || trading_die "Trading" "No active platform. Edit $TRADING_CONFIG"

if [[ $action == focus ]]; then
  platform_json=$(trading_platform_json "$platform")
  [[ -n $platform_json ]] || trading_die "Trading" "Unknown platform: '$platform' (see $TRADING_CONFIG)"
  label=$(trading_field "$platform_json" '.label' "$platform")
  class=$(trading_field "$platform_json" '.windowClass' "")
  launch=$(trading_field "$platform_json" '.launch' "")
  launch_timeout=$(jq -r '.launchTimeoutSec // 25' "$TRADING_CONFIG" 2>/dev/null)
  notify_ok=$(jq -r '.notifyOnSuccess // true' "$TRADING_CONFIG" 2>/dev/null)
  addr=$(trading_ensure_window "$class" "$launch" "$launch_timeout")
  [[ -n $addr ]] || trading_die "Trading — $label" "Window not found (class: '$class') and no launch command."
  trading_focus_window "$addr"
  sleep 0.35
  if [[ $notify_ok == true ]]; then
    trading_notify low "Trading" "$label focused"
  fi
  echo "focused: $label"
  exit 0
fi

case $action in
  buy | sell) perform_trade "$platform" "$action" || exit 1 ;;
  *) usage ;;
esac
