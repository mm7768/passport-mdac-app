import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/main.dart';

void _noop() {}

void main() {
  testWidgets('owner can enter the MDAC Desk workspace', (tester) async {
    await tester.pumpWidget(const MdacPilotApp());
    await tester.pumpAndSettle();

    expect(find.text('欢迎回来'), findsOneWidget);
    expect(find.text('owner@mdac.local'), findsOneWidget);

    await tester.tap(find.text('进入工作区'));
    await tester.pumpAndSettle();

    expect(find.text('早上好，粉肠哥'), findsOneWidget);
    expect(find.text('活跃客户'), findsOneWidget);
    expect(find.text('Worker 在线'), findsOneWidget);
  });

  testWidgets('workspace navigation exposes customers and task queue', (
    tester,
  ) async {
    await tester.pumpWidget(const MdacPilotApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('进入工作区'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('客户'));
    await tester.pumpAndSettle();
    expect(find.text('客户档案'), findsOneWidget);
    expect(find.text('TANG FUMING'), findsOneWidget);

    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    expect(find.text('任务队列'), findsOneWidget);
    await tester.tap(find.textContaining('最近批次'));
    await tester.pumpAndSettle();
    expect(find.text('MDAC 批量注册'), findsWidgets);
  });

  testWidgets('overview statistic cards navigate with the expected filters', (
    tester,
  ) async {
    await tester.pumpWidget(const MdacPilotApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('进入工作区'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('待处理资料'));
    await tester.pumpAndSettle();
    expect(find.text('客户档案'), findsOneWidget);
    expect(find.text('状态：待处理'), findsOneWidget);

    await tester.tap(find.text('总览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('运行中任务'));
    await tester.pumpAndSettle();
    expect(find.text('任务队列'), findsOneWidget);

    await tester.tap(find.text('总览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('需要关注'));
    await tester.pumpAndSettle();
    expect(find.text('客户档案'), findsOneWidget);
    expect(find.text('状态：需关注'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('customer screen exposes manual entry and edit actions', (
    tester,
  ) async {
    await tester.pumpWidget(const MdacPilotApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('进入工作区'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客户'));
    await tester.pumpAndSettle();

    expect(find.text('手动录入'), findsOneWidget);
    await tester.tap(find.text('手动录入'));
    await tester.pumpAndSettle();
    expect(find.text('手动录入护照'), findsOneWidget);
    expect(find.text('Gmail PIN（可留空）'), findsOneWidget);
    final cancelButton = find.text('取消').last;
    await tester.ensureVisible(cancelButton);
    await tester.tap(cancelButton);
    await tester.pumpAndSettle();
    expect(find.text('手动录入护照'), findsNothing);

    final customerName = find.text('TANG FUMING');
    await tester.ensureVisible(customerName);
    await tester.tap(customerName);
    await tester.pumpAndSettle();
    expect(find.text('编辑档案'), findsOneWidget);
    expect(find.text('Gmail PIN'), findsOneWidget);
    await tester.tap(find.text('编辑档案'));
    await tester.pumpAndSettle();
    expect(find.text('编辑客户档案'), findsOneWidget);
    expect(find.text('保存修改'), findsOneWidget);
  });

  testWidgets('owner sees bulk created_at action after selecting customers', (
    tester,
  ) async {
    await tester.pumpWidget(const MdacPilotApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('进入工作区'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客户'));
    await tester.pumpAndSettle();

    final checkboxes = find.byType(Checkbox);
    expect(checkboxes, findsNWidgets(5));
    await tester.tap(checkboxes.at(1));
    await tester.tap(checkboxes.at(2));
    await tester.pumpAndSettle();

    expect(find.text('已选 2 位'), findsOneWidget);
    expect(find.text('修改创建时间'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual customer submission closes cleanly', (tester) async {
    await tester.pumpWidget(const MdacPilotApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('进入工作区'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客户'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手动录入'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    final values = [
      'MANUAL SUBMIT',
      'ZX900099',
      '01/01/1990',
      'CHINA',
      'CHN',
      '01/01/2030',
      'AB  12 CD',
    ];
    for (var index = 0; index < values.length; index++) {
      await tester.enterText(fields.at(index), values[index]);
    }
    final genderDropdown = find.byType(DropdownButtonFormField<String>).first;
    await tester.ensureVisible(genderDropdown);
    await tester.tap(genderDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('男').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('创建客户'));
    await tester.tap(find.text('创建客户'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('MANUAL SUBMIT'), findsWidgets);
  });

  testWidgets('ocr review shows passport number and structured fields', (
    tester,
  ) async {
    await tester.pumpWidget(const MdacPilotApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('进入工作区'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客户'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入护照'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择单张图片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看草稿'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('审核').first);
    await tester.pumpAndSettle();

    expect(find.text('人工确认 OCR 结果'), findsOneWidget);
    expect(find.text('护照号码'), findsWidgets);
    expect(find.text('出生日期（DD/MM/YYYY）'), findsOneWidget);
    expect(find.text('护照有效期（DD/MM/YYYY）'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(2), '02021990');
    expect(
      tester.widget<TextFormField>(fields.at(2)).controller?.text,
      '02/02/1990',
    );

    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(find.text('人工确认 OCR 结果'), findsNothing);
  });

  testWidgets('passport document card handles private image and PDF states', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PassportDocumentCard(path: 'owner/ocr/passport.jpg'),
              PassportDocumentCard(path: 'owner/ocr/passport.pdf'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('护照原图 · 低分辨率预览'), findsOneWidget);
    expect(find.text('护照 PDF 已录入'), findsOneWidget);
    expect(find.text('护照图片暂时无法加载'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner can permanently delete an eligible customer', (
    tester,
  ) async {
    await tester.pumpWidget(const MdacPilotApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('进入工作区'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客户'));
    await tester.pumpAndSettle();

    final checkboxes = find.byType(Checkbox);
    await tester.ensureVisible(checkboxes.at(4));
    await tester.tap(checkboxes.at(4));
    await tester.pumpAndSettle();
    final deleteButton = find.byTooltip('永久删除');
    await tester.ensureVisible(deleteButton);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    expect(find.text('确认永久删除客户？'), findsOneWidget);
    expect(find.textContaining('此操作不可恢复'), findsOneWidget);
    await tester.tap(find.text('确认永久删除'));
    await tester.pumpAndSettle();

    expect(find.text('确认永久删除客户？'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('operator selection bar hides permanent delete action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionBar(
            count: 1,
            onMdac: _noop,
            onPin: _noop,
            onRegistration: _noop,
            onVisitPass: _noop,
            onExport: _noop,
          ),
        ),
      ),
    );

    expect(find.byTooltip('永久删除'), findsNothing);
    expect(find.text('导出 Excel'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone width keeps primary pages free of layout exceptions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MdacPilotApp());
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('进入工作区'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    for (final section in ['客户', '任务', '设置']) {
      await tester.tap(find.text(section));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '布局异常发生在 $section 页面');
    }
  });
}
