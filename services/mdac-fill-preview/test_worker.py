from __future__ import annotations

import os
import sys
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from worker import (
    WorkerConfig,
    WorkerError,
    map_gender,
    map_mdac_fields,
    normalize_mdac_settings,
    parse_date,
)


class FillPreviewWorkerTests(unittest.TestCase):
    def base_config(self) -> WorkerConfig:
        return WorkerConfig(
            supabase_url="https://example.supabase.co",
            service_role_key="service-role-test-only",
            worker_id="test-worker",
            execution_mode="FILL_PREVIEW",
            allow_real_submit=False,
            mdac_url="https://example.test/mdac/main?registerMain",
            poll_seconds=15,
            lease_seconds=900,
            max_attempts=5,
            request_timeout_seconds=30,
            page_timeout_ms=60000,
            screenshot_bucket="passport-documents",
            screenshot_prefix="mdac-previews",
            headless=True,
            log_level="INFO",
        )

    def settings_snapshot(self, pob_mode: str = "NATIONALITY") -> dict[str, str]:
        return normalize_mdac_settings(
            {
                "mdac_email": "operator@example.test",
                "mdac_phone": "60123456789",
                "region_code": "60",
                "travel_mode": "2",
                "embark_country": "CHN",
                "vessel": "TEST FLIGHT",
                "accommodation_stay": "02",
                "address1": "TEST ADDRESS 1",
                "address2": "TEST ADDRESS 2",
                "state_code": "01",
                "city_code": "0100",
                "postcode": "50000",
                "pob_mode": pob_mode,
            }
        )

    def test_custom_region_code_accepted(self) -> None:
        for code in ["60", "86", "65", "852", "1"]:
            raw = {
                "mdac_email": "operator@example.test",
                "mdac_phone": "13800138000",
                "region_code": code,
                "travel_mode": "2",
                "embark_country": "CHN",
                "vessel": "TEST FLIGHT",
                "accommodation_stay": "02",
                "address1": "TEST ADDRESS 1",
                "state_code": "01",
                "city_code": "0100",
                "postcode": "50000",
                "pob_mode": "NATIONALITY",
            }
            res = normalize_mdac_settings(raw)
            self.assertEqual(res["region_code"], code)

    def test_invalid_region_code_rejected(self) -> None:
        for invalid_code in ["abc", "12345", "60a"]:
            raw = {
                "mdac_email": "operator@example.test",
                "mdac_phone": "13800138000",
                "region_code": invalid_code,
                "travel_mode": "2",
                "embark_country": "CHN",
                "vessel": "TEST FLIGHT",
                "accommodation_stay": "02",
                "address1": "TEST ADDRESS 1",
                "state_code": "01",
                "city_code": "0100",
                "postcode": "50000",
                "pob_mode": "NATIONALITY",
            }
            with self.assertRaisesRegex(WorkerError, "地区代码"):
                normalize_mdac_settings(raw)

    def test_maps_snapshot_to_official_selectors(self) -> None:
        snapshot = {
            "full_name": "  TEST PERSON ",
            "passport_number": " ab123456 ",
            "date_of_birth": "1990-01-02",
            "place_of_birth": "CHINA",
            "nationality": "chn",
            "gender": "女",
            "passport_expiry_date": "2030-03-04",
        }
        batch = {"entry_date": "2026-09-01", "exit_date": "2026-09-10"}
        fields = map_mdac_fields(snapshot, batch, self.settings_snapshot())
        self.assertEqual(fields["#region"], "60")
        self.assertEqual(fields["#nationality"], "CHN")
        self.assertEqual(fields["#pob"], "CHN")
        self.assertEqual(fields["#sex"], "2")
        self.assertEqual(fields["#name"], "TEST PERSON")
        self.assertEqual(fields["#passNo"], "AB123456")
        self.assertEqual(fields["#dob"], "02/01/1990")
        self.assertEqual(fields["#passExpDte"], "04/03/2030")
        self.assertEqual(fields["#arrDt"], "01/09/2026")
        self.assertEqual(fields["#depDt"], "10/09/2026")

    def test_customer_place_of_birth_mode_is_explicit(self) -> None:
        snapshot = {
            "full_name": "TEST PERSON",
            "passport_number": "AB123456",
            "date_of_birth": "1990-01-02",
            "place_of_birth": "MYS",
            "nationality": "CHN",
            "gender": "男",
            "passport_expiry_date": "2030-03-04",
        }
        batch = {"entry_date": "2026-09-01", "exit_date": "2026-09-10"}
        fields = map_mdac_fields(snapshot, batch, self.settings_snapshot("CUSTOMER"))
        self.assertEqual(fields["#pob"], "MYS")

    def test_exit_date_must_not_precede_entry_date(self) -> None:
        snapshot = {
            "full_name": "TEST PERSON",
            "passport_number": "AB123456",
            "date_of_birth": "1990-01-02",
            "nationality": "CHN",
            "gender": "男",
            "passport_expiry_date": "2030-03-04",
        }
        batch = {"entry_date": "2026-09-10", "exit_date": "2026-09-01"}
        with self.assertRaisesRegex(ValueError, "出境日期不能早于入境日期"):
            map_mdac_fields(snapshot, batch, self.settings_snapshot())

    def test_invalid_date_and_gender_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            parse_date("31/02/2026")
        with self.assertRaisesRegex(ValueError, "未知性别"):
            map_gender("X")

    def test_worker_refuses_missing_or_unsafe_mode(self) -> None:
        env = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "service-role-test-only",
            "MDAC_WORKER_ID": "test-worker",
            "MDAC_EXECUTION_MODE": "FILL_PREVIEW",
            "ALLOW_REAL_SUBMIT": "false",
        }
        with patch.dict(os.environ, env, clear=True):
            config = WorkerConfig.from_env()
            self.assertEqual(config.execution_mode, "FILL_PREVIEW")
            self.assertFalse(config.allow_real_submit)

        unsafe = dict(env)
        unsafe["ALLOW_REAL_SUBMIT"] = "true"
        with patch.dict(os.environ, unsafe, clear=True):
            with self.assertRaisesRegex(WorkerError, "ALLOW_REAL_SUBMIT 必须为 false"):
                WorkerConfig.from_env()

    def test_worker_refuses_default_or_non_fill_mode(self) -> None:
        env = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "service-role-test-only",
            "MDAC_WORKER_ID": "test-worker",
            "MDAC_EXECUTION_MODE": "DRY_RUN",
            "ALLOW_REAL_SUBMIT": "false",
        }
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(WorkerError, "必须为 AUTO_SUBMIT 或 FILL_PREVIEW"):
                WorkerConfig.from_env()

    def test_worker_accepts_auto_submit_mode(self) -> None:
        env = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "service-role-test-only",
            "MDAC_WORKER_ID": "test-worker",
            "MDAC_EXECUTION_MODE": "AUTO_SUBMIT",
            "ALLOW_REAL_SUBMIT": "true",
        }
        with patch.dict(os.environ, env, clear=True):
            config = WorkerConfig.from_env()
            self.assertEqual(config.execution_mode, "AUTO_SUBMIT")
            self.assertTrue(config.allow_real_submit)

    def test_slider_solver_generate_track(self) -> None:
        from slider_solver import generate_track

        total_distance = 150.0
        track = generate_track(total_distance)
        self.assertGreaterEqual(len(track), 30)
        self.assertLessEqual(len(track), 40)
        sum_distance = sum(track)
        self.assertAlmostEqual(sum_distance, total_distance, delta=1.0)

    def test_supabase_client_finish_registration_calls_rpc(self) -> None:
        from worker import SupabaseAdminClient

        config = self.base_config()
        client = SupabaseAdminClient(config)
        with patch.object(client, "_rpc") as mock_rpc:
            mock_rpc.return_value = {"id": "test-item-id", "status": "SUCCEEDED"}
            res = client.finish_registration(
                item_id="item-123",
                status="SUCCEEDED",
                registration_no="MDAC12345",
                screenshot_path="mdac-submissions/b/i/success.png",
                raw_summary={"test": True},
            )
            self.assertEqual(res["status"], "SUCCEEDED")
            mock_rpc.assert_called_once_with(
                "finish_mdac_registration_worker",
                {
                    "p_item_id": "item-123",
                    "p_worker_id": "test-worker",
                    "p_status": "SUCCEEDED",
                    "p_registration_no": "MDAC12345",
                    "p_screenshot_path": "mdac-submissions/b/i/success.png",
                    "p_raw_summary": {"test": True},
                    "p_error_code": None,
                    "p_error_message": None,
                },
            )


if __name__ == "__main__":
    unittest.main()
