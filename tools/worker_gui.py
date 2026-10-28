"""Pure Obsidian Black GUI with Breathing White Halo Borders for MDAC Worker Suite.

Theme: Pure Obsidian Black (#000000 & #08080A)
Aesthetic:
- Crisp anti-aliased native typography (Windows Per-Monitor DPI Aware, zero pixelation)
- Elegant smooth rounded cards (Radius 16px)
- Cyclic breathing white borders (Sine-wave brightness modulation from #252528 to #FFFFFF)
- Human-friendly business terminology (zero raw code console noise)
- Windows subprocess CREATE_NO_WINDOW flags (zero black CMD popups)
- Pure standard library + Tkinter (zero extra pip dependencies)
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
        "name": "MDAC 马来西亚自动申报服务",
        "desc": "批量入境卡申报 · 官方拼图滑块自适应验证",
        "badge": "核心申报",
        "badge_bg": "#14281E",
        "badge_fg": "#4ADE80",
        "script": "services/mdac-fill-preview/worker.py",
        "args": ["--poll"],
        "icon": "⚡",
    },
    {
        "id": "reg",
        "name": "官方入境登记凭证核验",
        "desc": "Registration 登记号查验 · 状态自动回填",
        "badge": "登记核验",
        "badge_bg": "#132338",
        "badge_fg": "#60A5FA",
        "script": "services/registration-check-worker/worker.py",
        "args": ["--poll"],
        "icon": "🔍",
    },
    {
        "id": "vp",
        "name": "Visit Pass 电子入境签核验",
        "desc": "官方电子准证查验 · 签发凭证自动存盘",
        "badge": "准证核验",
        "badge_bg": "#28173B",
        "badge_fg": "#C084FC",
        "script": "services/visit-pass-check-worker/worker.py",
        "args": ["--poll"],
        "icon": "🛂",
    },
    {
        "id": "ocr",
        "name": "Azure 智能护照识别 (OCR)",
        "desc": "护照全量字段高精度提取 · 智能档案校验",
        "badge": "护照识别",
        "badge_bg": "#132A26",
        "badge_fg": "#2DD4BF",
        "script": "worker/azure_ocr_worker.py",
        "args": ["--poll"],
        "icon": "📷",
    },
    {
        "id": "pin",
        "name": "Gmail PIN 验证码自动抓取",
        "desc": "移民局官方邮件监听 · 验证码毫秒级提取",
        "badge": "邮件验证",
        "badge_bg": "#331625",
        "badge_fg": "#F472B6",
        "script": "services/gmail-pin-worker/worker.py",
        "args": ["--poll"],
        "icon": "📬",
    },
]

# Pure Black Palette
BG_MAIN = "#000000"         # Jet Black
BG_CARD = "#08080A"         # Obsidian Card
BG_CARD_INNER = "#0C0C0F"   # Metric pill
BORDER_DIM = "#222226"      # Rest state border
BORDER_ACTIVE = "#FFFFFF"   # Pure White Light
TEXT_WHITE = "#FFFFFF"      # Crisp White
TEXT_MUTED = "#8E8E93"      # Clean neutral grey
TEXT_DARK = "#48484A"       # Subtle border & hint
ACCENT_GREEN = "#34D399"    # Neon Emerald
ACCENT_CYAN = "#38BDF8"     # Electric Cyan
ACCENT_AMBER = "#FBBF24"    # Amber Warning
ACCENT_RED = "#F87171"      # Red Alert

FONT_CN = "Microsoft YaHei UI"
FONT_EN = "Segoe UI"


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
                return "🟢 服务就绪上线，已连接队列开始巡航"
            if step in ("batch_claim", "item_claim"):
                return "📥 领取到新业务工单，正在执行核查..."
            if step == "result_writeback":
                if status == "succeeded":
                    res = data.get("result", "")
                    return f"✅ 核查结果已保存回填 (状态: {res})"
                elif status == "failed":
                    return f"ℹ️ 官方核查未能确认: {err_msg or '请检查官网或输入'}"
            if err_msg and str(err_msg).lower() != "null":
                return f"⚠️ 提示: {err_msg}"
            return None
        except Exception:
            return None

    # Specific Service events
    if service_id == "mdac":
        if "已领取 mdac 批次" in raw_line:
            return "📥 收到新申报批次任务，准备启动自动填报"
        if "检测到 mdac 滑块" in raw_line or "slider_solver" in low:
            return "🧩 检测到官方拼图滑块，正在自适应识别对齐"
        if "滑块验证成功" in raw_line:
            return "✅ 滑块拼图校验通过"
        if "已点击官方 submit" in raw_line:
            return "🚀 已提交至移民局官网，等待受理确认"
        if "官方注册成功" in raw_line or "status=succeeded" in low:
            return "🎉 客户申报成功，官方凭证已写回系统"
        if "needs_review" in low or "失败" in raw_line:
            return "⚠️ 遇到官方网页异常，已安全转人工核实"

    elif service_id == "reg":
        if "已领取" in raw_line or "claimed" in low:
            return "📥 收到登记核验任务，正在连接官方接口核对"
        if "核验成功" in raw_line or "success" in low or "status=succeeded" in low:
            return "✅ 官方登记凭证已核验完毕，状态已更新"

    elif service_id == "vp":
        if "已领取" in raw_line or "claimed" in low:
            return "📥 收到 Visit Pass 查签任务，正在查询入境准证"
        if "提取" in raw_line and "visit pass" in low:
            return "📄 成功提取到官方电子入境准证"
        if "success" in low or "status=succeeded" in low:
            return "✅ Visit Pass 准证核验完成并存盘"

    elif service_id == "ocr":
        if "claimed" in low or "领取" in raw_line:
            return "📥 收到待识别护照图片，正在进行智能解析"
        if "ocr" in low and ("成功" in raw_line or "completed" in low or "success" in low):
            return "🔍 护照 OCR 信息识别提取完毕，已建档校验"

    elif service_id == "pin":
        if "claimed" in low or "领取" in raw_line:
            return "📥 正在扫描移民局官方邮件..."
        if "pin" in low and ("提取" in raw_line or "received" in low or "成功" in raw_line):
            return "🔑 成功提取官方 PIN 安全验证码"

    # Catch-all
    if "succeeded" in low or "完成" in raw_line or "成功" in raw_line:
        return "✨ 业务任务处理顺利完成"
    if ("error" in low or "exception" in low or "失败" in raw_line) and "error_code\": null" not in low and "error\": null" not in low:
        if not stripped.startswith("{"):
            clean = raw_line.replace("ERROR", "").replace("Exception", "").strip()
            if len(clean) > 40:
                clean = clean[:38] + "..."
            return f"⚠️ 提示: {clean}"

    return None


class RoundedCard(tk.Canvas):
    """Custom canvas that renders a smooth anti-aliased rounded card with dynamic breathing borders."""

    def __init__(self, parent, height: int, radius: int = 16, bg_color: str = BG_CARD, border_color: str = BORDER_DIM, border_width: float = 1.5, **kwargs):
        super().__init__(parent, height=height, bg=BG_MAIN, highlightthickness=0, **kwargs)
        self.radius = radius
        self.bg_color = bg_color
        self.border_width = border_width
        self.poly_id = None
        self.win_id = None

        self.inner = tk.Frame(self, bg=bg_color)
        self.bind("<Configure>", self._on_resize)

    def _on_resize(self, event):
        w, h = event.width, event.height
        if w < 20 or h < 20:
            return
        r = self.radius
        x1, y1, x2, y2 = 2, 2, w - 2, h - 2
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
        if self.poly_id is None:
            self.poly_id = self.create_polygon(
                points,
                fill=self.bg_color,
                outline=BORDER_DIM,
                width=self.border_width,
                smooth=True,
            )
            self.win_id = self.create_window(
                14, 10,
                window=self.inner,
                anchor="nw",
                width=w - 28,
                height=h - 20,
            )
        else:
            self.coords(self.poly_id, *points)
            self.coords(self.win_id, 14, 10)
            self.itemconfigure(self.win_id, width=w - 28, height=h - 20)

    def set_border(self, color_hex: str):
        if self.poly_id is not None:
            self.itemconfig(self.poly_id, outline=color_hex)


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
            time.sleep(0.12)

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
                    self.on_status_change(w_id, "随时待命 · 队列空闲", "ready")

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
                    elif any(k in low for k in ["succeeded", "成功", "完成", "done"]):
                        if self.on_status_change:
                            self.on_status_change(w_id, "任务完成 · 待命中", "ready")
                    elif any(k in low for k in ["idle", "waiting", "heartbeat", "空闲"]):
                        if self.on_status_change:
                            self.on_status_change(w_id, "随时待命 · 队列空闲", "ready")

                proc.wait()
            except Exception as e:
                if self.on_raw_log:
                    self.on_raw_log(w_info["badge"], f"运行异常: {e}")

            if self.stop_event.is_set():
                break

            if self.on_status_change:
                self.on_status_change(w_id, "服务离线，3秒后自动重启...", "error")
            time.sleep(3)


class PureBlackWorkerApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("Passport MDAC Desk · 自动化控制中枢")
        self.root.geometry("620x820+30+20")
        self.root.minsize(560, 720)
        self.root.configure(bg=BG_MAIN)

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
        self._start_breathing_loop()
        self._start_uptime_ticker()

        # Start workers
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
        # 1. Top Brand Header
        header_box = tk.Frame(self.root, bg=BG_MAIN)
        header_box.pack(fill=tk.X, padx=26, pady=(22, 10))

        brand_line = tk.Frame(header_box, bg=BG_MAIN)
        brand_line.pack(fill=tk.X)

        title_lbl = tk.Label(
            brand_line,
            text="PASSPORT MDAC DESK",
            font=(FONT_EN, 13, "bold"),
            fg=TEXT_WHITE,
            bg=BG_MAIN,
        )
        title_lbl.pack(side=tk.LEFT)

        ver_badge = tk.Label(
            brand_line,
            text="AUTOMATION SUITE · v1.0.43",
            font=(FONT_EN, 8, "bold"),
            fg=TEXT_MUTED,
            bg="#111114",
            padx=8,
            pady=2,
        )
        ver_badge.pack(side=tk.LEFT, padx=12)

        # 2. Hero Card with White Breathing Border
        self.hero_card = RoundedCard(self.root, height=140, radius=18, bg_color=BG_CARD, border_width=2.0)
        self.hero_card.pack(fill=tk.X, padx=26, pady=(4, 14))
        self.breathing_cards.append((self.hero_card, 1.0))  # Full intensity breathing

        hero_top = tk.Frame(self.hero_card.inner, bg=BG_CARD)
        hero_top.pack(fill=tk.X, padx=6, pady=(6, 10))

        # Glowing white/emerald canvas halo
        self.light_canvas = tk.Canvas(hero_top, width=44, height=44, bg=BG_CARD, highlightthickness=0)
        self.light_canvas.pack(side=tk.LEFT, padx=(0, 14))

        hero_titles = tk.Frame(hero_top, bg=BG_CARD)
        hero_titles.pack(side=tk.LEFT, fill=tk.Y)

        self.hero_title = tk.Label(
            hero_titles,
            text="全套自动化服务平稳巡航中",
            font=(FONT_CN, 12, "bold"),
            fg=TEXT_WHITE,
            bg=BG_CARD,
        )
        self.hero_title.pack(anchor=tk.W)

        self.hero_sub = tk.Label(
            hero_titles,
            text="5 组高并发任务 Worker 待命 · 实时监听 Supabase 任务队列",
            font=(FONT_CN, 9),
            fg=TEXT_MUTED,
            bg=BG_CARD,
        )
        self.hero_sub.pack(anchor=tk.W, pady=(3, 0))

        # Metrics Row inside Hero Card
        metrics_bar = tk.Frame(self.hero_card.inner, bg=BG_CARD_INNER, highlightbackground="#18181B", highlightthickness=1)
        metrics_bar.pack(fill=tk.X, padx=4, pady=(0, 4))

        m1 = tk.Frame(metrics_bar, bg=BG_CARD_INNER)
        m1.pack(side=tk.LEFT, expand=True, fill=tk.BOTH, pady=6)
        tk.Label(m1, text="平稳运行时长", font=(FONT_CN, 8), fg=TEXT_MUTED, bg=BG_CARD_INNER).pack()
        self.lbl_uptime = tk.Label(m1, text="00:00:00", font=(FONT_EN, 11, "bold"), fg=TEXT_WHITE, bg=BG_CARD_INNER)
        self.lbl_uptime.pack()

        tk.Frame(metrics_bar, width=1, bg="#1C1C20").pack(side=tk.LEFT, fill=tk.Y, pady=4)

        m2 = tk.Frame(metrics_bar, bg=BG_CARD_INNER)
        m2.pack(side=tk.LEFT, expand=True, fill=tk.BOTH, pady=6)
        tk.Label(m2, text="本次处理业务", font=(FONT_CN, 8), fg=TEXT_MUTED, bg=BG_CARD_INNER).pack()
        self.lbl_processed = tk.Label(m2, text="0 笔", font=(FONT_EN, 11, "bold"), fg=ACCENT_GREEN, bg=BG_CARD_INNER)
        self.lbl_processed.pack()

        tk.Frame(metrics_bar, width=1, bg="#1C1C20").pack(side=tk.LEFT, fill=tk.Y, pady=4)

        m3 = tk.Frame(metrics_bar, bg=BG_CARD_INNER)
        m3.pack(side=tk.LEFT, expand=True, fill=tk.BOTH, pady=6)
        tk.Label(m3, text="云端通信链路", font=(FONT_CN, 8), fg=TEXT_MUTED, bg=BG_CARD_INNER).pack()
        self.lbl_cloud = tk.Label(m3, text="保持就绪", font=(FONT_CN, 10, "bold"), fg=TEXT_WHITE, bg=BG_CARD_INNER)
        self.lbl_cloud.pack()

        # 3. Monitored Services List
        sec_label = tk.Label(
            self.root,
            text="服务运行状态",
            font=(FONT_CN, 9, "bold"),
            fg=TEXT_MUTED,
            bg=BG_MAIN,
        )
        sec_label.pack(anchor=tk.W, padx=30, pady=(2, 6))

        for w in WORKERS_CONFIG:
            card = RoundedCard(self.root, height=54, radius=14, bg_color=BG_CARD, border_width=1.2)
            card.pack(fill=tk.X, padx=26, pady=3)
            self.breathing_cards.append((card, 0.45))  # Subtle white breathing glow for service cards

            # Left block: icon + title + desc
            left_box = tk.Frame(card.inner, bg=BG_CARD)
            left_box.pack(side=tk.LEFT, fill=tk.Y)

            icon_lbl = tk.Label(
                left_box,
                text=w["icon"],
                font=(FONT_CN, 11),
                bg=BG_CARD,
            )
            icon_lbl.pack(side=tk.LEFT, padx=(2, 8))

            info_box = tk.Frame(left_box, bg=BG_CARD)
            info_box.pack(side=tk.LEFT, anchor=tk.W)

            title_row = tk.Frame(info_box, bg=BG_CARD)
            title_row.pack(anchor=tk.W)

            name_lbl = tk.Label(
                title_row,
                text=w["name"],
                font=(FONT_CN, 9, "bold"),
                fg=TEXT_WHITE,
                bg=BG_CARD,
            )
            name_lbl.pack(side=tk.LEFT)

            badge_lbl = tk.Label(
                title_row,
                text=w["badge"],
                font=(FONT_CN, 7, "bold"),
                fg=w["badge_fg"],
                bg=w["badge_bg"],
                padx=5,
                pady=1,
            )
            badge_lbl.pack(side=tk.LEFT, padx=6)

            desc_lbl = tk.Label(
                info_box,
                text=w["desc"],
                font=(FONT_CN, 8),
                fg=TEXT_MUTED,
                bg=BG_CARD,
            )
            desc_lbl.pack(anchor=tk.W, pady=(1, 0))

            # Right status indicator
            right_box = tk.Frame(card.inner, bg=BG_CARD)
            right_box.pack(side=tk.RIGHT, fill=tk.Y)

            dot_canvas = tk.Canvas(right_box, width=8, height=8, bg=BG_CARD, highlightthickness=0)
            dot_canvas.pack(side=tk.LEFT, padx=(0, 6))
            dot = dot_canvas.create_oval(1, 1, 7, 7, fill=ACCENT_GREEN, outline="")

            status_lbl = tk.Label(
                right_box,
                text="随时待命",
                font=(FONT_CN, 8, "bold"),
                fg=ACCENT_GREEN,
                bg=BG_CARD,
            )
            status_lbl.pack(side=tk.LEFT)

            self.worker_widgets[w["id"]] = {
                "card": card,
                "dot_canvas": dot_canvas,
                "dot": dot,
                "status_lbl": status_lbl,
            }

        # 4. Business Activity Timeline Section
        feed_header = tk.Frame(self.root, bg=BG_MAIN)
        feed_header.pack(fill=tk.X, padx=30, pady=(12, 6))

        feed_title = tk.Label(
            feed_header,
            text="业务实时播报",
            font=(FONT_CN, 9, "bold"),
            fg=TEXT_MUTED,
            bg=BG_MAIN,
        )
        feed_title.pack(side=tk.LEFT)

        feed_hint = tk.Label(
            feed_header,
            text="动态翻译官方日志",
            font=(FONT_CN, 8),
            fg=TEXT_DARK,
            bg=BG_MAIN,
        )
        feed_hint.pack(side=tk.RIGHT)

        # Timeline Rounded Card
        self.timeline_card = RoundedCard(self.root, height=130, radius=16, bg_color=BG_CARD, border_width=1.2)
        self.timeline_card.pack(fill=tk.BOTH, expand=True, padx=26, pady=2)
        self.breathing_cards.append((self.timeline_card, 0.4))

        self.timeline_box = tk.Frame(self.timeline_card.inner, bg=BG_CARD)
        self.timeline_box.pack(fill=tk.BOTH, expand=True, padx=8, pady=4)

        self.empty_lbl = tk.Label(
            self.timeline_box,
            text="等待队列新任务中... 5 组自动化服务已连接处于就绪状态",
            font=(FONT_CN, 9),
            fg=TEXT_MUTED,
            bg=BG_CARD,
            pady=16,
        )
        self.empty_lbl.pack()

        # 5. Bottom Action Bar
        bottom_bar = tk.Frame(self.root, bg=BG_MAIN)
        bottom_bar.pack(fill=tk.X, padx=26, pady=(10, 14))

        self.btn_toggle_tech = tk.Button(
            bottom_bar,
            text="查看技术日志 ▾",
            font=(FONT_CN, 8),
            fg=TEXT_MUTED,
            bg=BG_CARD,
            activeforeground=TEXT_WHITE,
            activebackground="#1C1C20",
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
            text="🔄 平稳重启全部服务",
            font=(FONT_CN, 8, "bold"),
            fg=TEXT_WHITE,
            bg="#18181B",
            activeforeground="#FFFFFF",
            activebackground="#27272A",
            relief=tk.FLAT,
            bd=0,
            padx=14,
            pady=6,
            cursor="hand2",
            command=self.manager.restart,
        )
        btn_restart.pack(side=tk.RIGHT)

        # Collapsible Tech Log Drawer
        self.tech_frame = tk.Frame(self.root, bg="#050507", highlightbackground=BORDER_DIM, highlightthickness=1)
        self.tech_text = tk.Text(
            self.tech_frame,
            bg="#050507",
            fg="#A1A1AA",
            insertbackground=TEXT_WHITE,
            font=("Consolas", 8),
            relief=tk.FLAT,
            bd=0,
            padx=10,
            pady=8,
            height=6,
        )
        self.tech_text.pack(fill=tk.BOTH, expand=True)

    def _toggle_tech_log(self):
        if self.log_visible:
            self.tech_frame.pack_forget()
            self.btn_toggle_tech.config(text="查看技术日志 ▾")
            self.log_visible = False
        else:
            self.tech_frame.pack(fill=tk.BOTH, expand=False, padx=26, pady=(0, 12))
            self.btn_toggle_tech.config(text="收起技术日志 ▴")
            self.log_visible = True

    def _start_breathing_loop(self):
        """Cyclic breathing light on card borders & central halo: white brightness raises & lowers smoothly."""
        def animate():
            t = time.time()
            # Sine wave oscillation (period ~2.4 seconds)
            val = 0.5 * (1 + math.sin(t * 2.6))  # 0.0 ~ 1.0

            # 1. Update White Breathing Borders for Cards
            # Range: Dim #222226 to Radiant White #FFFFFF
            for card, factor in self.breathing_cards:
                min_b = 30
                max_b = int(30 + factor * 225)
                cur_b = int(min_b + val * (max_b - min_b))
                border_hex = f"#{cur_b:02x}{cur_b:02x}{cur_b:02x}"
                card.set_border(border_hex)

            # 2. Central Halo Animation in Hero Card
            # Smooth pulsing white core & soft grey outer aura
            core_b = int(120 + val * 135)
            core_hex = f"#{core_b:02x}{core_b:02x}{core_b:02x}"
            halo_b = int(24 + val * 60)
            halo_hex = f"#{halo_b:02x}{halo_b:02x}{halo_b:02x}"

            outer_r = 15 + val * 4.5
            inner_r = 7 + val * 2.0
            cx, cy = 22, 22

            self.light_canvas.delete("all")
            # Outer soft halo
            self.light_canvas.create_oval(
                cx - outer_r, cy - outer_r, cx + outer_r, cy + outer_r, fill=halo_hex, outline=""
            )
            # Inner bright core
            self.light_canvas.create_oval(
                cx - inner_r, cy - inner_r, cx + inner_r, cy + inner_r, fill=core_hex, outline=""
            )

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
                self.lbl_processed.config(text=f"{self.processed_count} 笔")

            row = tk.Frame(self.timeline_box, bg=BG_CARD)
            row.pack(fill=tk.X, pady=2, anchor=tk.W)

            time_lbl = tk.Label(
                row,
                text=now_str,
                font=(FONT_EN, 8),
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
                fg=TEXT_WHITE,
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
            if state_type == "active":
                w["dot_canvas"].itemconfig(w["dot"], fill=ACCENT_CYAN)
                w["status_lbl"].config(fg=ACCENT_CYAN)
            elif state_type == "ready":
                w["dot_canvas"].itemconfig(w["dot"], fill=ACCENT_GREEN)
                w["status_lbl"].config(fg=ACCENT_GREEN)
            elif state_type == "connecting":
                w["dot_canvas"].itemconfig(w["dot"], fill=ACCENT_AMBER)
                w["status_lbl"].config(fg=ACCENT_AMBER)
            else:
                w["dot_canvas"].itemconfig(w["dot"], fill=ACCENT_RED)
                w["status_lbl"].config(fg=ACCENT_RED)

        self.root.after_idle(update)

    def _on_close(self):
        self.manager.stop()
        self.root.destroy()


def main():
    try:
        root = tk.Tk()
        app = PureBlackWorkerApp(root)
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
