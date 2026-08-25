import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseGateway {
  SupabaseGateway._();

  static SupabaseClient? _client;

  static const projectUrl = String.fromEnvironment('SUPABASE_URL');
  static const publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  static bool get isConfigured =>
      projectUrl.isNotEmpty && publishableKey.isNotEmpty;

  static SupabaseClient? get client => _client;
  static String? get currentUserId => _client?.auth.currentUser?.id;

  static Future<void> initialize() async {
    if (!isConfigured) return;
    await Supabase.initialize(url: projectUrl, publishableKey: publishableKey);
    _client = Supabase.instance.client;
  }

  static Future<({String name, String role})> signIn({
    required String email,
    required String password,
  }) async {
    final client = _client;
    if (client == null) {
      throw const AuthException('Supabase 尚未配置。');
    }

    final response = await client.auth.signInWithPassword(
      email: email,
      password: password,
    );
    final user = response.user;
    if (user == null) {
      throw const AuthException('登录未返回用户资料。');
    }

    final profile = await client
        .from('profiles')
        .select('name, role, is_active, deleted_at')
        .eq('id', user.id)
        .maybeSingle();
    if (profile == null || profile['is_active'] != true) {
      await client.auth.signOut();
      throw const AuthException('账号尚未配置为可用的 MDAC Desk 用户。');
    }
    if (profile['deleted_at'] != null) {
      await client.auth.signOut();
      throw const AuthException('账号已停用。');
    }

    return (
      name: (profile['name'] as String?)?.trim().isNotEmpty == true
          ? profile['name'] as String
          : (user.email ?? email).split('@').first,
      role: (profile['role'] as String?) ?? 'OPERATOR',
    );
  }

  static Future<void> signOut() async {
    await _client?.auth.signOut();
  }

  static Future<({String name, String role})?> restoreSession() async {
    final client = _client;
    final user = client?.auth.currentUser;
    if (client == null || user == null) return null;
    final profile = await client
        .from('profiles')
        .select('name, role, is_active, deleted_at')
        .eq('id', user.id)
        .maybeSingle();
    if (profile == null ||
        profile['is_active'] != true ||
        profile['deleted_at'] != null) {
      await client.auth.signOut();
      return null;
    }
    return (
      name: (profile['name'] as String?)?.trim().isNotEmpty == true
          ? profile['name'] as String
          : (user.email ?? '').split('@').first,
      role: (profile['role'] as String?) ?? 'OPERATOR',
    );
  }

  static Future<List<Map<String, dynamic>>> fetchOcrBatches() async {
    final rows = await _requiredClient
        .from('ocr_batches')
        .select(
          'id, source_type, file_path, status, total_results, '
          'processed_results, error_message, metadata, created_at, updated_at',
        )
        .order('created_at', ascending: false)
        .limit(100);
    return rows
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  static Future<List<Map<String, dynamic>>> fetchOcrResults() async {
    final rows = await _requiredClient
        .from('ocr_results')
        .select(
          'id, batch_id, page_index, segment_index, raw_result, '
          'extracted_data, confidence, status, error_message, '
          'created_customer_id, created_at, updated_at',
        )
        .order('created_at', ascending: false)
        .limit(200);
    return rows
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  static Future<void> markOcrResultCreated({
    required String resultId,
    required String customerId,
    required Map<String, dynamic> extractedData,
  }) async {
    await _requiredClient
        .from('ocr_results')
        .update({
          'status': 'CREATED',
          'created_customer_id': customerId,
          'reviewed_by': _requiredUserId,
          'reviewed_at': DateTime.now().toUtc().toIso8601String(),
          'extracted_data': extractedData,
        })
        .eq('id', resultId);
  }

  static Future<Map<String, dynamic>> uploadOcrBatch({
    required Uint8List bytes,
    required String fileName,
    required bool isPdf,
    required String contentHash,
  }) async {
    final client = _requiredClient;
    final userId = _requiredUserId;
    final safeName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final extension = isPdf ? 'pdf' : 'jpg';
    final path =
        '$userId/ocr/${DateTime.now().toUtc().millisecondsSinceEpoch}_$safeName';
    final contentType = isPdf
        ? 'application/pdf'
        : safeName.toLowerCase().endsWith('.png')
        ? 'image/png'
        : 'image/jpeg';

    await client.storage
        .from('passport-documents')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: false),
        );
    try {
      final row = await client
          .from('ocr_batches')
          .insert({
            'uploaded_by': userId,
            'source_type': isPdf ? 'PDF' : 'IMAGE',
            'file_path': path,
            'status': 'UPLOADED',
            'total_results': isPdf ? 0 : 1,
            'processed_results': 0,
            'metadata': {
              'original_file_name': fileName,
              'size_bytes': bytes.length,
              'content_hash': contentHash,
              'mime_type': contentType,
            },
          })
          .select(
            'id, source_type, file_path, status, total_results, '
            'processed_results, error_message, metadata, created_at, updated_at',
          )
          .single();
      return {
        ...Map<String, dynamic>.from(row),
        'original_file_name': fileName,
        'size_bytes': bytes.length,
        'extension': extension,
      };
    } catch (_) {
      await client.storage.from('passport-documents').remove([path]);
      rethrow;
    }
  }

  static Future<List<Map<String, dynamic>>> fetchCustomers() async {
    final client = _requiredClient;
    final rows = await client
        .from('customers')
        .select(
          'id, full_name, date_of_birth, place_of_birth, passport_number, '
          'nationality, gender, passport_expiry_date, business_status, '
          'created_by, created_at, deleted_at',
        )
        .isFilter('deleted_at', null)
        .order('created_at', ascending: false)
        .limit(200);
    final pins = await client
        .from('email_pin_records')
        .select('customer_id, pin_value, status, received_at, created_at')
        .order('created_at', ascending: false)
        .limit(500);
    final profiles = await client
        .from('profiles')
        .select('id, name')
        .limit(200);

    final latestPins = <String, Map<String, dynamic>>{};
    for (final pin in pins) {
      final customerId = pin['customer_id'] as String?;
      if (customerId != null && !latestPins.containsKey(customerId)) {
        latestPins[customerId] = Map<String, dynamic>.from(pin);
      }
    }
    final names = <String, String>{
      for (final profile in profiles)
        if (profile['id'] != null && profile['name'] != null)
          profile['id'] as String: profile['name'] as String,
    };

    return [
      for (final row in rows)
        {
          ...Map<String, dynamic>.from(row),
          'created_by_name': names[row['created_by']] ?? row['created_by'],
          'pin_record': latestPins[row['id']],
        },
    ];
  }

  static Future<Map<String, dynamic>> insertCustomer({
    required String fullName,
    required String passportNumber,
    required String dateOfBirth,
    required String placeOfBirth,
    required String nationality,
    required String gender,
    required String passportExpiryDate,
    String businessStatus = 'PENDING',
  }) async {
    final client = _requiredClient;
    final userId = _requiredUserId;
    final row = await client
        .from('customers')
        .insert({
          'full_name': fullName.trim().toUpperCase(),
          'passport_number': passportNumber.trim().toUpperCase(),
          'date_of_birth': _toIsoDate(dateOfBirth),
          'place_of_birth': placeOfBirth.trim().toUpperCase(),
          'nationality': nationality.trim().toUpperCase(),
          'gender': gender.trim(),
          'passport_expiry_date': _toIsoDate(passportExpiryDate),
          'business_status': businessStatus,
          'created_by': userId,
        })
        .select(
          'id, full_name, date_of_birth, place_of_birth, passport_number, '
          'nationality, gender, passport_expiry_date, business_status, '
          'created_by, created_at, deleted_at',
        )
        .single();
    return Map<String, dynamic>.from(row);
  }

  static Future<Map<String, dynamic>> updateCustomer({
    required String id,
    required String fullName,
    required String passportNumber,
    required String dateOfBirth,
    required String placeOfBirth,
    required String nationality,
    required String gender,
    required String passportExpiryDate,
    String? businessStatus,
  }) async {
    final client = _requiredClient;
    final userId = _requiredUserId;
    final payload = <String, dynamic>{
      'full_name': fullName.trim().toUpperCase(),
      'passport_number': passportNumber.trim().toUpperCase(),
      'date_of_birth': _toIsoDate(dateOfBirth),
      'place_of_birth': placeOfBirth.trim().toUpperCase(),
      'nationality': nationality.trim().toUpperCase(),
      'gender': gender.trim(),
      'passport_expiry_date': _toIsoDate(passportExpiryDate),
      'updated_by': userId,
    };
    if (businessStatus != null) {
      payload['business_status'] = businessStatus;
    }
    final row = await client
        .from('customers')
        .update(payload)
        .eq('id', id)
        .select(
          'id, full_name, date_of_birth, place_of_birth, passport_number, '
          'nationality, gender, passport_expiry_date, business_status, '
          'created_by, created_at, deleted_at',
        )
        .single();
    return Map<String, dynamic>.from(row);
  }

  static Future<void> softDeleteCustomer(String id) async {
    final client = _requiredClient;
    await client
        .from('customers')
        .update({
          'deleted_at': DateTime.now().toUtc().toIso8601String(),
          'updated_by': _requiredUserId,
        })
        .eq('id', id);
  }

  static Future<void> clearLatestPinRecord(String customerId) async {
    final client = _requiredClient;
    final latest = await client
        .from('email_pin_records')
        .select('id')
        .eq('customer_id', customerId)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (latest == null) return;
    await client
        .from('email_pin_records')
        .update({
          'pin_value': null,
          'status': 'NEEDS_REVIEW',
          'raw_summary': {'source': 'MANUAL_EDIT', 'pin_cleared': true},
        })
        .eq('id', latest['id']);
  }

  static Future<void> insertPinRecord({
    required String customerId,
    required String pin,
    String matchedBy = 'MANUAL',
  }) async {
    final storedPin = normalizePin(pin);
    if (storedPin == null) {
      throw const FormatException('PIN 不能为空。');
    }
    await _requiredClient.from('email_pin_records').insert({
      'customer_id': customerId,
      'matched_by': matchedBy,
      'pin_value': storedPin,
      'status': 'RECEIVED',
      'raw_summary': {'source': matchedBy, 'internal_spaces_preserved': true},
      'received_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static String? normalizePin(String? value) {
    if (value == null || value.isEmpty) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static SupabaseClient get _requiredClient =>
      _client ?? (throw const AuthException('Supabase 尚未初始化。'));

  static String get _requiredUserId =>
      currentUserId ?? (throw const AuthException('当前没有登录用户。'));

  static String _toIsoDate(String value) {
    final parts = value.trim().split('/');
    if (parts.length != 3) throw const FormatException('日期必须是 DD/MM/YYYY。');
    final day = int.parse(parts[0]);
    final month = int.parse(parts[1]);
    final year = int.parse(parts[2]);
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      throw const FormatException('日期无效。');
    }
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}
