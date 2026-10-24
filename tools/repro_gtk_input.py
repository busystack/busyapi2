"""Trusted AB-only GtkTextView comparison; never packaged. System GTK/IM unchanged."""
import gi, time, json, sys

gi.require_version('Gtk','3.0');gi.require_version('Gdk','3.0')
from gi.repository import Gtk,Gdk
scroll = '--scroll' in sys.argv[1:]
window=Gtk.Window(title='BusyAPI trusted GTK input comparison')
window.set_default_size(900 if scroll else 800,700 if scroll else 400)
view=Gtk.TextView();view.set_monospace(True);view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
buffer=view.get_buffer();buffer.set_text('padding\n'*100+'AB\n'+'padding\n'*70 if scroll else 'AB')
if scroll:
 scroller=Gtk.ScrolledWindow();scroller.add(view);window.add(scroller)
else:window.add(view)
sequence=0
def log(event,data):
 global sequence
 sequence+=1
 print(json.dumps({'seq':sequence,'mono_ns':time.monotonic_ns(),'event':event,**data}),flush=True)
def key(widget,event):
 log('key',{'type':int(event.type),'keyval':event.keyval,'code':event.hardware_keycode,'state':int(event.state)})
 return False
view.connect('key-press-event',key);view.connect('key-release-event',key)
view.connect('preedit-changed',lambda v,text: log('preedit',{'characters':len(text)}))
buffer.connect('changed',lambda b: log('text',{'text':b.get_text(b.get_start_iter(),b.get_end_iter(),True),'offset':b.get_iter_at_mark(b.get_insert()).get_offset()}))
window.connect('destroy',Gtk.main_quit);window.show_all();view.grab_focus()
if scroll:
 from gi.repository import GLib
 def position():
  it=buffer.get_iter_at_line(100);it.forward_chars(2);buffer.place_cursor(it)
  view.scroll_to_iter(it,0,True,0,0.7)
  return False
 GLib.idle_add(position)
else:buffer.place_cursor(buffer.get_end_iter())
log('ready',{'pid':__import__('os').getpid(),**({'scroll':True,'characters':buffer.get_char_count()} if scroll else {'text':'AB'})})
Gtk.main()
