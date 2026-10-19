import QtQuick
import Quickshell
import Quickshell.Io

// Owns the tracker process. omarchy-shell creates this service while the
// plugin is enabled (its id is in shell.json) and destroys it on disable,
// so the Python tracker starts and stops with the plugin. Settings are read
// by the script straight from shell.json, so the bar widget only has to
// persist them.
Item {
  id: service

  // Injected by omarchy-shell.
  property var shell: null

  readonly property string scriptPath: decodeURIComponent(
    Qt.resolvedUrl("hypr-launch-tracker.py").toString().replace(/^file:\/\//, ""))

  readonly property bool running: tracker.running
  property bool stopping: false
  property int moveCount: 0
  // Most recent first: [{ class, title, from, to, at }]
  property var recentMoves: []
  property var recentLog: []

  function restart() {
    restartTimer.stop()
    if (tracker.running) tracker.running = false
    restartTimer.interval = 300
    restartTimer.start()
  }

  function handleLine(line) {
    if (line.indexOf("@@moved ") === 0) {
      try {
        var move = JSON.parse(line.slice(8))
        move.at = new Date()
        service.moveCount += 1
        service.recentMoves = [move].concat(service.recentMoves).slice(0, 5)
      } catch (e) {
        console.warn("hyprlaunchtracker: bad move event:", line)
      }
      return
    }
    service.recentLog = service.recentLog.concat([line]).slice(-200)
  }

  Process {
    id: tracker
    command: ["python3", "-u", service.scriptPath]
    running: true

    stdout: SplitParser {
      onRead: data => service.handleLine(data)
    }

    stderr: SplitParser {
      onRead: data => {
        console.warn("hyprlaunchtracker:", data)
        service.handleLine(data)
      }
    }

    onExited: (exitCode, exitStatus) => {
      if (service.stopping) return
      // Crashed or lost Hyprland: try again shortly.
      restartTimer.interval = 3000
      restartTimer.start()
    }
  }

  Timer {
    id: restartTimer
    interval: 3000
    onTriggered: if (!service.stopping) tracker.running = true
  }

  Component.onDestruction: {
    service.stopping = true
    restartTimer.stop()
    tracker.running = false
  }
}
