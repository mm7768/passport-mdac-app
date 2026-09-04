import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'mdac_human_review_utils.dart';

/// Human-in-the-loop continuation for an MDAC fill-preview batch.
///
/// This screen never attempts to solve or manipulate the MDAC CAPTCHA. It only
/// rebuilds the already-reviewed form from frozen batch/item snapshots, lets a
/// person complete the slider, and requires an explicit confirmation before it
/// invokes the official page's normal submit button.
class MdacHumanReviewScreen extends StatefulWidget {
  const MdacHumanReviewScreen({
    required this.batchId,
    required this.supabase,
    super.key,
  });

  final String batchId;
  final SupabaseClient supabase;

  @override
  State<MdacHumanReviewScreen> createState() => _MdacHumanReviewScreenState();
}

class _MdacHumanReviewScreenState extends State<MdacHumanReviewScreen> {
  static const _officialUrl =
      'https://imigresen-online.imi.gov.my/mdac/main?registerMain';
  static const _ink = Color(0xFF12383E);
  static const _teal = Color(0xFF138A8A);
  static const _muted = Color(0xFF708287);
  static const _canvas = Color(0xFFF4F7F6);
  static const _warning = Color(0xFFE3A228);
  static const _danger = Color(0xFFD9635D);

  _MdacHumanBatch? _batch;
  _MdacHumanItem? _active;
  WebViewController? _controller;
  bool _loading = true;
  bool _pageLoading = false;
  bool _filling = false;
  bool _captchaReady = false;
  bool _submitBusy = false;
  bool _submitClicked = false;
  bool _resultPageSeen = false;
  bool _officialSuccessMarkerSeen = false;
  String? _pageMessage;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadBatch();
  }

  Future<void> _loadBatch({String? preferItemId}) async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final batchRow = await widget.supabase
          .from('automation_batches')
          .select(
            'id, task_type, status, entry_date, exit_date, mdac_settings_snapshot',
          )
          .eq('id', widget.batchId)
          .single();
      if (batchRow['task_type']?.toString() != 'MDAC_REGISTRATION') {
        throw const FormatException('这不是 MDAC 注册批次。');
      }

      final itemRows = await widget.supabase
          .from('automation_items')
          .select(
            'id, batch_id, customer_id, customer_snapshot, status, '
            'result_unknown, error_code, error_message, created_at',
          )
          .eq('batch_id', widget.batchId)
          .order('created_at');

      final items = <_MdacHumanItem>[];
      for (final raw in itemRows) {
        final row = Map<String, dynamic>.from(raw);
        final registration = await widget.supabase
            .from('mdac_registrations')
            .select(
              'batch_item_id, registration_status, registration_no, '
              'raw_summary, submitted_at, result_confirmed_at',
            )
            .eq('batch_item_id', row['id'])
            .maybeSingle();
        items.add(
          _MdacHumanItem.fromRows(
            row,
            registration == null
                ? null
                : Map<String, dynamic>.from(registration),
          ),
        );
      }

      final batch = _MdacHumanBatch.fromRow(
        Map<String, dynamic>.from(batchRow),
        items,
      );
      _MdacHumanItem? next;
      if (preferItemId != null) {
        for (final item in items) {
          if (item.id == preferItemId && item.canOpenReview) {
            next = item;
            break;
          }
        }
      }
      next ??= items.cast<_MdacHumanItem?>().firstWhere(
        (item) => item?.canOpenReview == true,
        orElse: () => null,
      );

      if (!mounted) return;
      setState(() {
        _batch = batch;
        _active = next;
        _loading = false;
        _resetBrowserState();
      });
      if (next != null) {
        await _openItem(next);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '无法加载人工处理批次：$error';
      });
    }
  }

  void _resetBrowserState() {
    _controller = null;
    _pageLoading = false;
    _filling = false;
    _captchaReady = false;
    _submitBusy = false;
    _submitClicked = false;
    _resultPageSeen = false;
    _officialSuccessMarkerSeen = false;
    _pageMessage = null;
  }

  Future<void> _openItem(_MdacHumanItem item) async {
    if (!item.canOpenReview) return;
    setState(() {
      _active = item;
      _resetBrowserState();
      _pageLoading = item.canOpenForm;
      _pageMessage = item.canOpenForm
          ? '正在打开官方 MDAC 页面…'
          : '这笔提交已在数据库记录，但原官方结果页已离开。为防止重复注册，只能核实后标记“结果无法确认”。';
    });

    if (!item.canOpenForm) return;

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            if (!mounted) return;
            setState(() {
              _pageLoading = true;
              _pageMessage = '官方页面加载中…';
            });
          },
          onPageFinished: (url) async {
            if (!mounted || _active?.id != item.id) return;
            setState(() => _pageLoading = false);
            if (_submitClicked) {
              setState(() {
                if (!_looksLikeRegistrationPage(url)) {
                  _resultPageSeen = true;
                }
                _pageMessage = '提交后的官方页面已加载，正在核对结果标记…';
              });
              await _inspectOfficialSuccessMarker();
            } else if (_looksLikeRegistrationPage(url)) {
              await _fillOfficialForm(item);
            }
          },
          onUrlChange: (change) {
            final url = change.url;
            if (!mounted || url == null || !_submitClicked) return;
            if (!_looksLikeRegistrationPage(url)) {
              setState(() {
                _resultPageSeen = true;
                _pageMessage = '检测到提交后页面变化，请核对官方结果。';
              });
            }
          },
          onWebResourceError: (error) {
            if (!mounted || error.isForMainFrame != true) return;
            setState(() {
              _pageLoading = false;
              _pageMessage = _submitClicked
                  ? '提交后页面加载失败，结果不能确认，请不要盲目重复提交。'
                  : '官方页面加载失败：${error.description}';
            });
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            final allowed =
                uri != null &&
                uri.scheme == 'https' &&
                uri.host == 'imigresen-online.imi.gov.my';
            return allowed
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      );

    if (!mounted || _active?.id != item.id) return;
    setState(() => _controller = controller);
    await controller.loadRequest(Uri.parse(_officialUrl));
  }

  bool _looksLikeRegistrationPage(String url) =>
      url.contains('imigresen-online.imi.gov.my/mdac/') &&
      (url.contains('registerMain') || url.endsWith('/mdac/main'));

  Future<bool> _inspectOfficialSuccessMarker() async {
    final controller = _controller;
    if (controller == null) return false;
    try {
      final result = await controller.runJavaScriptReturningResult('''
        (() => {
          const officialHost = location.hostname === 'imigresen-online.imi.gov.my';
          const text = document.body?.innerText || '';
          return JSON.stringify({
            officialHost,
            success: officialHost && /SUCCESSFULLY\\s+REGISTERED\\./i.test(text),
          });
        })();
      ''');
      final parsed = _decodeJsResult(result);
      final seen = parsed['officialHost'] == true && parsed['success'] == true;
      if (mounted) {
        setState(() {
          _officialSuccessMarkerSeen = seen;
          _pageMessage = seen
              ? '已在官方页面检测到 “SUCCESSFULLY REGISTERED.”，请最后人工核对并确认。'
              : '尚未检测到官方成功文字。请等待页面完成；若结果仍不明确，请选择“结果无法确认”。';
        });
      }
      return seen;
    } catch (error) {
      if (mounted) {
        setState(() {
          _officialSuccessMarkerSeen = false;
          _pageMessage = '无法核对官方成功文字：$error。请按“结果无法确认”处理。';
        });
      }
      return false;
    }
  }

  Future<void> _fillOfficialForm(_MdacHumanItem item) async {
    final controller = _controller;
    final batch = _batch;
    if (controller == null || batch == null || _filling) return;
    setState(() {
      _filling = true;
      _pageMessage = '正在恢复已审核的任务快照…';
    });

    try {
      final payload = batch.formPayload(item);
      final encoded = jsonEncode(payload);
      final result = await controller.runJavaScriptReturningResult('''
        (async () => {
          const payload = $encoded;
          const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
          const el = selector => document.querySelector(selector);
          const fire = node => {
            node.dispatchEvent(new Event('input', {bubbles: true}));
            node.dispatchEvent(new Event('change', {bubbles: true}));
          };
          const setText = (selector, value) => {
            const node = el(selector);
            if (!node) throw new Error('missing ' + selector);
            node.value = value ?? '';
            fire(node);
          };
          const setSelect = async (selector, value) => {
            const node = el(selector);
            if (!node) throw new Error('missing ' + selector);
            for (let attempt = 0; attempt < 30; attempt++) {
              if ([...node.options].some(option => option.value === value)) break;
              await sleep(150);
            }
            if (![...node.options].some(option => option.value === value)) {
              throw new Error('option unavailable ' + selector + '=' + value);
            }
            node.value = value;
            fire(node);
            await sleep(250);
          };

          if (!el('#name')) return JSON.stringify({ok:false, error:'form_not_ready'});
          await setSelect('#region', payload.region);
          await setSelect('#nationality', payload.nationality);
          await sleep(500);
          await setSelect('#pob', payload.pob);
          await setSelect('#sex', payload.sex);
          setText('#name', payload.name);
          setText('#passNo', payload.passNo);
          setText('#dob', payload.dob);
          setText('#passExpDte', payload.passExpDte);
          setText('#arrDt', payload.arrDt);
          setText('#depDt', payload.depDt);
          setText('#email', payload.email);
          setText('#confirmEmail', payload.email);
          setText('#mobile', payload.mobile);
          await setSelect('#trvlMode', payload.travelMode);
          await setSelect('#embark', payload.embark);
          setText('#vesselNm', payload.vessel);
          await setSelect('#accommodationStay', payload.accommodationStay);
          setText('#accommodationAddress1', payload.address1);
          setText('#accommodationAddress2', payload.address2);
          await setSelect('#accommodationState', payload.stateCode);
          await setSelect('#accommodationCity', payload.cityCode);
          setText('#accommodationPostcode', payload.postcode);
          await sleep(600);

          const expected = {
            '#region': payload.region,
            '#nationality': payload.nationality,
            '#pob': payload.pob,
            '#sex': payload.sex,
            '#name': payload.name,
            '#passNo': payload.passNo,
            '#dob': payload.dob,
            '#passExpDte': payload.passExpDte,
            '#arrDt': payload.arrDt,
            '#depDt': payload.depDt,
            '#email': payload.email,
            '#confirmEmail': payload.email,
            '#mobile': payload.mobile,
            '#trvlMode': payload.travelMode,
            '#embark': payload.embark,
            '#vesselNm': payload.vessel,
            '#accommodationStay': payload.accommodationStay,
            '#accommodationAddress1': payload.address1,
            '#accommodationAddress2': payload.address2,
            '#accommodationState': payload.stateCode,
            '#accommodationCity': payload.cityCode,
            '#accommodationPostcode': payload.postcode,
          };
          const mismatch = Object.entries(expected)
            .filter(([selector, value]) => !el(selector) || String(el(selector).value).trim() !== String(value).trim())
            .map(([selector]) => selector);
          const captchaPresent = Boolean(
            document.querySelector('#captcha .sliderContainer') ||
            document.querySelector('#captcha canvas')
          );
          return JSON.stringify({
            ok: mismatch.length === 0,
            mismatch,
            captchaPresent,
            submitDisabled: Boolean(el('#submit')?.disabled),
          });
        })();
      ''');
      final parsed = _decodeJsResult(result);
      if (!mounted || _active?.id != item.id) return;
      if (parsed['ok'] != true) {
        setState(() {
          _pageMessage =
              '自动恢复字段后回读不一致，请不要提交。异常字段：'
              '${(parsed['mismatch'] as List?)?.join(', ') ?? 'unknown'}';
        });
        return;
      }
      setState(() {
        _pageMessage = parsed['captchaPresent'] == true
            ? '资料已恢复。请你本人完成页面中的滑块，然后点“检查滑块状态”。'
            : '资料已恢复。请检查官方页面；当前没有检测到预期滑块。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _pageMessage = '恢复 MDAC 表单失败：$error');
    } finally {
      if (mounted) setState(() => _filling = false);
    }
  }

  Future<void> _checkCaptchaState() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final result = await controller.runJavaScriptReturningResult('''
        (() => {
          const submit = document.querySelector('#submit');
          const invalid = document.querySelectorAll('input:invalid, select:invalid').length;
          const slider = Boolean(document.querySelector('#captcha .sliderContainer'));
          return JSON.stringify({
            submitExists: Boolean(submit),
            submitDisabled: Boolean(submit?.disabled),
            invalid,
            slider,
          });
        })();
      ''');
      final parsed = _decodeJsResult(result);
      final ready =
          parsed['submitExists'] == true &&
          parsed['submitDisabled'] != true &&
          (parsed['invalid'] as num? ?? 1) == 0;
      if (!mounted) return;
      setState(() {
        _captchaReady = ready;
        _pageMessage = ready
            ? '官方表单已进入可提交状态。请先核对资料，再使用下方“确认提交 MDAC”。'
            : '尚未进入可提交状态。请完成滑块并确认页面没有必填项提示。';
      });
    } catch (error) {
      if (mounted) setState(() => _pageMessage = '无法检查页面状态：$error');
    }
  }

  Future<Map<String, dynamic>> _validateSubmitPreflight(
    _MdacHumanItem item,
  ) async {
    final controller = _controller;
    final batch = _batch;
    if (controller == null || batch == null) {
      return const {'ok': false, 'reason': 'review_not_ready'};
    }
    final encoded = jsonEncode(batch.formPayload(item));
    final result = await controller.runJavaScriptReturningResult('''
      (() => {
        const payload = $encoded;
        const expected = {
          '#region': payload.region,
          '#nationality': payload.nationality,
          '#pob': payload.pob,
          '#sex': payload.sex,
          '#name': payload.name,
          '#passNo': payload.passNo,
          '#dob': payload.dob,
          '#passExpDte': payload.passExpDte,
          '#arrDt': payload.arrDt,
          '#depDt': payload.depDt,
          '#email': payload.email,
          '#confirmEmail': payload.email,
          '#mobile': payload.mobile,
          '#trvlMode': payload.travelMode,
          '#embark': payload.embark,
          '#vesselNm': payload.vessel,
          '#accommodationStay': payload.accommodationStay,
          '#accommodationAddress1': payload.address1,
          '#accommodationAddress2': payload.address2,
          '#accommodationState': payload.stateCode,
          '#accommodationCity': payload.cityCode,
          '#accommodationPostcode': payload.postcode,
        };
        const mismatches = Object.entries(expected)
          .filter(([selector, value]) => {
            const node = document.querySelector(selector);
            return !node || String(node.value).trim() !== String(value ?? '').trim();
          })
          .map(([selector]) => selector);
        const submit = document.querySelector('#submit');
        const invalid = document.querySelectorAll('input:invalid, select:invalid').length;
        const officialHost = location.protocol === 'https:' &&
          location.hostname === 'imigresen-online.imi.gov.my';
        return JSON.stringify({
          ok: officialHost && mismatches.length === 0 && Boolean(submit) &&
            !submit.disabled && invalid === 0,
          officialHost,
          mismatches,
          submitExists: Boolean(submit),
          submitDisabled: Boolean(submit?.disabled),
          invalid,
        });
      })();
    ''');
    return _decodeJsResult(result);
  }

  Future<void> _confirmAndSubmit() async {
    final item = _active;
    final controller = _controller;
    if (item == null || controller == null || !_captchaReady || _submitBusy) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认提交 MDAC？'),
        content: Text(
          '请确认官方页面中的姓名、护照号、入境日期和出境日期都正确。\n\n'
          '${item.fullName}\n'
          '${item.maskedPassport}\n'
          '${_batch?.entryDate ?? ''} → ${_batch?.exitDate ?? ''}\n\n'
          '点击“确认并提交”后，App 会调用官方页面正常的 Submit。此动作不可当作成功证明，只有看到官方结果并再次确认后才会写成成功。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续检查'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认并提交'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _submitBusy = true;
      _pageMessage = '正在最后核对官方页面字段与滑块状态…';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在核对并提交，请稍候…')),
    );
    // Let the dialog route finish closing before interrogating the WebView.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    try {
      final preflight = await _validateSubmitPreflight(item);
      if (!mounted || _active?.id != item.id) return;
      if (preflight['ok'] != true) {
        final mismatches = (preflight['mismatches'] as List?)?.join(', ');
        final message = mismatches != null && mismatches.isNotEmpty
            ? '提交已停止：确认后页面字段发生变化（$mismatches）。请重新恢复并核对资料。'
            : '提交已停止：官方页面、必填项或滑块状态已变化。请重新检查后再提交。';
        setState(() {
          _captchaReady = false;
          _pageMessage = message;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: _danger),
        );
        return;
      }
      setState(() {
        _pageMessage = '最终核对通过，正在记录本次提交意图以防止异常后重复提交…';
      });
      await widget.supabase.rpc(
        'mark_mdac_human_submitted',
        params: {
          'p_item_id': item.id,
          'p_evidence': {
            'source': 'ANDROID_WEBVIEW',
            'official_host': 'imigresen-online.imi.gov.my',
            'human_submit_intent_recorded': true,
            'submit_click_executed': false,
          },
        },
      );
      if (!mounted) return;
      setState(() {
        _submitClicked = true;
        _pageMessage = '提交意图已安全记录，正在触发官方 Submit…';
      });
      final clickResult = await controller.runJavaScriptReturningResult('''
        (() => {
          const submit = document.querySelector('#submit');
          if (!submit) return JSON.stringify({clicked:false, reason:'submit_missing'});
          if (submit.disabled) return JSON.stringify({clicked:false, reason:'submit_disabled'});
          submit.click();
          return JSON.stringify({clicked:true, url:location.href});
        })();
      ''');
      final click = _decodeJsResult(clickResult);
      if (click['clicked'] != true) {
        throw StateError('官方 Submit 不可用：${click['reason'] ?? 'unknown'}');
      }
      if (!mounted) return;
      setState(() {
        _pageMessage = '已触发官方 Submit。正在等待并核对官方结果，请勿重复提交。';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已触发官方提交，正在等待结果…')),
      );
      // Some official responses replace the DOM without changing the URL, so
      // navigation callbacks alone are insufficient. Poll the visible result.
      for (var attempt = 0; attempt < 12; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!mounted || _active?.id != item.id) return;
        if (await _inspectOfficialSuccessMarker()) {
          setState(() => _resultPageSeen = true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已检测到官方注册成功，请点击“确认官方成功”完成写回。'),
            ),
          );
          break;
        }
      }
    } catch (error) {
      if (!mounted) return;
      final message = _submitClicked
          ? '提交意图已记录，但官方点击或页面返回异常。请按“结果无法确认”处理，禁止盲目重提。错误：$error'
          : '未能记录提交意图，因此没有触发官方 Submit：$error';
      setState(() => _pageMessage = message);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: _danger),
      );
    } finally {
      if (mounted) setState(() => _submitBusy = false);
    }
  }

  Future<void> _confirmOfficialSuccess() async {
    final item = _active;
    if (item == null || !_submitClicked) return;
    setState(() {
      _submitBusy = true;
      _pageMessage = '正在核对官方成功文字…';
    });
    final successMarkerSeen = await _inspectOfficialSuccessMarker();
    if (mounted) setState(() => _submitBusy = false);
    if (!successMarkerSeen || !mounted) return;
    final registrationController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认官方结果为成功？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '只有当你已经在官方页面看到明确的成功/注册结果时才确认。若页面空白、超时或结果不明确，请选择“结果无法确认”。',
            ),
            const SizedBox(height: 14),
            TextField(
              controller: registrationController,
              decoration: const InputDecoration(
                labelText: 'Registration No.（如官方页面有显示，可填写）',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认注册成功'),
          ),
        ],
      ),
    );
    final registrationNo = registrationController.text.trim();
    registrationController.dispose();
    if (confirmed != true || !mounted) return;

    setState(() => _submitBusy = true);
    try {
      await widget.supabase.rpc(
        'confirm_mdac_human_success',
        params: {
          'p_item_id': item.id,
          'p_registration_no': registrationNo.isEmpty ? null : registrationNo,
          'p_evidence': {
            'source': 'ANDROID_WEBVIEW',
            'official_result_page_seen': _resultPageSeen,
            'official_success_marker_seen': _officialSuccessMarkerSeen,
            'human_confirmed_success': true,
          },
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该客户 MDAC 已确认成功并写回 Supabase。')),
      );
      await _loadBatch();
    } catch (error) {
      if (mounted) {
        setState(() => _pageMessage = '成功状态写回失败：$error');
      }
    } finally {
      if (mounted) setState(() => _submitBusy = false);
    }
  }

  Future<void> _markUnknown() async {
    final item = _active;
    if (item == null ||
        (!_submitClicked && item.registrationStatus != 'SUBMITTED')) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('标记为“结果无法确认”？'),
        content: const Text('系统会保留“已经尝试提交但结果未知”的状态，阻止把它误当成成功，也提醒后续不要直接重复提交。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('结果无法确认'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _submitBusy = true);
    try {
      await widget.supabase.rpc(
        'mark_mdac_human_result_unknown',
        params: {
          'p_item_id': item.id,
          'p_evidence': {
            'source': 'ANDROID_WEBVIEW',
            'official_result_page_seen': _resultPageSeen,
          },
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保留结果未知状态。请先核实官方结果，不要盲目重复提交。')),
      );
      await _loadBatch();
    } catch (error) {
      if (mounted) setState(() => _pageMessage = '结果未知状态写回失败：$error');
    } finally {
      if (mounted) setState(() => _submitBusy = false);
    }
  }

  Map<String, dynamic> _decodeJsResult(Object result) {
    var raw = result.toString();
    if (raw.startsWith('"') && raw.endsWith('"')) {
      try {
        raw = jsonDecode(raw) as String;
      } catch (_) {
        // Android/iOS platform implementations serialize results differently.
      }
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('WebView 返回格式不正确');
    return Map<String, dynamic>.from(decoded);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _canvas,
      appBar: AppBar(
        title: const Text('MDAC 人工处理'),
        backgroundColor: Colors.white,
        foregroundColor: _ink,
        actions: [
          IconButton(
            tooltip: '刷新任务状态',
            onPressed: _loading
                ? null
                : () => _loadBatch(preferItemId: _active?.id),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? _errorState()
          : _batch == null
          ? const Center(child: Text('没有批次资料'))
          : _content(),
    );
  }

  Widget _errorState() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, color: _danger, size: 42),
          const SizedBox(height: 12),
          Text(_loadError ?? '加载失败', textAlign: TextAlign.center),
          const SizedBox(height: 14),
          FilledButton(onPressed: _loadBatch, child: const Text('重试')),
        ],
      ),
    ),
  );

  Widget _content() {
    final batch = _batch!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final list = _itemList(batch);
        final browser = _browserPanel();
        if (!wide) {
          return Column(
            children: [
              SizedBox(height: 180, child: list),
              const Divider(height: 1),
              Expanded(child: browser),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 320, child: list),
            const VerticalDivider(width: 1),
            Expanded(child: browser),
          ],
        );
      },
    );
  }

  Widget _itemList(_MdacHumanBatch batch) {
    return ColoredBox(
      color: Colors.white,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Text(
            '${batch.items.where((item) => item.isSucceeded).length}/${batch.items.length} 已确认成功',
            style: const TextStyle(fontWeight: FontWeight.w800, color: _ink),
          ),
          const SizedBox(height: 4),
          Text(
            '${batch.entryDate} → ${batch.exitDate}',
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          for (final item in batch.items)
            Card(
              elevation: 0,
              color: _active?.id == item.id ? const Color(0xFFE7F6F1) : _canvas,
              child: ListTile(
                dense: true,
                enabled: item.canOpenReview,
                onTap: item.canOpenReview ? () => _openItem(item) : null,
                leading: Icon(
                  item.isSucceeded
                      ? Icons.check_circle_rounded
                      : item.resultUnknown
                      ? Icons.help_outline_rounded
                      : Icons.person_outline_rounded,
                  color: item.isSucceeded
                      ? _teal
                      : item.resultUnknown
                      ? _warning
                      : _ink,
                ),
                title: Text(
                  item.fullName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${item.maskedPassport} · ${item.statusLabel}'),
                trailing: item.canOpenReview
                    ? const Icon(Icons.chevron_right_rounded)
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  Widget _browserPanel() {
    final item = _active;
    if (item == null) {
      final remaining = _batch!.items
          .where((entry) => entry.canOpenReview)
          .length;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            remaining == 0
                ? '这个批次没有可以继续提交的项目。已成功或结果未知的项目不会自动重新提交。'
                : '请选择一位待人工处理的客户。',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted),
          ),
        ),
      );
    }
    return Column(
      children: [
        _safetyBanner(item),
        Expanded(
          child: Stack(
            children: [
              if (_controller != null)
                Positioned.fill(child: WebViewWidget(controller: _controller!))
              else if (item.registrationStatus == 'SUBMITTED')
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(28),
                    child: Text(
                      '原来的官方结果页已不可恢复。请先用官方查询核实；当前页面不会再次载入注册表单，也不会再次提交。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _muted),
                    ),
                  ),
                )
              else
                const Center(child: CircularProgressIndicator()),
              if (_pageLoading)
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: LinearProgressIndicator(minHeight: 3),
                ),
            ],
          ),
        ),
        _actionBar(item),
      ],
    );
  }

  Widget _safetyBanner(_MdacHumanItem item) {
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.shield_outlined, color: _teal, size: 20),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${item.fullName} · ${item.maskedPassport}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _pageMessage ?? 'App 不会拖动、破解或外包 CAPTCHA。滑块必须由你本人完成。',
                  style: TextStyle(
                    color: (_pageMessage ?? '').contains('失败')
                        ? _danger
                        : _muted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBar(_MdacHumanItem item) {
    final blocked =
        item.registrationStatus == 'SUBMITTED' ||
        item.registrationStatus == 'RESULT_UNKNOWN' ||
        item.resultUnknown;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: SafeArea(
        top: false,
        child: blocked && !_submitClicked
            ? Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Icon(Icons.warning_amber_rounded, color: _warning),
                  const Text(
                    '已记录提交尝试；为避免重复注册，这里不会再次提供 Submit。',
                    style: TextStyle(color: _ink, fontSize: 12),
                  ),
                  if (item.registrationStatus == 'SUBMITTED')
                    TextButton.icon(
                      onPressed: _submitBusy ? null : _markUnknown,
                      icon: const Icon(Icons.help_outline_rounded),
                      label: const Text('标记结果无法确认'),
                    ),
                ],
              )
            : Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _submitBusy ? null : _checkCaptchaState,
                    icon: const Icon(Icons.touch_app_outlined),
                    label: Text(_captchaReady ? '滑块已通过 / 可提交' : '检查滑块状态'),
                  ),
                  FilledButton.icon(
                    onPressed: _captchaReady && !_submitClicked && !_submitBusy
                        ? _confirmAndSubmit
                        : null,
                    icon: _submitBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_outlined),
                    label: const Text('确认提交 MDAC'),
                  ),
                  if (_submitClicked) ...[
                    FilledButton.icon(
                      onPressed: _submitBusy ? null : _confirmOfficialSuccess,
                      icon: const Icon(Icons.verified_outlined),
                      label: const Text('确认官方结果成功'),
                    ),
                    TextButton.icon(
                      onPressed: _submitBusy ? null : _markUnknown,
                      icon: const Icon(Icons.help_outline_rounded),
                      label: const Text('结果无法确认'),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _MdacHumanBatch {
  const _MdacHumanBatch({
    required this.id,
    required this.entryDate,
    required this.exitDate,
    required this.settings,
    required this.items,
  });

  factory _MdacHumanBatch.fromRow(
    Map<String, dynamic> row,
    List<_MdacHumanItem> items,
  ) {
    final settingsRaw = row['mdac_settings_snapshot'];
    if (settingsRaw is! Map) {
      throw const FormatException('批次缺少 MDAC 设置快照。');
    }
    return _MdacHumanBatch(
      id: row['id'].toString(),
      entryDate: row['entry_date']?.toString() ?? '',
      exitDate: row['exit_date']?.toString() ?? '',
      settings: Map<String, dynamic>.from(settingsRaw),
      items: items,
    );
  }

  final String id;
  final String entryDate;
  final String exitDate;
  final Map<String, dynamic> settings;
  final List<_MdacHumanItem> items;

  Map<String, dynamic> formPayload(_MdacHumanItem item) {
    String requiredValue(Map<String, dynamic> source, String key) {
      final value = source[key]?.toString().trim() ?? '';
      if (value.isEmpty) throw FormatException('任务快照缺少 $key');
      return value;
    }

    final snapshot = item.snapshot;
    final nationality = requiredValue(snapshot, 'nationality').toUpperCase();
    final pobMode = requiredValue(settings, 'pob_mode').toUpperCase();
    final pob = pobMode == 'CUSTOMER'
        ? requiredValue(snapshot, 'place_of_birth').toUpperCase()
        : nationality;
    final gender = requiredValue(snapshot, 'gender').toUpperCase();
    final sex = {'男', 'MALE', '1'}.contains(gender)
        ? '1'
        : {'女', 'FEMALE', '2'}.contains(gender)
        ? '2'
        : throw FormatException('无法识别性别 $gender');

    return {
      'region': requiredValue(settings, 'region_code'),
      'nationality': nationality,
      'pob': pob,
      'sex': sex,
      'name': requiredValue(snapshot, 'full_name'),
      'passNo': requiredValue(snapshot, 'passport_number').toUpperCase(),
      'dob': formatMdacHumanDate(snapshot['date_of_birth']),
      'passExpDte': formatMdacHumanDate(snapshot['passport_expiry_date']),
      'arrDt': formatMdacHumanDate(snapshot['entry_date'] ?? entryDate),
      'depDt': formatMdacHumanDate(snapshot['exit_date'] ?? exitDate),
      'email': requiredValue(settings, 'mdac_email'),
      'mobile': requiredValue(settings, 'mdac_phone'),
      'travelMode': requiredValue(settings, 'travel_mode'),
      'embark': requiredValue(settings, 'embark_country').toUpperCase(),
      'vessel': requiredValue(settings, 'vessel'),
      'accommodationStay': requiredValue(settings, 'accommodation_stay'),
      'address1': requiredValue(settings, 'address1'),
      'address2': settings['address2']?.toString().trim() ?? '',
      'stateCode': requiredValue(settings, 'state_code'),
      'cityCode': requiredValue(settings, 'city_code'),
      'postcode': requiredValue(settings, 'postcode'),
    };
  }
}

class _MdacHumanItem {
  const _MdacHumanItem({
    required this.id,
    required this.customerId,
    required this.snapshot,
    required this.itemStatus,
    required this.resultUnknown,
    required this.registrationStatus,
    required this.registrationNo,
  });

  factory _MdacHumanItem.fromRows(
    Map<String, dynamic> item,
    Map<String, dynamic>? registration,
  ) {
    final snapshotRaw = item['customer_snapshot'];
    return _MdacHumanItem(
      id: item['id'].toString(),
      customerId: item['customer_id'].toString(),
      snapshot: snapshotRaw is Map
          ? Map<String, dynamic>.from(snapshotRaw)
          : const <String, dynamic>{},
      itemStatus: item['status']?.toString() ?? '',
      resultUnknown:
          item['result_unknown'] == true ||
          registration?['registration_status']?.toString() == 'RESULT_UNKNOWN',
      registrationStatus: registration?['registration_status']?.toString(),
      registrationNo: registration?['registration_no']?.toString(),
    );
  }

  final String id;
  final String customerId;
  final Map<String, dynamic> snapshot;
  final String itemStatus;
  final bool resultUnknown;
  final String? registrationStatus;
  final String? registrationNo;

  String get fullName => snapshot['full_name']?.toString() ?? '未命名客户';
  String get passportNumber => snapshot['passport_number']?.toString() ?? '';
  String get maskedPassport {
    final value = passportNumber.trim();
    if (value.length <= 4) return '••••';
    return '${value.substring(0, 2)}••••${value.substring(value.length - 2)}';
  }

  bool get isSucceeded => itemStatus == 'SUCCEEDED';
  bool get canOpenReview =>
      itemStatus == 'NEEDS_REVIEW' &&
      !resultUnknown &&
      registrationStatus != 'RESULT_UNKNOWN';
  bool get canOpenForm => canOpenReview && registrationStatus != 'SUBMITTED';

  String get statusLabel {
    if (isSucceeded) return '已成功';
    if (resultUnknown || registrationStatus == 'RESULT_UNKNOWN') return '结果未知';
    if (registrationStatus == 'SUBMITTED') return '已提交待确认';
    if (itemStatus == 'NEEDS_REVIEW') return '待人工处理';
    return itemStatus;
  }
}
