"""Windows Terminal Launcher for 3 MDAC Workers in ONE Window.

Supports:
1. Multi-Tab mode (3 tabs in a single window)
2. Split-Pane mode (3 split panes in a single window)
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys

PYTHON_EXE = sys.executable
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def build_command(mode: str) -> list[str]:
    w1_cmd = (
        f'chcp 65001 >nul & title MDAC 自动注册 & cd /d "{REPO_ROOT}" & '
        f'"{PYTHON_EXE}" services/mdac-fill-preview/worker.py --poll'
    )
    w2_cmd = (
        f'chcp 65001 >nul & title 查 Registration & cd /d "{REPO_ROOT}" & '
        f'"{PYTHON_EXE}" services/registration-check-worker/worker.py --poll'
    )
    w3_cmd = (
        f'chcp 65001 >nul & title 查 Visit Pass & cd /d "{REPO_ROOT}" & '
        f'"{PYTHON_EXE}" services/visit-pass-check-worker/worker.py --poll'
    )

    if mode == "split":
        # Split-pane layout: Left half for MDAC, Right-top for Reg Check, Right-bottom for Visit Pass
        return [
            "wt",
            "-w", "0",
            "--title", "1. MDAC 自动注册",
            "cmd", "/k", w1_cmd,
            ";",
            "split-pane", "-V",
            "--title", "2. 查 Registration",
            "cmd", "/k", w2_cmd,
            ";",
            "split-pane", "-H",
            "--title", "3. 查 Visit Pass",
            "cmd", "/k", w3_cmd,
        ]
    else:
        # Default: 3 tabs in a single window
        return [
            "wt",
            "-w", "0",
            "new-tab",
            "--title", "1. MDAC 自动注册",
            "cmd", "/k", w1_cmd,
            ";",
            "new-tab",
            "--title", "2. 查 Registration",
            "cmd", "/k", w2_cmd,
            ";",
            "new-tab",
            "--title", "3. 查 Visit Pass",
            "cmd", "/k", w3_cmd,
        ]


def main() -> None:
    parser = argparse.ArgumentParser(description="Launch workers in Windows Terminal")
    parser.add_argument(
        "--mode",
        choices=["tabs", "split"],
        default="tabs",
        help="Display layout: 'tabs' (multi-tab) or 'split' (split-pane)",
    )
    args = parser.parse_args()
    cmd = build_command(args.mode)
    try:
        subprocess.Popen(cmd)
        mode_text = "【同窗口 3 标签页 (Tabs)】" if args.mode == "tabs" else "【同窗口 3 分屏 (Split-Pane)】"
        print(f"成功唤起 Windows Terminal {mode_text}！")
        print("所有 3 个 Worker 已在同一个窗口中就绪并在后台监听。")
    except Exception as e:
        print(f"调起 Windows Terminal 失败: {e}")


if __name__ == "__main__":
    main()
