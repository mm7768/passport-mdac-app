# Retry/counts acceptance fixtures

These scripts run **only** in isolated schemas on the nonproduction acceptance project `rvgslhjmiaunylwhcamz`. They are not production migrations. Never run them against `xdmcxhvdqsbcqedfprcy`.

The fixture schemas clone production metadata (27 tables including a local copy of the auth-user FK target, 17 enums, 143 function definitions, 77 business triggers, all table constraints, 64 additional indexes and RLS policies). No production rows or credentials are copied. `is_active_user` is the real profile/expiry predicate, not a constant stub. Schema names are remapped, and Storage existence checks use synthetic metadata instead of real objects. The Data API is not configured to expose these schemas.

The metadata bootstrap and storage adapter used for this run are included in the delivered evidence bundle. Scripts intentionally require a fresh fixture namespace; do not reset or delete a previously populated schema to rerun them without reviewing ownership and pending tests.

Order after metadata bootstrap and namespace-mapped migration application:

1. `fixture.sql`
2. `owner_and_guard.sql`
3. `roles_and_mdac.sql`
4. `other_automation_workers.sql`
5. `blocked_and_counts.sql`
6. Storage test adapter, then `ocr_recovery.sql`
7. `success_results_preserved.sql`
8. `final_retry.sql`

Run the same claim query in two independent SQL transactions after step 8, using worker IDs `ISOLATED-race-1` and `ISOLATED-race-2`:

```sql
begin;
set local role service_role;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select set_config('request.headers','{"x-mdac-protocol":"2"}',true);
with got as (
  select id from mdac_retry_app_20261027.claim_mdac_batch('ISOLATED-race-1',900,5)
)
select count(*) claims,pg_sleep(2) from got;
commit;
```

Observed results are 1 and 0. Only the winner then claims the failed item and completes it through heartbeat → external permit → submission marker → simulated result writeback. All 19 prior successful result rows remain untouched; final counts are 20 tasks, 20 successes, 22 historical attempts, and 20 result rows.

The delivered final SQL evidence includes additional assertions for cross-batch active-customer rejection and canonical dashboard counts. Queries switch to real PostgreSQL `authenticated`/`service_role` roles and synthetic JWT claims; they do not perform a real Supabase Auth sign-in. Provider results are simulated. Flutter transport tests use MockClient, and widget tests cover the shared real Retry button. These boundaries must remain explicit in release review.
