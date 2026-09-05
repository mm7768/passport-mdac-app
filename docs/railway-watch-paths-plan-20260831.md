# Railway Watch Paths Plan

Date: 2026-08-31

## Purpose

Prevent a change to one isolated Worker from automatically redeploying every
Railway service connected to `mm7768/passport-mdac-app`.

This document records the reviewed production mapping and the proposed Watch
Paths. It does not apply any production change.

Railway treats Watch Paths as gitignore-style patterns evaluated from the
repository root. The official monorepo example uses a leading slash, such as
`/packages/backend/**`.

Reference: <https://docs.railway.com/deployments/monorepo#watch-paths>

## Production mapping reviewed

| Railway service | Root directory | Worker role |
| --- | --- | --- |
| `passport-mdac-app` | repository root | Azure OCR |
| `wholesome-rebirth` | `services/mdac-fill-preview` | MDAC fill-preview |
| `pleasing-acceptance` | `services/gmail-pin-worker` | Gmail PIN |
| `selfless-enchantment` | `services/registration-check-worker` | Registration Check |
| `courageous-fascination` | `services/visit-pass-check-worker` | Visit Pass Check |

All five services track the GitHub `main` branch. None of the inspected service
configurations currently exposes a Watch Paths setting.

## Proposed Watch Paths

### Azure OCR — `passport-mdac-app`

```text
/worker/**
/requirements-worker.txt
/Dockerfile
/railway.toml
```

The OCR service builds from the repository root, so its root-level dependency,
Docker, and Railway configuration files must be included explicitly.

### MDAC fill-preview — `wholesome-rebirth`

```text
/services/mdac-fill-preview/**
```

### Gmail PIN — `pleasing-acceptance`

```text
/services/gmail-pin-worker/**
```

### Registration Check — `selfless-enchantment`

```text
/services/registration-check-worker/**
```

### Visit Pass Check — `courageous-fascination`

```text
/services/visit-pass-check-worker/**
```

## Important constraint

The service directories are currently isolated. If shared runtime code is later
added outside a service directory, every dependent service must also watch that
shared path. Otherwise a shared-code change could fail to redeploy its consumers.

Supabase migrations are intentionally not included because they are not copied
into any Worker runtime image. Database migrations must continue to use their own
explicit apply and verification process.

## Safe application sequence

1. Re-read all five production service configs and confirm the root directories
   still match this document.
2. Apply Watch Paths to one service at a time in the production environment.
3. Read the service config back after every update and compare the exact pattern
   list.
4. Do not force a redeploy merely to test the setting.
5. On the next real code change, verify that only the service whose watched path
   changed receives a new automatic deployment.
6. If a root-level file changes, inspect whether it is a runtime dependency before
   assuming that no service should redeploy.

## Rollback

If a required deployment is missed, clear the affected service's Watch Paths and
redeploy only that service. Then add the missing dependency path before enabling
the filter again.
