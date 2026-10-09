"""Local mock/AST tests only. No Auth, Supabase, Playwright or government requests."""
from __future__ import annotations

import ast
import asyncio
import hashlib
import importlib.util
import json
import logging
from pathlib import Path
from types import SimpleNamespace
from typing import Any
import unittest
from uuid import NAMESPACE_URL, uuid5

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ("mdac-fill-preview", "registration-check-worker", "visit-pass-check-worker")
ITEM = "00000000-0000-4000-8000-000000000001"
CASE = "00000000-0000-4000-8000-000000000002"
CUSTOMER = "00000000-0000-4000-8000-000000000003"
OB = "00000000-0000-4000-8000-000000000004"
MEMBER = "00000000-0000-4000-8000-000000000005"


def load_client(service):
    spec = importlib.util.spec_from_file_location("protocol_" + service, ROOT / service / "attempt_evidence.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    source = ast.parse((ROOT / service / "worker.py").read_text(encoding="utf-8-sig"))
    client = next(n for n in source.body if isinstance(n, ast.ClassDef) and n.name == "SupabaseAdminClient")
    # Execute the actual client class, not its Playwright/parser imports.
    namespace = {
        "Any": Any, "WorkerConfig": Any, "WorkerError": RuntimeError,
        "AttemptEvidence": module.AttemptEvidence,
        "requests": SimpleNamespace(Session=lambda: Session(), Response=Any),
        "socket": SimpleNamespace(gethostname=lambda: "synthetic"),
        "WORKER_VERSION": "test-attempt-protocol",
    }
    exec(compile(ast.Module(body=[client], type_ignores=[]), str(ROOT / service / "worker.py"), "exec"), namespace)
    config = SimpleNamespace(
        supabase_url="https://rvgslhjmiaunylwhcamz.supabase.co", service_role_key="synthetic-placeholder",
        worker_id="synthetic-worker", lease_seconds=60, max_attempts=3, request_timeout_seconds=1,
        screenshot_bucket="passport-documents", screenshot_prefix="unused",
    )
    instance = namespace["SupabaseAdminClient"](config)
    return instance, module


class Response:
    def __init__(self, data=None, status=200):
        self.data, self.status_code = data, status
        self.ok, self.content = 200 <= status < 300, b"{}"
        self.text = "SENSITIVE_RESPONSE_MUST_NOT_APPEAR"
    def json(self):
        return self.data


class Session:
    def __init__(self):
        self.headers, self.calls, self.objects, self.grants = {}, [], {}, {}
        self.round = 1
        self.fail_upload = self.fail_confirm = self.fail_finish = False
        self.missing_nonce = self.missing_member = self.bad_grant = False
        self.duplicate_grant = False
        self.current_attempt = self.attempt()
        self.counter = 0

    def attempt(self):
        return str(uuid5(NAMESPACE_URL, f"synthetic-attempt-{self.round}"))

    def next_round(self):
        self.round += 1
        self.current_attempt = self.attempt()

    def post(self, url, **kwargs):
        self.calls.append((url, kwargs))
        if "/rpc/" in url:
            name = url.rsplit("/", 1)[-1]
            payload = kwargs["json"]
            if name.startswith("claim_") and name.endswith("_item"):
                row = {
                    "id": ITEM, "case_id": CASE, "customer_id": CUSTOMER,
                    "original_operational_batch_id": OB, "original_membership_id": MEMBER,
                    "current_attempt_id": self.current_attempt, "attempt_no": self.round,
                    "locked_by": "synthetic-worker", "status": "CLAIMED",
                }
                if self.missing_nonce:
                    del row["current_attempt_id"]
                if self.missing_member:
                    del row["original_membership_id"]
                return Response([row])
            if name == "prepare_automation_evidence":
                if not self.duplicate_grant:
                    self.counter += 1
                eid = str(uuid5(NAMESPACE_URL, f"synthetic-evidence-{self.round}-{self.counter}"))
                path = f"automation-attempt-evidence/{payload['p_attempt_id']}/{eid}.{payload['p_extension']}"
                grant = dict(evidence_id=eid, attempt_id=payload["p_attempt_id"],
                             bucket="passport-documents", path=path, sha256=payload["p_sha256"],
                             state="PREPARED")
                self.grants[eid] = grant
                return Response(dict(grant, path="untrusted/path.png") if self.bad_grant else grant)
            if name == "confirm_automation_evidence":
                if self.fail_confirm:
                    return Response(status=503)
                grant = self.grants[payload["p_evidence_id"]]
                assert hashlib.sha256(self.objects[grant["path"]]).hexdigest() == payload["p_sha256"]
                grant["state"] = "STORED"
                return Response(dict(grant))
            if name == "record_automation_evidence_failure":
                return Response({"recorded": True})
            if name.startswith("finish_"):
                if self.fail_finish or payload["p_attempt_id"] != self.current_attempt:
                    return Response(status=409)
                return Response({"automation_item_id": ITEM, "attempt_id": payload["p_attempt_id"]})
            return Response({})
        assert "/storage/v1/object/passport-documents/" in url
        path = url.split("/storage/v1/object/passport-documents/")[1]
        assert kwargs["headers"]["x-upsert"] == "false"
        if self.fail_upload:
            return Response(status=503)
        if path in self.objects:
            return Response(status=409)
        self.objects[path] = kwargs["data"]
        return Response({"saved": True})

    def delete(self, *args, **kwargs):
        raise AssertionError("No deletion is allowed in retry evidence flow")


def upload(client, service, content=b"synthetic-png", extension="png"):
    if service == "registration-check-worker":
        return client.upload_evidence(ITEM, content, extension)
    return client.upload_screenshot(ITEM, content)


def finish(client, service, path=None):
    if service == "mdac-fill-preview":
        return client.finish_registration(item_id=ITEM, status="NEEDS_REVIEW", screenshot_path=path)
    if service == "registration-check-worker":
        return client.finish_check_worker(item_id=ITEM, outcome="NO_RECORD", evidence_path=path)
    return client.finish_visit_pass_worker(item_id=ITEM, outcome="NO_RECORD", evidence_path=path)


class AttemptProtocolTests(unittest.TestCase):
    def test_copies_identical(self):
        blobs = [(ROOT / service / "attempt_evidence.py").read_bytes() for service in SERVICES]
        self.assertTrue(all(blob == blobs[0] for blob in blobs))

    def test_three_workers_two_rounds_preserve_old_bytes(self):
        for service in SERVICES:
            with self.subTest(service=service):
                client, _ = load_client(service)
                client.claim_item(OB)
                old = upload(client, service, b"synthetic-round-one")
                finish(client, service, old)
                client.session.next_round()
                client.claim_item(OB)
                new = upload(client, service, b"synthetic-round-two")
                finish(client, service, new)
                self.assertNotEqual(old, new)
                self.assertEqual(client.session.objects[old], b"synthetic-round-one")
                self.assertEqual(client.session.objects[new], b"synthetic-round-two")
                self.assertTrue(all(g["state"] == "STORED" for g in client.session.grants.values()))

    def test_registration_pdf_is_attempt_scoped(self):
        client, _ = load_client(SERVICES[1])
        client.claim_item(OB)
        path = upload(client, SERVICES[1], b"%PDF-synthetic-only", "pdf")
        self.assertTrue(path.endswith(".pdf"))
        post = next(kwargs for url, kwargs in client.session.calls if "/storage/" in url)
        self.assertEqual(post["headers"]["Content-Type"], "application/pdf")

    def test_missing_nonce_or_original_member_refused(self):
        for flag in ("missing_nonce", "missing_member"):
            for service in SERVICES:
                client, module = load_client(service)
                setattr(client.session, flag, True)
                with self.assertRaises(module.AttemptProtocolError):
                    client.claim_item(OB)
                self.assertEqual(client.session.objects, {})

    def test_production_url_refused_before_http(self):
        for service in SERVICES:
            client, module = load_client(service)
            client.config.supabase_url = "https://xdmcxhvdqsbcqedfprcy.supabase.co"
            with self.assertRaisesRegex(module.AttemptProtocolError, "ISOLATION_ONLY"):
                client.claim_item(OB)
            self.assertEqual(client.session.calls, [])

    def test_bad_grant_refused_without_upload(self):
        for service in SERVICES:
            client, module = load_client(service)
            client.claim_item(OB)
            client.session.bad_grant = True
            with self.assertRaisesRegex(module.AttemptProtocolError, "MISMATCHED_EVIDENCE_GRANT"):
                upload(client, service)
            self.assertEqual(client.session.objects, {})

    def test_duplicate_object_is_never_overwritten(self):
        for service in SERVICES:
            client, module = load_client(service)
            client.claim_item(OB)
            path = upload(client, service, b"old-evidence")
            client.session.duplicate_grant = True
            with self.assertRaisesRegex(module.AttemptProtocolError, "HTTP_409"):
                upload(client, service, b"replacement")
            self.assertEqual(client.session.objects[path], b"old-evidence")
            self.assertTrue(any("record_automation_evidence_failure" in url for url, _ in client.session.calls))

    def test_upload_failure_preserves_prepared_manifest(self):
        for service in SERVICES:
            client, module = load_client(service)
            client.claim_item(OB)
            client.session.fail_upload = True
            with self.assertRaises(module.AttemptProtocolError):
                upload(client, service)
            self.assertEqual(client.session.objects, {})
            self.assertEqual(next(iter(client.session.grants.values()))["state"], "PREPARED")

    def test_confirmation_failure_leaves_identifiable_object(self):
        for service in SERVICES:
            client, _ = load_client(service)
            client.claim_item(OB)
            client.session.fail_confirm = True
            with self.assertRaises(RuntimeError) as error:
                upload(client, service)
            self.assertNotIn("SENSITIVE_RESPONSE", str(error.exception))
            self.assertEqual(len(client.session.objects), 1)
            grant = next(iter(client.session.grants.values()))
            self.assertEqual(grant["state"], "PREPARED")
            self.assertIn(grant["path"], client.session.objects)

    def test_finish_failure_does_not_fall_back(self):
        for service in SERVICES:
            client, _ = load_client(service)
            client.claim_item(OB)
            path = upload(client, service)
            client.session.fail_finish = True
            with self.assertRaises(RuntimeError):
                finish(client, service, path)
            calls = [url for url, _ in client.session.calls if "/rpc/finish_" in url]
            self.assertEqual(len(calls), 1)
            self.assertTrue(calls[0].endswith("_attempt"))
            self.assertEqual(next(iter(client.session.grants.values()))["state"], "STORED")

    def test_inflight_nonce_cannot_be_silently_replaced(self):
        for service in SERVICES:
            client, module = load_client(service)
            client.claim_item(OB)
            original = client.attempts.context(ITEM)["attempt_id"]
            client.session.next_round()
            with self.assertRaises(module.AttemptProtocolError):
                client.claim_item(OB)
            self.assertEqual(client.attempts.context(ITEM)["attempt_id"], original)

    def test_finish_without_claim_refused(self):
        for service in SERVICES:
            client, module = load_client(service)
            with self.assertRaises(module.AttemptProtocolError):
                finish(client, service)
            self.assertEqual(client.session.calls, [])

    def test_visit_legacy_cleanup_is_noop(self):
        client, _ = load_client(SERVICES[2])
        self.assertEqual(client.delete_case_old_visit_pass_evidence(CASE), [])
        self.assertEqual(client.delete_customer_old_visit_pass_screenshots(CUSTOMER), [])
        self.assertEqual(client.session.calls, [])

    def test_known_result_requires_confirmed_evidence(self):
        for service in SERVICES:
            client, module = load_client(service)
            client.claim_item(OB)
            outcome_payload = {"p_item_id": ITEM, "p_worker_id": "synthetic-worker"}
            if service == "mdac-fill-preview":
                name = "finish_mdac_registration_worker"
                outcome_payload["p_status"] = "SUCCEEDED"
            else:
                name = "finish_registration_check_worker" if service == SERVICES[1] else "finish_visit_pass_check_worker"
                outcome_payload["p_outcome"] = "FOUND"
            with self.assertRaisesRegex(module.AttemptProtocolError, "CONFIRMED_EVIDENCE_REQUIRED"):
                client._rpc(name, outcome_payload)
            outcome_payload["p_evidence_path"] = "untrusted/other-round.png"
            with self.assertRaisesRegex(module.AttemptProtocolError, "UNCONFIRMED_EVIDENCE_REF"):
                client._rpc(name, outcome_payload)
            self.assertFalse(any("/rpc/finish_" in url for url, _ in client.session.calls))

    def test_process_finish_failure_is_not_replaced_by_second_outcome(self):
        for service, class_name in ((SERVICES[1], "RegistrationCheckWorker"),
                                    (SERVICES[2], "VisitPassCheckWorker")):
            source = ast.parse((ROOT / service / "worker.py").read_text(encoding="utf-8-sig"))
            node = next(n for n in source.body if isinstance(n, ast.ClassDef) and n.name == class_name)
            async def capture(*args, **kwargs):
                if service == SERVICES[1]:
                    return "NO_RECORD", b"synthetic", "png", {}
                return "NO_RECORD", b"synthetic", {}
            namespace = {"Any": Any, "WorkerConfig": Any, "asyncio": asyncio,
                         "logging": logging, "log_event": lambda *a, **k: None,
                         "query_and_capture_page": capture,
                         "classify_page_failure": lambda e: ("SYNTHETIC", "synthetic", False)}
            exec(compile(ast.Module(body=[node], type_ignores=[]), "synthetic-process-test", "exec"), namespace)
            worker = namespace[class_name].__new__(namespace[class_name])
            worker.config = SimpleNamespace(mode="FILL_REVIEW")
            remaining = [{"id": ITEM, "customer_id": CUSTOMER, "case_id": CASE}]
            calls = []
            def failed_finish(**kwargs):
                calls.append(kwargs)
                raise RuntimeError("synthetic lost finish response")
            worker.supabase = SimpleNamespace(
                claim_item=lambda _: remaining.pop() if remaining else None,
                heartbeat_tick=lambda **kwargs: None, heartbeat=lambda **kwargs: None,
                get_runtime_input=lambda *args, **kwargs: {"case_id": CASE, "entry_date": "2026-10-09"},
                upload_evidence=lambda *args: "synthetic-stored-ref",
                upload_screenshot=lambda *args: "synthetic-stored-ref",
                finish_check_worker=failed_finish, finish_visit_pass_worker=failed_finish,
            )
            self.assertEqual(worker.process_batch({"id": OB}), 0)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0]["outcome"], "NO_RECORD")


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(AttemptProtocolTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print(json.dumps({
        "scope": "local fake HTTP / actual client AST, not real Auth/API/Storage/Worker execution",
        "tests": result.testsRun, "failures": len(result.failures), "errors": len(result.errors),
        "passed": result.wasSuccessful(), "government_requests": 0, "database_requests": 0,
    }))
    raise SystemExit(0 if result.wasSuccessful() else 1)
