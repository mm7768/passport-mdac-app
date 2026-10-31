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
    def test_logging_uses_stdout_for_railway_severity(self) -> None:
        with patch.object(logging, "basicConfig") as basic_config:
            worker.configure_logging("INFO")

        self.assertIs(basic_config.call_args.kwargs["stream"], sys.stdout)

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

    def test_config_accepts_auto_search_mode(self) -> None:
        values = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "not-a-real-key",
            "REGISTRATION_CHECK_WORKER_ID": "test-worker",
            "REGISTRATION_CHECK_MODE": "AUTO_SEARCH",
            "ALLOW_REAL_SUBMIT": "true",
            "REGISTRATION_CHECK_HEADLESS": "true",
        }
        with patch.dict(os.environ, values, clear=False):
            config = worker.WorkerConfig.from_env()
        self.assertEqual(config.mode, "AUTO_SEARCH")
        self.assertTrue(config.allow_real_submit)

    def test_date_candidates_and_check_dates_match(self) -> None:
        cands = worker.date_candidates("2026-09-10")
        self.assertIn("10/09/2026", cands)
        self.assertIn("10-09-2026", cands)
        self.assertIn("2026-09-10", cands)
        self.assertIn("10 Sep 2026", cands)

        sample_page = "Registration Details: Date of Arrival: 10/09/2026, Departure: 15/09/2026"
        self.assertTrue(worker.check_dates_match(sample_page, "2026-09-10", "2026-09-15"))
        self.assertTrue(worker.check_dates_match(sample_page, "2026-09-10", None))
        self.assertFalse(worker.check_dates_match(sample_page, "2025-01-01", "2025-01-05"))

    def test_slider_solver_generate_track(self) -> None:
        from slider_solver import generate_track

        total_distance = 150.0
        track = generate_track(total_distance)
        self.assertGreaterEqual(len(track), 30)
        self.assertLessEqual(len(track), 40)
        sum_distance = sum(track)
        self.assertAlmostEqual(sum_distance, total_distance, delta=1.0)

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

        async def fake_query_and_capture(config, runtime_input, target_entry_date=None, target_exit_date=None):
            return (
                "FOUND",
                b"%PDF-1.4",
                "pdf",
                worker.make_preview_summary(
                    challenge_type="CAPTCHA_SLIDER",
                    field_checks={"passNo": True},
                    screenshot_saved=True,
                ),
            )

        with patch.object(worker, "query_and_capture_page", side_effect=fake_query_and_capture):
            with self.assertLogs(
                "registration_check_worker", level=logging.INFO
            ) as captured:
                processed = instance.process_batch({"id": "batch-1"})

        self.assertEqual(processed, 1)
        self.assertEqual(supabase.finished[0]["outcome"], "FOUND")
        self.assertEqual(supabase.finished[0]["evidence_path"], "private/path.pdf")
        events = [json.loads(record.getMessage()) for record in captured.records]
        item_event = next(event for event in events if event["step"] == "item_claim")
        self.assertEqual(item_event["worker"], "registration_check")
        self.assertEqual(item_event["batch_id"], "batch-1")
        self.assertEqual(item_event["item_id"], "item-1")
        self.assertEqual(item_event["customer_id"], "customer-1")
        self.assertNotIn("passport_number", str(events))
        self.assertNotIn("pin_value", str(events))


    def test_compute_slot_window_geometry_quadrants(self) -> None:
        for slot in (1, 2, 3, 4):
            pos, size = worker.compute_slot_window_geometry(slot)
            x, y = map(int, pos.split(","))
            w, h = map(int, size.split(","))
            self.assertGreaterEqual(x, 0)
            self.assertGreaterEqual(y, 0)
            self.assertGreater(w, 300)
            self.assertGreater(h, 200)

    def test_compute_slot_window_geometry_env_override(self) -> None:
        env_override = {
            "REGISTRATION_CHECK_SLOT_2_POSITION": "120,240",
            "REGISTRATION_CHECK_SLOT_2_SIZE": "520,620",
        }
        with patch.dict(os.environ, env_override):
            pos, size = worker.compute_slot_window_geometry(2)
            self.assertEqual(pos, "120,240")
            self.assertEqual(size, "520,620")

    def test_config_reads_concurrency_and_fault_tolerance_defaults(self) -> None:
        base_env = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "service-role-test-placeholder",
            "REGISTRATION_CHECK_WORKER_ID": "test-worker",
            "REGISTRATION_CHECK_MODE": "AUTO_SEARCH",
            "ALLOW_REAL_SUBMIT": "true",
            "REGISTRATION_CHECK_HEADLESS": "false",
        }
        with patch.dict(os.environ, base_env, clear=True):
            cfg = worker.WorkerConfig.from_env()
            self.assertEqual(cfg.concurrency, 4)
            self.assertEqual(cfg.slot_stagger_seconds, 1.5)
            self.assertEqual(cfg.query_wait_seconds, 45)
            self.assertEqual(cfg.query_grace_seconds, 15)
            self.assertEqual(cfg.max_local_attempts, 2)

    def test_process_batch_concurrent_4_slots(self) -> None:
        supabase = _FakeSupabase()
        supabase.items = [
            {"id": f"item-{i}", "customer_id": f"customer-{i}"}
            for i in range(1, 5)
        ]
        instance = worker.RegistrationCheckWorker.__new__(worker.RegistrationCheckWorker)
        instance.config = SimpleNamespace(
            concurrency=4,
            slot_stagger_seconds=0.0,
            max_local_attempts=2,
            mode="AUTO_SEARCH",
        )
        instance.supabase = supabase

        async def fake_query(config, runtime_input, target_entry_date=None, target_exit_date=None, slot_id=1):
            return ("FOUND", b"%PDF-1.4", "pdf", {"challenge_type": None, "screenshot_saved": False})

        with patch.object(worker, "query_and_capture_page", side_effect=fake_query):
            processed = instance.process_batch({"id": "batch-concurrent", "claim_token": "b-tok"})

        self.assertEqual(processed, 4)
        self.assertEqual(len(supabase.finished), 4)
        outcomes = [r["outcome"] for r in supabase.finished]
        self.assertEqual(outcomes, ["FOUND", "FOUND", "FOUND", "FOUND"])

    def test_process_batch_local_retry_on_query_timeout(self) -> None:
        supabase = _FakeSupabase()
        supabase.items = [{"id": "item-retry", "customer_id": "cust-retry"}]
        instance = worker.RegistrationCheckWorker.__new__(worker.RegistrationCheckWorker)
        instance.config = SimpleNamespace(
            concurrency=1,
            slot_stagger_seconds=0.0,
            max_local_attempts=2,
            mode="AUTO_SEARCH",
        )
        instance.supabase = supabase

        attempts = 0
        async def mock_query(*args, **kwargs):
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                return ("QUERY_TIMEOUT", b"png", "png", {"outcome": "QUERY_TIMEOUT", "error": "QUERY_TIMEOUT"})
            return ("FOUND", b"%PDF-1.4", "pdf", {"outcome": "FOUND"})

        with patch.object(worker, "query_and_capture_page", side_effect=mock_query), patch("time.sleep"):
            processed = instance.process_batch({"id": "batch-retry", "claim_token": "tok"})

        self.assertEqual(processed, 1)
        self.assertEqual(attempts, 2)
        self.assertEqual(len(supabase.finished), 1)
        self.assertEqual(supabase.finished[0]["outcome"], "FOUND")

    def test_fetch_official_pdf_tier1_in_page_fetch(self) -> None:
        import asyncio, base64
        from unittest.mock import AsyncMock, MagicMock

        mock_page = AsyncMock()
        fake_pdf = b"%PDF-1.4 Official Slip Content"
        mock_page.evaluate.return_value = base64.b64encode(fake_pdf).decode("utf-8")
        mock_context = MagicMock()

        pdf_bytes = asyncio.run(
            worker.fetch_official_pdf_with_fallbacks(
                page=mock_page,
                context=mock_context,
                target_trip_id="TRIP123456",
                slot_id=1,
            )
        )
        self.assertEqual(pdf_bytes, fake_pdf)
        self.assertTrue(mock_page.evaluate.called)

    def test_fetch_official_pdf_tier2_context_request(self) -> None:
        import asyncio
        from unittest.mock import AsyncMock, MagicMock

        mock_page = AsyncMock()
        # Tier 1 returns None
        mock_page.evaluate.return_value = None

        mock_resp = AsyncMock()
        mock_resp.ok = True
        fake_pdf = b"%PDF-1.4 Tier 2 Content"
        mock_resp.body.return_value = fake_pdf

        mock_context = MagicMock()
        mock_context.request = AsyncMock()
        mock_context.request.post.return_value = mock_resp

        pdf_bytes = asyncio.run(
            worker.fetch_official_pdf_with_fallbacks(
                page=mock_page,
                context=mock_context,
                target_trip_id="TRIP789",
                slot_id=2,
            )
        )
        self.assertEqual(pdf_bytes, fake_pdf)
        self.assertTrue(mock_context.request.post.called)

    def test_fetch_official_pdf_tier3_expect_download(self) -> None:
        import asyncio, tempfile
        from unittest.mock import AsyncMock, MagicMock

        mock_page = AsyncMock()
        # Tier 1 returns None
        mock_page.evaluate.return_value = None

        mock_context = MagicMock()
        # Tier 2 fails
        mock_context.request = AsyncMock()
        mock_context.request.post.side_effect = Exception("API error")

        fake_pdf = b"%PDF-1.4 Tier 3 Content"
        temp_f = tempfile.NamedTemporaryFile(delete=False)
        temp_f.write(fake_pdf)
        temp_f.close()

        mock_dl = AsyncMock()
        mock_dl.path.return_value = temp_f.name

        class FakeEventInfo:
            def __init__(self, dl):
                f = asyncio.Future()
                f.set_result(dl)
                self.value = f

        class FakeDownloadContext:
            def __init__(self, dl):
                self.dl = dl
            async def __aenter__(self):
                return FakeEventInfo(self.dl)
            async def __aexit__(self, exc_type, exc_val, exc_tb):
                pass

        mock_page.expect_download = MagicMock(return_value=FakeDownloadContext(mock_dl))

        mock_link = AsyncMock()
        mock_link.count.return_value = 1

        pdf_bytes = asyncio.run(
            worker.fetch_official_pdf_with_fallbacks(
                page=mock_page,
                context=mock_context,
                target_trip_id="TRIP000",
                link_locator=mock_link,
                slot_id=3,
            )
        )
        self.assertEqual(pdf_bytes, fake_pdf)
        os.unlink(temp_f.name)

    def test_fetch_official_pdf_all_fail_returns_none(self) -> None:
        import asyncio
        from unittest.mock import AsyncMock, MagicMock

        mock_page = AsyncMock()
        mock_page.evaluate.return_value = None
        mock_page.expect_download = MagicMock(side_effect=Exception("Download failed"))

        mock_context = MagicMock()
        mock_context.request = AsyncMock()
        mock_context.request.post.side_effect = Exception("Network error")

        pdf_bytes = asyncio.run(
            worker.fetch_official_pdf_with_fallbacks(
                page=mock_page,
                context=mock_context,
                target_trip_id="TRIP_FAIL",
                slot_id=4,
            )
        )
        self.assertIsNone(pdf_bytes)

class _FakeSupabase:
    def __init__(self) -> None:
        self.items = [{"id": "item-1", "customer_id": "customer-1"}]
        self.finished: list[dict] = []

    def heartbeat(self, **kwargs) -> None:
        return None

    def heartbeat_tick(self, **kwargs) -> None:
        return None

    def claim_item(self, batch_id: str, **kwargs) -> dict | None:
        return self.items.pop(0) if self.items else None

    def get_runtime_input(self, item_id: str) -> dict[str, str]:
        return {
            "passport_number": "AB123",
            "nationality": "CHN",
            "pin_value": "SECRET",
        }

    def upload_evidence(self, item_id: str, evidence_bytes: bytes, ext: str) -> str:
        return f"private/path.{ext}"

    def finish_check_worker(self, **kwargs) -> dict:
        self.finished.append(kwargs)
        return {"ok": True}


if __name__ == "__main__":
    unittest.main()
