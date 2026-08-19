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

  // --- Screenshots ---------------------------------------------------------

  /// Every page of [uri], following `links.next`.
  Future<List<Object?>> _allPages(Uri uri, String action) async {
    final all = <Object?>[];
    var next = uri;
    while (true) {
      final response = await http.get(next, headers: _headers);
      all.addAll(_dataList(response, action));
      final links =
          response.body is Map ? (response.body as Map)['links'] : null;
      final link = links is Map ? links['next'] : null;
      if (link is! String || link.isEmpty) return all;
      next = Uri.parse(link);
    }
  }

  /// The app resource id for [bundleId], or null when the app has no
  /// record yet.
  Future<String?> findApp(String bundleId) async {
    final data = await _allPages(
        Uri.parse('$baseUrl/apps?filter[bundleId]=$bundleId&limit=200'),
        'look up the app');
    for (final entry in data) {
      if (entry is! Map) continue;
      final attributes = entry['attributes'];
      if (attributes is Map && attributes['bundleId'] == bundleId) {
        final id = entry['id'];
        if (id is String && id.isNotEmpty) return id;
      }
    }
    return null;
  }

  /// The one iOS version open for editing.
  ///
  /// Returns null when there is none, and also when there is more than
  /// one — App Store Connect only ever has a single edit version, so an
  /// ambiguous answer means this client is looking at something it does
  /// not understand. Callers delete assets based on this, so it fails
  /// closed rather than guessing.
  Future<String?> editableVersion(String appId) async {
    const editable = {
      'PREPARE_FOR_SUBMISSION',
      'DEVELOPER_REJECTED',
      'REJECTED',
      'METADATA_REJECTED',
      'INVALID_BINARY',
    };
    final data = await _allPages(
        Uri.parse('$baseUrl/apps/$appId/appStoreVersions'
            '?filter[platform]=IOS&limit=200'),
        'list the app versions');
    final candidates = <String>[];
    for (final entry in data) {
      if (entry is! Map) continue;
      final attributes = entry['attributes'];
      if (attributes is! Map) continue;
      // `appStoreState` is the long-standing field; newer responses also
      // carry `appVersionState`. Accept whichever is present.
      final state = attributes['appStoreState'] ?? attributes['appVersionState'];
      final id = entry['id'];
      if (editable.contains('$state') && id is String && id.isNotEmpty) {
        candidates.add(id);
      }
    }
    return candidates.length == 1 ? candidates.single : null;
  }

  /// Every screenshot App Store Connect holds for [versionId], grouped the
  /// way it stores them: one set per locale and display type.
  ///
  /// Throws when the API returns an entry without an id or a file name —
  /// two nameless screenshots would otherwise look like duplicates of each
  /// other, and the caller deletes duplicates.
  Future<List<AscScreenshotSet>> screenshotSets(String versionId) async {
    final sets = <AscScreenshotSet>[];
    final locales = await _allPages(
        Uri.parse('$baseUrl/appStoreVersions/$versionId'
            '/appStoreVersionLocalizations?limit=200'),
        'list the version locales');
    for (final entry in locales) {
      if (entry is! Map) continue;
      final attributes = entry['attributes'];
      final locale = attributes is Map ? attributes['locale'] : null;
      final localizationId = entry['id'];
      if (locale is! String || localizationId is! String) {
        throw SetupException(
          'App Store Connect returned a version locale without a locale or '
          'an id.',
        );
      }
      final setData = await _allPages(
          Uri.parse('$baseUrl/appStoreVersionLocalizations/$localizationId'
              '/appScreenshotSets?limit=200'),
          'list the screenshot sets');
      for (final setEntry in setData) {
        if (setEntry is! Map) continue;
        final setId = setEntry['id'];
        final setAttributes = setEntry['attributes'];
        if (setId is! String) {
          throw SetupException(
              'App Store Connect returned a screenshot set without an id.');
        }
        sets.add(AscScreenshotSet(
          id: setId,
          locale: locale,
          displayType: setAttributes is Map
              ? '${setAttributes['screenshotDisplayType']}'
              : '',
          screenshots: await _screenshots(setId),
        ));
      }
    }
    return sets;
  }

  Future<List<AscScreenshot>> _screenshots(String setId) async {
    final data = await _allPages(
        Uri.parse('$baseUrl/appScreenshotSets/$setId/appScreenshots?limit=200'),
        'list the screenshots');
    final screenshots = <AscScreenshot>[];
    for (final entry in data) {
      if (entry is! Map) continue;
      final id = entry['id'];
      final attributes = entry['attributes'];
      final fileName = attributes is Map ? attributes['fileName'] : null;
      if (id is! String ||
          id.isEmpty ||
          fileName is! String ||
          fileName.isEmpty) {
        throw SetupException(
          'App Store Connect returned a screenshot without an id or a file '
          'name — refusing to decide what is a duplicate from that.',
        );
      }
      screenshots.add(AscScreenshot(id: id, fileName: fileName));
    }
    return screenshots;
  }

  Future<void> deleteScreenshot(String screenshotId) async {
    final response = await http.delete(
        Uri.parse('$baseUrl/appScreenshots/$screenshotId'),
        headers: _headers);
    if (!response.ok) {
      throw SetupException(
        'Could not delete screenshot $screenshotId: '
        '${_errorDetail(response)}',
      );
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

/// One screenshot as App Store Connect holds it.
class AscScreenshot {
  final String id;
  final String fileName;

  AscScreenshot({required this.id, required this.fileName});
}

/// The screenshots for one locale and one display type — App Store
/// Connect's own unit of grouping.
class AscScreenshotSet {
  final String id;
  final String locale;
  final String displayType;
  final List<AscScreenshot> screenshots;

  AscScreenshotSet({
    required this.id,
    required this.locale,
    required this.displayType,
    required this.screenshots,
  });
}
