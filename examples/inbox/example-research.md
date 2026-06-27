# Research: caching strategy for the account-tree endpoint

## Goal
Produce a short design note recommending a caching approach for the
`getAccountTree` endpoint, which is slow under load. Output a markdown file at
`docs/account-tree-caching.md` comparing in-memory vs. Redis with a recommendation.

## Context
The endpoint walks a deep MCC hierarchy on every call. Read-heavy, rarely mutated.
This is a research/design task — no code changes expected, just the design note.

## Acceptance Criteria
- `docs/account-tree-caching.md` exists with an in-memory vs. Redis comparison
- A clear recommendation with rationale (latency, invalidation, memory footprint)
- At least one cache-invalidation strategy described
