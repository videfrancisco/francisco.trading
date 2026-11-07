import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root

  moduleName: "francisco.trading"

  property string activeId: ""
  property string activeLabel: ""
  property bool activeEnabled: true
  property bool standby: false
  property bool buyReady: false
  property bool sellReady: false

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/trading.json"
  readonly property string tradeScript: decodeURIComponent(Qt.resolvedUrl("scripts/trade.sh").toString().replace(/^file:\/\//, ""))

  // Re-applies the Super+Alt+<key> flow shortcuts when the shell starts
  // (dynamic Hyprland binds are lost on every reload/restart).
  Process {
    id: bindsApply

    command: [root.tradeScript, "binds-apply"]
  }

  Component.onCompleted: bindsApply.running = true

  function refresh(raw) {
    try {
      if (typeof raw !== "string" || raw.length > 131072) return
      var cfg = JSON.parse(raw || "{}")
      var id = String(cfg.activePlatform || "")
      var platform = (cfg.platforms || {})[id] || {}
      var pos = platform.positions || {}
      root.activeId = id
      root.activeLabel = String(platform.shortLabel || platform.label || id || "—")
      root.activeEnabled = platform.enabled !== false
      root.standby = !!cfg.standby
      root.buyReady = !!pos.buy
      root.sellReady = !!pos.sell
    } catch (error) {
      return
    }
  }

  function trade(action) {
    if (root.standby) return
    if (!root.activeId || !root.activeEnabled || !root.bar) return
    root.bar.run('"' + root.tradeScript + '" ' + action)
  }

  implicitWidth: row.implicitWidth
  implicitHeight: row.implicitHeight

  FileView {
    path: root.configPath
    watchChanges: true
    onLoaded: root.refresh(text())
    onFileChanged: reload()
  }

  Row {
    id: row

    spacing: 1

    WidgetButton {
      id: platformButton

      visible: !root.standby

      bar: root.bar
      text: root.activeLabel
      fontSize: Style.font.caption
      dimmed: root.activeId !== "" && !root.activeEnabled
      tooltipText: root.activeId
        ? "Active platform: " + root.activeLabel
          + (root.activeEnabled ? "" : " (disabled)")
          + " · left-click opens the Trading panel · right-click switches"
        : "No active platform — open the Trading panel to add one"

      onPressed: function (mouseButton) {
        if (!root.bar) return
        if (mouseButton === Qt.RightButton) {
          root.bar.run('"' + root.tradeScript + '" next-platform')
          return
        }
        root.bar.run("omarchy-shell shell toggle francisco.trading")
      }
    }

    WidgetButton {
      id: buyButton

      visible: !root.standby

      bar: root.bar
      text: "\uf062"
      fontSize: Style.font.body
      foreground: "#3fb950"
      dimmed: !root.buyReady || !root.activeEnabled
      tooltipText: !root.activeEnabled
        ? "BUY unavailable — " + root.activeLabel + " is disabled"
        : root.buyReady
          ? "BUY · " + root.activeLabel + " (Super+Alt+C)"
          : "BUY not calibrated — Trading panel › Calibrate BUY"

      onPressed: function (mouseButton) {
        if (mouseButton !== Qt.LeftButton) return
        root.trade("buy")
      }
    }

    WidgetButton {
      id: sellButton

      visible: !root.standby

      bar: root.bar
      text: "\uf063"
      fontSize: Style.font.body
      foreground: "#f85149"
      dimmed: !root.sellReady || !root.activeEnabled
      tooltipText: !root.activeEnabled
        ? "SELL unavailable — " + root.activeLabel + " is disabled"
        : root.sellReady
          ? "SELL · " + root.activeLabel + " (Super+Alt+V)"
          : "SELL not calibrated — Trading panel › Calibrate SELL"

      onPressed: function (mouseButton) {
        if (mouseButton !== Qt.LeftButton) return
        root.trade("sell")
      }
    }

    // Stand by: the arrows and the platform short label go away and only the
    // "Trading OFF" text remains. Clicking it opens the panel to turn back on.
    WidgetButton {
      id: standbyButton

      visible: root.standby

      bar: root.bar
      text: "Trading OFF"
      fontSize: Style.font.caption
      dimmed: true
      tooltipText: "Trading in stand by — click to open the Trading panel and turn it back on"

      onPressed: function (mouseButton) {
        if (mouseButton !== Qt.LeftButton) return
        root.bar.run("omarchy-shell shell toggle francisco.trading")
      }
    }
  }
}
