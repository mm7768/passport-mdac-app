from __future__ import annotations

import json
import logging
import sys
import unittest
from email.message import EmailMessage
from types import SimpleNamespace
from unittest.mock import patch

from worker import (
    GmailPinWorker,
    configure_logging,
    decide_for_item,
    log_event,
    normalize_pin,
    parse_message,
    resolve_gmail_address,
)


class GMailPinParsingTests(unittest.TestCase):
    def test_logging_uses_stdout_for_railway_severity(self) -> None:
        with patch.object(logging, "basicConfig") as basic_config:
            configure_logging("INFO")

        self.assertIs(basic_config.call_args.kwargs["stream"], sys.stdout)

    def test_normalize_pin_trims_outer_only(self) -> None:
        self.assertEqual(normalize_pin("  A  B   C  "), "A  B   C")
        self.assertIsNone(normalize_pin("   "))
        self.assertIsNone(normalize_pin(None))

    def test_resolve_gmail_address_from_batch_snapshot(self) -> None:
        self.assertEqual(
            resolve_gmail_address({'gmail_address': ' MDAC.Company@GMAIL.COM '}),
            'mdac.company@gmail.com',
        )
        self.assertIsNone(resolve_gmail_address({}))
        self.assertIsNone(resolve_gmail_address({'gmail_address': 'not-an-email'}))

    def test_parse_plain_text_message(self) -> None:
        message = EmailMessage()
        message["Message-ID"] = "<test-1@example.test>"
        message["From"] = "mdac@imi.gov.my"
        message["Subject"] = "MDAC PIN"
        message["Date"] = "Tue, 26 Aug 2026 10:00:00 +0000"
        message.set_content(
            "Name : TEST PERSON\n"
            "Passport No. : ab123456\n"
            "PIN :  8pcz  kJDr  \n"
        )
        parsed = parse_message(message.as_bytes())
        self.assertEqual(parsed.passport_number, "AB123456")
        self.assertEqual(parsed.pin, "8pcz  kJDr")
        self.assertEqual(parsed.sender, "mdac@imi.gov.my")

    def test_parse_html_message_when_plain_text_missing(self) -> None:
        message = EmailMessage()
        message["Message-ID"] = "<test-2@example.test>"
        message["From"] = "mdac@imi.gov.my"
        message["Subject"] = "MDAC PIN"
        message.set_content(
            "<p>Name : HTML PERSON</p>"
            "<p>Passport No. : ZZ998877</p>"
            "<p>PIN : PIN-123</p>",
            subtype="html",
        )
        parsed = parse_message(message.as_bytes())
        self.assertEqual(parsed.passport_number, "ZZ998877")
        self.assertEqual(parsed.pin, "PIN-123")

    def test_unique_passport_match_is_received(self) -> None:
        message = parse_message(self._message_bytes("AA100", "PIN100", "one"))
        decision = decide_for_item(
            {"passport_number": " aa100 "}, [message], lookback_days=7
        )
        self.assertEqual(decision.status, "RECEIVED")
        self.assertEqual(decision.email, message)
        self.assertEqual(decision.confidence, 1.0)

    def test_no_match_is_not_found(self) -> None:
        message = parse_message(self._message_bytes("AA100", "PIN100", "one"))
        decision = decide_for_item(
            {"passport_number": "BB200"}, [message], lookback_days=7
        )
        self.assertEqual(decision.status, "NOT_FOUND")
        self.assertEqual(decision.error_code, "PIN_NOT_FOUND")
        self.assertIsNone(decision.email)

    def test_multiple_matches_require_review(self) -> None:
        messages = [
            parse_message(self._message_bytes("AA100", "PIN100", "one")),
            parse_message(self._message_bytes("AA100", "PIN200", "two")),
        ]
        decision = decide_for_item(
            {"passport_number": "AA100"}, messages, lookback_days=7
        )
        self.assertEqual(decision.status, "NEEDS_REVIEW")
        self.assertEqual(decision.error_code, "PIN_MATCH_NOT_UNIQUE")

    def test_matching_message_without_pin_is_parse_failed(self) -> None:
        message = parse_message(self._message_bytes("AA100", None, "no-pin"))
        decision = decide_for_item(
            {"passport_number": "AA100"}, [message], lookback_days=7
        )
        self.assertEqual(decision.status, "PARSE_FAILED")
        self.assertEqual(decision.error_code, "PIN_NOT_PARSED")

    def test_structured_log_contains_context_without_secret_values(self) -> None:
        with self.assertLogs("gmail_pin_worker", level=logging.INFO) as captured:
            log_event(
                logging.INFO,
                step="result_writeback",
                status="succeeded",
                batch_id="batch-1",
                item_id="item-1",
                customer_id="customer-1",
                result="RECEIVED",
            )

        event = json.loads(captured.records[0].getMessage())
        self.assertEqual(event["worker"], "gmail_pin")
        self.assertEqual(event["batch_id"], "batch-1")
        self.assertEqual(event["item_id"], "item-1")
        self.assertEqual(event["customer_id"], "customer-1")
        self.assertNotIn("passport_number", event)
        self.assertNotIn("pin_value", event)

    def test_process_batch_writes_unique_match_and_logs_no_pin(self) -> None:
        message = parse_message(self._message_bytes("AA100", "SECRET-PIN", "one"))
        supabase = _FakeSupabase()
        worker = GmailPinWorker.__new__(GmailPinWorker)
        worker.config = SimpleNamespace(gmail_lookback_days=7)
        worker.supabase = supabase
        worker.gmail = _FakeGmail([message])

        with self.assertLogs("gmail_pin_worker", level=logging.INFO) as captured:
            processed = worker.process_batch(
                {
                    "id": "batch-1",
                    "gmail_settings_snapshot": {"gmail_address": "test@gmail.com"},
                }
            )

        self.assertEqual(processed, 1)
        self.assertEqual(supabase.finished[0]["pin_status"], "RECEIVED")
        self.assertEqual(supabase.finished[0]["pin_value"], "SECRET-PIN")
        self.assertNotIn("SECRET-PIN", "\n".join(captured.output))

    def test_process_batch_surfaces_writeback_failure(self) -> None:
        message = parse_message(self._message_bytes("AA100", "SECRET-PIN", "one"))
        supabase = _FakeSupabase(fail_writeback=True)
        worker = GmailPinWorker.__new__(GmailPinWorker)
        worker.config = SimpleNamespace(gmail_lookback_days=7)
        worker.supabase = supabase
        worker.gmail = _FakeGmail([message])

        with self.assertLogs("gmail_pin_worker", level=logging.ERROR) as captured:
            with self.assertRaises(RuntimeError):
                worker.process_batch(
                    {
                        "id": "batch-1",
                        "gmail_settings_snapshot": {
                            "gmail_address": "test@gmail.com"
                        },
                    }
                )

        self.assertIn("SUPABASE_WRITEBACK_FAILED", "\n".join(captured.output))
        self.assertNotIn("SECRET-PIN", "\n".join(captured.output))

    @staticmethod
    def _message_bytes(passport: str, pin: str | None, suffix: str) -> bytes:
        message = EmailMessage()
        message["Message-ID"] = f"<{suffix}@example.test>"
        message["From"] = "mdac@imi.gov.my"
        message["Subject"] = "MDAC PIN"
        pin_line = f"PIN : {pin}\n" if pin is not None else "Thank you\n"
        message.set_content(
            f"Name : TEST PERSON\nPassport No. : {passport}\n{pin_line}"
        )
        return message.as_bytes()


class _FakeGmail:
    def __init__(self, messages: list) -> None:
        self.messages = messages

    def fetch_recent(self, gmail_address: str, app_password: str) -> list:
        return self.messages


class _FakeSupabase:
    def __init__(self, *, fail_writeback: bool = False) -> None:
        self.items = [
            {
                "id": "item-1",
                "customer_id": "customer-1",
                "customer_snapshot": {"passport_number": "AA100"},
            }
        ]
        self.finished: list[dict] = []
        self.fail_writeback = fail_writeback

    def heartbeat(self, **kwargs) -> None:
        return None

    def get_gmail_runtime_credentials(self) -> dict[str, str]:
        return {
            "gmail_address": "test@gmail.com",
            "gmail_app_password": "not-logged",
        }

    def claim_item(self, batch_id: str) -> dict | None:
        return self.items.pop(0) if self.items else None

    def finish_item(self, **kwargs) -> dict:
        if self.fail_writeback:
            raise RuntimeError("writeback failed")
        self.finished.append(kwargs)
        return {"ok": True}


if __name__ == "__main__":
    unittest.main()
