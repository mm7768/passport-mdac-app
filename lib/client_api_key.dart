import 'dart:convert';

/// Mobile apps may contain a publishable key or a legacy anon JWT, never an admin key.
class ClientApiKey {
  static bool isPublic(String key) {
    if (key.startsWith('sb_publishable_')) {
      return key.length > 'sb_publishable_'.length;
    }
    final parts = key.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      return payload is Map && payload['role'] == 'anon';
    } catch (_) {
      return false;
    }
  }

  static void requirePublic(String key) {
    if (!isPublic(key)) {
      throw StateError('手机端必须使用 publishable/anon 公钥，禁止使用服务端密钥。');
    }
  }
}
