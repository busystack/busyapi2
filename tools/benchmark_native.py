"""Observe actual Source and Reference paint on an owned Linux test window.

Run with /usr/bin/python3 (PyGObject/Gdk 3), X11/XWayland and libXtst. Prepare a
trusted temporary fixture in Source with Preview, put the caret inside its API
 title, and provide crops covering source text and the native Reference title.
The emitted values include XTest dispatch and raster observation; they are not
physical monitor/photon measurements. No app model or timing threshold is changed.
"""
import argparse, ctypes, json, math, pathlib, platform, time, hashlib, statistics
import gi

gi.require_version('Gdk', '3.0')
gi.require_version('GdkX11', '3.0')
from gi.repository import Gdk, GdkX11, Gio, GLib
from native_focus import belongs_to_window

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('window', type=int)
parser.add_argument('fixture', type=pathlib.Path)
parser.add_argument('--source', required=True, help='x,y,width,height')
parser.add_argument('--reference', required=True, help='x,y,width,height')
parser.add_argument('--source-exclude', help='Validated union of before/after caret rectangles: x,y,width,height')
parser.add_argument('--samples', type=int, default=20)
parser.add_argument('--mode', choices=['profile', 'release', 'debug'], required=True)
parser.add_argument('--warmup', type=int, default=4, help='Even number of unmeasured edits, at least four')
parser.add_argument('--readback', choices=['ximage','gdk'], default='ximage',
                    help='Direct physical X11 crop (default), or retained Cairo/GDK observation')
parser.add_argument('--source-observation', choices=['damage', 'paired'], default='damage',
                    help='Paired diagnosis also polls Source content every 2 ms; keeps damage timing separately')
parser.add_argument('--detector', choices=['templates','legacy'], default='templates')
parser.add_argument('--legacy-readback', action='store_true',
                    help='Reproduce continuous competing Reference reads for observer diagnosis')
args = parser.parse_args()
if args.warmup < 4 or args.warmup % 2:
    parser.error('Warmup must be even and at least four')
fixture_identity = hashlib.sha256(args.fixture.read_bytes()).hexdigest()
if not args.fixture.resolve().is_relative_to('/tmp'):
    parser.error('Use a trusted temporary fixture; this test enters source text')
if not 2 <= args.samples <= 100 or args.samples % 2:
    parser.error('Use an even sample count between 2 and 100 to restore the original text')
# Do not send measurement input through a locked session. Other desktop
# environments may not provide this optional GNOME interface.
screensaver = None
try:
    screensaver = Gio.DBusProxy.new_for_bus_sync(
        Gio.BusType.SESSION, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None,
        'org.gnome.ScreenSaver', '/org/gnome/ScreenSaver',
        'org.gnome.ScreenSaver', None)
    if screensaver.get_name_owner() and screensaver.call_sync(
            'GetActive', None, Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]:
        parser.error('Desktop is locked; unlock it before native sampling')
except GLib.Error:
    pass

window = GdkX11.X11Window.foreign_new_for_display(Gdk.Display.get_default(), args.window)
if not window or not window.is_viewable():
    parser.error('An owned mapped native test window is required')

x = ctypes.CDLL('libX11.so.6')
test = ctypes.CDLL('libXtst.so.6')
x.XOpenDisplay.restype = ctypes.c_void_p
x.XStringToKeysym.argtypes = [ctypes.c_char_p]
x.XStringToKeysym.restype = ctypes.c_ulong
x.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
x.XKeysymToKeycode.restype = ctypes.c_uint
x.XFlush.argtypes = [ctypes.c_void_p]
x.XCloseDisplay.argtypes = [ctypes.c_void_p]
x.XPending.argtypes = [ctypes.c_void_p]
x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
x.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
x.XGetInputFocus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int)]
x.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong),
                        ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_uint)]
x.XFree.argtypes = [ctypes.c_void_p]
test.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
display = x.XOpenDisplay(None)
damage = ctypes.CDLL('libXdamage.so.1')
damage.XDamageQueryExtension.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
damage.XDamageCreate.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int]
damage.XDamageCreate.restype = ctypes.c_ulong
damage.XDamageSubtract.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
damage.XDamageDestroy.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
event_base, error_base = ctypes.c_int(), ctypes.c_int()
if not damage.XDamageQueryExtension(display, ctypes.byref(event_base), ctypes.byref(error_base)):
    parser.error('XDamage is required for native paint notification')
damage_id = damage.XDamageCreate(display, args.window, 3)
class Rectangle(ctypes.Structure):
    _fields_ = [('x', ctypes.c_short), ('y', ctypes.c_short),
                ('width', ctypes.c_ushort), ('height', ctypes.c_ushort)]
class DamageEvent(ctypes.Structure):
    _fields_ = [('type', ctypes.c_int), ('serial', ctypes.c_ulong),
                ('send_event', ctypes.c_int), ('display', ctypes.c_void_p),
                ('drawable', ctypes.c_ulong), ('damage', ctypes.c_ulong),
                ('level', ctypes.c_int), ('more', ctypes.c_int),
                ('timestamp', ctypes.c_ulong), ('area', Rectangle),
                ('geometry', Rectangle)]
class PropertyEvent(ctypes.Structure):
    _fields_ = [('type', ctypes.c_int), ('serial', ctypes.c_ulong),
                ('send_event', ctypes.c_int), ('display', ctypes.c_void_p),
                ('window', ctypes.c_ulong), ('atom', ctypes.c_ulong),
                ('timestamp', ctypes.c_ulong), ('state', ctypes.c_int)]
class XEvent(ctypes.Union):
    _fields_ = [('type', ctypes.c_int), ('damage', DamageEvent),
                ('property', PropertyEvent), ('pad', ctypes.c_long * 24)]

x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x.XDefaultRootWindow.restype = ctypes.c_ulong
x.XCreateSimpleWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                  ctypes.c_int, ctypes.c_int, ctypes.c_uint,
                                  ctypes.c_uint, ctypes.c_uint,
                                  ctypes.c_ulong, ctypes.c_ulong]
x.XCreateSimpleWindow.restype = ctypes.c_ulong
x.XSelectInput.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_long]
x.XChangeProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
                              ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
                              ctypes.c_void_p, ctypes.c_int]
x.XDestroyWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
# An unmapped window owned by the harness supplies a server timestamp without
# changing any property, input selection or setting of the application window.
clock_window = x.XCreateSimpleWindow(display, x.XDefaultRootWindow(display),
                                    0, 0, 1, 1, 0, 0, 0)
x.XSelectInput(display, clock_window, 1 << 22)

def calibrate_clock():
    start = time.perf_counter_ns()/1e6
    x.XChangeProperty(display, clock_window, 19, 19, 8, 0, b'1', 1)
    x.XFlush(display)
    while time.perf_counter_ns()/1e6-start < 1000:
        while x.XPending(display):
            event = XEvent()
            x.XNextEvent(display, ctypes.byref(event))
            if event.type == 28 and event.property.window == clock_window:
                finish = time.perf_counter_ns()/1e6
                stamp = event.property.timestamp
                return start-stamp, finish-stamp
        time.sleep(.0005)
    raise RuntimeError('X server clock calibration did not complete')

def paint_event():
    notified = None
    while x.XPending(display):
        event = XEvent()
        x.XNextEvent(display, ctypes.byref(event))
        if event.type == event_base.value and event.damage.damage == damage_id:
            notified = event.damage.timestamp
    if notified is not None:
        damage.XDamageSubtract(display, damage_id, 0, 0)
        x.XFlush(display)
    return notified
codes = [x.XKeysymToKeycode(display, x.XStringToKeysym(key))
         for key in (b'x', b'BackSpace')]

def crop(value):
    numbers = tuple(map(int, value.split(',')))
    if len(numbers) != 4 or min(numbers) < 0:
        parser.error('Crops must be x,y,width,height')
    return numbers

source, reference = crop(args.source), crop(args.reference)
source_ignored = set()
if args.source_exclude:
    ex, ey, ew, eh = crop(args.source_exclude)
    sx, sy, sw, sh = source
    source_ignored = {y*sw+x for y in range(sh) for x in range(sw)
                      if ex <= x+sx < ex+ew and ey <= y+sy < ey+eh}

from native_ximage import XImageReader
reader = XImageReader(x, display, args.window)
window_physical_size = reader.size()
readback_cost = []
def gdk_pixels(rect):
    scale = window.get_scale_factor()
    if any(v % scale for v in rect):
        raise RuntimeError('GDK comparison crops must align to its backing scale')
    pixbuf = Gdk.pixbuf_get_from_window(window, *(v // scale for v in rect))
    if pixbuf is None:
        raise RuntimeError('Native window stopped providing paint')
    channels = pixbuf.get_n_channels()
    data, stride = pixbuf.get_pixels(), pixbuf.get_rowstride()
    width = pixbuf.get_width() * channels
    # Ignore row padding; it is not an observed pixel.
    result = b''.join(data[y*stride:y*stride+width]
                    for y in range(pixbuf.get_height())), channels
    return result

def pixels(rect):
    begun = time.perf_counter_ns()
    result = reader.pixels(rect) if args.readback == 'ximage' else gdk_pixels(rect)
    if len(readback_cost) < 100000:
        readback_cost.append((time.perf_counter_ns()-begun)/1e6)
    return result

def changed(before, after, source_text=False):
    a, channels = before
    b, _ = after
    if a == b:
        return False
    count = 0
    for i in range(0, min(len(a), len(b)), channels):
        if a[i:i+3] == b[i:i+3]:
            continue
        # Source string glyphs are red in the adapted syntax palette. Excluding
        # accent-colored caret pixels prevents blink/focus from counting as input.
        if source_text and not any(p[0] > p[1]+30 and p[1] < 150 and p[2] < 150
                                   for p in (a[i:i+3], b[i:i+3])):
            continue
        count += 1
        if count >= 12:
            return True
    return False

from native_paint_detector import templates, matches

observations, warm, warm_stability = [], [], []
failure = None
def parent_of(child):
    root, parent, children, count = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_void_p(), ctypes.c_uint()
    status = x.XQueryTree(display, child, ctypes.byref(root), ctypes.byref(parent),
                         ctypes.byref(children), ctypes.byref(count))
    if children.value:
        x.XFree(children)
    return parent.value if status else None

def require_focus():
    focused, revert = ctypes.c_ulong(), ctypes.c_int()
    x.XGetInputFocus(display, ctypes.byref(focused), ctypes.byref(revert))
    if not belongs_to_window(focused.value, args.window, parent_of):
        raise RuntimeError(f'Window focus changed (focused={focused.value}, owned={args.window}); discard this uncontrolled measurement')

def require_unlocked():
    if screensaver and screensaver.get_name_owner() and screensaver.call_sync(
            'GetActive', None, Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]:
        raise RuntimeError('Desktop locked; sampling stopped without sending input')

try:
    # Measure idle observation overhead rather than subtracting an assumed cost.
    for _ in range(100):
        pixels(source); pixels(reference)
    idle_readback_cost = list(readback_cost)
    source_template = reference_template = None
    for sample in range(args.warmup + args.samples):
        require_unlocked()
        require_focus()
        before_source, before_reference = pixels(source), pixels(reference)
        if sample < args.warmup:
            warm.append((before_source, before_reference))
            # Observe the same authored state across a caret blink. Without this
            # control, phase-aligned warmups can mistake its lit pixels for text.
            time.sleep(.6)
            require_focus()
            warm_stability.append((pixels(source), pixels(reference)))
        if sample == args.warmup and args.detector == 'templates':
            source_template = templates([v[0] for v in warm], [v[0] for v in warm_stability], source_ignored)
            reference_template = templates([v[1] for v in warm], [v[1] for v in warm_stability])
        state = sample % 2
        if source_template is not None and (not matches(before_source, source_template, state)
                or not matches(before_reference, reference_template, state)):
            raise RuntimeError('Visible content no longer matches the expected pre-input state: source=' + str(matches(before_source, source_template, state)) + ' reference=' + str(matches(before_reference, reference_template, state)))
        clock_lower, clock_upper = calibrate_clock()
        damage.XDamageSubtract(display, damage_id, 0, 0)
        x.XSync(display, 0)
        paint_event()
        require_unlocked()
        require_focus()
        wall_start = time.time_ns() // 1000
        start = time.perf_counter_ns()
        code = codes[state]
        test.XTestFakeKeyEvent(display, code, 1, 0)
        test.XTestFakeKeyEvent(display, code, 0, 0)
        x.XFlush(display)
        source_ms = reference_ms = damage_ms = paint_lower = paint_upper = None
        source_poll_ms = None
        next_source_read = start
        next_reference_read = start
        while time.perf_counter_ns()-start < 10_000_000_000:
            require_focus()
            timestamp = paint_event()
            current = None
            if (args.source_observation == 'paired' and source_poll_ms is None
                    and time.perf_counter_ns() >= next_source_read):
                current = pixels(source)
                next_source_read = time.perf_counter_ns() + 2_000_000
                if (matches(current, source_template, 1-state) if source_template
                        else changed(before_source, current, True)):
                    source_poll_ms = (time.perf_counter_ns()-start)/1e6
            if timestamp is not None and source_ms is None:
                notified_ms = (time.perf_counter_ns()-start)/1e6
                current = current if current is not None else pixels(source)
                detected = (matches(current, source_template, 1-state)
                            if source_template else changed(before_source, current, True))
                if detected:
                    damage_ms = notified_ms
                    paint_lower = timestamp+clock_lower-start/1e6
                    paint_upper = timestamp+clock_upper-start/1e6
                    source_ms = (time.perf_counter_ns()-start)/1e6
            # Source is event-driven. Do not continually read back the Preview
            # surface while waiting for its text frame: that synchronous GPU/X11
            # work competes with the response being measured. Reference normally
            # follows analysis, and remains observed with its actual read finish
            # timestamp, including the declared polling interval (no subtraction).
            now = time.perf_counter_ns()
            if reference_ms is None and (args.legacy_readback or
                    source_ms is not None and now >= next_reference_read):
                current = pixels(reference)
                next_reference_read = time.perf_counter_ns() + 16_000_000
                detected = (matches(current, reference_template, 1-state)
                            if reference_template else changed(before_reference, current))
                if detected:
                    reference_ms = (time.perf_counter_ns()-start)/1e6
            if source_ms is not None and reference_ms is not None:
                break
            time.sleep(.002)
        if source_ms is None or reference_ms is None:
            raise RuntimeError('Intended input or Reference title did not paint within the observation bound')
        require_unlocked()
        require_focus()
        if sample >= args.warmup:
            observations.append({'dispatchWallUs':wall_start,
                                 'inputDamageMs':damage_ms,
                                 'serverPaintLowerMs':paint_lower,
                                 'serverPaintUpperMs':paint_upper,
                                 'inputPaintMs':source_ms, 'referencePaintMs':reference_ms})
            if args.source_observation == 'paired':
                observations[-1]['inputPolledPaintMs'] = source_poll_ms
        # Fixed sampling: 4 warmups, 100 edits per run, 100 ms after observed
        # Reference completion. Burst/overlap tests are separate workloads.
        time.sleep(.1 if sample >= args.warmup else .7)

except Exception as error:
    failure = str(error)
finally:
    damage.XDamageDestroy(display, damage_id)
    x.XDestroyWindow(display, clock_window)
    x.XCloseDisplay(display)

def summary(values):
    ordered = sorted(values)
    if not ordered:
        return {'count': 0, 'p50': None, 'p95': None, 'max': None}
    return {'count': len(ordered), 'p50': statistics.median(ordered),
            'p95': ordered[math.ceil(len(ordered)*.95)-1], 'max': max(ordered)}

print(json.dumps({'version':3, 'status':'failed' if failure else 'complete',
    'error':failure, 'mode':args.mode, 'fixture':str(args.fixture),
    'fixtureBytes':args.fixture.stat().st_size, 'fixtureSha256':fixture_identity,
    'machine':platform.uname()._asdict(), 'loadAverage':__import__('os').getloadavg(),
    'display':Gdk.Display.get_default().get_name(),
    'windowPhysicalSize':window_physical_size,
    'observerLogicalWindowSize':[window.get_width(),window.get_height()],
    'observerGdkScale':window.get_scale_factor(), 'crops':{'source':source,'reference':reference},
    'focusCheck':'owned-frame-or-bounded-GTK-child',
    'warmup':args.warmup, 'detector':args.detector, 'readback':args.readback,
    'referenceReadback': 'legacy-continuous' if args.legacy_readback else 'after-source-16ms',
    'sourceExcludedRectangle':args.source_exclude,
    'sourceObservation':args.source_observation,
    'stableSourcePixels':len(source_template[0])//3 if source_template else None,
    'stableReferencePixels':len(reference_template[0])//3 if reference_template else None,
    'idleReadbackMs':summary(idle_readback_cost), 'readbackMs':summary(readback_cost),
    'samples':observations,
    'statistics':{key:summary([v[key] for v in observations if v.get(key) is not None]) for key in
        ['inputDamageMs','serverPaintUpperMs','inputPaintMs','referencePaintMs'] +
        (['inputPolledPaintMs'] if args.source_observation == 'paired' else [])}}, indent=2))
if failure:
    raise RuntimeError(failure)
