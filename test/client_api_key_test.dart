import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/client_api_key.dart';

String jwt(String role) => '${base64Url.encode(utf8.encode('{"alg":"HS256"}'))}.${base64Url.encode(utf8.encode(jsonEncode({'role':role})))}.test-signature';

void main() {
  test('publishable keys and legacy anon JWTs are accepted', () {
    expect(ClientApiKey.isPublic('sb_publishable_test-placeholder'),isTrue);
    expect(ClientApiKey.isPublic(jwt('anon')),isTrue);
  });
  test('admin secrets and service-role JWTs are rejected without echoing them', () {
    for(final key in ['sb_secret_test-placeholder',jwt('service_role'),jwt('authenticated'),'','not-a-key','sb_publishable_','a.bad.payload']) {
      expect(ClientApiKey.isPublic(key),isFalse);
      expect(()=>ClientApiKey.requirePublic(key),throwsStateError);
    }
  });
}
