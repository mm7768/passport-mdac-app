"""Check Registration Worker.

This module is intentionally a fill-and-review worker, not a submission bot.
It reads the passport number and nationality from the client-safe task snapshot,
gets the PIN only through a service-role-only RPC, fills the official public query
page, verifies the filled DOM values, detects official CAPTCHA/slider challenges,
saves a private review screenshot, and writes NEEDS_REVIEW/RESULT_UNKNOWN.

It never solves a CAPTCHA, simulates a drag, invokes a form action, or confirms a
registration result. No passport number or PIN is written to logs.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import socket
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from urllib.parse import quote

import requests
from playwright.async_api import Browser, Page, TimeoutError as PlaywrightTimeoutError, async_playwright

LOG = logging.getLogger("registration_check_worker")
DEFAULT_CHECK_URL = "https://imigresen-online.imi.gov.my/mdac/register?viewRegistration"
DEFAULT_BUCKET = "passport-documents"


class WorkerError(RuntimeError):
    """Expected worker or remote-service failure."""


@dataclass(frozen=True)
class WorkerConfig:
    supabase_url: str
    service_role_key: str
    worker_id: str
    check_url: str
    poll_seconds: float
    lease_seconds: int
    max_attempts: int
    request_timeout_seconds: float
    page_timeout_ms: int
    screenshot_bucket: str
    screenshot_prefix: str
    log_level: str

    @classmethod
    def from_env(cls) -> "WorkerConfig":
        def required(name: str) -> str:
            value = os.getenv(name, "").strip()
            if not value:
                raise WorkerError(f"缺少环境变量：{name}")
            return value

        def positive_float(name: str, default: str, minimum: float) -> float:
            try:
                value = float(os.getenv(name, default))
            except ValueError as exc:
                raise WorkerError(f"{name} 必须是数字") from exc
            if value < minimum:
                raise WorkerError(f"{name} 必须大于或等于 {minimum}")
            return value

        def bounded_int(name: str, default: str, lower: int, upper: int) -> int:
            try:
                value = int(os.getenv(name, default))
            except ValueError as exc:
                raise WorkerError(f"{name} 必须是整数") from exc
            if value < lower or value > upper:
                raise WorkerError(f"{name} 必须在 {lower} 到 {upper} 之间")
            return value

        mode = os.getenv("REGISTRATION_CHECK_MODE", "FILL_REVIEW").strip().upper()
        if mode != "FILL_REVIEW":
            raise WorkerError("REGISTRATION_CHECK_MODE 必须严格为 FILL_REVIEW")
        allow_submit = os.getenv("ALLOW_REAL_SUBMIT", "false").strip().lower()
        if allow_submit != "false":
            raise WorkerError("ALLOW_REAL_SUBMIT 必须严格为 false")
        headless = os.getenv("REGISTRATION_CHECK_HEADLESS", "true").strip().lower()
        if headless != "true":
            raise WorkerError("REGISTRATION_CHECK_HEADLESS 必须严格为 true")

        return cls(
            supabase_url=required("SUPABASE_URL").rstrip("/"),
            service_role_key=required("SUPABASE_SERVICE_ROLE_KEY"),
            worker_id=required("REGISTRATION_CHECK_WORKER_ID"),
            check_url=os.getenv("REGISTRATION_CHECK_URL", DEFAULT_CHECK_URL).strip()
            or DEFAULT_CHECK_URL,
            poll_seconds=positive_float("REGISTRATION_CHECK_POLL_SECONDS", "30", 10.0),
            lease_seconds=bounded_int("REGISTRATION_CHECK_LEASE_SECONDS", "900", 60, 3600),
            max_attempts=bounded_int("REGISTRATION_CHECK_MAX_ATTEMPTS", "5", 1, 20),
            request_timeout_seconds=positive_float(
                "SUPABASE_REQUEST_TIMEOUT_SECONDS", "30", 5.0
            ),
            page_timeout_ms=bounded_int("REGISTRATION_CHECK_PAGE_TIMEOUT_MS", "60000", 10000, 180000),
            screenshot_bucket=(
                os.getenv("REGISTRATION_CHECK_SCREENSHOT_BUCKET", DEFAULT_BUCKET).strip()
                or DEFAULT_BUCKET
            ),
            screenshot_prefix=(
                os.getenv("REGISTRATION_CHECK_SCREENSHOT_PREFIX", "registration-check-previews").strip()
                or "registration-check-previews"
            ),
            log_level=os.getenv("LOG_LEVEL", "INFO").strip().upper(),
        )


class SupabaseAdminClient:
    def __init__(self, config: WorkerConfig) -> None:
        self.config = config
        self.rest_url = f"{config.supabase_url}/rest/v1"
        self.storage_url = f"{config.supabase_url}/storage/v1/object"
        self.session = requests.Session()
        self.session.headers.update(
            {
                "apikey": config.service_role_key,
                "Authorization": f"Bearer {config.service_role_key}",
                "Content-Type": "application/json",
            }
        )

    def _check(self, response: requests.Response, action: str) -> None:
        if not response.ok:
            raise WorkerError(f"{action}失败：HTTP {response.status_code} {response.text[:400]}")

    def _rpc(self, name: str, payload: dict[str, Any]) -> Any:
        response = self.session.post(
            f"{self.rest_url}/rpc/{name}",
            json=payload,
            timeout=self.config.request_timeout_seconds,
        )
        self._check(response, f"调用 Supabase RPC {name}")
        if not response.content:
            return None
        return response.json()

    def claim_batch(self) -> dict[str, Any] | None:
        rows = self._rpc(
            "claim_registration_check_batch",
            {
                "p_worker_id": self.config.worker_id,
                "p_lease_seconds": self.config.lease_seconds,
                "p_max_attempts": self.config.max_attempts,
            },
        )
        if not rows:
            return None
        if not isinstance(rows, list):
            raise WorkerError("claim_registration_check_batch 返回格式不正确")
        return dict(rows[0])

    def claim_item(self, batch_id: str) -> dict[str, Any] | None:
        rows = self._rpc(
            "claim_registration_check_item",
            {
                "p_batch_id": batch_id,
                "p_worker_id": self.config.worker_id,
                "p_lease_seconds": self.config.lease_seconds,
                "p_max_attempts": self.config.max_attempts,
            },
        )
        if not rows:
            return None
        if not isinstance(rows, list):
            raise WorkerError("claim_registration_check_item 返回格式不正确")
        return dict(rows[0])

    def get_runtime_input(self, item_id: str) -> dict[str, str]:
        rows = self._rpc(
            "get_registration_check_runtime_input",
            {"p_item_id": item_id, "p_worker_id": self.config.worker_id},
        )
        if not isinstance(rows, list) or not rows or not isinstance(rows[0], dict):
            raise WorkerError("Check Registration 运行时输入返回格式不正确")
        row = dict(rows[0])
        passport_number = normalize_passport(row.get("passport_number"))
        nationality = normalize_nationality(row.get("nationality"))
        pin_value = normalize_pin(row.get("pin_value"))
        if not passport_number or not nationality or not pin_value:
            raise WorkerError("Check Registration 运行时输入缺失")
        return {
            "passport_number": passport_number,
            "nationality": nationality,
            "pin_value": pin_value,
        }

    def heartbeat(
        self,
        *,
        status: str,
        batch_id: str | None = None,
        item_id: str | None = None,
    ) -> None:
        self._rpc(
            "heartbeat_registration_check",
            {
                "p_worker_id": self.config.worker_id,
                "p_batch_id": batch_id,
                "p_item_id": item_id,
                "p_lease_seconds": self.config.lease_seconds,
                "p_status": status,
                "p_hostname": socket.gethostname(),
                "p_version": "registration-check-1",
            },
        )

    def upload_screenshot(self, item_id: str, image_bytes: bytes) -> str:
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        safe_item_id = re.sub(r"[^a-zA-Z0-9-]", "", item_id)
        object_path = f"{self.config.screenshot_prefix}/{day}/{safe_item_id}.png"
        bucket = quote(self.config.screenshot_bucket, safe="")
        path = quote(object_path, safe="/")
        response = self.session.post(
            f"{self.storage_url}/{bucket}/{path}",
            headers={"Content-Type": "image/png", "x-upsert": "true"},
            data=image_bytes,
            timeout=self.config.request_timeout_seconds,
        )
        self._check(response, "上传 Check Registration 私有截图")
        return object_path

    def finish_item(
        self,
        *,
        item_id: str,
        check_status: str,
        normalized_status: str | None,
        raw_summary: dict[str, Any],
        screenshot_path: str | None,
        challenge_type: str | None,
        result_unknown: bool,
        retryable: bool,
        error_code: str | None,
        error_message: str | None,
    ) -> dict[str, Any]:
        result = self._rpc(
            "finish_registration_check_item",
            {
                "p_item_id": item_id,
                "p_worker_id": self.config.worker_id,
                "p_check_status": check_status,
                "p_normalized_status": normalized_status,
                "p_raw_summary": raw_summary,
                "p_screenshot_path": screenshot_path,
                "p_challenge_type": challenge_type,
                "p_result_confirmed": False,
                "p_result_unknown": result_unknown,
                "p_retryable": retryable,
                "p_max_attempts": self.config.max_attempts,
                "p_error_code": error_code,
                "p_error_message": error_message,
            },
        )
        if not isinstance(result, dict):
            raise WorkerError("finish_registration_check_item 返回格式不正确")
        return result


def normalize_pin(value: Any) -> str | None:
    if value is None:
        return None
    normalized = str(value).strip()
    return normalized or None


def normalize_passport(value: Any) -> str:
    return str(value or "").strip().upper()


def normalize_nationality(value: Any) -> str:
    return str(value or "").strip().upper()


def challenge_type_from_markup(markup: str) -> str | None:
    """Return a challenge label only when the official challenge structure is present."""
    lowered = markup.lower()
    has_container = "slidercontainer" in lowered
    canvas_count = len(re.findall(r"<canvas\b", lowered))
    has_drag_text = "drag to verify" in lowered
    if has_container and canvas_count >= 2 and has_drag_text:
        return "CAPTCHA_SLIDER"
    return None


def make_preview_summary(
    *,
    challenge_type: str | None,
    field_checks: dict[str, bool],
    screenshot_saved: bool,
) -> dict[str, Any]:
    return {
        "source": "MDAC_CHECK_REGISTRATION",
        "mode": "FILL_REVIEW",
        "fields_checked": sorted(field_checks),
        "field_values_verified": all(field_checks.values()),
        "challenge_type": challenge_type,
        "screenshot_saved": screenshot_saved,
        "captcha_bypass": False,
        "submitted": False,
        "result_confirmed": False,
        "result_page_read": False,
        "passport_number_logged": False,
        "pin_value_logged": False,
    }


def classify_page_failure(exception: Exception) -> tuple[str, str, bool]:
    if isinstance(exception, PlaywrightTimeoutError):
        return (
            "PAGE_TIMEOUT",
            "Official Check Registration page did not become ready in time",
            True,
        )
    if isinstance(exception, (requests.RequestException, TimeoutError)):
        return ("TRANSIENT_REMOTE_ERROR", "Temporary remote service error", True)
    return ("REGISTRATION_CHECK_WORKER_ERROR", "Check Registration preview failed", True)


async def preview_page(
    config: WorkerConfig,
    runtime_input: dict[str, str],
) -> tuple[bytes, str | None, dict[str, Any]]:
    async with async_playwright() as playwright:
        browser: Browser = await playwright.chromium.launch(
            headless=True,
            args=["--no-sandbox"],
        )
        try:
            page: Page = await browser.new_page()
            await page.goto(
                config.check_url,
                wait_until="domcontentloaded",
                timeout=config.page_timeout_ms,
            )
            await page.wait_for_selector("#passNo", state="visible", timeout=config.page_timeout_ms)
            await page.wait_for_selector("#nationality", state="visible", timeout=config.page_timeout_ms)
            await page.wait_for_selector("#pinKeyId", state="visible", timeout=config.page_timeout_ms)

            await page.fill("#passNo", runtime_input["passport_number"])
            await page.select_option("#nationality", runtime_input["nationality"])
            await page.fill("#pinKeyId", runtime_input["pin_value"])

            field_checks = {
                "passNo": (await page.input_value("#passNo")) == runtime_input["passport_number"],
                "nationality": (await page.input_value("#nationality")) == runtime_input["nationality"],
                "pinKeyId": (await page.input_value("#pinKeyId")) == runtime_input["pin_value"],
            }
            if not all(field_checks.values()):
                raise WorkerError("Check Registration 字段回读不一致")

            markup = await page.content()
            challenge_type = challenge_type_from_markup(markup)
            screenshot = await page.screenshot(full_page=True, type="png")
            summary = make_preview_summary(
                challenge_type=challenge_type,
                field_checks=field_checks,
                screenshot_saved=True,
            )
            return screenshot, challenge_type, summary
        finally:
            await browser.close()


class RegistrationCheckWorker:
    def __init__(self, config: WorkerConfig) -> None:
        self.config = config
        self.supabase = SupabaseAdminClient(config)

    def process_batch(self, batch: dict[str, Any]) -> int:
        batch_id = str(batch["id"])
        self.supabase.heartbeat(status="BUSY", batch_id=batch_id)
        processed = 0
        while True:
            item = self.supabase.claim_item(batch_id)
            if item is None:
                break
            item_id = str(item["id"])
            self.supabase.heartbeat(status="BUSY", batch_id=batch_id, item_id=item_id)
            try:
                runtime_input = self.supabase.get_runtime_input(item_id)
                screenshot, challenge_type, summary = asyncio.run(
                    preview_page(self.config, runtime_input)
                )
                screenshot_path: str | None = None
                try:
                    screenshot_path = self.supabase.upload_screenshot(item_id, screenshot)
                except Exception:
                    LOG.exception("Check Registration 截图上传失败；不记录截图内容")
                    summary["screenshot_saved"] = False
                    summary["screenshot_upload_failed"] = True

                if challenge_type is not None:
                    error_code = "MANUAL_CHALLENGE_REQUIRED"
                    error_message = "Official CAPTCHA/slider detected; manual review required"
                else:
                    error_code = "NO_SUBMIT_PREVIEW"
                    error_message = "Fields were verified but no result was queried because this worker never submits"
                self.supabase.finish_item(
                    item_id=item_id,
                    check_status="UNPARSED",
                    normalized_status=None,
                    raw_summary=summary,
                    screenshot_path=screenshot_path,
                    challenge_type=challenge_type,
                    result_unknown=True,
                    retryable=False,
                    error_code=error_code,
                    error_message=error_message,
                )
                processed += 1
                LOG.warning(
                    "Check Registration 预览完成：需要人工审核；不自动处理挑战，不确认结果，不提交"
                )
            except Exception as exception:
                error_code, error_message, retryable = classify_page_failure(exception)
                LOG.exception("Check Registration 预览异常；未确认结果")
                try:
                    self.supabase.finish_item(
                        item_id=item_id,
                        check_status="FAILED",
                        normalized_status=None,
                        raw_summary={
                            "source": "MDAC_CHECK_REGISTRATION",
                            "mode": "FILL_REVIEW",
                            "submitted": False,
                            "result_confirmed": False,
                            "captcha_bypass": False,
                            "screenshot_saved": False,
                        },
                        screenshot_path=None,
                        challenge_type=None,
                        result_unknown=True,
                        retryable=retryable,
                        error_code=error_code,
                        error_message=error_message,
                    )
                except Exception:
                    LOG.exception("Check Registration 失败回写异常")

        self.supabase.heartbeat(status="ONLINE")
        return processed

    def run_once(self) -> int:
        self.supabase.heartbeat(status="ONLINE")
        batch = self.supabase.claim_batch()
        if batch is None:
            return 0
        return self.process_batch(batch)

    def run_poll(self) -> None:
        LOG.info(
            "Registration Check Worker ONLINE：轮询间隔 %ss；FILL_REVIEW；不处理 CAPTCHA；不提交",
            self.config.poll_seconds,
        )
        while True:
            try:
                processed = self.run_once()
                if processed:
                    LOG.info("本轮处理 %d 项 Check Registration 预览任务", processed)
            except Exception:
                LOG.exception("Registration Check Worker 本轮异常；未将结果标为成功")
                try:
                    self.supabase.heartbeat(status="ERROR")
                except Exception:
                    LOG.exception("无法写入 Registration Check Worker ERROR 心跳")
            time.sleep(self.config.poll_seconds)


def configure_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true", help="run one queue pass")
    parser.add_argument("--poll", action="store_true", help="run the polling loop")
    args = parser.parse_args()
    config = WorkerConfig.from_env()
    configure_logging(config.log_level)
    worker = RegistrationCheckWorker(config)
    if args.once:
        worker.run_once()
        return
    if args.poll:
        worker.run_poll()
        return
    parser.error("必须指定 --once 或 --poll")


if __name__ == "__main__":
    main()
