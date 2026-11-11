"""Azure Document Intelligence passport OCR worker.

This worker is intentionally server-side only. It never belongs in the Flutter APK
and it reads all credentials from environment variables.

Required environment variables:
    AZURE_DI_ENDPOINT
    AZURE_DI_KEY
    SUPABASE_URL
    SUPABASE_SERVICE_ROLE_KEY

Run one uploaded batch:
    python worker/azure_ocr_worker.py --batch-id <uuid>

The worker accepts the Azure v4.0 (2024-11-30) prebuilt-idDocument response and
writes both the raw provider response and normalized application fields to
public.ocr_results. Missing critical fields, unsupported sex values, invalid dates,
and non-passport documents remain REVIEW_REQUIRED.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import sys
import time
from dataclasses import dataclass, replace
from datetime import date, datetime, timezone
import socket
from pathlib import PurePosixPath, Path
from typing import Any, Iterable
from urllib.parse import quote

import requests

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mdac_protocol import FencedRPCMixin

LOG = logging.getLogger("azure_ocr_worker")
API_VERSION = "2024-11-30"
DEFAULT_POLL_SECONDS = 2.0
DEFAULT_TIMEOUT_SECONDS = 45


class WorkerConfigError(RuntimeError):
    """Raised when a required environment variable is missing."""


class AzureAnalyzeError(RuntimeError):
    """Raised when Azure rejects or cannot complete an analysis."""


class SupabaseError(RuntimeError):
    """Raised when the Supabase REST or Storage API fails."""


def _load_env_file() -> None:
    env_file = os.getenv("ENV_FILE", "").strip()
    candidates = [env_file] if env_file else [".env.local", ".env"]
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)
    for c in candidates:
        if not c:
            continue
        for base in (script_dir, repo_root):
            path = c if os.path.isabs(c) else os.path.join(base, c)
            if os.path.exists(path):
                with open(path, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if not line or line.startswith("#") or "=" not in line:
                            continue
                        k, v = line.split("=", 1)
                        k, v = k.strip(), v.strip()
                        if k and k not in os.environ:
                            os.environ[k] = v


@dataclass(frozen=True)
class WorkerConfig:
    supabase_url: str
    supabase_service_role_key: str
    azure_endpoint: str
    azure_key: str
    worker_id: str = "azure-ocr-worker"
    poll_seconds: float = DEFAULT_POLL_SECONDS
    request_timeout: int = DEFAULT_TIMEOUT_SECONDS

    @property
    def service_role_key(self):
        return self.supabase_service_role_key

    @property
    def request_timeout_seconds(self):
        return self.request_timeout

    @classmethod
    def from_env(cls) -> "WorkerConfig":
        _load_env_file()
        names = {
            "SUPABASE_URL": os.getenv("SUPABASE_URL", "").strip(),
            "SUPABASE_SERVICE_ROLE_KEY": os.getenv("SUPABASE_SERVICE_ROLE_KEY", "").strip(),
            "AZURE_DI_ENDPOINT": os.getenv("AZURE_DI_ENDPOINT", "").strip(),
            "AZURE_DI_KEY": os.getenv("AZURE_DI_KEY", "").strip(),
        }
        missing = [name for name, value in names.items() if not value]
        if missing:
            raise WorkerConfigError(
                "缺少 Worker 环境变量：" + ", ".join(missing)
            )
        return cls(
            supabase_url=names["SUPABASE_URL"].rstrip("/"),
            supabase_service_role_key=names["SUPABASE_SERVICE_ROLE_KEY"],
            azure_endpoint=names["AZURE_DI_ENDPOINT"].rstrip("/"),
            azure_key=names["AZURE_DI_KEY"],
            worker_id=os.getenv("OCR_WORKER_ID", "azure-ocr-worker"),
            poll_seconds=max(float(os.getenv("OCR_POLL_SECONDS", "2")), 0.5),
            request_timeout=max(int(os.getenv("OCR_REQUEST_TIMEOUT_SECONDS", "45")), 5),
        )


class SupabaseAdminClient(FencedRPCMixin):
    """Small REST client using a server-only service role key."""

    def __init__(self, config: WorkerConfig, session: requests.Session | None = None):
        self.config = config
        self.session = session or requests.Session()
        self.session.headers.update(
            {
                "apikey": config.supabase_service_role_key,
                "Authorization": f"Bearer {config.supabase_service_role_key}",
            }
        )

    @property
    def rest_url(self) -> str:
        return f"{self.config.supabase_url}/rest/v1"

    @property
    def storage_url(self) -> str:
        return f"{self.config.supabase_url}/storage/v1"

    def get_batch(self, batch_id: str) -> dict[str, Any]:
        response = self.session.get(
            f"{self.rest_url}/ocr_batches",
            params={
                "id": f"eq.{batch_id}",
                "select": "id,file_path,source_type,status,total_results,processed_results,metadata",
                "limit": "1",
            },
            timeout=self.config.request_timeout,
        )
        self._raise(response, "读取 OCR 批次")
        rows = response.json()
        if not rows:
            raise SupabaseError(f"找不到 OCR 批次：{batch_id}")
        return rows[0]

    def _check(self, response, action):
        self._raise(response, action)

    def _rpc(self, name, payload):
        return self.protocol_rpc(name, payload)

    def cleanup_discarded_batches(self) -> None:
        try:
            response = self.session.get(
                f"{self.rest_url}/ocr_batches",
                params={
                    "status": "in.(REVIEW_REQUIRED,READY_TO_CREATE)",
                    "select": "id,ocr_results(status)",
                    "limit": "50",
                },
                timeout=self.config.request_timeout,
            )
            if not response.ok:
                return
            for row in response.json():
                results = row.get("ocr_results") or []
                if results and all(r.get("status") == "FAILED" for r in results):
                    self.session.delete(
                        f"{self.rest_url}/ocr_batches",
                        params={"id": f"eq.{row['id']}"},
                        timeout=self.config.request_timeout,
                    )
        except Exception:
            pass

    def claim_next_batch(self, batch_id=None) -> dict[str, Any] | None:
        self.cleanup_discarded_batches()
        payload = {"p_worker_id": self.config.worker_id, "p_lease_seconds": 900, "p_max_attempts": 5}
        if batch_id:
            payload["p_batch_id"] = batch_id
        rows = self._rpc("claim_ocr_batch", payload)
        return rows[0] if rows else None

    def before_ocr_analyze(self, batch_id):
        self._rpc("before_ocr_analyze_v2", {"p_worker_id": self.config.worker_id, "p_batch_id": batch_id})

    def record_ocr_operation(self, batch_id, operation_url):
        self._rpc("record_ocr_operation_v2", {"p_worker_id": self.config.worker_id,
                 "p_batch_id": batch_id, "p_operation_url": operation_url})

    def download_private_file(self, file_path: str) -> bytes:
        safe_path = "/".join(quote(part, safe="") for part in PurePosixPath(file_path).parts)
        response = self.session.get(
            f"{self.storage_url}/object/passport-documents/{safe_path}",
            timeout=self.config.request_timeout,
        )
        self._raise(response, "读取私有护照文件")
        return response.content

    def set_batch_status(
        self,
        batch_id: str,
        status: str,
        *,
        total_results: int | None = None,
        processed_results: int | None = None,
        error_message: str | None = None,
    ) -> None:
        payload: dict[str, Any] = {"status": status}
        if total_results is not None:
            payload["total_results"] = total_results
        if processed_results is not None:
            payload["processed_results"] = processed_results
        if error_message is not None:
            payload["error_message"] = error_message[:2000]
        self._rpc("update_ocr_batch_v2" if status == "PROCESSING" else "finish_ocr_batch",
                  {"p_worker_id": self.config.worker_id, "p_batch_id": batch_id, "p_payload": payload})

    def insert_result(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self._rpc("write_ocr_result_v2", {"p_worker_id": self.config.worker_id,
                         "p_batch_id": payload["batch_id"], "p_payload": payload})

    def heartbeat(self, *, worker_id=None, status="ONLINE", batch_id=None, item_id=None):
        self._rpc("heartbeat_ocr_v2", {"p_worker_id": worker_id or self.config.worker_id,
                  "p_batch_id": batch_id, "p_status": status, "p_hostname": socket.gethostname(),
                  "p_version": os.getenv("MDAC_WORKER_BUILD", "azure-ocr-fenced-v2"), "p_lease_seconds": 900})

    def _raise(self, response: requests.Response, action: str) -> None:
        if response.ok:
            return
        raise SupabaseError(f"{action}失败：HTTP {response.status_code}")


class AzureIdentityDocumentClient:
    """REST client for Azure Document Intelligence prebuilt-idDocument."""

    def __init__(self, config: WorkerConfig, session: requests.Session | None = None):
        self.config = config
        self.session = session or requests.Session()

    def analyze(self, content: bytes, content_type: str) -> dict[str, Any]:
        url = (
            f"{self.config.azure_endpoint}/documentintelligence/"
            f"documentModels/prebuilt-idDocument:analyze"
        )
        response = self.session.post(
            url,
            params={"api-version": API_VERSION},
            headers={
                "Ocp-Apim-Subscription-Key": self.config.azure_key,
                "Content-Type": content_type,
            },
            data=content,
            timeout=self.config.request_timeout,
        )
        if response.status_code != 202:
            detail = response.text[:500].replace("\n", " ")
            raise AzureAnalyzeError(
                f"Azure 提交失败：HTTP {response.status_code}，{detail}"
            )
        operation_url = response.headers.get("Operation-Location")
        if not operation_url:
            raise AzureAnalyzeError("Azure 响应缺少 Operation-Location")
        callback = getattr(self, "on_operation_started", None)
        if callback:
            callback(operation_url)
        return self._poll(operation_url)

    def _poll(self, operation_url: str) -> dict[str, Any]:
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            response = self.session.get(
                operation_url,
                headers={"Ocp-Apim-Subscription-Key": self.config.azure_key},
                timeout=self.config.request_timeout,
            )
            if not response.ok:
                detail = response.text[:500].replace("\n", " ")
                raise AzureAnalyzeError(
                    f"Azure 轮询失败：HTTP {response.status_code}，{detail}"
                )
            body = response.json()
            status = str(body.get("status", "")).lower()
            if status == "succeeded":
                return body
            if status in {"failed", "canceled", "cancelled"}:
                error = body.get("error") or body.get("analyzeResult", {}).get("errors")
                raise AzureAnalyzeError(f"Azure OCR 失败：{error or status}")
            time.sleep(self.config.poll_seconds)
        raise AzureAnalyzeError("Azure OCR 轮询超过 300 秒")


def content_type_for_path(file_path: str) -> str:
    suffix = PurePosixPath(file_path).suffix.lower()
    return {
        ".pdf": "application/pdf",
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".bmp": "image/bmp",
        ".tif": "image/tiff",
        ".tiff": "image/tiff",
        ".heif": "image/heif",
    }.get(suffix, "application/octet-stream")


def sha256_hex(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def _first_text(node: Any) -> str:
    if not isinstance(node, dict):
        return ""
    for key in ("valueString", "valueDate", "valueCountryRegion", "content"):
        value = node.get(key)
        if value is not None and str(value).strip():
            return str(value).strip()
    return ""


def _field(fields: dict[str, Any], *names: str) -> dict[str, Any]:
    for name in names:
        node = fields.get(name)
        if isinstance(node, dict):
            return node
    return {}


def _field_text(fields: dict[str, Any], *names: str) -> str:
    return _first_text(_field(fields, *names))


def _confidence(node: dict[str, Any]) -> float | None:
    value = node.get("confidence")
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _normalize_passport_name(value: str) -> str:
    """Keep passport-name letters, apostrophes and hyphens; discard OCR punctuation."""
    cleaned = re.sub(r"[^A-Za-z' -]+", " ", value.replace("<", " "))
    return " ".join(cleaned.split()).upper()


def parse_azure_result(raw_result: dict[str, Any]) -> tuple[dict[str, Any], float | None, str]:
    """Return normalized fields, aggregate confidence, and review status."""
    documents = raw_result.get("analyzeResult", {}).get("documents", [])
    if not documents:
        return {}, None, "REVIEW_REQUIRED"
    document = documents[0] if isinstance(documents[0], dict) else {}
    fields = document.get("fields", {}) if isinstance(document.get("fields"), dict) else {}

    first_name = _normalize_passport_name(_field_text(fields, "FirstName", "GivenName"))
    last_name = _normalize_passport_name(_field_text(fields, "LastName", "Surname"))
    # Azure FirstName is the given name and LastName is the surname.
    # For passports, keep the canonical passport/MRZ order: surname first,
    # followed by given names (for example LI XISHUN, not XISHUN LI).
    full_name = " ".join(part for part in (last_name, first_name) if part).upper()
    passport_number = _field_text(fields, "DocumentNumber", "PassportNumber").upper()
    date_of_birth = _iso_date(_field_text(fields, "DateOfBirth", "BirthDate"))
    passport_expiry = _iso_date(
        _field_text(fields, "DateOfExpiration", "ExpirationDate", "DateOfExpiry")
    )
    nationality = _field_text(fields, "Nationality", "CountryRegion").upper()
    sex_raw = _field_text(fields, "Sex", "Gender").upper()
    gender = {"M": "男", "F": "女", "MALE": "男", "FEMALE": "女"}.get(sex_raw, "")
    mrz = _mrz_text(_field(fields, "MachineReadableZone", "MRZ"))

    document_type = str(document.get("docType", "")).lower()
    # The current Azure prebuilt ID model namespaces the same passport type.
    if document_type == "iddocument.passport":
        document_type = "passport"

    values = {
        "full_name": full_name,
        "passport_number": passport_number,
        "date_of_birth": date_of_birth,
        "passport_expiry_date": passport_expiry,
        "nationality": nationality,
        "place_of_birth": nationality,
        "gender": gender,
        "mrz": mrz,
        "document_type": document_type,
    }

    critical = (
        values["full_name"],
        values["passport_number"],
        values["date_of_birth"],
        values["passport_expiry_date"],
        values["nationality"],
        values["gender"],
    )
    status = "READY_TO_CREATE" if all(critical) and values["document_type"] in {"", "passport"} else "REVIEW_REQUIRED"
    confidences = [
        _confidence(_field(fields, *names))
        for names in (
            ("FirstName", "GivenName"),
            ("LastName", "Surname"),
            ("DocumentNumber", "PassportNumber"),
            ("DateOfBirth", "BirthDate"),
            ("DateOfExpiration", "ExpirationDate", "DateOfExpiry"),
            ("Nationality", "CountryRegion"),
            ("Sex", "Gender"),
        )
    ]
    known_confidences = [value for value in confidences if value is not None]
    confidence = sum(known_confidences) / len(known_confidences) if known_confidences else None
    return values, confidence, status


def _iso_date(value: str) -> str:
    value = value.strip()
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%m/%d/%Y"):
        try:
            return datetime.strptime(value, fmt).date().isoformat()
        except ValueError:
            continue
    return ""


def _mrz_text(node: dict[str, Any]) -> str:
    if not node:
        return ""
    nested = node.get("valueObject")
    if isinstance(nested, dict):
        parts = [_first_text(value) for value in nested.values()]
        return "\n".join(part for part in parts if part)
    return _first_text(node)


def process_batch(
    batch_id: str,
    config: WorkerConfig,
    *,
    supabase: SupabaseAdminClient | None = None,
    azure: AzureIdentityDocumentClient | None = None,
) -> dict[str, Any]:
    supabase = supabase or SupabaseAdminClient(config)
    azure = azure or AzureIdentityDocumentClient(config)
    batch = supabase.get_batch(batch_id)
    file_path = str(batch.get("file_path", "")).strip()
    if not file_path:
        raise SupabaseError(f"批次 {batch_id} 没有 file_path")

    supabase.set_batch_status(batch_id, "PROCESSING", total_results=1, processed_results=0)
    content = supabase.download_private_file(file_path)
    supabase.before_ocr_analyze(batch_id)
    azure.on_operation_started = lambda url: supabase.record_ocr_operation(batch_id, url)
    raw_result = azure.analyze(content, content_type_for_path(file_path))
    extracted, confidence, status = parse_azure_result(raw_result)
    supabase.insert_result(
        {
            "batch_id": batch_id,
            "page_index": 0,
            "segment_index": 0,
            "raw_result": raw_result,
            "extracted_data": {
                **extracted,
                "source_file_sha256": sha256_hex(content),
                "display_date_of_birth": _display_date(extracted.get("date_of_birth", "")),
                "display_passport_expiry_date": _display_date(extracted.get("passport_expiry_date", "")),
            },
            "confidence": confidence,
            "status": status,
        }
    )
    supabase.set_batch_status(
        batch_id,
        status,
        total_results=1,
        processed_results=1,
    )
    return {
        "batch_id": batch_id,
        "status": status,
        "confidence": confidence,
        "extracted_data": extracted,
    }


def _display_date(value: str) -> str:
    try:
        return date.fromisoformat(value).strftime("%d/%m/%Y")
    except (TypeError, ValueError):
        return ""


def run_poll_loop(
    config: WorkerConfig,
    *,
    worker_id: str,
    queue_poll_seconds: float = 15.0,
    once: bool = False,
) -> int:
    """Continuously claim and process uploaded OCR batches for Railway."""
    supabase = SupabaseAdminClient(config)
    azure = AzureIdentityDocumentClient(config)
    interval = max(queue_poll_seconds, 5.0)
    LOG.info("OCR Worker 已启动：worker_id=%s，轮询间隔 %.1fs", worker_id, interval)
    last_hb_time = 0.0
    while True:
        try:
            now_mono = time.monotonic()
            if now_mono - last_hb_time >= 45.0:
                supabase.heartbeat(worker_id=worker_id, status="ONLINE")
                last_hb_time = now_mono

            batch = supabase.claim_next_batch()
            if batch is None:
                if once:
                    return 0
                time.sleep(interval)
                continue
            batch_id = str(batch["id"])
            supabase.heartbeat(worker_id=worker_id, status="BUSY", batch_id=batch_id)
            LOG.info("Worker %s 开始处理批次 %s", worker_id, batch_id)
            try:
                result = process_batch(
                    batch_id,
                    config,
                    supabase=supabase,
                    azure=azure,
                )
                LOG.info(
                    "批次 %s 完成：status=%s confidence=%s",
                    batch_id,
                    result.get("status"),
                    result.get("confidence"),
                )
            except (AzureAnalyzeError, SupabaseError, requests.RequestException) as exc:
                LOG.exception("批次 %s 处理失败", batch_id)
                try:
                    supabase.set_batch_status(
                        batch_id,
                        "FAILED",
                        error_message=str(exc),
                    )
                except (SupabaseError, requests.RequestException):
                    LOG.exception("批次 %s 失败状态回写也失败", batch_id)
            if once:
                return 0
        except (SupabaseError, requests.RequestException) as exc:
            LOG.error("Worker 轮询失败：%s", exc)
            if once:
                return 1
            time.sleep(interval)


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Azure passport OCR Worker")
    parser.add_argument("--batch-id", help="Supabase ocr_batches.id; omit to poll automatically")
    parser.add_argument("--poll", action="store_true", help="continuously process UPLOADED batches")
    parser.add_argument("--once", action="store_true", help="poll once and exit when no batch remains")
    parser.add_argument("--worker-id", default=os.getenv("OCR_WORKER_ID", "azure-ocr-worker"))
    parser.add_argument(
        "--queue-poll-seconds",
        type=float,
        default=float(os.getenv("OCR_QUEUE_POLL_SECONDS", "15")),
    )
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(list(argv) if argv is not None else None)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    try:
        config = replace(WorkerConfig.from_env(), worker_id=args.worker_id)
        if args.batch_id:
            client = SupabaseAdminClient(config)
            if not client.claim_next_batch(args.batch_id):
                raise SupabaseError("Requested OCR batch is not safely claimable")
            result = process_batch(args.batch_id, config, supabase=client)
            print(json.dumps({k: result[k] for k in ("batch_id", "status", "confidence")}, ensure_ascii=False))
            return 0
        if not args.poll and not args.once:
            parser.error("请提供 --batch-id、--poll 或 --once")
        return run_poll_loop(
            config,
            worker_id=args.worker_id,
            queue_poll_seconds=args.queue_poll_seconds,
            once=args.once,
        )
    except (WorkerConfigError, AzureAnalyzeError, SupabaseError, requests.RequestException) as exc:
        LOG.error("OCR Worker 失败：%s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
