# Dependable upgrades and capacity stability

## Outcome

One dependable upgrade path for native and Docker deployments: no silently inconsistent state, preserved traffic history, unchanged services left running, and only the downtime required by the deployment method. All implementation belongs to the associated pull request; this plan is not a substitute for working code and passing acceptance tests.

## Objectives

- [ ] Stage and validate complete dashboard/management releases before activation; preserve a compatible known-good release and recover from copy, validation, startup, health-check and interrupted-update failures. Keep backend/frontend release identity consistent. Do not restart unchanged services or perform duplicate restarts. Respect database schema compatibility during recovery.
- [ ] Check reporting schema compatibility before stopping services. Preserve supported history, cursors and protective backups; isolate reporting preparation/backup/migration failures from independent public API upgrades while recording a truthful degraded/incomplete result and retry path.
- [ ] Include MCP in automatic bundled-Python patch selection within the operator's chosen family. Keep old interpreters/releases for rollback; resolve compatible offline bundles before mutating configuration.
- [ ] Unify runtime configuration transactions across manual, selected, all and image updates. Resolve every selection before mutation; restore all settings on pre-commit failure; retain committed settings when only post-commit edge work fails. Preserve graceful nginx switching, draining and generation rollback.
- [ ] Investigate and correct recurring telemetry_spool capacity warnings without deleting unread/active data or merely hiding a collection failure. Distinguish unread backlog, active-file bytes, consumed rotated files, producer rate and collector throughput. Bound collector work fairly, reclaim only safely consumed data, and preserve cursor/reopen/rotation correctness.
- [ ] Persist capacity incidents across collector restarts. Notify on meaningful onset, worsening, deliberately bounded reminders and recovery rather than repeating the same warning every 10-20 minutes. Keep unresolved incidents visible and actionable; never silence genuine danger through unlimited budgets.
- [ ] Expose capacity diagnostics in CLI and dashboard: configured/effective limits, measured usage and high-water marks, repeated saturation, backlog/lag and growth where observable, and evidence-based suggested settings with units, assumptions, observation window and insufficient-data states. Respect available disk/memory headroom and environment-controlled settings. Never promise a universally ideal value or auto-increase limits without operator intent.
- [ ] Add an upgrade plan and interactive target checklist. Show dashboard/management, individual query/search versions, MCP and static-domain configuration targets with eligibility/reasons. Select changed targets by default, allow explicit subsets and force/retry, and provide matching noninteractive CLI/dashboard operations. Static data synchronization stays separate from software upgrades.
- [ ] Determine eligibility from relevant implementation, dependencies, templates and effective configuration fingerprints, not only the manager's global version. Skip unchanged code/configuration without restarting workers, refreshing static corpus data, issuing certificates or changing DNS during local/image application. Preserve explicit redeploy and rollback.
- [ ] Track per-target desired/applied fingerprints and outcome so selective application cannot falsely mark skipped required targets as globally current. Make interrupted and partially successful upgrades idempotent and retryable. Distinguish serving health from upgrade completion; include MCP and enabled dashboard in appropriate readiness reporting.
- [ ] Keep native and Docker semantics aligned, persisted identities/settings/tokens/custom pages intact, memory overlap bounded and telemetry ingestion healthy during upgrades. Single-container replacement remains a documented restart, not a zero-downtime promise.
- [ ] Add general correctness/fault-injection tests and disposable systemd/Docker acceptance coverage for unchanged/selected/all upgrades, late preparation failure, post-commit edge failure, MCP patch transitions, dashboard recovery, supported/unsupported migrations, spool backlog recovery, rotation/restarts, persistent incident deduplication and advisory calculations. Run applicable Python, shell, frontend/browser and deployment workflows; record actual results and limitations.
- [ ] Update focused operator documentation, CLI help, dashboard contracts and release metadata. Mark the pull request ready for review only after runtime implementation and applicable checks pass. Do not merge on the operator's behalf.

## Reported symptom

Telegram repeatedly reports: `getBible capacity: telemetry_spool` / `Unread/active telemetry spools exceed their configured budget; they have not been deleted.` The observed frequency is roughly 10-20 minutes. A larger budget may be appropriate, but only diagnostics can establish whether the cause is undersizing, unfair/insufficient collection, stale rotation accounting, or another failure. Preserve unread events while resolving the cause.

## Validation record

Implementation and validation pending. Record completed work and exact checks in the pull request as commits land.
