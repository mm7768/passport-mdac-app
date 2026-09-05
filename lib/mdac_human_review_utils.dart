String formatMdacHumanDate(dynamic raw) {
  final text = raw?.toString().trim() ?? '';
  final isoDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(text);
  if (isoDate != null) {
    return '${isoDate.group(3)}/${isoDate.group(2)}/${isoDate.group(1)}';
  }
  if (RegExp(r'^\d{2}/\d{2}/\d{4}$').hasMatch(text)) return text;
  throw FormatException('无法识别日期 $text');
}

bool hasMdacOfficialSuccessMarker(String text) =>
    RegExp(r'SUCCESSFULLY\s+REGISTERED\.', caseSensitive: false).hasMatch(text);
