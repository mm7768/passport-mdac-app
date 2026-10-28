"""Minimalist Black GUI with White Breathing Light for MDAC Worker Suite.

Theme: Deep Obsidian Black (#000000)
Indicator: Pulsing White Breathing Light (Sine-wave animated)
Platform: Pure Python Tkinter (Zero extra pip dependencies required)
"""
from __future__ import annotations

import ctypes
import math
import os
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk

PYTHON_EXE = sys.executable
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

WORKERS = [
    {
        "id": "mdac",
        "name": "MDAC 自动注册",
        "tag": "MDAC",
        "script": "services/mdac-fill-preview/worker.py",
        "args": ["--poll"],
        "status": "准备启动...",
        "active": False,
    },
    {
        "id": "reg",
        "name": "Check Registration 核查",
        "tag": "CHECK-REG",
        "script": "services/registration-check-worker/worker.py",
        "args": ["--poll"],
        "status": "准备启动...",
        "active": False,
    },
    {
        "id": "vp",
        "name": "Check Visit Pass 核查",
        "tag": "CHECK-VP",
        "script": "services/visit-pass-check-worker/worker.py",
        "args": ["--poll"],
        "status": "准备启动...",
        "active": False,
    },
    {
        "id": "ocr",
        "name": "Azure 护照 OCR 解析",
        "tag": "OCR",
        "script": "worker/azure_ocr_worker.py",
        "args": ["--poll"],
        "status": "准备启动...",
        "active": False,
    },
    {
        "id": "pin",
        "name": "Gmail PIN 邮件抓取",
        "tag": "PIN",
        "script": "services/gmail-pin-worker/worker.py",
        "args": ["--poll"],
        "status": "准备启动...",
        "active": False,
    },
]

BG_COLOR = "#000000"
CARD_BG = "#0c0c0e"
CARD_BORDER = "#1c1c1f"
TEXT_PRIMARY = "#f4f4f5"
TEXT_SECONDARY = "#71717a"
TEXT_MUTED = "#3f3f46"
ACCENT_WHITE = "#ffffff"


class WorkerManager:
    def __init__(self, on_log=None, on_status_change=None):
        self.stop_event = threading.Event()
        self.on_log = on_log
        self.on_status_change = on_status_change
        self.threads = []
        self.procs = {}

    def start(self):
        self.stop_event.clear()
        for w in WORKERS:
            t = threading.Thread(target=self._run_loop, args=(w,), daemon=True)
            t.start()
            self.threads.append(t)
            time.sleep(0.15)

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
        time.sleep(0.5)
        self.start()

    def _run_loop(self, w_info: dict):
        tag = w_info["tag"]
        script_path = os.path.join(REPO_ROOT, w_info["script"])
        env = os.environ.copy()
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"

        while not self.stop_event.is_set():
            if self.on_status_change:
                self.on_status_change(w_info["id"], "正在连接队列...", True)
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
                )
                self.procs[w_info["id"]] = proc
                if self.on_status_change:
                    self.on_status_change(w_info["id"], "监听待命中 · 空闲", True)

                for raw_line in iter(proc.stdout.readline, ""):
                    if self.stop_event.is_set() or not raw_line:
                        break
                    line = raw_line.strip()
                    if line:
                        if self.on_log:
                            self.on_log(tag, line)
                        # Check activity status from line
                        low = line.lower()
                        if "claimed" in low or "processing" in low or "handling" in low or "start" in low:
                            if self.on_status_change:
                                self.on_status_change(w_info["id"], "正在执行任务...", True)
                        elif "succeeded" in low or "completed" in low or "done" in low:
                            if self.on_status_change:
                                self.on_status_change(w_info["id"], "任务处理完成 · 监听中", True)
                        elif "idle" in low or "waiting" in low or "heartbeat" in low:
                            if self.on_status_change:
                                self.on_status_change(w_info["id"], "监听待命中 · 空闲", True)
                proc.wait()
            except Exception as e:
                if self.on_log:
                    self.on_log(tag, f"运行异常: {e}")

            if self.stop_event.is_set():
                break

            if self.on_status_change:
                self.on_status_change(w_info["id"], "意外中断，3 秒后自动拉起...", False)
            time.sleep(3)


class MinimalistWorkerApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("Passport MDAC Desk · Worker Suite")
        self.root.geometry("560x780")
        self.root.minsize(500, 600)
        self.root.configure(bg=BG_COLOR)

        self._enable_dark_titlebar()

        self.manager = WorkerManager(
            on_log=self._on_log_received,
            on_status_change=self._on_status_changed,
        )

        self.log_visible = False
        self.worker_widgets = {}
        self._build_ui()
        self._start_breathing_animation()

        # Start workers
        self.manager.start()

        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    def _enable_dark_titlebar(self):
        try:
            hwnd = ctypes.windll.user32.GetParent(self.root.winfo_id())
            # DWMWA_USE_IMMERSIVE_DARK_MODE = 20
            value = ctypes.c_int(2)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(hwnd, 20, ctypes.byref(value), 4)
        except Exception:
            pass

    def _build_ui(self):
        # Top Header Area
        header_frame = tk.Frame(self.root, bg=BG_COLOR)
        header_frame.pack(fill=tk.X, padx=28, pady=(24, 10))

        # Title
        title_label = tk.Label(
            header_frame,
            text="PASSPORT MDAC DESK",
            font=("Segoe UI", 10, "bold"),
            fg=TEXT_SECONDARY,
            bg=BG_COLOR,
        )
        title_label.pack(anchor=tk.W)

        subtitle_label = tk.Label(
            header_frame,
            text="Local Automation Suite",
            font=("Segoe UI", 16, "bold"),
            fg=TEXT_PRIMARY,
            bg=BG_COLOR,
        )
        subtitle_label.pack(anchor=tk.W, pady=(2, 0))

        # Breathing Light Display Card
        pulse_card = tk.Frame(self.root, bg=CARD_BG, highlightbackground=CARD_BORDER, highlightthickness=1)
        pulse_card.pack(fill=tk.X, padx=28, pady=(12, 16))

        inner_pulse = tk.Frame(pulse_card, bg=CARD_BG)
        inner_pulse.pack(padx=20, pady=16)

        self.light_canvas = tk.Canvas(inner_pulse, width=44, height=44, bg=CARD_BG, highlightthickness=0)
        self.light_canvas.pack(side=tk.LEFT, padx=(0, 16))

        text_block = tk.Frame(inner_pulse, bg=CARD_BG)
        text_block.pack(side=tk.LEFT, fill=tk.Y)

        self.suite_status_label = tk.Label(
            text_block,
            text="ALL WORKERS ONLINE",
            font=("Segoe UI", 11, "bold"),
            fg=TEXT_PRIMARY,
            bg=CARD_BG,
        )
        self.suite_status_label.pack(anchor=tk.W)

        self.suite_sub_label = tk.Label(
            text_block,
            text="5 组本地网页与任务 Worker 正在监听 Supabase 队列",
            font=("Segoe UI", 9),
            fg=TEXT_SECONDARY,
            bg=CARD_BG,
        )
        self.suite_sub_label.pack(anchor=tk.W, pady=(2, 0))

        # Workers Section Title
        sec_label = tk.Label(
            self.root,
            text="MONITORED WORKERS",
            font=("Segoe UI", 8, "bold"),
            fg=TEXT_MUTED,
            bg=BG_COLOR,
        )
        sec_label.pack(anchor=tk.W, padx=32, pady=(8, 4))

        # Worker Cards Container
        workers_container = tk.Frame(self.root, bg=BG_COLOR)
        workers_container.pack(fill=tk.BOTH, expand=False, padx=28, pady=4)

        for w in WORKERS:
            w_frame = tk.Frame(workers_container, bg=CARD_BG, highlightbackground=CARD_BORDER, highlightthickness=1)
            w_frame.pack(fill=tk.X, pady=4)

            # Left badge & name
            left_col = tk.Frame(w_frame, bg=CARD_BG)
            left_col.pack(side=tk.LEFT, padx=14, pady=10)

            dot_canvas = tk.Canvas(left_col, width=10, height=10, bg=CARD_BG, highlightthickness=0)
            dot_canvas.pack(side=tk.LEFT, padx=(0, 10))
            dot = dot_canvas.create_oval(1, 1, 9, 9, fill="#52525b", outline="")

            tag_label = tk.Label(
                left_col,
                text=w["tag"],
                font=("Segoe UI", 8, "bold"),
                fg=TEXT_SECONDARY,
                bg="#18181b",
                padx=5,
                pady=1,
            )
            tag_label.pack(side=tk.LEFT, padx=(0, 10))

            name_label = tk.Label(
                left_col,
                text=w["name"],
                font=("Segoe UI", 10),
                fg=TEXT_PRIMARY,
                bg=CARD_BG,
            )
            name_label.pack(side=tk.LEFT)

            # Right status
            status_label = tk.Label(
                w_frame,
                text="准备启动...",
                font=("Segoe UI", 9),
                fg=TEXT_SECONDARY,
                bg=CARD_BG,
            )
            status_label.pack(side=tk.RIGHT, padx=14, pady=10)

            self.worker_widgets[w["id"]] = {
                "dot_canvas": dot_canvas,
                "dot": dot,
                "status_label": status_label,
            }

        # Latest Activity Feed
        feed_frame = tk.Frame(self.root, bg=BG_COLOR)
        feed_frame.pack(fill=tk.X, padx=28, pady=(12, 6))

        feed_title = tk.Label(feed_frame, text="最新动态", font=("Segoe UI", 8, "bold"), fg=TEXT_MUTED, bg=BG_COLOR)
        feed_title.pack(anchor=tk.W)

        self.last_log_label = tk.Label(
            feed_frame,
            text="等待队列新任务...",
            font=("Consolas", 8),
            fg="#a1a1aa",
            bg=CARD_BG,
            anchor=tk.W,
            padx=10,
            pady=8,
            highlightbackground=CARD_BORDER,
            highlightthickness=1,
        )
        self.last_log_label.pack(fill=tk.X, pady=(4, 0))

        # Bottom Button Bar
        btn_bar = tk.Frame(self.root, bg=BG_COLOR)
        btn_bar.pack(fill=tk.X, padx=28, pady=(12, 10))

        self.toggle_log_btn = tk.Button(
            btn_bar,
            text="展开详细日志 ▾",
            font=("Segoe UI", 8),
            fg=TEXT_SECONDARY,
            bg=CARD_BG,
            activeforeground=TEXT_PRIMARY,
            activebackground="#18181b",
            relief=tk.FLAT,
            bd=0,
            padx=12,
            pady=6,
            command=self._toggle_log,
        )
        self.toggle_log_btn.pack(side=tk.LEFT)

        restart_btn = tk.Button(
            btn_bar,
            text="一键重启所有 Worker",
            font=("Segoe UI", 8, "bold"),
            fg=TEXT_PRIMARY,
            bg="#18181b",
            activeforeground="#ffffff",
            activebackground="#27272a",
            relief=tk.FLAT,
            bd=0,
            padx=14,
            pady=6,
            command=self.manager.restart,
        )
        restart_btn.pack(side=tk.RIGHT)

        # Expandable Log Box
        self.log_frame = tk.Frame(self.root, bg=CARD_BG, highlightbackground=CARD_BORDER, highlightthickness=1)
        self.log_text = tk.Text(
            self.log_frame,
            bg=CARD_BG,
            fg="#a1a1aa",
            insertbackground=TEXT_PRIMARY,
            font=("Consolas", 8),
            relief=tk.FLAT,
            bd=0,
            padx=10,
            pady=8,
            height=8,
        )
        self.log_text.pack(fill=tk.BOTH, expand=True)

    def _toggle_log(self):
        if self.log_visible:
            self.log_frame.pack_forget()
            self.toggle_log_btn.config(text="展开详细日志 ▾")
            self.log_visible = False
        else:
            self.log_frame.pack(fill=tk.BOTH, expand=True, padx=28, pady=(0, 16))
            self.toggle_log_btn.config(text="收起详细日志 ▴")
            self.log_visible = True

    def _start_breathing_animation(self):
        def animate():
            t = time.time()
            # Smooth sine wave cycle (~2.4s period)
            val = 0.5 * (1 + math.sin(t * 2.6))  # 0.0 ~ 1.0

            # Core brightness: from 90 to 255 (white)
            core_v = int(90 + val * 165)
            core_hex = f"#{core_v:02x}{core_v:02x}{core_v:02x}"

            # Outer halo brightness: from 20 to 85
            halo_v = int(20 + val * 65)
            halo_hex = f"#{halo_v:02x}{halo_v:02x}{halo_v:02x}"

            # Dynamic radius
            outer_r = 15 + val * 5.0
            inner_r = 8 + val * 2.0

            cx, cy = 22, 22
            self.light_canvas.delete("all")
            # Outer soft glow halo
            self.light_canvas.create_oval(
                cx - outer_r, cy - outer_r, cx + outer_r, cy + outer_r, fill=halo_hex, outline=""
            )
            # Inner bright core
            self.light_canvas.create_oval(
                cx - inner_r, cy - inner_r, cx + inner_r, cy + inner_r, fill=core_hex, outline=""
            )

            self.root.after(35, animate)

        animate()

    def _on_log_received(self, tag: str, message: str):
        display_line = f"[{time.strftime('%H:%M:%S')}] [{tag}] {message}"

        def update():
            # Update last activity
            short_line = message
            if len(short_line) > 60:
                short_line = short_line[:57] + "..."
            self.last_log_label.config(text=f"[{tag}] {short_line}")

            # Append to full log text
            self.log_text.insert(tk.END, display_line + "\n")
            self.log_text.see(tk.END)
            # Keep max 500 lines in buffer
            if float(self.log_text.index("end-1c")) > 500:
                self.log_text.delete("1.0", "100.0")

        self.root.after_idle(update)

    def _on_status_changed(self, w_id: str, status_text: str, is_active: bool):
        def update():
            w = self.worker_widgets.get(w_id)
            if w:
                w["status_label"].config(text=status_text)
                if is_active:
                    w["dot_canvas"].itemconfig(w["dot"], fill="#ffffff")
                    w["status_label"].config(fg="#e4e4e7")
                else:
                    w["dot_canvas"].itemconfig(w["dot"], fill="#71717a")
                    w["status_label"].config(fg=TEXT_SECONDARY)

        self.root.after_idle(update)

    def _on_close(self):
        self.manager.stop()
        self.root.destroy()


def main():
    root = tk.Tk()
    app = MinimalistWorkerApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
