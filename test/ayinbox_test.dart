import 'dart:convert';
import 'dart:io';

import 'package:ayinbox/ayinbox.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const testKey = 'aybox_test_key_not_real';
const base = 'https://api.test.invalid/v1';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

const jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
  'x-request-id': 'req-fixture-0001',
};

http.Response ok(String name, [int status = 200]) =>
    http.Response(fixture(name), status, headers: jsonHeaders);

/// Answers with an error fixture, using the headers fixtures/index.json lists.
http.Response errorFixture(String name, int status,
    {Map<String, String> extra = const {}}) {
  final headers = <String, String>{...jsonHeaders, ...extra};
  if (name == '429_category_rate_limited.json') {
    headers.remove('x-request-id');
  }
  return http.Response(fixture('errors/$name'), status, headers: headers);
}

class Recorder {
  final List<http.Request> requests = [];
}

AyInbox clientFor(
  Recorder recorder,
  Future<http.Response> Function(http.Request request, int call) handler, {
  int maxRetries = 2,
}) {
  final client = MockClient((request) async {
    recorder.requests.add(request);
    return handler(request, recorder.requests.length);
  });
  return AyInbox(
    apiKey: testKey,
    baseUrl: '$base/',
    httpClient: client,
    maxRetries: maxRetries,
    delay: (_) async {},
  );
}

void main() {
  group('headers', () {
    test('sends auth, user agent and accept', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async => ok('me.json'));
      final me = await api.me.get();
      expect(me.email, 'dana@example.com');
      expect(me.scopes, contains('read_campaigns'));
      expect(me.authType, 'api_key');
      final req = rec.requests.single;
      expect(req.url.toString(), '$base/me');
      expect(req.headers['authorization'], 'Bearer $testKey');
      expect(req.headers['user-agent'], 'ayinbox-dart/$sdkVersion');
      expect(req.headers['accept'], 'application/json');
    });

    test('never shows the key in toString', () {
      final api = AyInbox(apiKey: testKey, httpClient: MockClient((_) async {
        return http.Response('{}', 200);
      }));
      expect(api.toString(), isNot(contains(testKey)));
      expect(api.baseUrl, AyInbox.defaultBaseUrl);
    });

    test('sends the idempotency key and a JSON body', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async => ok('contacts_create.json'));
      final created = await api.contacts.create(
        {'email': 'lee@example.com', 'first_name': 'Lee'},
        options: const RequestOptions(idempotencyKey: 'key-123'),
      );
      expect(created.single.email, 'lee@example.com');
      final req = rec.requests.single;
      expect(req.method, 'POST');
      expect(req.headers['idempotency-key'], 'key-123');
      expect(req.headers['content-type'], startsWith('application/json'));
      expect(jsonDecode(req.body), {
        'email': 'lee@example.com',
        'first_name': 'Lee',
      });
    });
  });

  group('typed errors', () {
    final cases = <String, (int, TypeMatcher<ApiException>, String)>{
      '400_bad_request.json': (400, isA<BadRequestException>(), 'bad_request'),
      '400_invalid_cursor.json': (
        400,
        isA<BadRequestException>(),
        'bad_request'
      ),
      '401_unauthorized.json': (
        401,
        isA<AuthenticationException>(),
        'unauthorized'
      ),
      '401_api_key_holder_left.json': (
        401,
        isA<AuthenticationException>(),
        'api_key_holder_left'
      ),
      '402_insufficient_credits.json': (
        402,
        isA<PaymentRequiredException>(),
        'insufficient_credits'
      ),
      '403_forbidden.json': (
        403,
        isA<PermissionDeniedException>(),
        'forbidden'
      ),
      '403_api_key_mailbox_limited.json': (
        403,
        isA<PermissionDeniedException>(),
        'api_key_mailbox_limited'
      ),
      '404_not_found.json': (404, isA<NotFoundException>(), 'not_found'),
      '409_conflict.json': (409, isA<ConflictException>(), 'conflict'),
      '409_idempotency_outcome_unknown.json': (
        409,
        isA<ConflictException>(),
        'idempotency_outcome_unknown'
      ),
      '409_idempotent_secret_withheld.json': (
        409,
        isA<ConflictException>(),
        'idempotent_secret_withheld'
      ),
      '422_unprocessable.json': (
        422,
        isA<UnprocessableException>(),
        'unprocessable'
      ),
      '500_internal_error.json': (
        500,
        isA<InternalServerException>(),
        'internal_error'
      ),
      '503_service_unavailable.json': (
        503,
        isA<ServiceUnavailableException>(),
        'service_unavailable'
      ),
    };

    cases.forEach((name, expected) {
      test(name, () async {
        final (status, matcher, code) = expected;
        final rec = Recorder();
        final api = clientFor(rec, (r, _) async => errorFixture(name, status),
            maxRetries: 0);
        try {
          await api.campaigns.get('11111111-1111-4111-8111-111111111111');
          fail('expected an error');
        } on ApiException catch (error) {
          expect(error, matcher);
          expect(error.status, status);
          expect(error.code, code);
          expect(error.requestId, 'req-fixture-0001');
          expect(error.message, isNotEmpty);
          expect(error.toString(), isNot(contains(testKey)));
        }
      });
    });

    test('400 and 422 share ValidationException', () async {
      final rec = Recorder();
      final api = clientFor(
          rec, (r, _) async => errorFixture('422_unprocessable.json', 422));
      await expectLater(
          api.me.get(), throwsA(isA<ValidationException>()));
    });

    test('429 from the per-key limiter carries retry_after', () async {
      final rec = Recorder();
      final api = clientFor(
          rec,
          (r, _) async => errorFixture('429_api_key_rate_limited.json', 429,
              extra: {'retry-after': '12'}),
          maxRetries: 0);
      try {
        await api.me.get();
        fail('expected an error');
      } on RateLimitException catch (error) {
        expect(error.code, 'rate_limit_exceeded');
        expect(error.retryAfter, const Duration(seconds: 12));
      }
    });

    test('429 without code or request_id still maps', () async {
      final rec = Recorder();
      final api = clientFor(
          rec,
          (r, _) async =>
              errorFixture('429_category_rate_limited.json', 429),
          maxRetries: 0);
      try {
        await api.me.get();
        fail('expected an error');
      } on RateLimitException catch (error) {
        expect(error.status, 429);
        expect(error.code, 'rate_limit_exceeded');
        expect(error.requestId, isNull);
        expect(error.retryAfter, const Duration(seconds: 12));
      }
    });

    test('a non-JSON body keeps the text and the default code', () async {
      final rec = Recorder();
      final api = clientFor(
          rec, (r, _) async => http.Response('gateway exploded', 502),
          maxRetries: 0);
      try {
        await api.me.get();
        fail('expected an error');
      } on InternalServerException catch (error) {
        expect(error.status, 502);
        expect(error.code, 'internal_error');
        expect(error.body, 'gateway exploded');
      }
    });

    test('a network failure is a ConnectionException', () async {
      final rec = Recorder();
      final api = clientFor(
          rec, (r, _) async => throw http.ClientException('connection reset'),
          maxRetries: 0);
      await expectLater(
          api.me.get(), throwsA(isA<ConnectionException>()));
    });
  });

  group('retries', () {
    test('retries a 503 then succeeds', () async {
      final rec = Recorder();
      final api = clientFor(
          rec,
          (r, call) async => call == 1
              ? errorFixture('503_service_unavailable.json', 503,
                  extra: {'retry-after': '5'})
              : ok('me.json'));
      final me = await api.me.get();
      expect(me.userId, isNotEmpty);
      expect(rec.requests, hasLength(2));
    });

    test('honours Retry-After on a 429 then succeeds', () async {
      final waits = <Duration>[];
      final requests = <http.Request>[];
      final api = AyInbox(
        apiKey: testKey,
        baseUrl: base,
        delay: (d) async => waits.add(d),
        httpClient: MockClient((request) async {
          requests.add(request);
          return requests.length == 1
              ? errorFixture('429_api_key_rate_limited.json', 429,
                  extra: {'retry-after': '12'})
              : ok('me.json');
        }),
      );
      await api.me.get();
      expect(requests, hasLength(2));
      expect(waits, [const Duration(seconds: 12)]);
    });

    test('stops after maxRetries', () async {
      final rec = Recorder();
      final api = clientFor(rec,
          (r, _) async => errorFixture('503_service_unavailable.json', 503));
      await expectLater(
          api.me.get(), throwsA(isA<ServiceUnavailableException>()));
      expect(rec.requests, hasLength(3));
    });

    test('does not retry a POST without an idempotency key', () async {
      final rec = Recorder();
      final api = clientFor(rec,
          (r, _) async => errorFixture('503_service_unavailable.json', 503));
      await expectLater(api.campaigns.create(name: 'Q4 outreach'),
          throwsA(isA<ServiceUnavailableException>()));
      expect(rec.requests, hasLength(1));
    });

    test('retries a POST that carries an idempotency key', () async {
      final rec = Recorder();
      final api = clientFor(
          rec,
          (r, call) async => call == 1
              ? errorFixture('503_service_unavailable.json', 503)
              : ok('campaign.json'));
      final campaign = await api.campaigns.create(
          name: 'Q4 outreach',
          options: const RequestOptions(idempotencyKey: 'create-q4'));
      expect(campaign.name, 'Q4 outreach');
      expect(rec.requests, hasLength(2));
      expect(rec.requests.every((r) => r.headers['idempotency-key'] == 'create-q4'),
          isTrue);
    });

    test('does not retry a 500', () async {
      final rec = Recorder();
      final api = clientFor(
          rec, (r, _) async => errorFixture('500_internal_error.json', 500));
      await expectLater(
          api.me.get(), throwsA(isA<InternalServerException>()));
      expect(rec.requests, hasLength(1));
    });
  });

  group('pagination', () {
    test('walks two pages of campaigns', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async {
        final cursor = r.url.queryParameters['cursor'];
        if (cursor == null) {
          return ok('campaigns_list.json');
        }
        expect(cursor, 'c1_ZmFrZS1jdXJzb3ItcGFnZS0y');
        return ok('campaigns_list_page2.json');
      });
      final campaigns = await api.campaigns.listAll(status: 'draft').toList();
      expect(campaigns.map((c) => c.id), [
        '11111111-1111-4111-8111-111111111111',
        '11111111-1111-4111-8111-222222222222',
        '11111111-1111-4111-8111-333333333333',
      ]);
      expect(rec.requests, hasLength(2));
      expect(rec.requests.every((r) => r.url.queryParameters['status'] == 'draft'),
          isTrue);
    });

    test('first page exposes the cursor and total', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async => ok('campaigns_list.json'));
      final page = await api.campaigns.list(limit: 2);
      expect(page.data, hasLength(2));
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 'c1_ZmFrZS1jdXJzb3ItcGFnZS0y');
      expect(page.total, 3);
      expect(rec.requests.single.url.queryParameters['limit'], '2');
    });

    test('generic paginate resends the search body', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async => ok('contacts_list.json'));
      final rows = await api
          .paginate('/contacts/search',
              method: 'POST', body: {'query': 'example'})
          .toList();
      expect(rows, hasLength(2));
      expect(jsonDecode(rec.requests.single.body), {'query': 'example'});
    });
  });

  group('resources', () {
    const campaignId = '11111111-1111-4111-8111-111111111111';
    const contactId = '22222222-2222-4222-8222-111111111111';

    test('campaigns.get', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async => ok('campaign.json'));
      final campaign = await api.campaigns.get(campaignId);
      expect(campaign.id, campaignId);
      expect(campaign.status, isNotEmpty);
      expect(rec.requests.single.url.path, '/v1/campaigns/$campaignId');
    });

    test('campaigns.create sends name and extra fields', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async => ok('campaign.json'));
      await api.campaigns
          .create(name: 'Q4 outreach', fields: {'daily_limit': 30});
      expect(jsonDecode(rec.requests.single.body),
          {'daily_limit': 30, 'name': 'Q4 outreach'});
    });

    test('campaigns.pause posts to stop', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async => ok('campaign_stop.json'));
      final result = await api.campaigns.pause(campaignId);
      expect(result['status'], 'stopped');
      expect(rec.requests.single.method, 'POST');
      expect(rec.requests.single.url.path, '/v1/campaigns/$campaignId/stop');
    });

    test('contacts.list', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async => ok('contacts_list.json'));
      final page = await api.contacts.list(search: {'query': 'lee'}, limit: 10);
      expect(page.data.first.id, contactId);
      expect(rec.requests.single.method, 'POST');
      expect(rec.requests.single.url.path, '/v1/contacts/search');
    });

    test('contacts.get', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async => ok('contact.json'));
      final contact = await api.contacts.get(contactId);
      expect(contact.email, 'lee@example.com');
    });

    test('contacts.update sends an explicit null', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async {
        final rows = jsonDecode(fixture('contacts_create.json')) as List;
        return http.Response(jsonEncode(rows.first), 200, headers: jsonHeaders);
      });
      final contact =
          await api.contacts.update(contactId, {'company': 'New Co', 'phone': null});
      expect(contact.id, contactId);
      expect(rec.requests.single.method, 'PATCH');
      expect(jsonDecode(rec.requests.single.body),
          {'company': 'New Co', 'phone': null});
    });

    test('contacts.delete handles 204', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async => http.Response('', 204));
      await api.contacts.delete(contactId);
      expect(rec.requests.single.method, 'DELETE');
    });

    test('mailboxes.list', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async => ok('mailboxes_list.json'));
      final page = await api.mailboxes.list();
      expect(page.data, hasLength(2));
      expect(page.data.first.provider, 'gmail');
      expect(rec.requests.single.url.path, '/v1/emails');
    });

    test('unibox.listThreads', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async => ok('unibox_threads.json'));
      final page = await api.unibox
          .listThreads(filters: {'folder': 'inbox', 'unseen': true});
      expect(page.data.single.threadId, 'thread-example-001');
      expect(page.hasMore, isTrue);
      expect(rec.requests.single.url.queryParameters['unseen'], 'true');
    });

    test('unibox.getThread', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async => ok('unibox_thread.json'));
      final page = await api.unibox.getThread('thread-example-001');
      expect(page.data, hasLength(2));
      expect(rec.requests.single.url.queryParameters['thread_id'],
          'thread-example-001');
    });

    test('request reaches any route', () async {
      final rec = Recorder();
      final api = clientFor(rec, (r, _) async => ok('campaign.json'));
      final body = await api.request('GET', '/campaigns-overview',
          query: {'x': 1});
      expect(body, isA<Map>());
      expect(rec.requests.single.url.toString(),
          '$base/campaigns-overview?x=1');
    });
  });

  group('webhooks', () {
    final vector =
        jsonDecode(fixture('webhook_signature.json')) as Map<String, Object?>;
    final secret = vector['secret'] as String;
    final body = vector['body'] as String;
    final header = vector['header'] as String;
    final at = DateTime.fromMillisecondsSinceEpoch(
        (vector['timestamp'] as int) * 1000,
        isUtc: true);
    const webhooks = Webhooks();

    test('accepts the test vector', () {
      expect(
          webhooks.verifySignature(
              payload: body, header: header, secret: secret, now: at),
          isTrue);
      expect(
          webhooks.verifySignature(
              payload: utf8.encode(body),
              header: header,
              secret: secret,
              now: at),
          isTrue);
      final event = webhooks.constructEvent(
          payload: body, header: header, secret: secret, now: at);
      expect(event['event_type'], 'campaign.reply_received');
    });

    test('rejects a tampered body', () {
      expect(
          webhooks.verifySignature(
              payload: body.replaceFirst('{}', '{"x":1}'),
              header: header,
              secret: secret,
              now: at),
          isFalse);
    });

    test('rejects a wrong secret', () {
      expect(
          webhooks.verifySignature(
              payload: body, header: header, secret: 'whsec_wrong', now: at),
          isFalse);
      expect(
          () => webhooks.constructEvent(
              payload: body, header: header, secret: 'whsec_wrong', now: at),
          throwsA(isA<SignatureVerificationException>()));
    });

    test('rejects an old timestamp and a malformed header', () {
      expect(
          webhooks.verifySignature(
              payload: body,
              header: header,
              secret: secret,
              now: at.add(const Duration(seconds: 301))),
          isFalse);
      expect(
          webhooks.verifySignature(
              payload: body, header: 'v1=abc', secret: secret, now: at),
          isFalse);
    });
  });
}
