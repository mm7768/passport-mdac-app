from __future__ import annotations

import importlib.util
import json
import logging
import os
import pathlib
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import requests


MODULE_PATH = pathlib.Path(__file__).with_name("worker.py")
spec = importlib.util.spec_from_file_location("registration_check_worker", MODULE_PATH)
assert spec and spec.loader
worker = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = worker
spec.loader.exec_module(worker)


class RegistrationCheckWorkerTests(unittest.TestCase):
    def test_normalization(self) -> None:
        self.assertEqual(worker.normalize_passport(" ab 123 "), "AB 123")
        self.assertEqual(worker.normalize_nationality(" chn "), "CHN")
        self.assertEqual(worker.normalize_pin(" 12  34 "), "12  34")
        self.assertIsNone(worker.normalize_pin("   "))

    def test_challenge_requires_real_official_structure(self) -> None:
        self.assertIsNone(worker.challenge_type_from_markup("<div id='sliderContainer'></div>"))
        self.assertIsNone(worker.challenge_type_from_markup("<canvas></canvas><canvas></canvas>"))
        markup = (
            "<div class='sliderContainer'>Drag To Verify</div>"
            "<canvas></canvas><canvas></canvas>"
        )
        self.assertEqual(worker.challenge_type_from_markup(markup), "CAPTCHA_SLIDER")

    def test_preview_summary_has_no_sensitive_values(self) -> None:
        summary = worker.make_preview_summary(
            challenge_type="CAPTCHA_SLIDER",
            field_checks={"passNo": True, "nationality": True, "pinKeyId": True},
            screenshot_saved=True,
        )
        self.assertEqual(summary["challenge_type"], "CAPTCHA_SLIDER")
        self.assertFalse(summary["submitted"])
        self.assertFalse(summary["result_confirmed"])
        self.assertFalse(summary["captcha_bypass"])
        self.assertNotIn("AB123456", str(summary))
        self.assertNotIn("12345678", str(summary))

    def test_config_requires_fill_review_and_headless(self) -> None:
        values = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "not-a-real-key",
            "REGISTRATION_CHECK_WORKER_ID": "test-worker",
            "REGISTRATION_CHECK_MODE": "FILL_REVIEW",
            "ALLOW_REAL_SUBMIT": "false",
            "REGISTRATION_CHECK_HEADLESS": "true",
        }
        with patch.dict(os.environ, values, clear=False):
            config = worker.WorkerConfig.from_env()
        self.assertEqual(config.worker_id, "test-worker")
        self.assertTrue(config.check_url.endswith("viewRegistration"))

    def test_config_rejects_submit_mode(self) -> None:
        values = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "not-a-real-key",
            "REGISTRATION_CHECK_WORKER_ID": "test-worker",
            "REGISTRATION_CHECK_MODE": "FILL_REVIEW",
            "ALLOW_REAL_SUBMIT": "true",
            "REGISTRATION_CHECK_HEADLESS": "true",
        }
        with patch.dict(os.environ, values, clear=False):
            with self.assertRaises(worker.WorkerError):
                worker.WorkerConfig.from_env()

    def test_source_contains_no_submit_or_drag_invocation(self) -> None:
        source = MODULE_PATH.read_text(encoding="utf-8")
        forbidden = (
            "page.click(",
            "page.submit(",
            "form.submit(",
            "press(\"Enter\")",
            "slider.drag",
        )
        for token in forbidden:
            self.assertNotIn(token, source)

    def test_remote_failure_is_retryable_without_exposing_exception(self) -> None:
        code, message, retryable = worker.classify_page_failure(
            requests.Timeout("passport AB123 and PIN SECRET")
        )
        self.assertEqual(code, "TRANSIENT_REMOTE_ERROR")
        self.assertTrue(retryable)
        self.assertNotIn("AB123", message)
        self.assertNotIn("SECRET", message)

    def test_process_batch_writes_review_result_with_structured_context(self) -> None:
        supabase = _FakeSupabase()
        instance = worker.RegistrationCheckWorker.__new__(
            worker.RegistrationCheckWorker
        )
        instance.config = SimpleNamespace()
        instance.supabase = supabase

        async def fake_preview(config, runtime_input):
            return (
                b"png",
                "CAPTCHA_SLIDER",
                worker.make_preview_summary(
                    challenge_type="CAPTCHA_SLIDER",
                    field_checks={"passNo": True},
                    screenshot_saved=True,
                ),
            )

        with patch.object(worker, "preview_page", side_effect=fake_preview):
            with self.assertLogs(
                "registration_check_worker", level=logging.INFO
            ) as captured:
                processed = instance.process_batch({"id": "batch-1"})

        self.assertEqual(processed, 1)
        self.assertEqual(supabase.finished[0]["check_status"], "UNPARSED")
        self.assertTrue(supabase.finished[0]["result_unknown"])
        events = [json.loads(record.getMessage()) for record in captured.records]
        item_event = next(event for event in events if event["step"] == "item_claim")
        self.assertEqual(item_event["worker"], "registration_check")
        self.assertEqual(item_event["batch_id"], "batch-1")
        self.assertEqual(item_event["item_id"], "item-1")
        self.assertEqual(item_event["customer_id"], "customer-1")
        self.assertNotIn("passport_number", str(events))
        self.assertNotIn("pin_value", str(events))


class _FakeSupabase:
    def __init__(self) -> None:
        self.items = [{"id": "item-1", "customer_id": "customer-1"}]
        self.finished: list[dict] = []

    def heartbeat(self, **kwargs) -> None:
        return None

    def claim_item(self, batch_id: str) -> dict | None:
        return self.items.pop(0) if self.items else None

    def get_runtime_input(self, item_id: str) -> dict[str, str]:
        return {
            "passport_number": "AB123",
            "nationality": "CHN",
            "pin_value": "SECRET",
        }

    def upload_screenshot(self, item_id: str, image_bytes: bytes) -> str:
        return "private/path.png"

    def finish_item(self, **kwargs) -> dict:
        self.finished.append(kwargs)
        return {"ok": True}


if __name__ == "__main__":
    unittest.main()
