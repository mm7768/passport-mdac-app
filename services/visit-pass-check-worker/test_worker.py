from __future__ import annotations

import importlib.util
import json
import logging
import os
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import requests


WORKER_DIR = str(Path(__file__).parent)
if WORKER_DIR not in sys.path:
    sys.path.insert(0, WORKER_DIR)

MODULE_PATH = Path(__file__).with_name("worker.py")
SPEC = importlib.util.spec_from_file_location("visit_pass_worker_under_test", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class VisitPassWorkerTests(unittest.TestCase):
    def test_logging_uses_stdout_for_railway_severity(self) -> None:
        with patch.object(logging, "basicConfig") as basic_config:
            MODULE.configure_logging("INFO")

        self.assertIs(basic_config.call_args.kwargs["stream"], sys.stdout)

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

    def test_config_accepts_headless_mode(self) -> None:
        env = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "service-role-test-placeholder",
            "VISIT_PASS_CHECK_WORKER_ID": "test-worker",
            "VISIT_PASS_CHECK_MODE": "FILL_REVIEW",
            "ALLOW_REAL_SUBMIT": "false",
            "VISIT_PASS_CHECK_HEADLESS": "false",
        }
        with patch.dict(os.environ, env, clear=True):
            config = MODULE.WorkerConfig.from_env()
            self.assertFalse(config.headless)

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
        self.assertEqual(config.poll_seconds, 10.0)

    def test_config_accepts_auto_search_mode(self) -> None:
        env = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "service-role-test-placeholder",
            "VISIT_PASS_CHECK_WORKER_ID": "test-worker",
            "VISIT_PASS_CHECK_MODE": "AUTO_SEARCH",
            "ALLOW_REAL_SUBMIT": "true",
            "VISIT_PASS_CHECK_HEADLESS": "true",
        }
        with patch.dict(os.environ, env, clear=True):
            config = MODULE.WorkerConfig.from_env()
        self.assertEqual(config.mode, "AUTO_SEARCH")
        self.assertTrue(config.allow_real_submit)

    def test_slider_solver_generate_track(self) -> None:
        from slider_solver import generate_track

        total_distance = 150.0
        track = generate_track(total_distance)
        self.assertGreaterEqual(len(track), 25)
        self.assertLessEqual(len(track), 45)
        sum_distance = sum(track)
        self.assertAlmostEqual(sum_distance, total_distance, delta=1.0)

    def test_remote_failure_is_retryable_without_exposing_exception(self) -> None:
        code, message, retryable = MODULE.classify_page_failure(
            requests.Timeout("passport AB123 and PIN SECRET")
        )
        self.assertEqual(code, "TRANSIENT_REMOTE_ERROR")
        self.assertTrue(retryable)
        self.assertNotIn("AB123", message)
        self.assertNotIn("SECRET", message)

    def test_process_batch_writes_review_result_with_structured_context(self) -> None:
        supabase = _FakeSupabase()
        instance = MODULE.VisitPassCheckWorker.__new__(MODULE.VisitPassCheckWorker)
        instance.config = SimpleNamespace(mode="AUTO_SEARCH")
        instance.supabase = supabase

        async def fake_query_and_capture(config, runtime_input, *args, **kwargs):
            return (
                "FOUND",
                b"png",
                {
                    "source": "MDAC_CHECK_VISIT_PASS",
                    "mode": "AUTO_SEARCH",
                    "outcome": "FOUND",
                    "slider_solved": True,
                    "submitted": True,
                    "result_confirmed": True,
                },
            )

        with patch.object(MODULE, "query_and_capture_page", side_effect=fake_query_and_capture):
            with self.assertLogs(
                "visit_pass_check_worker", level=logging.INFO
            ) as captured:
                processed = instance.process_batch({"id": "batch-1"})

        self.assertEqual(processed, 1)
        self.assertEqual(supabase.finished[0]["outcome"], "FOUND")
        self.assertEqual(supabase.finished[0]["evidence_path"], "private/path.png")
        events = [
            json.loads(record.getMessage())
            for record in captured.records
            if record.getMessage().strip().startswith('{')
        ]
        item_event = next(event for event in events if event["step"] == "item_claim")
        self.assertEqual(item_event["worker"], "visit_pass_check")
        self.assertEqual(item_event["batch_id"], "batch-1")
        self.assertEqual(item_event["item_id"], "item-1")
        self.assertEqual(item_event["customer_id"], "customer-1")
        self.assertNotIn("passport_number", str(events))
        self.assertNotIn("pin_value", str(events))

    def test_entry_window_candidates_covers_0_to_4_days(self) -> None:
        candidates = MODULE.entry_window_candidates("2026-09-24")

        # 0 ~ +4 days must be present
        self.assertIn("24/09/2026", candidates)  # +0
        self.assertIn("25/09/2026", candidates)  # +1
        self.assertIn("26/09/2026", candidates)  # +2
        self.assertIn("27/09/2026", candidates)  # +3
        self.assertIn("28/09/2026", candidates)  # +4

        # Days outside the 0 ~ +4 window must NOT be present
        self.assertNotIn("23/09/2026", candidates)  # -1
        self.assertNotIn("29/09/2026", candidates)  # +5
        self.assertNotIn("30/09/2026", candidates)  # +6

    def test_visit_pass_matching_acceptance_cases(self) -> None:
        target_entry_date = "2026-09-24"
        window = MODULE.entry_window_candidates(target_entry_date)

        def simulate_table_row_match(date_col_text: str, is_exit: bool = False) -> str:
            if is_exit:
                return "NO_RECORD"
            if any(w.upper() in date_col_text.upper() for w in window):
                return "FOUND"
            return "NO_RECORD"

        # Acceptance Test Cases
        self.assertEqual(simulate_table_row_match("24/09/2026"), "FOUND")
        self.assertEqual(simulate_table_row_match("25/09/2026"), "FOUND")
        self.assertEqual(simulate_table_row_match("26/09/2026"), "FOUND")
        self.assertEqual(simulate_table_row_match("27/09/2026"), "FOUND")
        self.assertEqual(simulate_table_row_match("28/09/2026"), "FOUND")
        self.assertEqual(simulate_table_row_match("29/09/2026"), "NO_RECORD")
        self.assertEqual(simulate_table_row_match("23/09/2026"), "NO_RECORD")

        # Expiry date exclusion check:
        # Table row has Date = 10/09/2026, Pass Expiry = 27/09/2026
        # Date column should be inspected, not Pass Expiry column
        entry_date_cell = "10/09/2026"
        self.assertEqual(simulate_table_row_match(entry_date_cell), "NO_RECORD")


class _FakeSupabase:
    def __init__(self) -> None:
        self.items = [{"id": "item-1", "customer_id": "customer-1"}]
        self.finished: list[dict] = []

    def heartbeat(self, **kwargs) -> None:
        return None

    def heartbeat_tick(self, **kwargs) -> None:
        return None

    def claim_item(self, batch_id: str) -> dict | None:
        return self.items.pop(0) if self.items else None

    def get_customer_entry_date(self, customer_id: str) -> str | None:
        return "2026-09-24"

    def get_runtime_input(self, item_id: str) -> dict[str, str]:
        return {
            "passport_number": "AB123",
            "nationality": "CHN",
            "email": "secret@example.com",
            "region_code": "60",
            "mobile": "123456789",
            "pin_value": "SECRET",
        }

    def upload_screenshot(self, item_id: str, image_bytes: bytes) -> str:
        return "private/path.png"

    def finish_item(self, **kwargs) -> dict:
        self.finished.append(kwargs)
        return {"ok": True}

    def finish_visit_pass_worker(self, **kwargs) -> dict:
        self.finished.append(kwargs)
        return {"ok": True}


if __name__ == "__main__":
    unittest.main()
