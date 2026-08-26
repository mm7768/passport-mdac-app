import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'supabase_gateway.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseGateway.initialize();
  runApp(const MdacPilotApp());
}

class MdacPilotApp extends StatefulWidget {
  const MdacPilotApp({super.key});

  @override
  State<MdacPilotApp> createState() => _MdacPilotAppState();
}

class _MdacPilotAppState extends State<MdacPilotApp> {
  final DemoRepository repository = DemoRepository();
  bool signedIn = false;
  bool restoring = true;
  String signedInName = '';
  UserRole signedInRole = UserRole.owner;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final session = await SupabaseGateway.restoreSession();
    if (!mounted) return;
    if (session != null) {
      final syncError = await repository.syncCustomersFromSupabase();
      final batchSyncError = await repository.syncOcrBatchesFromSupabase();
      final ocrResultSyncError = await repository.syncOcrResultsFromSupabase();
      final automationSyncError = await repository
          .syncAutomationTasksFromSupabase();
      final mdacSettingsSyncError = await repository
          .syncMdacSettingsFromSupabase();
      if (syncError != null) repository.auditEvents.insert(0, syncError);
      if (batchSyncError != null)
        repository.auditEvents.insert(0, batchSyncError);
      if (ocrResultSyncError != null)
        repository.auditEvents.insert(0, ocrResultSyncError);
      if (automationSyncError != null)
        repository.auditEvents.insert(0, automationSyncError);
      if (mdacSettingsSyncError != null)
        repository.auditEvents.insert(0, mdacSettingsSyncError);
      if (!mounted) return;
      signedIn = true;
      signedInName = session.name;
      signedInRole = session.role == 'OWNER'
          ? UserRole.owner
          : UserRole.operator;
    }
    if (mounted) setState(() => restoring = false);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MDAC Desk',
      theme: AppTheme.light(),
      home: restoring
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : signedIn
          ? MdacShell(
              repository: repository,
              userName: signedInName,
              role: signedInRole,
              onSignOut: () async {
                await SupabaseGateway.signOut();
                if (mounted) setState(() => signedIn = false);
              },
            )
          : LoginScreen(
              onLogin: (name, role) async {
                final syncError = await repository.syncCustomersFromSupabase();
                final batchSyncError = await repository
                    .syncOcrBatchesFromSupabase();
                final ocrResultSyncError = await repository
                    .syncOcrResultsFromSupabase();
                final automationSyncError = await repository
                    .syncAutomationTasksFromSupabase();
                final mdacSettingsSyncError = await repository
                    .syncMdacSettingsFromSupabase();
                if (syncError != null) {
                  repository.auditEvents.insert(0, syncError);
                }
                if (batchSyncError != null) {
                  repository.auditEvents.insert(0, batchSyncError);
                }
                if (ocrResultSyncError != null) {
                  repository.auditEvents.insert(0, ocrResultSyncError);
                }
                if (automationSyncError != null) {
                  repository.auditEvents.insert(0, automationSyncError);
                }
                if (mdacSettingsSyncError != null) {
                  repository.auditEvents.insert(0, mdacSettingsSyncError);
                }
                if (!mounted) return;
                setState(() {
                  signedIn = true;
                  signedInName = name;
                  signedInRole = role;
                });
              },
            ),
    );
  }
}

class AppTheme {
  static const ink = Color(0xFF12383E);
  static const deep = Color(0xFF073B43);
  static const teal = Color(0xFF138A8A);
  static const mint = Color(0xFFDDF3EB);
  static const orange = Color(0xFFF3A25E);
  static const canvas = Color(0xFFF4F7F6);
  static const muted = Color(0xFF708287);
  static const line = Color(0xFFE2EAE8);
  static const danger = Color(0xFFD9635D);
  static const warning = Color(0xFFE3A228);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: teal,
      brightness: Brightness.light,
      primary: teal,
      surface: Colors.white,
      error: danger,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      fontFamily: 'Arial',
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w800,
          color: ink,
          height: 1.12,
        ),
        headlineMedium: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: ink,
        ),
        titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: ink,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: ink,
        ),
        bodyLarge: TextStyle(fontSize: 15, color: ink, height: 1.35),
        bodyMedium: TextStyle(fontSize: 13, color: muted, height: 1.35),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: teal, width: 1.5),
        ),
        labelStyle: const TextStyle(color: muted),
        hintStyle: const TextStyle(color: Color(0xFFA2AFB0)),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: mint,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
        ),
      ),
      dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
    );
  }
}

enum UserRole { owner, operator }

enum AppSection { overview, customers, tasks, settings }

enum TaskType { mdacRegistration, gmailPin, registrationCheck, visitPassCheck }

enum TaskStatus {
  queued,
  running,
  succeeded,
  partialSuccess,
  failed,
  needsReview,
}

const customerGenderOptions = <String>['男', '女'];
const customerBusinessStatusOptions = <String>[
  'PENDING',
  'MDAC_REGISTERING',
  'MDAC_REGISTERED',
  'PIN_PENDING',
  'PIN_RECEIVED',
  'REGISTRATION_CHECKED',
  'VISIT_PASS_CHECKED',
  'ACTION_REQUIRED',
  'ARCHIVED',
];

class Customer {
  Customer({
    required this.id,
    required this.fullName,
    required this.passportNumber,
    required this.dateOfBirth,
    required this.placeOfBirth,
    required this.nationality,
    required this.gender,
    required this.passportExpiryDate,
    required this.businessStatus,
    required this.createdAt,
    required this.createdBy,
    this.deletedAt,
    this.pin,
    this.registrationNumber,
    this.lastSummary,
  });

  final String id;
  String fullName;
  String passportNumber;
  String dateOfBirth;
  String placeOfBirth;
  String nationality;
  String gender;
  String passportExpiryDate;
  String businessStatus;
  DateTime createdAt;
  String createdBy;
  DateTime? deletedAt;
  String? pin;
  String? registrationNumber;
  String? lastSummary;

  bool get isDeleted => deletedAt != null;
  bool get hasMdacFields => [
    fullName,
    passportNumber,
    dateOfBirth,
    placeOfBirth,
    nationality,
    gender,
    passportExpiryDate,
  ].every((value) => value.trim().isNotEmpty);
}

class OcrDraft {
  OcrDraft({
    required this.id,
    required this.sourceLabel,
    required this.sourceIndex,
    required this.fullName,
    required this.passportNumber,
    required this.dateOfBirth,
    required this.placeOfBirth,
    required this.nationality,
    required this.gender,
    required this.passportExpiryDate,
    required this.confidence,
  });

  final String id;
  final String sourceLabel;
  final String sourceIndex;
  String fullName;
  String passportNumber;
  String dateOfBirth;
  String placeOfBirth;
  String nationality;
  String gender;
  String passportExpiryDate;
  double confidence;

  bool get isLowConfidence => confidence < 0.9;
  bool get isComplete => [
    fullName,
    passportNumber,
    dateOfBirth,
    placeOfBirth,
    nationality,
    gender,
    passportExpiryDate,
  ].every((value) => value.trim().isNotEmpty);
}

enum UploadStatus { selecting, uploading, uploaded, failed }

class UploadRecord {
  UploadRecord({
    required this.id,
    required this.fileName,
    required this.isPdf,
    required this.sizeBytes,
    required this.createdAt,
    this.status = UploadStatus.uploading,
    this.progress = 0,
    this.batchId,
    this.filePath,
    this.errorMessage,
    this.retryBytes,
  });

  final String id;
  final String fileName;
  final bool isPdf;
  final int sizeBytes;
  final DateTime createdAt;
  UploadStatus status;
  double progress;
  String? batchId;
  String? filePath;
  String? errorMessage;
  Uint8List? retryBytes;

  String get fingerprint => '$fileName:$sizeBytes';
  bool get isFinished =>
      status == UploadStatus.uploaded || status == UploadStatus.failed;
}

class AutomationTask {
  AutomationTask({
    required this.id,
    required this.type,
    required this.customerIds,
    required this.createdAt,
    required this.createdBy,
    this.entryDate,
    this.exitDate,
    this.status = TaskStatus.queued,
    this.successCount = 0,
    this.failedCount = 0,
    this.note = '',
  });

  final String id;
  final TaskType type;
  final List<String> customerIds;
  final DateTime createdAt;
  final String createdBy;
  final DateTime? entryDate;
  final DateTime? exitDate;
  TaskStatus status;
  int successCount;
  int failedCount;
  String note;

  int get totalCount => customerIds.length;
  int get completedCount => successCount + failedCount;
  double get progress => totalCount == 0 ? 0 : completedCount / totalCount;
}

class MdacSettings {
  const MdacSettings({
    required this.mdacEmail,
    required this.mdacPhone,
    required this.regionCode,
    required this.travelMode,
    required this.embarkCountry,
    required this.vessel,
    required this.accommodationStay,
    required this.address1,
    required this.address2,
    required this.stateCode,
    required this.cityCode,
    required this.postcode,
    required this.pobMode,
    this.updatedAt,
  });

  factory MdacSettings.defaults() => const MdacSettings(
    mdacEmail: '',
    mdacPhone: '',
    regionCode: '60',
    travelMode: '2',
    embarkCountry: '',
    vessel: '',
    accommodationStay: '02',
    address1: '',
    address2: '',
    stateCode: '',
    cityCode: '',
    postcode: '',
    pobMode: 'NATIONALITY',
  );

  factory MdacSettings.fromMap(Map<String, dynamic> row) {
    String read(String key, [String fallback = '']) =>
        row[key]?.toString() ?? fallback;
    return MdacSettings(
      mdacEmail: read('mdac_email'),
      mdacPhone: read('mdac_phone'),
      regionCode: read('region_code', '60'),
      travelMode: read('travel_mode', '2'),
      embarkCountry: read('embark_country').toUpperCase(),
      vessel: read('vessel'),
      accommodationStay: read('accommodation_stay', '02'),
      address1: read('address1'),
      address2: read('address2'),
      stateCode: read('state_code'),
      cityCode: read('city_code'),
      postcode: read('postcode'),
      pobMode: read('pob_mode', 'NATIONALITY'),
      updatedAt: DateTime.tryParse(row['updated_at']?.toString() ?? ''),
    );
  }

  final String mdacEmail;
  final String mdacPhone;
  final String regionCode;
  final String travelMode;
  final String embarkCountry;
  final String vessel;
  final String accommodationStay;
  final String address1;
  final String address2;
  final String stateCode;
  final String cityCode;
  final String postcode;
  final String pobMode;
  final DateTime? updatedAt;

  bool get isComplete => [
    mdacEmail,
    mdacPhone,
    regionCode,
    travelMode,
    embarkCountry,
    vessel,
    accommodationStay,
    address1,
    stateCode,
    cityCode,
    postcode,
    pobMode,
  ].every((value) => value.trim().isNotEmpty);

  Map<String, dynamic> toRpcParams() => {
    'mdacEmail': mdacEmail.trim(),
    'mdacPhone': mdacPhone.trim(),
    'regionCode': regionCode.trim(),
    'travelMode': travelMode.trim(),
    'embarkCountry': embarkCountry.trim().toUpperCase(),
    'vessel': vessel.trim(),
    'accommodationStay': accommodationStay.trim(),
    'address1': address1.trim(),
    'address2': address2.trim(),
    'stateCode': stateCode.trim(),
    'cityCode': cityCode.trim(),
    'postcode': postcode.trim(),
    'pobMode': pobMode.trim().toUpperCase(),
  };
}

class DemoRepository extends ChangeNotifier {
  DemoRepository() {
    mdacSettings = MdacSettings.defaults();
    _seed();
  }

  final List<Customer> customers = [];
  final List<OcrDraft> ocrDrafts = [];
  final List<AutomationTask> tasks = [];
  final List<String> auditEvents = [];
  final List<UploadRecord> uploadRecords = [];
  final Set<String> _successfulUploadFingerprints = {};
  bool workerOnline = true;
  String workerVersion = 'fill-preview 0.1.0';
  String currentWorkerActivity = '空闲，等待任务';
  MdacSettings? mdacSettings;
  bool mdacSettingsLoading = false;

  void _seed() {
    final now = DateTime.now();
    customers.addAll([
      Customer(
        id: 'c-001',
        fullName: 'TANG FUMING',
        passportNumber: 'EJ1660876',
        dateOfBirth: '18/10/1981',
        placeOfBirth: 'CHINA',
        nationality: 'CHN',
        gender: '男',
        passportExpiryDate: '23/04/2036',
        businessStatus: 'MDAC_REGISTERED',
        createdAt: now.subtract(const Duration(days: 4)),
        createdBy: '粉肠哥',
        registrationNumber: 'MDAC-240801-001',
        lastSummary: 'Registration 已提交，等待 PIN 邮件',
      ),
      Customer(
        id: 'c-002',
        fullName: 'LIM WEI JIE',
        passportNumber: 'KJ4829103',
        dateOfBirth: '03/02/1990',
        placeOfBirth: 'MALAYSIA',
        nationality: 'MYS',
        gender: '男',
        passportExpiryDate: '11/09/2031',
        businessStatus: 'PIN_RECEIVED',
        createdAt: now.subtract(const Duration(days: 3)),
        createdBy: 'Alicia',
        pin: '8pczkJDr',
        registrationNumber: 'MDAC-240801-002',
        lastSummary: 'PIN 已通过护照号唯一匹配',
      ),
      Customer(
        id: 'c-003',
        fullName: 'NUR AINA BINTI AZMAN',
        passportNumber: 'A12980461',
        dateOfBirth: '28/06/1995',
        placeOfBirth: 'MALAYSIA',
        nationality: 'MYS',
        gender: '女',
        passportExpiryDate: '07/01/2030',
        businessStatus: 'ACTION_REQUIRED',
        createdAt: now.subtract(const Duration(days: 1)),
        createdBy: 'Marcus',
        lastSummary: '上一次查询结果无法解析，需要重试',
      ),
      Customer(
        id: 'c-004',
        fullName: 'CHEN YU HAN',
        passportNumber: 'G34729104',
        dateOfBirth: '12/11/1988',
        placeOfBirth: 'CHINA',
        nationality: 'CHN',
        gender: '女',
        passportExpiryDate: '16/05/2034',
        businessStatus: 'PENDING',
        createdAt: now.subtract(const Duration(hours: 9)),
        createdBy: '粉肠哥',
      ),
    ]);

    tasks.addAll([
      AutomationTask(
        id: 'task-001',
        type: TaskType.mdacRegistration,
        customerIds: ['c-001', 'c-002'],
        createdAt: now.subtract(const Duration(hours: 2)),
        createdBy: '粉肠哥',
        entryDate: now.add(const Duration(days: 8)),
        exitDate: now.add(const Duration(days: 15)),
        status: TaskStatus.succeeded,
        successCount: 2,
        note: 'dry-run 演示批次，结果已写回客户档案',
      ),
      AutomationTask(
        id: 'task-002',
        type: TaskType.gmailPin,
        customerIds: ['c-001', 'c-003'],
        createdAt: now.subtract(const Duration(minutes: 48)),
        createdBy: 'Alicia',
        status: TaskStatus.partialSuccess,
        successCount: 1,
        failedCount: 1,
        note: '一项唯一匹配，一项因护照号未找到进入待处理',
      ),
    ]);
  }

  List<Customer> get activeCustomers =>
      customers.where((customer) => !customer.isDeleted).toList();

  Customer? findCustomer(String id) {
    for (final customer in customers) {
      if (customer.id == id) return customer;
    }
    return null;
  }

  bool get remoteMode =>
      SupabaseGateway.isConfigured && SupabaseGateway.currentUserId != null;

  Future<String?> syncCustomersFromSupabase() async {
    if (!remoteMode) return null;
    try {
      final rows = await SupabaseGateway.fetchCustomers();
      customers
        ..clear()
        ..addAll(rows.map(_customerFromRemote));
      auditEvents.insert(0, '已从 Supabase 同步 ${customers.length} 个客户档案');
      notifyListeners();
      return null;
    } catch (exception) {
      return '客户云端同步失败：$exception';
    }
  }

  Future<String?> syncMdacSettingsFromSupabase() async {
    if (!remoteMode) return null;
    mdacSettingsLoading = true;
    notifyListeners();
    try {
      final row = await SupabaseGateway.fetchMdacSettings();
      mdacSettings = MdacSettings.fromMap(row);
      auditEvents.insert(0, '已从 Supabase 同步 MDAC 默认配置');
      return null;
    } catch (exception) {
      return 'MDAC 设置同步失败：$exception';
    } finally {
      mdacSettingsLoading = false;
      notifyListeners();
    }
  }

  Future<String?> saveMdacSettings(MdacSettings value) async {
    if (!remoteMode) {
      mdacSettings = value;
      auditEvents.insert(0, '已保存本地 MDAC 默认配置');
      notifyListeners();
      return null;
    }
    mdacSettingsLoading = true;
    notifyListeners();
    try {
      final row = await SupabaseGateway.updateMdacSettings(
        mdacEmail: value.mdacEmail,
        mdacPhone: value.mdacPhone,
        regionCode: value.regionCode,
        travelMode: value.travelMode,
        embarkCountry: value.embarkCountry,
        vessel: value.vessel,
        accommodationStay: value.accommodationStay,
        address1: value.address1,
        address2: value.address2,
        stateCode: value.stateCode,
        cityCode: value.cityCode,
        postcode: value.postcode,
        pobMode: value.pobMode,
      );
      mdacSettings = MdacSettings.fromMap(row);
      auditEvents.insert(0, '已保存 MDAC 默认配置，并写入审计日志');
      return null;
    } catch (exception) {
      return 'MDAC 设置保存失败：$exception';
    } finally {
      mdacSettingsLoading = false;
      notifyListeners();
    }
  }

  Future<String?> syncAutomationTasksFromSupabase() async {
    if (!remoteMode) return null;
    try {
      final rows = await SupabaseGateway.fetchAutomationBatches();
      final remoteTasks = <AutomationTask>[];
      for (final row in rows) {
        final items = row['items'] is List
            ? (row['items'] as List)
                  .whereType<Map>()
                  .map((item) => Map<String, dynamic>.from(item))
                  .toList()
            : <Map<String, dynamic>>[];
        final status = _taskStatusFromRemote(row['status']?.toString());
        remoteTasks.add(
          AutomationTask(
            id: row['id']?.toString() ?? 'remote-batch',
            type: TaskType.mdacRegistration,
            customerIds: [
              for (final item in items)
                if (item['customer_id'] != null) item['customer_id'].toString(),
            ],
            createdAt:
                DateTime.tryParse(row['created_at']?.toString() ?? '') ??
                DateTime.now(),
            createdBy: row['created_by']?.toString() ?? 'Supabase',
            entryDate: _parseRemoteDate(row['entry_date']),
            exitDate: _parseRemoteDate(row['exit_date']),
            status: status,
            successCount:
                int.tryParse(row['success_count']?.toString() ?? '') ?? 0,
            failedCount:
                int.tryParse(row['failed_count']?.toString() ?? '') ?? 0,
            note: row['note']?.toString() ?? '',
          ),
        );
      }
      tasks
        ..clear()
        ..addAll(remoteTasks);
      notifyListeners();
      return null;
    } catch (exception) {
      return 'MDAC 任务同步失败：$exception';
    }
  }

  TaskStatus _taskStatusFromRemote(String? value) {
    switch (value) {
      case 'RUNNING':
      case 'CLAIMED':
        return TaskStatus.running;
      case 'SUCCEEDED':
        return TaskStatus.succeeded;
      case 'PARTIAL_SUCCESS':
        return TaskStatus.partialSuccess;
      case 'FAILED':
      case 'CANCELLED':
        return TaskStatus.failed;
      case 'NEEDS_REVIEW':
        return TaskStatus.needsReview;
      case 'QUEUED':
      default:
        return TaskStatus.queued;
    }
  }

  DateTime? _parseRemoteDate(dynamic value) {
    final raw = value?.toString();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  Future<String?> syncOcrBatchesFromSupabase() async {
    if (!remoteMode) return null;
    try {
      final rows = await SupabaseGateway.fetchOcrBatches();
      uploadRecords
        ..clear()
        ..addAll(
          rows.map((row) {
            final metadata = row['metadata'] is Map
                ? Map<String, dynamic>.from(row['metadata'] as Map)
                : <String, dynamic>{};
            final sourceType = row['source_type']?.toString() ?? 'IMAGE';
            final isFailed = row['status']?.toString() == 'FAILED';
            final record = UploadRecord(
              id: 'remote-upload-${row['id']}',
              fileName:
                  metadata['original_file_name']?.toString() ??
                  row['file_path']?.toString().split('/').last ??
                  'passport-document',
              isPdf: sourceType == 'PDF',
              sizeBytes:
                  int.tryParse(metadata['size_bytes']?.toString() ?? '') ?? 0,
              createdAt:
                  DateTime.tryParse(row['created_at']?.toString() ?? '') ??
                  DateTime.now(),
              status: isFailed ? UploadStatus.failed : UploadStatus.uploaded,
              progress: isFailed ? 0 : 1,
              batchId: row['id']?.toString(),
              filePath: row['file_path']?.toString(),
              errorMessage: row['error_message']?.toString(),
            );
            final hash = metadata['content_hash']?.toString();
            if (hash != null && hash.isNotEmpty && !isFailed) {
              _successfulUploadFingerprints.add(hash);
            }
            return record;
          }),
        );
      notifyListeners();
      return null;
    } catch (exception) {
      return 'OCR 批次同步失败：$exception';
    }
  }

  Future<String?> syncOcrResultsFromSupabase() async {
    if (!remoteMode) return null;
    try {
      final rows = await SupabaseGateway.fetchOcrResults();
      final fileNames = <String, String>{
        for (final upload in uploadRecords)
          if (upload.batchId != null) upload.batchId!: upload.fileName,
      };
      final drafts = <OcrDraft>[];
      for (final row in rows) {
        final status = row['status']?.toString() ?? 'REVIEW_REQUIRED';
        if (status != 'REVIEW_REQUIRED' && status != 'READY_TO_CREATE') {
          continue;
        }
        final extracted = row['extracted_data'] is Map
            ? Map<String, dynamic>.from(row['extracted_data'] as Map)
            : <String, dynamic>{};
        final batchId = row['batch_id']?.toString() ?? 'unknown-batch';
        final pageIndex =
            int.tryParse(row['page_index']?.toString() ?? '') ?? 0;
        final segmentIndex =
            int.tryParse(row['segment_index']?.toString() ?? '') ?? 0;
        final confidence =
            double.tryParse(row['confidence']?.toString() ?? '') ?? 0;
        drafts.add(
          OcrDraft(
            id: 'remote-ocr-${row['id']}',
            sourceLabel: fileNames[batchId] ?? 'OCR 批次 $batchId',
            sourceIndex: '第 ${pageIndex + 1} 页 · 护照 ${segmentIndex + 1}',
            fullName: extracted['full_name']?.toString() ?? '',
            passportNumber: extracted['passport_number']?.toString() ?? '',
            dateOfBirth: _displayDate(
              extracted['date_of_birth'] ?? extracted['display_date_of_birth'],
            ),
            placeOfBirth: extracted['place_of_birth']?.toString() ?? '',
            nationality: extracted['nationality']?.toString() ?? '',
            gender: extracted['gender']?.toString() ?? '',
            passportExpiryDate: _displayDate(
              extracted['passport_expiry_date'] ??
                  extracted['display_passport_expiry_date'],
            ),
            confidence: confidence,
          ),
        );
      }
      ocrDrafts
        ..clear()
        ..addAll(drafts);
      notifyListeners();
      return null;
    } catch (exception) {
      return 'OCR 结果同步失败：$exception';
    }
  }

  Customer _customerFromRemote(Map<String, dynamic> row) {
    final pinRecord = row['pin_record'];
    final pin = pinRecord is Map<String, dynamic>
        ? SupabaseGateway.normalizePin(pinRecord['pin_value'] as String?)
        : null;
    final createdAt =
        DateTime.tryParse(row['created_at']?.toString() ?? '') ??
        DateTime.now();
    return Customer(
      id: row['id'].toString(),
      fullName: row['full_name'].toString(),
      passportNumber: row['passport_number'].toString(),
      dateOfBirth: _displayDate(row['date_of_birth']),
      placeOfBirth: row['place_of_birth'].toString(),
      nationality: row['nationality'].toString(),
      gender: row['gender'].toString(),
      passportExpiryDate: _displayDate(row['passport_expiry_date']),
      businessStatus: row['business_status'].toString(),
      createdAt: createdAt,
      createdBy:
          row['created_by_name']?.toString() ?? row['created_by'].toString(),
      deletedAt: row['deleted_at'] == null
          ? null
          : DateTime.tryParse(row['deleted_at'].toString()),
      pin: pin,
      lastSummary: pin == null ? null : 'PIN 已从 Supabase 云端记录读取；中间空格保留',
    );
  }

  String _displayDate(dynamic value) {
    final raw = value?.toString() ?? '';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    return '${parsed.day.toString().padLeft(2, '0')}/'
        '${parsed.month.toString().padLeft(2, '0')}/${parsed.year}';
  }

  Future<String?> createCustomerWithSync(
    Map<String, String> values,
    String actor,
  ) async {
    if (!remoteMode) return createManualCustomer(values, actor);
    final error = _validateCustomerValues(values);
    if (error != null) return error;
    try {
      final row = await SupabaseGateway.insertCustomer(
        fullName: values['fullName']!,
        passportNumber: values['passportNumber']!,
        dateOfBirth: values['dateOfBirth']!,
        placeOfBirth: values['placeOfBirth']!,
        nationality: values['nationality']!,
        gender: values['gender']!,
        passportExpiryDate: values['passportExpiryDate']!,
        businessStatus: values['businessStatus'] ?? 'PENDING',
      );
      final customer = _customerFromRemote(row);
      final pin = SupabaseGateway.normalizePin(values['pin']);
      if (pin != null) {
        await SupabaseGateway.insertPinRecord(
          customerId: customer.id,
          pin: pin,
          matchedBy: 'MANUAL',
        );
        customer.pin = pin;
        customer.lastSummary = 'PIN 已写入 Supabase；中间空格保留';
      }
      customers.insert(0, customer);
      auditEvents.insert(0, '$actor 在 Supabase 创建客户 ${customer.fullName}');
      notifyListeners();
      return null;
    } catch (exception) {
      return '客户创建失败，云端未保存：$exception';
    }
  }

  Future<String?> updateCustomerWithSync(
    Customer customer,
    Map<String, String> values,
    String actor,
  ) async {
    final validationError = _validateCustomerValues(
      values,
      excludeId: customer.id,
    );
    if (validationError != null) return validationError;
    if (!remoteMode || customer.id.startsWith('c-')) {
      return updateCustomer(customer, values, actor);
    }

    try {
      final nextPin = SupabaseGateway.normalizePin(values['pin']);
      final previousPin = customer.pin;
      final row = await SupabaseGateway.updateCustomer(
        id: customer.id,
        fullName: values['fullName']!,
        passportNumber: values['passportNumber']!,
        dateOfBirth: values['dateOfBirth']!,
        placeOfBirth: values['placeOfBirth']!,
        nationality: values['nationality']!,
        gender: values['gender']!,
        passportExpiryDate: values['passportExpiryDate']!,
        businessStatus: values['businessStatus'],
      );
      if (nextPin == null && previousPin != null) {
        await SupabaseGateway.clearLatestPinRecord(customer.id);
      } else if (nextPin != null) {
        await SupabaseGateway.insertPinRecord(
          customerId: customer.id,
          pin: nextPin,
          matchedBy: 'MANUAL_EDIT',
        );
      }
      final refreshed = _customerFromRemote(row);
      customer
        ..fullName = refreshed.fullName
        ..passportNumber = refreshed.passportNumber
        ..dateOfBirth = refreshed.dateOfBirth
        ..placeOfBirth = refreshed.placeOfBirth
        ..nationality = refreshed.nationality
        ..gender = refreshed.gender
        ..passportExpiryDate = refreshed.passportExpiryDate
        ..businessStatus = nextPin == null && previousPin != null
            ? 'PIN_PENDING'
            : refreshed.businessStatus
        ..pin = nextPin
        ..lastSummary = nextPin == null ? null : 'PIN 已写入 Supabase；中间空格保留';
      auditEvents.insert(0, '$actor 在 Supabase 编辑客户 ${customer.fullName}');
      notifyListeners();
      return null;
    } catch (exception) {
      return '客户修改失败，云端未保存：$exception';
    }
  }

  Future<({List<String> blocked, String? error})> deleteCustomersWithSync(
    List<String> ids,
    String actor,
  ) async {
    final blocked = ids.where((id) {
      return tasks.any(
        (task) =>
            (task.status == TaskStatus.queued ||
                task.status == TaskStatus.running ||
                task.status == TaskStatus.needsReview) &&
            task.customerIds.contains(id),
      );
    }).toList();
    final allowed = ids.where((id) => !blocked.contains(id)).toList();
    if (remoteMode) {
      try {
        for (final id in allowed) {
          if (!id.startsWith('c-')) {
            await SupabaseGateway.softDeleteCustomer(id);
          }
        }
      } catch (exception) {
        return (blocked: blocked, error: '客户云端软删除失败：$exception');
      }
    }
    final localBlocked = deleteCustomers(ids, actor);
    return (blocked: {...blocked, ...localBlocked}.toList(), error: null);
  }

  Future<String?> pickAndUploadDocument(String actor) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'],
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      return '无法读取文件内容，请重新选择。';
    }
    final lowerName = file.name.toLowerCase();
    final isPdf = lowerName.endsWith('.pdf');
    final allowed =
        isPdf ||
        lowerName.endsWith('.jpg') ||
        lowerName.endsWith('.jpeg') ||
        lowerName.endsWith('.png');
    if (!allowed) return '只支持 JPG、PNG 或 PDF 文件。';
    if (bytes.length > 15 * 1024 * 1024) {
      return '文件不能超过 15 MB。';
    }

    final contentHash = sha256.convert(bytes).toString();
    final record = UploadRecord(
      id: 'upload-${DateTime.now().microsecondsSinceEpoch}',
      fileName: file.name,
      isPdf: isPdf,
      sizeBytes: bytes.length,
      createdAt: DateTime.now(),
      retryBytes: bytes,
    );
    if (_successfulUploadFingerprints.contains(contentHash)) {
      return '这个文件已经上传过，已阻止重复提交。';
    }
    uploadRecords.insert(0, record);
    notifyListeners();
    return _uploadRecord(record, bytes, actor, contentHash);
  }

  Future<String?> retryUpload(UploadRecord record, String actor) async {
    final bytes = record.retryBytes;
    if (bytes == null || bytes.isEmpty) return '原文件内容已过期，请重新选择文件。';
    final contentHash = sha256.convert(bytes).toString();
    record.status = UploadStatus.uploading;
    record.progress = 0.05;
    record.errorMessage = null;
    notifyListeners();
    return _uploadRecord(record, bytes, actor, contentHash);
  }

  Future<String?> _uploadRecord(
    UploadRecord record,
    Uint8List bytes,
    String actor,
    String contentHash,
  ) async {
    try {
      record.status = UploadStatus.uploading;
      record.progress = 0.1;
      notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      record.progress = 0.35;
      notifyListeners();

      if (remoteMode) {
        final row = await SupabaseGateway.uploadOcrBatch(
          bytes: bytes,
          fileName: record.fileName,
          isPdf: record.isPdf,
          contentHash: contentHash,
        );
        record.batchId = row['id']?.toString();
        record.filePath = row['file_path']?.toString();
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 260));
        importDemoDocument(isPdf: record.isPdf);
        record.batchId = 'demo-batch-${record.id}';
        record.filePath = 'demo/${record.fileName}';
      }

      record.progress = 1;
      record.status = UploadStatus.uploaded;
      record.errorMessage = null;
      record.retryBytes = null;
      _successfulUploadFingerprints.add(contentHash);
      auditEvents.insert(
        0,
        '$actor 上传 ${record.fileName}，已建立 ${record.isPdf ? 'PDF' : '图片'} OCR 批次',
      );
      notifyListeners();
      return null;
    } catch (exception) {
      record.status = UploadStatus.failed;
      record.progress = 0;
      record.errorMessage = '上传失败：$exception';
      record.retryBytes = bytes;
      auditEvents.insert(0, '$actor 上传 ${record.fileName} 失败，可重试');
      notifyListeners();
      return record.errorMessage;
    }
  }

  void importDemoDocument({required bool isPdf}) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final drafts = isPdf
        ? [
            OcrDraft(
              id: 'ocr-$stamp-a',
              sourceLabel:
                  'passport_batch_${stamp.toString().substring(7)}.pdf',
              sourceIndex: '第 1 页 · 护照 1',
              fullName: 'WONG JIA HAO',
              passportNumber: 'EJ${stamp.toString().substring(8)}',
              dateOfBirth: '09/09/1992',
              placeOfBirth: 'CHINA',
              nationality: 'CHN',
              gender: '男',
              passportExpiryDate: '04/12/2033',
              confidence: 0.94,
            ),
            OcrDraft(
              id: 'ocr-$stamp-b',
              sourceLabel:
                  'passport_batch_${stamp.toString().substring(7)}.pdf',
              sourceIndex: '第 2 页 · 护照 1',
              fullName: 'GOH MEI XIN',
              passportNumber: 'K${stamp.toString().substring(7)}',
              dateOfBirth: '21/04/1997',
              placeOfBirth: 'MALAYSIA',
              nationality: 'MYS',
              gender: '女',
              passportExpiryDate: '18/08/2035',
              confidence: 0.86,
            ),
          ]
        : [
            OcrDraft(
              id: 'ocr-$stamp',
              sourceLabel:
                  'passport_photo_${stamp.toString().substring(7)}.jpg',
              sourceIndex: '图片 1',
              fullName: 'LEE SHU FEN',
              passportNumber: 'EJ${stamp.toString().substring(8)}',
              dateOfBirth: '14/07/1989',
              placeOfBirth: 'CHINA',
              nationality: 'CHN',
              gender: '女',
              passportExpiryDate: '26/10/2032',
              confidence: 0.91,
            ),
          ];
    ocrDrafts.addAll(drafts);
    auditEvents.insert(
      0,
      '上传 ${isPdf ? '多护照 PDF' : '护照图片'}，产生 ${drafts.length} 个 OCR 识别草稿',
    );
    notifyListeners();
  }

  String? confirmOcr(OcrDraft draft, Map<String, String> values, String actor) {
    final validationError = _validateCustomerValues(values);
    if (validationError != null) return validationError;
    final normalizedPassport = values['passportNumber']!.trim().toUpperCase();
    final duplicate = activeCustomers.any(
      (customer) => customer.passportNumber.toUpperCase() == normalizedPassport,
    );
    if (duplicate) return '护照号码 $normalizedPassport 已存在，未创建重复档案。';

    final customer = Customer(
      id: 'c-${DateTime.now().microsecondsSinceEpoch}',
      fullName: values['fullName']!.trim().toUpperCase(),
      passportNumber: normalizedPassport,
      dateOfBirth: values['dateOfBirth']!.trim(),
      placeOfBirth: values['placeOfBirth']!.trim().toUpperCase(),
      nationality: values['nationality']!.trim().toUpperCase(),
      gender: values['gender']!.trim(),
      passportExpiryDate: values['passportExpiryDate']!.trim(),
      businessStatus: values['businessStatus'] ?? 'PENDING',
      createdAt: DateTime.now(),
      createdBy: actor,
    );
    customers.insert(0, customer);
    ocrDrafts.removeWhere((item) => item.id == draft.id);
    auditEvents.insert(0, '确认 OCR 结果并创建客户 ${customer.fullName}');
    notifyListeners();
    return null;
  }

  Future<String?> confirmOcrWithSync(
    OcrDraft draft,
    Map<String, String> values,
    String actor,
  ) async {
    if (!remoteMode) return confirmOcr(draft, values, actor);
    final validationError = _validateCustomerValues(values);
    if (validationError != null) return validationError;
    try {
      final row = await SupabaseGateway.insertCustomer(
        fullName: values['fullName']!,
        passportNumber: values['passportNumber']!,
        dateOfBirth: values['dateOfBirth']!,
        placeOfBirth: values['placeOfBirth']!,
        nationality: values['nationality']!,
        gender: values['gender']!,
        passportExpiryDate: values['passportExpiryDate']!,
        businessStatus: values['businessStatus'] ?? 'PENDING',
      );
      final customer = _customerFromRemote(row);
      final resultId = draft.id.startsWith('remote-ocr-')
          ? draft.id.substring('remote-ocr-'.length)
          : null;
      if (resultId != null) {
        await SupabaseGateway.markOcrResultCreated(
          resultId: resultId,
          customerId: customer.id,
          extractedData: {
            'full_name': values['fullName']!.trim().toUpperCase(),
            'passport_number': values['passportNumber']!.trim().toUpperCase(),
            'date_of_birth': values['dateOfBirth'],
            'place_of_birth': values['placeOfBirth']!.trim().toUpperCase(),
            'nationality': values['nationality']!.trim().toUpperCase(),
            'gender': values['gender'],
            'passport_expiry_date': values['passportExpiryDate'],
            'reviewed_manually': true,
          },
        );
      }
      customers.insert(0, customer);
      ocrDrafts.removeWhere((item) => item.id == draft.id);
      auditEvents.insert(
        0,
        '$actor 确认 OCR 并在 Supabase 创建客户 ${customer.fullName}',
      );
      notifyListeners();
      return null;
    } catch (exception) {
      return 'OCR 客户创建失败，云端未保存：$exception';
    }
  }

  String? createManualCustomer(Map<String, String> values, String actor) {
    final error = _validateCustomerValues(values);
    if (error != null) return error;

    final customer = Customer(
      id: 'c-${DateTime.now().microsecondsSinceEpoch}',
      fullName: values['fullName']!.trim().toUpperCase(),
      passportNumber: values['passportNumber']!.trim().toUpperCase(),
      dateOfBirth: values['dateOfBirth']!.trim(),
      placeOfBirth: values['placeOfBirth']!.trim().toUpperCase(),
      nationality: values['nationality']!.trim().toUpperCase(),
      gender: values['gender']!.trim(),
      passportExpiryDate: values['passportExpiryDate']!.trim(),
      businessStatus: values['businessStatus'] ?? 'PENDING',
      createdAt: DateTime.now(),
      createdBy: actor,
      pin: _pinForStorage(values['pin']),
    );
    customers.insert(0, customer);
    auditEvents.insert(0, '$actor 手动创建客户 ${customer.fullName}');
    notifyListeners();
    return null;
  }

  String? updateCustomer(
    Customer customer,
    Map<String, String> values,
    String actor,
  ) {
    final error = _validateCustomerValues(values, excludeId: customer.id);
    if (error != null) return error;

    customer.fullName = values['fullName']!.trim().toUpperCase();
    customer.passportNumber = values['passportNumber']!.trim().toUpperCase();
    customer.dateOfBirth = values['dateOfBirth']!.trim();
    customer.placeOfBirth = values['placeOfBirth']!.trim().toUpperCase();
    customer.nationality = values['nationality']!.trim().toUpperCase();
    customer.gender = values['gender']!.trim();
    customer.passportExpiryDate = values['passportExpiryDate']!.trim();
    customer.businessStatus =
        values['businessStatus'] ?? customer.businessStatus;
    customer.pin = _pinForStorage(values['pin']);
    auditEvents.insert(0, '$actor 编辑客户 ${customer.fullName}');
    notifyListeners();
    return null;
  }

  String? _validateCustomerValues(
    Map<String, String> values, {
    String? excludeId,
  }) {
    const requiredKeys = [
      'fullName',
      'passportNumber',
      'dateOfBirth',
      'placeOfBirth',
      'nationality',
      'gender',
      'passportExpiryDate',
    ];
    for (final key in requiredKeys) {
      if ((values[key] ?? '').trim().isEmpty) {
        return '缺少必填字段：${fieldLabel(key)}';
      }
    }
    for (final key in ['dateOfBirth', 'passportExpiryDate']) {
      if (!isMdacDate(values[key]!.trim())) {
        return '${fieldLabel(key)}必须是 DD/MM/YYYY，例如 09/08/1990。';
      }
    }
    if (!customerGenderOptions.contains(values['gender']!.trim())) {
      return '性别请选择“男”或“女”。';
    }
    final businessStatus = values['businessStatus'] ?? 'PENDING';
    if (!customerBusinessStatusOptions.contains(businessStatus)) {
      return '业务状态选择无效，请重新选择。';
    }
    final passport = values['passportNumber']!.trim().toUpperCase();
    final duplicate = activeCustomers.any(
      (item) =>
          item.id != excludeId && item.passportNumber.toUpperCase() == passport,
    );
    if (duplicate) return '护照号码 $passport 已存在，未保存重复档案。';
    return null;
  }

  String? _pinForStorage(String? value) {
    if (value == null || value.isEmpty) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? recordPin(String customerId, String pin, String actor) {
    final customer = findCustomer(customerId);
    final storedPin = _pinForStorage(pin);
    if (customer == null || customer.isDeleted) return '客户不存在或已被删除。';
    if (storedPin == null) return 'PIN 不能为空。';

    customer.pin = storedPin;
    customer.businessStatus = 'PIN_RECEIVED';
    customer.lastSummary = 'PIN 已写入客户档案；保留内部空格';
    auditEvents.insert(0, '$actor 写入客户 ${customer.fullName} 的 Gmail PIN');
    notifyListeners();
    return null;
  }

  List<String> deleteCustomers(List<String> ids, String actor) {
    final blocked = <String>[];
    for (final id in ids) {
      final hasRunningTask = tasks.any(
        (task) =>
            (task.status == TaskStatus.queued ||
                task.status == TaskStatus.running ||
                task.status == TaskStatus.needsReview) &&
            task.customerIds.contains(id),
      );
      final customer = findCustomer(id);
      if (customer == null || hasRunningTask) {
        if (customer != null) {
          blocked.add(customer.fullName);
        }
        continue;
      }
      customer.deletedAt = DateTime.now();
      auditEvents.insert(0, '软删除客户 ${customer.fullName}');
    }
    if (blocked.isEmpty) {
      auditEvents.insert(0, '$actor 批量软删除 ${ids.length} 位客户');
    }
    notifyListeners();
    return blocked;
  }

  AutomationTask? activeTaskForCustomer(String customerId) {
    for (final task in tasks) {
      if ((task.status == TaskStatus.queued ||
              task.status == TaskStatus.running ||
              task.status == TaskStatus.needsReview) &&
          task.customerIds.contains(customerId)) {
        return task;
      }
    }
    return null;
  }

  Future<String?> createTaskAsync({
    required TaskType type,
    required List<String> customerIds,
    required String actor,
    DateTime? entryDate,
    DateTime? exitDate,
  }) async {
    if (!remoteMode) {
      return createTask(
        type: type,
        customerIds: customerIds,
        actor: actor,
        entryDate: entryDate,
        exitDate: exitDate,
      );
    }
    if (type != TaskType.mdacRegistration) {
      return '当前只有 MDAC fill-preview Worker 已部署，其他自动化脚本尚未接入云端。';
    }
    if (customerIds.isEmpty) return '请先选择客户。';
    if (entryDate == null || exitDate == null) {
      return 'MDAC 注册必须提供入境和出境日期。';
    }
    if (exitDate.isBefore(entryDate)) {
      return '出境日期不能早于入境日期。';
    }

    final selected = <Customer>[];
    for (final id in customerIds) {
      final customer = findCustomer(id);
      if (customer == null || customer.isDeleted) {
        return '选中的客户已不存在或已被删除，请刷新后重试。';
      }
      if (!customer.hasMdacFields) {
        return '${customer.fullName} 缺少 MDAC 必填资料，不能启动任务。';
      }
      if (activeTaskForCustomer(id) != null) {
        return '${customer.fullName} 已有运行中的任务，系统阻止重复创建。';
      }
      selected.add(customer);
    }

    try {
      await SupabaseGateway.createMdacRegistrationBatch(
        entryDate: entryDate,
        exitDate: exitDate,
        customers: [
          for (final customer in selected)
            {
              'id': customer.id,
              'full_name': customer.fullName,
              'passport_number': customer.passportNumber,
              'date_of_birth': customer.dateOfBirth,
              'place_of_birth': customer.placeOfBirth,
              'nationality': customer.nationality,
              'gender': customer.gender,
              'passport_expiry_date': customer.passportExpiryDate,
            },
        ],
        note: '$actor 创建 MDAC fill-preview 批次；真实页面只填写不提交',
      );
      auditEvents.insert(
        0,
        '$actor 创建 MDAC fill-preview 批次，共 ${selected.length} 位客户；未提交',
      );
      currentWorkerActivity = '已排队，等待 Railway fill-preview Worker';
      await syncAutomationTasksFromSupabase();
      notifyListeners();
      return null;
    } catch (exception) {
      return 'MDAC 批次创建失败：$exception';
    }
  }

  String? createTask({
    required TaskType type,
    required List<String> customerIds,
    required String actor,
    DateTime? entryDate,
    DateTime? exitDate,
  }) {
    if (customerIds.isEmpty) return '请先选择客户。';
    final selected = <Customer>[];
    for (final id in customerIds) {
      final customer = findCustomer(id);
      if (customer == null || customer.isDeleted) {
        return '选中的客户已不存在或已被删除，请刷新后重试。';
      }
      if (!customer.hasMdacFields) {
        return '${customer.fullName} 缺少 MDAC 必填资料，不能启动任务。';
      }
      if (activeTaskForCustomer(id) != null) {
        return '${customer.fullName} 已有运行中的任务，系统阻止重复创建。';
      }
      selected.add(customer);
    }
    if (type == TaskType.mdacRegistration &&
        (entryDate == null || exitDate == null)) {
      return 'MDAC 注册必须提供入境和出境日期。';
    }
    if (type == TaskType.mdacRegistration && exitDate!.isBefore(entryDate!)) {
      return '出境日期不能早于入境日期。';
    }

    final task = AutomationTask(
      id: 'task-${DateTime.now().microsecondsSinceEpoch}',
      type: type,
      customerIds: selected.map((customer) => customer.id).toList(),
      createdAt: DateTime.now(),
      createdBy: actor,
      entryDate: entryDate,
      exitDate: exitDate,
      note: '已写入客户快照，等待离线测试 Worker 领取',
    );
    tasks.insert(0, task);
    auditEvents.insert(
      0,
      '$actor 创建 ${taskTypeLabel(type)} 批次，共 ${selected.length} 位客户',
    );
    notifyListeners();
    _runDryWorker(task);
    return null;
  }

  Future<void> _runDryWorker(AutomationTask task) async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    task.status = TaskStatus.running;
    task.note = 'Worker 已领取任务，逐项执行中';
    currentWorkerActivity =
        '${taskTypeLabel(task.type)} · ${task.customerIds.length} 项处理中';
    notifyListeners();

    for (final customerId in task.customerIds) {
      await Future<void>.delayed(const Duration(milliseconds: 650));
      final customer = findCustomer(customerId);
      if (customer == null ||
          customer.isDeleted ||
          customer.businessStatus == 'ACTION_REQUIRED') {
        task.failedCount += 1;
      } else {
        task.successCount += 1;
        if (task.type == TaskType.mdacRegistration) {
          customer.businessStatus = 'MDAC_REGISTERED';
          customer.registrationNumber =
              'DRY-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}';
          customer.lastSummary = 'dry-run 注册成功；真实网页执行尚未启用';
        } else if (task.type == TaskType.gmailPin) {
          recordPin(customer.id, 'DRY-PIN', 'dry-run Worker');
          customer.lastSummary = 'dry-run IMAP 匹配成功；真实邮箱尚未接入';
        } else if (task.type == TaskType.registrationCheck) {
          customer.businessStatus = 'REGISTRATION_CHECKED';
          customer.lastSummary = 'dry-run 查询结果：保存原始摘要';
        } else if (task.type == TaskType.visitPassCheck) {
          customer.businessStatus = 'VISIT_PASS_CHECKED';
          customer.lastSummary = 'dry-run 查询结果：保存原始摘要';
        }
      }
      notifyListeners();
    }

    if (task.failedCount == task.totalCount) {
      task.status = TaskStatus.failed;
    } else if (task.failedCount > 0) {
      task.status = TaskStatus.partialSuccess;
    } else {
      task.status = TaskStatus.succeeded;
    }
    task.note = task.failedCount > 0
        ? '失败项已停止，不伪装为成功；可按规则重试'
        : '批次完成，结果已逐项写回演示数据层';
    currentWorkerActivity = '空闲，等待任务';
    auditEvents.insert(
      0,
      'Worker 完成 ${taskTypeLabel(task.type)} 批次 ${task.id}',
    );
    notifyListeners();
  }

  void recordExport(List<String> ids, String actor) {
    auditEvents.insert(
      0,
      '$actor 导出选定客户 Excel 演示清单，共 ${ids.length} 位；字段：姓名、护照号码',
    );
    notifyListeners();
  }

  void addAccount(String name, UserRole role, String actor) {
    auditEvents.insert(
      0,
      '$actor 创建演示账号 $name（${roleLabel(role)}），首次登录须修改临时密码',
    );
    notifyListeners();
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({required this.onLogin, super.key});

  final Future<void> Function(String name, UserRole role) onLogin;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final identifierController = TextEditingController(text: 'owner@mdac.local');
  final passwordController = TextEditingController(text: 'demo123');
  bool obscure = true;
  String? error;

  @override
  void dispose() {
    identifierController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final identifier = identifierController.text.trim().toLowerCase();
    final password = passwordController.text;
    if (SupabaseGateway.isConfigured) {
      try {
        final session = await SupabaseGateway.signIn(
          email: identifier,
          password: password,
        );
        await widget.onLogin(
          session.name,
          session.role == 'OWNER' ? UserRole.owner : UserRole.operator,
        );
      } catch (exception) {
        if (!mounted) return;
        setState(
          () =>
              error = exception.toString().replaceFirst('AuthException: ', ''),
        );
      }
      return;
    }
    if (password.trim() != 'demo123' ||
        ![
          'owner@mdac.local',
          'operator1@mdac.local',
          'operator2@mdac.local',
        ].contains(identifier)) {
      setState(() => error = '演示账号或密码不正确。可使用 demo123 登录。');
      return;
    }
    final isOwner = identifier.startsWith('owner');
    widget.onLogin(
      isOwner
          ? '粉肠哥'
          : identifier.startsWith('operator1')
          ? 'Alicia'
          : 'Marcus',
      isOwner ? UserRole.owner : UserRole.operator,
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [AppTheme.deep, Color(0xFF0A5D62)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Row(
                  children: [
                    if (!compact)
                      Expanded(
                        flex: 5,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 48, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const BrandMark(inverted: true),
                              const SizedBox(height: 40),
                              Text(
                                '护照资料与\nMDAC 任务，一处掌握。',
                                style: Theme.of(context).textTheme.headlineLarge
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontSize: 42,
                                    ),
                              ),
                              const SizedBox(height: 18),
                              Text(
                                '从 OCR 审核、客户档案到批量任务队列，\n让办公室 Worker 安静地在后台工作。',
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: Colors.white70,
                                      height: 1.6,
                                    ),
                              ),
                              const SizedBox(height: 38),
                              const LoginFeature(
                                icon: Icons.document_scanner_outlined,
                                title: 'OCR 先审后建档',
                                caption: '低置信度字段不会直接进入业务流程',
                              ),
                              const LoginFeature(
                                icon: Icons.alt_route_rounded,
                                title: '任务与客户状态分离',
                                caption: '每个批次都保留可追溯的执行历史',
                              ),
                              const LoginFeature(
                                icon: Icons.lock_outline_rounded,
                                title: '私密资料边界',
                                caption: '演示版本不连接真实护照或邮箱数据',
                              ),
                            ],
                          ),
                        ),
                      ),
                    Expanded(
                      flex: 4,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '欢迎回来',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium,
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                '登录 MDAC Desk 演示工作区',
                                style: TextStyle(color: AppTheme.muted),
                              ),
                              const SizedBox(height: 28),
                              TextField(
                                controller: identifierController,
                                keyboardType: TextInputType.emailAddress,
                                decoration: const InputDecoration(
                                  labelText: '登录标识',
                                  prefixIcon: Icon(
                                    Icons.alternate_email_rounded,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                              TextField(
                                controller: passwordController,
                                obscureText: obscure,
                                onSubmitted: (_) => submit(),
                                decoration: InputDecoration(
                                  labelText: '密码',
                                  prefixIcon: const Icon(Icons.key_rounded),
                                  suffixIcon: IconButton(
                                    onPressed: () =>
                                        setState(() => obscure = !obscure),
                                    icon: Icon(
                                      obscure
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                    ),
                                  ),
                                ),
                              ),
                              if (error != null) ...[
                                const SizedBox(height: 12),
                                Text(
                                  error!,
                                  style: const TextStyle(
                                    color: AppTheme.danger,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 20),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: submit,
                                  icon: const Icon(Icons.arrow_forward_rounded),
                                  label: const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 13),
                                    child: Text('进入工作区'),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: AppTheme.canvas,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: const Text(
                                  '演示账号\nowner@mdac.local / demo123\noperator1@mdac.local / demo123',
                                  style: TextStyle(
                                    color: AppTheme.muted,
                                    height: 1.5,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MdacShell extends StatefulWidget {
  const MdacShell({
    required this.repository,
    required this.userName,
    required this.role,
    required this.onSignOut,
    super.key,
  });

  final DemoRepository repository;
  final String userName;
  final UserRole role;
  final VoidCallback onSignOut;

  @override
  State<MdacShell> createState() => _MdacShellState();
}

class _MdacShellState extends State<MdacShell> {
  AppSection section = AppSection.overview;

  void open(AppSection target) => setState(() => section = target);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.repository,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 840;
            final content = _sectionContent();
            return Scaffold(
              body: wide
                  ? Row(
                      children: [
                        SideRail(
                          current: section,
                          onSelect: open,
                          userName: widget.userName,
                          role: widget.role,
                          onSignOut: widget.onSignOut,
                        ),
                        Expanded(child: content),
                      ],
                    )
                  : content,
              bottomNavigationBar: wide
                  ? null
                  : MobileNav(current: section, onSelect: open),
            );
          },
        );
      },
    );
  }

  Widget _sectionContent() {
    switch (section) {
      case AppSection.overview:
        return OverviewScreen(
          repository: widget.repository,
          userName: widget.userName,
          onNavigate: open,
        );
      case AppSection.customers:
        return CustomersScreen(
          repository: widget.repository,
          actor: widget.userName,
        );
      case AppSection.tasks:
        return TasksScreen(repository: widget.repository);
      case AppSection.settings:
        return SettingsScreen(
          repository: widget.repository,
          actor: widget.userName,
          role: widget.role,
          onSignOut: widget.onSignOut,
        );
    }
  }
}

class SideRail extends StatelessWidget {
  const SideRail({
    required this.current,
    required this.onSelect,
    required this.userName,
    required this.role,
    required this.onSignOut,
    super.key,
  });

  final AppSection current;
  final ValueChanged<AppSection> onSelect;
  final String userName;
  final UserRole role;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 248,
      color: AppTheme.deep,
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const BrandMark(inverted: true),
          const SizedBox(height: 44),
          const Text(
            'WORKSPACE',
            style: TextStyle(
              color: Color(0xFF8FB8B5),
              fontWeight: FontWeight.w700,
              fontSize: 11,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          RailItem(
            icon: Icons.grid_view_rounded,
            label: '总览',
            selected: current == AppSection.overview,
            onTap: () => onSelect(AppSection.overview),
          ),
          RailItem(
            icon: Icons.people_alt_outlined,
            label: '客户档案',
            selected: current == AppSection.customers,
            onTap: () => onSelect(AppSection.customers),
          ),
          RailItem(
            icon: Icons.layers_outlined,
            label: '任务队列',
            selected: current == AppSection.tasks,
            onTap: () => onSelect(AppSection.tasks),
          ),
          const SizedBox(height: 26),
          const Text(
            'SYSTEM',
            style: TextStyle(
              color: Color(0xFF8FB8B5),
              fontWeight: FontWeight.w700,
              fontSize: 11,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          RailItem(
            icon: Icons.tune_rounded,
            label: '系统设置',
            selected: current == AppSection.settings,
            onTap: () => onSelect(AppSection.settings),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const WorkerDot(),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Worker 在线',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        'fill-preview 0.1.0 · 只填写不提交',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: .55),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Avatar(name: userName, dark: true),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      userName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      roleLabel(role),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .55),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onSignOut,
                tooltip: '退出登录',
                color: Colors.white70,
                icon: const Icon(Icons.logout_rounded, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class MobileNav extends StatelessWidget {
  const MobileNav({required this.current, required this.onSelect, super.key});

  final AppSection current;
  final ValueChanged<AppSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final index = AppSection.values.indexOf(current);
    return NavigationBar(
      selectedIndex: index,
      onDestinationSelected: (value) => onSelect(AppSection.values[value]),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.grid_view_outlined),
          selectedIcon: Icon(Icons.grid_view_rounded),
          label: '总览',
        ),
        NavigationDestination(
          icon: Icon(Icons.people_outline),
          selectedIcon: Icon(Icons.people_alt_rounded),
          label: '客户',
        ),
        NavigationDestination(
          icon: Icon(Icons.layers_outlined),
          selectedIcon: Icon(Icons.layers_rounded),
          label: '任务',
        ),
        NavigationDestination(
          icon: Icon(Icons.tune_outlined),
          selectedIcon: Icon(Icons.tune_rounded),
          label: '设置',
        ),
      ],
    );
  }
}

class OverviewScreen extends StatelessWidget {
  const OverviewScreen({
    required this.repository,
    required this.userName,
    required this.onNavigate,
    super.key,
  });

  final DemoRepository repository;
  final String userName;
  final ValueChanged<AppSection> onNavigate;

  @override
  Widget build(BuildContext context) {
    final active = repository.activeCustomers;
    final pending = active
        .where((customer) => customer.businessStatus == 'PENDING')
        .length;
    final attention = active
        .where((customer) => customer.businessStatus == 'ACTION_REQUIRED')
        .length;
    final running = repository.tasks
        .where(
          (task) =>
              task.status == TaskStatus.queued ||
              task.status == TaskStatus.running,
        )
        .length;
    return AppPage(
      eyebrow: 'SATURDAY · 22 AUG 2026',
      title: '早上好，$userName',
      subtitle: '把今天的资料处理，拆成清晰而可追踪的下一步。',
      trailing: WorkerStatus(repository: repository),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final cardWidth = constraints.maxWidth < 680
                    ? constraints.maxWidth
                    : 210.0;
                return Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    StatCard(
                      width: cardWidth,
                      label: '活跃客户',
                      value: '${active.length}',
                      caption: '软删除记录不计入',
                      icon: Icons.people_alt_outlined,
                      tint: AppTheme.mint,
                    ),
                    StatCard(
                      width: cardWidth,
                      label: '待处理资料',
                      value: '$pending',
                      caption: '可以开始下一步',
                      icon: Icons.pending_actions_rounded,
                      tint: const Color(0xFFFFEBD8),
                    ),
                    StatCard(
                      width: cardWidth,
                      label: '运行中任务',
                      value: '$running',
                      caption: '手机与 Worker 已解耦',
                      icon: Icons.sync_rounded,
                      tint: const Color(0xFFE0EDF8),
                    ),
                    StatCard(
                      width: cardWidth,
                      label: '需要关注',
                      value: '$attention',
                      caption: '不确定结果不会伪装成功',
                      icon: Icons.error_outline_rounded,
                      tint: const Color(0xFFFFE2E0),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 28),
            LayoutBuilder(
              builder: (context, constraints) {
                final quickStart = SectionCard(
                  title: '快速开始',
                  actionLabel: '查看客户',
                  onAction: () => onNavigate(AppSection.customers),
                  child: Column(
                    children: [
                      QuickAction(
                        icon: Icons.document_scanner_outlined,
                        title: '导入护照并审核 OCR',
                        caption: '图片或多护照 PDF · 先确认再建档',
                        color: AppTheme.teal,
                        onTap: () => onNavigate(AppSection.customers),
                      ),
                      const Divider(height: 24),
                      QuickAction(
                        icon: Icons.flight_takeoff_outlined,
                        title: '启动 MDAC 批量注册',
                        caption: '选择客户 · 统一输入出入境日期',
                        color: AppTheme.orange,
                        onTap: () => onNavigate(AppSection.customers),
                      ),
                      const Divider(height: 24),
                      QuickAction(
                        icon: Icons.mark_email_read_outlined,
                        title: '获取 Gmail PIN',
                        caption: '未部署云端邮箱 Worker',

                        color: const Color(0xFF6B78D6),
                        onTap: () => onNavigate(AppSection.customers),
                      ),
                    ],
                  ),
                );
                final taskStatus = SectionCard(
                  title: '任务状态',
                  actionLabel: '打开队列',
                  onAction: () => onNavigate(AppSection.tasks),
                  child: Column(
                    children: repository.tasks
                        .take(3)
                        .map((task) => TaskMiniRow(task: task))
                        .toList(),
                  ),
                );
                if (constraints.maxWidth < 680) {
                  return Column(
                    children: [
                      quickStart,
                      const SizedBox(height: 18),
                      taskStatus,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 5, child: quickStart),
                    const SizedBox(width: 18),
                    Expanded(flex: 4, child: taskStatus),
                  ],
                );
              },
            ),
            const SizedBox(height: 28),
            LayoutBuilder(
              builder: (context, constraints) {
                final principles = [
                  Principle(
                    icon: Icons.fact_check_outlined,
                    title: '先审核',
                    body: 'OCR 结果必须经过人工确认，缺少字段或重复护照号时阻止建档。',
                  ),
                  Principle(
                    icon: Icons.lock_clock_outlined,
                    title: '可追溯',
                    body: '客户状态与任务状态分离，批次、逐项结果和审计动作都保留。',
                  ),
                  Principle(
                    icon: Icons.shield_outlined,
                    title: '不冒险',
                    body: 'fill-preview、失败和不确定结果不会写成真实成功。',
                  ),
                ];
                final content = constraints.maxWidth < 680
                    ? Column(
                        children: [
                          for (
                            var index = 0;
                            index < principles.length;
                            index++
                          ) ...[
                            principles[index],
                            if (index < principles.length - 1)
                              const SizedBox(height: 12),
                          ],
                        ],
                      )
                    : Row(
                        children: [
                          for (
                            var index = 0;
                            index < principles.length;
                            index++
                          ) ...[
                            Expanded(child: principles[index]),
                            if (index < principles.length - 1)
                              const SizedBox(width: 16),
                          ],
                        ],
                      );
                return SectionCard(title: '处理原则', child: content);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({
    required this.repository,
    required this.actor,
    super.key,
  });

  final DemoRepository repository;
  final String actor;

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  final searchController = TextEditingController();
  final selected = <String>{};
  String filter = '全部';

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  List<Customer> get filtered {
    final query = searchController.text.trim().toLowerCase();
    return widget.repository.activeCustomers.where((customer) {
      final matchesQuery =
          query.isEmpty ||
          customer.fullName.toLowerCase().contains(query) ||
          customer.passportNumber.toLowerCase().contains(query);
      final matchesFilter =
          filter == '全部' ||
          businessStatusLabel(customer.businessStatus) == filter;
      return matchesQuery && matchesFilter;
    }).toList();
  }

  void toggleAll(List<Customer> list) {
    setState(() {
      if (list.isNotEmpty &&
          list.every((customer) => selected.contains(customer.id))) {
        selected.removeAll(list.map((customer) => customer.id));
      } else {
        selected.addAll(list.map((customer) => customer.id));
      }
    });
  }

  Future<void> createManualCustomer() async {
    final values = await showCustomerForm(context);
    if (values == null || !mounted) return;
    final error = await widget.repository.createCustomerWithSync(
      values,
      widget.actor,
    );
    if (!mounted) return;
    if (error != null) {
      showToast(context, error, error: true);
    } else {
      showToast(context, '客户档案已创建并同步到 Supabase。');
    }
  }

  Future<void> editCustomer(Customer customer) async {
    final values = await showCustomerForm(context, customer: customer);
    if (values == null || !mounted) return;
    final error = await widget.repository.updateCustomerWithSync(
      customer,
      values,
      widget.actor,
    );
    if (!mounted) return;
    if (error != null) {
      showToast(context, error, error: true);
    } else {
      setState(() {});
      showToast(context, '客户档案已更新并同步到 Supabase。');
    }
  }

  Future<void> importDocument() async {
    if (widget.repository.remoteMode) {
      final error = await widget.repository.pickAndUploadDocument(widget.actor);
      if (!mounted || error == null) {
        if (mounted && error == null) {
          showToast(context, '文件已上传到私有 Storage，OCR 批次已建立。');
        }
        return;
      }
      showToast(context, error, error: true);
      return;
    }

    final choice = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('导入护照资料', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              const Text(
                '当前为演示模式，将生成可编辑的 OCR 识别草稿。',
                style: TextStyle(color: AppTheme.muted),
              ),
              const SizedBox(height: 18),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: AppTheme.mint,
                  child: Icon(Icons.image_outlined, color: AppTheme.teal),
                ),
                title: const Text('选择单张图片'),
                subtitle: const Text('JPG / PNG · 单个识别结果'),
                onTap: () => Navigator.pop(context, false),
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFFFEBD8),
                  child: Icon(
                    Icons.picture_as_pdf_outlined,
                    color: AppTheme.orange,
                  ),
                ),
                title: const Text('选择多护照 PDF'),
                subtitle: const Text('按页面产生多个识别结果并保留来源索引'),
                onTap: () => Navigator.pop(context, true),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    widget.repository.importDemoDocument(isPdf: choice);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('已进入 OCR 审核队列'),
        content: const Text('识别草稿已生成。请在“待审核 OCR”区域打开并确认字段后，才会创建正式客户档案。'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('查看草稿'),
          ),
        ],
      ),
    );
  }

  Future<void> startMdac() async {
    if (selected.isEmpty) {
      showToast(context, '请先选择客户。');
      return;
    }
    DateTime? entry;
    DateTime? exit;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('MDAC 批量注册'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已选择 ${selected.length} 位客户',
                  style: const TextStyle(color: AppTheme.muted),
                ),
                const SizedBox(height: 18),
                DateField(
                  label: '入境日期',
                  value: entry,
                  onTap: () async {
                    final date = await pickDate(context, entry);
                    if (date != null) setDialogState(() => entry = date);
                  },
                ),
                const SizedBox(height: 12),
                DateField(
                  label: '出境日期',
                  value: exit,
                  onTap: () async {
                    final date = await pickDate(context, exit ?? entry);
                    if (date != null) setDialogState(() => exit = date);
                  },
                ),
                const SizedBox(height: 14),
                const Text(
                  '任务建立后会保存日期快照；远程模式由 Railway Worker 真实填写但不提交。',
                  style: TextStyle(color: AppTheme.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: entry == null || exit == null
                  ? null
                  : () => Navigator.pop(context),
              child: const Text('确认并排队'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || entry == null || exit == null) return;
    final error = await widget.repository.createTaskAsync(
      type: TaskType.mdacRegistration,
      customerIds: selected.toList(),
      actor: widget.actor,
      entryDate: entry,
      exitDate: exit,
    );
    if (error != null) {
      showToast(context, error, error: true);
    } else {
      setState(() => selected.clear());
      showToast(context, 'MDAC 批次已排队，Worker 将在后台逐项执行。');
    }
  }

  Future<void> startSimpleTask(TaskType type) async {
    if (selected.isEmpty) {
      showToast(context, '请先选择客户。');
      return;
    }
    final error = await widget.repository.createTaskAsync(
      type: type,
      customerIds: selected.toList(),
      actor: widget.actor,
    );
    if (error != null) {
      showToast(context, error, error: true);
    } else {
      setState(() => selected.clear());
      showToast(context, '${taskTypeLabel(type)} 已排队。');
    }
  }

  Future<void> deleteSelected() async {
    if (selected.isEmpty) {
      showToast(context, '请先选择客户。');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认软删除？'),
        content: Text('将从默认客户列表隐藏 ${selected.length} 位客户。历史任务与审计记录会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await widget.repository.deleteCustomersWithSync(
      selected.toList(),
      widget.actor,
    );
    if (!mounted) return;
    if (result.error != null) {
      showToast(context, result.error!, error: true);
      return;
    }
    setState(() => selected.clear());
    showToast(
      context,
      result.blocked.isEmpty
          ? '客户已软删除并同步到 Supabase，历史记录仍然保留。'
          : '以下客户正在执行任务，未删除：${result.blocked.join('、')}',
      error: result.blocked.isNotEmpty,
    );
  }

  Future<void> exportSelected() async {
    if (selected.isEmpty) {
      showToast(context, '请先选择客户。');
      return;
    }
    final exportable = widget.repository.activeCustomers
        .where(
          (customer) =>
              selected.contains(customer.id) &&
              customer.fullName.isNotEmpty &&
              customer.passportNumber.isNotEmpty,
        )
        .toList();
    if (exportable.length != selected.length) {
      showToast(context, '部分客户缺少姓名或护照号码，已阻止导出。', error: true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出客户 Excel'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('将导出 ${exportable.length} 位客户。'),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.canvas,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  '工作表：Customers\n字段：姓名、护照号码\n文件：customers_YYYYMMDD_HHmm.xlsx',
                  style: TextStyle(color: AppTheme.muted, height: 1.6),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '演示版本将生成导出预览并记录审计日志；Android 文件保存/分享面板在真实存储接入后启用。',
                style: TextStyle(color: AppTheme.muted, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认导出'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      widget.repository.recordExport(
        exportable.map((customer) => customer.id).toList(),
        widget.actor,
      );
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导出预览已生成'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: exportable
                  .map(
                    (customer) => Row(
                      children: [
                        Expanded(child: Text(customer.fullName)),
                        Text(
                          customer.passportNumber,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppTheme.teal,
                          ),
                        ),
                      ],
                    ),
                  )
                  .toList(),
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = filtered;
    final compact = MediaQuery.sizeOf(context).width < 700;
    return AppPage(
      eyebrow: 'CUSTOMERS · ${widget.repository.activeCustomers.length} ACTIVE',
      title: '客户档案',
      subtitle: '所有 MDAC 必填字段在进入自动化前都需要完整且已确认。',
      trailing: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: createManualCustomer,
            icon: const Icon(Icons.edit_note_rounded),
            label: const Text('手动录入'),
          ),
          FilledButton.icon(
            onPressed: importDocument,
            icon: const Icon(Icons.add_rounded),
            label: const Text('导入护照'),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            if (widget.repository.ocrDrafts.isNotEmpty)
              OcrDraftSection(
                repository: widget.repository,
                actor: widget.actor,
              ),
            if (widget.repository.uploadRecords.isNotEmpty)
              UploadHistorySection(
                repository: widget.repository,
                actor: widget.actor,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 14),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final search = TextField(
                    controller: searchController,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: '搜索姓名或护照号码',
                      prefixIcon: Icon(Icons.search_rounded),
                      isDense: true,
                    ),
                  );
                  final filterMenu = PopupMenuButton<String>(
                    initialValue: filter,
                    onSelected: (value) => setState(() => filter = value),
                    itemBuilder: (context) =>
                        ['全部', '待处理', '已注册', '已收 PIN', '需关注']
                            .map(
                              (item) =>
                                  PopupMenuItem(value: item, child: Text(item)),
                            )
                            .toList(),
                    child: OutlinedButton.icon(
                      onPressed: null,
                      icon: const Icon(Icons.filter_list_rounded),
                      label: Text(filter),
                    ),
                  );
                  if (constraints.maxWidth < 560) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        search,
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: filterMenu,
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: search),
                      const SizedBox(width: 12),
                      filterMenu,
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: SectionCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    if (!compact)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                        decoration: const BoxDecoration(
                          color: Color(0xFFF9FBFA),
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(20),
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 30,
                              child: Checkbox(
                                value:
                                    list.isNotEmpty &&
                                    list.every(
                                      (customer) =>
                                          selected.contains(customer.id),
                                    ),
                                onChanged: (_) => toggleAll(list),
                              ),
                            ),
                            const Expanded(
                              flex: 3,
                              child: Text(
                                '客户',
                                style: TextStyle(
                                  color: AppTheme.muted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const Expanded(
                              flex: 2,
                              child: Text(
                                '护照号码',
                                style: TextStyle(
                                  color: AppTheme.muted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const Expanded(
                              flex: 2,
                              child: Text(
                                '业务状态',
                                style: TextStyle(
                                  color: AppTheme.muted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(
                              width: 100,
                              child: Text(
                                '创建时间',
                                style: TextStyle(
                                  color: AppTheme.muted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (list.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: EmptyState(
                          icon: Icons.people_outline_rounded,
                          title: '没有符合条件的客户',
                          body: '可以导入护照资料，或清除当前搜索条件。',
                        ),
                      )
                    else
                      ...list.map(
                        (customer) => CustomerRow(
                          customer: customer,
                          checked: selected.contains(customer.id),
                          onCheck: (value) => setState(
                            () => value == true
                                ? selected.add(customer.id)
                                : selected.remove(customer.id),
                          ),
                          onOpen: () => showCustomerDetail(
                            context,
                            customer,
                            onEdit: () => editCustomer(customer),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (selected.isNotEmpty)
              SelectionBar(
                count: selected.length,
                onMdac: startMdac,
                onPin: () => startSimpleTask(TaskType.gmailPin),
                onRegistration: () =>
                    startSimpleTask(TaskType.registrationCheck),
                onVisitPass: () => startSimpleTask(TaskType.visitPassCheck),
                onExport: exportSelected,
                onDelete: deleteSelected,
              ),
            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }
}

class UploadHistorySection extends StatelessWidget {
  const UploadHistorySection({
    required this.repository,
    required this.actor,
    super.key,
  });

  final DemoRepository repository;
  final String actor;

  String _statusLabel(UploadStatus status) {
    switch (status) {
      case UploadStatus.selecting:
        return '准备中';
      case UploadStatus.uploading:
        return '上传中';
      case UploadStatus.uploaded:
        return '已上传';
      case UploadStatus.failed:
        return '上传失败';
    }
  }

  String _sizeLabel(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).ceil()} KB';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 14),
      child: SectionCard(
        title: '上传批次 · ${repository.uploadRecords.length}',
        child: Column(
          children: repository.uploadRecords.map((record) {
            final statusColor = record.status == UploadStatus.failed
                ? AppTheme.danger
                : record.status == UploadStatus.uploaded
                ? AppTheme.teal
                : AppTheme.orange;
            return Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FBFA),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        record.isPdf
                            ? Icons.picture_as_pdf_outlined
                            : Icons.image_outlined,
                        color: statusColor,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          record.fileName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: AppTheme.ink,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _statusLabel(record.status),
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${record.isPdf ? 'PDF' : '图片'} · ${_sizeLabel(record.sizeBytes)}',
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                  ),
                  if (record.status == UploadStatus.uploading) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: LinearProgressIndicator(
                            value: record.progress,
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(6),
                            color: AppTheme.teal,
                            backgroundColor: AppTheme.mint,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text('${(record.progress * 100).round()}%'),
                      ],
                    ),
                  ],
                  if (record.status == UploadStatus.uploaded)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '已保存至私有 Storage · 批次 ${record.batchId ?? '待同步'}',
                        style: const TextStyle(
                          color: AppTheme.teal,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  if (record.status == UploadStatus.failed)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            record.errorMessage ?? '未知上传错误',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.danger,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: record.retryBytes == null
                              ? null
                              : () async {
                                  final error = await repository.retryUpload(
                                    record,
                                    actor,
                                  );
                                  if (error != null && context.mounted) {
                                    showToast(context, error, error: true);
                                  }
                                },
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class OcrDraftSection extends StatelessWidget {
  const OcrDraftSection({
    required this.repository,
    required this.actor,
    super.key,
  });

  final DemoRepository repository;
  final String actor;

  Future<void> review(BuildContext context, OcrDraft draft) async {
    final controllers = {
      'fullName': TextEditingController(text: draft.fullName),
      'passportNumber': TextEditingController(text: draft.passportNumber),
      'dateOfBirth': TextEditingController(text: draft.dateOfBirth),
      'placeOfBirth': TextEditingController(text: draft.placeOfBirth),
      'nationality': TextEditingController(text: draft.nationality),
      'passportExpiryDate': TextEditingController(
        text: draft.passportExpiryDate,
      ),
    };
    final formKey = GlobalKey<FormState>();
    String? selectedGender = customerGenderOptions.contains(draft.gender)
        ? draft.gender
        : null;

    Widget fieldBlock(String label, Widget field) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          field,
        ],
      ),
    );

    TextFormField textField(String key, String label) => TextFormField(
      controller: controllers[key],
      validator: (value) =>
          value == null || value.trim().isEmpty ? '请输入$label' : null,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
      ),
    );

    TextFormField dateField(String key) => TextFormField(
      controller: controllers[key],
      keyboardType: TextInputType.number,
      maxLength: 10,
      inputFormatters: [MdacDateInputFormatter()],
      validator: (value) =>
          isMdacDate(value?.trim() ?? '') ? null : '请输入有效日期，格式为 DD/MM/YYYY',
      decoration: const InputDecoration(
        hintText: '输入 8 位数字，自动加入 /',
        counterText: '',
        isDense: true,
        border: OutlineInputBorder(),
      ),
    );

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('人工确认 OCR 结果'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${draft.sourceLabel} · ${draft.sourceIndex}',
                      style: const TextStyle(
                        color: AppTheme.muted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ConfidenceBanner(confidence: draft.confidence),
                    const SizedBox(height: 16),
                    fieldBlock('姓名', textField('fullName', '姓名')),
                    fieldBlock('护照号码', textField('passportNumber', '护照号码')),
                    fieldBlock('出生日期（DD/MM/YYYY）', dateField('dateOfBirth')),
                    fieldBlock('出生地点', textField('placeOfBirth', '出生地点')),
                    fieldBlock('国籍代码', textField('nationality', '国籍代码')),
                    fieldBlock(
                      '性别',
                      DropdownButtonFormField<String>(
                        initialValue: selectedGender,
                        decoration: const InputDecoration(
                          hintText: '请选择性别',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        items: customerGenderOptions
                            .map(
                              (gender) => DropdownMenuItem(
                                value: gender,
                                child: Text(gender),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          setDialogState(() => selectedGender = value);
                        },
                        validator: (value) => value == null ? '请选择性别' : null,
                      ),
                    ),
                    fieldBlock(
                      '护照有效期（DD/MM/YYYY）',
                      dateField('passportExpiryDate'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (!(formKey.currentState?.validate() ?? false)) return;
                final values = controllers.map(
                  (key, controller) => MapEntry(key, controller.text),
                )..['gender'] = selectedGender ?? '';
                final error = await repository.confirmOcrWithSync(
                  draft,
                  values,
                  actor,
                );
                if (!dialogContext.mounted) return;
                if (error != null) {
                  showToast(dialogContext, error, error: true);
                } else {
                  Navigator.pop(dialogContext, true);
                }
              },
              child: const Text('确认并建档'),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 350));
    for (final controller in controllers.values) {
      controller.dispose();
    }
    if (result == true && context.mounted) {
      showToast(context, '已创建客户档案，初始状态为待处理。');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 14),
      child: SectionCard(
        title: '待审核 OCR · ${repository.ocrDrafts.length}',
        actionLabel: '规则说明',
        onAction: () =>
            showToast(context, '必填字段：姓名、出生日期、出生地点、国籍、性别、护照号、护照过期日期。'),
        child: Column(
          children: repository.ocrDrafts
              .map(
                (draft) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: draft.isLowConfidence
                              ? const Color(0xFFFFEBD8)
                              : AppTheme.mint,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          draft.sourceLabel.endsWith('.pdf')
                              ? Icons.picture_as_pdf_outlined
                              : Icons.image_outlined,
                          color: draft.isLowConfidence
                              ? AppTheme.orange
                              : AppTheme.teal,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              draft.fullName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: AppTheme.ink,
                              ),
                            ),
                            Text(
                              '${draft.passportNumber} · ${draft.sourceIndex}',
                              style: const TextStyle(
                                color: AppTheme.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ConfidencePill(value: draft.confidence),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: () => review(context, draft),
                        child: const Text('审核'),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class TasksScreen extends StatelessWidget {
  const TasksScreen({required this.repository, super.key});

  final DemoRepository repository;

  @override
  Widget build(BuildContext context) {
    return AppPage(
      eyebrow: 'AUTOMATION QUEUE · ${repository.tasks.length} BATCHES',
      title: '任务队列',
      subtitle: '手机负责创建任务，Worker 负责领取、逐项执行和写回结果。',
      trailing: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.end,
        children: [
          OutlinedButton.icon(
            onPressed: () async {
              final error = await repository.syncAutomationTasksFromSupabase();
              if (!context.mounted) return;
              if (error != null) {
                showToast(context, error, error: true);
              } else {
                showToast(context, '已刷新 Supabase MDAC 任务状态。');
              }
            },
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('刷新'),
          ),
          WorkerStatus(repository: repository),
        ],
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            WorkerBanner(repository: repository),
            const SizedBox(height: 20),
            SectionCard(
              title: '最近批次',
              child: Column(
                children: repository.tasks
                    .map((task) => TaskRow(task: task, repository: repository))
                    .toList(),
              ),
            ),
            const SizedBox(height: 20),
            SectionCard(
              title: '状态说明',
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  StatusLegend(label: '排队中', color: const Color(0xFFE0EDF8)),
                  StatusLegend(label: '执行中', color: const Color(0xFFFFEBD8)),
                  StatusLegend(label: '成功', color: AppTheme.mint),
                  StatusLegend(label: '部分成功', color: const Color(0xFFFFF3CE)),
                  StatusLegend(
                    label: '失败 / 待处理',
                    color: const Color(0xFFFFE2E0),
                  ),
                  StatusLegend(label: '待人工确认', color: const Color(0xFFECE6FA)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MdacSettingsEditor extends StatefulWidget {
  const MdacSettingsEditor({required this.repository, super.key});

  final DemoRepository repository;

  @override
  State<MdacSettingsEditor> createState() => _MdacSettingsEditorState();
}

class _MdacSettingsEditorState extends State<MdacSettingsEditor> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _regionController = TextEditingController();
  final _embarkController = TextEditingController();
  final _vesselController = TextEditingController();
  final _address1Controller = TextEditingController();
  final _address2Controller = TextEditingController();
  final _stateController = TextEditingController();
  final _cityController = TextEditingController();
  final _postcodeController = TextEditingController();

  String _travelMode = '2';
  String _accommodationStay = '02';
  String _pobMode = 'NATIONALITY';
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _applySettings(widget.repository.mdacSettings ?? MdacSettings.defaults());
    widget.repository.addListener(_onRepositoryChanged);
  }

  @override
  void dispose() {
    widget.repository.removeListener(_onRepositoryChanged);
    for (final controller in [
      _emailController,
      _phoneController,
      _regionController,
      _embarkController,
      _vesselController,
      _address1Controller,
      _address2Controller,
      _stateController,
      _cityController,
      _postcodeController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onRepositoryChanged() {
    if (!mounted) return;
    if (!_dirty && !_saving && widget.repository.mdacSettings != null) {
      _applySettings(widget.repository.mdacSettings!);
    }
    setState(() {});
  }

  void _applySettings(MdacSettings settings) {
    _emailController.text = settings.mdacEmail;
    _phoneController.text = settings.mdacPhone;
    _regionController.text = settings.regionCode;
    _embarkController.text = settings.embarkCountry;
    _vesselController.text = settings.vessel;
    _address1Controller.text = settings.address1;
    _address2Controller.text = settings.address2;
    _stateController.text = settings.stateCode;
    _cityController.text = settings.cityCode;
    _postcodeController.text = settings.postcode;
    _travelMode = settings.travelMode;
    _accommodationStay = settings.accommodationStay;
    _pobMode = settings.pobMode;
    _dirty = false;
  }

  void _markDirty(String _) {
    if (!_dirty) setState(() => _dirty = true);
  }

  String? _required(String? value, String label) {
    if (value == null || value.trim().isEmpty) return '$label不能为空';
    return null;
  }

  String? _email(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'MDAC 联系邮箱不能为空';
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(text)) {
      return '请输入有效的邮箱地址';
    }
    return null;
  }

  String? _code(String? value, String label, int length) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '$label不能为空';
    if (!RegExp('^[0-9]{${length}}\$').hasMatch(text)) {
      return '$label必须是 $length 位数字代码';
    }
    return null;
  }

  MdacSettings _settingsFromForm() => MdacSettings(
    mdacEmail: _emailController.text,
    mdacPhone: _phoneController.text,
    regionCode: _regionController.text,
    travelMode: _travelMode,
    embarkCountry: _embarkController.text,
    vessel: _vesselController.text,
    accommodationStay: _accommodationStay,
    address1: _address1Controller.text,
    address2: _address2Controller.text,
    stateCode: _stateController.text,
    cityCode: _cityController.text,
    postcode: _postcodeController.text,
    pobMode: _pobMode,
  );

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      showToast(context, '请先修正 MDAC 默认配置中的必填项。', error: true);
      return;
    }
    setState(() => _saving = true);
    final error = await widget.repository.saveMdacSettings(_settingsFromForm());
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (error == null) _dirty = false;
    });
    showToast(
      context,
      error ?? 'MDAC 默认配置已保存；之后新建的批次会使用这份配置快照。',
      error: error != null,
    );
  }

  Widget _textField({
    required String label,
    required TextEditingController controller,
    String? hint,
    String? Function(String?)? validator,
    TextInputType? keyboardType,
    int maxLines = 1,
    bool readOnly = false,
  }) {
    return TextFormField(
      controller: controller,
      readOnly: readOnly,
      keyboardType: keyboardType,
      maxLines: maxLines,
      onChanged: _markDirty,
      validator: validator,
      decoration: InputDecoration(labelText: label, hintText: hint),
    );
  }

  Widget _wideField(double width, Widget child) =>
      SizedBox(width: width, child: child);

  @override
  Widget build(BuildContext context) {
    final settings = widget.repository.mdacSettings ?? MdacSettings.defaults();
    return SectionCard(
      title: 'MDAC 默认业务配置',
      actionLabel: settings.isComplete ? '已配置' : '待完善',
      onAction: null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final oneColumn = constraints.maxWidth < 720;
          final fieldWidth = oneColumn
              ? constraints.maxWidth
              : (constraints.maxWidth - 16) / 2;
          return Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '这些是新 MDAC 批次使用的固定业务默认值，可在 App 修改。保存批次时会复制快照；已排队批次不会因之后修改设置而改变。',
                  style: TextStyle(
                    color: AppTheme.muted,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 16,
                  runSpacing: 12,
                  children: [
                    _wideField(
                      fieldWidth,
                      _textField(
                        label: 'MDAC 联系邮箱',
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        validator: _email,
                      ),
                    ),
                    _wideField(
                      fieldWidth,
                      _textField(
                        label: 'MDAC 手机号码',
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        validator: (value) => _required(value, 'MDAC 手机号码'),
                      ),
                    ),
                    _wideField(
                      fieldWidth,
                      _textField(
                        label: '地区代码（当前规则固定为 60）',
                        controller: _regionController,
                        keyboardType: TextInputType.number,
                        readOnly: true,
                        validator: (value) =>
                            value?.trim() == '60' ? null : '地区代码必须是 60',
                      ),
                    ),
                    _wideField(
                      fieldWidth,
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _travelMode,
                        decoration: const InputDecoration(labelText: '交通方式'),
                        items: const [
                          DropdownMenuItem(value: '1', child: Text('AIR · 空运')),
                          DropdownMenuItem(
                            value: '2',
                            child: Text('LAND · 陆路'),
                          ),
                          DropdownMenuItem(value: '3', child: Text('SEA · 海运')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _travelMode = value;
                              _dirty = true;
                            });
                          }
                        },
                        validator: (value) => value == null ? '请选择交通方式' : null,
                      ),
                    ),
                    _wideField(
                      fieldWidth,
                      _textField(
                        label: '最后出发国家（三字码）',
                        controller: _embarkController,
                        hint: '例如 CHN',
                        validator: (value) {
                          final text = value?.trim().toUpperCase() ?? '';
                          if (!RegExp(r'^[A-Z]{3}$').hasMatch(text)) {
                            return '请输入 3 位大写国家代码';
                          }
                          return null;
                        },
                      ),
                    ),
                    _wideField(
                      fieldWidth,
                      _textField(
                        label: '航班 / 车辆 / 船只编号',
                        controller: _vesselController,
                        validator: (value) => _required(value, '交通编号'),
                      ),
                    ),
                    _wideField(
                      fieldWidth,
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _accommodationStay,
                        decoration: const InputDecoration(labelText: '住宿类型'),
                        items: const [
                          DropdownMenuItem(
                            value: '01',
                            child: Text('HOTEL / MOTEL / REST HOUSE'),
                          ),
                          DropdownMenuItem(value: '02', child: Text('朋友或亲属住所')),
                          DropdownMenuItem(value: '99', child: Text('其他')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _accommodationStay = value;
                              _dirty = true;
                            });
                          }
                        },
                        validator: (value) => value == null ? '请选择住宿类型' : null,
                      ),
                    ),
                    _wideField(
                      fieldWidth,
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _pobMode,
                        decoration: const InputDecoration(
                          labelText: 'Place of Birth 映射',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'NATIONALITY',
                            child: Text('使用国籍代码（旧版规则）'),
                          ),
                          DropdownMenuItem(
                            value: 'CUSTOMER',
                            child: Text('使用客户出生地点'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _pobMode = value;
                              _dirty = true;
                            });
                          }
                        },
                        validator: (value) =>
                            value == null ? '请选择 POB 映射' : null,
                      ),
                    ),
                    _wideField(
                      fieldWidth,
                      _textField(
                        label: '马来西亚住宿地址第一行',
                        controller: _address1Controller,
                        validator: (value) => _required(value, '住宿地址第一行'),
                      ),
                    ),
                    _wideField(
                      fieldWidth,
                      _textField(
                        label: '马来西亚住宿地址第二行（可空）',
                        controller: _address2Controller,
                      ),
                    ),
                    _wideField(
                      fieldWidth,
                      _textField(
                        label: '马来西亚州代码',
                        controller: _stateController,
                        hint: '例如 14 = WP KUALA LUMPUR',
                        keyboardType: TextInputType.number,
                        validator: (value) => _code(value, '州代码', 2),
                      ),
                    ),
                    _wideField(
                      fieldWidth,
                      _textField(
                        label: '马来西亚城市代码',
                        controller: _cityController,
                        hint: '请使用官方下拉选项的 value',
                        keyboardType: TextInputType.number,
                        validator: (value) => _code(value, '城市代码', 4),
                      ),
                    ),
                    _wideField(
                      fieldWidth,
                      _textField(
                        label: '住宿邮编',
                        controller: _postcodeController,
                        keyboardType: TextInputType.number,
                        validator: (value) => _code(value, '邮编', 5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(_saving ? '保存中…' : '保存 MDAC 默认配置'),
                    ),
                    if (_dirty)
                      const Text(
                        '有未保存修改',
                        style: TextStyle(color: AppTheme.orange, fontSize: 12),
                      ),
                    if (widget.repository.remoteMode)
                      const Text(
                        '保存到 Supabase，并写入审计日志',
                        style: TextStyle(color: AppTheme.muted, fontSize: 12),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.repository,
    required this.actor,
    required this.role,
    required this.onSignOut,
    super.key,
  });

  final DemoRepository repository;
  final String actor;
  final UserRole role;
  final VoidCallback onSignOut;

  Future<void> createAccount(BuildContext context) async {
    final nameController = TextEditingController();
    UserRole selectedRole = UserRole.operator;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('创建演示账号'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '姓名',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<UserRole>(
                  initialValue: selectedRole,
                  decoration: const InputDecoration(labelText: '角色'),
                  items: UserRole.values
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(roleLabel(value)),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => selectedRole = value);
                  },
                ),
                const SizedBox(height: 12),
                const Text(
                  '真实版本将在受保护的服务端创建 Auth 用户，并要求首次登录修改临时密码。',
                  style: TextStyle(color: AppTheme.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true &&
        nameController.text.trim().isNotEmpty &&
        context.mounted) {
      repository.addAccount(nameController.text.trim(), selectedRole, actor);
      showToast(context, '演示账号创建记录已写入审计日志。');
    }
    nameController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auditWidgets = repository.auditEvents
        .take(8)
        .map(
          (event) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.receipt_long_outlined,
              color: AppTheme.muted,
              size: 20,
            ),
            title: Text(event, style: const TextStyle(fontSize: 13)),
            subtitle: const Text(
              '演示事件 · 由本地数据层记录',
              style: TextStyle(fontSize: 11, color: AppTheme.muted),
            ),
          ),
        )
        .toList();

    return AppPage(
      eyebrow: 'SYSTEM · SECURITY & INTEGRATIONS',
      title: '系统设置',
      subtitle: 'Supabase 与 Railway Worker 已接入；真实 MDAC 仍保持只填写、不提交。',

      trailing: OutlinedButton.icon(
        onPressed: onSignOut,
        icon: const Icon(Icons.logout_rounded),
        label: const Text('退出登录'),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionCard(
              title: '当前账号',
              child: Row(
                children: [
                  Avatar(name: actor),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          actor,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: AppTheme.ink,
                          ),
                        ),
                        Text(
                          roleLabel(role),
                          style: const TextStyle(color: AppTheme.muted),
                        ),
                      ],
                    ),
                  ),
                  Chip(
                    label: Text(role == UserRole.owner ? '可管理账号' : '业务操作权限'),
                    backgroundColor: role == UserRole.owner
                        ? AppTheme.mint
                        : const Color(0xFFE0EDF8),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            MdacSettingsEditor(repository: repository),
            const SizedBox(height: 18),
            SectionCard(
              title: '账号管理',
              actionLabel: role == UserRole.owner ? '创建演示账号' : null,
              onAction: role == UserRole.owner
                  ? () => createAccount(context)
                  : null,
              child: const SettingRow(
                icon: Icons.group_add_outlined,
                title: 'OWNER / OPERATOR 白名单',
                body: '首期仅允许登记账号登录；停用、审计和历史记录保留策略已在规格中定义。',
              ),
            ),
            const SizedBox(height: 18),
            SectionCard(
              title: '集成状态',
              child: Column(
                children: const [
                  IntegrationRow(
                    icon: Icons.storage_outlined,
                    title: '数据平台',
                    status: 'Supabase 已接入',
                    detail: 'Auth、PostgreSQL 与私有 Storage 已启用；服务端密钥不进入 APK。',
                  ),
                  IntegrationRow(
                    icon: Icons.document_scanner_outlined,
                    title: '护照 OCR',
                    status: 'Azure Worker Online',
                    detail: 'Azure Document Intelligence 已部署；端到端脱敏文件验收待完成。',
                  ),
                  IntegrationRow(
                    icon: Icons.computer_outlined,
                    title: '办公室 Worker',
                    status: 'fill-preview deployed',
                    detail: '真实 MDAC 页面只填写、回读和截图；禁止 Submit，遇挑战转人工审核。',
                  ),
                  IntegrationRow(
                    icon: Icons.mail_outline_rounded,
                    title: 'Gmail PIN',
                    status: 'IMAP boundary',
                    detail: '护照号优先匹配；凭证只存 Worker 本地安全配置',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            SectionCard(
              title: '安全提示',
              child: Column(
                children: const [
                  SettingRow(
                    icon: Icons.visibility_off_outlined,
                    title: '敏感字段最小化展示',
                    body: '正式版本应遮蔽护照号与 PIN，并使用短时限授权 URL 访问私有文件。',
                  ),
                  SettingRow(
                    icon: Icons.history_rounded,
                    title: '审计记录',
                    body: '导出、软删除、账号管理与任务创建都应写入 audit_logs.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            SectionCard(
              title: '最近审计动作',
              child: Column(children: auditWidgets),
            ),
          ],
        ),
      ),
    );
  }
}

class AppPage extends StatelessWidget {
  const AppPage({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.child,
    this.trailing,
    super.key,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.canvas,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final heading = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        eyebrow,
                        style: const TextStyle(
                          color: AppTheme.teal,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        title,
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                      const SizedBox(height: 7),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  );
                  if (trailing == null) return heading;
                  if (constraints.maxWidth < 640) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        heading,
                        const SizedBox(height: 16),
                        trailing!,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: heading),
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: trailing!,
                      ),
                    ],
                  );
                },
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.child,
    this.title,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.all(20),
    super.key,
  });

  final Widget child;
  final String? title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title!,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (actionLabel != null)
                    TextButton(onPressed: onAction, child: Text(actionLabel!)),
                ],
              ),
              const SizedBox(height: 16),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

class StatCard extends StatelessWidget {
  const StatCard({
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    required this.tint,
    this.width,
    super.key,
  });

  final String label;
  final String value;
  final String caption;
  final IconData icon;
  final Color tint;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width ?? 210,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: tint,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: AppTheme.ink, size: 20),
                  ),
                  const Spacer(),
                  const Icon(Icons.more_horiz_rounded, color: AppTheme.muted),
                ],
              ),
              const SizedBox(height: 18),
              Text(value, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 3),
              Text(
                label,
                style: const TextStyle(
                  color: AppTheme.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                caption,
                style: const TextStyle(color: AppTheme.muted, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class QuickAction extends StatelessWidget {
  const QuickAction({
    required this.icon,
    required this.title,
    required this.caption,
    required this.color,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String caption;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    caption,
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              color: AppTheme.muted,
              size: 15,
            ),
          ],
        ),
      ),
    );
  }
}

class Principle extends StatelessWidget {
  const Principle({
    required this.icon,
    required this.title,
    required this.body,
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.canvas,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppTheme.teal),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: AppTheme.ink,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            body,
            style: const TextStyle(
              color: AppTheme.muted,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class CustomerRow extends StatelessWidget {
  const CustomerRow({
    required this.customer,
    required this.checked,
    required this.onCheck,
    required this.onOpen,
    super.key,
  });

  final Customer customer;
  final bool checked;
  final ValueChanged<bool?> onCheck;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        return InkWell(
          onTap: onOpen,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 14 : 18,
              vertical: 14,
            ),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppTheme.line)),
            ),
            child: compact ? _buildCompact(context) : _buildWide(context),
          ),
        );
      },
    );
  }

  Widget _buildCompact(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 30,
          child: Checkbox(value: checked, onChanged: onCheck),
        ),
        const SizedBox(width: 8),
        Avatar(name: customer.fullName),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                customer.fullName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppTheme.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${customer.passportNumber} · ${customer.nationality} · ${customer.gender}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppTheme.muted, fontSize: 11),
              ),
              const SizedBox(height: 7),
              Text(
                '创建于 ${formatShortDate(customer.createdAt)} · ${customer.createdBy}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppTheme.muted, fontSize: 10),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            StatusPill(status: customer.businessStatus),
            const SizedBox(height: 8),
            const Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
          ],
        ),
      ],
    );
  }

  Widget _buildWide(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 30,
          child: Checkbox(value: checked, onChanged: onCheck),
        ),
        Expanded(
          flex: 3,
          child: Row(
            children: [
              Avatar(name: customer.fullName),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      customer.fullName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: AppTheme.ink,
                      ),
                    ),
                    Text(
                      '${customer.nationality} · ${customer.gender} · ${customer.createdBy}',
                      style: const TextStyle(
                        color: AppTheme.muted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 2,
          child: Text(
            customer.passportNumber,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppTheme.ink,
            ),
          ),
        ),
        Expanded(flex: 2, child: StatusPill(status: customer.businessStatus)),
        SizedBox(
          width: 100,
          child: Text(
            formatShortDate(customer.createdAt),
            style: const TextStyle(color: AppTheme.muted, fontSize: 12),
          ),
        ),
        const SizedBox(width: 10),
        const Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
      ],
    );
  }
}

class SelectionBar extends StatelessWidget {
  const SelectionBar({
    required this.count,
    required this.onMdac,
    required this.onPin,
    required this.onRegistration,
    required this.onVisitPass,
    required this.onExport,
    required this.onDelete,
    super.key,
  });

  final int count;
  final VoidCallback onMdac;
  final VoidCallback onPin;
  final VoidCallback onRegistration;
  final VoidCallback onVisitPass;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(28, 16, 28, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.deep,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppTheme.deep.withValues(alpha: .18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          Text(
            '已选 $count 位',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 6),
          ActionChip(
            avatar: const Icon(Icons.flight_takeoff_rounded, size: 16),
            label: const Text('MDAC 注册'),
            onPressed: onMdac,
          ),
          ActionChip(
            avatar: const Icon(Icons.mail_outline_rounded, size: 16),
            label: const Text('获取 PIN'),
            onPressed: onPin,
          ),
          ActionChip(
            avatar: const Icon(Icons.manage_search_rounded, size: 16),
            label: const Text('查 Registration'),
            onPressed: onRegistration,
          ),
          ActionChip(
            avatar: const Icon(Icons.badge_outlined, size: 16),
            label: const Text('查 Visit Pass'),
            onPressed: onVisitPass,
          ),
          ActionChip(
            avatar: const Icon(Icons.file_download_outlined, size: 16),
            label: const Text('导出 Excel'),
            onPressed: onExport,
          ),
          IconButton(
            onPressed: onDelete,
            tooltip: '软删除',
            color: Colors.white70,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
    );
  }
}

class TaskRow extends StatelessWidget {
  const TaskRow({required this.task, required this.repository, super.key});

  final AutomationTask task;
  final DemoRepository repository;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.line)),
          ),
          child: compact ? _buildCompact(context) : _buildWide(context),
        );
      },
    );
  }

  Widget _taskIcon() {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: taskTypeColor(task.type).withValues(alpha: .12),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Icon(taskTypeIcon(task.type), color: taskTypeColor(task.type)),
    );
  }

  Widget _progress() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          value: task.progress,
          minHeight: 5,
          borderRadius: BorderRadius.circular(6),
          backgroundColor: AppTheme.line,
          color: taskStatusColor(task.status),
        ),
        const SizedBox(height: 5),
        Text(
          '${task.completedCount}/${task.totalCount} 完成 · ${task.successCount} 成功 · ${task.failedCount} 失败',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppTheme.muted, fontSize: 10),
        ),
      ],
    );
  }

  Widget _buildCompact(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _taskIcon(),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                taskTypeLabel(task.type),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppTheme.ink,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${task.customerIds.length} 位客户 · ${formatDateTime(task.createdAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppTheme.muted, fontSize: 10),
              ),
              const SizedBox(height: 9),
              _progress(),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            TaskStatusPill(status: task.status),
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              onPressed: () => showTaskDetail(context, task, repository),
              icon: const Icon(
                Icons.open_in_new_rounded,
                size: 18,
                color: AppTheme.muted,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildWide(BuildContext context) {
    return Row(
      children: [
        _taskIcon(),
        const SizedBox(width: 12),
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                taskTypeLabel(task.type),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppTheme.ink,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${task.id} · ${task.customerIds.length} 位客户 · ${formatDateTime(task.createdAt)}',
                style: const TextStyle(color: AppTheme.muted, fontSize: 11),
              ),
            ],
          ),
        ),
        SizedBox(width: 155, child: _progress()),
        const SizedBox(width: 18),
        SizedBox(width: 92, child: TaskStatusPill(status: task.status)),
        const SizedBox(width: 10),
        IconButton(
          onPressed: () => showTaskDetail(context, task, repository),
          icon: const Icon(
            Icons.open_in_new_rounded,
            size: 18,
            color: AppTheme.muted,
          ),
        ),
      ],
    );
  }
}

class TaskMiniRow extends StatelessWidget {
  const TaskMiniRow({required this.task, super.key});
  final AutomationTask task;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: taskTypeColor(task.type).withValues(alpha: .12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              taskTypeIcon(task.type),
              size: 18,
              color: taskTypeColor(task.type),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  taskTypeLabel(task.type),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${task.completedCount}/${task.totalCount} 完成',
                  style: const TextStyle(color: AppTheme.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          TaskStatusPill(status: task.status),
        ],
      ),
    );
  }
}

class WorkerBanner extends StatelessWidget {
  const WorkerBanner({required this.repository, super.key});
  final DemoRepository repository;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.deep, Color(0xFF0A6267)],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.computer_rounded, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '办公室 Worker',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  repository.currentWorkerActivity,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .72),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const WorkerDot(light: true),
          const SizedBox(width: 8),
          const Text(
            'ONLINE',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 11,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class WorkerStatus extends StatelessWidget {
  const WorkerStatus({required this.repository, super.key});
  final DemoRepository repository;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const WorkerDot(),
          const SizedBox(width: 8),
          Text(
            repository.workerOnline ? 'Worker 在线' : 'Worker 离线',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppTheme.ink,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class IntegrationRow extends StatelessWidget {
  const IntegrationRow({
    required this.icon,
    required this.title,
    required this.status,
    required this.detail,
    super.key,
  });
  final IconData icon;
  final String title;
  final String status;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: AppTheme.canvas,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: AppTheme.teal, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: AppTheme.ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          Flexible(
            child: Text(
              status,
              textAlign: TextAlign.end,
              softWrap: true,
              style: const TextStyle(
                color: AppTheme.teal,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingRow extends StatelessWidget {
  const SettingRow({
    required this.icon,
    required this.title,
    required this.body,
    super.key,
  });
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(
            color: AppTheme.mint,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: AppTheme.teal, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppTheme.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                body,
                style: const TextStyle(
                  color: AppTheme.muted,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class Avatar extends StatelessWidget {
  const Avatar({required this.name, this.dark = false, super.key});
  final String name;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final initials = name.trim().isEmpty
        ? '?'
        : name
              .trim()
              .split(RegExp(r'\s+'))
              .map((part) => part[0])
              .take(2)
              .join()
              .toUpperCase();
    return CircleAvatar(
      radius: 18,
      backgroundColor: dark
          ? Colors.white.withValues(alpha: .16)
          : AppTheme.mint,
      child: Text(
        initials,
        style: TextStyle(
          color: dark ? Colors.white : AppTheme.teal,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      ),
    );
  }
}

class BrandMark extends StatelessWidget {
  const BrandMark({this.inverted = false, super.key});
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    final foreground = inverted ? Colors.white : AppTheme.deep;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: AppTheme.orange,
            borderRadius: BorderRadius.circular(11),
          ),
          child: const Icon(
            Icons.flight_rounded,
            color: AppTheme.deep,
            size: 19,
          ),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MDAC',
              style: TextStyle(
                color: foreground,
                fontWeight: FontWeight.w900,
                fontSize: 17,
                letterSpacing: 1.5,
              ),
            ),
            Text(
              'DESK',
              style: TextStyle(
                color: inverted ? Colors.white70 : AppTheme.muted,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 2.4,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class RailItem extends StatelessWidget {
  const RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: selected
            ? Colors.white.withValues(alpha: .12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(13),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: selected ? AppTheme.orange : Colors.white70,
                  size: 19,
                ),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.white70,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WorkerDot extends StatelessWidget {
  const WorkerDot({this.light = false, super.key});
  final bool light;
  @override
  Widget build(BuildContext context) => Container(
    width: 9,
    height: 9,
    decoration: BoxDecoration(
      color: light ? const Color(0xFF8CE3B5) : const Color(0xFF35B778),
      shape: BoxShape.circle,
      boxShadow: [
        BoxShadow(
          color: (light ? const Color(0xFF8CE3B5) : const Color(0xFF35B778))
              .withValues(alpha: .4),
          blurRadius: 5,
        ),
      ],
    ),
  );
}

class ConfidenceBanner extends StatelessWidget {
  const ConfidenceBanner({required this.confidence, super.key});
  final double confidence;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: confidence < .9 ? const Color(0xFFFFF3CE) : AppTheme.mint,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Icon(
          confidence < .9
              ? Icons.warning_amber_rounded
              : Icons.check_circle_outline_rounded,
          color: confidence < .9 ? AppTheme.warning : AppTheme.teal,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            confidence < .9 ? '置信度偏低，请重点核对字段。' : '识别置信度良好，仍需人工确认后建档。',
            style: const TextStyle(fontSize: 12, color: AppTheme.ink),
          ),
        ),
        Text(
          '${(confidence * 100).round()}%',
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            color: AppTheme.ink,
          ),
        ),
      ],
    ),
  );
}

class ConfidencePill extends StatelessWidget {
  const ConfidencePill({required this.value, super.key});
  final double value;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: value < .9 ? const Color(0xFFFFF3CE) : AppTheme.mint,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      '${(value * 100).round()}%',
      style: TextStyle(
        color: value < .9 ? AppTheme.warning : AppTheme.teal,
        fontWeight: FontWeight.w800,
        fontSize: 11,
      ),
    ),
  );
}

class StatusPill extends StatelessWidget {
  const StatusPill({required this.status, super.key});
  final String status;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: statusColor(status),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      businessStatusLabel(status),
      style: TextStyle(
        color: statusTextColor(status),
        fontWeight: FontWeight.w800,
        fontSize: 10,
      ),
      overflow: TextOverflow.ellipsis,
    ),
  );
}

class TaskStatusPill extends StatelessWidget {
  const TaskStatusPill({required this.status, super.key});
  final TaskStatus status;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: BoxDecoration(
      color: taskStatusColor(status).withValues(alpha: .13),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      taskStatusLabel(status),
      style: TextStyle(
        color: taskStatusColor(status),
        fontWeight: FontWeight.w800,
        fontSize: 10,
      ),
    ),
  );
}

class StatusLegend extends StatelessWidget {
  const StatusLegend({required this.label, required this.color, super.key});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: const TextStyle(
        fontWeight: FontWeight.w700,
        color: AppTheme.ink,
        fontSize: 11,
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.body,
    super.key,
  });
  final IconData icon;
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Icon(icon, color: AppTheme.muted, size: 34),
      const SizedBox(height: 10),
      Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          color: AppTheme.ink,
        ),
      ),
      const SizedBox(height: 5),
      Text(body, style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
    ],
  );
}

class DateField extends StatelessWidget {
  const DateField({
    required this.label,
    required this.value,
    required this.onTap,
    super.key,
  });
  final String label;
  final DateTime? value;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.calendar_today_outlined),
      ),
      child: Text(
        value == null ? '选择日期' : formatDate(value!),
        style: TextStyle(
          color: value == null ? AppTheme.muted : AppTheme.ink,
          fontWeight: value == null ? FontWeight.normal : FontWeight.w700,
        ),
      ),
    ),
  );
}

class LoginFeature extends StatelessWidget {
  const LoginFeature({
    required this.icon,
    required this.title,
    required this.caption,
    super.key,
  });
  final IconData icon;
  final String title;
  final String caption;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      children: [
        Icon(icon, color: AppTheme.orange, size: 21),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              caption,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ],
        ),
      ],
    ),
  );
}

class MdacDateInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final limited = digits.length > 8 ? digits.substring(0, 8) : digits;
    final formatted = StringBuffer();
    for (var index = 0; index < limited.length; index++) {
      if (index == 2 || index == 4) formatted.write('/');
      formatted.write(limited[index]);
    }
    final text = formatted.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: TextRange.empty,
    );
  }
}

bool isMdacDate(String value) {
  final match = RegExp(r'^(\d{2})/(\d{2})/(\d{4})$').firstMatch(value);
  if (match == null) return false;
  final day = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final year = int.parse(match.group(3)!);
  final date = DateTime(year, month, day);
  return date.year == year && date.month == month && date.day == day;
}

Future<DateTime?> pickDate(BuildContext context, DateTime? initial) =>
    showDatePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 730)),
      initialDate: initial ?? DateTime.now(),
      helpText: '选择日期',
      cancelText: '取消',
      confirmText: '确定',
    );

Future<Map<String, String>?> showCustomerForm(
  BuildContext context, {
  Customer? customer,
}) async {
  final editing = customer != null;
  final controllers = <String, TextEditingController>{
    'fullName': TextEditingController(text: customer?.fullName ?? ''),
    'passportNumber': TextEditingController(
      text: customer?.passportNumber ?? '',
    ),
    'dateOfBirth': TextEditingController(text: customer?.dateOfBirth ?? ''),
    'placeOfBirth': TextEditingController(text: customer?.placeOfBirth ?? ''),
    'nationality': TextEditingController(text: customer?.nationality ?? ''),
    'passportExpiryDate': TextEditingController(
      text: customer?.passportExpiryDate ?? '',
    ),
    'pin': TextEditingController(text: customer?.pin ?? ''),
  };
  final formKey = GlobalKey<FormState>();
  String? selectedGender =
      customer?.gender.isNotEmpty == true &&
          customerGenderOptions.contains(customer!.gender)
      ? customer.gender
      : null;
  String selectedBusinessStatus =
      customer?.businessStatus != null &&
          customerBusinessStatusOptions.contains(customer!.businessStatus)
      ? customer.businessStatus
      : 'PENDING';

  TextFormField textField(
    String key, {
    required String label,
    String? hintText,
    TextInputType? keyboardType,
  }) => TextFormField(
    controller: controllers[key],
    keyboardType: keyboardType,
    validator: (value) =>
        value == null || value.trim().isEmpty ? '请输入$label' : null,
    decoration: InputDecoration(
      labelText: label,
      hintText: hintText,
      isDense: true,
    ),
  );

  TextFormField dateField(String key, String label) => TextFormField(
    controller: controllers[key],
    keyboardType: TextInputType.number,
    maxLength: 10,
    inputFormatters: [MdacDateInputFormatter()],
    validator: (value) =>
        isMdacDate(value?.trim() ?? '') ? null : '请输入有效日期，格式为 DD/MM/YYYY',
    decoration: InputDecoration(
      labelText: label,
      hintText: '输入 8 位数字，系统自动加入 / 符号',
      counterText: '',
      isDense: true,
    ),
  );

  final result = await showModalBottomSheet<Map<String, String>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final bottomInset = MediaQuery.viewInsetsOf(sheetContext).bottom;
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(22, 0, 22, 26 + bottomInset),
          child: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    editing ? '编辑客户档案' : '手动录入护照',
                    style: Theme.of(sheetContext).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    editing ? '修改后会保留审计记录；业务状态可以手动调整。' : '所有字段会先校验，业务状态可以手动选择。',
                    style: const TextStyle(color: AppTheme.muted),
                  ),
                  const SizedBox(height: 18),
                  textField('fullName', label: '姓名'),
                  const SizedBox(height: 11),
                  textField('passportNumber', label: '护照号码'),
                  const SizedBox(height: 11),
                  dateField('dateOfBirth', '出生日期（DD/MM/YYYY）'),
                  const SizedBox(height: 11),
                  textField('placeOfBirth', label: '出生地点'),
                  const SizedBox(height: 11),
                  textField('nationality', label: '国籍代码'),
                  const SizedBox(height: 11),
                  DropdownButtonFormField<String>(
                    initialValue: selectedGender,
                    decoration: const InputDecoration(
                      labelText: '性别',
                      isDense: true,
                    ),
                    items: customerGenderOptions
                        .map(
                          (gender) => DropdownMenuItem(
                            value: gender,
                            child: Text(gender),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => selectedGender = value,
                    validator: (value) => value == null ? '请选择性别' : null,
                  ),
                  const SizedBox(height: 11),
                  dateField('passportExpiryDate', '护照有效期（DD/MM/YYYY）'),
                  const SizedBox(height: 11),
                  DropdownButtonFormField<String>(
                    initialValue: selectedBusinessStatus,
                    decoration: const InputDecoration(
                      labelText: '业务状态',
                      isDense: true,
                    ),
                    items: customerBusinessStatusOptions
                        .map(
                          (status) => DropdownMenuItem(
                            value: status,
                            child: Text(businessStatusLabel(status)),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) selectedBusinessStatus = value;
                    },
                  ),
                  const SizedBox(height: 11),
                  textField(
                    'pin',
                    label: 'Gmail PIN（可留空）',
                    hintText: '保留 PIN 中间空格，首尾空格会自动清除',
                    keyboardType: TextInputType.visiblePassword,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () {
                          if (!formKey.currentState!.validate()) return;
                          Navigator.pop(sheetContext, {
                            for (final entry in controllers.entries)
                              entry.key: entry.value.text,
                            'gender': selectedGender ?? '',
                            'businessStatus': selectedBusinessStatus,
                          });
                        },
                        child: Text(editing ? '保存修改' : '创建客户'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  // Flutter may still perform one final rebuild while the bottom-sheet
  // dismissal animation is completing. Dispose controllers only after that
  // route has fully left the tree, otherwise TextFormField can retain a
  // listener briefly and trigger framework deactivation assertions.
  await Future<void>.delayed(const Duration(milliseconds: 400));
  for (final controller in controllers.values) {
    controller.dispose();
  }
  return result;
}

Future<void> showCustomerDetail(
  BuildContext context,
  Customer customer, {
  VoidCallback? onEdit,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 26),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Avatar(name: customer.fullName),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          customer.fullName,
                          style: Theme.of(sheetContext).textTheme.titleLarge,
                        ),
                        Text(
                          customer.passportNumber,
                          style: const TextStyle(color: AppTheme.muted),
                        ),
                      ],
                    ),
                  ),
                  StatusPill(status: customer.businessStatus),
                ],
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  DetailChip(label: '出生日期', value: customer.dateOfBirth),
                  DetailChip(label: '出生地点', value: customer.placeOfBirth),
                  DetailChip(label: '国籍', value: customer.nationality),
                  DetailChip(label: '性别', value: customer.gender),
                  DetailChip(
                    label: '护照有效期',
                    value: customer.passportExpiryDate,
                  ),
                  DetailChip(label: 'Gmail PIN', value: customer.pin ?? '未获取'),
                ],
              ),
              if (customer.lastSummary != null) ...[
                const SizedBox(height: 18),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: AppTheme.canvas,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    customer.lastSummary!,
                    style: const TextStyle(color: AppTheme.muted, height: 1.4),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Text(
                '创建于 ${formatDateTime(customer.createdAt)} · ${customer.createdBy}',
                style: const TextStyle(color: AppTheme.muted, fontSize: 12),
              ),
              if (onEdit != null) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      onEdit();
                    },
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('编辑档案'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class DetailChip extends StatelessWidget {
  const DetailChip({required this.label, required this.value, super.key});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
    decoration: BoxDecoration(
      color: AppTheme.canvas,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: AppTheme.muted, fontSize: 10),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(
            color: AppTheme.ink,
            fontWeight: FontWeight.w800,
            fontSize: 12,
          ),
        ),
      ],
    ),
  );
}

Future<void> showTaskDetail(
  BuildContext context,
  AutomationTask task,
  DemoRepository repository,
) async {
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(
        children: [
          Icon(taskTypeIcon(task.type), color: taskTypeColor(task.type)),
          const SizedBox(width: 10),
          Expanded(child: Text(taskTypeLabel(task.type))),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              task.id,
              style: const TextStyle(color: AppTheme.muted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('批次状态', style: TextStyle(color: AppTheme.muted)),
                TaskStatusPill(status: task.status),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: task.progress,
              minHeight: 7,
              borderRadius: BorderRadius.circular(8),
              color: taskStatusColor(task.status),
            ),
            const SizedBox(height: 10),
            Text(
              '${task.completedCount}/${task.totalCount} 完成 · ${task.successCount} 成功 · ${task.failedCount} 失败',
            ),
            const SizedBox(height: 14),
            Text(
              task.note,
              style: const TextStyle(color: AppTheme.muted, height: 1.4),
            ),
            if (task.entryDate != null) ...[
              const SizedBox(height: 14),
              Text(
                '日期快照：${formatDate(task.entryDate!)} → ${formatDate(task.exitDate!)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.ink,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

void showToast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      backgroundColor: error ? AppTheme.danger : AppTheme.deep,
      content: Text(message),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

String fieldLabel(String key) {
  const labels = {
    'fullName': '姓名',
    'passportNumber': '护照号码',
    'dateOfBirth': '出生日期',
    'placeOfBirth': '出生地点',
    'nationality': '国籍',
    'gender': '性别',
    'passportExpiryDate': '护照过期日期',
    'businessStatus': '业务状态',
  };
  return labels[key] ?? key;
}

String roleLabel(UserRole role) =>
    role == UserRole.owner ? 'OWNER' : 'OPERATOR';

String businessStatusLabel(String value) {
  const labels = {
    'PENDING': '待处理',
    'MDAC_REGISTERING': '注册中',
    'MDAC_REGISTERED': '已注册',
    'PIN_PENDING': 'PIN 待获取',
    'PIN_RECEIVED': '已收 PIN',
    'REGISTRATION_CHECKED': 'Registration 已查',
    'VISIT_PASS_CHECKED': 'Visit Pass 已查',
    'ACTION_REQUIRED': '需关注',
    'ARCHIVED': '已归档',
  };
  return labels[value] ?? value;
}

Color statusColor(String value) {
  if (value == 'MDAC_REGISTERED' ||
      value == 'PIN_RECEIVED' ||
      value == 'REGISTRATION_CHECKED' ||
      value == 'VISIT_PASS_CHECKED') {
    return AppTheme.mint;
  }
  if (value == 'ACTION_REQUIRED') {
    return const Color(0xFFFFE2E0);
  }
  if (value == 'MDAC_REGISTERING') {
    return const Color(0xFFFFEBD8);
  }
  return const Color(0xFFE0EDF8);
}

Color statusTextColor(String value) =>
    value == 'ACTION_REQUIRED' ? AppTheme.danger : AppTheme.ink;

String taskTypeLabel(TaskType type) {
  switch (type) {
    case TaskType.mdacRegistration:
      return 'MDAC 批量注册';
    case TaskType.gmailPin:
      return 'Gmail PIN 获取';
    case TaskType.registrationCheck:
      return 'Check Registration';
    case TaskType.visitPassCheck:
      return 'Check Visit Pass';
  }
}

IconData taskTypeIcon(TaskType type) {
  switch (type) {
    case TaskType.mdacRegistration:
      return Icons.flight_takeoff_rounded;
    case TaskType.gmailPin:
      return Icons.mark_email_read_outlined;
    case TaskType.registrationCheck:
      return Icons.manage_search_rounded;
    case TaskType.visitPassCheck:
      return Icons.badge_outlined;
  }
}

Color taskTypeColor(TaskType type) {
  switch (type) {
    case TaskType.mdacRegistration:
      return AppTheme.orange;
    case TaskType.gmailPin:
      return const Color(0xFF6B78D6);
    case TaskType.registrationCheck:
      return AppTheme.teal;
    case TaskType.visitPassCheck:
      return const Color(0xFF6D8EAC);
  }
}

String taskStatusLabel(TaskStatus status) {
  switch (status) {
    case TaskStatus.queued:
      return '排队中';
    case TaskStatus.running:
      return '执行中';
    case TaskStatus.succeeded:
      return '已完成';
    case TaskStatus.partialSuccess:
      return '部分成功';
    case TaskStatus.failed:
      return '失败';
    case TaskStatus.needsReview:
      return '待确认';
  }
}

Color taskStatusColor(TaskStatus status) {
  switch (status) {
    case TaskStatus.queued:
      return const Color(0xFF5D85AD);
    case TaskStatus.running:
      return AppTheme.orange;
    case TaskStatus.succeeded:
      return AppTheme.teal;
    case TaskStatus.partialSuccess:
      return AppTheme.warning;
    case TaskStatus.failed:
      return AppTheme.danger;
    case TaskStatus.needsReview:
      return const Color(0xFF7B67AF);
  }
}

String formatDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

String formatShortDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}';

String formatDateTime(DateTime date) =>
    '${formatDate(date)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
