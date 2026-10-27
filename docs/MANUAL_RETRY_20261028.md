# Four Worker manual Retry candidate

This change adds a user-initiated Retry entry for FAILED and NEEDS_REVIEW items in MDAC registration, Get PIN, Check Registration and Check Visit Pass. Screen loading, refresh, Worker polling and failure handling do not initiate a retry.

The app asks the server for a current preview only after a tap. Successful items are excluded. Query and PIN tasks can be re-executed after confirmation. For MDAC, proven pre-submit failures can be retried separately; including possibly submitted items requires an explicit acknowledgement that registration may be duplicated. The server independently verifies active FULL access, original batch ownership, item state, attempt limits, leases, expected snapshot and customer overlap. Old state and results are retained in private history before the current claim is reset. The item/Case/customer identities and attempt counts are retained; ordinary clients do not PATCH protected fields.

If a network response is ambiguous, the app retains the same request UUID and choice in Repository memory and offers confirmation of that request. It does not silently generate a new request. This state survives screen changes but not an app process restart; a new explicit request after restart is revalidated against the current server state.

The backend uses preview_automation_manual_retry(uuid) and request_automation_manual_retry(uuid,uuid,text,boolean). Both are authenticated, scoped RPCs; missing endpoints produce an explicit update-required message and no fallback. The SQL candidate and isolated test evidence are delivered separately before any production installation.

The build workflow uploads an artifact only. It does not merge, publish a GitHub Release, apply SQL or deploy Workers. The candidate uses a separate Android package com.example.passport_mdac_app.manualretry, version1.0.43/code44, labelled MDAC 手动重试版. The prior debug signing key is unavailable, so the old installed repair app is preserved. The user-facing APK will be signed locally with a retained protected key; no keystore or signing password is committed or sent to CI.

New private retry-request/history tables must be explicitly included in a future authorized complete customer/task purge. They are not silently removed by normal task deletion. Production rollback removes new entry points while retaining historical evidence; it must not restore permissive direct state updates.

Validation is isolated and synthetic. Database role tests are not live Auth login or government-site execution. Real customer registrations are not triggered by these tests.
