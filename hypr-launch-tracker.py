#!/usr/bin/env python3

import ctypes
import json
import os
import signal
import socket
import subprocess
import time
from dataclasses import dataclass, field
from typing import Optional

# ============================================================
# Configuration
# ============================================================

# Fallback defaults. When running as the Omarchy plugin these are
# replaced by barWidget.defaults in manifest.json, and those by the
# plugin's entry in ~/.config/omarchy/shell.json, which the bar
# widget edits. Both files are re-read whenever they change, so new
# values apply without a restart.

# How long a launch record should remain alive.
LAUNCH_TTL = 30.0

# Don't try to associate an unrelated application with an old
# launch if it appears after this amount of time.
MATCH_WINDOW = 15.0

# Set to True once you are confident the matching works.
MOVE_WINDOWS = True

# Print detailed process information.
VERBOSE = False

PLUGIN_ID = "hyprmove.hyprlaunchtracker"

SHELL_CONFIG = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
    "omarchy",
    "shell.json",
)

MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "manifest.json")

# shell.json key -> (global name, type)
CONFIG_KEYS = {
    "launchTtl": ("LAUNCH_TTL", float),
    "matchWindow": ("MATCH_WINDOW", float),
    "moveWindows": ("MOVE_WINDOWS", bool),
    "verbose": ("VERBOSE", bool),
}


# ============================================================
# Data structures
# ============================================================


@dataclass
class ProcessInfo:
    pid: int
    ppid: int
    exe: str
    cmdline: str
    name: str


@dataclass
class WindowInfo:
    address: str
    workspace: str
    workspace_id: Optional[int]

    pid: int
    class_name: str
    initial_class: str
    title: str
    initial_title: str

    process: Optional[ProcessInfo]
    ancestors: list[ProcessInfo]

    created_at: float = field(default_factory=time.monotonic)


@dataclass
class LaunchRecord:
    id: int

    workspace: str
    workspace_id: Optional[int]

    created_at: float
    expires_at: float

    # Windows/processes that have been associated with this launch.
    windows: dict[str, WindowInfo] = field(default_factory=dict)
    pids: set[int] = field(default_factory=set)

    # Useful identity information from the initial window.
    executables: set[str] = field(default_factory=set)
    classes: set[str] = field(default_factory=set)
    initial_classes: set[str] = field(default_factory=set)


# ============================================================
# Global state
# ============================================================

launches: dict[int, LaunchRecord] = {}
next_launch_id = 1


# ============================================================
# Logging
# ============================================================


def log(message: str):
    print(message, flush=True)


def verbose(message: str):
    if VERBOSE:
        print(message, flush=True)


# ============================================================
# Plugin settings
# ============================================================

# Values the script starts with, used when neither the manifest nor
# shell.json gives a valid one.
BUILTIN_DEFAULTS = {key: globals()[name] for key, (name, _) in CONFIG_KEYS.items()}

config_mtimes: Optional[tuple] = None


def find_plugin_entry(config) -> Optional[dict]:
    """
    Find this plugin's entry in shell.json, either in the bar
    layout or in the top-level plugins list.
    """

    if not isinstance(config, dict):
        return None

    bar = config.get("bar")
    layout = bar.get("layout") if isinstance(bar, dict) else None

    if not isinstance(layout, dict):
        layout = {}

    entries = []

    for section in ("left", "center", "right"):
        entries.extend(layout.get(section) or [])

    entries.extend(config.get("plugins") or [])

    for entry in entries:
        if isinstance(entry, dict) and entry.get("id") == PLUGIN_ID:
            return entry

    return None


def coerce_setting(kind, value):
    """
    Return value as kind, or None if it is not a valid setting.
    """

    if kind is bool:
        return value if isinstance(value, bool) else None

    if isinstance(value, bool):
        return None

    try:
        value = kind(value)
    except (TypeError, ValueError):
        return None

    return value if value > 0 else None


def read_json(path: str):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        verbose(f"Could not read {path}: {e}")
        return None


def file_mtime(path: str) -> Optional[float]:
    try:
        return os.stat(path).st_mtime
    except OSError:
        return None


def reload_config(force: bool = False):
    """
    Apply settings if shell.json or manifest.json changed since the
    last read. Each setting comes from the shell.json entry, then the
    manifest defaults, then BUILTIN_DEFAULTS, using the first valid one.
    """

    global config_mtimes

    mtimes = (file_mtime(SHELL_CONFIG), file_mtime(MANIFEST))

    if not force and mtimes == config_mtimes:
        return

    config_mtimes = mtimes

    manifest = read_json(MANIFEST)
    bar_widget = manifest.get("barWidget") if isinstance(manifest, dict) else None
    defaults = bar_widget.get("defaults") if isinstance(bar_widget, dict) else None

    if not isinstance(defaults, dict):
        defaults = {}

    entry = find_plugin_entry(read_json(SHELL_CONFIG)) or {}

    changed = []

    for key, (name, kind) in CONFIG_KEYS.items():
        value = None

        for source in (entry, defaults):
            if key in source:
                value = coerce_setting(kind, source[key])

                if value is not None:
                    break

        if value is None:
            value = BUILTIN_DEFAULTS[key]

        if globals()[name] != value:
            globals()[name] = value
            changed.append(f"{key}={value}")

    if changed:
        log(f"CONFIG {' '.join(changed)}")


def die_with_parent():
    """
    Ask the kernel to SIGTERM us if omarchy-shell goes away, so a
    crashed shell never leaves an orphaned tracker behind.
    """

    try:
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        PR_SET_PDEATHSIG = 1
        libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM)
    except OSError:
        pass


# ============================================================
# Process inspection
# ============================================================


def read_process(pid: int) -> Optional[ProcessInfo]:
    """
    Read information about a Linux process from /proc.
    """

    try:
        if not os.path.exists(f"/proc/{pid}"):
            return None

        # Executable
        try:
            exe = os.path.realpath(f"/proc/{pid}/exe")
        except OSError:
            exe = ""

        # Command line
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                raw = f.read()

            cmdline = raw.replace(b"\x00", b" ").decode(errors="replace").strip()
        except OSError:
            cmdline = ""

        # Name + PPID
        name = ""
        ppid = 0

        try:
            with open(f"/proc/{pid}/status", "r") as f:
                for line in f:
                    if line.startswith("Name:"):
                        name = line.split(":", 1)[1].strip()

                    elif line.startswith("PPid:"):
                        ppid = int(line.split(":", 1)[1].strip())
        except (OSError, ValueError):
            pass

        return ProcessInfo(
            pid=pid,
            ppid=ppid,
            exe=exe,
            cmdline=cmdline,
            name=name,
        )

    except Exception as e:
        verbose(f"    process inspection failed for {pid}: {e}")
        return None


def get_process_tree(pid: int, max_depth: int = 20):
    """
    Walk from pid toward init/systemd and return the ancestry.
    """

    result = []

    current_pid = pid
    seen = set()

    for _ in range(max_depth):
        if current_pid <= 0 or current_pid in seen:
            break

        seen.add(current_pid)

        process = read_process(current_pid)

        if process is None:
            break

        result.append(process)

        if process.ppid == current_pid:
            break

        current_pid = process.ppid

    return result


# ============================================================
# Hyprland helpers
# ============================================================


def hyprctl(*args) -> Optional[str]:
    """
    Run hyprctl and return stdout.
    """

    try:
        result = subprocess.run(
            ["hyprctl", *args],
            capture_output=True,
            text=True,
            timeout=2,
        )

        if result.returncode != 0:
            verbose(f"hyprctl failed: {' '.join(args)}\n{result.stderr.strip()}")
            return None

        return result.stdout

    except Exception as e:
        verbose(f"hyprctl exception: {e}")
        return None


def get_clients():
    """
    Get all Hyprland clients.
    """

    output = hyprctl("-j", "clients")

    if not output:
        return []

    try:
        return json.loads(output)
    except json.JSONDecodeError:
        verbose("Could not decode hyprctl clients output")
        return []


def get_client(address: str):
    """
    Find one Hyprland client by address.
    """

    for client in get_clients():
        if normalize_address(client.get("address", "")) == normalize_address(address):
            return client

    return None


def normalize_address(address: str) -> str:
    """
    Normalize Hyprland window addresses.
    """

    address = address.strip()

    if address.startswith("0x"):
        return address.lower()

    return "0x" + address.lower()


def move_window(address: str, workspace: str) -> bool:
    """
    Move a specific window to a workspace without following it.

    Hyprland 0.55+:
        hyprctl dispatch 'hl.dsp.window.move({
            workspace = "...",
            window = "address:0x...",
            follow = false
        })'

    `hyprctl dispatch` already wraps the expression in
    `hl.dispatch(...)`, so we must NOT add hl.dispatch()
    ourselves.
    """

    address = normalize_address(address)

    workspace_value = str(workspace)

    # Safely quote the values as Lua strings.
    lua_workspace = json.dumps(workspace_value)
    lua_address = json.dumps(f"address:{address}")

    lua_expression = (
        "hl.dsp.window.move({"
        f"workspace = {lua_workspace}, "
        f"window = {lua_address}, "
        "follow = false"
        "})"
    )

    log("")
    log("MOVING WINDOW")
    log(f"  address  : {address}")
    log(f"  workspace: {workspace}")
    log(f"  lua      : {lua_expression}")

    if not MOVE_WINDOWS:
        log("  [dry-run: window not actually moved]")
        return False

    try:
        result = subprocess.run(
            [
                "hyprctl",
                "dispatch",
                lua_expression,
            ],
            capture_output=True,
            text=True,
            timeout=3,
        )

        log(f"  return code: {result.returncode}")

        if result.stdout.strip():
            log(f"  stdout: {result.stdout.strip()}")

        if result.stderr.strip():
            log(f"  stderr: {result.stderr.strip()}")

        if result.returncode != 0:
            log("  FAILED")
        else:
            log("  SUCCESS")

        return result.returncode == 0

    except Exception as e:
        log(f"  EXCEPTION: {e}")
        return False


# ============================================================
# Window inspection
# ============================================================


def make_window_info(
    address: str,
    event_workspace: str,
    event_class: str,
    event_title: str,
) -> Optional[WindowInfo]:

    address = normalize_address(address)

    client = get_client(address)

    if client is None:
        verbose(f"  Could not find client {address} in hyprctl clients")
        return None

    pid = int(client.get("pid", 0) or 0)

    workspace_info = client.get("workspace", {}) or {}

    workspace_id = workspace_info.get("id")

    workspace_name = workspace_info.get("name") or event_workspace

    class_name = client.get("class") or event_class or ""

    initial_class = client.get("initialClass") or class_name or ""

    title = client.get("title") or event_title or ""

    initial_title = client.get("initialTitle") or title or ""

    process = read_process(pid)
    ancestors = get_process_tree(pid)

    return WindowInfo(
        address=address,
        workspace=workspace_name,
        workspace_id=workspace_id,
        pid=pid,
        class_name=class_name,
        initial_class=initial_class,
        title=title,
        initial_title=initial_title,
        process=process,
        ancestors=ancestors,
    )


def print_window(window: WindowInfo):

    log("")
    log("=" * 70)
    log("NEW WINDOW")
    log("=" * 70)

    log(f"address       : {window.address}")
    log(f"workspace     : {window.workspace}")
    log(f"workspace id  : {window.workspace_id}")
    log(f"pid           : {window.pid}")
    log(f"class         : {window.class_name}")
    log(f"initial class : {window.initial_class}")
    log(f"title         : {window.title}")
    log(f"initial title : {window.initial_title}")

    if window.process:
        p = window.process

        log("")
        log("PROCESS")
        log(f"  name        : {p.name}")
        log(f"  executable  : {p.exe}")
        log(f"  command     : {p.cmdline}")
        log(f"  parent pid  : {p.ppid}")

    log("")
    log("PROCESS ANCESTRY")

    for i, p in enumerate(window.ancestors):
        log(f"  {'  ' * i}{p.pid} {p.name} ({p.exe})")


# ============================================================
# Matching
# ============================================================


def executable(window: WindowInfo) -> str:
    if window.process:
        return window.process.exe

    return ""


def ancestor_pids(window: WindowInfo) -> set[int]:
    return {p.pid for p in window.ancestors}


def ancestor_executables(window: WindowInfo) -> set[str]:
    return {p.exe for p in window.ancestors if p.exe}


def score_match(
    window: WindowInfo,
    launch: LaunchRecord,
) -> tuple[int, list[str]]:

    score = 0
    reasons = []

    now = time.monotonic()

    age = now - launch.created_at

    if age > MATCH_WINDOW:
        return 0, ["too old"]

    current_exe = executable(window)

    # --------------------------------------------------------
    # Exact PID
    # --------------------------------------------------------

    if window.pid in launch.pids:
        score += 100
        reasons.append("same PID")

    # --------------------------------------------------------
    # Process ancestry
    # --------------------------------------------------------

    current_ancestors = ancestor_pids(window)

    if current_ancestors & launch.pids:
        score += 80
        reasons.append("launch PID is an ancestor")

    # Check whether any original window's process is an
    # ancestor of the new process.
    for old_window in launch.windows.values():
        old_tree = ancestor_pids(old_window)

        if old_window.pid in current_ancestors:
            score += 90
            reasons.append(f"new PID is descendant of PID {old_window.pid}")

        if old_tree & current_ancestors:
            score += 30
            reasons.append("shared process ancestry")

    # --------------------------------------------------------
    # Executable
    # --------------------------------------------------------

    if current_exe and current_exe in launch.executables:
        score += 35
        reasons.append("same executable")

    # --------------------------------------------------------
    # Initial class
    # --------------------------------------------------------

    if window.initial_class and window.initial_class in launch.initial_classes:
        score += 25
        reasons.append("same initial class")

    # --------------------------------------------------------
    # Normal class
    # --------------------------------------------------------

    if window.class_name and window.class_name in launch.classes:
        score += 15
        reasons.append("same class")

    # --------------------------------------------------------
    # Process executable appears in ancestry
    # --------------------------------------------------------

    if launch.executables & ancestor_executables(window):
        score += 30
        reasons.append("launch executable in ancestry")

    return score, reasons


def find_matching_launch(window: WindowInfo):
    """
    Find the strongest unique launch match.

    We deliberately refuse ambiguous matches.
    Moving the wrong window is worse than leaving it alone.
    """

    candidates = []

    for launch in launches.values():
        score, reasons = score_match(window, launch)

        if score > 0:
            candidates.append((score, launch, reasons))

    if not candidates:
        return None

    candidates.sort(
        key=lambda x: x[0],
        reverse=True,
    )

    best_score, best_launch, best_reasons = candidates[0]

    # If two launches have exactly the same score, don't guess.
    if len(candidates) > 1:
        second_score = candidates[1][0]

        if best_score == second_score:
            log(
                f"  AMBIGUOUS MATCH: launches "
                f"{best_launch.id} and "
                f"{candidates[1][1].id}"
            )

            return None

    # Require a reasonably strong match.
    #
    # Same executable alone is only 35 points, so two independent
    # launches of the same program won't automatically get merged.
    if best_score < 40:
        return None

    return best_launch, best_score, best_reasons


# ============================================================
# Launch management
# ============================================================


def create_launch(window: WindowInfo) -> LaunchRecord:

    global next_launch_id

    launch = LaunchRecord(
        id=next_launch_id,
        workspace=window.workspace,
        workspace_id=window.workspace_id,
        created_at=time.monotonic(),
        expires_at=time.monotonic() + LAUNCH_TTL,
    )

    next_launch_id += 1

    add_window_to_launch(launch, window)

    launches[launch.id] = launch

    log(f"  NEW LAUNCH #{launch.id} workspace={launch.workspace} pid={window.pid}")

    return launch


def add_window_to_launch(
    launch: LaunchRecord,
    window: WindowInfo,
):
    launch.windows[window.address] = window
    launch.pids.add(window.pid)

    exe = executable(window)

    if exe:
        launch.executables.add(exe)

    if window.class_name:
        launch.classes.add(window.class_name)

    if window.initial_class:
        launch.initial_classes.add(window.initial_class)

    # Every related window extends the lifetime of the launch.
    launch.expires_at = time.monotonic() + LAUNCH_TTL


def expire_launches():

    now = time.monotonic()

    expired = [
        launch_id for launch_id, launch in launches.items() if launch.expires_at <= now
    ]

    for launch_id in expired:
        launch = launches.pop(launch_id)

        log(f"EXPIRE launch #{launch.id} workspace={launch.workspace}")


# ============================================================
# Window handling
# ============================================================


def handle_window_open(
    address: str,
    workspace: str,
    class_name: str,
    title: str,
):

    reload_config()

    expire_launches()

    window = make_window_info(
        address,
        workspace,
        class_name,
        title,
    )

    if window is None:
        return

    print_window(window)

    # --------------------------------------------------------
    # Try to associate with an existing launch
    # --------------------------------------------------------

    match = find_matching_launch(window)

    if match is None:
        # Nothing looks related.
        #
        # This window becomes the beginning of a new launch
        # record.
        create_launch(window)

        return

    launch, score, reasons = match

    log("")
    log(f"MATCH → launch #{launch.id} (score={score})")

    for reason in reasons:
        log(f"  + {reason}")

    log(f"  original workspace : {launch.workspace}")

    log(f"  current workspace  : {window.workspace}")

    # Add this window to the launch.
    add_window_to_launch(launch, window)

    # Already on the correct workspace.
    if window.workspace == launch.workspace:
        log("  already on correct workspace")
        return

    # Otherwise move it back.
    moved = move_window(
        window.address,
        launch.workspace,
    )

    if moved:
        # Machine-readable line for the omarchy-shell service.
        event = {
            "class": window.class_name,
            "title": window.title,
            "from": window.workspace,
            "to": launch.workspace,
        }

        log(f"@@moved {json.dumps(event)}")


# ============================================================
# Socket handling
# ============================================================


def socket_path() -> str:

    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")

    if not runtime_dir:
        raise RuntimeError("XDG_RUNTIME_DIR is not set")

    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")

    if not signature:
        raise RuntimeError("HYPRLAND_INSTANCE_SIGNATURE is not set")

    return f"{runtime_dir}/hypr/{signature}/.socket2.sock"


def parse_event(line: str):

    line = line.rstrip("\n")

    if ">>" not in line:
        return None

    event, data = line.split(">>", 1)

    return event, data


def handle_event(line: str):

    parsed = parse_event(line)

    if parsed is None:
        return

    event, data = parsed

    # verbose(f"EVENT: {event} >> {data}")

    if event != "openwindow":
        return

    parts = data.split(",")

    if len(parts) < 4:
        log(f"Malformed openwindow event: {data}")
        return

    address = parts[0]
    workspace = parts[1]
    class_name = parts[2]
    title = ",".join(parts[3:])

    handle_window_open(
        address,
        workspace,
        class_name,
        title,
    )


# ============================================================
# Main
# ============================================================


def main():

    die_with_parent()

    # Exit quietly when the plugin is disabled.
    signal.signal(signal.SIGTERM, lambda *_: (log("Exiting."), os._exit(0)))

    reload_config(force=True)

    path = socket_path()

    log("")
    log("=" * 70)
    log("Hyprland Application Launch Tracker")
    log("=" * 70)
    log(f"socket: {path}")
    log(f"launch TTL: {LAUNCH_TTL}s")
    log(f"match window: {MATCH_WINDOW}s")
    log(f"move windows: {MOVE_WINDOWS}")
    log("=" * 70)
    log("")

    if not os.path.exists(path):
        raise RuntimeError(f"Hyprland socket does not exist:\n{path}")

    while True:
        try:
            with socket.socket(
                socket.AF_UNIX,
                socket.SOCK_STREAM,
            ) as sock:
                log("Connecting to Hyprland socket...")

                sock.connect(path)

                log("Connected.")
                log("Waiting for windows...")
                log("")

                buffer = b""

                while True:
                    data = sock.recv(8192)

                    if not data:
                        raise ConnectionError("Hyprland socket closed")

                    buffer += data

                    while b"\n" in buffer:
                        raw_line, buffer = buffer.split(
                            b"\n",
                            1,
                        )

                        line = raw_line.decode(errors="replace")

                        handle_event(line)

        except KeyboardInterrupt:
            log("Exiting.")
            break

        except Exception as e:
            log("")
            log(f"Socket error: {e}")
            log("Reconnecting in 2 seconds...")
            log("")

            time.sleep(2)


if __name__ == "__main__":
    main()
