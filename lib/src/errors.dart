import 'dart:convert';

/// Base of every error this package throws.
sealed class AyInboxException implements Exception {
  AyInboxException(this.message);

  /// Human-readable text. Never branch on it.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The API answered with a non-2xx status.
class ApiException extends AyInboxException {
  ApiException({
    required this.status,
    required this.code,
    required String message,
    this.reason,
    this.requestId,
    this.body,
    this.headers = const {},
  }) : super(message);

  /// HTTP status code.
  final int status;

  /// Stable machine key. Branch on this plus [status].
  final String code;

  /// Finer key on a few codes, or null.
  final String? reason;

  /// The request id from the body or the `X-Request-Id` header.
  final String? requestId;

  /// The decoded JSON body, or the raw text when it was not JSON.
  final Object? body;

  /// Response headers, lowercase names.
  final Map<String, String> headers;

  /// Builds the matching subclass from a response.
  static ApiException fromResponse(
    int status,
    Map<String, String> headers,
    String text,
  ) {
    Object? body = text;
    Map<String, Object?> map = const {};
    if (text.isNotEmpty) {
      try {
        final decoded = jsonDecode(text);
        body = decoded;
        if (decoded is Map<String, Object?>) {
          map = decoded;
        }
      } on FormatException {
        body = text;
      }
    }

    final fallback = _defaultCodes[status] ??
        (status >= 500 ? 'internal_error' : 'http_$status');
    String code = fallback;
    final bodyCode = map['code'];
    final bodyError = map['error'];
    if (bodyCode is String && bodyCode.isNotEmpty) {
      code = bodyCode;
    } else if (bodyError is String && _codePattern.hasMatch(bodyError)) {
      code = bodyError;
    }

    final bodyMessage = map['message'];
    final message = bodyMessage is String && bodyMessage.isNotEmpty
        ? bodyMessage
        : (text.isNotEmpty && map.isEmpty ? text : 'HTTP $status');
    final bodyReason = map['reason'];
    final reason = bodyReason is String ? bodyReason : null;
    final bodyRequestId = map['request_id'];
    final requestId =
        bodyRequestId is String ? bodyRequestId : headers['x-request-id'];

    switch (status) {
      case 400:
        return BadRequestException(
            status: status,
            code: code,
            message: message,
            reason: reason,
            requestId: requestId,
            body: body,
            headers: headers);
      case 401:
        return AuthenticationException(
            status: status,
            code: code,
            message: message,
            reason: reason,
            requestId: requestId,
            body: body,
            headers: headers);
      case 402:
        return PaymentRequiredException(
            status: status,
            code: code,
            message: message,
            reason: reason,
            requestId: requestId,
            body: body,
            headers: headers);
      case 403:
        return PermissionDeniedException(
            status: status,
            code: code,
            message: message,
            reason: reason,
            requestId: requestId,
            body: body,
            headers: headers);
      case 404:
        return NotFoundException(
            status: status,
            code: code,
            message: message,
            reason: reason,
            requestId: requestId,
            body: body,
            headers: headers);
      case 409:
        return ConflictException(
            status: status,
            code: code,
            message: message,
            reason: reason,
            requestId: requestId,
            body: body,
            headers: headers);
      case 422:
        return UnprocessableException(
            status: status,
            code: code,
            message: message,
            reason: reason,
            requestId: requestId,
            body: body,
            headers: headers);
      case 429:
        return RateLimitException(
            status: status,
            code: code,
            message: message,
            reason: reason,
            requestId: requestId,
            body: body,
            headers: headers,
            retryAfter: parseRetryAfter(headers, map));
      case 503:
        return ServiceUnavailableException(
            status: status,
            code: code,
            message: message,
            reason: reason,
            requestId: requestId,
            body: body,
            headers: headers,
            retryAfter: parseRetryAfter(headers, map));
    }
    if (status >= 500) {
      return InternalServerException(
          status: status,
          code: code,
          message: message,
          reason: reason,
          requestId: requestId,
          body: body,
          headers: headers);
    }
    return ApiException(
        status: status,
        code: code,
        message: message,
        reason: reason,
        requestId: requestId,
        body: body,
        headers: headers);
  }

  /// Reads the wait the server asked for: `Retry-After`, then `retry_after`,
  /// then `retry_after_ms` rounded up to whole seconds.
  static Duration? parseRetryAfter(
    Map<String, String> headers,
    Map<String, Object?> body,
  ) {
    final header = headers['retry-after'];
    if (header != null) {
      final seconds = num.tryParse(header.trim());
      if (seconds != null && seconds >= 0) {
        return Duration(milliseconds: (seconds * 1000).round());
      }
    }
    final retryAfter = body['retry_after'];
    if (retryAfter is num && retryAfter >= 0) {
      return Duration(milliseconds: (retryAfter * 1000).round());
    }
    final retryAfterMs = body['retry_after_ms'];
    if (retryAfterMs is num && retryAfterMs >= 0) {
      return Duration(seconds: (retryAfterMs / 1000).ceil());
    }
    return null;
  }

  static final RegExp _codePattern = RegExp(r'^[a-z0-9_]+$');

  static const Map<int, String> _defaultCodes = {
    400: 'bad_request',
    401: 'unauthorized',
    402: 'insufficient_credits',
    403: 'forbidden',
    404: 'not_found',
    409: 'conflict',
    422: 'unprocessable',
    429: 'rate_limit_exceeded',
    500: 'internal_error',
    501: 'not_implemented',
    503: 'service_unavailable',
  };

  @override
  String toString() {
    final id = requestId == null ? '' : ', request_id: $requestId';
    return '$runtimeType($status $code$id): $message';
  }
}

/// A 400 or 422: the request was refused as invalid.
abstract class ValidationException extends ApiException {
  ValidationException({
    required super.status,
    required super.code,
    required super.message,
    super.reason,
    super.requestId,
    super.body,
    super.headers,
  });
}

/// 400 Bad Request.
class BadRequestException extends ValidationException {
  BadRequestException({
    required super.status,
    required super.code,
    required super.message,
    super.reason,
    super.requestId,
    super.body,
    super.headers,
  });
}

/// 422 Unprocessable.
class UnprocessableException extends ValidationException {
  UnprocessableException({
    required super.status,
    required super.code,
    required super.message,
    super.reason,
    super.requestId,
    super.body,
    super.headers,
  });
}

/// 401: the credential is missing, wrong or no longer valid.
class AuthenticationException extends ApiException {
  AuthenticationException({
    required super.status,
    required super.code,
    required super.message,
    super.reason,
    super.requestId,
    super.body,
    super.headers,
  });
}

/// 402: the workspace is out of credits or not entitled.
class PaymentRequiredException extends ApiException {
  PaymentRequiredException({
    required super.status,
    required super.code,
    required super.message,
    super.reason,
    super.requestId,
    super.body,
    super.headers,
  });
}

/// 403: the credential lacks a scope or the action is not allowed.
class PermissionDeniedException extends ApiException {
  PermissionDeniedException({
    required super.status,
    required super.code,
    required super.message,
    super.reason,
    super.requestId,
    super.body,
    super.headers,
  });
}

/// 404 Not Found.
class NotFoundException extends ApiException {
  NotFoundException({
    required super.status,
    required super.code,
    required super.message,
    super.reason,
    super.requestId,
    super.body,
    super.headers,
  });
}

/// 409 Conflict, including the idempotency conflicts.
class ConflictException extends ApiException {
  ConflictException({
    required super.status,
    required super.code,
    required super.message,
    super.reason,
    super.requestId,
    super.body,
    super.headers,
  });
}

/// 429 Too Many Requests.
class RateLimitException extends ApiException {
  RateLimitException({
    required super.status,
    required super.code,
    required super.message,
    super.reason,
    super.requestId,
    super.body,
    super.headers,
    this.retryAfter,
  });

  /// How long the server asked to wait, when it said.
  final Duration? retryAfter;
}

/// 500, 501, 502, 504 and any other 5xx except 503.
class InternalServerException extends ApiException {
  InternalServerException({
    required super.status,
    required super.code,
    required super.message,
    super.reason,
    super.requestId,
    super.body,
    super.headers,
  });
}

/// 503 Service Unavailable.
class ServiceUnavailableException extends ApiException {
  ServiceUnavailableException({
    required super.status,
    required super.code,
    required super.message,
    super.reason,
    super.requestId,
    super.body,
    super.headers,
    this.retryAfter,
  });

  /// How long the server asked to wait, when it said.
  final Duration? retryAfter;
}

/// The request never got an HTTP answer: DNS, TLS or a dropped connection.
class ConnectionException extends AyInboxException {
  ConnectionException(super.message, [this.cause]);

  /// The underlying error.
  final Object? cause;
}

/// The request took longer than its timeout.
class RequestTimeoutException extends AyInboxException {
  RequestTimeoutException(super.message);
}

/// A webhook signature did not verify.
class SignatureVerificationException extends AyInboxException {
  SignatureVerificationException(super.message);
}
