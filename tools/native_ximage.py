"""Bounded direct X11 crop reads for the development-only paint observer."""
import ctypes


class _Image(ctypes.Structure):
    _fields_ = [('width', ctypes.c_int), ('height', ctypes.c_int),
                ('xoffset', ctypes.c_int), ('format', ctypes.c_int),
                ('data', ctypes.c_void_p), ('byte_order', ctypes.c_int),
                ('bitmap_unit', ctypes.c_int), ('bitmap_bit_order', ctypes.c_int),
                ('bitmap_pad', ctypes.c_int), ('depth', ctypes.c_int),
                ('bytes_per_line', ctypes.c_int), ('bits_per_pixel', ctypes.c_int),
                ('red_mask', ctypes.c_ulong), ('green_mask', ctypes.c_ulong),
                ('blue_mask', ctypes.c_ulong), ('obdata', ctypes.c_void_p)]


def rgb32(raw, width, height, stride, byte_order):
    if width <= 0 or height <= 0 or stride < width * 4 or len(raw) != stride * height:
        raise RuntimeError('Invalid XImage storage')
    if byte_order not in (0, 1):
        raise RuntimeError('Unsupported XImage byte order')
    packed = b''.join(raw[y * stride:y * stride + width * 4]
                      for y in range(height))
    result = bytearray(width * height * 3)
    for channel, source in enumerate((2, 1, 0) if byte_order == 0 else (1, 2, 3)):
        result[channel::3] = packed[source::4]
    return bytes(result), 3


class XImageReader:
    def __init__(self, library, display, window):
        self.x, self.display, self.window = library, display, window
        self.x.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
            ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint,
            ctypes.c_ulong, ctypes.c_int]
        self.x.XGetImage.restype = ctypes.POINTER(_Image)
        self.x.XDestroyImage.argtypes = [ctypes.POINTER(_Image)]

    def size(self):
        root = ctypes.c_ulong()
        left, top = ctypes.c_int(), ctypes.c_int()
        width, height, border, depth = [ctypes.c_uint() for _ in range(4)]
        self.x.XGetGeometry.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
            ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_int), *([ctypes.POINTER(ctypes.c_uint)] * 4)]
        if not self.x.XGetGeometry(self.display, self.window, ctypes.byref(root),
                ctypes.byref(left), ctypes.byref(top), ctypes.byref(width),
                ctypes.byref(height), ctypes.byref(border), ctypes.byref(depth)):
            raise RuntimeError('Native window geometry is unavailable')
        return width.value, height.value

    def pixels(self, rect):
        _, _, width, height = rect
        if width * height > 1024 * 1024:
            raise RuntimeError('Use a bounded text observation crop')
        image = self.x.XGetImage(self.display, self.window, *rect,
                                ctypes.c_ulong(-1).value, 2)
        if not image:
            raise RuntimeError('Native window stopped providing pixels')
        try:
            info = image.contents
            if (info.width, info.height) != (width, height) or \
                    info.bits_per_pixel != 32 or \
                    (info.red_mask, info.green_mask, info.blue_mask) != \
                    (0xff0000, 0xff00, 0xff) or \
                    info.bytes_per_line < width * 4 or \
                    info.bytes_per_line * height > 8 * 1024 * 1024:
                raise RuntimeError('Unsupported XImage visual or storage')
            raw = ctypes.string_at(info.data, info.bytes_per_line * height)
            return rgb32(raw, width, height, info.bytes_per_line, info.byte_order)
        finally:
            self.x.XDestroyImage(image)
