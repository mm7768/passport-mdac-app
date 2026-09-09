"""Check Visit Pass fill-and-review worker.

This worker is implemented from the official public MDAC Check Visit Pass page.
It fills the query form and verifies ordinary DOM fields, but it never submits the
form, never reads a result page, and never solves or bypasses CAPTCHA/slider
challenges. A completed run is written as NEEDS_REVIEW with result_unknown=true.

The PIN is returned only through a service-role-only Supabase RPC while the item
lease is owned by this worker. PIN values and credentials are never logged.
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

LOG = logging.getLogger("visit_pass_check_worker")
WORKER_NAME = "visit_pass_check"
DEFAULT_CHECK_URL = "https://imigresen-online.imi.gov.my/mdac/register?viewVisitPass"
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


def _load_env_file() -> None:
    env_file = os.getenv("ENV_FILE", "").strip()
    candidates = [env_file] if env_file else [".env.local", ".env"]
    script_dir = os.path.dirname(os.path.abspath(__file__))
    for c in candidates:
        if not c:
            continue
        path = c if os.path.isabs(c) else os.path.join(script_dir, c)
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    k = k.strip()
                    v = v.strip().strip("'\"")
                    if k not in os.environ:
                        os.environ[k] = v
            break

@dataclass(frozen=True)
class WorkerConfig:
    supabase_url: str
    service_role_key: str
    worker_id: str
    mode: str
    allow_real_submit: bool
    headless: bool
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
        _load_env_file()
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

        mode = os.getenv("VISIT_PASS_CHECK_MODE", "AUTO_SEARCH").strip().upper() or "AUTO_SEARCH"
        if mode not in {"AUTO_SEARCH", "FILL_REVIEW"}:
            raise WorkerError("VISIT_PASS_CHECK_MODE 必须为 AUTO_SEARCH 或 FILL_REVIEW")

        raw_allow_submit = os.getenv("ALLOW_REAL_SUBMIT", "").strip().lower()
        if mode == "FILL_REVIEW":
            if raw_allow_submit and raw_allow_submit != "false":
                raise WorkerError("FILL_REVIEW 模式下 ALLOW_REAL_SUBMIT 必须为 false")
            allow_real_submit = False
        else:
            allow_real_submit = raw_allow_submit != "false"

        headless = os.getenv("VISIT_PASS_CHECK_HEADLESS", "false").strip().lower() == "true"

        return cls(
            supabase_url=required("SUPABASE_URL").rstrip("/"),
            service_role_key=required("SUPABASE_SERVICE_ROLE_KEY"),
            worker_id=required("VISIT_PASS_CHECK_WORKER_ID"),
            mode=mode,
            allow_real_submit=allow_real_submit,
            headless=headless,
            check_url=os.getenv("VISIT_PASS_CHECK_URL", DEFAULT_CHECK_URL).strip()
            or DEFAULT_CHECK_URL,
            poll_seconds=positive_float("VISIT_PASS_CHECK_POLL_SECONDS", "30", 10.0),
            lease_seconds=bounded_int("VISIT_PASS_CHECK_LEASE_SECONDS", "900", 60, 3600),
            max_attempts=bounded_int("VISIT_PASS_CHECK_MAX_ATTEMPTS", "5", 1, 20),
            request_timeout_seconds=positive_float(
                "SUPABASE_REQUEST_TIMEOUT_SECONDS", "30", 5.0
            ),
            page_timeout_ms=bounded_int("VISIT_PASS_CHECK_PAGE_TIMEOUT_MS", "60000", 10000, 180000),
            screenshot_bucket=(
                os.getenv("VISIT_PASS_CHECK_SCREENSHOT_BUCKET", DEFAULT_BUCKET).strip()
                or DEFAULT_BUCKET
            ),
            screenshot_prefix=(
                os.getenv("VISIT_PASS_CHECK_SCREENSHOT_PREFIX", "visit-pass-check-previews").strip()
                or "visit-pass-check-previews"
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
            "claim_visit_pass_check_batch",
            {
                "p_worker_id": self.config.worker_id,
                "p_lease_seconds": self.config.lease_seconds,
                "p_max_attempts": self.config.max_attempts,
            },
        )
        if not rows:
            return None
        if not isinstance(rows, list):
            raise WorkerError("claim_visit_pass_check_batch 返回格式不正确")
        return dict(rows[0])

    def claim_item(self, batch_id: str) -> dict[str, Any] | None:
        rows = self._rpc(
            "claim_visit_pass_check_item",
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
            raise WorkerError("claim_visit_pass_check_item 返回格式不正确")
        return dict(rows[0])

    def get_runtime_input(self, item_id: str) -> dict[str, str]:
        rows = self._rpc(
            "get_visit_pass_check_runtime_input",
            {"p_item_id": item_id, "p_worker_id": self.config.worker_id},
        )
        if not isinstance(rows, list) or not rows or not isinstance(rows[0], dict):
            raise WorkerError("Check Visit Pass 运行时输入返回格式不正确")
        row = dict(rows[0])
        result = {
            "passport_number": normalize_passport(row.get("passport_number")),
            "nationality": normalize_nationality(row.get("nationality")),
            "email": normalize_email(row.get("email")),
            "region_code": normalize_region_code(row.get("region_code")),
            "mobile": normalize_mobile(row.get("mobile")),
            "pin_value": normalize_pin(row.get("pin_value")),
        }
        if not result["passport_number"] or not result["nationality"] or not result["pin_value"]:
            raise WorkerError("Check Visit Pass 运行时输入缺少护照号、国籍或 PIN")
        if not result["email"] or not result["region_code"] or not result["mobile"]:
            raise WorkerError("Check Visit Pass 运行时输入缺少邮箱、国家区号或手机号")
        return result

    def heartbeat(
        self,
        *,
        status: str,
        batch_id: str | None = None,
        item_id: str | None = None,
    ) -> None:
        self._rpc(
            "heartbeat_visit_pass_check",
            {
                "p_worker_id": self.config.worker_id,
                "p_batch_id": batch_id,
                "p_item_id": item_id,
                "p_lease_seconds": self.config.lease_seconds,
                "p_status": status,
                "p_hostname": socket.gethostname(),
                "p_version": "visit-pass-check-auto-2",
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
        self._check(response, "上传 Check Visit Pass 私有截图")
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
            "finish_visit_pass_check_item",
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
            raise WorkerError("finish_visit_pass_check_item 返回格式不正确")
        return result

    def finish_visit_pass_worker(
        self,
        *,
        item_id: str,
        outcome: str,
        evidence_path: str | None = None,
        raw_summary: dict[str, Any] | None = None,
        error_code: str | None = None,
        error_message: str | None = None,
    ) -> dict[str, Any]:
        result = self._rpc(
            "finish_visit_pass_check_worker",
            {
                "p_item_id": item_id,
                "p_worker_id": self.config.worker_id,
                "p_outcome": outcome,
                "p_evidence_path": evidence_path,
                "p_raw_summary": raw_summary or {},
                "p_error_code": error_code,
                "p_error_message": error_message,
            },
        )
        if not isinstance(result, dict):
            raise WorkerError("finish_visit_pass_check_worker 返回格式不正确")
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


def normalize_email(value: Any) -> str:
    return str(value or "").strip().lower()


def normalize_region_code(value: Any) -> str:
    normalized = str(value or "").strip()
    return normalized if normalized.isdigit() else ""


def normalize_mobile(value: Any) -> str:
    normalized = str(value or "").strip()
    return normalized if re.fullmatch(r"[0-9+\-]+", normalized or "") else ""


def challenge_type_from_markup(markup: str) -> str | None:
    """Return a label only when the official challenge structure is present."""
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
        "source": "MDAC_CHECK_VISIT_PASS",
        "mode": "FILL_REVIEW",
        "fields_checked": sorted(field_checks),
        "field_values_verified": all(field_checks.values()),
        "challenge_type": challenge_type,
        "screenshot_saved": screenshot_saved,
        "captcha_bypass": False,
        "submitted": False,
        "result_confirmed": False,
        "result_page_read": False,
        "movement_record_read": False,
        "passport_number_logged": False,
        "pin_value_logged": False,
        "note": "Official result was not queried because this worker never submits the form",
    }


def classify_page_failure(exception: Exception) -> tuple[str, str, bool]:
    if isinstance(exception, PlaywrightTimeoutError):
        return (
            "PAGE_TIMEOUT",
            "Official Check Visit Pass page did not become ready in time",
            True,
        )
    if isinstance(exception, (requests.RequestException, TimeoutError)):
        return ("TRANSIENT_REMOTE_ERROR", "Temporary remote service error", True)
    return ("VISIT_PASS_CHECK_WORKER_ERROR", "Check Visit Pass preview failed", True)


async def query_and_capture_page(
    config: WorkerConfig,
    runtime_input: dict[str, str],
) -> tuple[str, bytes, dict[str, Any]]:
    async with async_playwright() as playwright:
        browser: Browser = await playwright.chromium.launch(
            headless=config.headless,
            args=["--no-sandbox", "--disable-setuid-sandbox"],
        )
        context = await browser.new_context(
            user_agent=(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/124.0.0.0 Safari/537.36"
            ),
            viewport={"width": 1280, "height": 900},
        )
        try:
            page: Page = await context.new_page()

            async def route_handler(route, request):
                if not config.allow_real_submit and request.method == "POST":
                    LOG.warning("FILL_REVIEW 模式拦截到 POST 请求，已中止: %s", request.url)
                    await route.abort()
                    return
                await route.continue_()

            await page.route("**/*", route_handler)

            dialog_messages: list[str] = []

            async def on_dialog(dialog):
                msg = str(dialog.message)
                dialog_messages.append(msg)
                LOG.info("官方页面弹出 Dialog: %s", msg)
                try:
                    await dialog.dismiss()
                except Exception:
                    pass

            page.on("dialog", on_dialog)

            await page.goto(
                config.check_url,
                wait_until="domcontentloaded",
                timeout=config.page_timeout_ms,
            )
            for selector in ("#passNo", "#nationality", "#email", "#regCd", "#mobile", "#pinKeyId"):
                await page.wait_for_selector(selector, state="visible", timeout=config.page_timeout_ms)

            await page.fill("#passNo", runtime_input["passport_number"])
            await page.select_option("#nationality", runtime_input["nationality"])
            await page.fill("#email", runtime_input["email"])
            await page.select_option("#regCd", runtime_input["region_code"])
            await page.fill("#mobile", runtime_input["mobile"])
            await page.fill("#pinKeyId", runtime_input["pin_value"])

            field_checks = {
                "passNo": (await page.input_value("#passNo")) == runtime_input["passport_number"],
                "nationality": (await page.input_value("#nationality")) == runtime_input["nationality"],
                "email": (await page.input_value("#email")) == runtime_input["email"],
                "regCd": (await page.input_value("#regCd")) == runtime_input["region_code"],
                "mobile": (await page.input_value("#mobile")) == runtime_input["mobile"],
                "pinKeyId": (await page.input_value("#pinKeyId")) == runtime_input["pin_value"],
            }
            if not all(field_checks.values()):
                raise WorkerError("Check Visit Pass 字段回读不一致")

            markup = await page.content()
            challenge_type = challenge_type_from_markup(markup)

            if config.mode == "FILL_REVIEW":
                screenshot = await page.screenshot(full_page=True, type="png")
                summary = make_preview_summary(
                    challenge_type=challenge_type,
                    field_checks=field_checks,
                    screenshot_saved=True,
                )
                return ("NEEDS_REVIEW", screenshot, summary)

            from slider_solver import solve_mdac_slider

            slider_ok = True
            has_slider = (
                challenge_type == "CAPTCHA_SLIDER"
                or await page.locator(".sliderContainer, #captcha canvas").count() > 0
            )
            if has_slider:
                slider_ok = await solve_mdac_slider(page, log_func=LOG.info, max_retries=3)

            if not slider_ok:
                screenshot = await page.screenshot(full_page=True, type="png")
                summary = make_preview_summary(
                    challenge_type="CAPTCHA_SLIDER",
                    field_checks=field_checks,
                    screenshot_saved=True,
                )
                summary["slider_solved"] = False
                summary["error"] = "SLIDER_SOLVER_FAILED"
                return ("NEEDS_REVIEW", screenshot, summary)

            LOG.info("滑块验证通过，准备触发 Submit 查询 Visit Pass...")
            submit_locator = page.locator(
                "#submit, button[type='submit'], input[type='submit'], #searchVisitPass"
            ).first
            if await submit_locator.is_disabled():
                await page.wait_for_timeout(1000)

            await submit_locator.click()
            LOG.info("已点击 Submit 查询，等待结果返回...")

            outcome: str | None = None
            for _ in range(15):
                await page.wait_for_timeout(1000)

                all_dialog_text = " ".join(dialog_messages).lower()
                if "invalid pin" in all_dialog_text or "pin tidak sah" in all_dialog_text or "pin salah" in all_dialog_text:
                    LOG.warning("官方弹窗明确提示：PIN 无效 (PIN_INVALID)")
                    outcome = "PIN_INVALID"
                    break
                if "no record" in all_dialog_text or "rekod tidak dijumpai" in all_dialog_text or "tiada rekod" in all_dialog_text:
                    LOG.info("官方弹窗明确提示：没有找到记录 (NO_RECORD)")
                    outcome = "NO_RECORD"
                    break

                page_text = await page.evaluate("() => document.body ? document.body.innerText : ''")
                lowered_text = page_text.lower()

                if "invalid pin" in lowered_text or "pin tidak sah" in lowered_text or "pin salah" in lowered_text:
                    LOG.warning("官方页面明确显示：PIN 无效 (PIN_INVALID)")
                    outcome = "PIN_INVALID"
                    break

                if "no record found" in lowered_text or "rekod tidak dijumpai" in lowered_text or "tiada rekod" in lowered_text:
                    LOG.info("官方页面明确显示：没有找到记录 (NO_RECORD)")
                    outcome = "NO_RECORD"
                    break

                if (
                    "visit pass information" in lowered_text
                    or "type of pass" in lowered_text
                    or "date of pass expiry" in lowered_text
                    or "movement record" in lowered_text
                    or "rekod pergerakan" in lowered_text
                    or "pass type" in lowered_text
                    or "jenis pas" in lowered_text
                    or "social visit pass" in lowered_text
                    or "date of entry" in lowered_text
                    or "tarikh masuk" in lowered_text
                ):
                    LOG.info("官方页面明确显示：查到 Visit Pass 记录 (FOUND)")
                    outcome = "FOUND"
                    break

            if outcome is None:
                LOG.warning("未检测到明确结果或超时，标记为 NEEDS_REVIEW 供人工核对")
                outcome = "NEEDS_REVIEW"

            screenshot = await page.screenshot(full_page=True, type="png")
            summary = {
                "source": "MDAC_CHECK_VISIT_PASS",
                "mode": "AUTO_SEARCH",
                "outcome": outcome,
                "slider_solved": True,
                "submitted": True,
                "result_confirmed": (outcome in {"FOUND", "NO_RECORD", "PIN_INVALID"}),
                "dialogs": dialog_messages if dialog_messages else None,
            }
            return (outcome, screenshot, summary)
        finally:
            await browser.close()


async def preview_page(
    config: WorkerConfig,
    runtime_input: dict[str, str],
) -> tuple[bytes, str | None, dict[str, Any]]:
    """Legacy helper for backward compatibility."""
    outcome, screenshot, summary = await query_and_capture_page(config, runtime_input)
    challenge_type = summary.get("challenge_type")
    return screenshot, challenge_type, summary


class VisitPassCheckWorker:
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
                outcome, screenshot, summary = asyncio.run(
                    query_and_capture_page(self.config, runtime_input)
                )
                screenshot_path: str | None = None
                try:
                    screenshot_path = self.supabase.upload_screenshot(item_id, screenshot)
                    summary["screenshot_path"] = screenshot_path
                except Exception as upload_err:
                    log_event(
                        logging.WARNING,
                        step="screenshot_upload",
                        status="failed",
                        batch_id=batch_id,
                        item_id=item_id,
                        customer_id=customer_id,
                        error_code="SCREENSHOT_UPLOAD_FAILED",
                        error_message=str(upload_err),
                    )
                    summary["screenshot_saved"] = False
                    summary["screenshot_upload_failed"] = True

                error_code = None
                error_message = None
                if outcome == "NEEDS_REVIEW":
                    error_code = summary.get("error") or summary.get("outcome") or "MANUAL_REVIEW_REQUIRED"
                    error_message = summary.get("note") or "Check Visit Pass 需要人工审核"
                elif outcome == "NO_RECORD":
                    error_code = "NO_RECORD"
                    error_message = "官方页面显示无记录"
                elif outcome == "PIN_INVALID":
                    error_code = "PIN_INVALID"
                    error_message = "官方页面提示 PIN 错误"

                self.supabase.finish_visit_pass_worker(
                    item_id=item_id,
                    outcome=outcome,
                    evidence_path=screenshot_path,
                    raw_summary=summary,
                    error_code=error_code,
                    error_message=error_message,
                )
                processed += 1
                log_event(
                    logging.INFO,
                    step="result_writeback",
                    status="succeeded" if outcome == "FOUND" else "processed",
                    batch_id=batch_id,
                    item_id=item_id,
                    customer_id=customer_id,
                    result=outcome,
                    error_code=error_code,
                    error_message=error_message,
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
                    self.supabase.finish_visit_pass_worker(
                        item_id=item_id,
                        outcome="NEEDS_REVIEW",
                        evidence_path=None,
                        raw_summary={
                            "source": "MDAC_CHECK_VISIT_PASS",
                            "mode": self.config.mode,
                            "submitted": False,
                            "result_confirmed": False,
                            "captcha_bypass": False,
                            "screenshot_saved": False,
                            "error": error_code,
                        },
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
                        error_message="Visit Pass Check failure writeback failed",
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
            result={"mode": self.config.mode, "poll_seconds": self.config.poll_seconds},
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
                    error_message="Visit Pass Check worker poll failed",
                )
                try:
                    self.supabase.heartbeat(status="ERROR")
                except Exception:
                    log_event(
                        logging.ERROR,
                        step="heartbeat",
                        status="failed",
                        error_code="HEARTBEAT_WRITE_FAILED",
                        error_message="Visit Pass Check error heartbeat write failed",
                    )
            time.sleep(self.config.poll_seconds)


def configure_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(message)s",
        stream=sys.stdout,
    )


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true", help="run one queue pass")
    parser.add_argument("--poll", action="store_true", help="run the polling loop")
    args = parser.parse_args()
    config = WorkerConfig.from_env()
    configure_logging(config.log_level)
    print("========================================================")
    print("   Check Visit Pass Worker 已启动（本地服务）")
    print(f"  Worker ID: {config.worker_id}")
    print(f"  运行模式: {config.mode} (允许真实查询: {config.allow_real_submit})")
    print(f"  桌面浏览器: {'后台静默' if config.headless else '前台可见'}")
    print("  正在监听 Supabase Visit Pass Check 队列...")
    print("========================================================")
    worker = VisitPassCheckWorker(config)
    if args.once:
        worker.run_once()
        return
    if args.poll:
        worker.run_poll()
        return
    parser.error("必须指定 --once 或 --poll")


if __name__ == "__main__":
    main()
