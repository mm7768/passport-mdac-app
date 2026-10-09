"""Isolation-only attempt protocol candidate; database endpoints are not installed yet.

No government-page automation or result parsing lives here. Three local copies
are identical so existing per-service Docker build contexts remain unchanged.
"""
from __future__ import annotations

import hashlib
from typing import Any, Callable
from urllib.parse import urlsplit
from uuid import UUID

ISOLATED_HOST = "rvgslhjmiaunylwhcamz.supabase.co"
CLAIMS = {
    "claim_mdac_item", "claim_registration_check_item", "claim_visit_pass_check_item",
}
ROUTES = {
    **{f"claim_{kind}_{part}": f"claim_{kind}_attempt_{part}"
       for kind in ("mdac", "registration_check", "visit_pass_check")
       for part in ("batch", "item")},
    **{f"heartbeat_{kind}": f"heartbeat_{kind}_attempt"
       for kind in ("mdac", "registration_check", "visit_pass_check")},
    **{name: name + "_attempt" for name in (
        "finish_mdac_fill_preview", "finish_mdac_registration_worker",
        "finish_registration_check_worker", "finish_registration_check_item",
        "finish_visit_pass_check_worker", "finish_visit_pass_check_item",
        "get_registration_check_runtime_input", "get_visit_pass_check_runtime_input",
    )},
}


class AttemptProtocolError(RuntimeError):
    """Safe code-only error: no response bodies, URLs, PINs or credentials."""


def canonical_uuid(value: Any) -> str:
    try:
        result = str(UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        raise AttemptProtocolError("INVALID_PROTOCOL_ID") from None
    if str(value) != result:
        raise AttemptProtocolError("NON_CANONICAL_PROTOCOL_ID")
    return result


class AttemptEvidence:
    def __init__(self, rpc: Callable, session: Any, config: Any) -> None:
        self.rpc, self.session, self.config = rpc, session, config
        self.claims: dict[str, dict[str, Any]] = {}

    def require_isolation(self) -> None:
        url = urlsplit(self.config.supabase_url)
        if (url.scheme != "https" or url.netloc != ISOLATED_HOST
                or url.path not in ("", "/") or url.query or url.fragment):
            raise AttemptProtocolError("ISOLATION_ONLY_WORKER_CANDIDATE")

    def route(self, name: str, payload: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        self.require_isolation()
        output = dict(payload)
        if name in ROUTES:
            if name.startswith(("finish_", "get_")):
                context = self.context(output.get("p_item_id"))
                output["p_attempt_id"] = context["attempt_id"]
                if name.startswith("finish_"):
                    path = output.get("p_evidence_path") or output.get("p_screenshot_path")
                    outcome = output.get("p_outcome") or output.get("p_status") or output.get("p_normalized_status")
                    if outcome in ("SUCCEEDED", "FOUND", "NO_RECORD") and not path:
                        raise AttemptProtocolError("CONFIRMED_EVIDENCE_REQUIRED")
                    if path and path not in context.get("stored_paths", []):
                        raise AttemptProtocolError("UNCONFIRMED_EVIDENCE_REF")
            elif name.startswith("heartbeat_"):
                item_id = output.get("p_item_id")
                output["p_attempt_id"] = self.context(item_id)["attempt_id"] if item_id else None
            return ROUTES[name], output
        if name.startswith("delete_"):
            raise AttemptProtocolError("EVIDENCE_RETENTION_REQUIRED")
        return name, output

    def accept(self, name: str, result: Any) -> None:
        if name.startswith("finish_") and name in ROUTES:
            if not isinstance(result, dict):
                raise AttemptProtocolError("INVALID_ATTEMPT_FINISH_RESPONSE")
            item_id = canonical_uuid(result.get("automation_item_id"))
            context = self.context(item_id)
            if result.get("attempt_id") != context["attempt_id"]:
                raise AttemptProtocolError("MISMATCHED_ATTEMPT_FINISH")
            self.claims[item_id]["finished"] = True
            return
        if name not in CLAIMS or not result:
            return
        if not isinstance(result, list) or len(result) != 1 or not isinstance(result[0], dict):
            raise AttemptProtocolError("INVALID_ATTEMPT_CLAIM")
        row = result[0]
        item_id = canonical_uuid(row.get("id"))
        witness = {key: canonical_uuid(row.get(key)) for key in (
            "case_id", "customer_id", "original_operational_batch_id", "original_membership_id",
        )}
        attempt_id = canonical_uuid(row.get("current_attempt_id"))
        attempt_no = row.get("attempt_no")
        if (type(attempt_no) is not int or attempt_no < 1
                or row.get("locked_by") != self.config.worker_id
                or row.get("status") not in ("CLAIMED", "RUNNING")):
            raise AttemptProtocolError("INVALID_ATTEMPT_LEASE")
        previous = self.claims.get(item_id)
        # A single client must not silently replace the nonce of an in-flight item.
        if previous and not previous.get("finished") and previous["attempt_id"] != attempt_id:
            raise AttemptProtocolError("ATTEMPT_CLIENT_RESTART_REQUIRED")
        self.claims[item_id] = dict(witness, attempt_id=attempt_id, attempt_no=attempt_no)

    def context(self, item_id: Any) -> dict[str, Any]:
        key = canonical_uuid(item_id)
        if key not in self.claims:
            raise AttemptProtocolError("SERVER_ATTEMPT_REQUIRED")
        return dict(self.claims[key])

    def upload(self, item_id: str, content: bytes, extension: str = "png") -> str:
        self.require_isolation()
        witness = self.context(item_id)
        if extension not in ("png", "pdf") or not isinstance(content, bytes) or not content:
            raise AttemptProtocolError("INVALID_EVIDENCE_CONTENT")
        digest = hashlib.sha256(content).hexdigest()
        common = {
            "p_item_id": canonical_uuid(item_id),
            "p_attempt_id": witness["attempt_id"],
            "p_worker_id": self.config.worker_id,
        }
        grant = self.rpc("prepare_automation_evidence", dict(
            common, p_extension=extension, p_sha256=digest, p_size=len(content),
        ))
        if not isinstance(grant, dict):
            raise AttemptProtocolError("INVALID_EVIDENCE_GRANT")
        evidence_id = canonical_uuid(grant.get("evidence_id"))
        path = f"automation-attempt-evidence/{witness['attempt_id']}/{evidence_id}.{extension}"
        if (grant.get("path") != path or grant.get("bucket") != "passport-documents"
                or grant.get("attempt_id") != witness["attempt_id"]
                or grant.get("sha256") != digest):
            raise AttemptProtocolError("MISMATCHED_EVIDENCE_GRANT")
        media = "application/pdf" if extension == "pdf" else "image/png"
        try:
            response = self.session.post(
                f"{self.config.supabase_url.rstrip('/')}/storage/v1/object/passport-documents/{path}",
                headers={"Content-Type": media, "x-upsert": "false",
                         "Cache-Control": "private, max-age=0, no-store"},
                data=content, timeout=self.config.request_timeout_seconds,
            )
        except Exception:
            # PREPARED grant survives network uncertainty for controlled reconciliation.
            raise AttemptProtocolError("EVIDENCE_UPLOAD_NETWORK_UNKNOWN") from None
        if not response.ok:
            try:
                self.rpc("record_automation_evidence_failure", dict(
                    common, p_evidence_id=evidence_id, p_http_status=response.status_code,
                ))
            except Exception:
                pass  # Never fall back to DELETE/upsert; PREPARED remains observable.
            raise AttemptProtocolError(f"EVIDENCE_UPLOAD_HTTP_{int(response.status_code)}")
        result = self.rpc("confirm_automation_evidence", dict(
            common, p_evidence_id=evidence_id, p_sha256=digest,
        ))
        if (not isinstance(result, dict) or result.get("state") != "STORED"
                or result.get("attempt_id") != witness["attempt_id"]
                or result.get("evidence_id") != evidence_id or result.get("sha256") != digest):
            raise AttemptProtocolError("EVIDENCE_CONFIRMATION_REQUIRED")
        if self.context(item_id)["attempt_id"] != witness["attempt_id"]:
            raise AttemptProtocolError("EVIDENCE_UPLOADED_FOR_OLD_ATTEMPT")
        self.claims[item_id].setdefault("stored_paths", []).append(path)
        return path
