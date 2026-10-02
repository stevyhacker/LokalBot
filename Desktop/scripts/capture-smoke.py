#!/usr/bin/env python3
"""Run with dbus-run-session on remote/hosted Ubuntu. Only fictional GTK fields."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]
LIB=ROOT/'.eval'/('capture-'+str(time.time_ns()))
CLI=ROOT/'target/debug/lokalbot-desktop-cli'
env={k:v for k,v in os.environ.items() if k!='OPENROUTER_API_KEY'}
xvfb=subprocess.Popen(['Xvfb','-displayfd','1','-screen','0','1000x600x24','-nolisten','tcp'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
env['DISPLAY']=':'+xvfb.stdout.readline().strip()
runtime=ROOT/'.eval/capture-runtime';runtime.mkdir(mode=0o700,exist_ok=True)
env.update(XDG_RUNTIME_DIR=str(runtime),NO_AT_BRIDGE='0',GTK_MODULES='gail:atk-bridge',GDK_BACKEND='x11',GIO_USE_VFS='local',LOKALBOT_STORAGE_ROOT=str(LIB))
env.pop('WAYLAND_DISPLAY',None)
fixture='''
import gi,sys
gi.require_version('Gtk','3.0')
from gi.repository import Gtk
w=Gtk.Window(title='LokalBot synthetic focus fixture');w.set_default_size(800,400)
box=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=20);w.add(box)
box.pack_start(Gtk.Label(label='Fictional harmless visible text'),False,False,0)
e=Gtk.Entry();e.set_text('Fictional field one');box.pack_start(e,False,False,0)
if len(sys.argv)>1:e.set_visibility(False)
other=Gtk.Entry();other.set_text('Fictional field two');box.pack_start(other,False,False,0)
w.show_all();e.grab_focus();Gtk.main()
'''
children=[]
def run(*args,check=True):
    return subprocess.run(args,env=env,text=True,capture_output=True,check=check,timeout=10)
def moments():
    with sqlite3.connect(LIB/'desktop.sqlite') as db:
        return [json.loads(row[0]) for row in db.execute('SELECT data FROM moments')]
try:
    run(str(CLI),'configure','--screen-text','true','--pixels','true')
    for secure in [False,True]:
        child=subprocess.Popen(['python3','-c',fixture]+(['secure'] if secure else []),env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);children.append(child)
        time.sleep(2)
        wid=run('xdotool','search','--name','LokalBot synthetic focus fixture').stdout.splitlines()[-1]
        run('xdotool','windowfocus','--sync',wid)
        time.sleep(.5)
        observation=json.loads(run('python3',str(ROOT/'helpers/focus_probe.py'),'--text').stdout)
        assert observation['observation']['field'] and observation['observation']['focus_verified']
        assert observation['observation']['secure']==secure
        captured=run(str(CLI),'capture-screen',check=False)
        if secure:
            assert captured.returncode!=0 and len(moments())==1
            assert 'Fictional field one' not in observation['text']
        else:
            assert captured.returncode==0,captured.stderr
            saved=moments()[0]
            assert 'Fictional harmless' in saved['text']
            encrypted=LIB/saved['pixels']
            assert encrypted.is_file() and not encrypted.read_bytes().startswith(b'\x89PNG')
            first=observation['observation']['field']
            run('xdotool','key','Tab');time.sleep(.25)
            after=json.loads(run('python3',str(ROOT/'helpers/focus_probe.py'),'--text').stdout)
            assert after['observation']['window']==observation['observation']['window']
            assert after['observation']['field']!=first
        child.terminate();child.wait(timeout=5)
    report={'passed':['visible accessibility text','encrypted focused pixels','focused-field identity change','password field refused with no persistence'],'synthetic_only':True}
    (ROOT/'.eval/capture-report.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report,indent=2))
finally:
    for child in children:
        if child.poll() is None:child.terminate();child.wait(timeout=5)
    xvfb.terminate();xvfb.wait(timeout=5)
