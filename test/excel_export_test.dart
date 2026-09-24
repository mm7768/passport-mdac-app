import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:passport_mdac_app/customer_excel_exporter.dart';

void main() {
  test('CustomerExcelExporter generates valid XLSX package with correct OpenXML contents', () {
    final items = [
      const CustomerExportItem(
        fullName: '张三 (ZHANG SAN)',
        passportNumber: 'E12345678',
        pin: '123456',
        mdacEmail: 'company@gmail.com',
        formattedPhone: '+86 13800000000',
      ),
      const CustomerExportItem(
        fullName: '李四 (LI SI)',
        passportNumber: 'G98765432',
        pin: '654321',
        mdacEmail: 'company@gmail.com',
        formattedPhone: '+86 13800000000',
      ),
    ];

    final Uint8List xlsxBytes = CustomerExcelExporter.exportCustomersToXlsx(items: items);
    expect(xlsxBytes.isNotEmpty, isTrue);

    // Verify ZIP archive and OpenXML structure
    final archive = ZipDecoder().decodeBytes(xlsxBytes);
    expect(archive.findFile('[Content_Types].xml'), isNotNull);
    expect(archive.findFile('xl/workbook.xml'), isNotNull);
    expect(archive.findFile('xl/worksheets/sheet1.xml'), isNotNull);
    expect(archive.findFile('xl/styles.xml'), isNotNull);

    // Verify Content Types mentions OpenXML spreadsheetml
    final contentTypesFile = archive.findFile('[Content_Types].xml')!;
    final contentTypesStr = String.fromCharCodes(contentTypesFile.content as List<int>);
    expect(contentTypesStr, contains('spreadsheetml'));
  });
}
