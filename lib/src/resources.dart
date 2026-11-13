import 'client.dart';
import 'models.dart';

Map<String, Object?> _object(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

String _seg(String id) => Uri.encodeComponent(id);

/// Walks every page of a paginated list, following `next_cursor` while
/// `has_more` is true. The same query and body are sent on every page.
Stream<Map<String, Object?>> paginateRaw(
  AyInbox client,
  String path, {
  Map<String, Object?>? query,
  String method = 'GET',
  Object? body,
  RequestOptions? options,
}) async* {
  String? cursor;
  while (true) {
    final pageQuery = <String, Object?>{...?query};
    if (cursor != null) {
      pageQuery['cursor'] = cursor;
    }
    final response = _object(await client.send(method, path,
        query: pageQuery, body: body, options: options, retrySafe: true));
    final page = Page<Map<String, Object?>>.fromJson(response, (m) => m);
    for (final item in page.data) {
      yield item;
    }
    final next = page.nextCursor;
    if (!page.hasMore || next == null) {
      return;
    }
    cursor = next;
  }
}

/// Adds [AyInbox.paginate] for any paginated path.
extension Paginate on AyInbox {
  /// Auto-pages any `{data, pagination}` list. For `POST /contacts/search`
  /// pass `method: 'POST'` and the search [body].
  Stream<Map<String, Object?>> paginate(
    String path, {
    Map<String, Object?>? query,
    String method = 'GET',
    Object? body,
    RequestOptions? options,
  }) =>
      paginateRaw(this, path,
          query: query, method: method, body: body, options: options);
}

/// `GET /me`.
class MeResource {
  MeResource(this._client);

  final AyInbox _client;

  /// Validates the credential and returns who it acts for. Needs no scope.
  Future<Identity> get({RequestOptions? options}) async =>
      Identity(_object(await _client.send('GET', '/me', options: options)));
}

/// Campaigns.
class CampaignsResource {
  CampaignsResource(this._client);

  final AyInbox _client;

  Map<String, Object?> _query(
          String? q, String? status, String? folder, int? limit) =>
      {'q': q, 'status': status, 'folder': folder, 'limit': limit};

  /// One page of campaigns. Needs `READ_CAMPAIGNS`. [status] is one of
  /// `draft`, `active`, `paused`, `completed`. Use a [limit] of 1 to 100.
  Future<Page<Campaign>> list({
    String? q,
    String? status,
    String? folder,
    String? cursor,
    int? limit,
    RequestOptions? options,
  }) async {
    final response = await _client.send('GET', '/campaigns',
        query: {..._query(q, status, folder, limit), 'cursor': cursor},
        options: options);
    return Page<Campaign>.fromJson(_object(response), Campaign.new);
  }

  /// Every campaign, page by page.
  Stream<Campaign> listAll({
    String? q,
    String? status,
    String? folder,
    int? limit,
    RequestOptions? options,
  }) =>
      paginateRaw(_client, '/campaigns',
              query: _query(q, status, folder, limit), options: options)
          .map(Campaign.new);

  /// One campaign. Needs `READ_CAMPAIGNS`.
  Future<Campaign> get(String id, {RequestOptions? options}) async =>
      Campaign(_object(await _client.send('GET', '/campaigns/${_seg(id)}',
          options: options)));

  /// Creates a draft campaign. Needs `WRITE_CAMPAIGNS`. Creating never sends
  /// mail. [fields] takes any other create field by its JSON key, such as
  /// `steps`, `senders` or `daily_limit`.
  Future<Campaign> create({
    required String name,
    Map<String, Object?> fields = const {},
    RequestOptions? options,
  }) async =>
      Campaign(_object(await _client.send('POST', '/campaigns',
          body: {...fields, 'name': name}, options: options)));

  /// Pauses an active campaign (`POST /campaigns/{id}/stop`). Sends nothing.
  /// Needs `WRITE_CAMPAIGNS`, `START_CAMPAIGNS` or `SEND_CAMPAIGNS`. Returns
  /// `{"status": "stopped"}`.
  Future<Map<String, Object?>> pause(String id,
          {RequestOptions? options}) async =>
      _object(await _client.send('POST', '/campaigns/${_seg(id)}/stop',
          options: options));
}

/// Contacts.
class ContactsResource {
  ContactsResource(this._client);

  final AyInbox _client;

  /// One page of contacts (`POST /contacts/search`). Needs `READ_CONTACTS`.
  /// [search] is the search body (`query`, `campaign_ids`, `sort_by` and so
  /// on); empty matches everything.
  Future<Page<Contact>> list({
    Map<String, Object?> search = const {},
    String? cursor,
    int? limit,
    String? category,
    RequestOptions? options,
  }) async {
    final response = await _client.send('POST', '/contacts/search',
        query: {'cursor': cursor, 'limit': limit, 'category': category},
        body: search,
        options: options,
        retrySafe: true);
    return Page<Contact>.fromJson(_object(response), Contact.new);
  }

  /// Every matching contact, page by page, resending the same [search].
  Stream<Contact> listAll({
    Map<String, Object?> search = const {},
    int? limit,
    String? category,
    RequestOptions? options,
  }) =>
      paginateRaw(_client, '/contacts/search',
              method: 'POST',
              query: {'limit': limit, 'category': category},
              body: search,
              options: options)
          .map(Contact.new);

  /// One contact with its detail fields. Needs `READ_CONTACTS`.
  Future<Contact> get(String id, {RequestOptions? options}) async =>
      Contact(_object(await _client.send('GET', '/contacts/${_seg(id)}',
          options: options)));

  /// Creates or updates (by email) one or more contacts. Needs
  /// `WRITE_CONTACTS`. [contacts] is one contact map or a list of them; the
  /// result is always a list.
  ///
  /// Adding a contact to an active or completed campaign can send mail.
  Future<List<Contact>> create(Object contacts,
      {RequestOptions? options}) async {
    if (contacts is! Map && contacts is! List) {
      throw ArgumentError.value(
          contacts, 'contacts', 'must be a Map or a List of Maps');
    }
    final response = await _client.send('POST', '/contacts',
        body: contacts, options: options);
    if (response is List) {
      return response.whereType<Map>().map(_object).map(Contact.new).toList();
    }
    if (response is Map) {
      return [Contact(_object(response))];
    }
    return const [];
  }

  /// Updates a contact. Needs `WRITE_CONTACTS`. Only the keys in [fields]
  /// change; `campaigns`, `categories` and `custom_fields` replace.
  Future<Contact> update(String id, Map<String, Object?> fields,
          {RequestOptions? options}) async =>
      Contact(_object(await _client.send('PATCH', '/contacts/${_seg(id)}',
          body: fields, options: options)));

  /// Deletes a contact. Needs `WRITE_CONTACTS`.
  Future<void> delete(String id, {RequestOptions? options}) async {
    await _client.send('DELETE', '/contacts/${_seg(id)}', options: options);
  }
}

/// Mailboxes (`/emails`).
class MailboxesResource {
  MailboxesResource(this._client);

  final AyInbox _client;

  /// One page of mailboxes. Needs `READ_EMAILS`.
  Future<Page<Mailbox>> list({
    String? q,
    String? tag,
    String? cursor,
    int? limit,
    RequestOptions? options,
  }) async {
    final response = await _client.send('GET', '/emails',
        query: {'q': q, 'tag': tag, 'cursor': cursor, 'limit': limit},
        options: options);
    return Page<Mailbox>.fromJson(_object(response), Mailbox.new);
  }

  /// Every mailbox, page by page.
  Stream<Mailbox> listAll({
    String? q,
    String? tag,
    int? limit,
    RequestOptions? options,
  }) =>
      paginateRaw(_client, '/emails',
              query: {'q': q, 'tag': tag, 'limit': limit}, options: options)
          .map(Mailbox.new);
}

/// The Unibox: one inbox across every connected mailbox.
class UniboxResource {
  UniboxResource(this._client);

  final AyInbox _client;

  /// One page of conversations, newest message per thread. Needs
  /// `READ_UNIBOX`. [filters] takes the other query parameters by name, such
  /// as `folder`, `unseen` or `campaign_id`.
  Future<Page<MessagePreview>> listThreads({
    Map<String, Object?> filters = const {},
    String? cursor,
    int? limit,
    RequestOptions? options,
  }) async {
    final response = await _client.send('GET', '/unibox',
        query: {...filters, 'cursor': cursor, 'limit': limit},
        options: options);
    return Page<MessagePreview>.fromJson(_object(response), MessagePreview.new);
  }

  /// Every conversation matching [filters], page by page.
  Stream<MessagePreview> listThreadsAll({
    Map<String, Object?> filters = const {},
    int? limit,
    RequestOptions? options,
  }) =>
      paginateRaw(_client, '/unibox',
              query: {...filters, 'limit': limit}, options: options)
          .map(MessagePreview.new);

  /// The messages of one thread. Needs `READ_UNIBOX`. Omit [emailId] to read
  /// across every mailbox.
  Future<Page<MessagePreview>> getThread(
    String threadId, {
    String? emailId,
    String? cursor,
    int? limit,
    RequestOptions? options,
  }) async {
    final response = await _client.send('GET', '/unibox/thread',
        query: {
          'thread_id': threadId,
          'email_id': emailId,
          'cursor': cursor,
          'limit': limit,
        },
        options: options);
    return Page<MessagePreview>.fromJson(_object(response), MessagePreview.new);
  }
}
