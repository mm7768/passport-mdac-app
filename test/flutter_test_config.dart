import 'dart:async';
import 'dart:io';

// C-only offline test bootstrap. No product client or upload protocol changes.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await HttpOverrides.runZoned(
    () async => testMain(),
    createHttpClient: (_) => throw StateError('OFFLINE_HTTP_FORBIDDEN'),
  );
}
