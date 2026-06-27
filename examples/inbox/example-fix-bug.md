# Fix the rate-limit bug in the API

## Goal
The rate limiter returns 429 too aggressively (after 100 req/s instead of the
intended 100 req/min). Make it a sliding-window limit of 100 requests per minute
per IP, and return a `Retry-After` header on breach. When done, every route under
`src/routes/` must honor the limit and unit tests must cover the boundary.

## Context
The Express entry point is `src/app.ts`. We already use `express-rate-limit`
elsewhere — reuse that pattern. No rate-limit tests exist yet.

## Acceptance Criteria
- All routes return 429 after 100 req/min per IP, with a correct `Retry-After` header
- Unit tests cover the limit boundary (99th request passes, 101st is rejected)
- `npm test` passes
