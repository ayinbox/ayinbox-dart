import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'errors.dart';

/// Verifies AY Inbox webhook deliveries.
class Webhooks {
  const Webhooks();

  /// Checks an `X-Ayinbox-Signature` header against the raw request body.
  ///
  /// [payload] is the exact body as a `String` or a `List<int>`, before any
  /// JSON parsing. [secret] is the endpoint secret including `whsec_`.
  bool verifySignature({
    required Object payload,
    required String header,
    required String secret,
    int toleranceSeconds = 300,
    DateTime? now,
  }) {
    final List<int> bytes;
    if (payload is String) {
      bytes = utf8.encode(payload);
    } else if (payload is List<int>) {
      bytes = payload;
    } else {
      return false;
    }

    int? timestamp;
    final signatures = <String>[];
    for (final part in header.split(',')) {
      final index = part.indexOf('=');
      if (index <= 0) {
        continue;
      }
      final key = part.substring(0, index).trim();
      final value = part.substring(index + 1).trim();
      if (key == 't') {
        timestamp = int.tryParse(value);
      } else if (key == 'v1') {
        signatures.add(value);
      }
    }
    if (timestamp == null || signatures.isEmpty) {
      return false;
    }

    final nowSeconds =
        (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    if ((nowSeconds - timestamp).abs() > toleranceSeconds) {
      return false;
    }

    final hmac = Hmac(sha256, utf8.encode(secret));
    final expected =
        hmac.convert([...utf8.encode('$timestamp.'), ...bytes]).toString();
    var matched = false;
    for (final signature in signatures) {
      if (_constantTimeEquals(expected, signature)) {
        matched = true;
      }
    }
    return matched;
  }

  /// Verifies the signature, then parses the event envelope
  /// (`id`, `event_type`, `organization_id`, `created_at`, `data`).
  ///
  /// Throws [SignatureVerificationException] when it does not verify.
  Map<String, Object?> constructEvent({
    required Object payload,
    required String header,
    required String secret,
    int toleranceSeconds = 300,
    DateTime? now,
  }) {
    if (!verifySignature(
        payload: payload,
        header: header,
        secret: secret,
        toleranceSeconds: toleranceSeconds,
        now: now)) {
      throw SignatureVerificationException(
          'Webhook signature did not verify.');
    }
    final text =
        payload is String ? payload : utf8.decode(payload as List<int>);
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw SignatureVerificationException(
          'Webhook body is not a JSON object.');
    }
    return Map<String, Object?>.from(decoded);
  }

  static bool _constantTimeEquals(String a, String b) {
    final x = a.codeUnits;
    final y = b.codeUnits;
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length; i++) {
      diff |= x[i] ^ (i < y.length ? y[i] : 0);
    }
    return diff == 0;
  }
}
