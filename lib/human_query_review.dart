import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  Uint8List? _officialPdfBytes;
  String? _officialPdfName;
  bool _capturingPdf = false;
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

  Future<void> _captureOfficialPdf(DownloadStartRequest request) async {
    if (_visitPass || _capturingPdf) return;
    final urlStr = request.url.toString().toLowerCase();
    if (!urlStr.contains('slip') && !urlStr.contains('.pdf') && !urlStr.contains('print')) {
      return;
    }
    setState(() {
      _capturingPdf = true;
      _error = null;
    });
    final client = HttpClient();
    try {
      final uri = Uri.parse(request.url.toString());
      final cookies = await CookieManager.instance().getCookies(url: request.url);
      final download = await client.getUrl(uri);
      if (cookies.isNotEmpty) {
        download.headers.set(
          HttpHeaders.cookieHeader,
          cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; '),
        );
      }
      download.followRedirects = true;
      final response = await download.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('官方 PDF 下载失败（HTTP ${response.statusCode}）');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) { builder.add(chunk); }
      final bytes = builder.takeBytes();
      if (bytes.length < 5 || ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != '%PDF') {
        throw const FormatException('官方返回的文件不是有效 PDF。');
      }
      if (!mounted) return;
      setState(() {
        _officialPdfBytes = bytes;
        _officialPdfName = request.suggestedFilename ?? 'registration.pdf';
        _capturingPdf = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _capturingPdf = false;
      });
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _confirmOutcome(String outcome) async {
    final message = switch (outcome) {
      'FOUND' => _visitPass
          ? '请确认官方页面已经明确显示有效 Visit Pass。确认后 App 会立即保存截图并完成任务。'
          : '请确认官方页面已查到有效 MDAC 记录。确认后 App 会提取官方原版 PDF 凭证并完成任务。',
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

  Future<Uint8List?> _extractPdfFromPage() async {
    final controller = _controller;
    if (controller == null) return null;

    final completer = Completer<String?>();
    const handlerName = 'pdfExtractedBridge';

    try {
      controller.removeJavaScriptHandler(handlerName: handlerName);
    } catch (_) {}

    controller.addJavaScriptHandler(
      handlerName: handlerName,
      callback: (args) {
        final res = args.isNotEmpty ? args[0]?.toString() : null;
        if (!completer.isCompleted) completer.complete(res);
        return null;
      },
    );

    try {
      // 优先注入脚本通过 addJavaScriptHandler 回传结果
      const script = '''
(async () => {
  try {
    let trip = null;
    const a = document.querySelector("a[onclick*='printSlip']");
    if (a) {
      const m = (a.getAttribute('onclick') || '').match(/printSlip\\(['"]?([^'"]+)['"]?\\)/);
      if (m) trip = m[1];
    }
    if (!trip) {
      const h = document.getElementById('hTripId');
      if (h && h.value) trip = h.value;
    }
    if (!trip) {
      const inputs = Array.from(document.querySelectorAll("input[type='hidden']"));
      for (const el of inputs) {
        if (el.value && /^[A-Z0-9_-]{10,}\$/i.test(el.value)) {
          trip = el.value;
          break;
        }
      }
    }
    if (!trip) {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('pdfExtractedBridge', null);
      }
      return;
    }
    const fd = new FormData();
    fd.append('hTripId', trip);
    const resp = await fetch('https://imigresen-online.imi.gov.my/mdac/register?printSlip', {
      method: 'POST',
      body: fd,
      credentials: 'include'
    });
    if (!resp.ok) {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('pdfExtractedBridge', null);
      }
      return;
    }
    const buf = await resp.arrayBuffer();
    const bytes = new Uint8Array(buf);
    if (bytes.length < 4 || bytes[0] !== 0x25 || bytes[1] !== 0x50 || bytes[2] !== 0x44 || bytes[3] !== 0x46) {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('pdfExtractedBridge', null);
      }
      return;
    }
    let binary = '';
    const chunk = 8192;
    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    const b64 = btoa(binary);
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('pdfExtractedBridge', b64);
    }
  } catch (e) {
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('pdfExtractedBridge', null);
    }
  }
})();
''';
      await controller.evaluateJavascript(source: script);
      final b64Result = await completer.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => null,
      );

      if (b64Result != null && b64Result.isNotEmpty) {
        final decoded = base64Decode(b64Result);
        if (decoded.length > 100 &&
            decoded[0] == 0x25 &&
            decoded[1] == 0x50 &&
            decoded[2] == 0x44 &&
            decoded[3] == 0x46) {
          return decoded;
        }
      }
    } catch (_) {} finally {
      try {
        controller.removeJavaScriptHandler(handlerName: handlerName);
      } catch (_) {}
    }
    return null;
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
        if (!_visitPass && outcome == 'FOUND') {
          if (_officialPdfBytes == null) {
            _officialPdfBytes = await _extractPdfFromPage();
          }
          if (_officialPdfBytes == null) {
            throw const FormatException('未能提取到官方原版 PDF 文件，请确认页面已完全显示查询结果表格后再试。');
          }
          screenshotPath = await SupabaseGateway.uploadHumanQueryEvidence(
            itemId: _itemId!,
            bytes: _officialPdfBytes!,
            extension: 'pdf',
            contentType: 'application/pdf',
          );
        } else {
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
          if (!_visitPass && (_capturingPdf || _officialPdfBytes != null))
            Container(
              width: double.infinity,
              color: const Color(0xFFE3F4EF),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                _capturingPdf
                    ? '正在下载官方 Registration PDF…'
                    : '已取得官方 PDF：${_officialPdfName ?? 'registration.pdf'}，确认成功时将自动上传。',
                style: const TextStyle(color: Color(0xFF006C63)),
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
                          useOnDownloadStart: true,
                        ),
                        onWebViewCreated: (controller) => _controller = controller,
                        onLoadStop: (controller, url) => _fillOfficialForm(),
                        // TODO: migrate when the beta callback API stabilizes.
                        // ignore: deprecated_member_use
                        onDownloadStartRequest: (controller, request) =>
                            _captureOfficialPdf(request),
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
                        Text('正在保存凭证、上传并回写…'),
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

class CustomerQueryEvidenceCard extends StatefulWidget {
  const CustomerQueryEvidenceCard({super.key, required this.customerId});
  final String customerId;
  @override
  State<CustomerQueryEvidenceCard> createState() => _CustomerQueryEvidenceCardState();
}

class _CustomerQueryEvidenceCardState extends State<CustomerQueryEvidenceCard> {
  late Future<List<Map<String, dynamic>>> _future;
  @override
  void initState() {
    super.initState();
    _future = SupabaseGateway.fetchCustomerHumanEvidence(widget.customerId);
  }
  void _reload() => setState(() {
    _future = SupabaseGateway.fetchCustomerHumanEvidence(widget.customerId);
  });
  Future<void> _open(Map<String, dynamic> row) async {
    final path = row['screenshot_path']?.toString() ?? '';
    if (path.isEmpty) return;
    try {
      final url = await SupabaseGateway.createSignedPassportImageUrl(path);
      if (!mounted) return;
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => PrivateEvidencePreviewPage(
          url: url,
          isPdf: path.toLowerCase().endsWith('.pdf'),
          title: row['type'] == 'VISIT_PASS_CHECK'
              ? 'Visit Pass 查询凭证'
              : 'Registration 查询凭证',
        ),
      ));
    } catch (exception) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('凭证加载失败：$exception')),
      );
    }
  }
  Future<void> _deleteEvidence(Map<String, dynamic> row) async {
    final checkId = row['id']?.toString() ?? '';
    final type = row['type']?.toString() ?? 'REGISTRATION_CHECK';
    final screenshotPath = row['screenshot_path']?.toString();
    final isPdf = (screenshotPath ?? '').toLowerCase().endsWith('.pdf');
    final label = isPdf ? '官方 PDF 凭证' : '查询截图';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除$label'),
        content: Text('确定要从该客户的档案中删除此$label吗？\n删除后该条核验凭证将不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFBA1A1A)),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await SupabaseGateway.deleteCustomerHumanEvidence(
        checkId: checkId,
        type: type,
        screenshotPath: screenshotPath,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除$label')),
      );
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return OutlinedButton.icon(
            onPressed: _reload,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('查询凭证加载失败，重试'),
          );
        }
        final rows = snapshot.data ?? const <Map<String, dynamic>>[];
        if (rows.isEmpty) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF5FAF8),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFD4E5E0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(children: [
                Icon(Icons.verified_outlined, color: Color(0xFF087F78)),
                SizedBox(width: 8),
                Text('官方查询凭证', style: TextStyle(fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 8),
              for (final row in rows)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    (row['screenshot_path']?.toString() ?? '').toLowerCase().endsWith('.pdf')
                        ? Icons.picture_as_pdf_outlined
                        : Icons.image_outlined,
                    color: const Color(0xFF087F78),
                  ),
                  title: Text(row['type'] == 'VISIT_PASS_CHECK'
                      ? 'Check Visit Pass'
                      : 'Check Registration'),
                  subtitle: Text(
                    '${row['normalized_status'] ?? ''} · ${row['checked_at'] ?? ''}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.open_in_new_rounded, size: 20),
                        tooltip: '查看凭证',
                        color: const Color(0xFF087F78),
                        onPressed: () => _open(row),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded, size: 20),
                        tooltip: '删除此凭证',
                        color: const Color(0xFFBA1A1A),
                        onPressed: () => _deleteEvidence(row),
                      ),
                    ],
                  ),
                  onTap: () => _open(row),
                ),
            ],
          ),
        );
      },
    );
  }
}

class PrivateEvidencePreviewPage extends StatelessWidget {
  const PrivateEvidencePreviewPage({
    super.key,
    required this.url,
    required this.isPdf,
    required this.title,
  });
  final String url;
  final bool isPdf;
  final String title;

  String _buildPdfViewerHtml(String pdfUrl) {
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=4.0, user-scalable=yes">
  <title>MDAC Slip Preview</title>
  <script src="https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/build/pdf.min.js"></script>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background-color: #323639;
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 12px;
      min-height: 100vh;
    }
    #loading {
      color: #fff;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      font-size: 14px;
      margin-top: 50px;
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .spinner {
      width: 20px;
      height: 20px;
      border: 3px solid rgba(255,255,255,0.3);
      border-radius: 50%;
      border-top-color: #fff;
      animation: spin 1s ease-in-out infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
    canvas {
      max-width: 100%;
      height: auto;
      margin-bottom: 16px;
      box-shadow: 0 4px 16px rgba(0,0,0,0.5);
      border-radius: 4px;
      background-color: #ffffff;
    }
    #error-box {
      display: none;
      color: #ff8080;
      background: rgba(255,0,0,0.1);
      padding: 16px;
      border-radius: 8px;
      margin-top: 30px;
      text-align: center;
      font-family: sans-serif;
      font-size: 13px;
    }
  </style>
</head>
<body>
  <div id="loading">
    <div class="spinner"></div>
    <span>正在排版渲染官方 PDF 凭证...</span>
  </div>
  <div id="error-box"></div>
  <div id="pdf-container"></div>

  <script>
    const pdfUrl = "$pdfUrl";
    pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/build/pdf.worker.min.js';

    const loadingTask = pdfjsLib.getDocument(pdfUrl);
    loadingTask.promise.then(function(pdf) {
      document.getElementById('loading').style.display = 'none';
      for (let pageNum = 1; pageNum <= pdf.numPages; pageNum++) {
        pdf.getPage(pageNum).then(function(page) {
          const scale = 2.0;
          const viewport = page.getViewport({ scale: scale });
          const canvas = document.createElement('canvas');
          const context = canvas.getContext('2d');
          canvas.height = viewport.height;
          canvas.width = viewport.width;
          document.getElementById('pdf-container').appendChild(canvas);
          page.render({ canvasContext: context, viewport: viewport });
        });
      }
    }).catch(function(error) {
      document.getElementById('loading').style.display = 'none';
      const errBox = document.getElementById('error-box');
      errBox.style.display = 'block';
      errBox.innerText = '渲染 PDF 异常：' + error.message;
    });
  </script>
</body>
</html>
''';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (isPdf)
            IconButton(
              icon: const Icon(Icons.open_in_browser_rounded),
              tooltip: '手机浏览器打开',
              onPressed: () async {
                try {
                  await InAppBrowser.openWithSystemBrowser(url: WebUri(url));
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('打开浏览器失败：$e')),
                    );
                  }
                }
              },
            ),
          IconButton(
            icon: const Icon(Icons.copy_rounded),
            tooltip: '复制凭证直链',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('凭证直链已复制到剪贴板，可粘贴至浏览器直接下载或查看'),
                    duration: Duration(seconds: 3),
                  ),
                );
              }
            },
          ),
        ],
      ),
      bottomNavigationBar: isPdf
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: const Color(0xFFF1F3F4),
              child: const SafeArea(
                child: Row(
                  children: [
                    Icon(Icons.touch_app_outlined, size: 16, color: Color(0xFF5F6368)),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '双指手势可缩放浏览 · 右上角支持一键在手机浏览器打开或复制直链。',
                        style: TextStyle(fontSize: 11, color: Color(0xFF5F6368)),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: isPdf
          ? InAppWebView(
              initialData: InAppWebViewInitialData(
                data: _buildPdfViewerHtml(url),
                mimeType: 'text/html',
                encoding: 'utf-8',
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                supportZoom: true,
                builtInZoomControls: true,
                displayZoomControls: false,
                useHybridComposition: true,
                allowFileAccess: true,
                allowContentAccess: true,
              ),
            )
          : InteractiveViewer(
              minScale: 0.8,
              maxScale: 5,
              child: Center(
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, error, __) => Text('图片加载失败：$error'),
                ),
              ),
            ),
    );
  }
}
