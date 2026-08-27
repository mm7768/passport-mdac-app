from __future__ import annotations

import importlib.util
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name("worker.py")
SPEC = importlib.util.spec_from_file_location("visit_pass_worker_under_test", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class VisitPassWorkerTests(unittest.TestCase):
    def test_normalize_inputs(self) -> None:
        self.assertEqual(MODULE.normalize_passport(" ab123 "), "AB123")
        self.assertEqual(MODULE.normalize_nationality(" chn "), "CHN")
        self.assertEqual(MODULE.normalize_email(" Test@Example.COM "), "test@example.com")
        self.assertEqual(MODULE.normalize_region_code("60"), "60")
        self.assertEqual(MODULE.normalize_mobile("+6012-3456789"), "+6012-3456789")
        self.assertEqual(MODULE.normalize_mobile("abc"), "")

    def test_pin_trims_outer_whitespace_only(self) -> None:
        self.assertEqual(MODULE.normalize_pin(" 12  34 "), "12  34")
        self.assertIsNone(MODULE.normalize_pin("   "))
        self.assertIsNone(MODULE.normalize_pin(None))

    def test_detects_official_slider_structure(self) -> None:
        markup = """
        <div id='captcha'><canvas></canvas><canvas class='block'></canvas>
        <div class='sliderContainer'><span>Drag To Verify</span></div></div>
        """
        self.assertEqual(MODULE.challenge_type_from_markup(markup), "CAPTCHA_SLIDER")

    def test_does_not_flag_empty_challenge_container(self) -> None:
        markup = "<div id='captcha'></div><span>Drag To Verify</span>"
        self.assertIsNone(MODULE.challenge_type_from_markup(markup))

    def test_summary_is_fill_review_and_contains_no_secret_values(self) -> None:
        summary = MODULE.make_preview_summary(
            challenge_type="CAPTCHA_SLIDER",
            field_checks={"passNo": True, "nationality": True, "email": True},
            screenshot_saved=True,
        )
        self.assertEqual(summary["source"], "MDAC_CHECK_VISIT_PASS")
        self.assertEqual(summary["mode"], "FILL_REVIEW")
        self.assertFalse(summary["submitted"])
        self.assertFalse(summary["result_confirmed"])
        self.assertFalse(summary["captcha_bypass"])
        self.assertFalse(summary["result_page_read"])
        self.assertFalse(summary["movement_record_read"])
        self.assertNotIn("pin_value", summary)
        self.assertNotIn("email_address", summary)

    def test_config_rejects_submit_mode(self) -> None:
        env = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "service-role-test-placeholder",
            "VISIT_PASS_CHECK_WORKER_ID": "test-worker",
            "VISIT_PASS_CHECK_MODE": "SUBMIT",
            "ALLOW_REAL_SUBMIT": "false",
            "VISIT_PASS_CHECK_HEADLESS": "true",
        }
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaises(MODULE.WorkerError):
                MODULE.WorkerConfig.from_env()

    def test_config_rejects_true_submit_switch(self) -> None:
        env = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "service-role-test-placeholder",
            "VISIT_PASS_CHECK_WORKER_ID": "test-worker",
            "VISIT_PASS_CHECK_MODE": "FILL_REVIEW",
            "ALLOW_REAL_SUBMIT": "true",
            "VISIT_PASS_CHECK_HEADLESS": "true",
        }
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaises(MODULE.WorkerError):
                MODULE.WorkerConfig.from_env()

    def test_config_requires_headless_mode(self) -> None:
        env = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "service-role-test-placeholder",
            "VISIT_PASS_CHECK_WORKER_ID": "test-worker",
            "VISIT_PASS_CHECK_MODE": "FILL_REVIEW",
            "ALLOW_REAL_SUBMIT": "false",
            "VISIT_PASS_CHECK_HEADLESS": "false",
        }
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaises(MODULE.WorkerError):
                MODULE.WorkerConfig.from_env()

    def test_config_accepts_safe_defaults(self) -> None:
        env = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "service-role-test-placeholder",
            "VISIT_PASS_CHECK_WORKER_ID": "test-worker",
            "VISIT_PASS_CHECK_MODE": "FILL_REVIEW",
            "ALLOW_REAL_SUBMIT": "false",
            "VISIT_PASS_CHECK_HEADLESS": "true",
        }
        with patch.dict(os.environ, env, clear=True):
            config = MODULE.WorkerConfig.from_env()
        self.assertEqual(config.check_url, MODULE.DEFAULT_CHECK_URL)
        self.assertEqual(config.screenshot_bucket, MODULE.DEFAULT_BUCKET)
        self.assertEqual(config.poll_seconds, 30.0)


if __name__ == "__main__":
    unittest.main()
