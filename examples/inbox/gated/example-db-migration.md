gate_reason: applies a destructive ALTER TABLE to a production database

# Add an index to the campaigns table

## Goal
Add a composite index on `campaigns(account_id, status)` to speed up the
dashboard query. This runs `ALTER TABLE` against the live database, so it must
pause for human approval before executing.

## Context
The dashboard query does a full scan on `campaigns` filtered by account and
status. A migration file lives under `migrations/`. This is a risky op (DB
mutation) — it stays gated.

## Acceptance Criteria
- A migration file adds the composite index, with a reversible `down` step
- The migration is applied only after explicit human "go"
- Query plan confirms the index is used after migration
