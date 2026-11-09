#!/usr/bin/env python3
"""A keyboard for live tests under KDE Plasma's KWin, which offers no virtual
keyboard protocol: keys go in through KWin's EIS endpoint (libei), the way a
remote desktop session types, so they take the same path as a real keyboard's.

Reads commands on stdin and answers each with `ok` once sent:
  tap <evdev keycode>     press and release one key
  type <lowercase letters>
Prints `ready` once KWin has given it a keyboard. Needs libei and PyGObject.
"""
import ctypes
import select
import sys
import time

from gi.repository import Gio, GLib

EI_EVENT_SEAT_ADDED = 3
EI_EVENT_DEVICE_ADDED = 5
EI_EVENT_DEVICE_RESUMED = 8
EI_DEVICE_CAP_KEYBOARD = 1 << 2
# org.kde.KWin.EIS.RemoteDesktop takes the portal's device types.
PORTAL_KEYBOARD = 1

ROWS = (("qwertyuiop", 16), ("asdfghjkl", 30), ("zxcvbnm", 44))
KEY_SPACE = 57

ei = ctypes.CDLL("libei.so.1")
P = ctypes.c_void_p
ei.ei_new_sender.restype = P
ei.ei_new_sender.argtypes = [P]
ei.ei_configure_name.argtypes = [P, ctypes.c_char_p]
ei.ei_setup_backend_fd.argtypes = [P, ctypes.c_int]
ei.ei_setup_backend_fd.restype = ctypes.c_int
ei.ei_get_fd.argtypes = [P]
ei.ei_get_fd.restype = ctypes.c_int
ei.ei_dispatch.argtypes = [P]
ei.ei_get_event.argtypes = [P]
ei.ei_get_event.restype = P
ei.ei_event_get_type.argtypes = [P]
ei.ei_event_get_type.restype = ctypes.c_int
ei.ei_event_get_seat.argtypes = [P]
ei.ei_event_get_seat.restype = P
ei.ei_event_get_device.argtypes = [P]
ei.ei_event_get_device.restype = P
ei.ei_event_unref.argtypes = [P]
ei.ei_event_unref.restype = P
ei.ei_device_ref.argtypes = [P]
ei.ei_device_ref.restype = P
ei.ei_device_has_capability.argtypes = [P, ctypes.c_int]
ei.ei_device_has_capability.restype = ctypes.c_bool
ei.ei_device_start_emulating.argtypes = [P, ctypes.c_uint32]
ei.ei_device_keyboard_key.argtypes = [P, ctypes.c_uint32, ctypes.c_bool]
ei.ei_device_frame.argtypes = [P, ctypes.c_uint64]
ei.ei_now.argtypes = [P]
ei.ei_now.restype = ctypes.c_uint64
# Variadic, ended by 0: give the arguments' types at each call.
bind_capabilities = ei.ei_seat_bind_capabilities


def connect():
    """The EIS socket, and the bus connection that must stay open with it:
    KWin ends the session when its caller leaves the bus."""
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    reply, fds = bus.call_with_unix_fd_list_sync(
        "org.kde.KWin", "/org/kde/KWin/EIS/RemoteDesktop", "org.kde.KWin.EIS.RemoteDesktop",
        "connectToEIS", GLib.Variant("(i)", (PORTAL_KEYBOARD,)), GLib.VariantType("(hi)"),
        Gio.DBusCallFlags.NONE, 5000, None, None)
    handle, _cookie = reply.unpack()
    return bus, fds.get(handle)


def main():
    context = ei.ei_new_sender(None)
    ei.ei_configure_name(context, b"lokalbot live test")
    bus, eis_fd = connect()
    if ei.ei_setup_backend_fd(context, eis_fd) != 0:
        sys.exit("could not set up libei")
    fd = ei.ei_get_fd(context)
    device = None
    pending = None
    sequence = 1
    deadline = time.monotonic() + 15
    while device is None:
        if time.monotonic() > deadline:
            sys.exit("KWin gave no keyboard")
        select.select([fd], [], [], 0.5)
        ei.ei_dispatch(context)
        while True:
            event = ei.ei_get_event(context)
            if not event:
                break
            kind = ei.ei_event_get_type(event)
            if kind == EI_EVENT_SEAT_ADDED:
                bind_capabilities(P(ei.ei_event_get_seat(event)),
                                  ctypes.c_int(EI_DEVICE_CAP_KEYBOARD), ctypes.c_int(0))
            elif kind == EI_EVENT_DEVICE_ADDED:
                found = ei.ei_event_get_device(event)
                if ei.ei_device_has_capability(found, EI_DEVICE_CAP_KEYBOARD):
                    pending = ei.ei_device_ref(found)
            elif kind == EI_EVENT_DEVICE_RESUMED and pending:
                ei.ei_device_start_emulating(pending, sequence)
                sequence += 1
                device = pending
            ei.ei_event_unref(event)

    def key(code, down):
        ei.ei_device_keyboard_key(device, code, down)
        ei.ei_device_frame(device, ei.ei_now(context))
        ei.ei_dispatch(context)

    def tap(code):
        key(code, True)
        time.sleep(0.02)
        key(code, False)
        time.sleep(0.03)

    print("ready", flush=True)
    for line in sys.stdin:
        command, _, argument = line.strip().partition(" ")
        if command == "tap":
            tap(int(argument))
        elif command == "type":
            for letter in argument:
                if letter == " ":
                    tap(KEY_SPACE)
                    continue
                code = next(start + row.index(letter) for row, start in ROWS if letter in row)
                tap(code)
        else:
            sys.exit(f"unknown command: {command}")
        ei.ei_dispatch(context)
        print("ok", flush=True)
    del bus


if __name__ == "__main__":
    main()
