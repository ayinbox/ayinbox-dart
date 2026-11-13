String? _string(Object? value) => value is String ? value : null;

int? _int(Object? value) => value is num ? value.toInt() : null;

bool? _bool(Object? value) => value is bool ? value : null;

DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];

Map<String, Object?> _map(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

/// A JSON object from the API with typed getters for the fields the API
/// documents. Every field, documented or not, stays readable through [raw].
abstract class ApiObject {
  ApiObject(this.raw);

  /// The decoded JSON object as the server sent it.
  final Map<String, Object?> raw;

  /// Any field by its JSON key.
  Object? operator [](String key) => raw[key];

  @override
  String toString() => '$runtimeType($raw)';
}

/// The caller behind a credential (`GET /me`).
class Identity extends ApiObject {
  Identity(super.raw);

  String get userId => _string(raw['user_id']) ?? '';
  String get email => _string(raw['email']) ?? '';
  String get name => _string(raw['name']) ?? '';
  String get firstName => _string(raw['first_name']) ?? '';
  String get lastName => _string(raw['last_name']) ?? '';
  String? get organizationId => _string(raw['organization_id']);
  String? get organizationName => _string(raw['organization_name']);

  /// `api_key`, `oauth` or `jwt`.
  String get authType => _string(raw['auth_type']) ?? '';

  /// Lowercased permission names, sorted.
  List<String> get scopes => _strings(raw['scopes']);
}

/// A campaign.
class Campaign extends ApiObject {
  Campaign(super.raw);

  String get id => _string(raw['id']) ?? '';
  String get name => _string(raw['name']) ?? '';
  String get description => _string(raw['description']) ?? '';
  String? get organizationId => _string(raw['organization_id']);

  /// `draft`, `active`, `paused`, `completed` or a `paused_*` status. Treat
  /// unknown values as opaque.
  String get status => _string(raw['status']) ?? '';
  int? get dailyLimit => _int(raw['daily_limit']);
  String get timezone => _string(raw['timezone']) ?? '';
  bool? get stopOnReply => _bool(raw['stop_on_reply']);
  bool? get reviewFirstEmails => _bool(raw['review_first_emails']);
  DateTime? get startDate => _time(raw['start_date']);
  DateTime? get endDate => _time(raw['end_date']);
  DateTime? get createdAt => _time(raw['created_at']);
  DateTime? get updatedAt => _time(raw['updated_at']);
}

/// A contact. Search rows and create results use this shape; `get` adds
/// detail fields reachable through [raw].
class Contact extends ApiObject {
  Contact(super.raw);

  String get id => _string(raw['id']) ?? '';
  String get email => _string(raw['email']) ?? '';
  String get firstName => _string(raw['first_name']) ?? '';
  String get lastName => _string(raw['last_name']) ?? '';
  String get company => _string(raw['company']) ?? '';
  String get phone => _string(raw['phone']) ?? '';
  bool? get subscribed => _bool(raw['subscribed']);

  /// `valid`, `risky`, `invalid` or `unknown`.
  String get verificationStatus => _string(raw['verification_status']) ?? '';

  Map<String, String> get customFields {
    final out = <String, String>{};
    _map(raw['custom_fields']).forEach((key, value) {
      if (value is String) {
        out[key] = value;
      }
    });
    return out;
  }

  /// Campaigns the contact is in, as `{id, name}` objects.
  List<Map<String, Object?>> get campaigns {
    final value = raw['campaigns'];
    return value is List ? value.whereType<Map>().map(_map).toList() : [];
  }

  /// Present on search rows filtered to exactly one campaign. Loosely typed.
  Map<String, Object?>? get campaignLead {
    final value = raw['campaign_lead'];
    return value is Map ? _map(value) : null;
  }

  DateTime? get createdAt => _time(raw['created_at']);
  DateTime? get updatedAt => _time(raw['updated_at']);
}

/// A connected mailbox (`/emails`).
class Mailbox extends ApiObject {
  Mailbox(super.raw);

  String get id => _string(raw['id']) ?? '';
  String get email => _string(raw['email']) ?? '';
  String get name => _string(raw['name']) ?? '';

  /// `gmail`, `outlook` or `smtp_imap`.
  String get provider => _string(raw['provider']) ?? '';
  String get status => _string(raw['status']) ?? '';
  int? get campaignLimit => _int(raw['campaign_limit']);
  int? get minWaitTime => _int(raw['min_wait_time']);
  List<String> get tags => _strings(raw['tags']);
  DateTime? get lastSyncedAt => _time(raw['last_synced_at']);
  DateTime? get createdAt => _time(raw['created_at']);
}

/// A Unibox row: the newest message of a conversation, or a message in a
/// thread read.
class MessagePreview extends ApiObject {
  MessagePreview(super.raw);

  String get id => _string(raw['id']) ?? '';

  /// The mailbox id.
  String get emailId => _string(raw['email_id']) ?? '';

  /// A provider thread string, not a UUID.
  String get threadId => _string(raw['thread_id']) ?? '';
  List<String> get fromAddr => _strings(raw['from_addr']);
  List<String> get toAddr => _strings(raw['to_addr']);
  String get subject => _string(raw['subject']) ?? '';
  String get snippet => _string(raw['snippet']) ?? '';
  DateTime? get internalDate => _time(raw['internal_date']);
  bool get seen => _bool(raw['seen']) ?? false;
  bool get hasUnread => _bool(raw['has_unread']) ?? false;
  int? get messageCount => _int(raw['message_count']);
  String? get campaignId => _string(raw['campaign_id']);
}

/// One page of a paginated list.
class Page<T> {
  Page({
    required this.data,
    required this.nextCursor,
    required this.hasMore,
    required this.total,
    required this.raw,
  });

  /// Builds a page from a `{data, pagination}` envelope.
  factory Page.fromJson(
    Map<String, Object?> json,
    T Function(Map<String, Object?>) item,
  ) {
    final data = json['data'];
    final pagination = _map(json['pagination']);
    final cursor = _string(pagination['next_cursor']);
    return Page<T>(
      data: data is List
          ? data.whereType<Map>().map(_map).map(item).toList()
          : [],
      nextCursor: cursor == null || cursor.isEmpty ? null : cursor,
      hasMore: _bool(pagination['has_more']) ?? false,
      total: _int(pagination['total']),
      raw: json,
    );
  }

  final List<T> data;

  /// Pass back as `cursor` for the next page. Null on the last page.
  final String? nextCursor;
  final bool hasMore;

  /// Present on some lists only. Never rely on it.
  final int? total;

  /// The whole response, including extras such as `counts`.
  final Map<String, Object?> raw;
}
