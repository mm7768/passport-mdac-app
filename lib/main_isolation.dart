import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'main.dart' as app;
import 'supabase_gateway.dart';

/// Development entrypoint for G4. The normal App entrypoint is unchanged.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  requireIsolationPreviewConfiguration(
    SupabaseGateway.projectUrl,
    SupabaseGateway.publishableKey,
  );
  await SupabaseGateway.initialize();
  runApp(const app.MdacPilotApp());
}

void requireIsolationPreviewConfiguration(String url, String key) {
  var publicKey = key.startsWith('sb_publishable_');
  if (!publicKey) {
    try {
      final parts = key.split('.');
      if (parts.length == 3) {
        final claims = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
        );
        publicKey =
            claims is Map &&
            claims['role'] == 'anon' &&
            claims['ref'] == 'rvgslhjmiaunylwhcamz';
      }
    } catch (_) {
      publicKey = false;
    }
  }
  if (url != 'https://rvgslhjmiaunylwhcamz.supabase.co' || !publicKey) {
    throw StateError('ISOLATION_PREVIEW_CONFIGURATION_REQUIRED');
  }
}
