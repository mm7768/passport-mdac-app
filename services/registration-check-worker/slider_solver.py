"""Async MDAC canvas slider solver for Check Registration.

Provides an asynchronous Playwright slider solver for the MDAC form using
ddddocr slide matching and human-like track dragging.
"""
from __future__ import annotations

import asyncio
import base64
import io
import logging
import random
from typing import Any, Callable

import ddddocr
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
    steps = random.randint(30, 40)
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


async def solve_mdac_slider(
    page: Page,
    log_func: Callable[[str], Any] = LOG.info,
    max_retries: int = 3,
) -> bool:
    """Solve the MDAC canvas slider on an existing async Playwright page.

    Args:
        page: Playwright async Page instance opened to the MDAC form.
        log_func: Callable for logging progress/diagnostic messages.
        max_retries: Maximum attempts to solve the slider.

    Returns:
        True if the slider succeeds, False otherwise.
    """
    for attempt in range(max_retries):
        log_func(f"正在尝试第 {attempt + 1} 次滑块验证...")
        try:
            await page.wait_for_selector("canvas", timeout=10000)
            await page.wait_for_timeout(1500)

            bg_base64 = await page.evaluate(
                "document.querySelectorAll('canvas')[0].toDataURL('image/png')"
            )
            block_base64 = await page.evaluate(
                "document.querySelectorAll('canvas')[1].toDataURL('image/png')"
            )

            bg_bytes = base64.b64decode(bg_base64.split(",")[1])
            block_bytes = base64.b64decode(block_base64.split(",")[1])

            block_img = Image.open(io.BytesIO(block_bytes))
            bbox = block_img.getbbox()
            img_start_x = bbox[0] if bbox else 0

            detector = get_detector()
            result = detector.slide_match(
                block_bytes, bg_bytes, simple_target=True
            )
            distance = result["target"][0] - img_start_x

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
            final_distance = distance * scale

            slider_handle = page.locator(".slider").first
            box = await slider_handle.bounding_box()
            if not box:
                raise RuntimeError("未找到滑块手柄位置")

            handle_start_x = box["x"] + box["width"] / 2
            handle_start_y = box["y"] + box["height"] / 2

            await slider_handle.hover()
            await page.mouse.down()
            await page.wait_for_timeout(random.randint(100, 200))

            actual_move = final_distance - 14
            current_x = handle_start_x
            for step_x in generate_track(actual_move):
                current_x += step_x
                await page.mouse.move(
                    current_x,
                    handle_start_y + random.uniform(-1.5, 1.5),
                )
                await asyncio.sleep(random.uniform(0.01, 0.02))

            await page.wait_for_timeout(random.randint(300, 500))
            await page.mouse.up()
            await page.wait_for_timeout(2000)

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

            log_func(f"第 {attempt + 1} 次验证失败，等待滑块重置...")
            await page.wait_for_timeout(2500)

        except Exception as error:
            log_func(f"自动滑块处理发生错误: {error}")
            try:
                await page.mouse.up()
            except Exception:
                pass
            await page.wait_for_timeout(2000)

    log_func(f"连续 {max_retries} 次滑块验证失败！")
    return False


__all__ = ["generate_track", "get_detector", "solve_mdac_slider"]
