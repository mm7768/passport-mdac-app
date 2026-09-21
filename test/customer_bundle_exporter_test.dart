import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:passport_mdac_app/customer_bundle_exporter.dart';

void main() {
  Uint8List createDummyPdf({required String title, double width = 595.0, double height = 842.0}) {
    final doc = PdfDocument();
    doc.pageSettings.size = ui.Size(width, height);
    doc.pageSettings.margins.all = 0;
    final page = doc.pages.add();
    page.graphics.drawString(
      title,
      PdfStandardFont(PdfFontFamily.helvetica, 12),
      bounds: ui.Rect.fromLTWH(20, 20, width - 40, 30),
    );
    // Draw border right up to the edge to test clipping
    page.graphics.drawRectangle(
      pen: PdfPens.black,
      bounds: ui.Rect.fromLTWH(10, 10, width - 20, height - 20),
    );
    final bytes = doc.saveSync();
    doc.dispose();
    return Uint8List.fromList(bytes);
  }

  test('CustomerBundleExporter imports registration PDF with exact page size and 0 margins', () async {
    final regBytes = createDummyPdf(title: 'MALAYSIA DIGITAL ARRIVAL CARD');

    final evidence = CustomerBundleEvidence(
      customerId: 'test-1',
      customerName: 'Test Customer',
      registrationPdfBytes: regBytes,
    );

    final bundledBytes = await CustomerBundleExporter.generateCustomerPdf(evidence);
    final bundledDoc = PdfDocument(inputBytes: bundledBytes);
    
    expect(bundledDoc.pages.count, equals(1));
    expect(bundledDoc.pages[0].size.width, closeTo(595.0, 1.0));
    expect(bundledDoc.pages[0].size.height, closeTo(842.0, 1.0));
    expect(bundledDoc.pages[0].getClientSize().width, closeTo(595.0, 1.0));
    bundledDoc.dispose();
  });

  test('CustomerBundleExporter creates multi-page bundle with proper section margins', () async {
    final regBytes = createDummyPdf(title: 'MALAYSIA DIGITAL ARRIVAL CARD');
    final passportPdfBytes = createDummyPdf(title: 'PASSPORT DOCUMENT');

    final evidence = CustomerBundleEvidence(
      customerId: 'test-2',
      customerName: 'Lan Haiyi',
      passportImageBytes: passportPdfBytes,
      registrationPdfBytes: regBytes,
    );

    final bundledBytes = await CustomerBundleExporter.generateCustomerPdf(evidence);
    final bundledDoc = PdfDocument(inputBytes: bundledBytes);
    
    expect(bundledDoc.pages.count, equals(2));
    // Page 1: Passport (0 margin, exact size)
    expect(bundledDoc.pages[0].size.width, closeTo(595.0, 1.0));
    expect(bundledDoc.pages[0].getClientSize().width, closeTo(595.0, 1.0));

    // Page 2: Registration PDF (0 margin, exact size)
    expect(bundledDoc.pages[1].size.width, closeTo(595.0, 1.0));
    expect(bundledDoc.pages[1].getClientSize().width, closeTo(595.0, 1.0));
    bundledDoc.dispose();
  });
}
