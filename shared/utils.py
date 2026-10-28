"""Shared utility functions across all MDAC workers."""
from __future__ import annotations

import re
from datetime import date, datetime
from typing import Any


def parse_date(value: Any) -> date:
    """Parse common date formats (YYYY-MM-DD, DD/MM/YYYY, YYYY/MM/DD)."""
    text = str(value or "").strip()
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%Y/%m/%d"):
        try:
            return datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    raise ValueError(f"无法识别日期：{text}")


def format_mdac_date(value: Any) -> str:
    """Format date to Malaysian official MDAC standard (DD/MM/YYYY)."""
    return parse_date(value).strftime("%d/%m/%Y")


def mask_passport(value: str) -> str:
    """Mask passport number for privacy compliance (e.g. E1••••89)."""
    value = str(value or "").strip()
    if len(value) <= 4:
        return "••••"
    return f"{value[:2]}••••{value[-2:]}"


def map_gender(value: Any) -> str:
    """Map human gender to MDAC option value (1=Male, 2=Female)."""
    normalized = str(value or "").strip().upper()
    if normalized in {"男", "MALE", "1"}:
        return "1"
    if normalized in {"女", "FEMALE", "2"}:
        return "2"
    raise ValueError(f"未知性别：{value}")
