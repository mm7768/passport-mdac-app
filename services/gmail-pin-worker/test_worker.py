from __future__ import annotations

import unittest
from email.message import EmailMessage

from worker import (
    decide_for_item,
    normalize_pin,
    parse_message,
    resolve_gmail_address,
)


class GMailPinParsingTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
