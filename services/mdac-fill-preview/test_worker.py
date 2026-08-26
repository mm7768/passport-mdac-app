from __future__ import annotations

import os
import sys
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from worker import WorkerConfig, WorkerError, map_gender, map_mdac_fields, parse_date


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
            mdac_email="operator@example.test",
            mdac_phone="60123456789",
            mdac_region_code="60",
            mdac_travel_mode="2",
            mdac_embark_country="CHN",
            mdac_vessel="TEST FLIGHT",
            mdac_accommodation_stay="02",
            mdac_address1="TEST ADDRESS 1",
            mdac_address2="TEST ADDRESS 2",
            mdac_state="01",
            mdac_city="0100",
            mdac_postcode="50000",
            mdac_pob_mode="NATIONALITY",
            headless=True,
            log_level="INFO",
        )

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
        fields = map_mdac_fields(snapshot, batch, self.base_config())
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
        config = replace(self.base_config(), mdac_pob_mode="CUSTOMER")
        fields = map_mdac_fields(snapshot, batch, config)
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
            map_mdac_fields(snapshot, batch, self.base_config())

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
            "MDAC_EMAIL": "operator@example.test",
            "MDAC_PHONE": "60123456789",
            "MDAC_VESSEL": "TEST FLIGHT",
            "MDAC_ADDRESS1": "TEST ADDRESS",
            "MDAC_POSTCODE": "50000",
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
            with self.assertRaisesRegex(WorkerError, "必须严格为 false"):
                WorkerConfig.from_env()

    def test_worker_refuses_default_or_non_fill_mode(self) -> None:
        env = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "service-role-test-only",
            "MDAC_WORKER_ID": "test-worker",
            "MDAC_EMAIL": "operator@example.test",
            "MDAC_PHONE": "60123456789",
            "MDAC_VESSEL": "TEST FLIGHT",
            "MDAC_ADDRESS1": "TEST ADDRESS",
            "MDAC_POSTCODE": "50000",
            "MDAC_EXECUTION_MODE": "DRY_RUN",
            "ALLOW_REAL_SUBMIT": "false",
        }
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(WorkerError, "必须严格为 FILL_PREVIEW"):
                WorkerConfig.from_env()


if __name__ == "__main__":
    unittest.main()
