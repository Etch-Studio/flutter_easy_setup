import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:easy_setup/easy_setup.dart';
import 'package:test/test.dart';

import '../helpers/fake_http_json_client.dart';

void main() {
  group('AscJwt', () {
    test('produces an ES256 token with the ASC claims', () {
      final token = AscJwt.generate(
        keyId: 'KEY123',
        issuerId: 'issuer-uuid',
        privateKeyPem: testEcPrivateKeyPem,
      );

      final decoded = JWT.decode(token);
      expect(decoded.header?['alg'], 'ES256');
      expect(decoded.header?['kid'], 'KEY123');
      final payload = decoded.payload as Map;
      expect(payload['iss'], 'issuer-uuid');
      expect(payload['aud'], 'appstoreconnect-v1');
      // Apple caps validity at 20 minutes.
      expect(payload['exp'] - payload['iat'], 1200);
    });

    test('rejects an unparsable key with a SetupException', () {
      expect(
        () => AscJwt.generate(
          keyId: 'K',
          issuerId: 'I',
          privateKeyPem: 'not a pem',
        ),
        throwsA(isA<SetupException>()),
      );
    });
  });
}
