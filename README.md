# AY Inbox Dart SDK

The official Dart client for the [AY Inbox](https://ayinbox.com) REST API. It works in Dart and Flutter apps.

AY Inbox is a hosted cold email platform. It warms mailboxes, sends cold email at a paced daily volume and brings every reply into one inbox, where Aya, its AI assistant, drafts the answer from the campaign brain and offers a meeting time.

AY Inbox is a hosted service. This repository holds the Dart client library for its public REST API. The service itself is not open source.

Access to the hosted service is invite only for now: ask at team@ayinbox.com.

## Install

Not on pub.dev yet. Until it is, depend on this repository from Git in your `pubspec.yaml`:

```yaml
dependencies:
  ayinbox:
    git:
      url: https://github.com/ayinbox/ayinbox-dart.git
      ref: main
```

Then run `dart pub get` (or `flutter pub get`). The package needs Dart 3.3 or later.

## Quick start

```dart
import 'package:ayinbox/ayinbox.dart';

Future<void> main() async {
  final client = AyInbox(); // reads AYINBOX_API_KEY
  final me = await client.me.get();
  print('Signed in as ${me.email} with ${me.scopes}');

  await for (final campaign in client.campaigns.listAll()) {
    print('${campaign.name}: ${campaign.status}');
  }

  try {
    final created = await client.contacts.create(
      {'email': 'lee@example.com', 'first_name': 'Lee'},
      options: const RequestOptions(idempotencyKey: 'contact-lee-2026-11-13'),
    );
    print('Saved ${created.first.id}');
  } on PermissionDeniedException catch (error) {
    print('Missing scope: ${error.code} (request ${error.requestId})');
  }
  client.close();
}
```

## Configuration

| Argument | Default | Notes |
|---|---|---|
| `apiKey` | `AYINBOX_API_KEY` | An API key (`aybox_...`) or an OAuth access token (`ayat_...`), sent as `Authorization: Bearer`. |
| `baseUrl` | `AYINBOX_BASE_URL`, then `https://api.ayinbox.com/v1` | A trailing slash is removed. |
| `timeout` | 30 seconds | Per attempt. |
| `maxRetries` | 2 | Retries after the first attempt. 0 turns them off. |
| `httpClient` | a new `http.Client` | Pass your own `package:http` client (for example a proxy-aware one). `close()` only closes a client the SDK created. |

Environment variables are read on the Dart VM and Flutter mobile and desktop. On the web pass `apiKey` yourself, and never ship a secret key in a browser app.

The key never appears in `toString()`, in error messages or in exceptions.

## Resources

| Resource | Method | HTTP route | Scope |
|---|---|---|---|
| `me` | `get()` | `GET /me` | none |
| `campaigns` | `list()`, `listAll()` | `GET /campaigns` | `READ_CAMPAIGNS` |
| `campaigns` | `get(id)` | `GET /campaigns/{id}` | `READ_CAMPAIGNS` |
| `campaigns` | `create(name:, fields:)` | `POST /campaigns` | `WRITE_CAMPAIGNS` |
| `campaigns` | `pause(id)` | `POST /campaigns/{id}/stop` | `WRITE_CAMPAIGNS`, `START_CAMPAIGNS` or `SEND_CAMPAIGNS` |
| `contacts` | `list()`, `listAll()` | `POST /contacts/search` | `READ_CONTACTS` |
| `contacts` | `get(id)` | `GET /contacts/{id}` | `READ_CONTACTS` |
| `contacts` | `create(contactOrList)` | `POST /contacts` | `WRITE_CONTACTS` |
| `contacts` | `update(id, fields)` | `PATCH /contacts/{id}` | `WRITE_CONTACTS` |
| `contacts` | `delete(id)` | `DELETE /contacts/{id}` | `WRITE_CONTACTS` |
| `mailboxes` | `list()`, `listAll()` | `GET /emails` | `READ_EMAILS` |
| `unibox` | `listThreads()`, `listThreadsAll()` | `GET /unibox` | `READ_UNIBOX` |
| `unibox` | `getThread(threadId)` | `GET /unibox/thread` | `READ_UNIBOX` |
| `webhooks` | `verifySignature()`, `constructEvent()` | local, no HTTP | none |

Results are light models (`Identity`, `Campaign`, `Contact`, `Mailbox`, `MessagePreview`) with typed getters for the documented fields. Every field the server sends, including ones added later, stays readable through `raw` or `model['field_name']`. Unknown fields never cause an error.

Every other route is reachable through `request`, with the same authentication, retries and errors:

```dart
final overview = await client.request('GET', '/campaigns-overview');
final started = await client.request(
  'POST',
  '/campaigns/$campaignId/start',
  options: const RequestOptions(idempotencyKey: 'start-q4'),
);
```

`request` returns the decoded JSON, `null` for an empty body, or the raw bytes when the response is not JSON.

## Errors

Every exception extends `AyInboxException` (a sealed class). HTTP errors extend `ApiException`, which carries `status`, `code`, `message`, `reason`, `requestId`, the decoded `body` and the response `headers`. Branch on `code` and `status`, never on `message`.

| Exception | Status |
|---|---|
| `BadRequestException` (a `ValidationException`) | 400 |
| `AuthenticationException` | 401 |
| `PaymentRequiredException` | 402 |
| `PermissionDeniedException` | 403 |
| `NotFoundException` | 404 |
| `ConflictException` | 409 |
| `UnprocessableException` (a `ValidationException`) | 422 |
| `RateLimitException` (with `retryAfter`) | 429 |
| `InternalServerException` | 500, 501, 502, 504 and other 5xx |
| `ServiceUnavailableException` (with `retryAfter`) | 503 |
| `ConnectionException` | no answer: DNS, TLS, dropped connection |
| `RequestTimeoutException` | the request took longer than its timeout |
| `SignatureVerificationException` | a webhook signature did not verify |

Some 429 answers carry no `code` and no `request_id`; the SDK still maps them to `RateLimitException` with code `rate_limit_exceeded` and reads the wait from `Retry-After`, `retry_after` or `retry_after_ms`.

## Retries and timeouts

The SDK retries 429, 502, 503, 504, connection errors and timeouts, up to `maxRetries` times. It waits for `Retry-After` when the server sends one (capped at 120 seconds), otherwise an exponential backoff with full jitter (base 0.5 seconds, cap 8 seconds).

A `POST` or `PATCH` without an idempotency key is never retried, except on 429 (the server did not run the request). A 500 is never retried, and neither is `409 idempotency_outcome_unknown`. `contacts.list` is a POST that only reads, so it is retried like a GET.

Override the timeout for one call with `RequestOptions(timeout: Duration(seconds: 60))`.

## Pagination

`list` methods return one `Page` with `data`, `nextCursor`, `hasMore` and an optional `total`. Pass `nextCursor` back as `cursor` for the next page. The `listAll` methods return a `Stream` that follows the cursor for you:

```dart
await for (final contact in client.contacts.listAll(search: {'query': 'acme'})) {
  print(contact.email);
}
```

For any other paginated route, use `client.paginate('/suppressions')` (or `client.paginate('/contacts/search', method: 'POST', body: {...})`). Use a `limit` between 1 and 100.

## Idempotency

Every call takes `RequestOptions(idempotencyKey: '...')`, sent as the `Idempotency-Key` header. The server keeps the outcome for 24 hours: the same key with the same request replays the first answer, and the same key with a different request answers `409`. The SDK does not generate keys for you, so a POST or PATCH you want retried needs one you choose. Use a new key for each distinct change.

## Webhooks

Verify each delivery against the raw body before parsing it. The secret is the endpoint secret including its `whsec_` prefix.

```dart
const webhooks = Webhooks();
final event = webhooks.constructEvent(
  payload: rawBody, // String or List<int>, exactly as received
  header: request.headers['x-ayinbox-signature']!,
  secret: endpointSecret,
); // throws SignatureVerificationException
print(event['event_type']);
```

`verifySignature` returns a `bool` instead. Both reject a timestamp more than 300 seconds from now (change it with `toleranceSeconds`) and compare in constant time. Deduplicate on the event `id`, which equals the `X-Ayinbox-Event-Id` header.

## Calls that send email

- These calls put real email on the wire:
  - `campaigns.start` (`POST /campaigns/{id}/start`, through `request`): needs `START_CAMPAIGNS` or `SEND_CAMPAIGNS`.
  - `campaigns.update` (`PATCH /campaigns/{id}`, through `request`) with `status: "active"` (and `completed` or `paused_undeliverable`): needs `START_CAMPAIGNS` or `SEND_CAMPAIGNS` in addition to `WRITE_CAMPAIGNS`.
  - `campaigns.leads.resume` (`POST /campaigns/{id}/leads/{contactId}/resume`, through `request`) on a finished campaign: needs `START_CAMPAIGNS` or `SEND_CAMPAIGNS`.
  - `unibox.reply` (`POST /unibox/reply`) and `unibox.approveAgentDraft` (`POST /unibox/agent-drafts/{id}/approve`), through `request`: need `WRITE_UNIBOX`. A key with `WRITE_UNIBOX` can send replies from any mailbox it can reach.
  - Through `request`: `POST /unibox/compose`, `POST /emails/{id}/send`, `POST /campaigns/{id}/test-email`, the first-email review queue (`/campaigns/{id}/reviews/...`), placement tests: `SEND_CAMPAIGNS` (compose: `WRITE_UNIBOX`).
- Adding contacts can send mail without calling start: contacts added to an `active` campaign are queued; a `completed` campaign starts again on its own when leads are added; a contact that comes to match a segment linked to a sending campaign is enrolled. This applies to `contacts.create` and `contacts.update` with `campaigns`.
- `START_CAMPAIGNS` starts, resumes and pauses campaigns and nothing else. `SEND_CAMPAIGNS` covers everything `START_CAMPAIGNS` covers plus the other sending actions. `WRITE_CAMPAIGNS` alone edits drafts and pauses, and cannot start anything.
- A key for a model that reads the inbox should use the "Agent: read and draft" preset (84574239): every read scope plus `AI_DRAFT`, with nothing that writes or sends.
- Some calls spend workspace credits (AI drafts, research, enrichment, paid tools). They answer `402 insufficient_credits` when the balance is out.
- Retrying a send without an idempotency key can send twice. Pass an idempotency key on every mutating call you might retry.

## Examples

- [`example/list_campaigns.dart`](example/list_campaigns.dart): list every campaign.
- [`example/verify_webhook.dart`](example/verify_webhook.dart): verify a webhook delivery.

Run one with `AYINBOX_API_KEY=aybox_... dart run example/list_campaigns.dart`.

## Documentation

- API reference: https://docs.ayinbox.com/api/
- Endpoints and scopes: https://docs.ayinbox.com/api/endpoints/
- Permissions: https://docs.ayinbox.com/api/permissions/
- Error codes: https://docs.ayinbox.com/api/error-codes/

## License

MIT. See [LICENSE](LICENSE).
