"""Modern Linear/Spotify-inspired Dark Theme GUI for MDAC Worker Suite.

Theme: Deep Slate / Obsidian Blue (#090D16)
Palette: Linear & Spotify Tech-Dark (#121927, #1E293B, #10B981, #38BDF8)
Features:
- Pure business-oriented terminology (zero developer jargon / raw code console style)
- Real-time business activity timeline translation
- System health & uptime dashboard metrics
- Soft sine-wave breathing indicator (Spotify emerald & cyan glow)
- Expandable technical debug drawer
- Zero extra external pip dependencies (Pure standard library + Tkinter)
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
        "desc": "批量入境卡填报 · 官方滑块拼图自适应验证",
        "badge": "核心申报",
        "badge_color": "#065F46",
        "badge_fg": "#34D399",
        "script": "services/mdac-fill-preview/worker.py",
        "args": ["--poll"],
        "icon": "⚡",
    },
    {
        "id": "reg",
        "name": "官方登记凭证核验服务",
        "desc": "Registration 官方登记号查验 · 状态自动回填",
        "badge": "登记核验",
        "badge_color": "#1E3A8A",
        "badge_fg": "#60A5FA",
        "script": "services/registration-check-worker/worker.py",
        "args": ["--poll"],
        "icon": "🔍",
    },
    {
        "id": "vp",
        "name": "Visit Pass 电子入境签核验",
        "desc": "电子准证状态获取 · 官方核验结果存盘",
        "badge": "准证核验",
        "badge_color": "#581C87",
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
        "badge_color": "#134E4A",
        "badge_fg": "#2DD4BF",
        "script": "worker/azure_ocr_worker.py",
        "args": ["--poll"],
        "icon": "📷",
    },
    {
        "id": "pin",
        "name": "Gmail PIN 验证码自动抓取",
        "desc": "移民局官方邮件实时监听 · 验证码毫秒级提取",
        "badge": "邮件验证",
        "badge_color": "#831843",
        "badge_fg": "#F472B6",
        "script": "services/gmail-pin-worker/worker.py",
        "args": ["--poll"],
        "icon": "📬",
    },
]

# Color Palette (Linear / Spotify Premium Slate Dark)
BG_MAIN = "#090D16"         # Deep obsidian slate
BG_CARD = "#121927"         # Elevated glass card
BG_CARD_HOVER = "#172134"   # Card hover state
BORDER_SUBTLE = "#1E293B"   # Subtle card border
BORDER_ACTIVE = "#38BDF8"   # Sky blue focus
TEXT_TITLE = "#F8FAFC"      # Clean crisp white (Slate 50)
TEXT_SUB = "#94A3B8"        # Soft muted slate (Slate 400)
TEXT_MUTED = "#64748B"      # Darker hint (Slate 500)
ACCENT_GREEN = "#10B981"    # Emerald green
ACCENT_CYAN = "#38BDF8"     # Sky cyan
ACCENT_AMBER = "#F59E0B"    # Amber warning
ACCENT_RED = "#EF4444"      # Rose red error

FONT_FAMILY = "Microsoft YaHei UI"


def translate_log_to_business(service_id: str, raw_line: str) -> str | None:
    """Translates raw console code logs into human-friendly business messages."""
    low = raw_line.lower()

    # Filter out pure noise / polling lines
    if "polling" in low or "heartbeat" in low or "sleep" in low:
        return None
    if "=================" in raw_line or "worker id:" in low:
        return None

    # Service-specific translations
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
        if "needs_review" in low:
            return "ℹ️ 登记号查无记录或需人工复查"

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
        if "claimed" in low or "领取" in raw_line or "polling" in low:
            return "📥 正在扫描移民局官方邮件..."
        if "pin" in low and ("提取" in raw_line or "received" in low or "成功" in raw_line):
            return "🔑 成功提取官方 PIN 安全验证码"

    # Structured JSON log handler (from Registration / Visit Pass workers)
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

    # Generic catch-all
    if "succeeded" in low or "完成" in raw_line or "成功" in raw_line:
        return "✨ 业务任务处理顺利完成"
    if ("error" in low or "exception" in low or "失败" in raw_line) and "error_code\": null" not in low and "error\": null" not in low:
        if not stripped.startswith("{"):
            clean = raw_line.replace("ERROR", "").replace("Exception", "").strip()
            if len(clean) > 40:
                clean = clean[:38] + "..."
            return f"⚠️ 提示: {clean}"

    return None


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
        w_name = w_info["name"]
        script_path = os.path.join(REPO_ROOT, w_info["script"])
        env = os.environ.copy()
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"

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

                    # Deliver raw log for tech drawer
                    if self.on_raw_log:
                        self.on_raw_log(w_info["badge"], line)

                    # Translate to business event
                    b_msg = translate_log_to_business(w_id, line)
                    if b_msg and self.on_business_event:
                        self.on_business_event(w_info["badge"], b_msg, w_info["icon"])

                    # Update status
                    low = line.lower()
                    if any(k in low for k in ["claimed", "已领取", "processing", "检测到", "正在尝试"]):
                        if self.on_status_change:
                            self.on_status_change(w_id, "⚡ 正在执行任务...", "active")
                    elif any(k in low for k in ["succeeded", "成功", "完成", "done"]):
                        if self.on_status_change:
                            self.on_status_change(w_id, "✅ 任务完成 · 待命中", "ready")
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


class ModernWorkerApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("Passport MDAC Desk · 自动化控制中枢")
        self.root.geometry("600x820")
        self.root.minsize(560, 680)
        self.root.configure(bg=BG_MAIN)

        self.start_time = time.time()
        self.processed_count = 0
        self.log_visible = False
        self.worker_widgets = {}
        self.timeline_items = []

        self.manager = WorkerManager(
            on_business_event=self._on_business_event,
            on_raw_log=self._on_raw_log,
            on_status_change=self._on_status_change,
        )

        self._build_ui()
        self._enable_dark_titlebar()
        self._start_breathing_animation()
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
        # 1. Top Header Area
        top_header = tk.Frame(self.root, bg=BG_MAIN)
        top_header.pack(fill=tk.X, padx=24, pady=(20, 10))

        # Brand row
        brand_row = tk.Frame(top_header, bg=BG_MAIN)
        brand_row.pack(fill=tk.X)

        title_lbl = tk.Label(
            brand_row,
            text="PASSPORT MDAC DESK",
            font=(FONT_FAMILY, 14, "bold"),
            fg=TEXT_TITLE,
            bg=BG_MAIN,
        )
        title_lbl.pack(side=tk.LEFT)

        version_pill = tk.Label(
            brand_row,
            text="v1.0.43 自动化中枢",
            font=(FONT_FAMILY, 8, "bold"),
            fg=ACCENT_CYAN,
            bg="#0F2847",
            padx=8,
            pady=2,
        )
        version_pill.pack(side=tk.LEFT, padx=10)

        # 2. Hero Breathing Dashboard Card
        hero_card = tk.Frame(self.root, bg=BG_CARD, highlightbackground=BORDER_SUBTLE, highlightthickness=1)
        hero_card.pack(fill=tk.X, padx=24, pady=(6, 14))

        hero_inner = tk.Frame(hero_card, bg=BG_CARD)
        hero_inner.pack(fill=tk.X, padx=18, pady=14)

        # Left Breathing Light Canvas
        self.light_canvas = tk.Canvas(hero_inner, width=46, height=46, bg=BG_CARD, highlightthickness=0)
        self.light_canvas.pack(side=tk.LEFT, padx=(0, 16))

        # Middle Status Title & Subtitle
        mid_status = tk.Frame(hero_inner, bg=BG_CARD)
        mid_status.pack(side=tk.LEFT, fill=tk.Y)

        self.hero_title = tk.Label(
            mid_status,
            text="全套自动化服务平稳巡航中",
            font=(FONT_FAMILY, 12, "bold"),
            fg=TEXT_TITLE,
            bg=BG_CARD,
        )
        self.hero_title.pack(anchor=tk.W)

        self.hero_sub = tk.Label(
            mid_status,
            text="5 组高并发 Worker 就绪待命 · 实时监听 Supabase 任务队列",
            font=(FONT_FAMILY, 9),
            fg=TEXT_SUB,
            bg=BG_CARD,
        )
        self.hero_sub.pack(anchor=tk.W, pady=(3, 0))

        # Metric Tiles (Uptime + Processed)
        metrics_frame = tk.Frame(hero_card, bg="#0E1420", highlightbackground=BORDER_SUBTLE, highlightthickness=1)
        metrics_frame.pack(fill=tk.X, padx=14, pady=(0, 14))

        m1 = tk.Frame(metrics_frame, bg="#0E1420")
        m1.pack(side=tk.LEFT, expand=True, fill=tk.BOTH, pady=8)
        tk.Label(m1, text="平稳运行时长", font=(FONT_FAMILY, 8), fg=TEXT_MUTED, bg="#0E1420").pack()
        self.lbl_uptime = tk.Label(m1, text="00:00:00", font=(FONT_FAMILY, 11, "bold"), fg=TEXT_TITLE, bg="#0E1420")
        self.lbl_uptime.pack()

        div1 = tk.Frame(metrics_frame, width=1, bg=BORDER_SUBTLE)
        div1.pack(side=tk.LEFT, fill=tk.Y, pady=6)

        m2 = tk.Frame(metrics_frame, bg="#0E1420")
        m2.pack(side=tk.LEFT, expand=True, fill=tk.BOTH, pady=8)
        tk.Label(m2, text="本次处理业务", font=(FONT_FAMILY, 8), fg=TEXT_MUTED, bg="#0E1420").pack()
        self.lbl_processed = tk.Label(m2, text="0 笔", font=(FONT_FAMILY, 11, "bold"), fg=ACCENT_GREEN, bg="#0E1420")
        self.lbl_processed.pack()

        div2 = tk.Frame(metrics_frame, width=1, bg=BORDER_SUBTLE)
        div2.pack(side=tk.LEFT, fill=tk.Y, pady=6)

        m3 = tk.Frame(metrics_frame, bg="#0E1420")
        m3.pack(side=tk.LEFT, expand=True, fill=tk.BOTH, pady=8)
        tk.Label(m3, text="云端通信链路", font=(FONT_FAMILY, 8), fg=TEXT_MUTED, bg="#0E1420").pack()
        self.lbl_cloud = tk.Label(m3, text="正常保持", font=(FONT_FAMILY, 11, "bold"), fg=ACCENT_CYAN, bg="#0E1420")
        self.lbl_cloud.pack()

        # 3. Monitored Services List
        sec_title = tk.Label(
            self.root,
            text="服务运行状态",
            font=(FONT_FAMILY, 9, "bold"),
            fg=TEXT_MUTED,
            bg=BG_MAIN,
        )
        sec_title.pack(anchor=tk.W, padx=28, pady=(4, 6))

        services_frame = tk.Frame(self.root, bg=BG_MAIN)
        services_frame.pack(fill=tk.X, padx=24)

        for w in WORKERS_CONFIG:
            card = tk.Frame(services_frame, bg=BG_CARD, highlightbackground=BORDER_SUBTLE, highlightthickness=1)
            card.pack(fill=tk.X, pady=3)

            # Left column: Icon & Title
            left = tk.Frame(card, bg=BG_CARD)
            left.pack(side=tk.LEFT, padx=12, pady=8)

            # Icon circle
            icon_lbl = tk.Label(
                left,
                text=w["icon"],
                font=(FONT_FAMILY, 12),
                bg=BG_CARD,
            )
            icon_lbl.pack(side=tk.LEFT, padx=(2, 10))

            # Names & Desc
            name_box = tk.Frame(left, bg=BG_CARD)
            name_box.pack(side=tk.LEFT)

            t_row = tk.Frame(name_box, bg=BG_CARD)
            t_row.pack(anchor=tk.W)

            title = tk.Label(
                t_row,
                text=w["name"],
                font=(FONT_FAMILY, 10, "bold"),
                fg=TEXT_TITLE,
                bg=BG_CARD,
            )
            title.pack(side=tk.LEFT)

            badge = tk.Label(
                t_row,
                text=w["badge"],
                font=(FONT_FAMILY, 7, "bold"),
                fg=w["badge_fg"],
                bg=w["badge_color"],
                padx=5,
                pady=1,
            )
            badge.pack(side=tk.LEFT, padx=6)

            desc = tk.Label(
                name_box,
                text=w["desc"],
                font=(FONT_FAMILY, 8),
                fg=TEXT_SUB,
                bg=BG_CARD,
            )
            desc.pack(anchor=tk.W, pady=(1, 0))

            # Right Status Capsule
            right = tk.Frame(card, bg=BG_CARD)
            right.pack(side=tk.RIGHT, padx=14, pady=8)

            dot_canvas = tk.Canvas(right, width=8, height=8, bg=BG_CARD, highlightthickness=0)
            dot_canvas.pack(side=tk.LEFT, padx=(0, 6))
            dot = dot_canvas.create_oval(1, 1, 7, 7, fill=ACCENT_GREEN, outline="")

            status_lbl = tk.Label(
                right,
                text="随时待命",
                font=(FONT_FAMILY, 9),
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
        feed_header.pack(fill=tk.X, padx=28, pady=(14, 6))

        feed_title = tk.Label(
            feed_header,
            text="业务实时播报",
            font=(FONT_FAMILY, 9, "bold"),
            fg=TEXT_MUTED,
            bg=BG_MAIN,
        )
        feed_title.pack(side=tk.LEFT)

        feed_hint = tk.Label(
            feed_header,
            text="动态翻译官方日志",
            font=(FONT_FAMILY, 8),
            fg=TEXT_MUTED,
            bg=BG_MAIN,
        )
        feed_hint.pack(side=tk.RIGHT)

        # Timeline Card Container
        self.timeline_card = tk.Frame(self.root, bg=BG_CARD, highlightbackground=BORDER_SUBTLE, highlightthickness=1)
        self.timeline_card.pack(fill=tk.BOTH, expand=True, padx=24, pady=2)

        self.timeline_box = tk.Frame(self.timeline_card, bg=BG_CARD)
        self.timeline_box.pack(fill=tk.BOTH, expand=True, padx=14, pady=10)

        # Initial Empty state
        self.empty_lbl = tk.Label(
            self.timeline_box,
            text="等待队列新任务中... 各服务正处于巡航监听状态",
            font=(FONT_FAMILY, 9),
            fg=TEXT_MUTED,
            bg=BG_CARD,
            pady=16,
        )
        self.empty_lbl.pack()

        # 5. Bottom Action Bar & Tech Log Drawer
        bottom_bar = tk.Frame(self.root, bg=BG_MAIN)
        bottom_bar.pack(fill=tk.X, padx=24, pady=(10, 14))

        self.btn_toggle_tech = tk.Button(
            bottom_bar,
            text="查看技术日志 ▾",
            font=(FONT_FAMILY, 8),
            fg=TEXT_SUB,
            bg=BG_CARD,
            activeforeground=TEXT_TITLE,
            activebackground=BG_CARD_HOVER,
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
            font=(FONT_FAMILY, 9, "bold"),
            fg=TEXT_TITLE,
            bg="#1E293B",
            activeforeground="#FFFFFF",
            activebackground="#334155",
            relief=tk.FLAT,
            bd=0,
            padx=16,
            pady=6,
            cursor="hand2",
            command=self.manager.restart,
        )
        btn_restart.pack(side=tk.RIGHT)

        # Collapsible Tech Log Drawer
        self.tech_frame = tk.Frame(self.root, bg="#080C14", highlightbackground=BORDER_SUBTLE, highlightthickness=1)
        self.tech_text = tk.Text(
            self.tech_frame,
            bg="#080C14",
            fg="#94A3B8",
            insertbackground=TEXT_TITLE,
            font=("Consolas", 8),
            relief=tk.FLAT,
            bd=0,
            padx=10,
            pady=8,
            height=7,
        )
        self.tech_text.pack(fill=tk.BOTH, expand=True)

    def _toggle_tech_log(self):
        if self.log_visible:
            self.tech_frame.pack_forget()
            self.btn_toggle_tech.config(text="查看技术日志 ▾")
            self.log_visible = False
        else:
            self.tech_frame.pack(fill=tk.BOTH, expand=False, padx=24, pady=(0, 14))
            self.btn_toggle_tech.config(text="收起技术日志 ▴")
            self.log_visible = True

    def _start_breathing_animation(self):
        def animate():
            t = time.time()
            # Smooth sine wave cycle (~2.8s period)
            val = 0.5 * (1 + math.sin(t * 2.3))  # 0.0 ~ 1.0

            # Linear Emerald & Cyan blend
            # Emerald: #10B981 (16, 185, 129)
            # Cyan: #06B6D4 (6, 182, 212)
            r = int(6 + val * 10)
            g = int(180 + val * 15)
            b = int(140 + val * 60)
            core_hex = f"#{r:02x}{g:02x}{b:02x}"

            # Subtle outer glow halo
            hr = int(4 + val * 6)
            hg = int(60 + val * 40)
            hb = int(50 + val * 50)
            halo_hex = f"#{hr:02x}{hg:02x}{hb:02x}"

            outer_r = 16 + val * 4.0
            inner_r = 7 + val * 2.0
            cx, cy = 23, 23

            self.light_canvas.delete("all")
            # Outer soft halo
            self.light_canvas.create_oval(
                cx - outer_r, cy - outer_r, cx + outer_r, cy + outer_r, fill=halo_hex, outline=""
            )
            # Inner bright pulse
            self.light_canvas.create_oval(
                cx - inner_r, cy - inner_r, cx + inner_r, cy + inner_r, fill=core_hex, outline=""
            )

            self.root.after(40, animate)

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
            # If empty label is visible, hide it
            if self.empty_lbl.winfo_ismapped():
                self.empty_lbl.pack_forget()

            # Increment counter on success
            if "成功" in message or "完成" in message:
                self.processed_count += 1
                self.lbl_processed.config(text=f"{self.processed_count} 笔")

            # Create new timeline entry row
            row = tk.Frame(self.timeline_box, bg=BG_CARD)
            row.pack(fill=tk.X, pady=2, anchor=tk.W)

            time_lbl = tk.Label(
                row,
                text=now_str,
                font=(FONT_FAMILY, 8),
                fg=TEXT_MUTED,
                bg=BG_CARD,
            )
            time_lbl.pack(side=tk.LEFT, padx=(0, 6))

            badge_lbl = tk.Label(
                row,
                text=f"[{badge}]",
                font=(FONT_FAMILY, 8, "bold"),
                fg=ACCENT_CYAN,
                bg=BG_CARD,
            )
            badge_lbl.pack(side=tk.LEFT, padx=(0, 6))

            msg_lbl = tk.Label(
                row,
                text=message,
                font=(FONT_FAMILY, 9),
                fg=TEXT_TITLE,
                bg=BG_CARD,
                anchor=tk.W,
            )
            msg_lbl.pack(side=tk.LEFT, fill=tk.X)

            self.timeline_items.append(row)
            # Keep max 5 recent timeline entries visible
            if len(self.timeline_items) > 5:
                old = self.timeline_items.pop(0)
                old.destroy()

        self.root.after_idle(update)

    def _on_raw_log(self, badge: str, raw_line: str):
        def update():
            entry = f"[{time.strftime('%H:%M:%S')}] [{badge}] {raw_line}\n"
            self.tech_text.insert(tk.END, entry)
            self.tech_text.see(tk.END)
            # Limit lines
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
        app = ModernWorkerApp(root)
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
