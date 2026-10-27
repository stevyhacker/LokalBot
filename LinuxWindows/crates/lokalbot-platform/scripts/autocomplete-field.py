#!/usr/bin/env python3
"""A GTK 3 window with a chat-like layout for autocomplete's live checks:
two messages above a multi-line reply field, a one-line subject and a
password field. Every change to the reply is printed as `REPLY <json>`, so a
test can see what an accept typed. Usage: autocomplete-field.py [title]
"""
import json
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

title = sys.argv[1] if len(sys.argv) > 1 else "Reply to Sarah"
window = Gtk.Window(title=title)
window.set_default_size(720, 420)
window.connect("destroy", Gtk.main_quit)

box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
box.set_border_width(16)
window.add(box)

for text in (
    "Sarah: The migration timeline we scoped yesterday still works for my team.",
    "Sarah: Daniel can start the database cutover on Thursday if you confirm today.",
):
    label = Gtk.Label(label=text, xalign=0)
    label.set_line_wrap(True)
    box.pack_start(label, False, False, 0)

subject = Gtk.Entry()
subject.set_placeholder_text("Subject")
box.pack_start(subject, False, False, 0)

password = Gtk.Entry()
password.set_visibility(False)
password.set_placeholder_text("Password")
box.pack_start(password, False, False, 0)

scroller = Gtk.ScrolledWindow()
scroller.set_hexpand(True)
scroller.set_vexpand(True)
reply = Gtk.TextView()
reply.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
reply.set_left_margin(6)
reply.set_top_margin(6)
scroller.add(reply)
box.pack_start(scroller, True, True, 0)


def changed(buffer):
    start, end = buffer.get_bounds()
    print("REPLY " + json.dumps(buffer.get_text(start, end, True)), flush=True)


reply.get_buffer().connect("changed", changed)
window.show_all()
GLib.idle_add(reply.grab_focus)
Gtk.main()
