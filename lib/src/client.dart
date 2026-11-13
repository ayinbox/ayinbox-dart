import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'env.dart';
import 'errors.dart';
import 'resources.dart';
import 'version.dart';
import 'webhooks.dart';

/// Options for one request.
class RequestOptions {
  const RequestOptions({this.idempotencyKey, this.timeout, this.headers});

  /// Sent as `Idempotency-Key`. Pass one on every mutating call you might
  /// retry; without it a POST or PATCH is never retried automatically.
  final String? idempotencyKey;

  /// Overrides the client timeout for this request.
  final Duration? timeout;

  /// Extra headers for this request.
  final Map<String, String>? headers;
}

/// The AY Inbox API client.
class AyInbox {
  /// Creates a client.
  ///
  /// [apiKey] falls back to the `AYINBOX_API_KEY` environment variable and
  /// [baseUrl] to `AYINBOX_BASE_URL`, then `https://api.ayinbox.com/v1`.
  /// Pass [httpClient] to supply your own transport. [delay] replaces the
  /// wait between retries (useful in tests).
  AyInbox({
    String? apiKey,
    String? baseUrl,
    this.timeout = const Duration(seconds: 30),
    this.maxRetries = 2,
    http.Client? httpClient,
    Future<void> Function(Duration)? delay,
  })  : _apiKey = _resolveKey(apiKey),
        baseUrl = _resolveBaseUrl(baseUrl),
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null,
        _delay = delay ?? Future<void>.delayed {
    if (maxRetries < 0) {
      throw ArgumentError.value(maxRetries, 'maxRetries', 'must be >= 0');
    }
  }

  /// The default base URL.
  static const String defaultBaseUrl = 'https://api.ayinbox.com/v1';

  final String _apiKey;

  /// Base URL with no trailing slash.
  final String baseUrl;

  /// Default timeout per attempt.
  final Duration timeout;

  /// Automatic retries after the first attempt. 0 disables them.
  final int maxRetries;

  final http.Client _http;
  final bool _ownsHttp;
  final Future<void> Function(Duration) _delay;
  final Random _random = Random();

  /// `GET /me`.
  late final MeResource me = MeResource(this);

  /// Campaigns.
  late final CampaignsResource campaigns = CampaignsResource(this);

  /// Contacts.
  late final ContactsResource contacts = ContactsResource(this);

  /// Mailboxes (`/emails`).
  late final MailboxesResource mailboxes = MailboxesResource(this);

  /// The Unibox.
  late final UniboxResource unibox = UniboxResource(this);

  /// Webhook signature verification (local, no HTTP).
  final Webhooks webhooks = const Webhooks();

  static String _resolveKey(String? apiKey) {
    final key = apiKey ?? readEnv('AYINBOX_API_KEY');
    if (key == null || key.trim().isEmpty) {
      throw ArgumentError(
          'No API key: pass apiKey or set the AYINBOX_API_KEY environment variable.');
    }
    return key.trim();
  }

  static String _resolveBaseUrl(String? baseUrl) {
    var url = baseUrl ?? readEnv('AYINBOX_BASE_URL') ?? defaultBaseUrl;
    if (url.trim().isEmpty) {
      url = defaultBaseUrl;
    }
    url = url.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// Closes the HTTP client when this client created it.
  void close() {
    if (_ownsHttp) {
      _http.close();
    }
  }

  @override
  String toString() => 'AyInbox(baseUrl: $baseUrl, apiKey: [redacted])';

  /// Sends any request to the API and returns the decoded JSON, null for an
  /// empty body, or the raw bytes when the response is not JSON.
  ///
  /// [path] is relative to the base URL, for example `/campaigns-overview`.
  /// Null query values are dropped; lists are joined with commas.
  Future<Object?> request(
    String method,
    String path, {
    Map<String, Object?>? query,
    Object? body,
    RequestOptions? options,
  }) =>
      send(method, path, query: query, body: body, options: options);

  /// Same as [request], with [retrySafe] marking a POST that only reads.
  Future<Object?> send(
    String method,
    String path, {
    Map<String, Object?>? query,
    Object? body,
    RequestOptions? options,
    bool retrySafe = false,
  }) async {
    final verb = method.toUpperCase();
    final uri = _buildUri(path, query);
    final idempotencyKey = options?.idempotencyKey;
    final hasBody = body != null;
    final bodyBytes = hasBody ? utf8.encode(jsonEncode(body)) : null;
    final perAttempt = options?.timeout ?? timeout;
    final safe = retrySafe ||
        idempotencyKey != null ||
        !(verb == 'POST' || verb == 'PATCH');

    for (var attempt = 0;; attempt++) {
      final req = http.Request(verb, uri);
      req.headers['Authorization'] = 'Bearer $_apiKey';
      req.headers['User-Agent'] = 'ayinbox-dart/$sdkVersion';
      req.headers['Accept'] = 'application/json';
      if (idempotencyKey != null) {
        req.headers['Idempotency-Key'] = idempotencyKey;
      }
      final extra = options?.headers;
      if (extra != null) {
        req.headers.addAll(extra);
      }
      if (bodyBytes != null) {
        req.headers['Content-Type'] = 'application/json';
        req.bodyBytes = bodyBytes;
      }

      http.Response response;
      try {
        final streamed = await _http.send(req).timeout(perAttempt);
        response = await http.Response.fromStream(streamed).timeout(perAttempt);
      } on TimeoutException {
        if (safe && attempt < maxRetries) {
          await _delay(_backoff(attempt));
          continue;
        }
        throw RequestTimeoutException(
            '$verb $path timed out after ${perAttempt.inMilliseconds} ms');
      } on http.ClientException catch (error) {
        if (safe && attempt < maxRetries) {
          await _delay(_backoff(attempt));
          continue;
        }
        throw ConnectionException(
            '$verb $path failed: ${error.message}', error);
      }

      final status = response.statusCode;
      if (status >= 200 && status < 300) {
        return _decode(response);
      }

      final error =
          ApiException.fromResponse(status, response.headers, response.body);
      final retryable = status == 429 ||
          ((status == 502 || status == 503 || status == 504) && safe);
      if (retryable && attempt < maxRetries) {
        await _delay(_waitFor(error, attempt));
        continue;
      }
      throw error;
    }
  }

  Uri _buildUri(String path, Map<String, Object?>? query) {
    final normalized = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$baseUrl$normalized');
    final params = <String, String>{...uri.queryParameters};
    query?.forEach((key, value) {
      if (value == null) {
        return;
      }
      if (value is Iterable) {
        params[key] = value.map((v) => '$v').join(',');
      } else if (value is DateTime) {
        params[key] = value.toUtc().toIso8601String();
      } else {
        params[key] = '$value';
      }
    });
    return params.isEmpty ? uri : uri.replace(queryParameters: params);
  }

  Object? _decode(http.Response response) {
    final bytes = response.bodyBytes;
    if (bytes.isEmpty) {
      return null;
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    if (text.trim().isEmpty) {
      return null;
    }
    try {
      return jsonDecode(text);
    } on FormatException {
      return bytes;
    }
  }

  Duration _waitFor(ApiException error, int attempt) {
    Duration? asked;
    if (error is RateLimitException) {
      asked = error.retryAfter;
    } else if (error is ServiceUnavailableException) {
      asked = error.retryAfter;
    }
    if (asked != null) {
      const cap = Duration(seconds: 120);
      return asked > cap ? cap : asked;
    }
    return _backoff(attempt);
  }

  Duration _backoff(int attempt) {
    final ceiling = min(8000, 500 * pow(2, attempt).toInt());
    return Duration(milliseconds: _random.nextInt(ceiling + 1));
  }
}
