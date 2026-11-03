"""Built-in motion sensors on Apple Silicon MacBooks, read through undocumented IOKit HID services.

The IMU (a Bosch part on the logic board, in the base) shows up as AppleSPUHIDDevice services:
usage page 0xFF00, usage 3 = accelerometer, usage 9 = gyroscope. Each 22-byte input report holds
int32 Q16.16 x/y/z at offsets 6/10/14 (g and deg/s). The sensors only stream after their
AppleSPUHIDDriver services are woken with SensorPropertyReportingState/PowerState/ReportInterval.
The lid-angle sensor is usage page 0x20 / usage 0x8A; feature report 1 carries the angle in bytes 1-2.
Access is gated by the Input Monitoring permission, not root.
"""

import ctypes
import ctypes.util
import queue
import struct
import threading
import time

V = ctypes.c_void_p
_io = ctypes.cdll.LoadLibrary(ctypes.util.find_library("IOKit"))
_cf = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))
_cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))
_libc = ctypes.CDLL(ctypes.util.find_library("c"))

_io.IOHIDCheckAccess.restype = ctypes.c_uint32
_io.IOHIDCheckAccess.argtypes = [ctypes.c_uint32]
_io.IOHIDRequestAccess.restype = ctypes.c_bool
_io.IOHIDRequestAccess.argtypes = [ctypes.c_uint32]
_io.IOServiceMatching.restype = V
_io.IOServiceMatching.argtypes = [ctypes.c_char_p]
_io.IOServiceGetMatchingServices.argtypes = [ctypes.c_uint, V, ctypes.POINTER(ctypes.c_uint)]
_io.IOIteratorNext.restype = ctypes.c_uint
_io.IOIteratorNext.argtypes = [ctypes.c_uint]
_io.IORegistryEntryCreateCFProperty.restype = V
_io.IORegistryEntryCreateCFProperty.argtypes = [ctypes.c_uint, V, V, ctypes.c_uint]
_io.IORegistryEntrySetCFProperty.restype = ctypes.c_int
_io.IORegistryEntrySetCFProperty.argtypes = [ctypes.c_uint, V, V]
_io.IOHIDDeviceCreate.restype = V
_io.IOHIDDeviceCreate.argtypes = [V, ctypes.c_uint]
_io.IOHIDDeviceOpen.restype = ctypes.c_int
_io.IOHIDDeviceOpen.argtypes = [V, ctypes.c_int]
_io.IOHIDDeviceRegisterInputReportWithTimeStampCallback.argtypes = [V, V, ctypes.c_long, V, V]
_io.IOHIDDeviceScheduleWithRunLoop.argtypes = [V, V, V]
_io.IOHIDDeviceGetReport.restype = ctypes.c_int
_io.IOHIDDeviceGetReport.argtypes = [V, ctypes.c_int, ctypes.c_long, V, ctypes.POINTER(ctypes.c_long)]
_cf.CFStringCreateWithCString.restype = V
_cf.CFStringCreateWithCString.argtypes = [V, ctypes.c_char_p, ctypes.c_uint32]
_cf.CFNumberCreate.restype = V
_cf.CFNumberCreate.argtypes = [V, ctypes.c_int, V]
_cf.CFNumberGetValue.argtypes = [V, ctypes.c_int, V]
_cf.CFRunLoopGetCurrent.restype = V
_cf.CFRunLoopRunInMode.argtypes = [V, ctypes.c_double, ctypes.c_bool]
_cf.CFRelease.argtypes = [V]
_cg.CGEventSourceSecondsSinceLastEventType.restype = ctypes.c_double
_cg.CGEventSourceSecondsSinceLastEventType.argtypes = [ctypes.c_int32, ctypes.c_uint32]
_libc.mach_absolute_time.restype = ctypes.c_uint64


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_tb = _Timebase()
_libc.mach_timebase_info(ctypes.byref(_tb))
TICK_S = _tb.numer / _tb.denom / 1e9

_RUNLOOP_MODE = V.in_dll(_cf, "kCFRunLoopDefaultMode")
_REPORT_CB = ctypes.CFUNCTYPE(None, V, ctypes.c_int, V, ctypes.c_int, ctypes.c_uint32,
                              ctypes.POINTER(ctypes.c_uint8), ctypes.c_long, ctypes.c_uint64)

# IOHIDRequestType / IOHIDAccessType
LISTEN_EVENT = 1
ACCESS_NAMES = {0: "granted", 1: "denied", 2: "unknown"}

# CGEventType values that mean the user is typing, clicking or scrolling.
_INPUT_TYPES = {"typing": (10, 12), "click": (1, 3, 25), "scroll": (22,)}
_HID_SYSTEM_STATE = 1


def now():
    """Seconds on the same clock as the IMU report timestamps (mach_absolute_time)."""
    return _libc.mach_absolute_time() * TICK_S


def seconds_since_input():
    """Seconds since the last keyboard, click and scroll event anywhere on the system."""
    return {kind: min(_cg.CGEventSourceSecondsSinceLastEventType(_HID_SYSTEM_STATE, t) for t in types)
            for kind, types in _INPUT_TYPES.items()}


def listen_access():
    return ACCESS_NAMES.get(_io.IOHIDCheckAccess(LISTEN_EVENT), "unknown")


def request_listen_access():
    return _io.IOHIDRequestAccess(LISTEN_EVENT)


def _cfstr(text):
    return _cf.CFStringCreateWithCString(None, text.encode(), 0x08000100)


def _cfnum(value):
    c = ctypes.c_int32(value)
    return _cf.CFNumberCreate(None, 3, ctypes.byref(c))


def _int_prop(service, key):
    name = _cfstr(key)
    ref = _io.IORegistryEntryCreateCFProperty(service, name, None, 0)
    _cf.CFRelease(name)
    if not ref:
        return None
    v = ctypes.c_long()
    _cf.CFNumberGetValue(ref, 4, ctypes.byref(v))
    _cf.CFRelease(ref)
    return v.value


def _services(class_name):
    it = ctypes.c_uint()
    _io.IOServiceGetMatchingServices(0, _io.IOServiceMatching(class_name), ctypes.byref(it))
    out = []
    while True:
        s = _io.IOIteratorNext(it.value)
        if not s:
            return out
        out.append(s)


class Sensors:
    """Streams accelerometer and gyroscope reports into a queue and polls the lid angle."""

    def __init__(self, report_interval_us=1000):
        self.samples = queue.SimpleQueue()  # (kind, t_seconds, x, y, z)
        self.lid_angle = None
        self.found = {"accel": False, "gyro": False, "lid": False}
        self.error = None
        self._interval = report_interval_us
        self._keep = []  # ctypes callbacks and report buffers must outlive the run loop

    def start(self):
        threading.Thread(target=self._run, name="sensors", daemon=True).start()

    def _report_callback(self, kind):
        put = self.samples.put

        def on_report(ctx, result, sender, rtype, rid, report, length, ts):
            if length == 22:
                x, y, z = struct.unpack_from("<iii", ctypes.string_at(report, 22), 6)
                put((kind, ts * TICK_S, x / 65536.0, y / 65536.0, z / 65536.0))

        return _REPORT_CB(on_report)

    def _run(self):
        try:
            lid = self._open()
        except Exception as e:  # keep the GUI alive and show the reason
            self.error = f"{type(e).__name__}: {e}"
            return
        loop = _cf.CFRunLoopGetCurrent()
        buf = (ctypes.c_uint8 * 8)()
        while True:
            _cf.CFRunLoopRunInMode(_RUNLOOP_MODE, 0.05, False)
            if lid:
                n = ctypes.c_long(8)
                if _io.IOHIDDeviceGetReport(lid, 2, 1, buf, ctypes.byref(n)) == 0 and n.value >= 3:
                    self.lid_angle = buf[1] | buf[2] << 8
        del loop

    def _open(self):
        for driver in _services(b"AppleSPUHIDDriver"):
            for key, value in (("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1),
                               ("ReportInterval", self._interval)):
                name, num = _cfstr(key), _cfnum(value)
                _io.IORegistryEntrySetCFProperty(driver, name, num)
                _cf.CFRelease(name)
                _cf.CFRelease(num)
        loop = _cf.CFRunLoopGetCurrent()
        lid = None
        for dev in _services(b"AppleSPUHIDDevice"):
            page, usage = _int_prop(dev, "PrimaryUsagePage"), _int_prop(dev, "PrimaryUsage")
            if (page, usage) == (0x20, 0x8A) and lid is None:
                handle = _io.IOHIDDeviceCreate(None, dev)
                if handle and _io.IOHIDDeviceOpen(handle, 0) == 0:
                    lid = handle
                    self.found["lid"] = True
                continue
            kind = {(0xFF00, 3): "accel", (0xFF00, 9): "gyro"}.get((page, usage))
            if not kind or self.found[kind] or _int_prop(dev, "MaxInputReportSize") != 22:
                continue
            handle = _io.IOHIDDeviceCreate(None, dev)
            if not handle or _io.IOHIDDeviceOpen(handle, 0) != 0:
                continue
            buf = ctypes.create_string_buffer(4096)
            cb = self._report_callback(kind)
            self._keep += [handle, buf, cb]
            _io.IOHIDDeviceRegisterInputReportWithTimeStampCallback(handle, buf, 4096, cb, None)
            _io.IOHIDDeviceScheduleWithRunLoop(handle, loop, _RUNLOOP_MODE)
            self.found[kind] = True
        if not (self.found["accel"] or self.found["gyro"]):
            raise RuntimeError("no IMU found (needs an M2-or-later MacBook, or M1 Pro/Max)")
        return lid


if __name__ == "__main__":
    s = Sensors()
    s.start()
    time.sleep(2)
    counts = {}
    while not s.samples.empty():
        k = s.samples.get()[0]
        counts[k] = counts.get(k, 0) + 1
    print("access:", listen_access(), "found:", s.found, "error:", s.error,
          "samples in ~2s:", counts, "lid:", s.lid_angle, "input:", seconds_since_input())
