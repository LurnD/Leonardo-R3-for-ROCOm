"""
Roco hardware HID host.

Pairs with the leonardo_roco.ino firmware running on an Arduino Leonardo (R3).
Replaces the old AutoHotkey scripts: all keyboard/mouse output is physically
emitted by the Leonardo as a real USB HID device. This host only:
  * watches which window is in the foreground (Win32 GetForegroundWindow)
  * computes coordinates / parameters
  * pushes plain-text command lines over USB serial to the Leonardo
  * exposes a small Tk GUI and two global hotkeys (Ctrl+- / Ctrl+=)

Dependencies (Python 3.10+):
  pip install pyserial

Windows only (uses user32.dll for window queries and hotkeys).
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wintypes
import json
import os
import queue
import random
import sys
import threading
import time
import tkinter as tk
from dataclasses import dataclass, asdict, field
from tkinter import ttk, messagebox
from typing import Callable, Optional

import serial
import serial.tools.list_ports


# ===== Win32 wrappers =================================================

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

try:
    user32.SetProcessDPIAware()
except Exception:
    pass

GetForegroundWindow = user32.GetForegroundWindow
GetForegroundWindow.restype = wintypes.HWND

GetWindowThreadProcessId = user32.GetWindowThreadProcessId
GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
GetWindowThreadProcessId.restype = wintypes.DWORD

GetClientRect = user32.GetClientRect
GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
GetClientRect.restype = wintypes.BOOL

ClientToScreen = user32.ClientToScreen
ClientToScreen.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.POINT)]
ClientToScreen.restype = wintypes.BOOL

GetCursorPos = user32.GetCursorPos
GetCursorPos.argtypes = [ctypes.POINTER(wintypes.POINT)]
GetCursorPos.restype = wintypes.BOOL

GetSystemMetrics = user32.GetSystemMetrics
GetSystemMetrics.argtypes = [ctypes.c_int]
GetSystemMetrics.restype = ctypes.c_int

EnumWindows = user32.EnumWindows
WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
EnumWindows.argtypes = [WNDENUMPROC, wintypes.LPARAM]
EnumWindows.restype = wintypes.BOOL

IsWindowVisible = user32.IsWindowVisible
IsWindowVisible.argtypes = [wintypes.HWND]
IsWindowVisible.restype = wintypes.BOOL

OpenProcess = kernel32.OpenProcess
OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
OpenProcess.restype = wintypes.HANDLE

CloseHandle = kernel32.CloseHandle
CloseHandle.argtypes = [wintypes.HANDLE]
CloseHandle.restype = wintypes.BOOL

QueryFullProcessImageNameW = kernel32.QueryFullProcessImageNameW
QueryFullProcessImageNameW.argtypes = [
    wintypes.HANDLE,
    wintypes.DWORD,
    wintypes.LPWSTR,
    ctypes.POINTER(wintypes.DWORD),
]
QueryFullProcessImageNameW.restype = wintypes.BOOL

PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

# Hotkeys
RegisterHotKey = user32.RegisterHotKey
RegisterHotKey.argtypes = [wintypes.HWND, ctypes.c_int, wintypes.UINT, wintypes.UINT]
RegisterHotKey.restype = wintypes.BOOL
UnregisterHotKey = user32.UnregisterHotKey
UnregisterHotKey.argtypes = [wintypes.HWND, ctypes.c_int]
UnregisterHotKey.restype = wintypes.BOOL
GetMessageW = user32.GetMessageW
GetMessageW.argtypes = [ctypes.POINTER(wintypes.MSG), wintypes.HWND, wintypes.UINT, wintypes.UINT]
GetMessageW.restype = ctypes.c_int
PostThreadMessageW = user32.PostThreadMessageW
PostThreadMessageW.argtypes = [wintypes.DWORD, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
PostThreadMessageW.restype = wintypes.BOOL
GetCurrentThreadId = kernel32.GetCurrentThreadId
GetCurrentThreadId.restype = wintypes.DWORD

MOD_ALT = 0x0001
MOD_CONTROL = 0x0002
MOD_SHIFT = 0x0004
MOD_NOREPEAT = 0x4000
WM_HOTKEY = 0x0312
WM_QUIT = 0x0012

# Virtual-key codes for the original AHK hotkeys on a US layout:
VK_OEM_MINUS = 0xBD   # the "-" key (Ctrl+-)
VK_OEM_PLUS = 0xBB    # the "=" key (Ctrl+=)

SM_CXSCREEN = 0
SM_CYSCREEN = 1


def get_screen_size() -> tuple[int, int]:
    return (GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN))


def get_foreground_process_name() -> Optional[str]:
    hwnd = GetForegroundWindow()
    if not hwnd:
        return None
    pid = wintypes.DWORD()
    GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    if not pid.value:
        return None
    handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
    if not handle:
        return None
    try:
        buf = ctypes.create_unicode_buffer(520)
        size = wintypes.DWORD(len(buf))
        if not QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
            return None
        return os.path.basename(buf.value)
    finally:
        CloseHandle(handle)


def find_window_by_process(exe_name: str) -> Optional[int]:
    target = exe_name.lower()
    found: list[int] = []

    @WNDENUMPROC
    def _cb(hwnd, _lparam):
        if not IsWindowVisible(hwnd):
            return True
        pid = wintypes.DWORD()
        GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if not pid.value:
            return True
        handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
        if not handle:
            return True
        try:
            buf = ctypes.create_unicode_buffer(520)
            size = wintypes.DWORD(len(buf))
            if QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                if os.path.basename(buf.value).lower() == target:
                    found.append(hwnd)
                    return False
        finally:
            CloseHandle(handle)
        return True

    EnumWindows(_cb, 0)
    return found[0] if found else None


def client_center_on_screen(hwnd: int) -> Optional[tuple[int, int]]:
    rect = wintypes.RECT()
    if not GetClientRect(hwnd, ctypes.byref(rect)):
        return None
    pt = wintypes.POINT(rect.right // 2, rect.bottom // 2)
    if not ClientToScreen(hwnd, ctypes.byref(pt)):
        return None
    return (pt.x, pt.y)


def cursor_pos() -> tuple[int, int]:
    pt = wintypes.POINT()
    GetCursorPos(ctypes.byref(pt))
    return (pt.x, pt.y)


def pixel_to_hid(x: int, y: int, screen_w: int, screen_h: int) -> tuple[int, int]:
    sx = max(0, min(32767, int(round(x / max(1, screen_w - 1) * 32767))))
    sy = max(0, min(32767, int(round(y / max(1, screen_h - 1) * 32767))))
    return sx, sy


# ===== Serial bridge ==================================================


class SerialBridge:
    def __init__(self, log_cb: Callable[[str], None]) -> None:
        self.log_cb = log_cb
        self.ser: Optional[serial.Serial] = None
        self.lock = threading.Lock()
        self.reader: Optional[threading.Thread] = None
        self.stop_flag = threading.Event()

    @property
    def connected(self) -> bool:
        return self.ser is not None and self.ser.is_open

    def connect(self, port: str) -> bool:
        self.disconnect()
        try:
            self.ser = serial.Serial(port, 115200, timeout=0.2)
        except Exception as exc:
            self.log_cb(f"串口打开失败: {exc}")
            return False
        self.stop_flag.clear()
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()
        time.sleep(1.2)  # let the Leonardo finish enumerating
        self.send("PING")
        return True

    def disconnect(self) -> None:
        self.stop_flag.set()
        if self.ser:
            try:
                self.ser.close()
            except Exception:
                pass
            self.ser = None

    def send(self, line: str) -> bool:
        with self.lock:
            if not self.connected:
                self.log_cb(f"未连接，丢弃命令: {line}")
                return False
            try:
                self.ser.write((line + "\n").encode("ascii"))
                self.ser.flush()
                return True
            except Exception as exc:
                self.log_cb(f"串口写入失败: {exc}")
                return False

    def _read_loop(self) -> None:
        buf = b""
        while not self.stop_flag.is_set():
            try:
                chunk = self.ser.read(64) if self.ser else b""
            except Exception as exc:
                self.log_cb(f"串口读取异常: {exc}")
                return
            if not chunk:
                continue
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode("utf-8", "replace").strip()
                if text:
                    self.log_cb(f"<< {text}")


# ===== Hotkeys ========================================================


class HotkeyThread(threading.Thread):
    """Win32 RegisterHotKey + dedicated message loop."""

    def __init__(self) -> None:
        super().__init__(daemon=True)
        self.callbacks: dict[int, Callable[[], None]] = {}
        self.bindings: list[tuple[int, int, int]] = []  # (id, mod, vk)
        self.tid: Optional[int] = None
        self._ready = threading.Event()

    def add(self, hk_id: int, mod: int, vk: int, callback: Callable[[], None]) -> None:
        self.bindings.append((hk_id, mod, vk))
        self.callbacks[hk_id] = callback

    def run(self) -> None:
        self.tid = GetCurrentThreadId()
        registered: list[int] = []
        for hk_id, mod, vk in self.bindings:
            if RegisterHotKey(None, hk_id, mod | MOD_NOREPEAT, vk):
                registered.append(hk_id)
        self._ready.set()
        msg = wintypes.MSG()
        while True:
            rv = GetMessageW(ctypes.byref(msg), None, 0, 0)
            if rv <= 0:
                break
            if msg.message == WM_HOTKEY:
                cb = self.callbacks.get(int(msg.wParam))
                if cb:
                    try:
                        cb()
                    except Exception as exc:
                        print(f"[hotkey] {exc}", file=sys.stderr)
        for hk_id in registered:
            UnregisterHotKey(None, hk_id)

    def stop(self) -> None:
        if self.tid is not None:
            PostThreadMessageW(self.tid, WM_QUIT, 0, 0)


# ===== Settings =======================================================


@dataclass
class CatchSettings:
    click_mode: str = "center"      # 'center' | 'screen' | 'cursor'
    screen_x: int = 960
    screen_y: int = 540
    interval_min: int = 800
    interval_max: int = 1200
    hold_min: int = 30
    hold_max: int = 60


@dataclass
class FlowerSettings:
    loop_min: int = 0
    loop_max: int = 0
    afk_pct: int = 3
    rest_pct: int = 5
    key_delay: int = 350


@dataclass
class Settings:
    port: str = ""
    target_exe: str = "NRC-Win64-Shipping.exe"
    catch: CatchSettings = field(default_factory=CatchSettings)
    flower: FlowerSettings = field(default_factory=FlowerSettings)
    auto_pause_on_focus_loss: bool = True

    def to_dict(self) -> dict:
        return {
            "port": self.port,
            "target_exe": self.target_exe,
            "catch": asdict(self.catch),
            "flower": asdict(self.flower),
            "auto_pause_on_focus_loss": self.auto_pause_on_focus_loss,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Settings":
        catch = CatchSettings(**(data.get("catch") or {}))
        flower = FlowerSettings(**(data.get("flower") or {}))
        return cls(
            port=data.get("port", ""),
            target_exe=data.get("target_exe", "NRC-Win64-Shipping.exe"),
            catch=catch,
            flower=flower,
            auto_pause_on_focus_loss=data.get("auto_pause_on_focus_loss", True),
        )


SETTINGS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "roco_host.json")


def load_settings() -> Settings:
    if not os.path.exists(SETTINGS_PATH):
        return Settings()
    try:
        with open(SETTINGS_PATH, "r", encoding="utf-8") as f:
            return Settings.from_dict(json.load(f))
    except Exception:
        return Settings()


def save_settings(settings: Settings) -> None:
    try:
        with open(SETTINGS_PATH, "w", encoding="utf-8") as f:
            json.dump(settings.to_dict(), f, indent=2, ensure_ascii=False)
    except Exception as exc:
        print(f"[settings] save failed: {exc}", file=sys.stderr)


# ===== App ============================================================

CATCH_HK_ID = 1
FLOWER_HK_ID = 2


class App:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.settings = load_settings()
        self.screen_w, self.screen_h = get_screen_size()

        self.active_script: Optional[str] = None   # 'catch' | 'flower' | None
        self.armed_script: Optional[str] = None    # what should resume when focus returns
        self.last_catch_args: Optional[tuple] = None
        self.last_flower_args: Optional[tuple] = None

        self.bridge = SerialBridge(self._log)
        self.hotkey_thread: Optional[HotkeyThread] = None

        root.title("洛克王国 - 硬件 HID 桥 (Leonardo)")
        root.geometry("620x640")
        root.protocol("WM_DELETE_WINDOW", self.on_close)
        self._build_ui()
        self._refresh_ports()
        self._log(f"屏幕尺寸: {self.screen_w} x {self.screen_h}")
        self._log("热键: Ctrl+- = 抓取启停, Ctrl+= = 循环启停")
        self._start_hotkeys()
        self._tick_foreground()

    # ----- UI -----

    def _build_ui(self) -> None:
        pad = {"padx": 6, "pady": 4}
        root = self.root

        top = ttk.LabelFrame(root, text="连接")
        top.pack(fill="x", **pad)
        ttk.Label(top, text="串口:").grid(row=0, column=0, **pad)
        self.port_var = tk.StringVar(value=self.settings.port)
        self.port_combo = ttk.Combobox(top, textvariable=self.port_var, width=30, state="readonly")
        self.port_combo.grid(row=0, column=1, **pad)
        ttk.Button(top, text="刷新", command=self._refresh_ports).grid(row=0, column=2, **pad)
        ttk.Button(top, text="连接", command=self._connect_clicked).grid(row=0, column=3, **pad)
        ttk.Button(top, text="断开", command=self._disconnect_clicked).grid(row=0, column=4, **pad)

        ttk.Label(top, text="游戏进程:").grid(row=1, column=0, **pad)
        self.target_var = tk.StringVar(value=self.settings.target_exe)
        ttk.Entry(top, textvariable=self.target_var, width=32).grid(row=1, column=1, **pad)
        self.pause_var = tk.BooleanVar(value=self.settings.auto_pause_on_focus_loss)
        ttk.Checkbutton(top, text="前台不是游戏时自动暂停",
                        variable=self.pause_var).grid(row=1, column=2, columnspan=3, sticky="w", **pad)

        self.status_var = tk.StringVar(value="状态: 未连接")
        ttk.Label(root, textvariable=self.status_var).pack(anchor="w", **pad)
        self.foreground_var = tk.StringVar(value="前台: ?")
        ttk.Label(root, textvariable=self.foreground_var).pack(anchor="w", **pad)

        # ---- Catch panel ----
        catch = ttk.LabelFrame(root, text="自动抓取 (Ctrl+-)")
        catch.pack(fill="x", **pad)
        self.catch_mode_var = tk.StringVar(value=self.settings.catch.click_mode)
        ttk.Label(catch, text="点击位置:").grid(row=0, column=0, sticky="w", **pad)
        for col, (label, value) in enumerate([("窗口客户区中心", "center"),
                                              ("屏幕坐标", "screen"),
                                              ("当前鼠标", "cursor")]):
            ttk.Radiobutton(catch, text=label, value=value,
                            variable=self.catch_mode_var).grid(row=0, column=1 + col, sticky="w", **pad)

        ttk.Label(catch, text="屏幕 X:").grid(row=1, column=0, sticky="w", **pad)
        self.catch_x_var = tk.IntVar(value=self.settings.catch.screen_x)
        ttk.Entry(catch, textvariable=self.catch_x_var, width=8).grid(row=1, column=1, sticky="w", **pad)
        ttk.Label(catch, text="屏幕 Y:").grid(row=1, column=2, sticky="w", **pad)
        self.catch_y_var = tk.IntVar(value=self.settings.catch.screen_y)
        ttk.Entry(catch, textvariable=self.catch_y_var, width=8).grid(row=1, column=3, sticky="w", **pad)
        ttk.Button(catch, text="3 秒后记录鼠标位置",
                   command=self._capture_cursor).grid(row=1, column=4, **pad)

        ttk.Label(catch, text="间隔 min/max (ms):").grid(row=2, column=0, sticky="w", **pad)
        self.catch_intv_min = tk.IntVar(value=self.settings.catch.interval_min)
        self.catch_intv_max = tk.IntVar(value=self.settings.catch.interval_max)
        ttk.Entry(catch, textvariable=self.catch_intv_min, width=8).grid(row=2, column=1, sticky="w", **pad)
        ttk.Entry(catch, textvariable=self.catch_intv_max, width=8).grid(row=2, column=2, sticky="w", **pad)

        ttk.Label(catch, text="按键停留 min/max (ms):").grid(row=3, column=0, sticky="w", **pad)
        self.catch_hold_min = tk.IntVar(value=self.settings.catch.hold_min)
        self.catch_hold_max = tk.IntVar(value=self.settings.catch.hold_max)
        ttk.Entry(catch, textvariable=self.catch_hold_min, width=8).grid(row=3, column=1, sticky="w", **pad)
        ttk.Entry(catch, textvariable=self.catch_hold_max, width=8).grid(row=3, column=2, sticky="w", **pad)

        ttk.Button(catch, text="开始/停止 抓取 (Ctrl+-)",
                   command=self.toggle_catch).grid(row=4, column=0, columnspan=2, sticky="we", **pad)
        ttk.Button(catch, text="测试单击", command=self.test_click).grid(row=4, column=2, sticky="we", **pad)

        # ---- Flower panel ----
        flower = ttk.LabelFrame(root, text="循环助手 (Ctrl+=)")
        flower.pack(fill="x", **pad)
        ttk.Label(flower, text="循环次数 min/max (0=无限):").grid(row=0, column=0, sticky="w", **pad)
        self.flower_loop_min = tk.IntVar(value=self.settings.flower.loop_min)
        self.flower_loop_max = tk.IntVar(value=self.settings.flower.loop_max)
        ttk.Entry(flower, textvariable=self.flower_loop_min, width=8).grid(row=0, column=1, **pad)
        ttk.Entry(flower, textvariable=self.flower_loop_max, width=8).grid(row=0, column=2, **pad)

        ttk.Label(flower, text="走神% / 喘息%:").grid(row=1, column=0, sticky="w", **pad)
        self.flower_afk = tk.IntVar(value=self.settings.flower.afk_pct)
        self.flower_rest = tk.IntVar(value=self.settings.flower.rest_pct)
        ttk.Entry(flower, textvariable=self.flower_afk, width=8).grid(row=1, column=1, **pad)
        ttk.Entry(flower, textvariable=self.flower_rest, width=8).grid(row=1, column=2, **pad)

        ttk.Label(flower, text="按键间补充延迟(ms):").grid(row=2, column=0, sticky="w", **pad)
        self.flower_key_delay = tk.IntVar(value=self.settings.flower.key_delay)
        ttk.Entry(flower, textvariable=self.flower_key_delay, width=8).grid(row=2, column=1, **pad)

        ttk.Button(flower, text="开始/停止 循环 (Ctrl+=)",
                   command=self.toggle_flower).grid(row=3, column=0, columnspan=2, sticky="we", **pad)
        ttk.Button(flower, text="初始化(↓×10)", command=self.run_init).grid(row=3, column=2, **pad)

        # ---- Log ----
        ttk.Label(root, text="日志:").pack(anchor="w", **pad)
        self.log_text = tk.Text(root, height=14, wrap="none")
        self.log_text.pack(fill="both", expand=True, **pad)

    # ----- Connection -----

    def _refresh_ports(self) -> None:
        ports = list(serial.tools.list_ports.comports())
        # Prefer Arduino Leonardo (VID 2341, PIDs 0x0036 boot / 0x8036 sketch).
        ports.sort(key=lambda p: 0 if "leonardo" in (p.description or "").lower()
                                   or (p.vid == 0x2341 and (p.pid or 0) in (0x0036, 0x8036)) else 1)
        labels = [f"{p.device} - {p.description}" for p in ports]
        self.port_combo["values"] = labels
        if labels:
            current = self.port_var.get()
            match = next((l for l in labels if l.startswith(current + " ") or l == current), None)
            self.port_combo.set(match or labels[0])

    def _connect_clicked(self) -> None:
        label = self.port_combo.get()
        if not label:
            messagebox.showwarning("提示", "请先选择串口")
            return
        port = label.split(" ", 1)[0]
        self._log(f"连接 {port}...")
        if self.bridge.connect(port):
            self.settings.port = port
            self.status_var.set(f"状态: 已连接 {port}")
            self._log("连接成功")
        else:
            self.status_var.set("状态: 连接失败")

    def _disconnect_clicked(self) -> None:
        self._send_stop("手动断开")
        self.bridge.disconnect()
        self.status_var.set("状态: 未连接")

    # ----- Helpers -----

    def _log(self, text: str) -> None:
        timestamp = time.strftime("%H:%M:%S")

        def append():
            self.log_text.insert("end", f"[{timestamp}] {text}\n")
            self.log_text.see("end")

        if threading.current_thread() is threading.main_thread():
            append()
        else:
            self.root.after(0, append)

    def _send(self, cmd: str) -> bool:
        self._log(f">> {cmd}")
        return self.bridge.send(cmd)

    def _send_stop(self, reason: str = "") -> None:
        if self.active_script:
            self._log(f"停止: {reason or self.active_script}")
        self.active_script = None
        self._send("STOP")

    def _resolve_catch_target(self) -> Optional[tuple[int, int]]:
        mode = self.catch_mode_var.get()
        if mode == "center":
            hwnd = find_window_by_process(self.target_var.get().strip())
            if not hwnd:
                self._log("找不到游戏窗口，无法用窗口中心模式")
                return None
            center = client_center_on_screen(hwnd)
            if not center:
                self._log("无法获取窗口中心")
                return None
            return center
        if mode == "screen":
            return (int(self.catch_x_var.get()), int(self.catch_y_var.get()))
        if mode == "cursor":
            return cursor_pos()
        return None

    def _capture_cursor(self) -> None:
        self._log("3 秒后记录当前鼠标位置...")
        def grab():
            x, y = cursor_pos()
            self.catch_x_var.set(x)
            self.catch_y_var.set(y)
            self.catch_mode_var.set("screen")
            self._log(f"已记录鼠标位置 (屏幕): ({x}, {y})，并切到屏幕坐标模式")
        self.root.after(3000, grab)

    def _read_catch_args(self) -> Optional[tuple[int, int, int, int, int, int]]:
        target = self._resolve_catch_target()
        if not target:
            return None
        x, y = pixel_to_hid(target[0], target[1], self.screen_w, self.screen_h)
        try:
            return (
                x, y,
                int(self.catch_hold_min.get()),
                int(self.catch_hold_max.get()),
                int(self.catch_intv_min.get()),
                int(self.catch_intv_max.get()),
            )
        except Exception as exc:
            self._log(f"抓取参数无效: {exc}")
            return None

    def _read_flower_args(self) -> Optional[tuple[int, int, int, int, int, int, int]]:
        hwnd = find_window_by_process(self.target_var.get().strip())
        if not hwnd:
            self._log("找不到游戏窗口，循环助手需要窗口中心坐标")
            return None
        center = client_center_on_screen(hwnd)
        if not center:
            self._log("无法获取窗口中心")
            return None
        cx, cy = pixel_to_hid(center[0], center[1], self.screen_w, self.screen_h)
        try:
            return (
                cx, cy,
                int(self.flower_loop_min.get()),
                int(self.flower_loop_max.get()),
                int(self.flower_afk.get()),
                int(self.flower_rest.get()),
                int(self.flower_key_delay.get()),
            )
        except Exception as exc:
            self._log(f"循环参数无效: {exc}")
            return None

    # ----- Actions -----

    def toggle_catch(self) -> None:
        if self.active_script == "catch":
            self.armed_script = None
            self._send_stop("手动停止抓取")
            return
        args = self._read_catch_args()
        if not args:
            return
        if not self._ensure_target_in_foreground("抓取"):
            return
        self.last_catch_args = args
        self.armed_script = "catch"
        self._send_catch(args)

    def _send_catch(self, args: tuple[int, int, int, int, int, int]) -> None:
        if self._send("CATCH " + " ".join(str(a) for a in args)):
            self.active_script = "catch"
            self.status_var.set("状态: 正在抓取")

    def toggle_flower(self) -> None:
        if self.active_script == "flower":
            self.armed_script = None
            self._send_stop("手动停止循环")
            return
        args = self._read_flower_args()
        if not args:
            return
        if not self._ensure_target_in_foreground("循环"):
            return
        self.last_flower_args = args
        self.armed_script = "flower"
        self._send_flower(args)

    def _send_flower(self, args: tuple[int, int, int, int, int, int, int]) -> None:
        if self._send("FLOWER " + " ".join(str(a) for a in args)):
            self.active_script = "flower"
            self.status_var.set("状态: 循环已启动")

    def _ensure_target_in_foreground(self, label: str) -> bool:
        if not self.pause_var.get():
            return True
        fg = get_foreground_process_name()
        if not fg:
            self._log(f"无法识别前台进程，仍尝试启动 {label}")
            return True
        if fg.lower() != self.target_var.get().strip().lower():
            self._log(f"前台是 {fg}，不是游戏。已武装，等待焦点返回。")
            return False
        return True

    def test_click(self) -> None:
        args = self._read_catch_args()
        if not args:
            return
        x, y, hold_min, hold_max, _, _ = args
        hold = random.randint(hold_min, max(hold_min, hold_max))
        self._send(f"MC {x} {y} {hold}")

    def run_init(self) -> None:
        if self.active_script:
            self._log("循环中，先停止再初始化")
            return
        self._send("INIT")

    # ----- Foreground monitor -----

    def _tick_foreground(self) -> None:
        fg = get_foreground_process_name() or "?"
        target = self.target_var.get().strip()
        is_target = fg.lower() == target.lower()
        self.foreground_var.set(f"前台: {fg} {'✓' if is_target else '✗'}")

        if self.pause_var.get():
            if not is_target and self.active_script:
                self._log("前台不是游戏，自动暂停")
                self._send("STOP")
                self.active_script = None
                self.status_var.set("状态: 已暂停 (失焦)")
            elif is_target and self.armed_script and not self.active_script:
                self._log("游戏回到前台，自动恢复")
                if self.armed_script == "catch" and self.last_catch_args:
                    self._send_catch(self.last_catch_args)
                elif self.armed_script == "flower" and self.last_flower_args:
                    self._send_flower(self.last_flower_args)

        self.root.after(500, self._tick_foreground)

    # ----- Hotkeys -----

    def _start_hotkeys(self) -> None:
        t = HotkeyThread()
        t.add(CATCH_HK_ID, MOD_CONTROL, VK_OEM_MINUS, lambda: self.root.after(0, self.toggle_catch))
        t.add(FLOWER_HK_ID, MOD_CONTROL, VK_OEM_PLUS, lambda: self.root.after(0, self.toggle_flower))
        t.start()
        self.hotkey_thread = t

    # ----- Shutdown -----

    def _collect_settings(self) -> None:
        s = self.settings
        s.target_exe = self.target_var.get().strip() or s.target_exe
        s.auto_pause_on_focus_loss = bool(self.pause_var.get())
        s.catch.click_mode = self.catch_mode_var.get()
        s.catch.screen_x = int(self.catch_x_var.get())
        s.catch.screen_y = int(self.catch_y_var.get())
        s.catch.interval_min = int(self.catch_intv_min.get())
        s.catch.interval_max = int(self.catch_intv_max.get())
        s.catch.hold_min = int(self.catch_hold_min.get())
        s.catch.hold_max = int(self.catch_hold_max.get())
        s.flower.loop_min = int(self.flower_loop_min.get())
        s.flower.loop_max = int(self.flower_loop_max.get())
        s.flower.afk_pct = int(self.flower_afk.get())
        s.flower.rest_pct = int(self.flower_rest.get())
        s.flower.key_delay = int(self.flower_key_delay.get())

    def on_close(self) -> None:
        self._send_stop("退出")
        try:
            self._collect_settings()
            save_settings(self.settings)
        except Exception:
            pass
        if self.hotkey_thread:
            self.hotkey_thread.stop()
        self.bridge.disconnect()
        self.root.destroy()


def main() -> None:
    if sys.platform != "win32":
        print("此上位机仅在 Windows 下能使用前台窗口检测与全局热键。")
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
