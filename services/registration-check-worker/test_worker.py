from __future__ import annotations

import importlib.util
import os
import pathlib
import sys
import unittest
from unittest.mock import patch


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


if __name__ == "__main__":
    unittest.main()
