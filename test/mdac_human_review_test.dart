import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/mdac_human_review_utils.dart';

void main() {
  group('formatMdacHumanDate', () {
    test('converts an ISO date to the official MDAC display format', () {
      expect(formatMdacHumanDate('2026-09-02'), '02/09/2026');
      expect(formatMdacHumanDate('2026-09-02T00:00:00.000Z'), '02/09/2026');
    });

    test('keeps an already formatted date', () {
      expect(formatMdacHumanDate('02/09/2026'), '02/09/2026');
    });

    test('rejects an unrecognized date', () {
      expect(() => formatMdacHumanDate('2 Sep 2026'), throwsFormatException);
    });
  });

  group('hasMdacOfficialSuccessMarker', () {
    test('accepts the exact official success wording', () {
      expect(hasMdacOfficialSuccessMarker('SUCCESSFULLY REGISTERED.'), isTrue);
      expect(
        hasMdacOfficialSuccessMarker('Successfully   registered.'),
        isTrue,
      );
    });

    test('does not accept ambiguous or incomplete wording', () {
      expect(hasMdacOfficialSuccessMarker('Registration submitted.'), isFalse);
      expect(hasMdacOfficialSuccessMarker('SUCCESSFULLY REGISTERED'), isFalse);
    });
  });
}
