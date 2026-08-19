import '../exceptions.dart';
import '../utils/http_json_client.dart';
import '../utils/process_runner.dart';

/// One app in an AdMob publisher account.
class AdmobApp {
  /// Externally visible ID the SDK needs (`ca-app-pub-…~…`).
  final String appId;

  /// `IOS` or `ANDROID`.
  final String platform;

  /// Name shown in the AdMob UI — the manual name, or the store name for a
  /// store-linked app.
  final String? displayName;

  /// `linkedAppInfo.appStoreId`: the numeric Apple ID on iOS, the package
  /// name on Android. Absent while the app is not linked to a store.
  final String? storeId;

  AdmobApp({
    required this.appId,
    required this.platform,
    this.displayName,
    this.storeId,
  });

  factory AdmobApp.fromJson(Map<Object?, Object?> json) {
    final linked = json['linkedAppInfo'];
    final manual = json['manualAppInfo'];
    return AdmobApp(
      appId: '${json['appId']}',
      platform: '${json['platform']}'.toUpperCase(),
      displayName: linked is Map && linked['displayName'] is String
          ? linked['displayName'] as String
          : (manual is Map ? manual['displayName'] as String? : null),
      storeId: linked is Map ? linked['appStoreId'] as String? : null,
    );
  }
}

/// One ad unit in an AdMob publisher account.
class AdmobAdUnit {
  /// Externally visible ID the SDK needs (`ca-app-pub-…/…`).
  final String adUnitId;

  /// The `appId` of the app this unit belongs to.
  final String appId;

  final String? displayName;
  final String? adFormat;

  AdmobAdUnit({
    required this.adUnitId,
    required this.appId,
    this.displayName,
    this.adFormat,
  });

  factory AdmobAdUnit.fromJson(Map<Object?, Object?> json) => AdmobAdUnit(
        adUnitId: '${json['adUnitId']}',
        appId: '${json['appId']}',
        displayName: json['displayName'] as String?,
        adFormat: json['adFormat'] as String?,
      );
}

/// Client for the AdMob API v1beta (V2_PLAN.md §5.4).
///
/// Listing apps and ad units is generally available, so the IDs an app needs
/// can always be read instead of copied out of the console by hand. Creating
/// them (`accounts.apps.create` / `accounts.adUnits.create`) is limited
/// access and answers 403 until Google grants it — the create calls here
/// return null in that case so the caller can fall back to console creation
/// (Plan B) with the discovery path still doing the ID work.
///
/// Auth is OAuth 2.0 user credentials — AdMob does not accept service
/// accounts. Three sources, in order: a ready access token, a refresh token
/// exchange, or gcloud's application-default credentials.
class AdmobApi {
  static const defaultBaseUrl = 'https://admob.googleapis.com/v1beta';
  static const tokenUrl = 'https://oauth2.googleapis.com/token';

  static const accessTokenEnv = 'ADMOB_ACCESS_TOKEN';
  static const refreshTokenEnv = 'ADMOB_REFRESH_TOKEN';
  static const clientIdEnv = 'ADMOB_OAUTH_CLIENT_ID';
  static const clientSecretEnv = 'ADMOB_OAUTH_CLIENT_SECRET';

  /// Scope for reading apps and ad units.
  static const readonlyScope = 'https://www.googleapis.com/auth/admob.readonly';

  /// Scope creation needs (and which also covers reading).
  static const monetizationScope =
      'https://www.googleapis.com/auth/admob.monetization';

  /// yaml `type` → AdMob `adFormat`.
  static const adFormats = {
    'banner': 'BANNER',
    'interstitial': 'INTERSTITIAL',
    'rewarded': 'REWARDED',
    'native': 'NATIVE',
    'app_open': 'APP_OPEN',
  };

  /// Formats that may also serve video creatives.
  static const _videoFormats = {
    'INTERSTITIAL',
    'REWARDED',
    'NATIVE',
    'APP_OPEN',
  };

  /// How to get a credential — printed whenever auth is missing or refused.
  static const credentialsHint = '''
AdMob API access needs OAuth user credentials (service accounts are not
supported). Either:
  a) gcloud auth application-default login \\
       --scopes=$monetizationScope,$readonlyScope
  b) export $accessTokenEnv=<token>
  c) export $clientIdEnv / $clientSecretEnv / $refreshTokenEnv
     (one-time OAuth client in the Google Cloud console, then a refresh token)''';

  final HttpJsonClient http;
  final Map<String, String> env;
  final ProcessRunner processes;
  final String baseUrl;

  String? _token;

  AdmobApi({
    required this.http,
    required this.env,
    this.processes = const ProcessRunner(),
    this.baseUrl = defaultBaseUrl,
  });

  /// Whether an env-provided credential is present. gcloud is not consulted
  /// here — it is tried when a token is actually needed.
  static bool hasEnvCredentials(Map<String, String> env) {
    bool set(String name) => (env[name] ?? '').trim().isNotEmpty;
    return set(accessTokenEnv) ||
        (set(refreshTokenEnv) && set(clientIdEnv) && set(clientSecretEnv));
  }

  /// Ad types to request for [adFormat] when creating a unit.
  static List<String> adTypesFor(String adFormat) =>
      _videoFormats.contains(adFormat)
          ? const ['RICH_MEDIA', 'VIDEO']
          : const ['RICH_MEDIA'];

  /// Resolves an OAuth access token, caching it for the process.
  Future<String> accessToken() async {
    final cached = _token;
    if (cached != null) return cached;

    final direct = (env[accessTokenEnv] ?? '').trim();
    if (direct.isNotEmpty) return _token = direct;

    final refreshToken = (env[refreshTokenEnv] ?? '').trim();
    final clientId = (env[clientIdEnv] ?? '').trim();
    final clientSecret = (env[clientSecretEnv] ?? '').trim();
    if (refreshToken.isNotEmpty &&
        clientId.isNotEmpty &&
        clientSecret.isNotEmpty) {
      return _token = await _refresh(clientId, clientSecret, refreshToken);
    }

    final fromGcloud = await _gcloudToken();
    if (fromGcloud != null) return _token = fromGcloud;

    throw SetupException(credentialsHint);
  }

  Future<String> _refresh(
      String clientId, String clientSecret, String refreshToken) async {
    final response = await http.postForm(Uri.parse(tokenUrl), fields: {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
      'client_secret': clientSecret,
    });
    final body = response.body;
    final token = body is Map ? body['access_token'] : null;
    if (!response.ok || token is! String || token.isEmpty) {
      final detail = body is Map
          ? (body['error_description'] ?? body['error'] ?? body)
          : body;
      throw SetupException(
        'AdMob OAuth refresh failed (HTTP ${response.status}): $detail\n'
        '$credentialsHint',
      );
    }
    return token;
  }

  /// `gcloud auth application-default print-access-token`, when gcloud is
  /// installed and logged in. Returns null when it is not usable.
  Future<String?> _gcloudToken() async {
    if (await processes.which('gcloud') == null) return null;
    final result = await processes.run(
      'gcloud',
      ['auth', 'application-default', 'print-access-token'],
    );
    if (result.exitCode != 0) return null;
    final token = (result.stdout as String).trim();
    return token.isEmpty ? null : token;
  }

  /// Resolves the publisher account resource name (`accounts/pub-…`).
  /// With [publisherId] it is built directly; otherwise the first account
  /// the credential can see is used.
  Future<String> accountName({String? publisherId}) async {
    if (publisherId != null && publisherId.isNotEmpty) {
      return 'accounts/$publisherId';
    }
    final response = await http.get(
      Uri.parse('$baseUrl/accounts'),
      headers: await _headers(),
    );
    final body = response.body;
    if (!response.ok) throw _failure('list AdMob accounts', response);
    // The list field is `account`, singular, in this API.
    final accounts = body is Map ? (body['account'] ?? body['accounts']) : null;
    final first = accounts is List && accounts.isNotEmpty ? accounts.first : null;
    final name = first is Map ? first['name'] : null;
    if (name is! String || name.isEmpty) {
      throw SetupException(
        'The AdMob credential can see no publisher account. Set '
        'admob.publisher_id in easy_setup.yaml, or sign in as the account '
        'that owns the apps.',
      );
    }
    return name;
  }

  Future<List<AdmobApp>> listApps(String account) async {
    final items = await _list('$account/apps', 'apps', 'list AdMob apps');
    return [
      for (final item in items)
        if (item is Map && item['appId'] is String) AdmobApp.fromJson(item),
    ];
  }

  Future<List<AdmobAdUnit>> listAdUnits(String account) async {
    final items =
        await _list('$account/adUnits', 'adUnits', 'list AdMob ad units');
    return [
      for (final item in items)
        if (item is Map && item['adUnitId'] is String)
          AdmobAdUnit.fromJson(item),
    ];
  }

  /// Creates an app under [account]. Returns null when the API refuses with
  /// 403 — app creation is limited access (V2_PLAN.md §5.4).
  Future<AdmobApp?> createApp(
    String account, {
    required String platform,
    required String displayName,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/$account/apps'),
      headers: await _headers(),
      body: {
        'platform': platform,
        'manualAppInfo': {'displayName': displayName},
      },
    );
    if (response.status == 403) return null;
    final body = response.body;
    if (!response.ok || body is! Map || body['appId'] is! String) {
      throw _failure('create the AdMob app "$displayName"', response);
    }
    return AdmobApp.fromJson(body);
  }

  /// Creates an ad unit under [account]. Returns null on 403 (limited
  /// access), like [createApp].
  Future<AdmobAdUnit?> createAdUnit(
    String account, {
    required String appId,
    required String displayName,
    required String adFormat,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/$account/adUnits'),
      headers: await _headers(),
      body: {
        'appId': appId,
        'displayName': displayName,
        'adFormat': adFormat,
        'adTypes': adTypesFor(adFormat),
      },
    );
    if (response.status == 403) return null;
    final body = response.body;
    if (!response.ok || body is! Map || body['adUnitId'] is! String) {
      throw _failure('create the ad unit "$displayName"', response);
    }
    return AdmobAdUnit.fromJson(body);
  }

  Future<Map<String, String>> _headers() async =>
      {'Authorization': 'Bearer ${await accessToken()}'};

  /// Follows `nextPageToken` until the listing is exhausted.
  Future<List<Object?>> _list(String path, String field, String what) async {
    final items = <Object?>[];
    String? pageToken;
    final headers = await _headers();
    do {
      final uri = Uri.parse('$baseUrl/$path').replace(queryParameters: {
        'pageSize': '1000',
        'pageToken': ?pageToken,
      });
      final response = await http.get(uri, headers: headers);
      if (!response.ok) throw _failure(what, response);
      final body = response.body;
      if (body is! Map) throw _failure(what, response);
      final page = body[field];
      if (page is List) items.addAll(page);
      final next = body['nextPageToken'];
      pageToken = next is String && next.isNotEmpty ? next : null;
    } while (pageToken != null);
    return items;
  }

  SetupException _failure(String what, JsonResponse response) {
    final body = response.body;
    final error = body is Map ? body['error'] : null;
    final message = error is Map ? error['message'] : body;
    if (response.status == 401 || response.status == 403) {
      return SetupException(
        'AdMob API refused to $what (HTTP ${response.status}): $message\n'
        'Check that the credential has the $readonlyScope scope and that the '
        'AdMob API is enabled for the project it belongs to.\n'
        '$credentialsHint',
      );
    }
    return SetupException(
        'Could not $what (HTTP ${response.status}): $message');
  }
}
