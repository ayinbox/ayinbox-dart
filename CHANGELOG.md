# Changelog

## 0.1.0

- First release: `me`, campaigns (list, get, create, pause), contacts (list, get, create, update, delete), mailboxes (list), Unibox (list threads, get thread).
- Generic `request` and `paginate` for every other route.
- Typed exceptions, retries with backoff that honour `Retry-After`, per-call idempotency keys.
- Webhook signature verification.
