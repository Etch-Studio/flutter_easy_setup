import '../exceptions.dart';
import '../utils/http_json_client.dart';

/// App Store Connect API client for Developer Portal resources:
/// bundle ID registration and App ID capabilities.
///
/// Authenticated with an [AscJwt]-generated bearer token; HTTP is injected
/// for tests. Ported from the verified v1 client (V2_PLAN.md §8), rebuilt
/// on HttpJsonClient.
class AscApiClient {
  static const defaultBaseUrl = 'https://api.appstoreconnect.apple.com/v1';

  final HttpJsonClient http;
  final String token;
  final String baseUrl;

  AscApiClient({
    required this.http,
    required this.token,
    this.baseUrl = defaultBaseUrl,
  });

  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};

  /// Returns the bundle ID resource ID, or null when it is not registered.
  /// Follows pagination — the exact match may sit on a later page since
  /// the ASC filter matches substrings.
  Future<String?> findBundleId(String identifier) async {
    var uri = Uri.parse('$baseUrl/bundleIds'
        '?filter[identifier]=$identifier&fields[bundleIds]=identifier'
        '&limit=200');
    while (true) {
      final response = await http.get(uri, headers: _headers);
      final data = _dataList(response, 'listing bundle IDs');
      for (final item in data) {
        if (item is Map &&
            (item['attributes'] as Map?)?['identifier'] == identifier) {
          return item['id'] as String?;
        }
      }
      final links =
          response.body is Map ? (response.body as Map)['links'] : null;
      final next = links is Map ? links['next'] : null;
      if (next is! String || next.isEmpty) return null;
      uri = Uri.parse(next);
    }
  }

  /// Registers the bundle ID on the Developer Portal. Returns its
  /// resource ID. A conflict (already registered, e.g. a race with another
  /// run) resolves to the existing resource instead of failing.
  Future<String> registerBundleId(String identifier, String name) async {
    final response = await http.post(
      Uri.parse('$baseUrl/bundleIds'),
      headers: _headers,
      body: {
        'data': {
          'type': 'bundleIds',
          'attributes': {
            'identifier': identifier,
            'name': name,
            'platform': 'IOS',
          },
        },
      },
    );
    if (response.status == 409) {
      final existing = await findBundleId(identifier);
      if (existing != null) return existing;
    }
    final data = _dataMap(response, 'registering bundle ID $identifier');
    return data['id'] as String;
  }

  /// Capability types currently enabled on the App ID
  /// (e.g. `PUSH_NOTIFICATIONS`, `APP_GROUPS`).
  Future<Set<String>> capabilityTypes(String bundleIdResourceId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/bundleIds/$bundleIdResourceId/bundleIdCapabilities'
          '?fields[bundleIdCapabilities]=capabilityType'),
      headers: _headers,
    );
    final data = _dataList(response, 'listing capabilities');
    return {
      for (final item in data)
        if (item is Map &&
            (item['attributes'] as Map?)?['capabilityType'] is String)
          (item['attributes'] as Map)['capabilityType'] as String,
    };
  }

  /// Enables a capability type on the App ID.
  Future<void> enableCapability(
      String bundleIdResourceId, String capabilityType) async {
    final response = await http.post(
      Uri.parse('$baseUrl/bundleIdCapabilities'),
      headers: _headers,
      body: {
        'data': {
          'type': 'bundleIdCapabilities',
          'attributes': {'capabilityType': capabilityType},
          'relationships': {
            'bundleId': {
              'data': {'type': 'bundleIds', 'id': bundleIdResourceId},
            },
          },
        },
      },
    );
    if (!response.ok) {
      throw SetupException(
          'ASC API error enabling $capabilityType: ${_errorDetail(response)}');
    }
  }

  List<Object?> _dataList(JsonResponse response, String action) {
    if (!response.ok) {
      throw SetupException('ASC API error $action: ${_errorDetail(response)}');
    }
    final data = response.body is Map ? (response.body as Map)['data'] : null;
    if (data is! List) {
      throw SetupException('Unexpected ASC API response while $action.');
    }
    return data;
  }

  Map<Object?, Object?> _dataMap(JsonResponse response, String action) {
    if (!response.ok) {
      throw SetupException('ASC API error $action: ${_errorDetail(response)}');
    }
    final data = response.body is Map ? (response.body as Map)['data'] : null;
    if (data is! Map) {
      throw SetupException('Unexpected ASC API response while $action.');
    }
    return data;
  }

  String _errorDetail(JsonResponse response) {
    final body = response.body;
    final errors = body is Map ? body['errors'] : null;
    if (errors is List && errors.isNotEmpty && errors.first is Map) {
      final first = errors.first as Map;
      return 'HTTP ${response.status} — '
          '${first['title'] ?? ''}: ${first['detail'] ?? ''}';
    }
    return 'HTTP ${response.status}';
  }
}
