"""Compare trusted AB native input on a temporary ordinary GTK/Flutter app.

Use system Python/GTK on X11. Arguments: TEMP_OUTPUT_DIR EXECUTABLE [ARG...].
The output directory must be new and outside the repository. COMPARE_IM chooses
ibus or gtk-im-context-simple for this child only. Diagnostic IBus sync modes
are inherited explicitly; this tool never changes user/system preferences.
The trusted reproducer logs AB-only text. Do not use it on project documents.
"""
import os,sys,pathlib,subprocess,time,json,ctypes,gi

gi.require_version('Gtk','3.0');gi.require_version('Gdk','3.0');gi.require_version('GdkX11','3.0')
from gi.repository import Gtk,Gdk,GdkX11,Gio,GLib
if len(sys.argv)<3:raise SystemExit(__doc__)
root=pathlib.Path(sys.argv[1]).resolve()
if not root.is_relative_to('/tmp') or root.exists():raise SystemExit('Choose a new /tmp output directory')
root.mkdir(parents=True)
exe=sys.argv[2:]
env=os.environ.copy();env['GTK_IM_MODULE']=os.environ.get('COMPARE_IM','ibus')
# Private XDG test state must not hide the running user's IBus socket. Merely
# mapping im-ibus.so is not proof that the provider is connected.
if env['GTK_IM_MODULE']=='ibus' and not env.get('IBUS_ADDRESS'):
 env['IBUS_ADDRESS']=subprocess.check_output(['ibus','address'],text=True).strip()
 if not env['IBUS_ADDRESS']:raise SystemExit('No running IBus service address')

for name,folder in [('XDG_CONFIG_HOME','config'),('XDG_CACHE_HOME','cache'),('XDG_STATE_HOME','state'),('XDG_DATA_HOME','data')]:
 (root/folder).mkdir(exist_ok=True);env[name]=str(root/folder)
log=(root/'app.log').open('w');app=None
xdo=os.environ.get('BUSYAPI_XDOTOOL','xdotool')
xenv=os.environ.copy()
def run(*a):return subprocess.check_output([xdo,*map(str,a)],env=xenv,text=True).strip()
proxy=Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SESSION,Gio.DBusProxyFlags.DO_NOT_AUTO_START,None,'org.gnome.ScreenSaver','/org/gnome/ScreenSaver','org.gnome.ScreenSaver',None)
def unlocked():
 if proxy.call_sync('GetActive',None,Gio.DBusCallFlags.NONE,1000,None).unpack()[0]:raise RuntimeError('LOCKED — no input sent')
 pointer=Gdk.Display.get_default().get_default_seat().get_pointer()
 state=Gdk.get_default_root_window().get_device_position(pointer)[3]
 blocked=(Gdk.ModifierType.SHIFT_MASK|Gdk.ModifierType.LOCK_MASK|Gdk.ModifierType.CONTROL_MASK|Gdk.ModifierType.MOD1_MASK|Gdk.ModifierType.MOD4_MASK|Gdk.ModifierType.SUPER_MASK|Gdk.ModifierType.META_MASK)
 if state&blocked:
  (root/'modifier-failure.txt').write_text(str(state)+'\n')
  raise RuntimeError('Desktop modifiers are active; no test input sent')

unlocked()
x=ctypes.CDLL('libX11.so.6');xt=ctypes.CDLL('libXtst.so.6')
x.XOpenDisplay.restype=ctypes.c_void_p
x.XStringToKeysym.argtypes=[ctypes.c_char_p];x.XStringToKeysym.restype=ctypes.c_ulong
x.XKeysymToKeycode.argtypes=[ctypes.c_void_p,ctypes.c_ulong];x.XKeysymToKeycode.restype=ctypes.c_uint
x.XFlush.argtypes=[ctypes.c_void_p]
xt.XTestFakeKeyEvent.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_int,ctypes.c_ulong]
d=x.XOpenDisplay(None)
def key(name):
 codes=[x.XKeysymToKeycode(d,x.XStringToKeysym(n.encode()))for n in name.split('+')]
 assert all(codes)
 for c in codes:xt.XTestFakeKeyEvent(d,c,1,0)
 for c in reversed(codes):xt.XTestFakeKeyEvent(d,c,0,0)
def pump(seconds):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  while GLib.MainContext.default().pending():GLib.MainContext.default().iteration(False)
  time.sleep(.005)
try:
 app=subprocess.Popen(exe,env=env,stdout=log,stderr=log)
 (root/'pid').write_text(str(app.pid))
 deadline=time.monotonic()+150;wid=None
 while time.monotonic()<deadline:
  if app.poll()is not None:raise RuntimeError('Application exited; inspect app.log')
  r=subprocess.run([xdo,'search','--pid',str(app.pid)],env=xenv,text=True,capture_output=True)
  for ident in r.stdout.split():
   w=GdkX11.X11Window.foreign_new_for_display(Gdk.Display.get_default(),int(ident))
   if w and w.is_viewable() and w.get_width()>400 and w.get_height()>250:wid=ident;break
  content=(root/'app.log').read_text()
  if wid and ('ORDINARY_READY' in content or '"event": "ready"'in content):break
  time.sleep(.1)
 else:raise RuntimeError('No ready painted owned window')
 unlocked();assert run('getwindowpid',wid)==str(app.pid)
 run('windowactivate','--sync',wid);run('windowfocus','--sync',wid)
 run('mousemove','--window',wid,100,20,'click',1)
 key('Control_L+End');x.XFlush(d);pump(.4)
 maps=pathlib.Path(f'/proc/{app.pid}/maps').read_text()
 (root/'maps.txt').write_text(maps)
 import hashlib
 identities={}
 for line in maps.splitlines():
  path=line.split()[-1]
  if any(name in path for name in ['libflutter_linux_gtk','im-ibus.so','libibus-1.0']):
   p=pathlib.Path(path)
   if p.is_file() and path not in identities:identities[path]=hashlib.sha256(p.read_bytes()).hexdigest()
 (root/'libraries.json').write_text(json.dumps(identities,indent=2)+'\n')
 clipboard=Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
 results=[]
 # Slow control, then one race and 100 repetitions, with no waits inside bursts.
 for label,repeat,gap in [('slow-control',1,.2),('burst-one',1,0),('burst-100',100,0)]:
  unlocked()
  actual_focus=run('getwindowfocus')
  if actual_focus!=wid:
   details=subprocess.run([xdo,'getwindowpid',actual_focus,'getwindowname',actual_focus],env=xenv,capture_output=True,text=True)
   (root/'focus-failure.txt').write_text('Expected '+str(wid)+'; actual '+str(actual_focus)+'\n'+details.stdout+details.stderr)
   raise RuntimeError('Owned focus changed; see focus-failure.txt')
  for _ in range(repeat):
   key('x')
   if gap:x.XFlush(d);pump(gap)
   key('BackSpace')
  x.XFlush(d);pump(1)
  clipboard.set_text('ORACLE_PENDING',-1)
  key('Control_L+a');key('Control_L+c');x.XFlush(d)
  text=None;until=time.monotonic()+5
  while time.monotonic()<until:
   pump(.05);text=clipboard.wait_for_text()
   if text is not None and text!='ORACLE_PENDING':break
  if text is None or text=='ORACLE_PENDING':
   # A failed oracle is not the field's text and must not be reported as a
   # demonstrated text-ordering failure. Stop before issuing another case.
   failure={'label':label,'repeat':repeat,'status':'unobserved',
            'error':'The full-text clipboard oracle did not complete'}
   (root/'unobserved.json').write_text(json.dumps(failure,indent=2)+'\n')
   raise RuntimeError(failure['error'])
  results.append({'label':label,'repeat':repeat,'inter_key_gap':gap,'text':text,'correct':text=='AB'})
  # Restore AB explicitly for the next independent sequence.
  key('BackSpace');x.XFlush(d);pump(.25)
  clipboard.set_text('AB',-1);key('Control_L+v');x.XFlush(d);pump(.4)
  key('Control_L+End');x.XFlush(d);pump(.15)
 print(json.dumps(results),flush=True)
 (root/'results.json').write_text(json.dumps({'environment':{k:env.get(k)for k in ['GTK_IM_MODULE','IBUS_ADDRESS','IBUS_ENABLE_SYNC_MODE','DISPLAY']},'exe':exe,'pid':app.pid,'window':int(wid),'cases':results},indent=2)+'\n')
finally:
 if app is not None:
  if app.poll()is None:app.terminate()
  try:app.wait(timeout=4)
  except subprocess.TimeoutExpired:app.kill();app.wait()

if not all(case['correct']for case in results):raise SystemExit(1)
