# MDAC fill-preview deployment status

更新时间：2026-08-26

## Current state

The real MDAC headless Worker source is in `services/mdac-fill-preview/` and is pushed to the private GitHub repository `mm7768/passport-mdac-app`. The latest code commit is `35aa9bc` (`Detect MDAC slider and route to manual review`). Subsequent repository-only status records are in commits `22384b5` and `a0b32bf`. The Flutter Debug APK containing the editable MDAC defaults page was built successfully at `build/app/outputs/flutter-apk/app-debug.apk`.

Supabase production has the following relevant migrations applied: `mdac_worker_leases`, `mdac_batch_enqueue`, `mdac_settings`, `mdac_settings_snapshot`, and `mdac_settings_write_lock`. The App stores editable business defaults in `mdac_settings`; the enqueue RPC copies them into `automation_batches.mdac_settings_snapshot`.

## Railway services

- Azure OCR Service `36ec81e4-ddab-4b8a-ae10-fe0b9c65a4d2`: Online; previously configured and polling OCR batches. End-to-end脱敏文件验收 remains pending.
- MDAC dry-run Service `f562efb6-7b55-4ea8-b9bb-fc041b586b6b` (`glorious-wonder`): created but not configured/running.
- MDAC fill-preview Service `70260bb4-8fb7-40e1-a25a-d3381084eac7` (`wholesome-rebirth`): GitHub-connected with Root Directory `services/mdac-fill-preview`; Raw Editor currently contains non-secret runtime variables as an unsaved draft, with `SUPABASE_SERVICE_ROLE_KEY` blank. It is not yet an operational Worker.

## Security boundary

Railway business defaults are no longer required. Only runtime/safety variables belong in Railway. `MDAC_EXECUTION_MODE=FILL_PREVIEW` and `ALLOW_REAL_SUBMIT=false` must remain unchanged. The Worker detects the official slider CAPTCHA and writes `CAPTCHA_SLIDER` / `NEEDS_HUMAN_INTERVENTION`; it never uses OCR/trajectory simulation, never clicks Submit, and never treats an unconfirmed result as success.

## Next manual step

When Railway Variables is usable, the user must paste the Supabase Service Role Key into the protected Secret field and click Update Variables. Then inspect the build and runtime logs. Do not paste the key into chat, GitHub, or the APK. Do not add the business default variables to Railway; they belong in the App settings page.


## 2026-08-26 13:06 deployment observation

After the user confirmed deployment, Railway applied 23 changes. The `wholesome-rebirth` fill-preview Service entered `Building` with the 15 variables present, including the masked Service Role Key. The separate `glorious-wonder` dry-run Service showed `Build failed just now`; it is unrelated to the fill-preview deployment and was not modified. The fill-preview build had not finished at the time of observation.


## 2026-08-26 13:15 runtime observation

The service-specific `services/mdac-fill-preview/railway.toml` was added and pushed in commit `cdff417` to override the repository-root Azure OCR start command. Railway created deployment `016e6954` and marked `wholesome-rebirth` Online with Deployment successful. The deployment log now shows only `Starting Container`; the previous `/app/worker/azure_ocr_worker.py` error is no longer present, but the application log viewer has not yet shown the expected Worker startup/heartbeat lines.
