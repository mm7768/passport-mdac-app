"""Frozen G1 source/mocked-client checks; no DB/Auth/Storage/network execution."""
from __future__ import annotations

import ast
import hashlib
import json
from pathlib import Path
import unittest

import test_attempt_protocol as candidate

ROOT = Path(__file__).resolve().parents[2]
WEB = ROOT.parent / "mdac-admin-web"
CONTRACT = json.loads((WEB / "supabase/contracts/requeue-g1-v1.json").read_text(encoding="utf-8-sig"))
WORKER = {row["name"]: row for row in CONTRACT["worker"]}
ADDED = {row["name"]: row for row in CONTRACT["added"]}


class FrozenG1Tests(unittest.TestCase):
    def test_all_four_route_copies_identical_and_names_declared(self):
        blobs = []
        for service in candidate.ALL_SERVICES:
            client, module = candidate.load_client(service)
            blobs.append(hashlib.sha256((ROOT / "services" / service / "attempt_evidence.py").read_bytes()).hexdigest())
            self.assertEqual(set(module.ROUTES.values()) - set(WORKER), set())
        self.assertEqual(len(set(blobs)), 1)

    def test_literal_worker_payloads_have_no_unknown_frozen_parameters(self):
        for service in candidate.ALL_SERVICES:
            _, module = candidate.load_client(service)
            tree = ast.parse((ROOT / "services" / service / "worker.py").read_text(encoding="utf-8-sig"))
            for node in ast.walk(tree):
                if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                        and node.func.attr == "_rpc" and len(node.args) >= 2
                        and isinstance(node.args[0], ast.Constant) and isinstance(node.args[1], ast.Dict)):
                    continue
                name = node.args[0].value
                if name not in module.ROUTES:
                    continue
                params = {key.value for key in node.args[1].keys if isinstance(key, ast.Constant)}
                if name.startswith(("finish_", "get_", "heartbeat_")):
                    params.add("p_attempt_id")
                declared = {part.strip().split()[0] for part in WORKER[module.ROUTES[name]]["identity_arguments"].split(",")}
                self.assertEqual(params - declared, set(), (service, name))

    def test_evidence_helper_parameters_exact_frozen_contract(self):
        client, _ = candidate.load_client("registration-check-worker")
        client.claim_item(candidate.OB)
        client.upload_evidence(candidate.ITEM, b"synthetic-frozen-g1", "pdf")
        for url, kwargs in client.session.calls:
            name = url.rsplit("/", 1)[-1]
            if name not in ADDED:
                continue
            declared = {part.strip().split()[0] for part in ADDED[name]["args"].split(",")}
            self.assertEqual(set(kwargs["json"]), declared, name)

    def test_gmail_finish_uses_nonce_but_never_screenshot(self):
        client, _ = candidate.load_client("gmail-pin-worker")
        client.claim_item(candidate.OB)
        client.finish_item(item_id=candidate.ITEM, pin_status="NOT_FOUND", email_message_id=None,
                           sender=None, subject=None, pin_value=None, match_confidence=None,
                           raw_summary={}, received_at=None, error_code=None, error_message=None)
        payload = client.session.calls[-1][1]["json"]
        self.assertIn("p_attempt_id", payload)
        self.assertNotIn("p_evidence_path", payload)
        self.assertNotIn("p_screenshot_path", payload)
        self.assertEqual(client.session.objects, {})

    def test_claim_result_shape_and_runtime_table_shape_match_frozen_contract(self):
        for name, row in WORKER.items():
            if name.startswith("claim_"):
                self.assertIn("SETOF", row["returns"])
            if name.startswith("get_"):
                self.assertIn("TABLE", row["returns"])
            if name.startswith("heartbeat_"):
                self.assertIn("void", row["returns"])

    def test_mdac_post_claim_heartbeat_passes_item_for_server_nonce(self):
        tree = ast.parse((ROOT / "services" / "mdac-fill-preview" / "worker.py").read_text(encoding="utf-8-sig"))
        found = False
        for node in ast.walk(tree):
            if not isinstance(node, ast.While):
                continue
            for index, statement in enumerate(node.body):
                if not (isinstance(statement, ast.Assign) and isinstance(statement.value, ast.Call)
                        and isinstance(statement.value.func, ast.Attribute)
                        and statement.value.func.attr == "claim_item"):
                    continue
                for following in node.body[index + 1:]:
                    if isinstance(following, ast.Expr) and isinstance(following.value, ast.Call):
                        call = following.value
                        if isinstance(call.func, ast.Attribute) and call.func.attr == "heartbeat_tick":
                            self.assertIn("item_id", {keyword.arg for keyword in call.keywords})
                            found = True
                            break
        self.assertTrue(found, "the real MDAC post-claim heartbeat must carry the current item")


if __name__ == "__main__":
    unittest.main(verbosity=2)
