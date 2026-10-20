import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/mdac_human_evidence.dart';

void main() {
  const actor = '10000000-0000-4000-8000-000000000001';
  const task = '20000000-0000-4000-8000-000000000001';
  const evidence = '30000000-0000-4000-8000-000000000001';
  test('offline bootstrap refuses creating any Dart HTTP client', () {
    expect(() => HttpClient(), throwsStateError);
  });
  test('exact 6 MiB valid PNG boundary accepted; one extra byte rejected', () {
    final bytes = Uint8List(6 * 1024 * 1024);
    bytes.setRange(0, 8, [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(validateMdacHumanFile(bytes, 'png'), 'image/png');
    final oversized = Uint8List(bytes.length + 1)..setRange(0, 8, bytes);
    expect(() => validateMdacHumanFile(oversized, 'png'), throwsFormatException);
  });
  test('truncated PNG and PDF signatures are rejected', () {
    expect(() => validateMdacHumanFile(Uint8List.fromList([137, 80, 78]), 'png'), throwsFormatException);
    expect(() => validateMdacHumanFile(Uint8List.fromList([37, 80, 68, 70]), 'pdf'), throwsFormatException);
  });
  test('HQUERY path binds exact Task without fabricating a Case', () {
    final reference = humanQueryEvidencePath(actorId: actor, itemId: task,
      evidenceId: evidence, extension: 'pdf');
    expect(reference, 'human-query-evidence/$actor/$task-$evidence.pdf');
    // Actual server support for case_id=NULL still requires G3/G4; this helper
    // has no case argument, and this test does not call create/finish RPCs.
  });
  test('manual path cannot silently become HQUERY path or vice versa', () {
    final payload = mdacHumanEvidencePayload(actorId: actor, itemId: task,
      evidenceId: evidence, extension: 'pdf', reason: 'INDEPENDENT_CHECK');
    expect((payload['evidence_ref'] as Map)['path'],
      'mdac-human-evidence/$actor/$task/$evidence.pdf');
    expect(humanQueryEvidencePath(actorId: actor, itemId: task,
      evidenceId: evidence, extension: 'pdf'), isNot((payload['evidence_ref'] as Map)['path']));
  });
  test('isolation guard rejects credentials, fragments and production', () {
    for (final url in ['https://user@rvgslhjmiaunylwhcamz.supabase.co/rest/v1',
      'https://rvgslhjmiaunylwhcamz.supabase.co/rest/v1#override',
      'https://xdmcxhvdqsbcqedfprcy.supabase.co/rest/v1']) {
      expect(() => requireMdacHumanIsolation(url), throwsStateError);
    }
  });
}
