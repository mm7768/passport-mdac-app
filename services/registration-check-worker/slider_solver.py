"""Async MDAC canvas slider solver.

Provides an asynchronous Playwright slider solver for the MDAC form using
hybrid ddddocr + OpenCV Canny edge template matching with adaptive human-like drag.
"""
from __future__ import annotations

import asyncio
import base64
import io
import logging
import random
from typing import Any, Callable

import cv2
import ddddocr
import numpy as np
from PIL import Image
from playwright.async_api import Page

LOG = logging.getLogger("mdac_slider_solver")

_DETECTOR: ddddocr.DdddOcr | None = None


def get_detector() -> ddddocr.DdddOcr:
    """Lazy-load and cache the ddddocr detector instance."""
    global _DETECTOR
    if _DETECTOR is None:
        _DETECTOR = ddddocr.DdddOcr(det=False, ocr=False, show_ad=False)
    return _DETECTOR


def generate_track(total_distance: float) -> list[float]:
    """Generate an ease-out displacement track simulating human drag."""
    track: list[float] = []
    current = 0.0
    steps = random.randint(28, 36)
    for index in range(1, steps + 1):
        progress = index / steps
        ease_progress = (
            1.0 if progress == 1.0 else 1.0 - (2.0 ** (-10.0 * progress))
        )
        move = total_distance * ease_progress
        step_move = move - current
        current = move
        track.append(step_move)
    return track


def compute_target_distances(
    bg_bytes: bytes, block_bytes: bytes
) -> tuple[float, float, float]:
    """Compute primary target distance and alternative via OpenCV edge template matching."""
    block_img = Image.open(io.BytesIO(block_bytes))
    bbox = block_img.getbbox()
    img_start_x = float(bbox[0]) if bbox else 0.0

    # 1. ddddocr
    detector = get_detector()
    dddd_res = detector.slide_match(block_bytes, bg_bytes, simple_target=True)
    dddd_dist = float(dddd_res["target"][0]) - img_start_x

    # 2. OpenCV Canny edge template matching with CLAHE enhancement
    cv_dist = dddd_dist
    cv_conf = 0.0
    try:
        bg_np = cv2.imdecode(np.frombuffer(bg_bytes, np.uint8), cv2.IMREAD_COLOR)
        block_np = cv2.imdecode(
            np.frombuffer(block_bytes, np.uint8), cv2.IMREAD_UNCHANGED
        )
        if bbox:
            cropped_block = block_np[bbox[1] : bbox[3], bbox[0] : bbox[2]]
        else:
            cropped_block = block_np

        bg_gray = cv2.cvtColor(bg_np, cv2.COLOR_BGR2GRAY)
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        bg_enhanced = clahe.apply(bg_gray)

        if cropped_block.shape[2] == 4:
            block_gray = cv2.cvtColor(
                cropped_block[:, :, :3], cv2.COLOR_BGR2GRAY
            )
        else:
            block_gray = cv2.cvtColor(cropped_block, cv2.COLOR_BGR2GRAY)
        block_enhanced = clahe.apply(block_gray)

        bg_canny = cv2.Canny(bg_enhanced, 50, 150)
        block_canny = cv2.Canny(block_enhanced, 50, 150)

        match_res = cv2.matchTemplate(
            bg_canny, block_canny, cv2.TM_CCOEFF_NORMED
        )
        _, max_val, _, max_loc = cv2.minMaxLoc(match_res)
        cv_dist = float(max_loc[0]) - img_start_x
        cv_conf = float(max_val)
    except Exception as e:
        LOG.debug("OpenCV edge matching fallback error: %s", e)

    return dddd_dist, cv_dist, cv_conf


async def solve_mdac_slider(
    page: Page,
    log_func: Callable[[str], Any] = LOG.info,
    max_retries: int = 5,
) -> bool:
    """Solve the MDAC canvas slider on an existing async Playwright page.

    Args:
        page: Playwright async Page instance opened to the MDAC form.
        log_func: Callable for logging progress/diagnostic messages.
        max_retries: Maximum attempts to solve the slider (default 5).

    Returns:
        True if the slider succeeds, False otherwise.
    """
    biases = [-14, -10, -16, -12, -18]

    for attempt in range(max_retries):
        log_func(f"正在尝试第 {attempt + 1} 次滑块验证...")
        try:
            captcha_el = page.locator("#captcha")
            await captcha_el.wait_for(state="visible", timeout=10000)
            await captcha_el.scroll_into_view_if_needed()
            await page.wait_for_timeout(600)

            bg_base64 = await page.evaluate(
                "document.querySelectorAll('canvas')[0].toDataURL('image/png')"
            )
            block_base64 = await page.evaluate(
                "document.querySelectorAll('canvas')[1].toDataURL('image/png')"
            )

            bg_bytes = base64.b64decode(bg_base64.split(",")[1])
            block_bytes = base64.b64decode(block_base64.split(",")[1])

            dddd_dist, cv_dist, cv_conf = compute_target_distances(
                bg_bytes, block_bytes
            )

            scale_info = await page.evaluate(
                """
                () => {
                    const canvas = document.querySelectorAll('canvas')[0];
                    return {
                        internal: canvas ? canvas.width : 0,
                        display: canvas ? canvas.getBoundingClientRect().width : 0
                    };
                }
                """
            )
            scale = (
                scale_info["display"] / scale_info["internal"]
                if scale_info.get("internal")
                else 1.0
            )

            if attempt == 2 and cv_conf > 0.35 and abs(cv_dist - dddd_dist) > 10:
                chosen_dist = cv_dist
                log_func(
                    f"第 {attempt + 1} 次尝试采用 OpenCV 边缘轮廓位置 (置信度 {cv_conf:.2f})"
                )
            else:
                chosen_dist = dddd_dist

            final_distance = chosen_dist * scale

            slider_handle = page.locator(".slider").first
            box = await slider_handle.bounding_box()
            if not box:
                raise RuntimeError("未找到滑块手柄位置")

            handle_start_x = box["x"] + box["width"] / 2
            handle_start_y = box["y"] + box["height"] / 2

            await slider_handle.hover()
            await page.mouse.down()
            await page.wait_for_timeout(random.randint(120, 220))

            offset_bias = biases[attempt % len(biases)]
            actual_move = final_distance + offset_bias
            current_x = handle_start_x
            for step_x in generate_track(actual_move):
                current_x += step_x
                await page.mouse.move(
                    current_x,
                    handle_start_y + random.uniform(-1.0, 1.0),
                )
                await asyncio.sleep(random.uniform(0.018, 0.03))

            await page.wait_for_timeout(random.randint(250, 450))
            await page.mouse.up()
            await page.wait_for_timeout(1200)

            success = await page.evaluate(
                """
                () => document.querySelector('.sliderContainer') !== null
                    && document.querySelector('.sliderContainer')
                        .classList.contains('sliderContainer_success')
                """
            )
            if success:
                log_func("滑块验证成功！")
                return True

            if attempt < max_retries - 1:
                log_func(f"第 {attempt + 1} 次自动滑块未对准，准备微调重试...")
                await page.wait_for_timeout(1500)
            else:
                log_func(
                    f"前 {max_retries} 次自动滑块未对准。"
                    f"【提示】您可直接在屏幕上用鼠标手动拖动滑块完成拼图（等待 8 秒）..."
                )
                for _ in range(16):
                    await page.wait_for_timeout(500)
                    manual_success = await page.evaluate(
                        """
                        () => document.querySelector('.sliderContainer') !== null
                            && document.querySelector('.sliderContainer')
                                .classList.contains('sliderContainer_success')
                        """
                    )
                    if manual_success:
                        log_func("滑块验证成功（手工辅助完成）！")
                        return True

        except Exception as error:
            log_func(f"自动滑块处理发生错误: {error}")
            try:
                await page.mouse.up()
            except Exception:
                pass
            await page.wait_for_timeout(1500)

    log_func(f"连续 {max_retries} 次滑块验证失败！")
    return False


__all__ = [
    "generate_track",
    "get_detector",
    "compute_target_distances",
    "solve_mdac_slider",
]
