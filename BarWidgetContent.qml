import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The launch tracker's bar button and popup, loaded by BarWidget.qml. The tracker
// process itself lives in Service.qml; this widget shows its status and edits
// the timing settings, which are saved inline on this widget's shell.json
// entry where the script picks them up.
Item {
  id: root
  // The Panel from BarWidget.qml, which owns the bar entry and its settings.
  required property var widget
  readonly property QtObject bar: widget.bar
  readonly property string moduleName: widget.moduleName
  readonly property bool opened: widget.opened

  // Unset values fall back to barWidget.defaults in manifest.json.
  property var defaults: ({})
  function setting(name) {
    var value = entry[name]
    return value === undefined || value === null ? defaults[name] : value
  }

  // This widget's entry in shell.json, read from the file itself. Neither
  // copy the shell offers can be trusted: the settings the bar injects keep
  // the values the slot was first built with (stale after a hot-reload), and
  // bar.shell.barConfig lags one save behind. A save built on either undoes
  // earlier changes. The injected settings only cover the first load.
  property var entry: widget.settings || ({})

  // The settings of the last save until shell.json shows them, so a reload
  // that still has an earlier write can't roll the entry back meanwhile.
  property string pendingSave: ""

  function findEntry(config) {
    if (!config) return null
    var layout = config.bar && config.bar.layout ? config.bar.layout : {}
    var entries = (layout.left || []).concat(layout.center || [], layout.right || [], config.plugins || [])
    for (var i = 0; i < entries.length; i++)
      if (entries[i] && entries[i].id === moduleName) return entries[i]
    return null
  }

  // Order-independent JSON of an entry's settings, without its id.
  function settingsJson(settings) {
    var keys = Object.keys(settings || {}).filter(function(k) { return k !== "id" }).sort()
    return JSON.stringify(keys.map(function(k) { return [k, settings[k]] }))
  }

  function loadEntry(text) {
    var found = null
    try {
      found = findEntry(JSON.parse(text))
    } catch (e) {
      return
    }
    if (!found) return
    if (pendingSave !== "") {
      if (settingsJson(found) !== pendingSave) return
      pendingSave = ""
      pendingSaveTimeout.stop()
    }
    entry = found
  }

  FileView {
    id: shellConfigFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadEntry(text())
  }

  // If a save never shows up in the file, stop waiting for it.
  Timer {
    id: pendingSaveTimeout
    interval: 2000
    onTriggered: {
      root.pendingSave = ""
      shellConfigFile.reload()
    }
  }

  function toggle() { widget.toggle() }
  function close() { widget.close() }
  function switchPanel(direction) { return widget.switchPanel(direction) }

  readonly property string pluginId: "hyprmove.hyprlaunchtracker"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int launchTtl: Math.round(Number(setting("launchTtl")))
  readonly property int matchWindow: Math.round(Number(setting("matchWindow")))
  readonly property bool moveWindows: setting("moveWindows") === true
  readonly property bool onlyWhileLoading: setting("onlyWhileLoading") === true
  readonly property string ignoredClasses: String(setting("ignoredClasses") || "")
  readonly property int minScore: Math.round(Number(setting("minScore")) || 0)

  // Points each signal adds when the script matches a new window to a launch.
  readonly property var weightKeys: [
    { key: "weightSamePid", label: "Same PID" },
    { key: "weightDescendant", label: "Descendant" },
    { key: "weightLaunchAncestor", label: "Launch ancestor" },
    { key: "weightSharedAncestry", label: "Shared ancestry" },
    { key: "weightSameExecutable", label: "Same executable" },
    { key: "weightExecutableInAncestry", label: "Exe in ancestry" },
    { key: "weightSameInitialClass", label: "Initial class" },
    { key: "weightSameClass", label: "Class" }
  ]
  // Each weight also has a "<key>Enabled" flag that switches it off
  // without losing its value.
  readonly property var weightSettingKeys: {
    var keys = ["minScore"]
    for (var i = 0; i < weightKeys.length; i++)
      keys.push(weightKeys[i].key, weightKeys[i].key + "Enabled")
    return keys
  }
  readonly property bool weightsCustomized: customized(weightSettingKeys)
  readonly property bool settingsCustomized: customized(Object.keys(entry))

  // Whether any of these keys is saved with a value other than its default.
  function customized(keys) {
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      if (key === "id" || entry[key] === undefined || entry[key] === null) continue
      if (entry[key] !== defaults[key]) return true
    }
    return false
  }

  function weightEnabled(key) {
    return setting(key + "Enabled") !== false
  }

  property var service: null
  readonly property bool running: service ? service.running === true : false
  readonly property int moveCount: service ? service.moveCount : 0
  readonly property var recentMoves: service ? service.recentMoves : []

  function findService() {
    if (service || !bar || !bar.shell || typeof bar.shell.serviceFor !== "function") return
    service = bar.shell.serviceFor(pluginId)
  }

  function saveSetting(key, value) {
    if (setting(key) === value) return
    var next = Object.assign({}, root.entry)
    next[key] = value
    saveEntry(next)
  }

  // Drop the weights from the entry so they follow the manifest defaults.
  function resetWeights() {
    var next = Object.assign({}, root.entry)
    for (var i = 0; i < weightSettingKeys.length; i++) delete next[weightSettingKeys[i]]
    saveEntry(next)
  }

  // Drop every setting so the whole widget follows the manifest defaults.
  function resetAll() {
    resetArmed = false
    saveEntry({})
  }

  // Resetting everything takes a second click within a few seconds.
  property bool resetArmed: false

  // Show the new settings straight away; shell.json catches up when the
  // shell's write lands.
  function saveEntry(next) {
    delete next.id
    root.entry = Object.assign({ id: root.moduleName }, next)
    root.widget.settings = next
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return
    root.pendingSave = settingsJson(next)
    pendingSaveTimeout.restart()
    // false means shell.json already holds these settings, so no write is coming.
    if (!bar.shell.updateEntryInline(root.moduleName, next)) {
      root.pendingSave = ""
      pendingSaveTimeout.stop()
    }
  }

  function statusText() {
    if (!service) return "Service not loaded"
    if (!running) return "Stopped"
    var moved = moveCount === 1 ? "1 window moved" : moveCount + " windows moved"
    return (moveWindows ? "Running" : "Dry run") + " · " + moved
  }

  function timeAgo(date) {
    if (!date) return ""
    var s = Math.max(0, Math.round((Date.now() - date.getTime()) / 1000))
    if (s < 60) return s + "s ago"
    if (s < 3600) return Math.round(s / 60) + "m ago"
    return Math.round(s / 3600) + "h ago"
  }

  FileView {
    path: decodeURIComponent(
      Qt.resolvedUrl("manifest.json").toString().replace(/^file:\/\//, ""))
    blockLoading: true
    onLoaded: {
      try {
        var manifest = JSON.parse(text())
        root.defaults = (manifest.barWidget && manifest.barWidget.defaults) || {}
      } catch (e) {
        console.warn("hyprlaunchtracker: bad manifest.json:", e)
      }
    }
  }

  onBarChanged: findService()
  onOpenedChanged: if (!opened) resetArmed = false
  Component.onCompleted: findService()

  // The service can be created after the widget on startup and replaced on
  // hot-reload, so keep looking it up until it appears.
  Timer {
    interval: 1000
    repeat: true
    running: !root.service || root.opened
    onTriggered: {
      if (root.service && root.bar && root.bar.shell)
        root.service = root.bar.shell.serviceFor(root.pluginId)
      else
        root.findService()
    }
  }

  Timer {
    interval: 3000
    running: root.resetArmed
    onTriggered: root.resetArmed = false
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰓾"
    slotSize: Style.bar.statusSlot
    dimmed: !root.running || !root.moveWindows
    tooltipText: "Launch Tracker: " + root.statusText()
    onPressed: function(b) {
      if (b === Qt.RightButton) root.saveSetting("moveWindows", !root.moveWindows)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root.widget
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰓾"
            color: root.running ? Color.accent : Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroButtons.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Launch Tracker"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.statusText().toUpperCase()
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Row {
            id: heroButtons
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Button {
              iconText: root.resetArmed ? "" : "󰦛"
              text: root.resetArmed ? "Reset all?" : ""
              tooltipText: root.resetArmed ? "Click again to reset every setting" : "Reset all settings to defaults"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              active: root.resetArmed
              visible: root.settingsCustomized
              onClicked: root.resetArmed ? root.resetAll() : root.resetArmed = true
            }

            Button {
              id: restartButton
              iconText: "󰑐"
              tooltipText: "Restart tracker"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              visible: root.service !== null
              onClicked: if (root.service) root.service.restart()
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---------- Timing ----------
        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "TIMING"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            id: timingRow
            width: parent.width
            spacing: Style.space(12)

            readonly property real cellWidth: (width - spacing) / 2

            NumberField {
              label: "Launch lifetime (s)"
              value: root.launchTtl
              from: 1
              to: 600
              fieldWidth: timingRow.cellWidth
              foreground: root.foreground
              fontFamily: root.fontFamily
              onModified: function(v) { root.saveSetting("launchTtl", v) }
            }

            NumberField {
              label: "Match window (s)"
              value: root.matchWindow
              from: 1
              to: 600
              fieldWidth: timingRow.cellWidth
              foreground: root.foreground
              fontFamily: root.fontFamily
              onModified: function(v) { root.saveSetting("matchWindow", v) }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "A launch is remembered for its lifetime after its last window. "
              + "Only windows that open within the match window of the launch "
              + "are moved back to its workspace."
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Toggle {
          width: parent.width
          label: "Move windows"
          description: root.moveWindows ? "Matched windows are moved back" : "Dry run: matches are only logged"
          checked: root.moveWindows
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.saveSetting("moveWindows", !root.moveWindows)
        }

        Toggle {
          width: parent.width
          label: "Only follow loading apps"
          description: root.onlyWhileLoading
            ? "New windows of apps already open stay where they open"
            : "Any matching window is moved, even for apps already open"
          checked: root.onlyWhileLoading
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.saveSetting("onlyWhileLoading", !root.onlyWhileLoading)
        }

        // ---------- Ignored apps ----------
        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "IGNORED APPS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          TextField {
            id: ignoredField
            width: parent.width
            text: root.ignoredClasses
            placeholderText: "com.mitchellh.ghostty, brave-browser"
            foreground: root.foreground
            font.family: root.fontFamily

            // Saved tidied up when editing ends; Escape drops the edit.
            onEditingFinished: {
              var classes = text.split(",").map(function(c) { return c.trim() })
                .filter(function(c) { return c !== "" })
              root.saveSetting("ignoredClasses", classes.join(", "))
              text = Qt.binding(function() { return root.ignoredClasses })
            }
            Keys.onEscapePressed: function(event) {
              text = Qt.binding(function() { return root.ignoredClasses })
              keyCatcher.forceActiveFocus()
              event.accepted = true
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Comma-separated window classes the tracker never moves. "
              + "Find an app's class with hyprctl clients."
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---------- Match weights ----------
        Column {
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            implicitHeight: Math.max(weightsHeader.implicitHeight, resetWeightsButton.implicitHeight)

            PanelSectionHeader {
              id: weightsHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "MATCH WEIGHTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Button {
              id: resetWeightsButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰦛"
              tooltipText: "Reset weights to defaults"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              visible: root.weightsCustomized
              onClicked: root.resetWeights()
            }
          }

          Grid {
            id: weightsGrid
            width: parent.width
            columns: 2
            columnSpacing: Style.space(12)
            rowSpacing: Style.space(10)

            readonly property real cellWidth: (width - columnSpacing) / 2

            Repeater {
              model: root.weightKeys

              Item {
                id: weightCell
                required property var modelData
                readonly property bool weightOn: root.weightEnabled(modelData.key)
                width: weightsGrid.cellWidth
                implicitHeight: weightField.implicitHeight

                NumberField {
                  id: weightField
                  label: weightCell.modelData.label
                  value: Math.round(Number(root.setting(weightCell.modelData.key)) || 0)
                  from: 0
                  to: 500
                  fieldWidth: weightCell.width - weightSwitch.width - Style.space(8)
                  opacity: weightCell.weightOn ? 1 : 0.4
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onModified: function(v) { root.saveSetting(weightCell.modelData.key, v) }
                }

                ToggleSwitch {
                  id: weightSwitch
                  anchors.right: parent.right
                  y: weightField.field.y + (weightField.field.height - height) / 2
                  checked: weightCell.weightOn
                  foreground: root.foreground
                  onToggled: root.saveSetting(weightCell.modelData.key + "Enabled", !weightCell.weightOn)
                }
              }
            }

            NumberField {
              label: "Minimum score"
              value: root.minScore
              from: 1
              to: 1000
              fieldWidth: weightsGrid.cellWidth
              foreground: root.foreground
              fontFamily: root.fontFamily
              onModified: function(v) { root.saveSetting("minScore", v) }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Each matching signal adds its weight to a launch's score. A window "
              + "is moved to the best launch if it scores at least the minimum and "
              + "no other launch ties. Switch a signal off to ignore it."
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---------- Recent moves ----------
        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "RECENT MOVES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.recentMoves.length === 0
            textFormat: Text.PlainText
            text: "No windows moved yet"
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.recentMoves

            Row {
              required property var modelData
              width: parent.width
              spacing: Style.space(8)

              Text {
                id: moveLabel
                width: parent.width - moveDetail.implicitWidth - parent.spacing
                textFormat: Text.PlainText
                text: modelData["class"] || modelData.title || "window"
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                id: moveDetail
                textFormat: Text.PlainText
                text: modelData.from + " → " + modelData.to + "  " + root.timeAgo(modelData.at)
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }
    }
  }
}
