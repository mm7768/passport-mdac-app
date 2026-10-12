# App client integration evidence — 2026-10-12 MYT

This is an internal integration appendix for the single final acceptance report, not a G3/G4 acceptance claim. No SQL, production API, production Storage, government submission, mailbox or Worker process was operated by this client work.

## Source and implementation

Branch: `feat/automation-requeue-security-20261009`; starting/unchanged committed HEAD: `dec3ef45572076ea8dffadb9632c97aba702e32b`. The source changes are uncommitted and require the integrator to bind the final commit SHA after committing. Existing uncommitted evidence/delete adaptations were preserved and reviewed.

- `mdac_human_review.dart`: each submitted/unknown/success action separately picks PNG/PDF through the existing file_picker, checks magic bytes and 6 MiB limit, generates a new UUID object, uploads with `upsert:false`, `retryAttempts:0`, and sends only `{reason,evidence_ref:{bucket,path}}` as `p_evidence`. No filename or file bytes are logged. Uploaded objects survive uncertain RPC/network outcomes. Official DOM parsing remains the existing implementation.
- `mdac_human_evidence.dart`: actor/item/evidence UUID validation, fixed audit reasons, exact `mdac-human-evidence/<actor>/<item>/<evidence>.png|pdf` path, type/size validation and exact isolation REST endpoint guard.
- `supabase_gateway.dart`: controlled deletion RPC only, with check/type/result validation; PENDING requires canonical request UUID and remains `deleted:false`. No bare table DELETE or Storage remove fallback. Old FOUND cleanup helper rejects; HUMAN_QUERY no longer invokes it.
- `human_query_review.dart`: PENDING is explicitly displayed as awaiting server cleanup, not completed deletion; FOUND preserves old evidence.
- `main.dart`: both Retry operations share a per-batch in-flight guard; the detail dialog disables both Retry buttons while one is pending. Disconnected mode reports no execution. Existing request-key retention/replay logic remains unchanged.
- `main_isolation.dart` and `web/index.html`: isolated development entrypoint and minimal Flutter browser bootstrap. Startup requires exact isolation URL and public key (publishable prefix or legacy anon JWT with isolation ref); absent/privileged/production-target config fails before initialization. Normal App entrypoint is unchanged.

## Local results

Runtime: Flutter 3.47.2 / Dart 3.13.2, Windows 11. Local Flutter/Dart tools needed approved execution outside the sandbox because sandboxed Dart reported an unresolved executable path. No tool upgrade was performed.

| Check | Result | Limit |
|---|---|---|
| Initial full `flutter test --no-pub` | 112 PASS, 10 existing SKIP | Before final in-flight/key guards; synthetic local regression only |
| Final full `flutter test --no-pub --reporter compact` | 115 PASS, 10 existing SKIP, 0 FAIL; 31 seconds | Final client source; all fixtures remain synthetic and local |
| Final targeted evidence + Retry tests | 29 PASS, 0 FAIL | `test/mdac_human_evidence_test.dart` 14 and existing Retry contract tests 15 |
| `flutter analyze --no-pub --no-fatal-infos` | Exit 0, 0 errors, 0 warnings, 6 existing deprecation infos | Initial run found two unused old boolean fields after minimal JSON adaptation; fields removed and rechecked |
| Flutter JavaScript Web build | PASS | Local output; no publishable key embedded, so startup intentionally refuses. Default optional WASM dry-run stalled and was stopped; JS build used `--no-wasm-dry-run --no-web-resources-cdn` |
| Android build/device | NOT RUN | Doctor cannot locate Android SDK; no Android device/emulator |
| Real G4 isolated login/Retry/UI | NOT RUN | Must follow G3 P0 PASS with real synthetic isolated identity and final server bundle; compile/tests are not button acceptance |

Web compiler reports a pre-existing missing CupertinoIcons font-family reference. MaterialIcons is present and tree-shaken. This warning is not a compile failure or a claim of visual verification.

## Reproducible G4 launch after server gate

Prepare an ignored local JSON config containing only `SUPABASE_URL` equal to `https://rvgslhjmiaunylwhcamz.supabase.co` and `SUPABASE_PUBLISHABLE_KEY` for that isolation project. Never put a service_role/secret key into a client config. Do not print the config or credentials in evidence.

```powershell
flutter run -d web-server --target lib/main_isolation.dart --dart-define-from-file=<ignored-isolation-config.json> --web-hostname 127.0.0.1 --web-port 8176
```

Use actual browser controls and synthetic isolated accounts after G3 P0 passes. Exercise both detail-dialog Retry actions, cross-button double click, lost response then deliberate retry with identical UUID, explicit rejection, unknown preservation and refresh. Separately verify independent evidence picking/upload rejection and PENDING cleanup messaging. Keep official government/IMAP workflows outside the test scope; embedded Android webviews need a supported device and mock external service before claiming their interaction PASS.

Final artifact Git SHA is recorded by the integrator; this appendix never substitutes local tests or HTTP/SSR availability for real Auth/API/G4 evidence.

## Continuation and final local candidate — 2026-10-13 MYT

App hard deletion now uses the server's stable job and `cleanup_request_id`/`cleanup_not_before`. Before managed evidence returns PURGED, it does not perform native Storage removal, mark Storage cleaned, complete the job or fail the job. PENDING, HTTP rejection, malformed confirmation and network uncertainty preserve the same job for deliberate continuation; the UI preserves selection and offers “继续清理”. After PURGED, only the remaining legal legacy manifest paths use the existing Owner cleanup path. The native removal helper refuses all three protected evidence namespaces before any removal.

Completion validation was matched to the integrator's real read-only RPC inspection: exact `job_id`, `status:'COMPLETED'`, nonnegative integer `customer_count` and `storage_object_count`. The UI uses these actual counts and never invents completion from an incomplete Map or a non-2xx PURGED body. No existing RPC parameter was changed and no new fetch-job RPC was introduced.

All four `services/*/attempt_evidence.py` copies remain byte-identical. Uploads require a timezone-qualified `grant_expires_at`, reject expired/near-expiry grants with remaining time <= request timeout + 5 seconds, and require finite `0 < request_timeout_seconds <= 60`. Refusal happens before sending file bytes; network uncertainty keeps PREPARED and never retries the upload, deletes or upserts. This is a request I/O timeout and local clock check, not a claim that client checks alone prove a globally atomic Storage cleanup boundary.

| Final local check | Actual result |
|---|---|
| Final stable full Flutter suite | 125 PASS, 10 existing SKIP, 0 FAIL; 36 seconds |
| Final targeted hard-delete/evidence/Retry suite | 39 PASS (10 + 14 + 15), 0 FAIL |
| Flutter analyze `--no-fatal-infos` | Exit 0; 0 errors, 0 warnings, 6 existing deprecation infos |
| Final guarded JS Web build | PASS; 150.5 seconds; same existing CupertinoIcons font warning |
| Python actual-client fake-HTTP/AST protocol suite | 21 PASS |
| Python frozen G1 protocol suite | 6 PASS |

Full test events are in the generated ignored `build/client-full-test-20261013.jsonl`; the integrator must preserve this artifact and bind it to the final committed source SHA. One intermediate full run finished with 124 PASS/1 FAIL/10 SKIP while completion-response source/tests were being edited. That mixed-source run is retained in the tool history and is not presented as final evidence; its exact failure output was truncated. The subsequent frozen-source full suite above passed, with the new exact-response regression included. An earlier approval review could not execute a validation command because account usage was exhausted; the command ran successfully after resumption.

The independent Web Edge executor is at `mdac-admin-web/supabase/functions/automation-evidence-cleanup/`. Its own README records 25 fake-fetch tests, strict TypeScript/ESLint validation, localhost-only CORS, per-object plan authorization and concurrent PURGED skipping. It was not deployed by this client work. Real Auth/API/Storage, Android device interactions and G4 acceptance remain the integration owner's separate live gates.
