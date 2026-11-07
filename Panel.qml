import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Trading panel: choose the active platform, enable or disable platforms and
// flows, calibrate BUY/SELL positions, build flows, rename and remove items.
//
// Hosted by the omarchy shell like other panel plugins: the shell drives
// `opened` on toggle/summon and the bar widget opens it with
// `omarchy-shell shell toggle francisco.trading`.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  property var platforms: []
  property var flows: []
  property string activeId: ""
  property string activeLabel: ""
  property bool standby: false

  // Inline editors and confirmations: at most one of each is open at a time.
  property string confirmRemoveId: ""
  property string confirmFlowRemoveId: ""
  property string renameId: ""
  property string renameShort: ""
  property string renameLabel: ""
  property string flowRenameId: ""
  property string flowRenameLabel: ""
  property string flowBindId: ""
  property string flowBindKey: ""

  property bool builderActive: false
  property var builderSteps: []

  property string lastResult: ""
  property bool busy: false
  property bool shown: false
  property bool markersVisible: false
  property var buyPt: null
  property var sellPt: null

  // Commands clicked while another one is running wait in this queue instead
  // of being dropped, so a fast second click is never lost.
  property var queue: []

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/trading.json"
  readonly property string tradeScript: decodeURIComponent(Qt.resolvedUrl("scripts/trade.sh").toString().replace(/^file:\/\//, ""))
  readonly property string calibrateScript: decodeURIComponent(Qt.resolvedUrl("scripts/calibrate.sh").toString().replace(/^file:\/\//, ""))

  onOpenedChanged: {
    if (root.opened) root.shown = true
    root.confirmRemoveId = ""
    root.confirmFlowRemoveId = ""
  }

  function open(payloadJson) {
    // Called by the shell host on summon/toggle.
    root.shown = true
    root.opened = true
  }

  function close() {
    // Called by the shell host on hide.
    root.shown = false
    root.opened = false
    root.confirmRemoveId = ""
    root.confirmFlowRemoveId = ""
    root.builderActive = false
    root.builderSteps = []
    root.cancelRename()
    root.cancelFlowRename()
    root.cancelFlowBind()
  }

  function hideSelf() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "francisco.trading")
  }

  function refresh(raw) {
    try {
      if (typeof raw !== "string" || raw.length > 131072) return
      var cfg = JSON.parse(raw || "{}")
      var list = []
      var ids = Object.keys(cfg.platforms || {}).sort()
      for (var i = 0; i < ids.length; i++) {
        var id = ids[i]
        var p = cfg.platforms[id] || {}
        var pos = p.positions || {}
        list.push({
                    "id": id,
                    "label": String(p.label || id),
                    "shortLabel": String(p.shortLabel || p.label || id).slice(0, 4),
                    "windowClass": String(p.windowClass || ""),
                    "enabled": p.enabled !== false,
                    "buy": !!pos.buy,
                    "sell": !!pos.sell
                  })
      }
      root.platforms = list
      root.activeId = String(cfg.activePlatform || "")
      root.standby = !!cfg.standby
      root.activeLabel = ""
      for (var j = 0; j < list.length; j++) {
        if (list[j].id === root.activeId) root.activeLabel = list[j].label
      }
      var shortById = {}
      for (var s = 0; s < list.length; s++) shortById[list[s].id] = list[s].shortLabel || list[s].id
      var flowsList = []
      var flowsObj = cfg.flows || {}
      var fids = Object.keys(flowsObj).sort()
      for (var f = 0; f < fids.length; f++) {
        var fid = fids[f]
        var fl = flowsObj[fid] || {}
        var steps = fl.steps || []
        var parts = []
        for (var t = 0; t < steps.length && t < 6; t++) {
          var st = steps[t] || {}
          var sid = shortById[String(st.platform)] || String(st.platform || "?")
          parts.push(sid + (String(st.action) === "buy" ? " ▲" : " ▼"))
        }
        if (steps.length > 6) parts.push("…")
        flowsList.push({
                         "id": fid,
                         "label": String(fl.label || fid),
                         "summary": parts.join(" → "),
                         "count": steps.length,
                         "key": String(fl.key || ""),
                         "enabled": fl.enabled !== false
                       })
      }
      root.flows = flowsList
    } catch (error) {
      return
    }
  }

  function builderSummary() {
    var parts = []
    for (var i = 0; i < root.builderSteps.length; i++) {
      var s = root.builderSteps[i]
      parts.push(String(s.short || s.platform) + (s.action === "buy" ? " ▲" : " ▼"))
    }
    return parts.length ? parts.join(" → ") : "Click ▲ / ▼ on the platforms to add steps"
  }

  function addBuilderStep(platformId, shortLabel, stepAction) {
    var steps = root.builderSteps.slice()
    steps.push({ "platform": platformId, "short": shortLabel, "action": stepAction })
    root.builderSteps = steps
  }

  function saveBuilderFlow() {
    if (root.builderSteps.length === 0) return
    var arg = root.builderSteps.map(function (s) { return s.platform + ":" + s.action }).join(" ")
    root.builderActive = false
    root.builderSteps = []
    root.run(root.tradeScript, ["flow-add", arg])
  }

  function cancelBuilderFlow() {
    root.builderActive = false
    root.builderSteps = []
  }

  function screenByName(name) {
    var ss = Quickshell.screens
    for (var i = 0; i < ss.length; i++) {
      if (ss[i].name === name) return ss[i]
    }
    return null
  }

  function showPoints(platformId) {
    pointsProcess.command = [root.tradeScript, "points", platformId]
    pointsProcess.running = true
  }

  // Runs a script. If another one is still running, the command is queued
  // and runs as soon as the current one finishes.
  function run(path, args) {
    var cmd = [path].concat(args)
    if (root.busy) {
      var q = root.queue.slice()
      q.push(cmd)
      root.queue = q
      return
    }
    root.busy = true
    scriptProcess.command = cmd
    scriptProcess.running = true
  }

  function runNext() {
    if (root.queue.length === 0) return
    var q = root.queue.slice()
    var cmd = q.shift()
    root.queue = q
    root.busy = true
    scriptProcess.command = cmd
    scriptProcess.running = true
  }

  function calibrate(id, action) {
    // The panel gets out of the way so it never covers the platform's own
    // order buttons; feedback arrives via notifications.
    root.hideSelf()
    root.run(root.calibrateScript, ["calibrate", id, action, "5"])
  }

  function setPlatformEnabled(id, value) {
    root.run(root.tradeScript, ["platform-enable", id, value ? "true" : "false"])
  }

  function setFlowEnabled(id, value) {
    root.run(root.tradeScript, ["flow-enable", id, value ? "true" : "false"])
  }

  function startRename(id, short, label) {
    root.confirmRemoveId = ""
    root.renameId = id
    root.renameShort = short
    root.renameLabel = label
  }

  function cancelRename() {
    root.renameId = ""
    root.renameShort = ""
    root.renameLabel = ""
  }

  function commitRename(id) {
    var short = root.renameShort.trim()
    if (short.length === 0) {
      root.lastResult = "✗ The short label cannot be empty"
      return
    }
    if (short.length > 4) {
      root.lastResult = "✗ The short label must be at most 4 characters"
      return
    }
    root.run(root.tradeScript, ["platform-rename", id, short, root.renameLabel.trim()])
    root.cancelRename()
  }

  function startFlowRename(id, label) {
    root.flowBindId = ""
    root.flowRenameId = id
    root.flowRenameLabel = label
  }

  function cancelFlowRename() {
    root.flowRenameId = ""
    root.flowRenameLabel = ""
  }

  function commitFlowRename(id) {
    var label = root.flowRenameLabel.trim()
    if (label.length === 0) {
      root.lastResult = "✗ The flow name cannot be empty"
      return
    }
    root.run(root.tradeScript, ["flow-rename", id, label])
    root.cancelFlowRename()
  }

  function startFlowBind(id, key) {
    root.flowRenameId = ""
    root.flowBindId = id
    root.flowBindKey = key
  }

  function cancelFlowBind() {
    root.flowBindId = ""
    root.flowBindKey = ""
  }

  function commitFlowBind(id) {
    var key = root.flowBindKey.trim().toUpperCase()
    if (key.length === 0) {
      root.run(root.tradeScript, ["flow-bind", id, "off"])
      root.cancelFlowBind()
      return
    }
    if (!/^([0-9A-Z]|F([1-9]|1[0-2]))$/.test(key)) {
      root.lastResult = "✗ Invalid key — use 0-9, A-Z or F1-F12 (no modifiers)"
      return
    }
    root.run(root.tradeScript, ["flow-bind", id, key])
    root.cancelFlowBind()
  }

  implicitWidth: 0
  implicitHeight: 0

  FileView {
    path: root.configPath
    watchChanges: true
    onLoaded: root.refresh(text())
    onFileChanged: reload()
  }

  Process {
    id: scriptProcess

    onExited: function (exitCode) {
      root.busy = false
      root.lastResult = exitCode === 0 ? "✓ Done" : "✗ Failed — see the notification"
      root.runNext()
    }
  }

  Process {
    id: pointsProcess

    // Collects the JSON the script prints; without a collector `stdout` is
    // null and the parsed points would never reach the panel or the markers.
    stdout: StdioCollector {
      waitForEnd: true
    }

    onExited: function (exitCode) {
      var txt = String((pointsProcess.stdout && pointsProcess.stdout.text) || "").trim()
      if (exitCode !== 0 || txt.length === 0 || txt.length > 8192) {
        root.lastResult = "✗ Could not read the points"
        return
      }
      try {
        var d = JSON.parse(txt)
        if (!d.open) {
          root.lastResult = d.label + " is not open — open the app to see its points"
          return
        }
        root.buyPt = d.buy && d.buy.calibrated ? d.buy : null
        root.sellPt = d.sell && d.sell.calibrated ? d.sell : null
        if (root.buyPt === null && root.sellPt === null) {
          root.lastResult = d.label + ": no calibrated position yet"
          return
        }
        root.markersVisible = true
        markerTimer.restart()
        var parts = []
        parts.push("▲ " + (d.buy && d.buy.calibrated ? "(" + d.buy.x + "," + d.buy.y + ")" : "—"))
        parts.push("▼ " + (d.sell && d.sell.calibrated ? "(" + d.sell.x + "," + d.sell.y + ")" : "—"))
        root.lastResult = d.label + " · " + parts.join("  ")
      } catch (error) {
        root.lastResult = "✗ Could not read the points"
      }
    }
  }

  Timer {
    id: markerTimer

    interval: 4000
    onTriggered: root.markersVisible = false
  }

  PanelWindow {
    id: panelWindow

    // Layer-shell panels don't receive keyboard events by default, so text
    // inputs would silently swallow nothing. Follow the shell's KeyboardPanel
    // pattern: prime with Exclusive on open (covers keybind summons, where no
    // click ever focused the surface), then settle on OnDemand so the rest of
    // the desktop keeps working while the panel is up.
    property bool keyboardPrimed: false

    WlrLayershell.keyboardFocus: root.shown
      ? (keyboardPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
      : WlrKeyboardFocus.None

    onVisibleChanged: {
      if (visible) {
        keyboardPrimed = false
        keyboardPrimeTimer.restart()
      } else {
        keyboardPrimeTimer.stop()
        keyboardPrimed = false
      }
    }

    Timer {
      id: keyboardPrimeTimer

      interval: 75
      onTriggered: if (root.shown) panelWindow.keyboardPrimed = true
    }

    visible: root.shown
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    // The card is the whole interactive surface. Without an explicit mask
    // the layer surface stays click-through on this shell (same fix the EQ
    // plugin needed), which leaves every button dead.
    mask: Region {
      item: card
    }

    anchors {
      top: true
      right: true
    }
    margins {
      top: 40
      right: 8
    }
    implicitWidth: 440
    implicitHeight: Math.min(cardColumn.implicitHeight + 28, 760)

    Rectangle {
      id: card

      anchors.fill: parent
      color: Commons.Color.background
      radius: Style.cornerRadius
      border.width: 1
      border.color: Qt.alpha(Commons.Color.foreground, 0.12)

      Column {
        id: cardColumn

        anchors.fill: parent
        anchors.margins: 14
        spacing: 12

        // Header
        Item {
          width: parent.width
          height: 30

          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            textFormat: Text.PlainText
            text: "\uf201  Trading"
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            spacing: 4

            // Stand by: removes the arrows and the short label from the bar,
            // leaving only "Trading OFF", until it is turned back on here.
            Button {
              iconText: "\uf011"
              fontSize: Style.font.body
              foreground: root.standby ? "#f0883e" : Commons.Color.foreground
              tooltipText: root.standby
                ? "Stand by is ON — trading is disabled. Click to turn it back on"
                : "Put Trading on stand by (the bar shows Trading OFF)"
              onClicked: root.run(root.tradeScript, ["standby", root.standby ? "off" : "on"])
            }

            Button {
              iconText: "\uf00d"
              fontSize: Style.font.body
              tooltipText: "Close"
              onClicked: root.hideSelf()
            }
          }
        }

        // Active platform summary
        Rectangle {
          width: parent.width
          height: 40
          radius: Style.cornerRadius * 0.6
          color: Qt.alpha(Commons.Color.accent, 0.12)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 10
            width: parent.width - 60
            textFormat: Text.PlainText
            text: root.activeId ? "Active: " + root.activeLabel : "No active platform"
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: 6
            iconText: "\uf124"
            fontSize: Style.font.caption
            tooltipText: "Go to the active platform (Super+Alt+T)"
            onClicked: root.run(root.tradeScript, ["focus"])
          }
        }

        // Stand-by banner
        Rectangle {
          width: parent.width
          height: root.standby ? 40 : 0
          visible: root.standby
          radius: Style.cornerRadius * 0.6
          color: Qt.alpha("#f0883e", 0.12)
          border.width: 1
          border.color: "#f0883e"

          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 10
            width: parent.width - 20
            textFormat: Text.PlainText
            text: "Stand by — BUY/SELL and flows are blocked. Turn it back on with the power button."
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
        }

        // Flow builder banner
        Rectangle {
          width: parent.width
          height: root.builderActive ? 52 : 0
          visible: root.builderActive
          radius: Style.cornerRadius * 0.6
          color: Qt.alpha(Commons.Color.accent, 0.12)
          border.width: 1
          border.color: Commons.Color.accent

          Column {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 10
            width: parent.width - 80
            spacing: 2

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "New flow — click ▲ / ▼ on the platforms"
              color: Commons.Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.builderSummary()
              color: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
          }

          Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: 6
            spacing: 2

            Button {
              iconText: "\uf00c"
              fontSize: Style.font.caption
              foreground: "#3fb950"
              tooltipText: "Save flow"
              enabled: root.builderSteps.length > 0
              onClicked: root.saveBuilderFlow()
            }

            Button {
              iconText: "\uf00d"
              fontSize: Style.font.caption
              tooltipText: "Cancel"
              onClicked: root.cancelBuilderFlow()
            }
          }
        }

        // Platforms section
        PanelSectionHeader {
          text: "PLATFORMS"
          foreground: Commons.Color.foreground
        }

        Flickable {
          width: parent.width
          height: Math.min(contentHeight, 300)
          clip: true
          contentWidth: width
          contentHeight: platformColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: platformColumn

            width: parent.width
            spacing: 6

            Repeater {
              model: root.platforms

              delegate: Rectangle {
                id: rowCard

                required property var modelData

                readonly property bool isActive: modelData.id === root.activeId
                readonly property bool editing: root.renameId === modelData.id

                width: parent.width
                height: editing ? 124 : 88
                radius: Style.cornerRadius * 0.6
                color: isActive ? Qt.alpha(Commons.Color.accent, 0.16) : Qt.alpha(Commons.Color.foreground, 0.04)
                border.width: isActive ? 1 : 0
                border.color: Commons.Color.accent

                // Selecting the row makes it the active platform (enabled only).
                MouseArea {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.right: toggleHost.left
                  anchors.bottom: parent.bottom
                  cursorShape: Qt.PointingHandCursor
                  enabled: !rowCard.editing && modelData.enabled
                  onClicked: {
                    if (rowCard.isActive) return
                    root.run(root.tradeScript, ["set-active", modelData.id])
                  }
                }

                // Info (dimmed when the platform is disabled)
                Row {
                  id: infoRow

                  anchors.left: parent.left
                  anchors.leftMargin: 10
                  anchors.top: parent.top
                  anchors.topMargin: 10
                  spacing: 10
                  opacity: modelData.enabled ? 1 : 0.5

                  Rectangle {
                    width: 40
                    height: 22
                    radius: Style.cornerRadius * 0.4
                    anchors.verticalCenter: parent.verticalCenter
                    color: rowCard.isActive ? Commons.Color.accent : Qt.alpha(Commons.Color.foreground, 0.10)

                    Text {
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: modelData.shortLabel
                      color: rowCard.isActive ? Commons.Color.background : Commons.Color.accent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1
                    width: infoRow.parent.width - 10 - 40 - 10 - toggleHost.width - 16

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: modelData.label + (modelData.enabled ? "" : "  · disabled")
                      color: Commons.Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: rowCard.isActive
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: (modelData.windowClass || "no window class")
                            + "   " + (modelData.buy ? "▲ ok" : "▲ —")
                            + "   " + (modelData.sell ? "▼ ok" : "▼ —")
                      color: Commons.Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideMiddle
                    }
                  }
                }

                // Enable / disable switch
                Item {
                  id: toggleHost

                  width: toggleSwitch.width
                  height: toggleSwitch.height
                  anchors.right: parent.right
                  anchors.rightMargin: 10
                  anchors.top: parent.top
                  anchors.topMargin: 10

                  ToggleSwitch {
                    id: toggleSwitch

                    checked: modelData.enabled
                    interactive: true
                    rounded: Style.cornerRadius > 0
                    trackHeight: 18
                    foreground: Commons.Color.foreground
                    accent: Commons.Color.accent
                    onToggled: root.setPlatformEnabled(modelData.id, !modelData.enabled)
                  }
                }

                // Action row (hidden while a rename or remove is in progress)
                Row {
                  id: actionRow

                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.right: parent.right
                  anchors.rightMargin: 8
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: 4
                  spacing: 2
                  visible: !rowCard.editing && root.confirmRemoveId !== modelData.id
                  layoutDirection: Qt.LeftToRight

                  Button {
                    iconText: "\uf062"
                    text: "Buy"
                    fontSize: Style.font.caption
                    foreground: modelData.buy ? "#3fb950" : Commons.Color.foreground
                    tooltipText: root.builderActive
                      ? "Add BUY on " + modelData.label + " to the flow"
                      : (modelData.buy ? "BUY calibrated — click to recalibrate" : "Calibrate BUY position")
                    onClicked: {
                      if (root.builderActive) {
                        root.addBuilderStep(modelData.id, modelData.shortLabel, "buy")
                        return
                      }
                      root.calibrate(modelData.id, "buy")
                    }
                  }

                  Button {
                    iconText: "\uf063"
                    text: "Sell"
                    fontSize: Style.font.caption
                    foreground: modelData.sell ? "#f85149" : Commons.Color.foreground
                    tooltipText: root.builderActive
                      ? "Add SELL on " + modelData.label + " to the flow"
                      : (modelData.sell ? "SELL calibrated — click to recalibrate" : "Calibrate SELL position")
                    onClicked: {
                      if (root.builderActive) {
                        root.addBuilderStep(modelData.id, modelData.shortLabel, "sell")
                        return
                      }
                      root.calibrate(modelData.id, "sell")
                    }
                  }

                  Button {
                    iconText: "\uf06e"
                    fontSize: Style.font.caption
                    tooltipText: "Show the saved points on screen (4s)"
                    onClicked: root.showPoints(modelData.id)
                  }

                  Button {
                    iconText: "\uf044"
                    fontSize: Style.font.caption
                    tooltipText: "Rename — short label (up to 4 characters) and name"
                    onClicked: {
                      root.startRename(modelData.id, modelData.shortLabel, modelData.label)
                      renameShortInput.text = modelData.shortLabel
                      renameLabelInput.text = modelData.label
                    }
                  }

                  Button {
                    iconText: "\uf1f8"
                    fontSize: Style.font.caption
                    tooltipText: "Remove platform"
                    onClicked: root.confirmRemoveId = modelData.id
                  }
                }

                // Remove confirmation
                Row {
                  anchors.right: parent.right
                  anchors.rightMargin: 8
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: 4
                  spacing: 2
                  visible: root.confirmRemoveId === modelData.id

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: "Remove?"
                    color: Commons.Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  Button {
                    iconText: "\uf00c"
                    fontSize: Style.font.caption
                    foreground: "#f85149"
                    tooltipText: "Confirm removal"
                    onClicked: {
                      var id = modelData.id
                      root.confirmRemoveId = ""
                      root.run(root.tradeScript, ["platform-remove", id])
                    }
                  }

                  Button {
                    iconText: "\uf00d"
                    fontSize: Style.font.caption
                    tooltipText: "Cancel"
                    onClicked: root.confirmRemoveId = ""
                  }
                }

                // Rename editor: short label (1-4 chars) + full name
                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: 10
                  anchors.right: parent.right
                  anchors.rightMargin: 8
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: 6
                  spacing: 6
                  visible: rowCard.editing
                  onVisibleChanged: {
                    if (visible) Qt.callLater(function () {
                      renameShortInput.forceActiveFocus()
                    })
                  }

                  Rectangle {
                    width: 58
                    height: 28
                    radius: Style.cornerRadius * 0.5
                    color: Qt.alpha(Commons.Color.foreground, 0.06)
                    border.width: 1
                    border.color: renameShortInput.activeFocus
                                  ? Commons.Color.accent : Qt.alpha(Commons.Color.foreground, 0.25)

                    TextInput {
                      id: renameShortInput

                      anchors.fill: parent
                      anchors.margins: 6
                      text: ""
                      maximumLength: 4
                      color: Commons.Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: true
                      verticalAlignment: TextInput.AlignVCenter
                      clip: true
                      onTextEdited: root.renameShort = text
                      Keys.onReturnPressed: root.commitRename(modelData.id)
                      Keys.onEscapePressed: root.cancelRename()
                    }
                  }

                  Rectangle {
                    width: 180
                    height: 28
                    radius: Style.cornerRadius * 0.5
                    color: Qt.alpha(Commons.Color.foreground, 0.06)
                    border.width: 1
                    border.color: renameLabelInput.activeFocus
                                  ? Commons.Color.accent : Qt.alpha(Commons.Color.foreground, 0.25)

                    TextInput {
                      id: renameLabelInput

                      anchors.fill: parent
                      anchors.margins: 6
                      text: ""
                      maximumLength: 40
                      color: Commons.Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      verticalAlignment: TextInput.AlignVCenter
                      clip: true
                      onTextEdited: root.renameLabel = text
                      Keys.onReturnPressed: root.commitRename(modelData.id)
                      Keys.onEscapePressed: root.cancelRename()
                    }
                  }

                  Button {
                    iconText: "\uf00c"
                    fontSize: Style.font.caption
                    foreground: "#3fb950"
                    tooltipText: "Save (Enter)"
                    onClicked: root.commitRename(modelData.id)
                  }

                  Button {
                    iconText: "\uf00d"
                    fontSize: Style.font.caption
                    tooltipText: "Cancel (Esc)"
                    onClicked: root.cancelRename()
                  }
                }
              }
            }
          }
        }

        // Flows section
        PanelSectionHeader {
          text: "FLOWS"
          foreground: Commons.Color.foreground
        }

        Repeater {
          model: root.flows

          delegate: Rectangle {
            id: flowRow

            required property var modelData

            readonly property bool editing: root.flowRenameId === modelData.id || root.flowBindId === modelData.id

            width: parent.width
            height: editing ? 146 : 118
            radius: Style.cornerRadius * 0.6
            color: Qt.alpha(Commons.Color.foreground, 0.04)

            // Info (dimmed when the flow is disabled)
            Item {
              id: flowInfo

              anchors.left: parent.left
              anchors.leftMargin: 10
              anchors.top: parent.top
              anchors.topMargin: 10
              anchors.right: flowToggleHost.left
              anchors.rightMargin: 10
              height: flowInfoColumn.implicitHeight
              opacity: modelData.enabled ? 1 : 0.5

              Column {
                id: flowInfoColumn

                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 1

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: modelData.label + (modelData.enabled ? "" : "  · disabled")
                  color: Commons.Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: modelData.summary + "  (" + modelData.count + " step" + (modelData.count === 1 ? "" : "s") + ")"
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  visible: modelData.key !== ""
                  text: "⌨ Super+Alt+" + modelData.key
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }

            // Enable / disable switch for the flow
            Item {
              id: flowToggleHost

              width: flowToggle.width
              height: flowToggle.height
              anchors.right: parent.right
              anchors.rightMargin: 10
              anchors.top: parent.top
              anchors.topMargin: 10

              ToggleSwitch {
                id: flowToggle

                checked: modelData.enabled
                interactive: true
                rounded: Style.cornerRadius > 0
                trackHeight: 18
                foreground: Commons.Color.foreground
                accent: Commons.Color.accent
                onToggled: root.setFlowEnabled(flowRow.modelData.id, !flowRow.modelData.enabled)
              }
            }

            // Action row
            Row {
              anchors.left: parent.left
              anchors.leftMargin: 8
              anchors.right: parent.right
              anchors.rightMargin: 8
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 4
              spacing: 2
              visible: !flowRow.editing && root.confirmFlowRemoveId !== modelData.id

              Button {
                iconText: "\uf04b"
                text: "Run"
                fontSize: Style.font.caption
                foreground: Commons.Color.accent
                enabled: modelData.enabled
                tooltipText: modelData.enabled ? "Run this flow now" : "Enable the flow to run it"
                onClicked: {
                  root.hideSelf()
                  root.run(root.tradeScript, ["flow", flowRow.modelData.id])
                }
              }

              Button {
                iconText: "\uf044"
                fontSize: Style.font.caption
                tooltipText: "Rename flow"
                onClicked: {
                  root.startFlowRename(flowRow.modelData.id, flowRow.modelData.label)
                  flowRenameInput.text = flowRow.modelData.label
                }
              }

              Button {
                iconText: "\uf11c"
                fontSize: Style.font.caption
                foreground: modelData.key !== "" ? Commons.Color.accent : Commons.Color.foreground
                tooltipText: modelData.key !== ""
                             ? "Current shortcut: Super+Alt+" + modelData.key + " — click to change"
                             : "Set keyboard shortcut (Super+Alt+<key>)"
                onClicked: {
                  root.startFlowBind(flowRow.modelData.id, flowRow.modelData.key)
                  flowBindInput.text = flowRow.modelData.key
                }
              }

              Button {
                iconText: "\uf1f8"
                fontSize: Style.font.caption
                tooltipText: "Remove flow"
                onClicked: root.confirmFlowRemoveId = flowRow.modelData.id
              }
            }

            // Flow remove confirmation
            Row {
              anchors.right: parent.right
              anchors.rightMargin: 8
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 4
              spacing: 2
              visible: root.confirmFlowRemoveId === modelData.id

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Remove?"
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Button {
                iconText: "\uf00c"
                fontSize: Style.font.caption
                foreground: "#f85149"
                tooltipText: "Confirm removal"
                onClicked: {
                  var fid = flowRow.modelData.id
                  root.confirmFlowRemoveId = ""
                  root.run(root.tradeScript, ["flow-remove", fid])
                }
              }

              Button {
                iconText: "\uf00d"
                fontSize: Style.font.caption
                tooltipText: "Cancel"
                onClicked: root.confirmFlowRemoveId = ""
              }
            }

            // Flow rename editor
            Row {
              anchors.left: parent.left
              anchors.leftMargin: 10
              anchors.right: parent.right
              anchors.rightMargin: 8
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 6
              spacing: 6
              visible: root.flowRenameId === modelData.id
              onVisibleChanged: {
                if (visible) Qt.callLater(function () {
                  flowRenameInput.forceActiveFocus()
                })
              }

              Rectangle {
                width: 240
                height: 28
                radius: Style.cornerRadius * 0.5
                color: Qt.alpha(Commons.Color.foreground, 0.06)
                border.width: 1
                border.color: flowRenameInput.activeFocus
                              ? Commons.Color.accent : Qt.alpha(Commons.Color.foreground, 0.25)

                TextInput {
                  id: flowRenameInput

                  anchors.fill: parent
                  anchors.margins: 6
                  text: ""
                  maximumLength: 40
                  color: Commons.Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  verticalAlignment: TextInput.AlignVCenter
                  clip: true
                  onTextEdited: root.flowRenameLabel = text
                  Keys.onReturnPressed: root.commitFlowRename(modelData.id)
                  Keys.onEscapePressed: root.cancelFlowRename()
                }
              }

              Button {
                iconText: "\uf00c"
                fontSize: Style.font.caption
                foreground: "#3fb950"
                tooltipText: "Save (Enter)"
                onClicked: root.commitFlowRename(modelData.id)
              }

              Button {
                iconText: "\uf00d"
                fontSize: Style.font.caption
                tooltipText: "Cancel (Esc)"
                onClicked: root.cancelFlowRename()
              }
            }

            // Flow shortcut editor
            Row {
              anchors.left: parent.left
              anchors.leftMargin: 10
              anchors.right: parent.right
              anchors.rightMargin: 8
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 6
              spacing: 6
              visible: root.flowBindId === modelData.id
              onVisibleChanged: {
                if (visible) Qt.callLater(function () {
                  flowBindInput.forceActiveFocus()
                })
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Super+Alt +"
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Rectangle {
                width: 60
                height: 28
                radius: Style.cornerRadius * 0.5
                color: Qt.alpha(Commons.Color.foreground, 0.06)
                border.width: 1
                border.color: flowBindInput.activeFocus
                              ? Commons.Color.accent : Qt.alpha(Commons.Color.foreground, 0.25)

                TextInput {
                  id: flowBindInput

                  anchors.fill: parent
                  anchors.margins: 6
                  text: ""
                  maximumLength: 3
                  color: Commons.Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  verticalAlignment: TextInput.AlignVCenter
                  clip: true
                  onTextEdited: root.flowBindKey = text
                  Keys.onReturnPressed: root.commitFlowBind(modelData.id)
                  Keys.onEscapePressed: root.cancelFlowBind()
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 150
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: "key (0-9, A-Z, F1-F12) · empty = none"
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Button {
                iconText: "\uf00c"
                fontSize: Style.font.caption
                foreground: "#3fb950"
                tooltipText: "Save shortcut (Enter)"
                onClicked: root.commitFlowBind(modelData.id)
              }

              Button {
                iconText: "\uf00d"
                fontSize: Style.font.caption
                tooltipText: "Cancel (Esc)"
                onClicked: root.cancelFlowBind()
              }
            }
          }
        }

        // New flow
        Rectangle {
          width: parent.width
          height: root.builderActive ? 0 : 40
          visible: !root.builderActive
          radius: Style.cornerRadius * 0.6
          color: Qt.alpha(Commons.Color.foreground, 0.04)
          border.width: 1
          border.color: Qt.alpha(Commons.Color.foreground, 0.10)

          Button {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 6
            iconText: "\uf067"
            text: "New flow"
            fontSize: Style.font.caption
            tooltipText: "Build a sequence of BUY/SELL steps across platforms"
            onClicked: {
              root.builderActive = true
              root.builderSteps = []
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: 10
            textFormat: Text.PlainText
            text: "e.g. BUY on Profit → Rocket"
            color: Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // Add platform
        Rectangle {
          width: parent.width
          height: 46
          radius: Style.cornerRadius * 0.6
          color: Qt.alpha(Commons.Color.foreground, 0.04)
          border.width: 1
          border.color: Qt.alpha(Commons.Color.foreground, 0.10)

          Button {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 6
            iconText: "\uf05b"
            text: "Capture active window"
            fontSize: Style.font.caption
            tooltipText: "Add the focused window as a platform (class + title)"
            onClicked: root.run(root.tradeScript, ["platform-add-active"])
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: 10
            width: parent.width / 2 - 16
            textFormat: Text.PlainText
            text: "Open the platform app, then click here"
            color: Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignRight
          }
        }

        // Footer status
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.busy ? "Working…" : (root.lastResult || "Click a platform to make it active")
          color: root.lastResult.startsWith("✗") ? "#f85149" : Commons.Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  // Circles drawn over the calibrated points (4s). One small window per
  // point instead of a fullscreen overlay, so they never block the platform
  // UI and land on the right monitor by name (points are monitor-local).
  component CalMarker: PanelWindow {
    id: marker

    property var pt: null
    property color tint: "#3fb950"

    visible: root.markersVisible && marker.pt !== null
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    screen: marker.pt ? root.screenByName(marker.pt.screen) : null
    anchors {
      top: true
      left: true
    }
    margins {
      top: marker.pt ? marker.pt.y - 20 : 0
      left: marker.pt ? marker.pt.x - 20 : 0
    }
    implicitWidth: 40
    implicitHeight: 40

    Rectangle {
      anchors.centerIn: parent
      width: 40
      height: 40
      radius: 20
      color: Qt.alpha(marker.tint, 0.18)
      border.color: marker.tint
      border.width: 3

      // Soft pulse so the ring reads as "this is the saved spot" even over
      // a busy chart; it only runs while the marker is on screen (4s).
      SequentialAnimation on scale {
        running: root.markersVisible && marker.pt !== null
        loops: Animation.Infinite
        NumberAnimation { to: 1.15; duration: Style.duration(450); easing.type: Easing.OutCubic }
        NumberAnimation { to: 0.92; duration: Style.duration(450); easing.type: Easing.OutCubic }
      }

      Rectangle {
        anchors.centerIn: parent
        width: 8
        height: 8
        radius: 4
        color: marker.tint
      }
    }
  }

  CalMarker {
    pt: root.buyPt
    tint: "#3fb950"
  }

  CalMarker {
    pt: root.sellPt
    tint: "#f85149"
  }
}
