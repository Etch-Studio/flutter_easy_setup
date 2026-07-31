import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

import '../exceptions.dart';

/// Generates the ES256-signed JWT the App Store Connect API requires.
/// Ported from the verified v1 implementation (see V2_PLAN.md §8).
abstract final class AscJwt {
  /// Creates a bearer token from the API key.
  ///
  /// [privateKeyPem] is the raw contents of the .p8 file. Apple caps token
  /// validity at 20 minutes.
  static String generate({
    required String keyId,
    required String issuerId,
    required String privateKeyPem,
    Duration validity = const Duration(minutes: 20),
  }) {
    final jwt = JWT(
      {'iss': issuerId, 'aud': 'appstoreconnect-v1'},
      header: {'kid': keyId},
    );
    try {
      return jwt.sign(
        ECPrivateKey(privateKeyPem.trim()),
        algorithm: JWTAlgorithm.ES256,
        expiresIn: validity,
      );
      // The parser throws various types (FormatException, RangeError, ...)
      // on malformed PEM input — wrap them all with actionable context.
    } catch (e) {
      throw SetupException(
          'Could not parse or sign with the ASC .p8 private key: $e');
    }
  }
}
