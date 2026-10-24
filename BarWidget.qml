import QtQuick
import qs.Ui

// Bar entry point for the launch tracker. The widget itself is in
// BarWidgetContent.qml.
//
// On hot-reload omarchy-shell re-creates bar widgets from the same URL, and
// Qt keeps handing back the type it already compiled for that URL, so edits
// to this file only show up after a shell restart. Loading the content
// through a URL that is new each time makes Qt compile the file as it is on
// disk, so keep this file minimal and make changes in BarWidgetContent.qml.
Panel {
  id: root
  moduleName: "hyprmove.hyprlaunchtracker"

  implicitWidth: content.item ? content.item.implicitWidth : 0
  implicitHeight: content.item ? content.item.implicitHeight : 0

  Loader {
    id: content
    anchors.fill: parent
    Component.onCompleted: setSource(
      Qt.resolvedUrl("BarWidgetContent.qml") + "?v=" + Date.now(), { widget: root })
  }
}
