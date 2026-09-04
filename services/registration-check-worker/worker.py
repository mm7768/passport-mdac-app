"""Check Registration Worker.

This module queries the official Check Registration service and records verified outcomes.
It reads the passport number and nationality from the client-safe task snapshot,
gets the PIN only through a service-role-only RPC, fills the official public query
page, verifies the filled DOM values, detects official CAPTCHA/slider challenges,
saves evidence only for found records or ambiguous responses, and writes the outcome.

It never solves a CAPTCHA or simulates a drag. It only invokes the official Search action
when no challenge is present. No passport number or PIN is written to logs.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import socket
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from urllib.parse import quote

import requests
from playwright.async_api import Browser, Page, TimeoutError as PlaywrightTimeoutError, async_playwright

LOG = logging.getLogger("registration_check_worker")
WORKER_NAME = "registration_check"
DEFAULT_CHECK_URL = "https://imigresen-online.imi.gov.my/mdac/register?viewRegistration"
DEFAULT_BUCKET = "passport-documents"


def log_event(
    level: int,
    *,
    step: str,
    status: str,
    batch_id: str | None = None,
    item_id: str | None = None,
    customer_id: str | None = None,
    result: Any = None,
    error_code: str | None = None,
    error_message: str | None = None,
) -> None:
    """Write one searchable event without passport, PIN, or page contents."""
    payload = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "worker": WORKER_NAME,
        "batch_id": batch_id,
        "item_id": item_id,
        "customer_id": customer_id,
        "step": step,
        "status": status,
        "result": result,
        "error_code": error_code,
        "error_message": error_message,
    }
    LOG.log(level, json.dumps(payload, ensure_ascii=False, sort_keys=True, default=str))


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

        mode = os.getenv("REGISTRATION_CHECK_MODE", "AUTO_QUERY").strip().upper()
        if mode not in {"AUTO_QUERY", "FILL_REVIEW"}:
            raise WorkerError("REGISTRATION_CHECK_MODE 必须为 AUTO_QUERY")
        if mode == "FILL_REVIEW":
            LOG.warning("REGISTRATION_CHECK_MODE=FILL_REVIEW 已兼容升级为 AUTO_QUERY")
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
                "p_version": "registration-check-2",
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
        result_confirmed: bool,
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
                "p_result_confirmed": result_confirmed,
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


def make_query_summary(
    *,
    challenge_type: str | None,
    field_checks: dict[str, bool],
    outcome: str,
    screenshot_saved: bool,
) -> dict[str, Any]:
    return {
        "source": "MDAC_CHECK_REGISTRATION",
        "mode": "AUTO_QUERY",
        "fields_checked": sorted(field_checks),
        "field_values_verified": all(field_checks.values()),
        "challenge_type": challenge_type,
        "outcome": outcome,
        "screenshot_saved": screenshot_saved,
        "captcha_bypass": False,
        "submitted": outcome != "CHALLENGE",
        "result_confirmed": outcome in {"REGISTERED", "NOT_REGISTERED", "PIN_INVALID"},
        "result_page_read": outcome != "CHALLENGE",
        "passport_number_logged": False,
        "pin_value_logged": False,
    }


def classify_result_text(text: str) -> str:
    normalized = " ".join(text.upper().split())
    pin_markers = (
        "INVALID PIN", "INCORRECT PIN", "WRONG PIN", "PIN IS INVALID",
        "PIN NOT VALID", "INVALID PASSPORT OR PIN",
    )
    no_record_markers = (
        "NO RECORD FOUND", "NO DATA FOUND", "RECORD NOT FOUND",
        "NO REGISTRATION FOUND", "NO MATCHING RECORD",
    )
    registered_markers = (
        "REGISTRATION INFORMATION", "REGISTRATION DETAILS",
        "ARRIVAL INFORMATION", "TRAVEL INFORMATION",
    )
    if any(marker in normalized for marker in pin_markers):
        return "PIN_INVALID"
    if any(marker in normalized for marker in no_record_markers):
        return "NOT_REGISTERED"
    if any(marker in normalized for marker in registered_markers):
        return "REGISTERED"
    return "UNKNOWN"


def classify_page_failure(exception: Exception) -> tuple[str, str, bool]:
    if isinstance(exception, PlaywrightTimeoutError):
        return ("PAGE_TIMEOUT", "Official Check Registration page did not respond in time", True)
    if isinstance(exception, (requests.RequestException, TimeoutError)):
        return ("TRANSIENT_REMOTE_ERROR", "Temporary remote service error", True)
    return ("REGISTRATION_CHECK_WORKER_ERROR", "Check Registration query failed", True)


async def query_page(
    config: WorkerConfig,
    runtime_input: dict[str, str],
) -> tuple[bytes | None, str | None, str, dict[str, Any]]:
    async with async_playwright() as playwright:
        browser: Browser = await playwright.chromium.launch(headless=True, args=["--no-sandbox"])
        try:
            page: Page = await browser.new_page()
            await page.goto(config.check_url, wait_until="domcontentloaded", timeout=config.page_timeout_ms)
            for selector in ("#passNo", "#nationality", "#pinKeyId"):
                await page.wait_for_selector(selector, state="visible", timeout=config.page_timeout_ms)

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

            challenge_type = challenge_type_from_markup(await page.content())
            if challenge_type:
                summary = make_query_summary(
                    challenge_type=challenge_type, field_checks=field_checks,
                    outcome="CHALLENGE", screenshot_saved=False,
                )
                return None, challenge_type, "CHALLENGE", summary

            before_text = await page.locator("body").inner_text()
            search = page.locator("#submit, #searchRegistration").first
            if await search.count() == 0:
                search = page.get_by_text("Search", exact=True).first
            if await search.count() == 0:
                search = page.locator("button[type=submit], input[type=submit]").first
            if await search.count() == 0:
                raise WorkerError("找不到官方 Search 按钮")

            await search.click()
            try:
                await page.wait_for_load_state("networkidle", timeout=min(config.page_timeout_ms, 30000))
            except PlaywrightTimeoutError:
                pass

            outcome = "UNKNOWN"
            deadline = time.monotonic() + min(config.page_timeout_ms / 1000, 30)
            while time.monotonic() < deadline:
                body_text = await page.locator("body").inner_text()
                outcome = classify_result_text(body_text)
                if outcome != "UNKNOWN":
                    break
                if body_text != before_text:
                    await page.wait_for_timeout(500)
                else:
                    await page.wait_for_timeout(750)

            screenshot = None
            if outcome in {"REGISTERED", "UNKNOWN"}:
                screenshot = await page.screenshot(full_page=True, type="png")
            summary = make_query_summary(
                challenge_type=None, field_checks=field_checks, outcome=outcome,
                screenshot_saved=screenshot is not None,
            )
            return screenshot, None, outcome, summary
        finally:
            await browser.close()


class RegistrationCheckWorker:
    def __init__(self, config: WorkerConfig) -> None:
        self.config = config
        self.supabase = SupabaseAdminClient(config)

    def process_batch(self, batch: dict[str, Any]) -> int:
        batch_id = str(batch["id"])
        self.supabase.heartbeat(status="BUSY", batch_id=batch_id)
        log_event(
            logging.INFO,
            step="batch_claim",
            status="running",
            batch_id=batch_id,
        )
        processed = 0
        while True:
            item = self.supabase.claim_item(batch_id)
            if item is None:
                break
            item_id = str(item["id"])
            customer_id = str(item.get("customer_id") or "") or None
            self.supabase.heartbeat(status="BUSY", batch_id=batch_id, item_id=item_id)
            log_event(
                logging.INFO,
                step="item_claim",
                status="running",
                batch_id=batch_id,
                item_id=item_id,
                customer_id=customer_id,
            )
            try:
                runtime_input = self.supabase.get_runtime_input(item_id)
                screenshot, challenge_type, outcome, summary = asyncio.run(
                    query_page(self.config, runtime_input)
                )
                screenshot_path: str | None = None
                if screenshot is not None:
                    try:
                        screenshot_path = self.supabase.upload_screenshot(item_id, screenshot)
                    except Exception:
                        summary["screenshot_saved"] = False
                        summary["screenshot_upload_failed"] = True
                        log_event(
                            logging.WARNING, step="screenshot_upload", status="failed",
                            batch_id=batch_id, item_id=item_id, customer_id=customer_id,
                            error_code="SCREENSHOT_UPLOAD_FAILED",
                            error_message="Registration Check evidence screenshot upload failed",
                        )

                mapping = {
                    "REGISTERED": ("PARSED", "REGISTERED", False, True, False, None, None, "succeeded"),
                    "NOT_REGISTERED": ("PARSED", "NOT_REGISTERED", False, True, False, "NO_REGISTRATION_RECORD", "No official registration record found", "succeeded"),
                    "PIN_INVALID": ("PARSED", "PIN_INVALID", False, True, False, "PIN_INVALID", "Official service rejected the PIN", "failed"),
                    "CHALLENGE": ("UNPARSED", None, True, False, False, "MANUAL_CHALLENGE_REQUIRED", "Official CAPTCHA/slider detected; manual review required", "needs_review"),
                    "UNKNOWN": ("UNPARSED", None, True, False, False, "REGISTRATION_RESULT_UNPARSED", "Official response could not be classified", "needs_review"),
                }
                check_status, normalized, unknown, confirmed, retryable, error_code, error_message, log_status = mapping[outcome]
                self.supabase.finish_item(
                    item_id=item_id, check_status=check_status, normalized_status=normalized,
                    raw_summary=summary, screenshot_path=screenshot_path,
                    challenge_type=challenge_type, result_unknown=unknown,
                    result_confirmed=confirmed, retryable=retryable,
                    error_code=error_code, error_message=error_message,
                )
                processed += 1
                log_event(
                    logging.INFO if log_status == "succeeded" else logging.WARNING,
                    step="result_writeback", status=log_status, batch_id=batch_id,
                    item_id=item_id, customer_id=customer_id, result=outcome,
                    error_code=error_code, error_message=error_message,
                )
            except Exception as exception:
                error_code, error_message, retryable = classify_page_failure(exception)
                log_event(
                    logging.ERROR,
                    step="page_preview",
                    status="failed",
                    batch_id=batch_id,
                    item_id=item_id,
                    customer_id=customer_id,
                    result="RESULT_UNKNOWN",
                    error_code=error_code,
                    error_message=error_message,
                )
                try:
                    self.supabase.finish_item(
                        item_id=item_id,
                        check_status="FAILED",
                        normalized_status=None,
                        raw_summary={
                            "source": "MDAC_CHECK_REGISTRATION",
                            "mode": "AUTO_QUERY",
                            "submitted": False,
                            "result_confirmed": False,
                            "captcha_bypass": False,
                            "screenshot_saved": False,
                        },
                        screenshot_path=None,
                        challenge_type=None,
                        result_unknown=True,
                        result_confirmed=False,
                        retryable=retryable,
                        error_code=error_code,
                        error_message=error_message,
                    )
                except Exception:
                    log_event(
                        logging.ERROR,
                        step="result_writeback",
                        status="failed",
                        batch_id=batch_id,
                        item_id=item_id,
                        customer_id=customer_id,
                        result="FAILED",
                        error_code="SUPABASE_WRITEBACK_FAILED",
                        error_message="Registration Check failure writeback failed",
                    )

        self.supabase.heartbeat(status="ONLINE")
        log_event(
            logging.INFO,
            step="batch_complete",
            status="completed",
            batch_id=batch_id,
            result={"processed_count": processed},
        )
        return processed

    def run_once(self) -> int:
        self.supabase.heartbeat(status="ONLINE")
        batch = self.supabase.claim_batch()
        if batch is None:
            log_event(logging.DEBUG, step="batch_claim", status="idle")
            return 0
        return self.process_batch(batch)

    def run_poll(self) -> None:
        log_event(
            logging.INFO,
            step="worker_start",
            status="online",
            result={"mode": "AUTO_QUERY", "poll_seconds": self.config.poll_seconds},
        )
        while True:
            try:
                processed = self.run_once()
                if processed:
                    log_event(
                        logging.INFO,
                        step="poll_complete",
                        status="completed",
                        result={"processed_count": processed},
                    )
            except Exception:
                log_event(
                    logging.ERROR,
                    step="poll",
                    status="failed",
                    error_code="WORKER_POLL_FAILED",
                    error_message="Registration Check worker poll failed",
                )
                try:
                    self.supabase.heartbeat(status="ERROR")
                except Exception:
                    log_event(
                        logging.ERROR,
                        step="heartbeat",
                        status="failed",
                        error_code="HEARTBEAT_WRITE_FAILED",
                        error_message="Registration Check error heartbeat write failed",
                    )
            time.sleep(self.config.poll_seconds)


def configure_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(message)s",
        stream=sys.stdout,
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
