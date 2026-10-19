import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar button + popup for the launch tracker. The tracker process itself
// lives in Service.qml; this widget shows its status and edits the timing
// settings, which are saved inline on this widget's shell.json entry where
// the script picks them up.
Panel {
  id: root
  moduleName: "hyprmove.hyprlaunchtracker"

  readonly property string pluginId: "hyprmove.hyprlaunchtracker"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int launchTtl: Math.round(Number(setting("launchTtl", 30)))
  readonly property int matchWindow: Math.round(Number(setting("matchWindow", 15)))
  readonly property bool moveWindows: setting("moveWindows", true) === true

  property var service: null
  readonly property bool running: service ? service.running === true : false
  readonly property int moveCount: service ? service.moveCount : 0
  readonly property var recentMoves: service ? service.recentMoves : []

  function findService() {
    if (service || !bar || !bar.shell || typeof bar.shell.serviceFor !== "function") return
    service = bar.shell.serviceFor(pluginId)
  }

  function saveSetting(key, value) {
    if (setting(key, undefined) === value) return
    var next = Object.assign({}, root.settings)
    next[key] = value
    root.settings = next
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(root.moduleName, next)
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

  onBarChanged: findService()
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
    owner: root
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
            anchors.right: restartButton.left
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

          Button {
            id: restartButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"
            tooltipText: "Restart tracker"
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            visible: root.service !== null
            onClicked: if (root.service) root.service.restart()
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
