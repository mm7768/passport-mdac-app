"""Unified Minimalist Worker Supervisor for Local MDAC Desk.

Features:
- Default: Launches sleek Minimalist Black GUI with White Breathing Light
- CLI Mode (--cli / --terminal): Minimalist Black Terminal Dashboard with White Breathing Pulse
"""
from __future__ import annotations

import argparse
import math
import os
import subprocess
import sys
import threading
import time

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

PYTHON_EXE = sys.executable
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

WORKERS = [
    {
        "id": "mdac",
        "name": "MDAC 自动注册",
        "tag": "MDAC",
        "script": "services/mdac-fill-preview/worker.py",
        "args": ["--poll"],
        "status": "待命中",
    },
    {
        "id": "reg",
        "name": "Check Registration",
        "tag": "CHECK-REG",
        "script": "services/registration-check-worker/worker.py",
        "args": ["--poll"],
        "status": "待命中",
    },
    {
        "id": "vp",
        "name": "Check Visit Pass",
        "tag": "CHECK-VP",
        "script": "services/visit-pass-check-worker/worker.py",
        "args": ["--poll"],
        "status": "待命中",
    },
    {
        "id": "ocr",
        "name": "Azure 护照 OCR",
        "tag": "OCR",
        "script": "worker/azure_ocr_worker.py",
        "args": ["--poll"],
        "status": "待命中",
    },
    {
        "id": "pin",
        "name": "Gmail PIN 抓取",
        "tag": "PIN",
        "script": "services/gmail-pin-worker/worker.py",
        "args": ["--poll"],
        "status": "待命中",
    },
]

# Minimalist Terminal Breathing Indicator frames
PULSE_FRAMES = ["·", "○", "◐", "●", "⚪", "●", "◐", "○"]

latest_logs = ["系统初始化完成，所有 Worker 准备监听队列..."]
log_lock = threading.Lock()


def stream_worker(proc: subprocess.Popen, w_info: dict, verbose: bool) -> None:
    tag = w_info["tag"]
    try:
        for raw_line in iter(proc.stdout.readline, ""):
            if not raw_line:
                break
            line = raw_line.strip()
            if not line:
                continue

            low = line.lower()
            if "claimed" in low or "processing" in low or "handling" in low or "start" in low:
                w_info["status"] = "正在执行任务..."
            elif "succeeded" in low or "completed" in low or "done" in low:
                w_info["status"] = "任务完成 · 待命中"
            elif "idle" in low or "waiting" in low or "heartbeat" in low:
                w_info["status"] = "监听队列 · 空闲"

            with log_lock:
                latest_logs.append(f"[{time.strftime('%H:%M:%S')}] [{tag}] {line}")
                if len(latest_logs) > 300:
                    latest_logs.pop(0)

            if verbose:
                print(f"[{tag}] {line}")
    except Exception:
        pass


def run_worker_loop(w_info: dict, stop_event: threading.Event, verbose: bool) -> None:
    tag = w_info["tag"]
    script_path = os.path.join(REPO_ROOT, w_info["script"])
    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"

    while not stop_event.is_set():
        try:
            w_info["status"] = "启动中..."
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
            w_info["proc"] = proc
            w_info["status"] = "监听中"

            t = threading.Thread(target=stream_worker, args=(proc, w_info, verbose), daemon=True)
            t.start()
            proc.wait()
        except Exception as err:
            w_info["status"] = f"异常: {err}"

        if stop_event.is_set():
            break
        w_info["status"] = "已退出，3 秒后自动拉起..."
        time.sleep(3)


def run_terminal_dashboard(stop_event: threading.Event) -> None:
    """Minimalist Black Terminal Dashboard with White Breathing Light Pulse."""
    os.system("cls" if os.name == "nt" else "clear")
    # Hide cursor on VT100
    sys.stdout.write("\033[?25l")
    frame_idx = 0

    try:
        while not stop_event.is_set():
            pulse_icon = PULSE_FRAMES[frame_idx % len(PULSE_FRAMES)]
            frame_idx += 1

            # Move cursor to home (0,0) without full cls flicker
            sys.stdout.write("\033[H")
            lines = [
                "",
                f"   \033[1;37m[{pulse_icon}]\033[0m  \033[1;37mPASSPORT MDAC DESK\033[0m · \033[90mLOCAL WORKER SUITE\033[0m",
                "   " + "─" * 58,
                "   \033[90mALL 5 WORKERS ONLINE · MINIMALIST BLACK MODE\033[0m",
                "",
            ]

            for w in WORKERS:
                status_color = "\033[1;37m" if "执行" in w["status"] else "\033[90m"
                tag_str = f"[{w['tag']}]".ljust(12)
                name_str = w["name"].ljust(22)
                lines.append(f"   \033[37m●\033[0m  {tag_str} {name_str} {status_color}{w['status']}\033[0m\033[K")

            lines.append("")
            lines.append("   " + "─" * 58)
            with log_lock:
                last_line = latest_logs[-1] if latest_logs else "等待队列任务..."
            if len(last_line) > 70:
                last_line = last_line[:67] + "..."
            lines.append(f"   \033[90m最新:\033[0m \033[37m{last_line}\033[0m\033[K")
            lines.append("   " + "─" * 58)
            lines.append("   \033[90m按 Ctrl + C 安全退出所有 Worker\033[0m\033[K")
            lines.append("")

            sys.stdout.write("\n".join(lines) + "\n")
            sys.stdout.flush()
            time.sleep(0.3)
    finally:
        # Show cursor back
        sys.stdout.write("\033[?25h\n")
        sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(description="Passport MDAC Worker Suite")
    parser.add_argument("--cli", action="store_true", help="Run in minimalist terminal dashboard mode")
    parser.add_argument("--verbose", action="store_true", help="Print raw logs directly to terminal")
    parser.add_argument("--gui", action="store_true", help="Force launch GUI window")
    args = parser.parse_args()

    # Default to GUI if not explicitly --cli or not running in a pure headless environment
    is_headless = os.environ.get("HEADLESS_TERMINAL") == "1" or not os.environ.get("DISPLAY", None) and os.name != "nt"
    launch_gui = (args.gui or not args.cli and not args.verbose) and not is_headless

    if launch_gui:
        try:
            import tools.worker_gui as worker_gui
            worker_gui.main()
            return
        except Exception as e:
            print(f"无法启动 GUI 窗口 ({e})，自动切换至极简终端看板模式...")

    # Run in minimalist terminal dashboard mode
    os.system("title Passport MDAC · Minimalist Worker Suite")
    stop_event = threading.Event()
    threads = []
    for w in WORKERS:
        t = threading.Thread(target=run_worker_loop, args=(w, stop_event, args.verbose), daemon=True)
        t.start()
        threads.append(t)
        time.sleep(0.1)

    try:
        if args.verbose:
            while True:
                time.sleep(1)
        else:
            run_terminal_dashboard(stop_event)
    except KeyboardInterrupt:
        print("\n\033[90m正在停止所有本地 Worker...\033[0m")
        stop_event.set()
        for w in WORKERS:
            p = w.get("proc")
            if p and p.poll() is None:
                try:
                    p.terminate()
                except Exception:
                    pass
        print("\033[37m● 所有 Worker 已安全停止。\033[0m")


if __name__ == "__main__":
    main()
