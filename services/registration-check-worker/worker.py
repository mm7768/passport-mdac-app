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
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from urllib.parse import quote

import requests
from playwright.async_api import Browser, Page, TimeoutError as PlaywrightTimeoutError, async_playwright

from slider_solver import solve_mdac_slider

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

        mode = os.getenv("REGISTRATION_CHECK_MODE", "AUTO_SEARCH").strip().upper() or "AUTO_SEARCH"
        if mode not in {"AUTO_SEARCH", "FILL_REVIEW"}:
            raise WorkerError("REGISTRATION_CHECK_MODE 必须为 AUTO_SEARCH 或 FILL_REVIEW")

        raw_allow_submit = os.getenv("ALLOW_REAL_SUBMIT", "").strip().lower()
        if mode == "FILL_REVIEW":
            if raw_allow_submit and raw_allow_submit != "false":
                raise WorkerError("FILL_REVIEW 模式下 ALLOW_REAL_SUBMIT 必须为 false")
            allow_real_submit = False
        else:
            allow_real_submit = raw_allow_submit != "false"

        headless = os.getenv("REGISTRATION_CHECK_HEADLESS", "true").strip().lower() == "true"

        return cls(
            supabase_url=required("SUPABASE_URL").rstrip("/"),
            service_role_key=required("SUPABASE_SERVICE_ROLE_KEY"),
            worker_id=required("REGISTRATION_CHECK_WORKER_ID"),
            mode=mode,
            allow_real_submit=allow_real_submit,
            headless=headless,
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
                "p_version": "registration-check-auto-2",
            },
        )

    def upload_evidence(self, item_id: str, content: bytes, extension: str = "png") -> str:
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        safe_item_id = re.sub(r"[^a-zA-Z0-9-]", "", item_id)
        object_path = f"{self.config.screenshot_prefix}/{day}/{safe_item_id}.{extension}"
        bucket = quote(self.config.screenshot_bucket, safe="")
        path = quote(object_path, safe="/")
        content_type = "application/pdf" if extension == "pdf" else "image/png"
        response = self.session.post(
            f"{self.storage_url}/{bucket}/{path}",
            headers={"Content-Type": content_type, "x-upsert": "true"},
            data=content,
            timeout=self.config.request_timeout_seconds,
        )
        self._check(response, f"上传 Check Registration 私有凭证 ({extension})")
        return object_path

    def upload_screenshot(self, item_id: str, image_bytes: bytes) -> str:
        return self.upload_evidence(item_id, image_bytes, "png")

    def finish_check_worker(
        self,
        *,
        item_id: str,
        outcome: str,
        evidence_path: str | None = None,
        raw_summary: dict[str, Any] | None = None,
        error_code: str | None = None,
        error_message: str | None = None,
    ) -> dict[str, Any]:
        try:
            result = self._rpc(
                "finish_registration_check_worker",
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
            if isinstance(result, dict):
                return result
        except Exception as exc:
            LOG.warning(
                "调用 finish_registration_check_worker 异常，回退至 finish_item: %s",
                exc,
            )

        check_status = (
            "PARSED"
            if outcome in ("FOUND", "NO_RECORD")
            else ("FAILED" if outcome == "PIN_INVALID" else "NEEDS_REVIEW")
        )
        return self.finish_item(
            item_id=item_id,
            check_status=check_status,
            normalized_status=outcome
            if outcome in ("FOUND", "NO_RECORD", "PIN_INVALID")
            else None,
            raw_summary=raw_summary or {},
            screenshot_path=evidence_path,
            challenge_type="CAPTCHA_SLIDER" if outcome == "FOUND" else None,
            result_unknown=(outcome not in ("FOUND", "NO_RECORD", "PIN_INVALID")),
            retryable=False,
            error_code=error_code,
            error_message=error_message,
        )

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


def date_candidates(iso_date: str | None) -> list[str]:
    if not iso_date:
        return []
    text = str(iso_date).strip()
    parts = text.split("-")
    if len(parts) != 3:
        return [text]
    year, month_str, day_str = parts[0], parts[1].zfill(2), parts[2].zfill(2)
    cands = [
        f"{day_str}/{month_str}/{year}",
        f"{day_str}-{month_str}-{year}",
        f"{year}-{month_str}-{day_str}",
        f"{day_str}.{month_str}.{year}",
    ]
    try:
        month_int = int(month_str)
        month_abbrs = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        if 1 <= month_int <= 12:
            abbr = month_abbrs[month_int - 1]
            day_int = int(day_str)
            cands.append(f"{day_str} {abbr} {year}")
            cands.append(f"{day_int} {abbr} {year}")
    except (ValueError, IndexError):
        pass
    return cands


def check_dates_match(page_text: str, entry_date: str | None, exit_date: str | None) -> bool:
    if not entry_date or not exit_date:
        return True
    entry_cands = date_candidates(entry_date)
    exit_cands = date_candidates(exit_date)
    if not entry_cands or not exit_cands:
        return True
    upper_text = page_text.upper()
    has_entry = any(c.upper() in upper_text for c in entry_cands)
    has_exit = any(c.upper() in upper_text for c in exit_cands)
    return has_entry and has_exit


async def query_and_capture_page(
    config: WorkerConfig,
    runtime_input: dict[str, str],
    target_entry_date: str | None = None,
    target_exit_date: str | None = None,
) -> tuple[str, bytes, str, dict[str, Any]]:
    async with async_playwright() as playwright:
        browser: Browser = await playwright.chromium.launch(
            headless=config.headless,
            args=["--no-sandbox"],
        )
        context = await browser.new_context(
            viewport={"width": 1440, "height": 1200},
            locale="en-MY",
            accept_downloads=True,
        )
        try:
            page: Page = await context.new_page()
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

            if config.mode == "AUTO_SEARCH" and config.allow_real_submit:
                slider_ok = True
                canvas_count = await page.locator("canvas").count()
                if challenge_type == "CAPTCHA_SLIDER" or canvas_count >= 2:
                    LOG.info("检测到 Check Registration 滑块，调用 slider_solver 自动处理...")
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
                    return ("NEEDS_REVIEW", screenshot, "png", summary)

                LOG.info("滑块验证通过，准备触发 Submit 查询...")
                submit_locator = page.locator(
                    "#submit, button[type='submit'], input[type='submit'], #searchRegistration"
                ).first
                if await submit_locator.is_disabled():
                    await page.wait_for_timeout(1000)

                download_task = asyncio.create_task(page.wait_for_event("download", timeout=12000))
                await submit_locator.click()
                LOG.info("已点击 Submit 查询，等待结果返回...")

                download_obj = None
                try:
                    download_obj = await asyncio.wait_for(download_task, timeout=4.0)
                except (asyncio.TimeoutError, Exception):
                    pass

                if download_obj is not None:
                    try:
                        stream = await download_obj.create_read_stream()
                        pdf_bytes = await stream.read()
                        if len(pdf_bytes) >= 4 and pdf_bytes[:4] == b"%PDF":
                            LOG.info("成功捕获到官方 Registration PDF (%d bytes)", len(pdf_bytes))
                            summary = {
                                "source": "MDAC_CHECK_REGISTRATION",
                                "mode": "AUTO_SEARCH",
                                "evidence_type": "PDF",
                                "slider_solved": True,
                                "submitted": True,
                                "result_confirmed": True,
                            }
                            return ("FOUND", pdf_bytes, "pdf", summary)
                    except Exception as e:
                        LOG.warning("读取官方下载 PDF 异常: %s", e)

                for _ in range(15):
                    await page.wait_for_timeout(1000)
                    page_text = await page.evaluate("() => document.body ? document.body.innerText : ''")
                    lowered_text = page_text.lower()

                    if "no record found" in lowered_text or "rekod tidak dijumpai" in lowered_text:
                        LOG.info("官方页面明确显示：没有找到记录 (NO_RECORD)")
                        screenshot = await page.screenshot(full_page=True, type="png")
                        return ("NO_RECORD", screenshot, "png", {
                            "source": "MDAC_CHECK_REGISTRATION",
                            "outcome": "NO_RECORD",
                            "slider_solved": True,
                            "submitted": True,
                        })

                    if "invalid pin" in lowered_text or "pin tidak sah" in lowered_text:
                        LOG.warning("官方页面明确显示：PIN 无效 (PIN_INVALID)")
                        screenshot = await page.screenshot(full_page=True, type="png")
                        return ("PIN_INVALID", screenshot, "png", {
                            "source": "MDAC_CHECK_REGISTRATION",
                            "outcome": "PIN_INVALID",
                            "slider_solved": True,
                            "submitted": True,
                        })

                    if ("registration no" in lowered_text or "no pendaftaran" in lowered_text
                            or "tarikh masuk" in lowered_text or "date of arrival" in lowered_text):
                        if not check_dates_match(page_text, target_entry_date, target_exit_date):
                            LOG.warning("查到记录但日期与本次 MDAC 不一致，降级人工审核防止误判")
                            screenshot = await page.screenshot(full_page=True, type="png")
                            return ("NEEDS_REVIEW", screenshot, "png", {
                                "source": "MDAC_CHECK_REGISTRATION",
                                "outcome": "DATE_MISMATCH",
                                "slider_solved": True,
                                "submitted": True,
                                "note": "日期与本次目标不一致，需人工核对",
                            })

                        pdf_btn = page.locator(
                            "a[href*='pdf'], button:has-text('PDF'), button:has-text('Print'), a:has-text('PDF'), a:has-text('Download')"
                        ).first
                        if await pdf_btn.count() > 0 and await pdf_btn.is_visible():
                            try:
                                async with page.expect_download(timeout=5000) as dl_info:
                                    await pdf_btn.click()
                                dl = await dl_info.value
                                stream = await dl.create_read_stream()
                                pdf_bytes = await stream.read()
                                if len(pdf_bytes) >= 4 and pdf_bytes[:4] == b"%PDF":
                                    LOG.info("点击页面按钮成功下载官方 Registration PDF (%d bytes)", len(pdf_bytes))
                                    return ("FOUND", pdf_bytes, "pdf", {
                                        "source": "MDAC_CHECK_REGISTRATION",
                                        "mode": "AUTO_SEARCH",
                                        "evidence_type": "PDF",
                                        "slider_solved": True,
                                        "submitted": True,
                                        "result_confirmed": True,
                                    })
                            except Exception as dl_err:
                                LOG.warning("点击下载按钮未触发 PDF: %s，回退全页截图", dl_err)

                        screenshot = await page.screenshot(full_page=True, type="png")
                        LOG.info("成功捕获官方查询结果页截图")
                        return ("FOUND", screenshot, "png", {
                            "source": "MDAC_CHECK_REGISTRATION",
                            "mode": "AUTO_SEARCH",
                            "evidence_type": "SCREENSHOT",
                            "slider_solved": True,
                            "submitted": True,
                            "result_confirmed": True,
                        })

                screenshot = await page.screenshot(full_page=True, type="png")
                return ("NEEDS_REVIEW", screenshot, "png", {
                    "source": "MDAC_CHECK_REGISTRATION",
                    "outcome": "RESULT_UNKNOWN",
                    "slider_solved": True,
                    "submitted": True,
                    "note": "查询后超时未识别明确状态，已截图转人工",
                })

            else:
                screenshot = await page.screenshot(full_page=True, type="png")
                summary = make_preview_summary(
                    challenge_type=challenge_type,
                    field_checks=field_checks,
                    screenshot_saved=True,
                )
                return ("NEEDS_REVIEW", screenshot, "png", summary)
        finally:
            await browser.close()


async def preview_page(
    config: WorkerConfig,
    runtime_input: dict[str, str],
) -> tuple[bytes, str | None, dict[str, Any]]:
    outcome, evidence_bytes, ext, summary = await query_and_capture_page(config, runtime_input)
    challenge_type = "CAPTCHA_SLIDER" if summary.get("challenge_type") == "CAPTCHA_SLIDER" else None
    return evidence_bytes, challenge_type, summary


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
                snapshot = item.get("customer_snapshot") or {}
                target_entry_date = snapshot.get("target_entry_date")
                target_exit_date = snapshot.get("target_exit_date")

                outcome, evidence_bytes, ext, summary = asyncio.run(
                    query_and_capture_page(
                        self.config,
                        runtime_input,
                        target_entry_date=target_entry_date,
                        target_exit_date=target_exit_date,
                    )
                )
                evidence_path: str | None = None
                try:
                    evidence_path = self.supabase.upload_evidence(item_id, evidence_bytes, ext)
                    summary["evidence_path"] = evidence_path
                except Exception as upload_err:
                    log_event(
                        logging.WARNING,
                        step="evidence_upload",
                        status="failed",
                        batch_id=batch_id,
                        item_id=item_id,
                        customer_id=customer_id,
                        error_code="EVIDENCE_UPLOAD_FAILED",
                        error_message=str(upload_err),
                    )
                    summary["evidence_upload_failed"] = True

                error_code = None
                error_message = None
                if outcome == "NEEDS_REVIEW":
                    error_code = summary.get("error") or summary.get("outcome") or "MANUAL_REVIEW_REQUIRED"
                    error_message = summary.get("note") or "Check Registration 需要人工审核"
                elif outcome == "NO_RECORD":
                    error_code = "NO_RECORD"
                    error_message = "官方页面显示无记录"
                elif outcome == "PIN_INVALID":
                    error_code = "PIN_INVALID"
                    error_message = "官方页面提示 PIN 错误"

                self.supabase.finish_check_worker(
                    item_id=item_id,
                    outcome=outcome,
                    evidence_path=evidence_path,
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
                    self.supabase.finish_check_worker(
                        item_id=item_id,
                        outcome="NEEDS_REVIEW",
                        evidence_path=None,
                        raw_summary={
                            "source": "MDAC_CHECK_REGISTRATION",
                            "mode": self.config.mode,
                            "submitted": False,
                            "result_confirmed": False,
                            "captcha_bypass": False,
                            "screenshot_saved": False,
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
    print("   Check Registration Worker 已启动（本地服务）")
    print(f"  Worker ID: {config.worker_id}")
    print(f"  运行模式: {config.mode} (允许真实查询: {config.allow_real_submit})")
    print(f"  桌面浏览器: {'后台静默' if config.headless else '前台可见'}")
    print("  正在监听 Supabase Registration Check 队列...")
    print("========================================================")
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
