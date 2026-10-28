"""Check Registration Worker.

High-concurrency MDAC registration-check worker service.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import json
import logging
import os
import re
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from playwright.async_api import Browser, Page, async_playwright
import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
LOG = logging.getLogger("registration_check_worker")


def get_current_epoch_seconds() -> int:
    return int(time.time())


@dataclass(frozen=True)
class WorkerConfig:
    supabase_url: str
    service_role_key: str
    poll_interval_seconds: float
    lease_duration_seconds: int
    page_timeout_ms: int
    worker_id: str
    check_url: str
    allow_real_submit: bool
    strict_lease_renewal_seconds: int
    batch_mode: bool
    queue_name: str
    headless: bool

    @classmethod
    def from_env(cls) -> WorkerConfig:
        url = os.getenv("SUPABASE_URL", "").strip().rstrip("/")
        key = (
            os.getenv("SUPABASE_SERVICE_ROLE_KEY", "")
            or os.getenv("SUPABASE_KEY", "")
        ).strip()
        if not url or not key:
            raise ValueError(
                "Missing required SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY"
            )

        allow_real = (
            os.getenv("REGISTRATION_CHECK_ALLOW_REAL_SUBMIT", "false")
            .strip()
            .lower()
            == "true"
        )
        headless = os.getenv("REGISTRATION_CHECK_HEADLESS", "true").strip().lower() == "true"

        return cls(
            supabase_url=url,
            service_role_key=key,
            poll_interval_seconds=float(
                os.getenv("REGISTRATION_CHECK_POLL_INTERVAL", "5.0")
            ),
            lease_duration_seconds=int(
                os.getenv("REGISTRATION_CHECK_LEASE_DURATION", "60")
            ),
            page_timeout_ms=int(
                os.getenv("REGISTRATION_CHECK_TIMEOUT_MS", "30000")
            ),
            worker_id=os.getenv(
                "REGISTRATION_CHECK_WORKER_ID",
                f"reg-chk-{os.getpid()}-{int(time.time())}",
            ),
            check_url=os.getenv(
                "REGISTRATION_CHECK_URL",
                "https://imigresen-online.imi.gov.my/mdac/main?checkReg",
            ),
            allow_real_submit=allow_real,
            strict_lease_renewal_seconds=int(
                os.getenv("STRICT_LEASE_RENEWAL_SECONDS", "15")
            ),
            batch_mode=os.getenv("REGISTRATION_CHECK_BATCH_MODE", "true")
            .strip()
            .lower()
            == "true",
            queue_name=os.getenv("REGISTRATION_CHECK_QUEUE", "registration_check"),
            headless=headless,
        )


def _supabase_headers(config: WorkerConfig) -> dict[str, str]:
    return {
        "apikey": config.service_role_key,
        "Authorization": f"Bearer {config.service_role_key}",
        "Content-Type": "application/json",
        "Prefer": "return=representation",
    }


def claim_next_batch(config: WorkerConfig) -> dict[str, Any] | None:
    url = f"{config.supabase_url}/rest/v1/rpc/claim_next_operational_batch"
    headers = _supabase_headers(config)
    payload = {
        "p_worker_id": config.worker_id,
        "p_queue_name": config.queue_name,
        "p_lease_duration_seconds": config.lease_duration_seconds,
    }
    resp = requests.post(url, headers=headers, json=payload, timeout=10)
    if resp.status_code != 200:
        LOG.error("claim_next_batch RPC error: %d %s", resp.status_code, resp.text)
        return None
    data = resp.json()
    if not data or not isinstance(data, list) or len(data) == 0:
        return None
    return data[0]


def claim_next_item(config: WorkerConfig) -> dict[str, Any] | None:
    url = f"{config.supabase_url}/rest/v1/rpc/claim_next_queue_item"
    headers = _supabase_headers(config)
    payload = {
        "p_worker_id": config.worker_id,
        "p_queue_name": config.queue_name,
        "p_lease_duration_seconds": config.lease_duration_seconds,
    }
    resp = requests.post(url, headers=headers, json=payload, timeout=10)
    if resp.status_code != 200:
        LOG.error("claim_next_item RPC error: %d %s", resp.status_code, resp.text)
        return None
    data = resp.json()
    if not data or not isinstance(data, list) or len(data) == 0:
        return None
    return data[0]


def renew_batch_lease(config: WorkerConfig, batch_id: str) -> bool:
    url = f"{config.supabase_url}/rest/v1/rpc/renew_operational_batch_lease"
    headers = _supabase_headers(config)
    payload = {
        "p_worker_id": config.worker_id,
        "p_batch_id": batch_id,
        "p_lease_duration_seconds": config.lease_duration_seconds,
    }
    resp = requests.post(url, headers=headers, json=payload, timeout=10)
    return resp.status_code == 200 and resp.json() is True


def renew_item_lease(config: WorkerConfig, item_id: str) -> bool:
    url = f"{config.supabase_url}/rest/v1/rpc/renew_queue_item_lease"
    headers = _supabase_headers(config)
    payload = {
        "p_worker_id": config.worker_id,
        "p_item_id": item_id,
        "p_lease_duration_seconds": config.lease_duration_seconds,
    }
    resp = requests.post(url, headers=headers, json=payload, timeout=10)
    return resp.status_code == 200 and resp.json() is True


def record_batch_result(
    config: WorkerConfig,
    batch_id: str,
    status: str,
    result_summary: dict[str, Any],
    error_code: str | None = None,
    error_message: str | None = None,
) -> bool:
    url = f"{config.supabase_url}/rest/v1/rpc/record_operational_batch_result"
    headers = _supabase_headers(config)
    payload = {
        "p_worker_id": config.worker_id,
        "p_batch_id": batch_id,
        "p_status": status,
        "p_result_summary": result_summary,
        "p_error_code": error_code,
        "p_error_message": error_message,
    }
    resp = requests.post(url, headers=headers, json=payload, timeout=10)
    return resp.status_code == 200 and resp.json() is True


def record_item_result(
    config: WorkerConfig,
    item_id: str,
    status: str,
    result_summary: dict[str, Any],
    error_code: str | None = None,
    error_message: str | None = None,
) -> bool:
    url = f"{config.supabase_url}/rest/v1/rpc/record_queue_item_result"
    headers = _supabase_headers(config)
    payload = {
        "p_worker_id": config.worker_id,
        "p_item_id": item_id,
        "p_status": status,
        "p_result_summary": result_summary,
        "p_error_code": error_code,
        "p_error_message": error_message,
    }
    resp = requests.post(url, headers=headers, json=payload, timeout=10)
    return resp.status_code == 200 and resp.json() is True


def get_case_record(config: WorkerConfig, case_id: str) -> dict[str, Any] | None:
    url = f"{config.supabase_url}/rest/v1/cases?id=eq.{case_id}&select=*"
    headers = _supabase_headers(config)
    resp = requests.get(url, headers=headers, timeout=10)
    if resp.status_code == 200 and resp.json():
        return resp.json()[0]
    return None


def get_case_registration_inputs(config: WorkerConfig, case_id: str) -> dict[str, str]:
    case_rec = get_case_record(config, case_id)
    if not case_rec:
        raise ValueError(f"Case {case_id} not found")

    reg_inputs = case_rec.get("registration_check_inputs") or {}
    if not isinstance(reg_inputs, dict):
        reg_inputs = {}

    pass_no = (
        reg_inputs.get("passNo")
        or reg_inputs.get("passport_number")
        or case_rec.get("passport_number")
        or ""
    ).strip().upper()
    nationality = (
        reg_inputs.get("nationality")
        or reg_inputs.get("country_code")
        or case_rec.get("nationality")
        or ""
    ).strip().upper()
    pin = (
        reg_inputs.get("pinKeyId")
        or reg_inputs.get("pin")
        or case_rec.get("mdac_pin")
        or ""
    ).strip()

    entry_date = (
        reg_inputs.get("target_entry_date")
        or case_rec.get("target_entry_date")
        or case_rec.get("entry_date")
        or ""
    ).strip()
    exit_date = (
        reg_inputs.get("target_exit_date")
        or case_rec.get("target_exit_date")
        or case_rec.get("exit_date")
        or ""
    ).strip()

    missing = []
    if not pass_no:
        missing.append("passNo / passport_number")
    if not nationality:
        missing.append("nationality")
    if not pin:
        missing.append("pinKeyId / pin")

    if missing:
        raise ValueError(f"Missing required check inputs: {', '.join(missing)}")

    return {
        "passNo": pass_no,
        "nationality": nationality,
        "pinKeyId": pin,
        "target_entry_date": entry_date,
        "target_exit_date": exit_date,
    }


def upload_storage_artifact(
    config: WorkerConfig,
    case_id: str,
    artifact_bytes: bytes,
    file_extension: str = "pdf",
    content_type: str = "application/pdf",
) -> str:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    filename = f"reg_check_{timestamp}_{config.worker_id}.{file_extension}"
    storage_path = f"{case_id}/{filename}"
    url = f"{config.supabase_url}/storage/v1/object/case-artifacts/{storage_path}"

    headers = {
        "apikey": config.service_role_key,
        "Authorization": f"Bearer {config.service_role_key}",
        "Content-Type": content_type,
    }
    resp = requests.post(url, headers=headers, data=artifact_bytes, timeout=15)
    if resp.status_code not in (200, 201):
        LOG.error("Failed to upload storage artifact: %d %s", resp.status_code, resp.text)
        raise RuntimeError(f"Storage upload failed with code {resp.status_code}")
    return storage_path


def update_case_registration_status(
    config: WorkerConfig,
    case_id: str,
    status_value: str,
    artifact_path: str | None,
    registration_number: str | None,
    details: dict[str, Any],
) -> bool:
    url = f"{config.supabase_url}/rest/v1/cases?id=eq.{case_id}"
    headers = _supabase_headers(config)

    now_iso = datetime.now(timezone.utc).isoformat()
    payload: dict[str, Any] = {
        "registration_check_status": status_value,
        "registration_check_last_at": now_iso,
        "registration_check_details": details,
        "updated_at": now_iso,
    }
    if artifact_path:
        payload["registration_check_artifact_path"] = artifact_path
    if registration_number:
        payload["registration_number"] = registration_number

    resp = requests.patch(url, headers=headers, json=payload, timeout=10)
    return resp.status_code in (200, 204)


async def check_registration_page(
    config: WorkerConfig,
    runtime_input: dict[str, str],
    target_entry_date: str | None = None,
    target_exit_date: str | None = None,
) -> tuple[str, bytes, str, dict[str, Any]]:
    async with async_playwright() as playwright:
        browser_args = [
            "--no-sandbox",
            "--disable-blink-features=AutomationControlled",
        ]
        if not config.headless:
            window_size = os.getenv("BROWSER_WINDOW_SIZE", "840,820")
            window_pos = os.getenv("BROWSER_WINDOW_POSITION", "665,20")
            browser_args.extend([
                f"--window-size={window_size}",
                f"--window-position={window_pos}",
            ])
        browser: Browser = await playwright.chromium.launch(
            headless=config.headless,
            args=browser_args,
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

            await page.fill("#passNo", runtime_input["passNo"])
            await page.select_option("#nationality", runtime_input["nationality"])
            await page.fill("#pinKeyId", runtime_input["pinKeyId"])

            if not config.allow_real_submit:
                LOG.info("Dry-run check (allow_real_submit=False), returning synthetic preview.")
                screenshot_bytes = await page.screenshot(full_page=True)
                return (
                    "PREVIEW_OK",
                    screenshot_bytes,
                    "MOCK-REG-12345",
                    {"dry_run": True, "mode": "preview"},
                )

            submit_btn = await page.query_selector("button:has-text('Submit'), input[type='submit']")
            if not submit_btn:
                raise RuntimeError("Could not find submit button on checkReg page")

            async with page.expect_download(timeout=config.page_timeout_ms) as download_info:
                await submit_btn.click()
                download = await download_info.value

            pdf_path = await download.path()
            if not pdf_path:
                raise RuntimeError("Downloaded file path was null")
            pdf_bytes = Path(pdf_path).read_bytes()

            text_content = await page.content()
            reg_match = re.search(r"MDAC\d{8,}", text_content)
            extracted_reg = reg_match.group(0) if reg_match else ""

            return (
                "SUCCESS",
                pdf_bytes,
                extracted_reg,
                {"download_suggested_filename": download.suggested_filename},
            )

        finally:
            await context.close()
            await browser.close()


def process_case(config: WorkerConfig, case_id: str) -> dict[str, Any]:
    inputs = get_case_registration_inputs(config, case_id)
    result_status, artifact_bytes, reg_no, details = asyncio.run(
        check_registration_page(
            config,
            inputs,
            inputs.get("target_entry_date"),
            inputs.get("target_exit_date"),
        )
    )

    artifact_path = None
    if artifact_bytes:
        ext = "pdf" if result_status == "SUCCESS" else "png"
        ctype = "application/pdf" if ext == "pdf" else "image/png"
        artifact_path = upload_storage_artifact(config, case_id, artifact_bytes, ext, ctype)

    status_val = "verified" if result_status == "SUCCESS" else "preview_captured"
    update_case_registration_status(
        config,
        case_id,
        status_val,
        artifact_path,
        reg_no or None,
        details,
    )

    return {
        "status": status_val,
        "registration_number": reg_no,
        "artifact_path": artifact_path,
        "details": details,
    }


def run_worker_loop(config: WorkerConfig) -> None:
    LOG.info("Starting Registration Check Worker: %s", config.worker_id)
    LOG.info("  Queue: %s | Batch Mode: %s", config.queue_name, config.batch_mode)
    LOG.info("  Mode: %s", "Dry-Run Preview" if not config.allow_real_submit else "Production Live Submit")
    LOG.info("  UI: %s", "Headless Silent" if config.headless else "Headed Visual Monitor")

    while True:
        try:
            if config.batch_mode:
                batch = claim_next_batch(config)
                if not batch:
                    time.sleep(config.poll_interval_seconds)
                    continue

                batch_id = batch["batch_id"]
                case_id = batch.get("case_id")
                LOG.info("Claimed batch %s for case %s", batch_id, case_id)

                if not case_id:
                    record_batch_result(
                        config,
                        batch_id,
                        "failed",
                        {},
                        "MISSING_CASE_ID",
                        "Batch has no associated case_id",
                    )
                    continue

                try:
                    summary = process_case(config, case_id)
                    record_batch_result(config, batch_id, "succeeded", summary)
                    LOG.info("Completed batch %s successfully", batch_id)
                except Exception as exc:
                    LOG.exception("Error processing batch %s: %s", batch_id, exc)
                    record_batch_result(
                        config,
                        batch_id,
                        "failed",
                        {},
                        "PROCESS_ERROR",
                        str(exc),
                    )

            else:
                item = claim_next_item(config)
                if not item:
                    time.sleep(config.poll_interval_seconds)
                    continue

                item_id = item["item_id"]
                case_id = item.get("case_id")
                LOG.info("Claimed item %s for case %s", item_id, case_id)

                if not case_id:
                    record_item_result(
                        config,
                        item_id,
                        "failed",
                        {},
                        "MISSING_CASE_ID",
                        "Item has no associated case_id",
                    )
                    continue

                try:
                    summary = process_case(config, case_id)
                    record_item_result(config, item_id, "succeeded", summary)
                    LOG.info("Completed item %s successfully", item_id)
                except Exception as exc:
                    LOG.exception("Error processing item %s: %s", item_id, exc)
                    record_item_result(
                        config,
                        item_id,
                        "failed",
                        {},
                        "PROCESS_ERROR",
                        str(exc),
                    )

        except Exception as e:
            LOG.exception("Unexpected error in worker loop: %s", e)
            time.sleep(config.poll_interval_seconds)


def main() -> None:
    parser = argparse.ArgumentParser(description="Registration Check Worker")
    parser.add_argument("--poll", action="store_true", help="Run in continuous polling loop")
    args = parser.parse_args()

    config = WorkerConfig.from_env()

    if args.poll:
        run_worker_loop(config)
    else:
        LOG.info("Single execution mode not configured, use --poll")


if __name__ == "__main__":
    main()
