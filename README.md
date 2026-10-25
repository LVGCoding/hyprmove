# Launch Tracker

An Omarchy shell plugin that keeps an app on the workspace you launched it
from.

Some apps show a splash or loader window first and open their real window seconds later. If you switch workspace while one of them is loading, Hyprland opens the real window on whatever workspace you are on by then. Launch Tracker spots that the new window belongs to the earlier launch and moves it back to the workspace where the launch started.

## Install

```sh
omarchy plugin add https://github.com/LVGCoding/hyprmove.git --enable
```

Or clone it into `~/.config/omarchy/plugins/hyprmove.hyprlaunchtracker` and
run `omarchy plugin enable hyprmove.hyprlaunchtracker`.

The tracker runs while the plugin is enabled and stops when it is disabled.
It needs `python3`.

## How it works

The bar service starts `hypr-launch-tracker.py`, which listens to Hyprland's
event socket.

1. **A window opens.** The script reads the window from `hyprctl clients` (class, PID, workspace, floating) and its process tree from `/proc`.
2. **It is scored against recent launches.** Each signal the window shares with a launch adds that signal's weight. Two examples are the same PID and the launch's process being an ancestor of the window's.
3. **The best launch wins.** It must reach the minimum score, and no other launch may tie with it. Otherwise the window starts a new launch on its own workspace.
4. **The window is moved back.** If it opened on a different workspace from its launch, it is moved to the launch's workspace and listed under "Recent moves" in the popup.

A launch is forgotten once its _launch lifetime_ passes with no new window.
Windows that open after the launch's _match window_ never join it.

### Apps that are already open

Apps like Ghostty and Brave run one process that owns every window. A new window from them shares a PID with the app's last launch, so on score alone it would be pulled back to that launch's workspace.

With **Only follow loading apps** on (the default), a _tiled_ window only joins a launch that has no open tiled window yet. That means the launch is still loading. _Floating_ windows can still join a launch that is already
open. GIMP relies on this: its welcome window is floating and follows the main window back. A launch whose loader window closed before the real window appeared also still counts as loading.

For anything this gets wrong, add the app's window class to **Ignored apps** (`hyprctl clients` shows the class). The tracker then never touches its windows.

## Settings

Open the popup by clicking the bar icon. Right-clicking the icon toggles **Move windows**. Settings are stored on the widget's entry in `~/.config/omarchy/shell.json`. The script re-reads them when the file changes, so new values apply without a restart. Anything unset uses `barWidget.defaults` in `manifest.json`.

| Setting                  | Key                | Default |                                                                 |
| ------------------------ | ------------------ | ------- | --------------------------------------------------------------- |
| Launch lifetime (s)      | `launchTtl`        | 15      | How long a launch is remembered after its last window.          |
| Match window (s)         | `matchWindow`      | 5       | Windows that open later than this after a launch never join it. |
| Move windows             | `moveWindows`      | on      | Off is a dry run: matches are only logged.                      |
| Only follow loading apps | `onlyWhileLoading` | on      | See [Apps that are already open](#apps-that-are-already-open).  |
| Ignored apps             | `ignoredClasses`   | empty   | Comma-separated window classes that are never moved.            |
| Verbose logging          | `verbose`          | on      | Log every window and process the script inspects.               |
| Minimum score            | `minScore`         | 40      | Score a launch needs before a window is moved to it.            |

### Match weights

Each weight has a switch in the popup (`<key>Enabled`) that turns it off
without losing its value.

| Signal                                       | Key                          | Default |
| -------------------------------------------- | ---------------------------- | ------- |
| Same PID                                     | `weightSamePid`              | 100     |
| New PID descends from a launch window's PID  | `weightDescendant`           | 90      |
| Launch PID is an ancestor                    | `weightLaunchAncestor`       | 80      |
| Shared process ancestry with a launch window | `weightSharedAncestry`       | 30      |
| Same executable                              | `weightSameExecutable`       | 35      |
| Launch executable in the process ancestry    | `weightExecutableInAncestry` | 30      |
| Same initial class                           | `weightSameInitialClass`     | 25      |
| Same class                                   | `weightSameClass`            | 15      |

"Descendant" and "shared ancestry" add once per matching launch window.
"Same executable" on its own (35) stays under the default minimum score, so two separate launches of the same program are not merged.

The popup can reset just the weights, or every setting. Resetting everything takes a second click.

## Files

| File                     |                                                                                     |
| ------------------------ | ----------------------------------------------------------------------------------- |
| `manifest.json`          | Plugin manifest: entry points, setting defaults and schema.                         |
| `Service.qml`            | Runs the tracker script, restarts it if it exits, and collects moves for the popup. |
| `BarWidget.qml`          | Bar entry point. A small shim that loads `BarWidgetContent.qml`.                    |
| `BarWidgetContent.qml`   | The bar button and popup.                                                           |
| `hypr-launch-tracker.py` | The tracker itself.                                                                 |

## Development

omarchy-shell hot-reloads a local plugin when its files change, but two shell quirks shape the widget code:

- **Bar widget code is cached.** On a reload the shell creates the widget from the same URL, and Qt hands back the type it compiled before. `BarWidget.qml` therefore loads `BarWidgetContent.qml` through a URL that is new each time, so edits there show up on reload. Changes to `BarWidget.qml` itself still need `omarchy-restart-shell`.
- **The shell's copies of the settings go stale.** The settings the bar gives a re-created widget are the ones its slot started with, and `bar.shell.barConfig` lags one save behind. The widget reads its entry straight from `shell.json` instead and builds every save on that.

Only the tracker's errors (stderr) reach the shell log:

```sh
quickshell log -p /usr/share/omarchy/shell | grep hyprlaunchtracker
```

Its normal output (stdout) is kept in the service for the popup and not printed. To watch matching decisions, disable the plugin and run the script in a terminal with `python3 -u hypr-launch-tracker.py`. It reads settings from `shell.json` and `manifest.json` the same way. Turn on verbose logging to also see every process it inspects. Disabling the plugin first means two trackers don't both move windows.
