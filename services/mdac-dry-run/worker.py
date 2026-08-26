"""Safe MDAC dry-run service for Railway.

This service consumes queued MDAC batches only to validate and preview the
legacy mdac-auto-v2 field mapping. It never launches a browser, logs into
MDAC, reads Gmail, or submits a registration. Each processed item is marked
FAILED with an explicit DRY_RUN_ONLY code so it cannot be mistaken for a real
registration or be picked up repeatedly.
"""
from __future__ import annotations

import logging
import os
import time
from datetime import datetime
from typing import Any

import requests

LOG = logging.getLogger("mdac_dry_run")


class WorkerError(RuntimeError):
    pass


class SupabaseClient:
    def __init__(self) -> None:
        self.base_url = os.environ["SUPABASE_URL"].rstrip("/")
        self.key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
        self.rest_url = f"{self.base_url}/rest/v1"
        self.session = requests.Session()
        self.session.headers.update(
            {
                "apikey": self.key,
                "Authorization": f"Bearer {self.key}",
                "Content-Type": "application/json",
            }
        )

    def _check(self, response: requests.Response, action: str) -> None:
        if not response.ok:
            raise WorkerError(f"{action}失败：HTTP {response.status_code} {response.text[:400]}")

    def claim_batch(self) -> dict[str, Any] | None:
        response = self.session.get(
            f"{self.rest_url}/automation_batches",
            params={
                "task_type": "eq.MDAC_REGISTRATION",
                "status": "eq.QUEUED",
                "select": "id,task_type,status,total_count,note,created_at",
                "order": "created_at.asc",
                "limit": "1",
            },
            timeout=30,
        )
        self._check(response, "读取 MDAC 队列")
        rows = response.json()
        if not rows:
            return None
        candidate = rows[0]
        response = self.session.patch(
            f"{self.rest_url}/automation_batches",
            params={"id": f"eq.{candidate['id']}", "status": "eq.QUEUED"},
            headers={"Prefer": "return=representation"},
            json={"status": "CLAIMED", "note": "dry-run 已领取；不会连接或提交真实 MDAC"},
            timeout=30,
        )
        self._check(response, "领取 MDAC 队列")
        rows = response.json()
        return rows[0] if rows else None

    def get_items(self, batch_id: str) -> list[dict[str, Any]]:
        response = self.session.get(
            f"{self.rest_url}/automation_items",
            params={
                "batch_id": f"eq.{batch_id}",
                "status": "eq.QUEUED",
                "select": "id,customer_id,customer_snapshot,status,attempt_count",
                "order": "created_at.asc",
                "limit": "200",
            },
            timeout=30,
        )
        self._check(response, "读取 MDAC 任务项")
        return response.json()

    def mark_item_dry_run_failed(self, item_id: str, message: str) -> None:
        now = datetime.utcnow().isoformat(timespec="seconds") + "Z"
        response = self.session.patch(
            f"{self.rest_url}/automation_items",
            params={"id": f"eq.{item_id}", "status": "eq.QUEUED"},
            headers={"Prefer": "return=minimal"},
            json={
                "status": "FAILED",
                "attempt_count": 1,
                "locked_by": os.getenv("MDAC_DRY_RUN_WORKER_ID", "railway-mdac-dry-run"),
                "locked_at": now,
                "started_at": now,
                "finished_at": now,
                "error_code": "DRY_RUN_ONLY",
                "error_message": message,
                "result_unknown": False,
            },
            timeout=30,
        )
        self._check(response, "回写 MDAC dry-run 结果")

    def audit(self, batch_id: str, item_count: int) -> None:
        response = self.session.post(
            f"{self.rest_url}/audit_logs",
            headers={"Prefer": "return=minimal"},
            json={
                "actor_id": None,
                "action": "MDAC_DRY_RUN",
                "entity_type": "automation_batches",
                "entity_id": batch_id,
                "metadata": {
                    "submitted": False,
                    "result_confirmed": False,
                    "item_count": item_count,
                    "message": "仅完成字段校验与映射预览，未打开浏览器、未登录、未提交 MDAC",
                },
            },
            timeout=30,
        )
        self._check(response, "写入 MDAC dry-run 审计")


def parse_date(value: str) -> datetime:
    value = str(value or "").strip()
    for fmt in ("%Y-%m-%d", "%d/%m/%Y"):
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            continue
    raise ValueError(f"无法识别日期：{value}")


def format_mdac_date(value: str) -> str:
    return parse_date(value).strftime("%d/%m/%Y")


def map_gender(value: str) -> str:
    normalized = str(value or "").strip()
    if normalized in {"男", "1"}:
        return "1"
    if normalized in {"女", "2"}:
        return "2"
    raise ValueError(f"未知性别：{value}")


def map_mdac_fields(snapshot: dict[str, Any]) -> dict[str, str]:
    required = {
        "full_name": snapshot.get("full_name"),
        "passport_number": snapshot.get("passport_number"),
        "date_of_birth": snapshot.get("date_of_birth"),
        "nationality": snapshot.get("nationality"),
        "gender": snapshot.get("gender"),
        "passport_expiry_date": snapshot.get("passport_expiry_date"),
        "entry_date": snapshot.get("entry_date"),
        "exit_date": snapshot.get("exit_date"),
    }
    missing = [key for key, value in required.items() if not str(value or "").strip()]
    if missing:
        raise ValueError(f"缺少必填字段：{', '.join(missing)}")
    entry = parse_date(str(snapshot["entry_date"]))
    exit_date = parse_date(str(snapshot["exit_date"]))
    if exit_date < entry:
        raise ValueError("出境日期不能早于入境日期")
    return {
        "#region": "60",
        "#nationality": str(snapshot["nationality"]).strip().upper(),
        "#pob": str(snapshot["nationality"]).strip().upper(),
        "#sex": map_gender(str(snapshot["gender"])),
        "#name": str(snapshot["full_name"]).strip(),
        "#passNo": str(snapshot["passport_number"]).strip().upper(),
        "#dob": format_mdac_date(str(snapshot["date_of_birth"])),
        "#passExpDte": format_mdac_date(str(snapshot["passport_expiry_date"])),
        "#arrDt": format_mdac_date(str(snapshot["entry_date"])),
        "#depDt": format_mdac_date(str(snapshot["exit_date"])),
    }


def process_batch(client: SupabaseClient, batch: dict[str, Any]) -> None:
    batch_id = str(batch["id"])
    items = client.get_items(batch_id)
    LOG.info("已领取 MDAC dry-run 批次 %s，共 %d 项", batch_id, len(items))
    for item in items:
        item_id = str(item["id"])
        try:
            fields = map_mdac_fields(item.get("customer_snapshot") or {})
            LOG.info(
                "批次 %s 项 %s 字段校验通过：passport=%s selector_count=%d",
                batch_id,
                item_id,
                mask_passport(fields["#passNo"]),
                len(fields),
            )
            message = "dry-run 字段映射通过；未打开浏览器、未登录、未提交真实 MDAC"
        except (KeyError, TypeError, ValueError) as exc:
            message = f"dry-run 字段校验失败：{exc}"
            LOG.warning("批次 %s 项 %s：%s", batch_id, item_id, message)
        client.mark_item_dry_run_failed(item_id, message)
    client.audit(batch_id, len(items))
    LOG.info("批次 %s 已结束：所有项标记 DRY_RUN_ONLY，绝不代表真实注册成功", batch_id)


def mask_passport(value: str) -> str:
    value = value.strip()
    if len(value) <= 4:
        return "••••"
    return f"{value[:2]}••••{value[-2:]}"


def main() -> None:
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    interval = max(float(os.getenv("MDAC_DRY_RUN_POLL_SECONDS", "30")), 10.0)
    client = SupabaseClient()
    LOG.info("MDAC dry-run Worker 已启动；不会启动浏览器或提交真实 MDAC")
    while True:
        try:
            batch = client.claim_batch()
            if batch:
                process_batch(client, batch)
            else:
                time.sleep(interval)
        except (WorkerError, requests.RequestException) as exc:
            LOG.error("MDAC dry-run Worker 错误：%s", exc)
            time.sleep(interval)


if __name__ == "__main__":
    main()
