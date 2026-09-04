import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'supabase_gateway.dart';

enum HumanQueryKind { registration, visitPass }

class HumanQueryReviewPage extends StatefulWidget {
  const HumanQueryReviewPage({
    super.key,
    required this.kind,
    required this.customerId,
    required this.customerName,
    required this.passportNumber,
    required this.nationality,
    required this.pin,
    this.email = '',
    this.regionCode = '',
    this.mobile = '',
  });

  final HumanQueryKind kind;
  final String customerId;
  final String customerName;
  final String passportNumber;
  final String nationality;
  final String pin;
  final String email;
  final String regionCode;
  final String mobile;

  @override
  State<HumanQueryReviewPage> createState() => _HumanQueryReviewPageState();
}

class _HumanQueryReviewPageState extends State<HumanQueryReviewPage> {
  InAppWebViewController? _controller;
  String? _itemId;
  String? _targetEntryDate;
  String? _targetExitDate;
  bool _starting = true;
  bool _pageLoaded = false;
  bool _finishing = false;
  String? _error;

  bool get _visitPass => widget.kind == HumanQueryKind.visitPass;
  String get _title => _visitPass ? 'Check Visit Pass' : 'Check Registration';
  WebUri get _url => WebUri(
        _visitPass
            ? 'https://imigresen-online.imi.gov.my/mdac/register?viewVisitPass'
            : 'https://imigresen-online.imi.gov.my/mdac/register?viewRegistration',
      );

  @override
  void initState() {
    super.initState();
    _startTask();
  }

  Future<void> _startTask() async {
    try {
      final task = await SupabaseGateway.createHumanQueryTask(
        customerId: widget.customerId,
        visitPass: _visitPass,
        settingsSnapshot: _visitPass
            ? {
                'email': widget.email,
                'region_code': widget.regionCode,
                'mobile': widget.mobile,
              }
            : const {},
      );
      if (!mounted) return;
      setState(() {
        _itemId = task['item_id']?.toString();
        _targetEntryDate = task['target_entry_date']?.toString();
        _targetExitDate = task['target_exit_date']?.toString();
        _starting = false;
      });
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = '无法建立查询任务：$exception';
      });
    }
  }

  Future<void> _fillOfficialForm() async {
    final controller = _controller;
    if (controller == null || _itemId == null) return;
    String jsValue(String value) => jsonEncode(value.trim());
    final script = '''
(() => {
  const setInput = (id, value) => {
    const el = document.getElementById(id);
    if (!el) return false;
    el.value = value;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
  };
  const checks = [];
  checks.push(setInput('passNo', ${jsValue(widget.passportNumber)}));
  checks.push(setInput('nationality', ${jsValue(widget.nationality.toUpperCase())}));
  checks.push(setInput('pinKeyId', ${jsValue(widget.pin)}));
  ${_visitPass ? "checks.push(setInput('email', ${jsValue(widget.email)})); checks.push(setInput('regCd', ${jsValue(widget.regionCode)})); checks.push(setInput('mobile', ${jsValue(widget.mobile)}));" : ""}
  return checks.every(Boolean);
})()
''';
    try {
      await controller.evaluateJavascript(source: script);
      if (!mounted) return;
      setState(() => _pageLoaded = true);
    } catch (exception) {
      if (!mounted) return;
      setState(() => _error = '官方页面已打开，但自动填写失败：$exception');
    }
  }

  List<String> _dateCandidates(String? isoDate) {
    if (isoDate == null || isoDate.isEmpty) return const [];
    final parts = isoDate.split('-');
    if (parts.length != 3) return [isoDate];
    final year = parts[0];
    final month = parts[1].padLeft(2, '0');
    final day = parts[2].padLeft(2, '0');
    return [
      '$day/$month/$year',
      '$day-$month-$year',
      '$year-$month-$day',
      '$day.$month.$year',
    ];
  }

  String _displayDate(String? value) {
    final candidates = _dateCandidates(value);
    return candidates.isEmpty ? '未设置' : candidates.first;
  }

  Future<bool> _officialPageMatchesTargetDates() async {
    if (_visitPass) return true;
    final controller = _controller;
    if (controller == null) return false;
    final entry = _dateCandidates(_targetEntryDate);
    final exit = _dateCandidates(_targetExitDate);
    if (entry.isEmpty || exit.isEmpty) return false;
    final result = await controller.evaluateJavascript(source: '''
(() => {
  const text = (document.body?.innerText || '').replace(/\\s+/g, ' ').toUpperCase();
  const entry = ${jsonEncode(entry)};
  const exit = ${jsonEncode(exit)};
  return entry.some(value => text.includes(value.toUpperCase())) &&
         exit.some(value => text.includes(value.toUpperCase()));
})()
''');
    return result == true || result?.toString().toLowerCase() == 'true';
  }

  Future<bool> _confirmOutcome(String outcome) async {
    final message = switch (outcome) {
      'FOUND' => '请确认官方页面已经明确显示有效记录。确认后 App 会立即截图；截图上传成功后才会完成任务。',
      'NO_RECORD' => '请确认官方页面明确显示没有记录。本结果不会保存截图。',
      'PIN_INVALID' => '请确认官方页面明确提示 PIN 错误。本结果不会保存截图。',
      _ => '请确认当前官方页面异常。App 会保存诊断截图并将任务保留为待处理。',
    };
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('确认判断 · $_title'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('返回核对'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('确认'),
              ),
            ],
          ),
        ) ==
        true;
  }

  Future<void> _finish(String outcome) async {
    if (_finishing || _itemId == null || !_pageLoaded) return;
    if (outcome == 'FOUND' && !_visitPass) {
      try {
        final matches = await _officialPageMatchesTargetDates();
        if (!matches) {
          if (!mounted) return;
          setState(() {
            _error =
                '当前官方结果没有同时显示本次目标日期：入境 ${_displayDate(_targetEntryDate)}，'
                '离境 ${_displayDate(_targetExitDate)}。可能是历史记录，不能确认成功。';
          });
          return;
        }
      } catch (exception) {
        if (!mounted) return;
        setState(() => _error = '无法核对官方结果日期：$exception');
        return;
      }
    }
    if (!await _confirmOutcome(outcome) || !mounted) return;
    setState(() {
      _finishing = true;
      _error = null;
    });

    String? screenshotPath;
    try {
      if (outcome == 'FOUND' || outcome == 'PAGE_ERROR') {
        final Uint8List? image = await _controller?.takeScreenshot(
          screenshotConfiguration: ScreenshotConfiguration(
            compressFormat: CompressFormat.PNG,
            quality: 100,
            afterScreenUpdates: true,
          ),
        );
        if (image == null || image.isEmpty) {
          throw const FormatException('网页截图为空，请保持结果页打开后重试。');
        }
        screenshotPath = await SupabaseGateway.uploadHumanQueryEvidence(
          itemId: _itemId!,
          bytes: image,
        );
      }
      await SupabaseGateway.finishHumanQueryTask(
        itemId: _itemId!,
        outcome: outcome,
        screenshotPath: screenshotPath,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        _finishing = false;
        _error = '确认失败：$exception\n任务没有完成，请保持当前结果页并重试。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('$_title · ${widget.customerName}'),
        actions: [
          IconButton(
            tooltip: '重新填写',
            onPressed: _pageLoaded ? _fillOfficialForm : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: const Color(0xFFFFF4D6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Row(
                children: [
                  const Icon(Icons.touch_app_outlined, color: Color(0xFF9A6700)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _visitPass
                          ? '资料会自动填写。请手动完成滑块、点击官方 Search，并根据官方结果选择下方按钮。'
                          : '目标：入境 ${_displayDate(_targetEntryDate)} · 离境 ${_displayDate(_targetExitDate)}。'
                              '请完成滑块并只确认日期完全一致的记录；历史记录不能判定成功。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null)
            Container(
              width: double.infinity,
              color: const Color(0xFFFFE2E0),
              padding: const EdgeInsets.all(10),
              child: Text(_error!, style: const TextStyle(color: Color(0xFFB3261E))),
            ),
          Expanded(
            child: _starting
                ? const Center(child: CircularProgressIndicator())
                : _itemId == null
                    ? const Center(child: Text('查询任务无法启动，请返回后重试。'))
                    : InAppWebView(
                        initialUrlRequest: URLRequest(url: _url),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          supportZoom: true,
                          useShouldOverrideUrlLoading: false,
                        ),
                        onWebViewCreated: (controller) => _controller = controller,
                        onLoadStop: (controller, url) => _fillOfficialForm(),
                        onReceivedError: (controller, request, error) {
                          if (request.isForMainFrame != true || !mounted) return;
                          setState(() => _error = '官方页面加载失败：${error.description}');
                        },
                      ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              decoration: const BoxDecoration(
                color: Colors.white,
                boxShadow: [BoxShadow(color: Color(0x22000000), blurRadius: 10)],
              ),
              child: _finishing
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 10),
                        Text('正在截图、上传并回写…'),
                      ],
                    )
                  : Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        FilledButton.icon(
                          onPressed: _pageLoaded ? () => _finish('FOUND') : null,
                          icon: const Icon(Icons.camera_alt_outlined),
                          label: const Text('查到记录'),
                        ),
                        OutlinedButton(
                          onPressed: _pageLoaded ? () => _finish('NO_RECORD') : null,
                          child: const Text('没有记录'),
                        ),
                        OutlinedButton(
                          onPressed: _pageLoaded ? () => _finish('PIN_INVALID') : null,
                          child: const Text('PIN 错误'),
                        ),
                        TextButton(
                          onPressed: _pageLoaded ? () => _finish('PAGE_ERROR') : null,
                          child: const Text('页面异常'),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
