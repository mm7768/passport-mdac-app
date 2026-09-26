"""Cleanly terminate existing MDAC & Passport automation workers."""
from __future__ import annotations

import os
import sys
import time

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

try:
    import psutil
except ImportError:
    print("未安装 psutil，正在尝试继续...")
    psutil = None

TARGET_SCRIPTS = [
    "services/mdac-fill-preview/worker.py",
    "services/registration-check-worker/worker.py",
    "services/visit-pass-check-worker/worker.py",
    "worker/azure_ocr_worker.py",
    "services/gmail-pin-worker/worker.py",
]


def stop_workers() -> int:
    if psutil is None:
        return 0

    current_pid = os.getpid()
    matched_procs: list[psutil.Process] = []

    for proc in psutil.process_iter(["pid", "name", "cmdline"]):
        try:
            if proc.info["pid"] == current_pid:
                continue
            name = (proc.info["name"] or "").lower()
            if "python" not in name:
                continue
            cmdline = " ".join(proc.info["cmdline"] or [])
            cmdline_norm = cmdline.replace("\\", "/")
            if any(target in cmdline_norm for target in TARGET_SCRIPTS):
                matched_procs.append(proc)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass

    if not matched_procs:
        print("未检测到运行中的旧版 Worker 进程。")
        return 0

    print(f"检测到 {len(matched_procs)} 个旧版 Worker 进程，正在安全终止...")
    for proc in matched_procs:
        try:
            proc.terminate()
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass

    # Wait up to 2.5 seconds for graceful shutdown
    gone, alive = psutil.wait_procs(matched_procs, timeout=2.5)
    for proc in alive:
        try:
            proc.kill()
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass

    print(f"已成功清理 {len(matched_procs)} 个旧版 Worker 进程！")
    return len(matched_procs)


if __name__ == "__main__":
    stop_workers()
