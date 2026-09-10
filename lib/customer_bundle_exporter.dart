import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'supabase_gateway.dart';

class CustomerBundleEvidence {
  CustomerBundleEvidence({
    required this.customerId,
    required this.customerName,
    this.visitPassImageBytes,
    this.passportImageBytes,
    this.registrationPdfBytes,
    this.error,
  });

  final String customerId;
  final String customerName;
  final Uint8List? visitPassImageBytes;
  final Uint8List? passportImageBytes;
  final Uint8List? registrationPdfBytes;
  final String? error;

  bool get hasAnyEvidence =>
      visitPassImageBytes != null ||
      passportImageBytes != null ||
      registrationPdfBytes != null;
}

class CustomerBundleExporter {
  CustomerBundleExporter._();

  /// Fetches evidence bytes from Supabase Storage for a given customer.
  static Future<CustomerBundleEvidence> loadCustomerEvidence({
    required String customerId,
    required String customerName,
    String? fallbackPassportImagePath,
  }) async {
    try {
      final paths =
          await SupabaseGateway.fetchCustomerBundleEvidence(customerId);
      final passportPath =
          paths.passportImagePath ?? fallbackPassportImagePath;
      final regPdfPath = paths.registrationPdfPath;
      final vpImgPath = paths.visitPassScreenshotPath;

      Uint8List? passportBytes;
      if (passportPath != null && passportPath.trim().isNotEmpty) {
        try {
          passportBytes =
              await SupabaseGateway.downloadStorageFile(passportPath);
        } catch (_) {}
      }

      Uint8List? vpBytes;
      if (vpImgPath != null && vpImgPath.trim().isNotEmpty) {
        try {
          vpBytes = await SupabaseGateway.downloadStorageFile(vpImgPath);
        } catch (_) {}
      }

      Uint8List? regPdfBytes;
      if (regPdfPath != null && regPdfPath.trim().isNotEmpty) {
        try {
          regPdfBytes =
              await SupabaseGateway.downloadStorageFile(regPdfPath);
        } catch (_) {}
      }

      return CustomerBundleEvidence(
        customerId: customerId,
        customerName: customerName,
        visitPassImageBytes: vpBytes,
        passportImageBytes: passportBytes,
        registrationPdfBytes: regPdfBytes,
      );
    } catch (e) {
      return CustomerBundleEvidence(
        customerId: customerId,
        customerName: customerName,
        error: e.toString(),
      );
    }
  }

  /// Compiles Visit Pass screenshot, Passport photo, and Registration check PDF
  /// into a single PDF document Uint8List.
  /// Page 1: Visit Pass screenshot
  /// Page 2: Passport photo
  /// Page 3+: Check Registration PDF
  static Future<Uint8List> generateCustomerPdf(CustomerBundleEvidence evidence) async {
    final document = PdfDocument();

    // Set standard page settings (A4 portrait)
    document.pageSettings.size = PdfPageSize.a4;
    document.pageSettings.margins.all = 20;

    // Helper to draw an image centered and scaled to fit the page
    void addImagePage(Uint8List imageBytes, String headerTitle) {
      final page = document.pages.add();
      final graphics = page.graphics;
      final pageSize = page.getClientSize();

      // Header text
      final font = PdfStandardFont(PdfFontFamily.helvetica, 12, style: PdfFontStyle.bold);
      graphics.drawString(
        headerTitle,
        font,
        brush: PdfSolidBrush(PdfColor(30, 41, 59)),
        bounds: ui.Rect.fromLTWH(0, 0, pageSize.width, 20),
      );

      try {
        final pdfBitmap = PdfBitmap(imageBytes);
        final imgWidth = pdfBitmap.width.toDouble();
        final imgHeight = pdfBitmap.height.toDouble();

        final availableWidth = pageSize.width;
        final availableHeight = pageSize.height - 25;

        // Calculate aspect fit
        final scaleX = availableWidth / imgWidth;
        final scaleY = availableHeight / imgHeight;
        final scale = scaleX < scaleY ? scaleX : scaleY;

        final drawWidth = imgWidth * scale;
        final drawHeight = imgHeight * scale;
        final offsetX = (availableWidth - drawWidth) / 2;
        final offsetY = 25 + (availableHeight - drawHeight) / 2;

        graphics.drawImage(
          pdfBitmap,
          ui.Rect.fromLTWH(offsetX, offsetY, drawWidth, drawHeight),
        );
      } catch (e) {
        final errorFont = PdfStandardFont(PdfFontFamily.helvetica, 10);
        graphics.drawString(
          '图片加载失败: ' + e.toString(),
          errorFont,
          brush: PdfSolidBrush(PdfColor(185, 28, 28)),
          bounds: ui.Rect.fromLTWH(0, 30, pageSize.width, 20),
        );
      }
    }

    // 1. Page 1: Visit Pass 截图
    if (evidence.visitPassImageBytes != null &&
        evidence.visitPassImageBytes!.isNotEmpty) {
      addImagePage(evidence.visitPassImageBytes!, 'Check Visit Pass 凭证截图');
    }

    // 2. Page 2: 护照档案图片
    if (evidence.passportImageBytes != null &&
        evidence.passportImageBytes!.isNotEmpty) {
      // Check if passport document is actually an image or already a PDF
      if (_isPdfBytes(evidence.passportImageBytes!)) {
        try {
          final loadedPassportPdf = PdfDocument(inputBytes: evidence.passportImageBytes!);
          final count = loadedPassportPdf.pages.count;
          for (int i = 0; i < count; i++) {
            final template = loadedPassportPdf.pages[i].createTemplate();
            final newPage = document.pages.add();
            newPage.graphics.drawPdfTemplate(template, const ui.Offset(0, 0));
          }
          loadedPassportPdf.dispose();
        } catch (_) {
          addImagePage(evidence.passportImageBytes!, '护照原件文件');
        }
      } else {
        addImagePage(evidence.passportImageBytes!, '护照档案图片');
      }
    }

    // 3. Page 3+: Check Registration PDF
    if (evidence.registrationPdfBytes != null &&
        evidence.registrationPdfBytes!.isNotEmpty) {
      try {
        final loadedRegPdf = PdfDocument(inputBytes: evidence.registrationPdfBytes!);
        final count = loadedRegPdf.pages.count;
        for (int i = 0; i < count; i++) {
          final template = loadedRegPdf.pages[i].createTemplate();
          final newPage = document.pages.add();
          newPage.graphics.drawPdfTemplate(template, const ui.Offset(0, 0));
        }
        loadedRegPdf.dispose();
      } catch (e) {
        final page = document.pages.add();
        final font = PdfStandardFont(PdfFontFamily.helvetica, 10);
        page.graphics.drawString(
          'Registration PDF 拼接失败: ' + e.toString(),
          font,
          brush: PdfSolidBrush(PdfColor(185, 28, 28)),
          bounds: const ui.Rect.fromLTWH(0, 0, 500, 30),
        );
      }
    }

    // If no pages were added at all (e.g. empty customer)
    if (document.pages.count == 0) {
      final page = document.pages.add();
      final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
      page.graphics.drawString(
        '客户档案暂无查询凭证或护照文件',
        font,
        bounds: const ui.Rect.fromLTWH(0, 0, 400, 30),
      );
    }

    final bytes = await document.save();
    document.dispose();
    return Uint8List.fromList(bytes);
  }

  /// Packages multiple customer PDFs into a single ZIP archive.
  /// Each file inside the ZIP is named: YYYYMMDD_客户姓名.pdf
  static Uint8List createZipArchive(Map<String, Uint8List> namedPdfFiles) {
    final archive = Archive();
    for (final entry in namedPdfFiles.entries) {
      archive.addFile(
        ArchiveFile(
          entry.key,
          entry.value.length,
          entry.value,
        ),
      );
    }
    final zipEncoder = ZipEncoder();
    final encoded = zipEncoder.encode(archive);
    return Uint8List.fromList(encoded ?? <int>[]);
  }

  /// Generates the standard file name for a customer: YYYYMMDD_客户姓名.pdf
  static String formatCustomerPdfName(String customerName, {DateTime? date}) {
    final d = date ?? DateTime.now();
    final yyyy = d.year.toString().padLeft(4, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    final safeName = customerName.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return '${yyyy}${mm}${dd}_$safeName.pdf';
  }

  static bool _isPdfBytes(Uint8List bytes) {
    if (bytes.length < 5) return false;
    // %PDF-
    return bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46 &&
        bytes[4] == 0x2D;
  }
}
