"""Gmail PIN Worker for Passport MDAC Desk.

This service reads only the required Gmail messages, matches a customer snapshot by
passport number, and writes the minimum result through protected Supabase RPCs.
It never logs PIN values or email bodies, never sends/deletes/moves mail, and never
changes a customer to success when the match is ambiguous or authentication fails.

The MVP authentication mode is IMAP with a Gmail App Password stored only in a
Railway secret variable. OAuth/XOAUTH2 can be added later without changing the
Supabase task contract.
"""
from __future__ import annotations

import argparse
import email
import html
import imaplib
import logging
import os
import re
import socket
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from email.header import decode_header
from email.message import Message
from email.utils import parsedate_to_datetime
from typing import Any

import requests

LOG = logging.getLogger("gmail_pin_worker")
DEFAULT_SENDER = "mdac@imi.gov.my"
DEFAULT_IMAP_HOST = "imap.gmail.com"


class WorkerError(RuntimeError):
    """Expected worker or remote-service failure."""


@dataclass(frozen=True)
class WorkerConfig:
    supabase_url: str
    service_role_key: str
    worker_id: str
    gmail_app_password: str
    gmail_sender_filter: str
    gmail_imap_host: str
    gmail_imap_folder: str
    gmail_lookback_days: int
    poll_seconds: float
    lease_seconds: int
    max_attempts: int
    request_timeout_seconds: float
    mark_seen: bool
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

        auth_mode = os.getenv("GMAIL_AUTH_MODE", "IMAP_APP_PASSWORD").strip().upper()
        if auth_mode != "IMAP_APP_PASSWORD":
            raise WorkerError(
                "GMAIL_AUTH_MODE 当前必须为 IMAP_APP_PASSWORD；OAuth/XOAUTH2 尚未启用"
            )

        mark_seen = os.getenv("GMAIL_MARK_SEEN", "false").strip().lower()
        if mark_seen != "false":
            raise WorkerError(
                "GMAIL_MARK_SEEN 必须严格为 false；MVP 不修改邮箱已读状态"
            )

        return cls(
            supabase_url=required("SUPABASE_URL").rstrip("/"),
            service_role_key=required("SUPABASE_SERVICE_ROLE_KEY"),
            worker_id=required("GMAIL_WORKER_ID"),
            gmail_app_password=required("GMAIL_APP_PASSWORD"),
            gmail_sender_filter=(
                os.getenv("GMAIL_SENDER_FILTER", DEFAULT_SENDER).strip().lower()
                or DEFAULT_SENDER
            ),
            gmail_imap_host=(
                os.getenv("GMAIL_IMAP_HOST", DEFAULT_IMAP_HOST).strip()
                or DEFAULT_IMAP_HOST
            ),
            gmail_imap_folder=(
                os.getenv("GMAIL_IMAP_FOLDER", "INBOX").strip() or "INBOX"
            ),
            gmail_lookback_days=bounded_int("GMAIL_LOOKBACK_DAYS", "7", 1, 30),
            poll_seconds=positive_float("GMAIL_POLL_SECONDS", "30", 10.0),
            lease_seconds=bounded_int("GMAIL_LEASE_SECONDS", "900", 60, 3600),
            max_attempts=bounded_int("GMAIL_MAX_ATTEMPTS", "5", 1, 20),
            request_timeout_seconds=positive_float(
                "SUPABASE_REQUEST_TIMEOUT_SECONDS", "30", 5.0
            ),
            mark_seen=False,
            log_level=os.getenv("LOG_LEVEL", "INFO").strip().upper(),
        )


class SupabaseAdminClient:
    def __init__(self, config: WorkerConfig) -> None:
        self.config = config
        self.rest_url = f"{config.supabase_url}/rest/v1"
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
            "claim_gmail_pin_batch",
            {
                "p_worker_id": self.config.worker_id,
                "p_lease_seconds": self.config.lease_seconds,
                "p_max_attempts": self.config.max_attempts,
            },
        )
        if not rows:
            return None
        if not isinstance(rows, list):
            raise WorkerError("claim_gmail_pin_batch 返回格式不正确")
        return dict(rows[0])

    def claim_item(self, batch_id: str) -> dict[str, Any] | None:
        rows = self._rpc(
            "claim_gmail_pin_item",
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
            raise WorkerError("claim_gmail_pin_item 返回格式不正确")
        return dict(rows[0])

    def heartbeat(
        self,
        *,
        status: str,
        batch_id: str | None = None,
        item_id: str | None = None,
    ) -> None:
        self._rpc(
            "heartbeat_gmail_pin",
            {
                "p_worker_id": self.config.worker_id,
                "p_batch_id": batch_id,
                "p_item_id": item_id,
                "p_lease_seconds": self.config.lease_seconds,
                "p_status": status,
                "p_hostname": socket.gethostname(),
                "p_version": "gmail-pin-1",
            },
        )

    def finish_item(
        self,
        *,
        item_id: str,
        pin_status: str,
        email_message_id: str | None,
        sender: str | None,
        subject: str | None,
        pin_value: str | None,
        match_confidence: float | None,
        raw_summary: dict[str, Any],
        received_at: str | None,
        error_code: str | None,
        error_message: str | None,
    ) -> dict[str, Any]:
        result = self._rpc(
            "finish_gmail_pin_item",
            {
                "p_item_id": item_id,
                "p_worker_id": self.config.worker_id,
                "p_pin_status": pin_status,
                "p_max_attempts": self.config.max_attempts,
                "p_email_message_id": email_message_id,
                "p_sender": sender,
                "p_subject": subject,
                "p_pin_value": pin_value,
                "p_match_confidence": match_confidence,
                "p_raw_summary": raw_summary,
                "p_received_at": received_at,
                "p_error_code": error_code,
                "p_error_message": error_message,
            },
        )
        if not isinstance(result, dict):
            raise WorkerError("finish_gmail_pin_item 返回格式不正确")
        return result


@dataclass(frozen=True)
class ParsedEmail:
    message_id: str | None
    sender: str | None
    subject: str | None
    received_at: str | None
    name: str | None
    passport_number: str | None
    pin: str | None


@dataclass(frozen=True)
class PinDecision:
    status: str
    email: ParsedEmail | None
    confidence: float | None
    summary: dict[str, Any]
    error_code: str | None = None
    error_message: str | None = None


def normalize_pin(value: str | None) -> str | None:
    """Trim only outer whitespace; preserve inner and repeated whitespace."""
    if value is None:
        return None
    normalized = value.strip()
    return normalized or None


def normalize_passport(value: Any) -> str:
    return str(value or "").strip().upper()


def resolve_gmail_address(snapshot: Any) -> str | None:
    if not isinstance(snapshot, dict):
        return None
    value = str(snapshot.get("gmail_address") or "").strip().lower()
    if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", value):
        return None
    return value


def decode_header_value(value: str | None) -> str | None:
    if not value:
        return None
    pieces: list[str] = []
    for fragment, charset in decode_header(value):
        if isinstance(fragment, bytes):
            pieces.append(fragment.decode(charset or "utf-8", errors="replace"))
        else:
            pieces.append(fragment)
    normalized = "".join(pieces).strip()
    return normalized or None


def decode_part_text(part: Message) -> str:
    payload = part.get_payload(decode=True)
    if payload is None:
        raw = part.get_payload()
        return raw if isinstance(raw, str) else ""
    charset = part.get_content_charset() or "utf-8"
    return payload.decode(charset, errors="replace")


def html_to_text(value: str) -> str:
    value = re.sub(r"<\s*br\s*/?\s*>", "\n", value, flags=re.IGNORECASE)
    value = re.sub(r"</\s*(p|div|tr|li)\s*>", "\n", value, flags=re.IGNORECASE)
    value = re.sub(r"<[^>]+>", " ", value)
    return html.unescape(value)


def extract_email_body(message: Message) -> str:
    plain_parts: list[str] = []
    html_parts: list[str] = []
    if message.is_multipart():
        for part in message.walk():
            if part.get_content_disposition() == "attachment":
                continue
            content_type = part.get_content_type()
            if content_type == "text/plain":
                plain_parts.append(decode_part_text(part))
            elif content_type == "text/html":
                html_parts.append(html_to_text(decode_part_text(part)))
    else:
        content_type = message.get_content_type()
        body = decode_part_text(message)
        if content_type == "text/html":
            html_parts.append(html_to_text(body))
        else:
            plain_parts.append(body)
    return "\n".join(plain_parts or html_parts).replace("\xa0", " ")


def extract_fields(body: str) -> dict[str, str | None]:
    def first(pattern: str) -> str | None:
        match = re.search(pattern, body, flags=re.IGNORECASE | re.MULTILINE)
        return match.group(1).strip() if match else None

    name = first(r"^\s*Name\s*:\s*(.+?)\s*$")
    passport = first(r"^\s*Passport\s+No\.\s*:\s*([A-Za-z0-9]+)\s*$")
    pin = first(r"^\s*PIN\s*:\s*(.*?)\s*$")
    return {
        "name": name,
        "passport_number": passport.upper() if passport else None,
        "pin": normalize_pin(pin),
    }


def parse_message(raw_email: bytes) -> ParsedEmail:
    message = email.message_from_bytes(raw_email)
    body = extract_email_body(message)
    fields = extract_fields(body)
    received_at: str | None = None
    date_header = message.get("Date")
    if date_header:
        try:
            received_at = parsedate_to_datetime(date_header).astimezone(timezone.utc).isoformat()
        except (TypeError, ValueError, OverflowError):
            received_at = None
    return ParsedEmail(
        message_id=decode_header_value(message.get("Message-ID")),
        sender=decode_header_value(message.get("From")),
        subject=decode_header_value(message.get("Subject")),
        received_at=received_at,
        name=fields["name"],
        passport_number=fields["passport_number"],
        pin=fields["pin"],
    )


def decide_for_item(
    snapshot: dict[str, Any], messages: list[ParsedEmail], lookback_days: int
) -> PinDecision:
    passport_number = normalize_passport(snapshot.get("passport_number"))
    if not passport_number:
        return PinDecision(
            status="PARSE_FAILED",
            email=None,
            confidence=None,
            summary={
                "source": "GMAIL_IMAP",
                "matched_by": "PASSPORT_NUMBER",
                "candidate_count": 0,
                "reason": "customer_snapshot_missing_passport_number",
                "lookback_days": lookback_days,
            },
            error_code="CUSTOMER_PASSPORT_MISSING",
            error_message="Customer snapshot does not contain a passport number",
        )

    candidates = [
        message
        for message in messages
        if normalize_passport(message.passport_number) == passport_number
    ]
    base_summary = {
        "source": "GMAIL_IMAP",
        "matched_by": "PASSPORT_NUMBER",
        "candidate_count": len(candidates),
        "lookback_days": lookback_days,
        "email_body_stored": False,
        "pin_value_logged": False,
    }
    if not candidates:
        return PinDecision(
            status="NOT_FOUND",
            email=None,
            confidence=None,
            summary=base_summary,
            error_code="PIN_NOT_FOUND",
            error_message="No matching MDAC PIN email found in the lookback window",
        )
    if len(candidates) != 1:
        return PinDecision(
            status="NEEDS_REVIEW",
            email=None,
            confidence=None,
            summary={**base_summary, "reason": "multiple_matching_messages"},
            error_code="PIN_MATCH_NOT_UNIQUE",
            error_message="Multiple matching Gmail messages require manual review",
        )

    candidate = candidates[0]
    if candidate.pin is None:
        return PinDecision(
            status="PARSE_FAILED",
            email=candidate,
            confidence=None,
            summary={**base_summary, "reason": "matching_message_has_no_pin"},
            error_code="PIN_NOT_PARSED",
            error_message="Matching Gmail message does not contain a readable PIN",
        )
    return PinDecision(
        status="RECEIVED",
        email=candidate,
        confidence=1.0,
        summary={**base_summary, "reason": "unique_passport_match"},
    )


class GmailReader:
    def __init__(self, config: WorkerConfig) -> None:
        self.config = config

    def fetch_recent(self, gmail_address: str) -> list[ParsedEmail]:
        threshold = datetime.now(timezone.utc).date() - timedelta(
            days=self.config.gmail_lookback_days
        )
        mailbox: imaplib.IMAP4_SSL | None = None
        parsed: list[ParsedEmail] = []
        try:
            mailbox = imaplib.IMAP4_SSL(
                self.config.gmail_imap_host,
                timeout=max(10, int(self.config.request_timeout_seconds)),
            )
            mailbox.login(gmail_address, self.config.gmail_app_password)
            status, _ = mailbox.select(self.config.gmail_imap_folder, readonly=True)
            if status != "OK":
                raise WorkerError("Gmail INBOX 无法以只读模式打开")
            status, data = mailbox.uid(
                "search",
                None,
                "FROM",
                self.config.gmail_sender_filter,
                "SINCE",
                threshold.strftime("%d-%b-%Y"),
            )
            if status != "OK":
                raise WorkerError("Gmail IMAP 搜索失败")
            uids = (data[0] or b"").split() if data else []
            for uid in uids:
                status, fetched = mailbox.uid("fetch", uid, "(BODY.PEEK[])")
                if status != "OK":
                    LOG.warning("跳过一封无法读取的 Gmail 邮件")
                    continue
                raw_email = next(
                    (
                        part[1]
                        for part in fetched
                        if isinstance(part, tuple) and len(part) > 1 and isinstance(part[1], bytes)
                    ),
                    None,
                )
                if raw_email is None:
                    continue
                parsed.append(parse_message(raw_email))
            return parsed
        except imaplib.IMAP4.error as exc:
            raise WorkerError("Gmail IMAP 认证或邮箱访问失败") from exc
        finally:
            if mailbox is not None:
                try:
                    mailbox.logout()
                except Exception:
                    pass


class GmailPinWorker:
    def __init__(self, config: WorkerConfig) -> None:
        self.config = config
        self.supabase = SupabaseAdminClient(config)
        self.gmail = GmailReader(config)

    def process_batch(self, batch: dict[str, Any]) -> int:
        batch_id = str(batch["id"])
        self.supabase.heartbeat(status="BUSY", batch_id=batch_id)
        gmail_settings = batch.get("gmail_settings_snapshot")
        gmail_address = resolve_gmail_address(gmail_settings)
        messages: list[ParsedEmail] = []
        if gmail_address is not None:
            messages = self.gmail.fetch_recent(gmail_address)
            LOG.info(
                "Gmail PIN 检查完成：获取 %d 封候选邮件；PIN 值不写入日志",
                len(messages),
            )
        else:
            LOG.error(
                "Gmail 地址快照缺失或无效；不会连接邮箱，也不会伪造 PIN 成功"
            )
        processed = 0
        while True:
            item = self.supabase.claim_item(batch_id)
            if item is None:
                break
            item_id = str(item["id"])
            self.supabase.heartbeat(status="BUSY", batch_id=batch_id, item_id=item_id)
            snapshot = item.get("customer_snapshot")
            if not isinstance(snapshot, dict):
                decision = PinDecision(
                    status="PARSE_FAILED",
                    email=None,
                    confidence=None,
                    summary={
                        "source": "GMAIL_IMAP",
                        "reason": "customer_snapshot_not_object",
                        "email_body_stored": False,
                        "pin_value_logged": False,
                    },
                    error_code="SNAPSHOT_INVALID",
                    error_message="Customer snapshot is not a JSON object",
                )
            elif gmail_address is None:
                decision = PinDecision(
                    status="PARSE_FAILED",
                    email=None,
                    confidence=None,
                    summary={
                        "source": "GMAIL_IMAP",
                        "reason": "gmail_address_snapshot_missing_or_invalid",
                        "email_body_stored": False,
                        "pin_value_logged": False,
                    },
                    error_code="GMAIL_ADDRESS_SNAPSHOT_INVALID",
                    error_message="Gmail address snapshot is missing or invalid",
                )
            else:
                decision = decide_for_item(
                    snapshot, messages, self.config.gmail_lookback_days
                )
            candidate = decision.email
            self.supabase.finish_item(
                item_id=item_id,
                pin_status=decision.status,
                email_message_id=candidate.message_id if candidate else None,
                sender=candidate.sender if candidate else None,
                subject=candidate.subject if candidate else None,
                pin_value=candidate.pin if decision.status == "RECEIVED" and candidate else None,
                match_confidence=decision.confidence,
                raw_summary=decision.summary,
                received_at=candidate.received_at if candidate else None,
                error_code=decision.error_code,
                error_message=decision.error_message,
            )
            processed += 1
            if decision.status == "RECEIVED":
                LOG.info("已写回一项 Gmail PIN 结果；PIN 值不写入日志")
            elif decision.status == "NOT_FOUND":
                LOG.info("本轮未找到一项对应 PIN；按租约策略处理")
            else:
                LOG.warning("一项 Gmail PIN 结果需要人工审核：%s", decision.status)
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
            "Gmail PIN Worker ONLINE：轮询间隔 %ss，发件人过滤 %s；不删除/移动/标记邮件",
            self.config.poll_seconds,
            self.config.gmail_sender_filter,
        )
        while True:
            try:
                processed = self.run_once()
                if processed:
                    LOG.info("本轮处理 %d 项 Gmail PIN 任务", processed)
            except Exception:
                LOG.exception("Gmail PIN Worker 本轮异常；未将未确认结果标为成功")
                try:
                    self.supabase.heartbeat(status="ERROR")
                except Exception:
                    LOG.exception("无法写入 Gmail PIN Worker ERROR 心跳")
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
    worker = GmailPinWorker(config)
    if args.once:
        worker.run_once()
        return
    if args.poll:
        worker.run_poll()
        return
    parser.error("必须指定 --once 或 --poll")


if __name__ == "__main__":
    main()
