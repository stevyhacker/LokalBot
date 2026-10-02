"""Bounded AT-SPI probe. Never reads document Value/selection/help attributes."""
import json
import os
import sys

def probe():
    import pyatspi
    capture_text = "--text" in sys.argv
    active = []
    desktop = pyatspi.Registry.getDesktop(0)
    for app in desktop:
        for window in app:
            state = window.getState()
            if state.contains(pyatspi.STATE_ACTIVE) and state.contains(pyatspi.STATE_VISIBLE):
                active.append((app, window))
    if len(active) != 1:
        raise RuntimeError("No unambiguous active accessibility window")
    app, window = active[0]
    bounds = window.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
    pid = app.get_process_id()
    title = window.name or ""
    secure = False
    focused = False
    field = None
    domain = None
    texts = []
    queue = [window]
    inspected = 0
    while queue and inspected < 800:
        node = queue.pop(0)
        inspected += 1
        state = node.getState()
        role = node.getRole()
        if state.contains(pyatspi.STATE_FOCUSED):
            focused = True
            # AT-SPI object identity, independent of mutable labels/text.
            field = str(getattr(node, "path", "")) or None
            secure = secure or role == pyatspi.ROLE_PASSWORD_TEXT
        if not state.contains(pyatspi.STATE_SHOWING):
            continue
        secure = secure or role == pyatspi.ROLE_PASSWORD_TEXT
        try:
            rect = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
            visible = rect.width > 0 and rect.height > 0 and rect.x >= bounds.x and rect.y >= bounds.y and rect.x + rect.width <= bounds.x + bounds.width and rect.y + rect.height <= bounds.y + bounds.height
        except Exception:
            visible = False
        # Visible character ranges, never the entire value of an editable document.
        if capture_text and visible and role in (pyatspi.ROLE_LABEL, pyatspi.ROLE_STATIC):
            if node.name:
                texts.append(node.name[:1000])
        if capture_text and visible and role != pyatspi.ROLE_PASSWORD_TEXT:
            try:
                text = node.queryText()
                # Ubuntu's AT-SPI getBoundedRanges GI binding can segfault.
                # Verify each character rectangle before reading a visible run.
                count = min(text.characterCount, 2000)
                run_start = None
                for offset in range(count):
                    x, y, width, height = text.getCharacterExtents(offset, pyatspi.DESKTOP_COORDS)
                    shown = width > 0 and height > 0 and x >= bounds.x and y >= bounds.y and x + width <= bounds.x + bounds.width and y + height <= bounds.y + bounds.height
                    if shown and run_start is None:
                        run_start = offset
                    if not shown and run_start is not None:
                        texts.append(text.getText(run_start, offset)[:2000])
                        run_start = None
                if run_start is not None:
                    texts.append(text.getText(run_start, count)[:2000])
            except Exception:
                pass
        queue.extend(list(node)[:100])
    if queue:
        secure = None  # An incomplete inspection cannot authorize pixel capture.
    # Domain exclusions remain fail closed when the address is unavailable.
    browser = any(name in (app.name or "").lower() for name in ("chrome", "chromium", "firefox", "brave", "edge", "vivaldi", "opera", "librewolf", "zen", "floorp", "waterfox", "epiphany", "falkon", "qutebrowser", "browser"))
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        import subprocess
        current = json.loads(subprocess.check_output(["hyprctl", "activewindow", "-j"], timeout=3))
        verified = current.get("pid") == pid and current.get("title") == title
        window_id = current.get("address", "")
    else:
        import subprocess
        window_id = subprocess.check_output(["xdotool", "getwindowfocus"], timeout=3).decode().strip()
        current_pid = int(subprocess.check_output(["xdotool", "getwindowpid", window_id], timeout=3))
        current_title = subprocess.check_output(["xdotool", "getwindowname", window_id], timeout=3).decode().strip()
        verified = current_pid == pid and current_title == title
    return {"observation": {"app": app.name or "Unknown", "title": title, "window": window_id, "pid": pid, "field": field, "focus_verified": bool(verified and focused), "secure": secure, "domain": domain, "browser": browser}, "bounds": [bounds.x, bounds.y, bounds.width, bounds.height], "text": "\n".join(dict.fromkeys(texts))[:40000]}

try:
    print(json.dumps(probe()))
except Exception:
    sys.exit(2)
