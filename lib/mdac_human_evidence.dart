import 'dart:math';
import 'dart:typed_data';

const mdacHumanEvidenceReasons = {
  'MANUAL_SUBMITTED': '人工核对并记录提交意图',
  'MANUAL_UNKNOWN': '人工检查后结果仍无法确认',
  'INDEPENDENT_CHECK': '独立证据核对官方结果',
};

bool _uuid(String value) =>
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(value);

void requireMdacHumanIsolation(String restUrl) {
  final uri = Uri.tryParse(restUrl);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.authority != 'rvgslhjmiaunylwhcamz.supabase.co' ||
      uri.path != '/rest/v1' ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw StateError('ISOLATION_ONLY_HUMAN_REVIEW_CANDIDATE');
  }
}

String newMdacHumanEvidenceId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String validateMdacHumanFile(Uint8List bytes, String extension) {
  if (bytes.isEmpty || bytes.length > 6 * 1024 * 1024) {
    throw const FormatException('HUMAN_EVIDENCE_SIZE_INVALID');
  }
  final signature = extension == 'png'
      ? [137, 80, 78, 71, 13, 10, 26, 10]
      : extension == 'pdf'
      ? [37, 80, 68, 70, 45]
      : <int>[];
  if (signature.isEmpty ||
      bytes.length < signature.length ||
      List<int>.generate(
        signature.length,
        (i) => bytes[i],
      ).asMap().entries.any((e) => e.value != signature[e.key])) {
    throw const FormatException('HUMAN_EVIDENCE_FORMAT_INVALID');
  }
  return extension == 'png' ? 'image/png' : 'application/pdf';
}

Map<String, dynamic> mdacHumanEvidencePayload({
  required String actorId,
  required String itemId,
  required String evidenceId,
  required String extension,
  required String reason,
}) {
  if (!_uuid(actorId) ||
      !_uuid(itemId) ||
      !_uuid(evidenceId) ||
      !['png', 'pdf'].contains(extension) ||
      !mdacHumanEvidenceReasons.containsKey(reason)) {
    throw const FormatException('HUMAN_EVIDENCE_REFERENCE_INVALID');
  }
  return {
    'reason': reason,
    'evidence_ref': {
      'bucket': 'passport-documents',
      'path': 'mdac-human-evidence/$actorId/$itemId/$evidenceId.$extension',
    },
  };
}
