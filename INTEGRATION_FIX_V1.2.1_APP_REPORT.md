# MDAC App / Worker — V1.2.1 Hotfix Report

**Date:** 2026-09-30  
**Repository:** `mm7768/passport-mdac-app`  
**Author:** Antigravity  

---

## 1. Summary of Changes

This hotfix addresses the critical issues identified during the V1.2 audit before Gate 2 (V1.3 Order Intake) deployment:

1. **Visit Pass Runtime Input Fail-Closed**:
   - For strict items (`case_id != null`), if `get_visit_pass_check_runtime_input` RPC fails/throws (e.g. lease expired, item ownership changed, batch closed), the worker aborts execution immediately (`WorkerError`).
   - Direct table queries and customer-level fallbacks are strictly blocked.
   - Legacy direct table query is permitted only when `case_id == null`, and even then, if the discovered `automation_item` row contains a `case_id`, execution is aborted.

2. **Case-Scoped Evidence Cleanup via Backend RPC**:
   - `delete_case_old_visit_pass_evidence` now calls backend RPC `delete_case_old_visit_pass_evidence(p_case_id, p_current_screenshot_path)`.
   - The worker never issues direct SQL `DELETE` requests to `visit_pass_checks`.
   - The worker only removes the specific Storage object paths returned by the backend RPC.
   - Storage deletion failure is logged and does not fail the successfully completed Visit Pass check.

3. **Repository Enqueue Network Guard**:
   - In `DemoRepository.createBatchDrivenTaskAsync()`, the return value of `await syncActiveBatchesFromSupabase()` is checked.
   - If `syncErr != null`, the enqueue request is immediately rejected with `'无法确认批次当前状态，请检查网络后刷新'`.
   - Stale locally cached `activeBatches` can never authorize execution during network partitioning.

---

## 2. Test Verification

### Visit Pass Check Worker Tests (`services/visit-pass-check-worker/test_worker.py`)
- **Test A (`test_v121_test_a_runtime_input_fail_closed_on_rpc_failure_for_strict_item`)**:
  Verified that for strict item (`case_id != null`), RPC exception triggers immediate `WorkerError` with Fail-closed note, and no HTTP GET fallback is executed.
- **Test B (`test_v121_test_b_runtime_input_allows_legacy_fallback_when_case_id_is_none`)**:
  Verified that for legacy item (`case_id == null`), legacy fallback continues to resolve credentials without error.
- **Test C (`test_v121_test_c_delete_case_old_visit_pass_evidence_uses_backend_rpc`)**:
  Verified that `delete_case_old_visit_pass_evidence` invokes the backend RPC, deletes only returned storage paths from Supabase Storage, and issues zero DELETE calls to the REST table.
- **Result**: `20/20` tests passed in 0.33s.

### Flutter App Batch Integration Tests (`test/batch_integration_test.dart`)
- **Test D (`Test D (V1.2.1): syncActiveBatchesFromSupabase returns error -> createBatchDrivenTaskAsync refuses enqueue`)**:
  Verified that when `syncActiveBatchesFromSupabase` returns a network error, `createBatchDrivenTaskAsync` refuses enqueue with `'无法确认批次当前状态，请检查网络后刷新'`, even if `activeBatches` had cached open batches.
- **Result**: `17/17` tests passed.
