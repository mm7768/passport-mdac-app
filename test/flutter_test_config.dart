import 'dart:async';
import 'dart:io';

// C-only offline test bootstrap. No product client or upload protocol changes.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // The Dart test runner can enter a fresh zone after test registration.
  // Persist the deny override for this test isolate, not only the registration
  // zone; product isolates and the original App working tree are unaffected.
  HttpOverrides.global = _NoHttpOverrides();
  await testMain();
}

class _NoHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('OFFLINE_HTTP_FORBIDDEN');
}
