"""MDAC Worker 的 dry-run 版本。

这个文件只模拟队列协作和字段映射，不打开真实网页、不连接 Gmail、不读取真实护照资料。
正式版本应将 QueueStore 替换为 Supabase 适配器，将 MdacAutomationAdapter 替换为经过授权的
官方业务自动化实现，同时保留本文件的锁、快照、重试和结果分离原则。
"""

from __future__ import annotations

import argparse
import json
import time
from dataclasses import asdict, dataclass, field
from datetime import date, datetime
from enum import Enum
from pathlib import Path
from typing import Any


class TaskStatus(str, Enum):
    QUEUED = "QUEUED"
    CLAIMED = "CLAIMED"
    RUNNING = "RUNNING"
    SUCCEEDED = "SUCCEEDED"
    PARTIAL_SUCCESS = "PARTIAL_SUCCESS"
    FAILED = "FAILED"
    ACTION_REQUIRED = "ACTION_REQUIRED"


class ItemStatus(str, Enum):
    QUEUED = "QUEUED"
    RUNNING = "RUNNING"
    SUCCEEDED = "SUCCEEDED"
    FAILED = "FAILED"


@dataclass
class CustomerSnapshot:
    customer_id: str
    full_name: str
    passport_number: str
    date_of_birth: str
    place_of_birth: str
    nationality: str
    gender: str
    passport_expiry_date: str
    entry_date: str
    exit_date: str
    business_status: str = "PENDING"

    def validate(self) -> None:
        required = {
            "姓名": self.full_name,
            "护照号码": self.passport_number,
            "出生日期": self.date_of_birth,
            "出生地点": self.place_of_birth,
            "国籍": self.nationality,
            "性别": self.gender,
            "护照过期日期": self.passport_expiry_date,
            "入境日期": self.entry_date,
            "出境日期": self.exit_date,
        }
        missing = [label for label, value in required.items() if not str(value).strip()]
        if missing:
            raise ValueError(f"缺少必填字段：{'、'.join(missing)}")
        entry = parse_date(self.entry_date)
        exit_ = parse_date(self.exit_date)
        if exit_ < entry:
            raise ValueError("出境日期不能早于入境日期")
        if self.gender not in {"男", "女", "1", "2"}:
            raise ValueError(f"未知性别：{self.gender}")


@dataclass
class TaskItem:
    item_id: str
    customer: CustomerSnapshot
    status: ItemStatus = ItemStatus.QUEUED
    attempt_count: int = 0
    error_code: str | None = None
    error_message: str | None = None
    result: dict[str, Any] = field(default_factory=dict)


@dataclass
class AutomationBatch:
    batch_id: str
    task_type: str
    items: list[TaskItem]
    status: TaskStatus = TaskStatus.QUEUED
    worker_id: str | None = None
    claimed_at: str | None = None
    created_at: str = field(default_factory=lambda: datetime.now().isoformat(timespec="seconds"))
    note: str = ""

    @property
    def success_count(self) -> int:
        return sum(item.status == ItemStatus.SUCCEEDED for item in self.items)

    @property
    def failed_count(self) -> int:
        return sum(item.status == ItemStatus.FAILED for item in self.items)

    def to_result(self) -> dict[str, Any]:
        return {
            "batch_id": self.batch_id,
            "task_type": self.task_type,
            "status": self.status.value,
            "worker_id": self.worker_id,
            "claimed_at": self.claimed_at,
            "success_count": self.success_count,
            "failed_count": self.failed_count,
            "total_count": len(self.items),
            "note": self.note,
            "items": [
                {
                    "item_id": item.item_id,
                    "customer_id": item.customer.customer_id,
                    "passport_number_masked": mask_passport(item.customer.passport_number),
                    "status": item.status.value,
                    "attempt_count": item.attempt_count,
                    "error_code": item.error_code,
                    "error_message": item.error_message,
                    "result": item.result,
                }
                for item in self.items
            ],
        }


def parse_date(value: str) -> date:
    """Accept ISO and the old script's DD/MM/YYYY output format."""
    value = value.strip()
    for fmt in ("%Y-%m-%d", "%d/%m/%Y"):
        try:
            return datetime.strptime(value, fmt).date()
        except ValueError:
            continue
    raise ValueError(f"无法识别日期：{value}")


def format_mdac_date(value: str) -> str:
    return parse_date(value).strftime("%d/%m/%Y")


def map_gender(value: str) -> str:
    normalized = value.strip()
    if normalized in {"男", "1"}:
        return "1"
    if normalized in {"女", "2"}:
        return "2"
    raise ValueError(f"未知性别：{value}")


def map_mdac_fields(snapshot: CustomerSnapshot) -> dict[str, str]:
    """Map the new customer snapshot to the legacy mdac-auto-v2 selectors."""
    snapshot.validate()
    # The existing script currently maps #pob to nationality. Keep the source place
    # in the domain model so this adapter can change without data migration later.
    return {
        "#region": "60",
        "#nationality": snapshot.nationality.upper(),
        "#pob": snapshot.nationality.upper(),
        "#sex": map_gender(snapshot.gender),
        "#name": snapshot.full_name.strip(),
        "#passNo": snapshot.passport_number.strip().upper(),
        "#dob": format_mdac_date(snapshot.date_of_birth),
        "#passExpDte": format_mdac_date(snapshot.passport_expiry_date),
        "#arrDt": format_mdac_date(snapshot.entry_date),
        "#depDt": format_mdac_date(snapshot.exit_date),
    }


def mask_passport(value: str) -> str:
    value = value.strip()
    if len(value) <= 4:
        return "••••"
    return f"{value[:2]}••••{value[-2:]}"


class DryRunWorker:
    """Single-concurrency worker that never reports unknown results as success."""

    def __init__(self, worker_id: str = "office-worker-01", max_attempts: int = 2):
        self.worker_id = worker_id
        self.max_attempts = max_attempts
        self.last_heartbeat: dict[str, Any] = {}

    def heartbeat(self, status: str = "ONLINE", current_task_id: str | None = None) -> dict[str, Any]:
        self.last_heartbeat = {
            "worker_id": self.worker_id,
            "hostname": "dry-run-office",
            "version": "dry-run 0.1.0",
            "status": status,
            "current_task_id": current_task_id,
            "last_seen_at": datetime.now().isoformat(timespec="seconds"),
        }
        return self.last_heartbeat

    def claim(self, batch: AutomationBatch) -> bool:
        if batch.status != TaskStatus.QUEUED:
            return False
        batch.status = TaskStatus.CLAIMED
        batch.worker_id = self.worker_id
        batch.claimed_at = datetime.now().isoformat(timespec="seconds")
        return True

    def run(self, batch: AutomationBatch) -> AutomationBatch:
        if not self.claim(batch):
            raise RuntimeError("任务不是 QUEUED，拒绝重复领取")
        batch.status = TaskStatus.RUNNING
        batch.note = "dry-run：已领取任务，逐项校验并模拟结果回写"
        self.heartbeat(status="BUSY", current_task_id=batch.batch_id)

        for item in batch.items:
            if item.status == ItemStatus.SUCCEEDED:
                # Idempotency: a success can never be overwritten by a retry.
                continue
            item.status = ItemStatus.RUNNING
            item.attempt_count += 1
            try:
                fields = map_mdac_fields(item.customer)
                # Deliberately deterministic. No browser, network, Gmail or real submit.
                time.sleep(0.02)
                item.result = {
                    "mode": "dry-run",
                    "selector_count": len(fields),
                    "registration_number": f"DRY-{item.customer.customer_id.upper()}",
                    "submitted": False,
                    "result_confirmed": False,
                    "message": "未连接真实 MDAC 网页；不得视为真实注册成功",
                }
                item.status = ItemStatus.SUCCEEDED
            except (ValueError, KeyError) as exc:
                item.status = ItemStatus.FAILED
                item.error_code = "VALIDATION_ERROR"
                item.error_message = str(exc)

        if batch.failed_count == len(batch.items):
            batch.status = TaskStatus.FAILED
        elif batch.failed_count:
            batch.status = TaskStatus.PARTIAL_SUCCESS
        else:
            batch.status = TaskStatus.SUCCEEDED
        batch.note = "dry-run 完成：结果仅用于验证队列和字段映射，不代表真实网页提交成功"
        self.heartbeat(status="ONLINE", current_task_id=None)
        return batch


def demo_batch() -> AutomationBatch:
    today = date.today()
    snapshots = [
        CustomerSnapshot(
            customer_id="c-004",
            full_name="CHEN YU HAN",
            passport_number="G34729104",
            date_of_birth="1988-11-12",
            place_of_birth="CHINA",
            nationality="CHN",
            gender="女",
            passport_expiry_date="2034-05-16",
            entry_date=today.replace(day=min(today.day, 28)).isoformat(),
            exit_date=(today.replace(day=min(today.day, 28))).isoformat(),
        ),
        CustomerSnapshot(
            customer_id="c-invalid",
            full_name="MISSING EXPIRY",
            passport_number="ZX000000",
            date_of_birth="1990-01-01",
            place_of_birth="CHINA",
            nationality="CHN",
            gender="男",
            passport_expiry_date="",
            entry_date=today.isoformat(),
            exit_date=today.isoformat(),
        ),
    ]
    return AutomationBatch(
        batch_id="dry-batch-001",
        task_type="MDAC_REGISTRATION",
        items=[TaskItem(item_id=f"item-{index + 1}", customer=snapshot) for index, snapshot in enumerate(snapshots)],
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the safe MDAC dry-run worker")
    parser.add_argument("--output", type=Path, default=Path("worker/demo_results.json"))
    args = parser.parse_args()

    worker = DryRunWorker()
    batch = worker.run(demo_batch())
    payload = {"heartbeat": worker.last_heartbeat, "batch": batch.to_result()}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(payload, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
