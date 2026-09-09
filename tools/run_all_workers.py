"""Unified Worker Supervisor for Local MDAC Desk.

Runs and monitors all 4 local workers concurrently:
1. MDAC Registration Worker (mdac-fill-preview)
2. Gmail PIN Worker (gmail-pin-worker)
3. Check Registration Worker (registration-check-worker)
4. Check Visit Pass Worker (visit-pass-check-worker)
"""
from __future__ import annotations

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
        "name": "MDAC 自动注册",
        "tag": "MDAC",
        "script": "services/mdac-fill-preview/worker.py",
        "args": ["--poll"],
    },
    {
        "name": "查 Registration",
        "tag": "CHECK-REG",
        "script": "services/registration-check-worker/worker.py",
        "args": ["--poll"],
    },
    {
        "name": "查 Visit Pass",
        "tag": "CHECK-VP",
        "script": "services/visit-pass-check-worker/worker.py",
        "args": ["--poll"],
    },
]

# ANSI color codes
COLORS = {
    "MDAC": "\033[96m",       # Cyan
    "GMAIL-PIN": "\033[93m",   # Yellow
    "CHECK-REG": "\033[92m",   # Green
    "CHECK-VP": "\033[95m",    # Magenta
    "RESET": "\033[0m",
    "BOLD": "\033[1m",
}


def stream_output(proc: subprocess.Popen, tag: str) -> None:
    color = COLORS.get(tag, "")
    reset = COLORS["RESET"]
    try:
        for line in iter(proc.stdout.readline, ""):
            if not line:
                break
            stripped = line.strip()
            if stripped:
                print(f"{color}[{tag}]{reset} {stripped}")
    except Exception:
        pass


def run_worker_loop(w_info: dict, stop_event: threading.Event) -> None:
    tag = w_info["tag"]
    script_path = os.path.join(REPO_ROOT, w_info["script"])
    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"

    while not stop_event.is_set():
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
            w_info["proc"] = proc
            t = threading.Thread(target=stream_output, args=(proc, tag), daemon=True)
            t.start()
            proc.wait()
        except Exception as err:
            print(f"[{tag}] 进程启动失败: {err}")

        if stop_event.is_set():
            break
        print(f"[{tag}] 进程已退出，将在 5 秒后自动重启...")
        time.sleep(5)


def main() -> None:
    os.system("title Passport MDAC 本地 3 合 1 Worker 控制台")
    print("=" * 65)
    print("      Passport MDAC 本地 3 合 1 Worker 服务中心已启动")
    print("=" * 65)
    print("已托管的自动化后台任务：")
    for w in WORKERS:
        print(f"  • [{w['tag']}] {w['name']} -> {w['script']}")
    print("-" * 65)
    print("提示：所有 Worker 正在同时监听各自的 Supabase 队列。")
    print("按 Ctrl + C 可安全停止所有本地 Worker。")
    print("=" * 65)
    print()

    stop_event = threading.Event()
    threads = []
    for w in WORKERS:
        t = threading.Thread(target=run_worker_loop, args=(w, stop_event), daemon=True)
        t.start()
        threads.append(t)
        time.sleep(0.5)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n收到退出指令，正在停止所有本地 Worker...")
        stop_event.set()
        for w in WORKERS:
            p = w.get("proc")
            if p and p.poll() is None:
                p.terminate()
        print("所有本地 Worker 已安全退出。")


if __name__ == "__main__":
    main()
