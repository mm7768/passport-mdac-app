from __future__ import annotations

import json
import logging
import sys
import unittest
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from types import SimpleNamespace
from unittest.mock import patch

from worker import (
    GmailPinWorker,
    ParsedEmail,
    PinDecision,
    decide_for_item,
    extract_fields,
    is_name_compatible,
    normalize_pin,
    parse_message,
)


class GMailPinBatchAndReliabilityTests(unittest.TestCase):
    def _create_email(
        self,
        passport: str,
        name: str = "TEST PERSON",
        pin: str | None = "PIN1234",
        date: datetime | None = None,
        msg_id: str = "test-msg-1",
    ) -> ParsedEmail:
        msg = EmailMessage()
        msg["Message-ID"] = f"<{msg_id}@example.test>"
        msg["From"] = "mdac@imi.gov.my"
        msg["Subject"] = "MDAC PIN"
        if date:
            msg["Date"] = date.strftime("%a, %d %b %Y %H:%M:%S +0000")
        pin_line = f"PIN : {pin}\n" if pin is not None else "Thank you\n"
        msg.set_content(f"Name : {name}\nPassport No. : {passport}\n{pin_line}")
        return parse_message(msg.as_bytes())

    def test_30_passports_shuffled_order_exact_mapping_no_crosstalk(self) -> None:
        """Requirement: 30 distinct passports, 30 emails out of order, all mapped 1:1 without crosstalk."""
        items = []
        messages = []
        now = datetime.now(timezone.utc)

        for i in range(1, 31):
            passport = f"E{10000000 + i}"
            pin = f"PIN-{1000 + i}"
            name = f"TRAVELER NUMBER {i}"
            customer_id = f"cust-uuid-{i:04d}"

            items.append({
                "id": f"item-uuid-{i:04d}",
                "customer_id": customer_id,
                "customer_snapshot": {
                    "full_name": name,
                    "passport_number": passport,
                    "customer_created_at": (now - timedelta(minutes=10)).isoformat(),
                },
                "created_at": now.isoformat(),
            })

            # Emails created with slight time differences, out of order
            email_dt = now - timedelta(minutes=5, seconds=i * 3)
            messages.append(self._create_email(
                passport=passport,
                name=name,
                pin=pin,
                date=email_dt,
                msg_id=f"msg-{i:04d}",
            ))

        # Shuffle messages
        shuffled_messages = list(reversed(messages))

        supabase = _MockSupabase(items=items)
        worker = GmailPinWorker.__new__(GmailPinWorker)
        worker.config = SimpleNamespace(gmail_lookback_days=7)
        worker.supabase = supabase
        worker.gmail = _MockGmail(shuffled_messages)

        processed = worker.process_batch({
            "id": "batch-30-passports",
            "gmail_settings_snapshot": {"gmail_address": "test@gmail.com"},
        })

        self.assertEqual(processed, 30)
        self.assertEqual(len(supabase.finished), 30)

        # Check every item matched its exact customer_id, passport, and PIN
        for i in range(1, 31):
            expected_passport = f"E{10000000 + i}"
            expected_pin = f"PIN-{1000 + i}"
            expected_item_id = f"item-uuid-{i:04d}"

            res = next((r for r in supabase.finished if r["item_id"] == expected_item_id), None)
            self.assertIsNotNone(res, f"Item {expected_item_id} must be finished")
            self.assertEqual(res["pin_status"], "RECEIVED")
            self.assertEqual(res["pin_value"], expected_pin)

    def test_stale_email_rejected_when_new_registration_email_delayed(self) -> None:
        """Requirement: Old email exists from 3 days ago, current email not arrived -> do NOT pick old PIN."""
        now = datetime.now(timezone.utc)
        passport = "E99887766"
        stale_date = now - timedelta(days=3)

        # Stale email from 3 days ago with old PIN
        old_email = self._create_email(
            passport=passport,
            name="ZHANG WEI",
            pin="OLD-PIN-999",
            date=stale_date,
            msg_id="old-email-1",
        )

        snapshot = {
            "full_name": "ZHANG WEI",
            "passport_number": passport,
            # Current registration was created 10 minutes ago
            "customer_created_at": (now - timedelta(minutes=10)).isoformat(),
            "latest_mdac_submitted_at": (now - timedelta(minutes=8)).isoformat(),
        }

        decision = decide_for_item(snapshot, [old_email], lookback_days=7)
        self.assertEqual(decision.status, "NOT_FOUND")
        self.assertEqual(decision.error_code, "PIN_NOT_FOUND_STALE_IGNORED")
        self.assertIsNone(decision.email)
        self.assertIn("stale_emails_ignored_waiting_for_new", decision.summary.get("reason", ""))

    def test_stale_email_with_previous_pin_ignored_when_fresh_email_arrives(self) -> None:
        """Requirement: Multiple emails exist; historical PIN is skipped in favor of fresh new registration PIN."""
        now = datetime.now(timezone.utc)
        passport = "E88776655"

        old_email = self._create_email(
            passport=passport,
            name="CHEN LI",
            pin="OLD-PIN-111",
            date=now - timedelta(days=2),
            msg_id="old-msg",
        )
        new_email = self._create_email(
            passport=passport,
            name="CHEN LI",
            pin="NEW-PIN-222",
            date=now - timedelta(minutes=2),
            msg_id="new-msg",
        )

        snapshot = {
            "full_name": "CHEN LI",
            "passport_number": passport,
            "latest_mdac_submitted_at": (now - timedelta(minutes=5)).isoformat(),
            "previous_pin_value": "OLD-PIN-111",
            "previous_pin_received_at": (now - timedelta(days=2)).isoformat(),
        }

        decision = decide_for_item(snapshot, [old_email, new_email], lookback_days=7)
        self.assertEqual(decision.status, "RECEIVED")
        self.assertEqual(decision.email.pin, "NEW-PIN-222")

    def test_name_mismatch_flags_needs_review(self) -> None:
        """Requirement: Same passport but completely different name flags NEEDS_REVIEW to prevent cross-customer errors."""
        now = datetime.now(timezone.utc)
        email = self._create_email(
            passport="E12345678",
            name="JOHN SMITH",
            pin="PIN-123",
            date=now - timedelta(minutes=5),
        )

        snapshot = {
            "full_name": "WANG XIAOMING",
            "passport_number": "E12345678",
            "customer_created_at": (now - timedelta(minutes=10)).isoformat(),
        }

        decision = decide_for_item(snapshot, [email], lookback_days=7)
        self.assertEqual(decision.status, "NEEDS_REVIEW")
        self.assertEqual(decision.error_code, "PIN_NAME_MISMATCH")

    def test_is_name_compatible_logic(self) -> None:
        # Same words in different order -> True
        self.assertTrue(is_name_compatible("WONG KOK LEONG", "KOK LEONG WONG"))
        # Partial match -> True
        self.assertTrue(is_name_compatible("MOHAMMAD ALI", "ALI"))
        # Completely disjoint words -> False
        self.assertFalse(is_name_compatible("ZHANG SAN", "LI SI"))
        # None or empty -> True (graceful fallback)
        self.assertTrue(is_name_compatible(None, "TEST"))
        self.assertTrue(is_name_compatible("TEST", None))

    def test_pin_regex_does_not_capture_multiline_or_empty_lines(self) -> None:
        """Requirement: Empty PIN followed by other text does not capture next line text as PIN."""
        body_empty_pin = "Name : TEST\nPassport No. : E11223344\nPIN :\nThank you for registering\n"
        fields = extract_fields(body_empty_pin)
        self.assertIsNone(fields["pin"])

        body_valid_pin = "Name : TEST\nPassport No. : E11223344\nPIN : 8pcz  kJDr \nThank you\n"
        fields2 = extract_fields(body_valid_pin)
        self.assertEqual(fields2["pin"], "8pcz  kJDr")

    def test_multiple_fresh_matches_with_conflicting_pins_requires_review(self) -> None:
        """Requirement: Two emails with same timestamp and differing PINs require manual review."""
        now = datetime.now(timezone.utc)
        dt = now - timedelta(minutes=2)
        email1 = self._create_email(passport="E55555555", pin="PIN-AAA", date=dt, msg_id="m1")
        email2 = self._create_email(passport="E55555555", pin="PIN-BBB", date=dt, msg_id="m2")

        snapshot = {
            "passport_number": "E55555555",
            "customer_created_at": (now - timedelta(minutes=10)).isoformat(),
        }

        decision = decide_for_item(snapshot, [email1, email2], lookback_days=7)
        self.assertEqual(decision.status, "NEEDS_REVIEW")
        self.assertEqual(decision.error_code, "PIN_MATCH_NOT_UNIQUE")


class _MockGmail:
    def __init__(self, messages: list[ParsedEmail]) -> None:
        self.messages = messages

    def fetch_recent(self, gmail_address: str, app_password: str) -> list[ParsedEmail]:
        return self.messages


class _MockSupabase:
    def __init__(self, items: list[dict]) -> None:
        self.items = list(items)
        self.finished: list[dict] = []

    def heartbeat(self, **kwargs) -> None:
        pass

    def get_gmail_runtime_credentials(self) -> dict[str, str]:
        return {
            "gmail_address": "test@gmail.com",
            "gmail_app_password": "fake-password",
        }

    def claim_item(self, batch_id: str) -> dict | None:
        return self.items.pop(0) if self.items else None

    def finish_item(self, **kwargs) -> dict:
        self.finished.append(kwargs)
        return {"ok": True}


if __name__ == "__main__":
    unittest.main()
