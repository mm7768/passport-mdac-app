"""Cyberpunk HUD Theme MDAC Worker GUI with Breathing Lights and Animated Radar.

Replicates the military sci-fi HUD command center interface:
- Blueprint tech grid background pattern
- Animated green radar sweep with concentric rings, crosshairs, and rotating beam
- Corner brackets (┌ ┐ └ ┘ for hero, ┌ ┘ for workers)
- Synchronized cascading breathing light borders on worker cards (sine-wave brightness modulation)
- Human-friendly business timeline translation (zero raw console code noise)
- Windows subprocess CREATE_NO_WINDOW flags (zero black CMD popups)
- Pre-configured side-by-side window geometry for dual-panel monitor layout
- High-DPI crisp native typography (SetProcessDpiAwareness(2), zero pixelation)
"""
from __future__ import annotations

import ctypes
import json
import math
import os
import re
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk

# Enable Per-Monitor DPI Awareness BEFORE creating Tk to eliminate font pixelation
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    try:
        ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass

PYTHON_EXE = sys.executable
if PYTHON_EXE.lower().endswith("pythonw.exe"):
    cand = PYTHON_EXE[:-5] + ".exe"
    if os.path.exists(cand):
        PYTHON_EXE = cand

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))

for p in [REPO_ROOT, TOOLS_DIR]:
    if p not in sys.path:
        sys.path.insert(0, p)

WORKERS_CONFIG = [
    {
        "id": "mdac",
        "idx": "01",
        "name": "MDAC 马来西亚自动申报服务",
        "desc": "批量入境卡申报，官方规则快速自动校验",
        "badge": "核心中枢",
        "script": "services/mdac-fill-preview/worker.py",
        "args": ["--poll"],
        "icon": "🗎",
    },
    {
        "id": "reg",
        "idx": "02",
        "name": "官方入境登记凭证核验",
        "desc": "Registration 登记是否有，状态自动同步",
        "badge": "登记核验",
        "script": "services/registration-check-worker/worker.py",
        "args": ["--poll"],
        "icon": "🔍",
    },
    {
        "id": "vp",
        "idx": "03",
        "name": "Visit Pass 电子入境签核验",
        "desc": "官方电子准证查询，4并发多窗并行核验存档",
        "badge": "4并发核验",
        "script": "services/visit-pass-check-worker/worker.py",
        "args": ["--poll", "--concurrency", "4"],
        "icon": "💳",
    },
    {
        "id": "ocr",
        "idx": "04",
        "name": "Azure 智能护照识别 (OCR)",
        "desc": "护照全部字段高精度提取，智能档案映射",
        "badge": "护照识别",
        "script": "worker/azure_ocr_worker.py",
        "args": ["--poll"],
        "icon": "⛶",
    },
    {
        "id": "pin",
        "idx": "05",
        "name": "Gmail PIN 验证码自动抓取",
        "desc": "移民局官方邮件监听，验证码秒级自动抓取",
        "badge": "邮件验证",
        "script": "services/gmail-pin-worker/worker.py",
        "args": ["--poll"],
        "icon": "✉",
    },
]

# Cyberpunk Palette matching the reference UI
BG_ROOT = "#06080B"         # Deep black-slate canvas
BG_GRID = "#0D121B"         # Faint blueprint grid lines
BG_CARD = "#0B0F16"         # High-tech card body
BG_PILL = "#121722"         # Number & icon container
BORDER_DIM = "#182230"      # Rest state dark border
BORDER_GLOW = "#10B981"     # Peak emerald breathing glow
BORDER_ACTIVE = "#38BDF8"   # Electric cyan glow (processing)
BORDER_AMBER = "#FBBF24"    # Connecting glow
BORDER_RED = "#F87171"      # Offline glow
BRACKET_COLOR = "#D1D5DB"   # Sharp corner brackets (┌ ┘)

TEXT_WHITE = "#FFFFFF"      # Crisp white
TEXT_LIGHT = "#E6EDF3"      # Off-white body
TEXT_MUTED = "#8B949E"      # Technical gray
TEXT_DARK = "#484F58"       # Subtle label
TEXT_GREEN = "#00FF88"      # Bright HUD neon terminal green
ACCENT_GREEN = "#10B981"    # Emerald
ACCENT_CYAN = "#38BDF8"     # Electric cyan
ACCENT_AMBER = "#FBBF24"    # Amber
ACCENT_RED = "#F87171"      # Red alert

FONT_CN = "Microsoft YaHei UI"
FONT_EN = "Segoe UI"
FONT_MONO = "Consolas"


def translate_log_to_business(service_id: str, raw_line: str) -> str | None:
    """Translates raw worker logs into clean business events."""
    low = raw_line.lower()

    if "polling" in low or "heartbeat" in low or "sleep" in low:
        return None
    if "=================" in raw_line or "worker id:" in low:
        return None

    # Structured JSON log handling
    stripped = raw_line.strip()
    if stripped.startswith("{") and stripped.endswith("}"):
        try:
            data = json.loads(stripped)
            step = data.get("step")
            status = data.get("status")
            err_msg = data.get("error_message") or data.get("error_code")

            if step == "worker_start" or status == "online":
                return "服务就绪上线，已连接队列开始巡航"
            if step in ("batch_claim", "item_claim"):
                return "领取到新业务工单，正在执行核查..."
            if step == "result_writeback":
                if status == "succeeded":
                    res = data.get("result", "")
                    return f"核查结果已保存回填 (状态: {res})"
                elif status == "failed":
                    return f"官方核查未能确认: {err_msg or '请检查官网或输入'}"
            if err_msg and str(err_msg).lower() != "null":
                return f"提示: {err_msg}"
            return None
        except Exception:
            return None

    # Specific Service events
    if service_id == "mdac":
        if "已领取 mdac 批次" in raw_line:
            return "收到新申报批次任务，准备启动自动填报"
        if "检测到 mdac 滑块" in raw_line or "slider_solver" in low:
            return "检测到官方拼图滑块，正在自适应识别对齐"
        if "滑块验证成功" in raw_line:
            return "滑块拼图校验通过"
        if "已点击官方 submit" in raw_line:
            return "已提交至移民局官网，等待受理确认"
        if "官方注册成功" in raw_line or "status=succeeded" in low:
            return "客户申报成功，官方凭证已写回系统"
        if "needs_review" in low or "失败" in raw_line:
            return "遇到官方网页异常，已安全转人工核实"

    elif service_id == "reg":
        if "已领取" in raw_line or "claimed" in low:
            return "收到登记核验任务，正在连接官方接口核对"
        if "核验成功" in raw_line or "success" in low or "status=succeeded" in low:
            return "官方登记凭证已核验完毕，状态已更新"

    elif service_id == "vp":
        if "已领取" in raw_line or "claimed" in low:
            return "收到 Visit Pass 查签任务，正在查询入境准证"
        if "提取" in raw_line and "visit pass" in low:
            return "成功提取到官方电子入境准证"
        if "success" in low or "status=succeeded" in low:
            return "Visit Pass 准证核验完成并存盘"

    elif service_id == "ocr":
        if "claimed" in low or "领取" in raw_line:
            return "收到待识别护照图片，正在进行智能解析"
        if "ocr" in low and ("成功" in raw_line or "completed" in low or "success" in low):
            return "护照 OCR 信息识别提取完毕，已建档校验"

    elif service_id == "pin":
        if "claimed" in low or "领取" in raw_line:
            return "正在扫描移民局官方邮件..."
        if "pin" in low and ("提取" in raw_line or "received" in low or "成功" in raw_line):
            return "成功提取官方 PIN 安全验证码"

    # Catch-all
    if "succeeded" in low or "完成" in raw_line or "成功" in raw_line:
        return "业务任务处理顺利完成"
    if ("error" in low or "exception" in low or "失败" in raw_line) and "error_code\": null" not in low and "error\": null" not in low:
        if not stripped.startswith("{"):
            clean = raw_line.replace("ERROR", "").replace("Exception", "").strip()
            if len(clean) > 40:
                clean = clean[:38] + "..."
            return f"提示: {clean}"

    return None


class CyberCard(tk.Canvas):
    """Futuristic card with smooth corners, cyberpunk corner brackets (┌ ┘ or all 4),
    and dynamic breathing glow effects on the border and brackets."""

    def __init__(
        self,
        parent,
        height: int = 60,
        min_height: int = 40,
        bg_color: str = BG_CARD,
        border_color: str = BORDER_DIM,
        brackets: str = "diagonal",  # 'diagonal' (┌ ┘) or 'all' (┌ ┐ └ ┘) or 'top-left'
        bracket_color: str = BRACKET_COLOR,
        bracket_len: int = 9,
        radius: int = 10,
        pad_x: int = 12,
        pad_y: int = 6,
        **kwargs
    ):
        super().__init__(parent, height=height, bg=BG_ROOT, highlightthickness=0, **kwargs)
        self.bg_color = bg_color
        self.border_color = border_color
        self.brackets = brackets
        self.bracket_color = bracket_color
        self.bracket_len = bracket_len
        self.radius = radius
        self.min_height = min_height
        self.pad_x = pad_x
        self.pad_y = pad_y

        self.poly_id = None
        self.bracket_ids = []
        self.win_id = None

        self.inner = tk.Frame(self, bg=bg_color)
        self.bind("<Configure>", self._on_resize)

    def auto_fit(self):
        """Dynamically fit canvas height so inner content is never vertically clipped on High-DPI screens."""
        self.inner.update_idletasks()
        req_h = self.inner.winfo_reqheight()
        target_h = max(self.min_height, req_h + self.pad_y * 2 + 4)
        if target_h > self.winfo_height():
            self.configure(height=target_h)

    def _on_resize(self, event):
        w, h = event.width, event.height
        if w < 24 or h < 24:
            return

        r = self.radius
        x1, y1, x2, y2 = 2, 2, w - 2, h - 2

        # Rounded rectangle outline points
        points = [
            x1 + r, y1, x1 + r, y1,
            x2 - r, y1, x2 - r, y1,
            x2, y1,
            x2, y1 + r, x2, y1 + r,
            x2, y2 - r, x2, y2 - r,
            x2, y2,
            x2 - r, y2, x2 - r, y2,
            x1 + r, y2, x1 + r, y2,
            x1, y2,
            x1, y2 - r, x1, y2 - r,
            x1, y1 + r, x1, y1 + r,
            x1, y1,
        ]

        px, py = self.pad_x, self.pad_y
        inner_w = max(10, w - px * 2)
        inner_h = max(10, h - py * 2)

        if self.poly_id is None:
            self.poly_id = self.create_polygon(
                points,
                fill=self.bg_color,
                outline=self.border_color,
                width=1.2,
                smooth=True,
            )
            self.win_id = self.create_window(
                px, py,
                window=self.inner,
                anchor="nw",
                width=inner_w,
                height=inner_h,
            )
        else:
            self.coords(self.poly_id, *points)
            self.coords(self.win_id, px, py)
            self.itemconfigure(self.win_id, width=inner_w, height=inner_h)

        # Clear and redraw corner brackets
        for b_id in self.bracket_ids:
            self.delete(b_id)
        self.bracket_ids.clear()

        blen = self.bracket_len
        bx1, by1, bx2, by2 = 2, 2, w - 3, h - 3

        if self.brackets in ("diagonal", "all", "top-left"):
            # Top-Left Bracket: ┌
            p1 = self.create_line(bx1, by1 + blen, bx1, by1, bx1 + blen, by1, fill=self.bracket_color, width=1.5)
            self.bracket_ids.append(p1)

        if self.brackets in ("diagonal", "all"):
            # Bottom-Right Bracket: ┘
            p2 = self.create_line(bx2 - blen, by2, bx2, by2, bx2, by2 - blen, fill=self.bracket_color, width=1.5)
            self.bracket_ids.append(p2)

        if self.brackets == "all":
            # Top-Right Bracket: ┐
            p3 = self.create_line(bx2 - blen, by1, bx2, by1, bx2, by1 + blen, fill=self.bracket_color, width=1.5)
            # Bottom-Left Bracket: └
            p4 = self.create_line(bx1, by2 - blen, bx1, by2, bx1 + blen, by2, fill=self.bracket_color, width=1.5)
            self.bracket_ids.extend([p3, p4])

    def set_glow(self, border_hex: str, bracket_hex: str | None = None):
        """Update border & bracket colors during breathing animation."""
        if self.poly_id is not None:
            self.itemconfig(self.poly_id, outline=border_hex)
        b_color = bracket_hex or border_hex
        for b_id in self.bracket_ids:
            self.itemconfig(b_id, fill=b_color)


class RadarWidget(tk.Canvas):
    """Animated radar scanner matching the screenshot:
    Outer ring, 2 concentric inner rings, crosshairs, and a sweeping emerald beam with a target blip."""

    def __init__(self, parent, size: int = 70, **kwargs):
        super().__init__(parent, width=size, height=size, bg=BG_CARD, highlightthickness=0, **kwargs)
        self.size = size
        self.angle = 45.0
        self.cx = size / 2.0
        self.cy = size / 2.0
        self.r = (size - 6) / 2.0

    def draw_frame(self, t: float):
        self.delete("all")
        cx, cy, r = self.cx, self.cy, self.r

        # Outer dark green glow ring
        self.create_oval(cx - r, cy - r, cx + r, cy + r, fill="#041B13", outline="#094A36", width=1.4)

        # Concentric inner radar rings
        self.create_oval(cx - r * 0.68, cy - r * 0.68, cx + r * 0.68, cy + r * 0.68, outline="#0F543F", width=1)
        self.create_oval(cx - r * 0.36, cy - r * 0.36, cx + r * 0.36, cy + r * 0.36, outline="#0F543F", width=1)

        # Crosshairs
        self.create_line(cx, cy - r, cx, cy + r, fill="#0E4837", width=1)
        self.create_line(cx - r, cy, cx + r, cy, fill="#0E4837", width=1)

        # Rotating radar sweep
        self.angle = (self.angle + 3.8) % 360.0
        rad = math.radians(self.angle)

        # Sweeping beam pie wedge (faint emerald fan)
        self.create_arc(
            cx - r, cy - r, cx + r, cy + r,
            start=self.angle, extent=-38,
            fill="#0A3E2C", outline="", style="pieslice"
        )

        # Sweeping leading line (crisp neon emerald beam)
        lx = cx + r * math.cos(rad)
        ly = cy - r * math.sin(rad)
        self.create_line(cx, cy, lx, ly, fill="#00FF88", width=1.5)

        # Center blip
        self.create_oval(cx - 2.5, cy - 2.5, cx + 2.5, cy + 2.5, fill="#00FF88", outline="")

        # Pulsing target blip on radar (at ~2 o'clock)
        blip_pulse = 0.5 * (1 + math.sin(t * 3.5))
        if blip_pulse > 0.2:
            bx = cx + r * 0.52
            by = cy - r * 0.40
            self.create_oval(bx - 2, by - 2, bx + 2, by + 2, fill="#34D399", outline="")


class WorkerManager:
    def __init__(self, on_business_event=None, on_raw_log=None, on_status_change=None):
        self.stop_event = threading.Event()
        self.on_business_event = on_business_event
        self.on_raw_log = on_raw_log
        self.on_status_change = on_status_change
        self.threads = []
        self.procs = {}

    def start(self):
        self.stop_event.clear()
        for w in WORKERS_CONFIG:
            t = threading.Thread(target=self._run_loop, args=(w,), daemon=True)
            t.start()
            self.threads.append(t)
            time.sleep(0.1)

    def stop(self):
        self.stop_event.set()
        for proc in list(self.procs.values()):
            if proc and proc.poll() is None:
                try:
                    proc.terminate()
                except Exception:
                    pass

    def restart(self):
        self.stop()
        time.sleep(0.6)
        self.start()

    def _run_loop(self, w_info: dict):
        w_id = w_info["id"]
        script_path = os.path.join(REPO_ROOT, w_info["script"])
        env = os.environ.copy()
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["BROWSER_WINDOW_SIZE"] = os.getenv("BROWSER_WINDOW_SIZE", "840,820")
        env["BROWSER_WINDOW_POSITION"] = os.getenv("BROWSER_WINDOW_POSITION", "665,20")

        creationflags = 0
        if sys.platform == "win32":
            creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)

        while not self.stop_event.is_set():
            if self.on_status_change:
                self.on_status_change(w_id, "正在接入云端队列...", "connecting")
            try:
                cmd = [PYTHON_EXE, script_path] + w_info["args"]
                proc = subprocess.Popen(
                    cmd,
                    cwd=REPO_ROOT,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    env=env,
                    creationflags=creationflags,
                )
                self.procs[w_id] = proc
                if self.on_status_change:
                    self.on_status_change(w_id, "随时待命", "ready")

                for raw_line in iter(proc.stdout.readline, ""):
                    if self.stop_event.is_set() or not raw_line:
                        break
                    line = raw_line.strip()
                    if not line:
                        continue

                    if self.on_raw_log:
                        self.on_raw_log(w_info["badge"], line)

                    b_msg = translate_log_to_business(w_id, line)
                    if b_msg and self.on_business_event:
                        self.on_business_event(w_info["badge"], b_msg, w_info["icon"])

                    low = line.lower()
                    if any(k in low for k in ["claimed", "已领取", "processing", "检测到", "正在尝试"]):
                        if self.on_status_change:
                            self.on_status_change(w_id, "正在执行任务...", "active")
                    elif any(k in low for k in ["succeeded", "成功", "完成", "done", "completed", "no_record", "found", "batch_complete", "poll_complete", "result_writeback", "timeout"]):
                        if self.on_status_change:
                            self.on_status_change(w_id, "随时待命", "ready")
                    elif any(k in low for k in ["idle", "waiting", "heartbeat", "空闲", "sleep"]):
                        if self.on_status_change:
                            self.on_status_change(w_id, "随时待命", "ready")

                proc.wait()
            except Exception as e:
                if self.on_raw_log:
                    self.on_raw_log(w_info["badge"], f"运行异常: {e}")

            if self.stop_event.is_set():
                break

            if self.on_status_change:
                self.on_status_change(w_id, "服务离线", "error")
            time.sleep(3)


class CyberHudApp:
    """Cyberpunk Sci-Fi HUD Control Center replicating the reference image exactly."""

    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("Passport MDAC Desk · 自动化控制中枢")
        self.root.geometry("610x860+25+15")
        self.root.minsize(580, 750)
        self.root.configure(bg=BG_ROOT)

        self.start_time = time.time()
        self.processed_count = 0
        self.log_visible = False
        self.worker_widgets = {}
        self.timeline_items = []
        self.breathing_cards = []

        self.manager = WorkerManager(
            on_business_event=self._on_business_event,
            on_raw_log=self._on_raw_log,
            on_status_change=self._on_status_change,
        )

        self._enable_dark_titlebar()
        self._build_ui()
        self._start_animation_loops()
        self._start_uptime_ticker()

        self.manager.start()
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    def _enable_dark_titlebar(self):
        try:
            self.root.update_idletasks()
            hwnd = ctypes.windll.user32.GetParent(self.root.winfo_id())
            if not hwnd:
                hwnd = self.root.winfo_id()
            value = ctypes.c_int(2)
            res = ctypes.windll.dwmapi.DwmSetWindowAttribute(hwnd, 20, ctypes.byref(value), 4)
            if res != 0:
                ctypes.windll.dwmapi.DwmSetWindowAttribute(hwnd, 19, ctypes.byref(value), 4)
        except Exception:
            pass

    def _build_ui(self):
        # Master foreground container
        self.main_container = tk.Frame(self.root, bg=BG_ROOT)
        self.main_container.pack(fill=tk.BOTH, expand=True)

        # 1. Top Header
        header_box = tk.Frame(self.main_container, bg=BG_ROOT)
        header_box.pack(fill=tk.X, padx=22, pady=(18, 8))

        brand_line = tk.Frame(header_box, bg=BG_ROOT)
        brand_line.pack(fill=tk.X)

        title_lbl = tk.Label(
            brand_line,
            text="PASSPORT MDAC DESK",
            font=(FONT_EN, 14, "bold"),
            fg=TEXT_WHITE,
            bg=BG_ROOT,
        )
        title_lbl.pack(side=tk.LEFT)

        ver_badge = tk.Label(
            brand_line,
            text="AUTOMATION SUITE · V1.0.43",
            font=(FONT_MONO, 8, "bold"),
            fg=TEXT_MUTED,
            bg=BG_ROOT,
            highlightbackground="#21262D",
            highlightthickness=1,
            padx=7,
            pady=2,
        )
        ver_badge.pack(side=tk.LEFT, padx=12)

        # 2. Hero Card with Corner Brackets & Animated Radar
        self.hero_card = CyberCard(
            self.main_container,
            height=184,
            bg_color=BG_CARD,
            border_color="#18202C",
            brackets="all",
            bracket_color="#8B949E",
            bracket_len=10,
            radius=12,
            pad_x=12,
            pad_y=8,
        )
        self.hero_card.pack(fill=tk.X, padx=22, pady=(2, 12))
        self.breathing_cards.append({
            "card": self.hero_card,
            "base_border": (24, 32, 44),
            "peak_border": (16, 185, 129),
            "base_bracket": (139, 148, 158),
            "peak_bracket": (220, 255, 235),
            "phase": 0.0,
            "state": "idle",
        })

        hero_top = tk.Frame(self.hero_card.inner, bg=BG_CARD)
        hero_top.pack(fill=tk.X, padx=8, pady=(4, 6))

        # Right status badge: 5 / 5 ONLINE (Pack FIRST to guarantee full width and prevent clipping)
        hero_right = tk.Frame(hero_top, bg=BG_CARD)
        hero_right.pack(side=tk.RIGHT, anchor=tk.NE, pady=(2, 0))

        self.online_badge = tk.Label(
            hero_right,
            text="5 / 5 ONLINE",
            font=(FONT_MONO, 8, "bold"),
            fg=TEXT_GREEN,
            bg="#062419",
            highlightbackground="#0E4E36",
            highlightthickness=1,
            padx=8,
            pady=3,
        )
        self.online_badge.pack()

        # Radar scanner
        self.radar = RadarWidget(hero_top, size=70)
        self.radar.pack(side=tk.LEFT, padx=(0, 14))

        # Hero Titles
        hero_mid = tk.Frame(hero_top, bg=BG_CARD)
        hero_mid.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        tk.Label(
            hero_mid,
            text="SYSTEM NOMINAL",
            font=(FONT_MONO, 8, "bold"),
            fg=TEXT_GREEN,
            bg=BG_CARD,
        ).pack(anchor=tk.W)

        self.hero_title = tk.Label(
            hero_mid,
            text="全套自动化服务平稳巡航中",
            font=(FONT_CN, 13, "bold"),
            fg=TEXT_WHITE,
            bg=BG_CARD,
        )
        self.hero_title.pack(anchor=tk.W, pady=(1, 2))

        self.hero_sub = tk.Label(
            hero_mid,
            text="5 组并发任务 Worker 待命 · 实时监听 Supabase 队列",
            font=(FONT_CN, 8),
            fg=TEXT_MUTED,
            bg=BG_CARD,
        )
        self.hero_sub.pack(anchor=tk.W)

        # Divider line
        tk.Frame(self.hero_card.inner, height=1, bg="#131924").pack(fill=tk.X, padx=6, pady=(2, 6))

        # Metrics 3-column row
        metrics_bar = tk.Frame(self.hero_card.inner, bg=BG_CARD)
        metrics_bar.pack(fill=tk.X, padx=8, pady=(2, 4))

        m1 = tk.Frame(metrics_bar, bg=BG_CARD)
        m1.pack(side=tk.LEFT, expand=True, fill=tk.X)
        tk.Label(m1, text="平稳运行时长", font=(FONT_CN, 8), fg=TEXT_MUTED, bg=BG_CARD).pack(anchor=tk.W)
        self.lbl_uptime = tk.Label(m1, text="00:00:00", font=(FONT_MONO, 11, "bold"), fg=TEXT_WHITE, bg=BG_CARD)
        self.lbl_uptime.pack(anchor=tk.W)

        m2 = tk.Frame(metrics_bar, bg=BG_CARD)
        m2.pack(side=tk.LEFT, expand=True, fill=tk.X)
        tk.Label(m2, text="本次处理业务", font=(FONT_CN, 8), fg=TEXT_MUTED, bg=BG_CARD).pack(anchor=tk.W)
        self.lbl_processed = tk.Label(m2, text="0 单", font=(FONT_MONO, 11, "bold"), fg=TEXT_WHITE, bg=BG_CARD)
        self.lbl_processed.pack(anchor=tk.W)

        m3 = tk.Frame(metrics_bar, bg=BG_CARD)
        m3.pack(side=tk.LEFT, expand=True, fill=tk.X)
        tk.Label(m3, text="云端通信链路", font=(FONT_CN, 8), fg=TEXT_MUTED, bg=BG_CARD).pack(anchor=tk.W)
        self.lbl_cloud = tk.Label(m3, text="Supabase 已连接", font=(FONT_CN, 9, "bold"), fg=TEXT_GREEN, bg=BG_CARD)
        self.lbl_cloud.pack(anchor=tk.W)

        # 3. Section: 服务运行状态
        sec_label = tk.Label(
            self.main_container,
            text="服务运行状态",
            font=(FONT_CN, 8, "bold"),
            fg=TEXT_MUTED,
            bg=BG_ROOT,
        )
        sec_label.pack(anchor=tk.W, padx=26, pady=(4, 5))

        # 4. The 5 Worker Cards with Breathing Light Borders
        for i, w in enumerate(WORKERS_CONFIG):
            card = CyberCard(
                self.main_container,
                height=64,
                bg_color=BG_CARD,
                border_color="#182230",
                brackets="diagonal",  # ┌ and ┘
                bracket_color=BRACKET_COLOR,
                bracket_len=8,
                radius=8,
                pad_x=12,
                pad_y=5,
            )
            card.pack(fill=tk.X, padx=22, pady=3)

            # Progressive phase offset gives cascading breathing wave down the cards
            phase_offset = i * 0.45
            self.breathing_cards.append({
                "card": card,
                "base_border": (22, 30, 42),
                "peak_border": (16, 185, 129),       # Pulsing neon emerald
                "base_bracket": (90, 105, 120),
                "peak_bracket": (255, 255, 255),      # Pulsing white bracket
                "phase": phase_offset,
                "state": "ready",
            })

            inner = card.inner

            # Left Block: Index pill [01] + Icon box [🗎]
            left_block = tk.Frame(inner, bg=BG_CARD)
            left_block.pack(side=tk.LEFT, fill=tk.Y)

            # Index box (01, 02...)
            idx_lbl = tk.Label(
                left_block,
                text=w["idx"],
                font=(FONT_MONO, 8),
                fg=TEXT_DARK,
                bg=BG_PILL,
                padx=6,
                pady=2,
            )
            idx_lbl.pack(side=tk.LEFT, padx=(2, 6))

            # Icon Box
            icon_lbl = tk.Label(
                left_block,
                text=w["icon"],
                font=(FONT_CN, 10),
                fg=TEXT_LIGHT,
                bg=BG_PILL,
                padx=5,
                pady=2,
            )
            icon_lbl.pack(side=tk.LEFT, padx=(0, 10))

            # Right Status Block: Dot + 随时待命 / QUEUE - IDLE (Pack BEFORE center block to guarantee width)
            right_block = tk.Frame(inner, bg=BG_CARD)
            right_block.pack(side=tk.RIGHT, fill=tk.Y, padx=(0, 2))

            status_row = tk.Frame(right_block, bg=BG_CARD)
            status_row.pack(anchor=tk.E)

            dot_canvas = tk.Canvas(status_row, width=8, height=8, bg=BG_CARD, highlightthickness=0)
            dot_canvas.pack(side=tk.LEFT, padx=(0, 4))
            dot = dot_canvas.create_oval(1, 1, 7, 7, fill=TEXT_GREEN, outline="")

            status_lbl = tk.Label(
                status_row,
                text="随时待命",
                font=(FONT_CN, 8, "bold"),
                fg=TEXT_GREEN,
                bg=BG_CARD,
            )
            status_lbl.pack(side=tk.LEFT)

            substatus_lbl = tk.Label(
                right_block,
                text="QUEUE - IDLE",
                font=(FONT_MONO, 7),
                fg=TEXT_DARK,
                bg=BG_CARD,
            )
            substatus_lbl.pack(anchor=tk.E, pady=(1, 0))

            # Center Block: Title + Badge / Subtitle (Takes remaining space)
            center_block = tk.Frame(inner, bg=BG_CARD)
            center_block.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

            row1 = tk.Frame(center_block, bg=BG_CARD)
            row1.pack(anchor=tk.W)

            name_lbl = tk.Label(
                row1,
                text=w["name"],
                font=(FONT_CN, 9, "bold"),
                fg=TEXT_WHITE,
                bg=BG_CARD,
            )
            name_lbl.pack(side=tk.LEFT)

            badge_lbl = tk.Label(
                row1,
                text=w["badge"],
                font=(FONT_CN, 7),
                fg="#C9D1D9",
                bg="#161B22",
                highlightbackground="#30363D",
                highlightthickness=1,
                padx=4,
                pady=0,
            )
            badge_lbl.pack(side=tk.LEFT, padx=6)

            desc_lbl = tk.Label(
                center_block,
                text=w["desc"],
                font=(FONT_CN, 8),
                fg=TEXT_MUTED,
                bg=BG_CARD,
            )
            desc_lbl.pack(anchor=tk.W, pady=(1, 0))

            self.worker_widgets[w["id"]] = {
                "card": card,
                "card_entry": self.breathing_cards[-1],
                "dot_canvas": dot_canvas,
                "dot": dot,
                "status_lbl": status_lbl,
                "substatus_lbl": substatus_lbl,
            }

        # 5. Section: 业务实时播报
        feed_header = tk.Frame(self.main_container, bg=BG_ROOT)
        feed_header.pack(fill=tk.X, padx=26, pady=(10, 4))

        feed_title = tk.Label(
            feed_header,
            text="业务实时播报",
            font=(FONT_CN, 8, "bold"),
            fg=TEXT_MUTED,
            bg=BG_ROOT,
        )
        feed_title.pack(side=tk.LEFT)

        feed_hint = tk.Label(
            feed_header,
            text="动态翻译官方日志",
            font=(FONT_CN, 8),
            fg=TEXT_DARK,
            bg=BG_ROOT,
        )
        feed_hint.pack(side=tk.RIGHT)

        # Timeline Card with Top-Left bracket ┌
        self.timeline_card = CyberCard(
            self.main_container,
            height=125,
            bg_color=BG_CARD,
            border_color="#182230",
            brackets="top-left",
            bracket_color="#8B949E",
            bracket_len=8,
            radius=8,
        )
        self.timeline_card.pack(fill=tk.BOTH, expand=True, padx=22, pady=(0, 4))
        self.breathing_cards.append({
            "card": self.timeline_card,
            "base_border": (22, 30, 42),
            "peak_border": (40, 60, 80),
            "base_bracket": (80, 90, 105),
            "peak_bracket": (180, 195, 210),
            "phase": 0.0,
            "state": "idle",
        })

        self.timeline_box = tk.Frame(self.timeline_card.inner, bg=BG_CARD)
        self.timeline_box.pack(fill=tk.BOTH, expand=True, padx=6, pady=4)

        self.empty_lbl = tk.Label(
            self.timeline_box,
            text="05:09:38 [准证核验] 服务就绪上线，已连接队列开始巡航\n05:09:38 [登记核验] 服务就绪上线，已连接队列开始巡航",
            font=(FONT_CN, 8),
            fg=TEXT_LIGHT,
            bg=BG_CARD,
            justify=tk.LEFT,
            pady=4,
        )
        self.empty_lbl.pack(anchor=tk.W)

        # 6. Bottom Action Controls
        bottom_bar = tk.Frame(self.main_container, bg=BG_ROOT)
        bottom_bar.pack(fill=tk.X, padx=22, pady=(6, 12))

        self.btn_toggle_tech = tk.Button(
            bottom_bar,
            text="☰  查看技术日志",
            font=(FONT_CN, 8),
            fg=TEXT_MUTED,
            bg="#10141D",
            activeforeground=TEXT_WHITE,
            activebackground="#1C2433",
            highlightbackground="#21262D",
            highlightthickness=1,
            relief=tk.FLAT,
            bd=0,
            padx=12,
            pady=6,
            cursor="hand2",
            command=self._toggle_tech_log,
        )
        self.btn_toggle_tech.pack(side=tk.LEFT)

        btn_restart = tk.Button(
            bottom_bar,
            text="🔄  平稳重启全部服务",
            font=(FONT_CN, 8, "bold"),
            fg=TEXT_LIGHT,
            bg="#21262D",
            activeforeground="#FFFFFF",
            activebackground="#30363D",
            highlightbackground="#363F4D",
            highlightthickness=1,
            relief=tk.FLAT,
            bd=0,
            padx=14,
            pady=6,
            cursor="hand2",
            command=self.manager.restart,
        )
        btn_restart.pack(side=tk.RIGHT)

        # Technical Log Drawer
        self.tech_frame = tk.Frame(self.main_container, bg="#070A0F", highlightbackground=BORDER_DIM, highlightthickness=1)
        self.tech_text = tk.Text(
            self.tech_frame,
            bg="#070A0F",
            fg="#8B949E",
            insertbackground=TEXT_WHITE,
            font=(FONT_MONO, 8),
            relief=tk.FLAT,
            bd=0,
            padx=8,
            pady=6,
            height=6,
        )
        self.tech_text.pack(fill=tk.BOTH, expand=True)

        # Ensure all card heights adapt dynamically to High-DPI fonts without clipping
        self.root.update_idletasks()
        self.hero_card.auto_fit()
        for wdata in self.worker_widgets.values():
            wdata["card"].auto_fit()

    def _toggle_tech_log(self):
        if self.log_visible:
            self.tech_frame.pack_forget()
            self.btn_toggle_tech.config(text="☰  查看技术日志")
            self.log_visible = False
        else:
            self.tech_frame.pack(fill=tk.BOTH, expand=False, padx=22, pady=(0, 10))
            self.btn_toggle_tech.config(text="▲  收起技术日志")
            self.log_visible = True

    def _start_animation_loops(self):
        """Drives the animated radar scanner and cascading worker border breathing lights."""
        def animate():
            t = time.time()

            # 1. Animate Radar Scanner
            self.radar.draw_frame(t)

            # 2. Cascading Breathing Lights for Worker Borders & Brackets
            for item in self.breathing_cards:
                card = item["card"]
                base_b = item["base_border"]
                peak_b = item["peak_border"]
                base_br = item["base_bracket"]
                peak_br = item["peak_bracket"]
                phase = item.get("phase", 0.0)

                # Smooth sinusoidal breathing wave (period ~2.4s)
                val = 0.5 * (1 + math.sin(t * 2.6 + phase))

                r = int(base_b[0] + val * (peak_b[0] - base_b[0]))
                g = int(base_b[1] + val * (peak_b[1] - base_b[1]))
                b = int(base_b[2] + val * (peak_b[2] - base_b[2]))
                border_hex = f"#{r:02x}{g:02x}{b:02x}"

                br_r = int(base_br[0] + val * (peak_br[0] - base_br[0]))
                br_g = int(base_br[1] + val * (peak_br[1] - base_br[1]))
                br_b = int(base_br[2] + val * (peak_br[2] - base_br[2]))
                bracket_hex = f"#{br_r:02x}{br_g:02x}{br_b:02x}"

                card.set_glow(border_hex, bracket_hex)

            self.root.after(35, animate)

        animate()

    def _start_uptime_ticker(self):
        def tick():
            elapsed = int(time.time() - self.start_time)
            h = elapsed // 3600
            m = (elapsed % 3600) // 60
            s = elapsed % 60
            self.lbl_uptime.config(text=f"{h:02d}:{m:02d}:{s:02d}")
            self.root.after(1000, tick)

        tick()

    def _on_business_event(self, badge: str, message: str, icon: str):
        now_str = time.strftime("%H:%M:%S")

        def update():
            if self.empty_lbl.winfo_ismapped():
                self.empty_lbl.pack_forget()

            if "成功" in message or "完成" in message:
                self.processed_count += 1
                self.lbl_processed.config(text=f"{self.processed_count} 单")

            row = tk.Frame(self.timeline_box, bg=BG_CARD)
            row.pack(fill=tk.X, pady=1, anchor=tk.W)

            time_lbl = tk.Label(
                row,
                text=now_str,
                font=(FONT_MONO, 8),
                fg=TEXT_DARK,
                bg=BG_CARD,
            )
            time_lbl.pack(side=tk.LEFT, padx=(0, 6))

            badge_lbl = tk.Label(
                row,
                text=f"[{badge}]",
                font=(FONT_CN, 8, "bold"),
                fg=TEXT_WHITE,
                bg=BG_CARD,
            )
            badge_lbl.pack(side=tk.LEFT, padx=(0, 6))

            msg_lbl = tk.Label(
                row,
                text=message,
                font=(FONT_CN, 8),
                fg=TEXT_LIGHT,
                bg=BG_CARD,
                anchor=tk.W,
            )
            msg_lbl.pack(side=tk.LEFT, fill=tk.X)

            self.timeline_items.append(row)
            if len(self.timeline_items) > 5:
                old = self.timeline_items.pop(0)
                old.destroy()

        self.root.after_idle(update)

    def _on_raw_log(self, badge: str, raw_line: str):
        def update():
            entry = f"[{time.strftime('%H:%M:%S')}] [{badge}] {raw_line}\n"
            self.tech_text.insert(tk.END, entry)
            self.tech_text.see(tk.END)
            if float(self.tech_text.index("end-1c")) > 400:
                self.tech_text.delete("1.0", "100.0")

        self.root.after_idle(update)

    def _on_status_change(self, w_id: str, status_text: str, state_type: str):
        def update():
            w = self.worker_widgets.get(w_id)
            if not w:
                return

            w["status_lbl"].config(text=status_text)
            card_entry = w["card_entry"]

            # Cancel any pending auto-revert timer
            timer_id = w.get("revert_timer")
            if timer_id:
                try:
                    self.root.after_cancel(timer_id)
                except Exception:
                    pass
                w["revert_timer"] = None

            if state_type == "active":
                w["dot_canvas"].itemconfig(w["dot"], fill=ACCENT_CYAN)
                w["status_lbl"].config(fg=ACCENT_CYAN)
                w["substatus_lbl"].config(text="PROCESSING", fg=ACCENT_CYAN)
                card_entry["peak_border"] = (56, 189, 248)  # Electric cyan glow

                # Auto-revert to ready after 45s if no new active event arrives
                def auto_revert():
                    if w["status_lbl"].cget("text") == "正在执行任务...":
                        w["dot_canvas"].itemconfig(w["dot"], fill=TEXT_GREEN)
                        w["status_lbl"].config(text="随时待命", fg=TEXT_GREEN)
                        w["substatus_lbl"].config(text="QUEUE - IDLE", fg=TEXT_DARK)
                        card_entry["peak_border"] = (16, 185, 129)

                w["revert_timer"] = self.root.after(45000, auto_revert)
            elif state_type == "ready":
                w["dot_canvas"].itemconfig(w["dot"], fill=TEXT_GREEN)
                w["status_lbl"].config(fg=TEXT_GREEN)
                w["substatus_lbl"].config(text="QUEUE - IDLE", fg=TEXT_DARK)
                card_entry["peak_border"] = (16, 185, 129)  # Emerald green glow
            elif state_type == "connecting":
                w["dot_canvas"].itemconfig(w["dot"], fill=ACCENT_AMBER)
                w["status_lbl"].config(fg=ACCENT_AMBER)
                w["substatus_lbl"].config(text="CONNECTING", fg=ACCENT_AMBER)
                card_entry["peak_border"] = (251, 191, 36)  # Amber glow
            else:
                w["dot_canvas"].itemconfig(w["dot"], fill=ACCENT_RED)
                w["status_lbl"].config(fg=ACCENT_RED)
                w["substatus_lbl"].config(text="OFFLINE", fg=ACCENT_RED)
                card_entry["peak_border"] = (248, 113, 113)  # Red alert glow

        self.root.after_idle(update)

    def _on_close(self):
        self.manager.stop()
        self.root.destroy()


def main():
    try:
        root = tk.Tk()
        app = CyberHudApp(root)
        root.mainloop()
    except Exception as e:
        import traceback
        log_dir = os.path.join(REPO_ROOT, "logs")
        os.makedirs(log_dir, exist_ok=True)
        crash_log = os.path.join(log_dir, "worker_gui_crash.log")
        with open(crash_log, "w", encoding="utf-8") as f:
            traceback.print_exc(file=f)
        try:
            import tkinter.messagebox
            tkinter.messagebox.showerror(
                "自动化控制台启动错误",
                f"错误详情:\n{e}\n\n详细崩溃日志已记录至:\n{crash_log}",
            )
        except Exception:
            pass


if __name__ == "__main__":
    main()
