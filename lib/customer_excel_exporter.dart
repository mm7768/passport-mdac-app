import 'dart:typed_data';
import 'package:syncfusion_flutter_xlsio/xlsio.dart' as xlsio;

class CustomerExportItem {
  const CustomerExportItem({
    required this.fullName,
    required this.passportNumber,
    required this.pin,
    required this.mdacEmail,
    required this.formattedPhone,
  });

  final String fullName;
  final String passportNumber;
  final String pin;
  final String mdacEmail;
  final String formattedPhone;
}

class CustomerExcelExporter {
  CustomerExcelExporter._();

  /// 生成标准的现代 Office Open XML (.xlsx) 格式 Excel 文件
  static Uint8List exportCustomersToXlsx({
    required List<CustomerExportItem> items,
  }) {
    final workbook = xlsio.Workbook();
    final sheet = workbook.worksheets[0];
    sheet.name = 'PIN客户列表';

    // 1. 列宽设置 (像素)
    sheet.setColumnWidthInPixels(1, 140); // 名字
    sheet.setColumnWidthInPixels(2, 130); // 护照号
    sheet.setColumnWidthInPixels(3, 110); // pin
    sheet.setColumnWidthInPixels(4, 220); // 注册使用的gmail
    sheet.setColumnWidthInPixels(5, 180); // 注册使用的手机号码

    // 2. 表头行设置 (Row 1)
    sheet.setRowHeightInPixels(1, 32);
    final headerRange = sheet.getRangeByName('A1:E1');
    headerRange.cellStyle.backColor = '#F1F5F9';
    headerRange.cellStyle.bold = true;
    headerRange.cellStyle.fontSize = 11;
    headerRange.cellStyle.fontName = 'Microsoft YaHei';
    headerRange.cellStyle.fontColor = '#0F172A';
    headerRange.cellStyle.hAlign = xlsio.HAlignType.center;
    headerRange.cellStyle.vAlign = xlsio.VAlignType.center;
    headerRange.cellStyle.borders.all.lineStyle = xlsio.LineStyle.thin;
    headerRange.cellStyle.borders.all.color = '#CBD5E1';

    sheet.getRangeByName('A1').setText('名字');
    sheet.getRangeByName('B1').setText('护照号');
    sheet.getRangeByName('C1').setText('pin');
    sheet.getRangeByName('D1').setText('注册使用的gmail');
    sheet.getRangeByName('E1').setText('注册使用的手机号码');

    // 3. 数据行设置 (Row 2 .. N+1)
    for (var i = 0; i < items.length; i++) {
      final rowIdx = i + 2;
      final item = items[i];
      sheet.setRowHeightInPixels(rowIdx, 24);

      // A: 名字
      final cellA = sheet.getRangeByIndex(rowIdx, 1);
      cellA.setText(item.fullName);
      cellA.cellStyle.fontName = 'Microsoft YaHei';
      cellA.cellStyle.vAlign = xlsio.VAlignType.center;

      // B: 护照号 (居中，等宽字体，强制文本格式)
      final cellB = sheet.getRangeByIndex(rowIdx, 2);
      cellB.setText(item.passportNumber);
      cellB.cellStyle.fontName = 'Consolas';
      cellB.cellStyle.hAlign = xlsio.HAlignType.center;
      cellB.cellStyle.vAlign = xlsio.VAlignType.center;
      cellB.cellStyle.numberFormat = '@';

      // C: pin (居中，加粗，主题青色，等宽字体，强制文本格式)
      final cellC = sheet.getRangeByIndex(rowIdx, 3);
      cellC.setText(item.pin.trim());
      cellC.cellStyle.fontName = 'Consolas';
      cellC.cellStyle.bold = true;
      cellC.cellStyle.fontColor = '#0F766E';
      cellC.cellStyle.hAlign = xlsio.HAlignType.center;
      cellC.cellStyle.vAlign = xlsio.VAlignType.center;
      cellC.cellStyle.numberFormat = '@';

      // D: 注册使用的gmail
      final cellD = sheet.getRangeByIndex(rowIdx, 4);
      cellD.setText(item.mdacEmail);
      cellD.cellStyle.fontName = 'Consolas';
      cellD.cellStyle.vAlign = xlsio.VAlignType.center;

      // E: 注册使用的手机号码 (强制文本格式)
      final cellE = sheet.getRangeByIndex(rowIdx, 5);
      cellE.setText(item.formattedPhone);
      cellE.cellStyle.fontName = 'Consolas';
      cellE.cellStyle.vAlign = xlsio.VAlignType.center;
      cellE.cellStyle.numberFormat = '@';

      // 行边框
      final rowRange = sheet.getRangeByName('A$rowIdx:E$rowIdx');
      rowRange.cellStyle.borders.all.lineStyle = xlsio.LineStyle.thin;
      rowRange.cellStyle.borders.all.color = '#E2E8F0';
    }

    final List<int> bytes = workbook.saveAsStream();
    workbook.dispose();
    return Uint8List.fromList(bytes);
  }
}
