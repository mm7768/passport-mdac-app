"""Controlled MDAC fill-preview Worker.

This service is intentionally fill-only. It may open the official public MDAC
registration form, fill and verify fields, and save a private screenshot. It
must never submit the form, bypass CAPTCHA/slider challenges, or report a
successful government registration.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import socket
from dataclasses import dataclass
from datetime import date, datetime
from typing import Any, Awaitable, Callable

import requests
from playwright.async_api import Browser, BrowserContext, Page, TimeoutError as PlaywrightTimeoutError, async_playwright

LOG = logging.getLogger("mdac_fill_preview")
WORKER_VERSION = "mdac-fill-preview-2"
MDAC_URL = "https://imigresen-online.imi.gov.my/mdac/main?registerMain"


class WorkerError(RuntimeError):
    """Expected worker or remote-service failure."""


class ManualReviewRequired(WorkerError):
    """A human must intervene; the worker must not guess or bypass a challenge."""


@dataclass(frozen=True)
class WorkerConfig:
    supabase_url: str
    service_role_key: str
    worker_id: str
    execution_mode: str
    allow_real_submit: bool
    mdac_url: str
    poll_seconds: float
    lease_seconds: int
    max_attempts: int
    request_timeout_seconds: float
    page_timeout_ms: int
    screenshot_bucket: str
    screenshot_prefix: str
    headless: bool
    log_level: str

    @classmethod
    def from_env(cls) -> "WorkerConfig":
        def required(name: str) -> str:
            value = os.getenv(name, "").strip()
            if not value:
                raise WorkerError(f"缺少环境变量：{name}")
            return value

        def positive_float(name: str, default: str, minimum: float) -> float:
            value = float(os.getenv(name, default))
            if value < minimum:
                raise WorkerError(f"{name} 必须大于或等于 {minimum}")
            return value

        def bounded_int(name: str, default: str, lower: int, upper: int) -> int:
            value = int(os.getenv(name, default))
            if value < lower or value > upper:
                raise WorkerError(f"{name} 必须在 {lower} 到 {upper} 之间")
            return value

        execution_mode = os.getenv("MDAC_EXECUTION_MODE", "").strip().upper()
        if execution_mode != "FILL_PREVIEW":
            raise WorkerError("MDAC_EXECUTION_MODE 必须严格为 FILL_PREVIEW")

        allow_submit = os.getenv("ALLOW_REAL_SUBMIT", "").strip().lower()
        if allow_submit != "false":
            raise WorkerError("ALLOW_REAL_SUBMIT 必须严格为 false；本服务禁止真实提交")

        return cls(
            supabase_url=required("SUPABASE_URL").rstrip("/"),
            service_role_key=required("SUPABASE_SERVICE_ROLE_KEY"),
            worker_id=required("MDAC_WORKER_ID"),
            execution_mode=execution_mode,
            allow_real_submit=False,
            mdac_url=os.getenv("MDAC_URL", MDAC_URL).strip() or MDAC_URL,
            poll_seconds=positive_float("MDAC_POLL_SECONDS", "15", 5.0),
            lease_seconds=bounded_int("MDAC_LEASE_SECONDS", "900", 60, 3600),
            max_attempts=bounded_int("MDAC_MAX_ATTEMPTS", "5", 1, 20),
            request_timeout_seconds=positive_float("SUPABASE_REQUEST_TIMEOUT_SECONDS", "30", 5.0),
            page_timeout_ms=bounded_int("MDAC_PAGE_TIMEOUT_MS", "60000", 10000, 180000),
            screenshot_bucket=os.getenv("MDAC_SCREENSHOT_BUCKET", "passport-documents").strip() or "passport-documents",
            screenshot_prefix=os.getenv("MDAC_SCREENSHOT_PREFIX", "mdac-previews").strip("/ ") or "mdac-previews",
            headless=os.getenv("MDAC_HEADLESS", "true").strip().lower() == "true",
            log_level=os.getenv("LOG_LEVEL", "INFO").strip().upper(),
        )


class SupabaseAdminClient:
    def __init__(self, config: WorkerConfig) -> None:
        self.config = config
        self.rest_url = f"{config.supabase_url}/rest/v1"
        self.storage_url = f"{config.supabase_url}/storage/v1"
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
            "claim_mdac_batch",
            {
                "p_worker_id": self.config.worker_id,
                "p_lease_seconds": self.config.lease_seconds,
                "p_max_attempts": self.config.max_attempts,
            },
        )
        if not rows:
            return None
        if not isinstance(rows, list):
            raise WorkerError("claim_mdac_batch 返回格式不正确")
        return dict(rows[0]) if rows else None

    def claim_item(self, batch_id: str) -> dict[str, Any] | None:
        rows = self._rpc(
            "claim_mdac_item",
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
            raise WorkerError("claim_mdac_item 返回格式不正确")
        return dict(rows[0]) if rows else None

    def heartbeat(
        self,
        *,
        status: str,
        batch_id: str | None = None,
        item_id: str | None = None,
    ) -> None:
        self._rpc(
            "heartbeat_mdac",
            {
                "p_worker_id": self.config.worker_id,
                "p_batch_id": batch_id,
                "p_item_id": item_id,
                "p_lease_seconds": self.config.lease_seconds,
                "p_status": status,
                "p_hostname": socket.gethostname(),
                "p_version": WORKER_VERSION,
            },
        )

    def upload_screenshot(self, path: str, content: bytes) -> str:
        object_path = path.strip("/")
        response = self.session.post(
            f"{self.storage_url}/object/{self.config.screenshot_bucket}/{object_path}",
            headers={
                "Content-Type": "image/png",
                "Cache-Control": "private, max-age=0, no-store",
                "x-upsert": "true",
            },
            data=content,
            timeout=self.config.request_timeout_seconds,
        )
        self._check(response, "上传 MDAC 预览截图")
        return object_path

    def finish_fill_preview(
        self,
        *,
        item_id: str,
        screenshot_path: str | None,
        raw_summary: dict[str, Any],
        error_code: str | None,
        error_message: str | None,
    ) -> dict[str, Any]:
        result = self._rpc(
            "finish_mdac_fill_preview",
            {
                "p_item_id": item_id,
                "p_worker_id": self.config.worker_id,
                "p_screenshot_path": screenshot_path,
                "p_raw_summary": raw_summary,
                "p_error_code": error_code,
                "p_error_message": error_message,
            },
        )
        if not isinstance(result, dict):
            raise WorkerError("finish_mdac_fill_preview 返回格式不正确")
        return result


def parse_date(value: Any) -> date:
    text = str(value or "").strip()
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%Y/%m/%d"):
        try:
            return datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    raise ValueError(f"无法识别日期：{text}")


def format_mdac_date(value: Any) -> str:
    return parse_date(value).strftime("%d/%m/%Y")


def map_gender(value: Any) -> str:
    normalized = str(value or "").strip().upper()
    if normalized in {"男", "MALE", "1"}:
        return "1"
    if normalized in {"女", "FEMALE", "2"}:
        return "2"
    raise ValueError(f"未知性别：{value}")


def _required_snapshot(snapshot: dict[str, Any], key: str) -> str:
    value = str(snapshot.get(key) or "").strip()
    if not value:
        raise ValueError(f"缺少必填字段：{key}")
    return value


def normalize_mdac_settings(raw: Any) -> dict[str, str]:
    if not isinstance(raw, dict):
        raise WorkerError("批次缺少 mdac_settings_snapshot")

    def value(key: str, *, required: bool = True) -> str:
        text = str(raw.get(key) or "").strip()
        if required and not text:
            raise WorkerError(f"MDAC 设置快照缺少必填字段：{key}")
        return text

    email = value("mdac_email")
    if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email):
        raise WorkerError("MDAC 设置快照的邮箱格式不正确")
    phone = value("mdac_phone")
    region_code = value("region_code")
    if region_code != "60":
        raise WorkerError("MDAC 设置快照的地区代码必须是 60")
    travel_mode = value("travel_mode")
    if travel_mode not in {"1", "2", "3"}:
        raise WorkerError("MDAC 设置快照的交通方式无效")
    embark_country = value("embark_country").upper()
    if not re.fullmatch(r"[A-Z]{3}", embark_country):
        raise WorkerError("MDAC 设置快照的出发国家代码无效")
    vessel = value("vessel")
    accommodation_stay = value("accommodation_stay")
    if accommodation_stay not in {"01", "02", "99"}:
        raise WorkerError("MDAC 设置快照的住宿类型无效")
    address1 = value("address1")
    address2 = value("address2", required=False)
    state_code = value("state_code")
    city_code = value("city_code")
    postcode = value("postcode")
    if not re.fullmatch(r"[0-9]{2}", state_code):
        raise WorkerError("MDAC 设置快照的州代码无效")
    if not re.fullmatch(r"[0-9]{4}", city_code):
        raise WorkerError("MDAC 设置快照的城市代码无效")
    if not re.fullmatch(r"[0-9]{5}", postcode):
        raise WorkerError("MDAC 设置快照的邮编无效")
    pob_mode = value("pob_mode").upper()
    if pob_mode not in {"NATIONALITY", "CUSTOMER"}:
        raise WorkerError("MDAC 设置快照的 POB 映射无效")

    return {
        "mdac_email": email,
        "mdac_phone": phone,
        "region_code": region_code,
        "travel_mode": travel_mode,
        "embark_country": embark_country,
        "vessel": vessel,
        "accommodation_stay": accommodation_stay,
        "address1": address1,
        "address2": address2,
        "state_code": state_code,
        "city_code": city_code,
        "postcode": postcode,
        "pob_mode": pob_mode,
    }


def map_mdac_fields(
    snapshot: dict[str, Any],
    batch: dict[str, Any],
    settings: dict[str, str],
) -> dict[str, str]:
    full_name = _required_snapshot(snapshot, "full_name")
    passport_number = _required_snapshot(snapshot, "passport_number")
    nationality = _required_snapshot(snapshot, "nationality").upper()
    place_of_birth = str(snapshot.get("place_of_birth") or "").strip().upper()
    pob = nationality if settings["pob_mode"] == "NATIONALITY" else place_of_birth
    if not pob:
        raise ValueError("POB 映射为 CUSTOMER 时缺少 place_of_birth")

    date_of_birth = _required_snapshot(snapshot, "date_of_birth")
    passport_expiry_date = _required_snapshot(snapshot, "passport_expiry_date")
    entry_date = str(snapshot.get("entry_date") or batch.get("entry_date") or "").strip()
    exit_date = str(snapshot.get("exit_date") or batch.get("exit_date") or "").strip()
    if not entry_date or not exit_date:
        raise ValueError("缺少入境或出境日期")

    entry = parse_date(entry_date)
    exit_date_value = parse_date(exit_date)
    if exit_date_value < entry:
        raise ValueError("出境日期不能早于入境日期")

    return {
        "#region": settings["region_code"],
        "#nationality": nationality,
        "#pob": pob,
        "#sex": map_gender(snapshot.get("gender")),
        "#name": full_name,
        "#passNo": passport_number.upper(),
        "#dob": format_mdac_date(date_of_birth),
        "#passExpDte": format_mdac_date(passport_expiry_date),
        "#arrDt": entry.strftime("%d/%m/%Y"),
        "#depDt": exit_date_value.strftime("%d/%m/%Y"),
    }


def mask_passport(value: str) -> str:
    value = value.strip()
    if len(value) <= 4:
        return "••••"
    return f"{value[:2]}••••{value[-2:]}"


def _safe_text(value: Any, limit: int = 180) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())[:limit]


async def _set_readonly_date(locator: Any, value: str) -> None:
    await locator.evaluate(
        """(element, nextValue) => {
            element.value = nextValue;
            element.dispatchEvent(new Event('input', { bubbles: true }));
            element.dispatchEvent(new Event('change', { bubbles: true }));
        }""",
        value,
    )


async def _wait_for_option(locator: Any, option_value: str, timeout_ms: int) -> None:
    await locator.wait_for(state="visible", timeout=timeout_ms)
    await locator.page.wait_for_function(
        """({selector, value}) => {
            const element = document.querySelector(selector);
            return Boolean(element && Array.from(element.options).some(option => option.value === value));
        }""",
        {"selector": await locator.get_attribute("id") and f"#{await locator.get_attribute('id')}", "value": option_value},
        timeout=timeout_ms,
    )


async def _select_value(page: Page, selector: str, value: str, timeout_ms: int) -> None:
    locator = page.locator(selector)
    await locator.wait_for(state="visible", timeout=timeout_ms)
    element_id = await locator.get_attribute("id")
    if not element_id:
        raise WorkerError(f"下拉控件缺少 id：{selector}")
    await page.wait_for_function(
        """({selector, value}) => {
            const element = document.querySelector(selector);
            return Boolean(element && Array.from(element.options).some(option => option.value === value));
        }""",
        {"selector": f"#{element_id}", "value": value},
        timeout=timeout_ms,
    )
    await locator.select_option(value=value)


async def _input_value(page: Page, selector: str) -> str:
    return (await page.locator(selector).input_value()).strip()


async def fill_and_verify_page(
    page: Page,
    fields: dict[str, str],
    config: WorkerConfig,
    settings: dict[str, str],
) -> dict[str, Any]:
    timeout_ms = config.page_timeout_ms
    await page.goto(config.mdac_url, wait_until="domcontentloaded", timeout=timeout_ms)
    await page.set_default_timeout(timeout_ms)
    await page.locator("#name").wait_for(state="visible", timeout=timeout_ms)

    password_count = await page.locator('input[type="password"]').count()
    if password_count:
        raise ManualReviewRequired("页面要求账号登录；当前服务不自动处理登录或验证码")

    await _select_value(page, "#region", fields["#region"], timeout_ms)
    await _select_value(page, "#nationality", fields["#nationality"], timeout_ms)
    await page.wait_for_timeout(500)
    await _select_value(page, "#pob", fields["#pob"], timeout_ms)

    await page.locator("#email").fill(settings["mdac_email"])
    await page.locator("#confirmEmail").fill(settings["mdac_email"])
    await page.locator("#mobile").fill(settings["mdac_phone"])
    await _select_value(page, "#trvlMode", settings["travel_mode"], timeout_ms)
    await _select_value(page, "#embark", settings["embark_country"], timeout_ms)
    await page.locator("#vesselNm").fill(settings["vessel"])

    await _select_value(page, "#accommodationStay", settings["accommodation_stay"], timeout_ms)
    await page.locator("#accommodationAddress1").fill(settings["address1"])
    await page.locator("#accommodationAddress2").fill(settings["address2"])
    await _select_value(page, "#accommodationState", settings["state_code"], timeout_ms)
    await _select_value(page, "#accommodationCity", settings["city_code"], timeout_ms)
    await page.locator("#accommodationPostcode").fill(settings["postcode"])

    await page.locator("#sex").select_option(value=fields["#sex"])
    await page.locator("#name").fill(fields["#name"])
    await page.locator("#passNo").fill(fields["#passNo"])
    await _set_readonly_date(page.locator("#dob"), fields["#dob"])
    await _set_readonly_date(page.locator("#passExpDte"), fields["#passExpDte"])
    await _set_readonly_date(page.locator("#arrDt"), fields["#arrDt"])
    await _set_readonly_date(page.locator("#depDt"), fields["#depDt"])
    await page.wait_for_timeout(800)

    selectors = {
        "#region": fields["#region"],
        "#nationality": fields["#nationality"],
        "#pob": fields["#pob"],
        "#sex": fields["#sex"],
        "#name": fields["#name"],
        "#passNo": fields["#passNo"],
        "#dob": fields["#dob"],
        "#passExpDte": fields["#passExpDte"],
        "#arrDt": fields["#arrDt"],
        "#depDt": fields["#depDt"],
        "#email": settings["mdac_email"],
        "#confirmEmail": settings["mdac_email"],
        "#mobile": settings["mdac_phone"],
        "#trvlMode": settings["travel_mode"],
        "#embark": settings["embark_country"],
        "#vesselNm": settings["vessel"],
        "#accommodationStay": settings["accommodation_stay"],
        "#accommodationAddress1": settings["address1"],
        "#accommodationAddress2": settings["address2"],
        "#accommodationState": settings["state_code"],
        "#accommodationCity": settings["city_code"],
        "#accommodationPostcode": settings["postcode"],
    }
    mismatches: dict[str, dict[str, str]] = {}
    for selector, expected in selectors.items():
        actual = await _input_value(page, selector)
        if actual != expected:
            mismatches[selector] = {"expected": expected, "actual": actual}

    invalid_count = await page.locator("input:invalid, select:invalid").count()
    submit_disabled = await page.locator("#submit").is_disabled()
    captcha_canvas_count = await page.locator("#captcha canvas").count()
    slider_container_present = await page.locator("#captcha .sliderContainer").count() > 0
    captcha_present = captcha_canvas_count >= 2 and slider_container_present
    current_url = page.url
    if "/mdac/register" in current_url and not current_url.endswith("registerMain"):
        raise ManualReviewRequired(f"填写期间页面发生非预期跳转：{current_url}")
    if mismatches:
        raise WorkerError(f"页面字段回读不一致：{json.dumps(mismatches, ensure_ascii=False)[:800]}")

    return {
        "page_url": current_url,
        "field_count": len(selectors),
        "invalid_control_count": invalid_count,
        "submit_disabled_before_captcha": submit_disabled,
        "captcha_present": captcha_present,
        "captcha_canvas_count": captcha_canvas_count,
        "slider_container_present": slider_container_present,
        "manual_review_required": captcha_present,
        "challenge_type": "CAPTCHA_SLIDER" if captcha_present else None,
        "verification": "DOM values matched expected mapping; no submit action invoked",
    }


async def _block_form_posts(context: BrowserContext) -> None:
    async def route_handler(route: Any) -> None:
        request = route.request
        if request.method.upper() == "POST" and "/mdac/register" in request.url:
            LOG.error("检测到 MDAC POST 请求，已在 fill-preview 防护层拦截")
            await route.abort()
            return
        await route.continue_()

    await context.route("**/mdac/register*", route_handler)


async def process_item(
    *,
    page: Page,
    client: SupabaseAdminClient,
    config: WorkerConfig,
    batch: dict[str, Any],
    item: dict[str, Any],
) -> None:
    batch_id = str(batch["id"])
    item_id = str(item["id"])
    summary: dict[str, Any] = {
        "execution_mode": config.execution_mode,
        "preview_only": True,
        "submitted": False,
        "result_confirmed": False,
        "batch_id": batch_id,
        "item_id": item_id,
        "mdac_url": config.mdac_url,
    }
    screenshot_path: str | None = None
    error_code: str | None = None
    error_message: str | None = None

    try:
        snapshot = item.get("customer_snapshot")
        if not isinstance(snapshot, dict):
            raise ValueError("customer_snapshot 格式不正确")
        settings = normalize_mdac_settings(batch.get("mdac_settings_snapshot"))
        fields = map_mdac_fields(snapshot, batch, settings)
        summary["settings_snapshot_present"] = True
        summary["passport_masked"] = mask_passport(fields["#passNo"])
        summary["mapped_fields"] = {
            key: value for key, value in fields.items() if key != "#passNo"
        }
        client.heartbeat(status="BUSY", batch_id=batch_id, item_id=item_id)
        page_summary = await fill_and_verify_page(page, fields, config, settings)
        summary.update(page_summary)
        if page_summary.get("manual_review_required"):
            error_code = "NEEDS_HUMAN_INTERVENTION"
            error_message = (
                "检测到 MDAC CAPTCHA/滑块；Worker 未拖动、未破解、未提交，等待人工审核"
            )
    except ManualReviewRequired as exc:
        error_code = "NEEDS_HUMAN_INTERVENTION"
        error_message = _safe_text(exc)
        summary["manual_review_required"] = True
    except (ValueError, WorkerError, PlaywrightTimeoutError) as exc:
        error_code = "FILL_PREVIEW_FAILED"
        error_message = _safe_text(exc)
    except Exception as exc:  # noqa: BLE001 - final per-item containment
        error_code = "UNEXPECTED_FILL_PREVIEW_ERROR"
        error_message = _safe_text(exc)
        LOG.exception("批次 %s 项 %s 未预期错误", batch_id, item_id)

    try:
        screenshot = await page.screenshot(type="png", full_page=True)
        screenshot_path = client.upload_screenshot(
            f"{config.screenshot_prefix}/{batch_id}/{item_id}/preview.png",
            screenshot,
        )
        summary["screenshot_saved"] = True
    except Exception as exc:  # noqa: BLE001 - preserve review state even if storage fails
        summary["screenshot_saved"] = False
        summary["screenshot_error"] = _safe_text(exc)
        if error_code is None:
            error_code = "SCREENSHOT_UPLOAD_FAILED"
            error_message = _safe_text(exc)

    summary["submitted"] = False
    summary["result_confirmed"] = False
    client.finish_fill_preview(
        item_id=item_id,
        screenshot_path=screenshot_path,
        raw_summary=summary,
        error_code=error_code,
        error_message=error_message,
    )
    LOG.info(
        "批次 %s 项 %s 已写回 NEEDS_REVIEW；preview_only=true submitted=false error=%s",
        batch_id,
        item_id,
        error_code or "none",
    )


async def run_once(config: WorkerConfig, client: SupabaseAdminClient) -> bool:
    batch = client.claim_batch()
    if not batch:
        return False

    batch_id = str(batch["id"])
    client.heartbeat(status="BUSY", batch_id=batch_id)
    LOG.info("已领取 MDAC 批次 %s；仅填表预览，绝不提交", batch_id)

    async with async_playwright() as playwright:
        browser: Browser | None = None
        try:
            browser = await playwright.chromium.launch(headless=config.headless)
            context = await browser.new_context(
                viewport={"width": 1440, "height": 1200},
                locale="en-MY",
                accept_downloads=False,
            )
            await _block_form_posts(context)
            page = await context.new_page()
            while True:
                item = client.claim_item(batch_id)
                if not item:
                    break
                try:
                    await process_item(
                        page=page,
                        client=client,
                        config=config,
                        batch=batch,
                        item=item,
                    )
                finally:
                    await page.close()
                    page = await context.new_page()
            await context.close()
        except Exception:
            LOG.exception("批次 %s 浏览器阶段失败", batch_id)
            raise
        finally:
            if browser is not None:
                await browser.close()

    client.heartbeat(status="ONLINE")
    LOG.info("批次 %s 已处理；所有项均等待人工审核，未提交", batch_id)
    return True


async def run_poll(config: WorkerConfig, client: SupabaseAdminClient) -> None:
    client.heartbeat(status="ONLINE")
    while True:
        try:
            processed = await run_once(config, client)
            if not processed:
                await asyncio.sleep(config.poll_seconds)
        except (WorkerError, requests.RequestException) as exc:
            LOG.error("MDAC fill-preview Worker 错误：%s", exc)
            try:
                client.heartbeat(status="ERROR")
            except Exception:  # noqa: BLE001 - keep poll loop alive
                LOG.exception("错误状态心跳写入失败")
            await asyncio.sleep(config.poll_seconds)
        except Exception:
            LOG.exception("MDAC fill-preview Worker 未预期错误")
            try:
                client.heartbeat(status="ERROR")
            except Exception:  # noqa: BLE001
                LOG.exception("未预期错误心跳写入失败")
            await asyncio.sleep(config.poll_seconds)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="MDAC fill-preview Worker; never submits")
    parser.add_argument("--once", action="store_true", help="处理一个队列批次后退出")
    parser.add_argument("--poll", action="store_true", help="持续轮询 Supabase 队列")
    parser.add_argument("--verbose", action="store_true", help="启用 DEBUG 日志")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    config = WorkerConfig.from_env()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else getattr(logging, config.log_level, logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    client = SupabaseAdminClient(config)
    if args.once:
        asyncio.run(run_once(config, client))
        return
    asyncio.run(run_poll(config, client))


if __name__ == "__main__":
    main()
