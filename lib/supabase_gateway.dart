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
    final row = await _requiredClient
        .from('ocr_results')
        .update({
          'status': 'CREATED',
          'created_customer_id': customerId,
          'reviewed_by': _requiredUserId,
          'reviewed_at': DateTime.now().toUtc().toIso8601String(),
          'extracted_data': extractedData,
        })
        .eq('id', resultId)
        .select('id, created_customer_id')
        .single();
    if (row['created_customer_id']?.toString() != customerId) {
      throw const FormatException('OCR 与客户关联写入失败。');
    }
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

  static Future<Map<String, dynamic>> createMdacRegistrationBatch({
    required DateTime entryDate,
    required DateTime exitDate,
    required List<Map<String, dynamic>> customers,
    String? note,
  }) async {
    if (customers.isEmpty) {
      throw const FormatException('MDAC 批次至少需要一位客户。');
    }
    final entry = _dateOnly(entryDate);
    final exit = _dateOnly(exitDate);
    final items = <Map<String, dynamic>>[
      for (final customer in customers)
        {
          'customer_id': customer['id'],
          'customer_snapshot': {
            'full_name': customer['full_name']?.toString().trim() ?? '',
            'passport_number':
                customer['passport_number']?.toString().trim() ?? '',
            'date_of_birth': _toIsoDate(
              customer['date_of_birth']?.toString() ?? '',
            ),
            'place_of_birth':
                customer['place_of_birth']?.toString().trim() ?? '',
            'nationality': customer['nationality']?.toString().trim() ?? '',
            'gender': customer['gender']?.toString().trim() ?? '',
            'passport_expiry_date': _toIsoDate(
              customer['passport_expiry_date']?.toString() ?? '',
            ),
            'entry_date': entry,
            'exit_date': exit,
          },
        },
    ];
    final result = await _requiredClient.rpc(
      'create_mdac_registration_batch',
      params: {
        'p_entry_date': entry,
        'p_exit_date': exit,
        'p_items': items,
        'p_note': note,
      },
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw const FormatException('Supabase 未返回 MDAC 批次。');
  }

  static Future<Map<String, dynamic>> createGmailPinBatch({
    required List<Map<String, dynamic>> customers,
    String? note,
  }) async {
    if (customers.isEmpty) {
      throw const FormatException('Gmail PIN 批次至少需要一位客户。');
    }
    final items = <Map<String, dynamic>>[
      for (final customer in customers)
        {
          'customer_id': customer['id'],
          'customer_snapshot': {
            'full_name': customer['full_name']?.toString().trim() ?? '',
            'passport_number':
                customer['passport_number']?.toString().trim() ?? '',
            'date_of_birth': _toIsoDate(
              customer['date_of_birth']?.toString() ?? '',
            ),
            'place_of_birth':
                customer['place_of_birth']?.toString().trim() ?? '',
            'nationality': customer['nationality']?.toString().trim() ?? '',
            'gender': customer['gender']?.toString().trim() ?? '',
            'passport_expiry_date': _toIsoDate(
              customer['passport_expiry_date']?.toString() ?? '',
            ),
          },
        },
    ];
    final result = await _requiredClient.rpc(
      'create_gmail_pin_batch',
      params: {'p_items': items, 'p_note': note},
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw const FormatException('Supabase 未返回 Gmail PIN 批次。');
  }

  static Future<Map<String, dynamic>> createRegistrationCheckBatch({
    required List<Map<String, dynamic>> customers,
    String? note,
  }) async {
    if (customers.isEmpty) {
      throw const FormatException('Check Registration 批次至少需要一位客户。');
    }
    final items = <Map<String, dynamic>>[
      for (final customer in customers)
        {
          'customer_id': customer['id'],
          'customer_snapshot': {
            'full_name': customer['full_name']?.toString().trim() ?? '',
            'passport_number':
                customer['passport_number']?.toString().trim() ?? '',
            'nationality': customer['nationality']?.toString().trim() ?? '',
          },
        },
    ];
    final result = await _requiredClient.rpc(
      'create_registration_check_batch',
      params: {'p_items': items, 'p_note': note},
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw const FormatException('Supabase 未返回 Check Registration 批次。');
  }

  static Future<Map<String, dynamic>> createVisitPassCheckBatch({
    required List<Map<String, dynamic>> customers,
    required String email,
    required String regionCode,
    required String mobile,
    String? note,
  }) async {
    if (customers.isEmpty) {
      throw const FormatException('Check Visit Pass 批次至少需要一位客户。');
    }
    final normalizedEmail = email.trim().toLowerCase();
    final normalizedRegionCode = regionCode.trim();
    final normalizedMobile = mobile.trim();
    if (normalizedEmail.isEmpty ||
        normalizedRegionCode.isEmpty ||
        normalizedMobile.isEmpty) {
      throw const FormatException('Check Visit Pass 需要邮箱、国家/地区代码和手机号。');
    }
    final items = <Map<String, dynamic>>[
      for (final customer in customers)
        {
          'customer_id': customer['id'],
          'customer_snapshot': {
            'full_name': customer['full_name']?.toString().trim() ?? '',
            'passport_number':
                customer['passport_number']?.toString().trim() ?? '',
            'nationality': customer['nationality']?.toString().trim() ?? '',
          },
        },
    ];
    final result = await _requiredClient.rpc(
      'create_visit_pass_check_batch',
      params: {
        'p_items': items,
        'p_settings_snapshot': {
          'email': normalizedEmail,
          'region_code': normalizedRegionCode,
          'mobile': normalizedMobile,
        },
        'p_note': note,
      },
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw const FormatException('Supabase 未返回 Check Visit Pass 批次。');
  }

  static Future<Map<String, dynamic>> createHumanQueryTask({
    required String customerId,
    required bool visitPass,
    Map<String, dynamic> settingsSnapshot = const {},
  }) async {
    final result = await _requiredClient.rpc(
      'create_human_query_task',
      params: {
        'p_customer_id': customerId,
        'p_task_type': visitPass ? 'VISIT_PASS_CHECK' : 'REGISTRATION_CHECK',
        'p_settings_snapshot': settingsSnapshot,
      },
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw const FormatException('Supabase 未返回人工查询任务。');
  }

  static Future<String> uploadHumanQueryEvidence({
    required String itemId,
    required Uint8List bytes,
    String extension = 'png',
    String contentType = 'image/png',
  }) async {
    if (bytes.isEmpty) throw const FormatException('查询凭证为空。');
    final userId = currentUserId;
    if (userId == null) throw const AuthException('登录状态已失效。');
    final safeExtension = extension.toLowerCase() == 'pdf' ? 'pdf' : 'png';
    final path =
        'human-query-evidence/$userId/$itemId-${DateTime.now().millisecondsSinceEpoch}.$safeExtension';
    await _requiredClient.storage.from('passport-documents').uploadBinary(
      path,
      bytes,
      fileOptions: FileOptions(
        contentType: contentType,
        upsert: false,
      ),
    );
    return path;
  }

  static Future<Uint8List> downloadHumanQueryEvidence(String path) async {
    if (!path.startsWith('human-query-evidence/$_requiredUserId/')) {
      throw const AuthException('无权读取该查询凭证。');
    }
    return _requiredClient.storage.from('passport-documents').download(path);
  }

  static Future<Map<String, dynamic>> finishHumanQueryTask({
    required String itemId,
    required String outcome,
    String? screenshotPath,
  }) async {
    final result = await _requiredClient.rpc(
      'finish_human_query_task',
      params: {
        'p_item_id': itemId,
        'p_outcome': outcome,
        'p_screenshot_path': screenshotPath,
      },
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw const FormatException('Supabase 未返回人工查询结果。');
  }

  static Future<Map<String, dynamic>> fetchGmailSettings() async {
    final row = await _requiredClient
        .from('gmail_settings')
        .select(
          'id, gmail_address, credential_configured, updated_by, updated_at',
        )
        .eq('id', true)
        .single();
    return Map<String, dynamic>.from(row);
  }

  static Future<Map<String, dynamic>> updateGmailSettings({
    required String gmailAddress,
  }) async {
    final result = await _requiredClient.rpc(
      'update_gmail_settings',
      params: {'p_gmail_address': gmailAddress},
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw const FormatException('Supabase 未返回 Gmail 设置。');
  }

  static Future<Map<String, dynamic>> saveGmailCredentials({
    required String gmailAddress,
    required String appPassword,
  }) async {
    final result = await _requiredClient.rpc(
      'save_gmail_credentials',
      params: {'p_gmail_address': gmailAddress, 'p_app_password': appPassword},
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw const FormatException('Supabase 未返回 Gmail 凭证状态。');
  }

  static Future<Map<String, dynamic>> fetchMdacSettings() async {
    final row = await _requiredClient
        .from('mdac_settings')
        .select(
          'id, mdac_email, mdac_phone, region_code, travel_mode, '
          'embark_country, vessel, accommodation_stay, address1, address2, '
          'state_code, city_code, postcode, pob_mode, updated_by, updated_at',
        )
        .eq('id', true)
        .single();
    return Map<String, dynamic>.from(row);
  }

  static Future<Map<String, dynamic>> updateMdacSettings({
    required String mdacEmail,
    required String mdacPhone,
    required String regionCode,
    required String travelMode,
    required String embarkCountry,
    required String vessel,
    required String accommodationStay,
    required String address1,
    required String address2,
    required String stateCode,
    required String cityCode,
    required String postcode,
    required String pobMode,
  }) async {
    final result = await _requiredClient.rpc(
      'update_mdac_settings',
      params: {
        'p_mdac_email': mdacEmail,
        'p_mdac_phone': mdacPhone,
        'p_region_code': regionCode,
        'p_travel_mode': travelMode,
        'p_embark_country': embarkCountry,
        'p_vessel': vessel,
        'p_accommodation_stay': accommodationStay,
        'p_address1': address1,
        'p_address2': address2,
        'p_state_code': stateCode,
        'p_city_code': cityCode,
        'p_postcode': postcode,
        'p_pob_mode': pobMode,
      },
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw const FormatException('Supabase 未返回 MDAC 设置。');
  }

  static Future<List<Map<String, dynamic>>> fetchAutomationBatches() async {
    final client = _requiredClient;
    final batchRows = await client
        .from('automation_batches')
        .select(
          'id, task_type, status, total_count, success_count, failed_count, '
          'entry_date, exit_date, mdac_settings_snapshot, note, created_by, '
          'created_at, updated_at',
        )
        .order('created_at', ascending: false)
        .limit(100);
    final batches = batchRows
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    if (batches.isEmpty) return batches;

    final batchIds = batches
        .map((row) => row['id'])
        .whereType<String>()
        .toList();
    final itemRows = await client
        .from('automation_items')
        .select(
          'id, batch_id, customer_id, status, attempt_count, error_code, '
          'error_message, result_unknown, created_at, updated_at',
        )
        .inFilter('batch_id', batchIds)
        .order('created_at', ascending: true)
        .limit(500);
    final items = itemRows
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    final itemIds = items.map((row) => row['id']).whereType<String>().toList();
    final registrationRows = itemIds.isEmpty
        ? <dynamic>[]
        : await client
              .from('mdac_registrations')
              .select(
                'batch_item_id, registration_no, registration_status, '
                'raw_summary, screenshot_path, submitted_at, '
                'result_confirmed_at, updated_at',
              )
              .inFilter('batch_item_id', itemIds)
              .limit(500);
    final registrationByItem = <String, Map<String, dynamic>>{
      for (final row in registrationRows)
        if (row['batch_item_id'] != null)
          row['batch_item_id'].toString(): Map<String, dynamic>.from(row),
    };
    final registrationCheckRows = itemIds.isEmpty
        ? <dynamic>[]
        : await client
              .from('registration_checks')
              .select(
                'batch_item_id, checked_at, result_status, raw_summary, '
                'normalized_status, error_message, screenshot_path, '
                'challenge_type, submitted, result_confirmed, updated_at',
              )
              .inFilter('batch_item_id', itemIds)
              .limit(500);
    final registrationCheckByItem = <String, Map<String, dynamic>>{
      for (final row in registrationCheckRows)
        if (row['batch_item_id'] != null)
          row['batch_item_id'].toString(): Map<String, dynamic>.from(row),
    };
    final itemsByBatch = <String, List<Map<String, dynamic>>>{};
    for (final item in items) {
      final batchId = item['batch_id']?.toString();
      if (batchId == null) continue;
      itemsByBatch.putIfAbsent(batchId, () => <Map<String, dynamic>>[]).add({
        ...item,
        'registration': registrationByItem[item['id']?.toString()],
        'registration_check': registrationCheckByItem[item['id']?.toString()],
      });
    }
    return [
      for (final batch in batches)
        {
          ...batch,
          'items':
              itemsByBatch[batch['id']?.toString()] ?? <Map<String, dynamic>>[],
        },
    ];
  }

  static Future<Map<String, dynamic>> cancelAutomationBatch(
    String batchId,
  ) async {
    final result = await _requiredClient.rpc(
      'cancel_automation_batch',
      params: {'p_batch_id': batchId},
    );
    if (result is! Map) {
      throw const FormatException('Supabase 未返回删除任务结果。');
    }
    final row = Map<String, dynamic>.from(result);
    final rawPaths = row['storage_paths'];
    final paths = rawPaths is List
        ? rawPaths
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList(growable: false)
        : const <Map<String, dynamic>>[];
    if (paths.isNotEmpty) {
      await removeCustomerStorageObjects(paths);
    }
    return row;
  }

  static Future<List<Map<String, dynamic>>> fetchCustomers() async {
    final client = _requiredClient;
    final rows = await client
        .from('customers')
        .select(
          'id, full_name, date_of_birth, place_of_birth, passport_number, '
          'nationality, gender, passport_expiry_date, passport_image_path, '
          'business_status, created_by, created_at, deleted_at',
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
    String? passportImagePath,
  }) async {
    final response = await _requiredClient.rpc(
      'create_customer_with_case',
      params: {
        'p_full_name': fullName.trim().toUpperCase(),
        'p_passport_number': passportNumber.trim().toUpperCase(),
        'p_date_of_birth': _toIsoDate(dateOfBirth),
        'p_place_of_birth': placeOfBirth.trim().toUpperCase(),
        'p_nationality': nationality.trim().toUpperCase(),
        'p_gender': gender.trim(),
        'p_passport_expiry_date': _toIsoDate(passportExpiryDate),
        'p_passport_image_path': passportImagePath,
        'p_customer_type': 'STANDARD',
      },
    );
    if (response is! Map || response['customer'] is! Map) {
      throw const FormatException('Supabase 未返回 Customer + Passport + Case。');
    }
    return Map<String, dynamic>.from(response['customer'] as Map);
  }

  static Future<Map<String, dynamic>> createCaseForExistingCustomer(
    String customerId,
  ) async {
    final response = await _requiredClient.rpc(
      'create_case_for_existing_customer',
      params: {'p_customer_id': customerId},
    );
    if (response is! Map || response['case'] is! Map) {
      throw const FormatException('Supabase 未返回新 Case。');
    }
    return Map<String, dynamic>.from(response);
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
          'nationality, gender, passport_expiry_date, passport_image_path, '
          'business_status, created_by, created_at, deleted_at',
        )
        .single();
    return Map<String, dynamic>.from(row);
  }

  static Future<List<Map<String, dynamic>>> bulkUpdateCustomerCreatedAt({
    required List<String> customerIds,
    required DateTime createdAt,
  }) async {
    if (customerIds.isEmpty) {
      throw const FormatException('至少需要选择一位客户。');
    }
    final normalizedIds = customerIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (normalizedIds.length != customerIds.length) {
      throw const FormatException('客户 ID 无效。');
    }
    final result = await _requiredClient.rpc(
      'bulk_update_customer_created_at',
      params: {
        'p_customer_ids': normalizedIds,
        'p_created_at': createdAt.toUtc().toIso8601String(),
      },
    );
    if (result is! List) {
      throw const FormatException('Supabase 未返回批量修改结果。');
    }
    return result
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  static Future<Map<String, dynamic>> previewCustomerHardDelete({
    required List<String> customerIds,
  }) async {
    if (customerIds.isEmpty) {
      throw const FormatException('至少需要选择一位客户。');
    }
    final result = await _requiredClient.rpc(
      'preview_customer_hard_delete',
      params: {'p_customer_ids': customerIds},
    );
    if (result is! Map) {
      throw const FormatException('Supabase 未返回永久删除预览。');
    }
    return Map<String, dynamic>.from(result);
  }

  static Future<Map<String, dynamic>> createCustomerHardDeleteJob({
    required List<String> customerIds,
  }) async {
    if (customerIds.isEmpty) {
      throw const FormatException('至少需要选择一位客户。');
    }
    final result = await _requiredClient.rpc(
      'create_customer_hard_delete_job',
      params: {'p_customer_ids': customerIds},
    );
    if (result is! Map) {
      throw const FormatException('Supabase 未返回永久删除任务。');
    }
    return Map<String, dynamic>.from(result);
  }

  static Future<void> removeCustomerStorageObjects(
    List<Map<String, dynamic>> storagePaths,
  ) async {
    final grouped = <String, List<String>>{};
    for (final item in storagePaths) {
      final bucket = item['bucket']?.toString().trim() ?? '';
      final path = item['path']?.toString().trim() ?? '';
      if (bucket.isEmpty || path.isEmpty) continue;
      if (bucket != 'passport-documents') {
        throw const FormatException('永久删除遇到未授权的 Storage bucket。');
      }
      grouped.putIfAbsent(bucket, () => <String>[]).add(path);
    }
    for (final entry in grouped.entries) {
      await _requiredClient.storage.from(entry.key).remove(entry.value);
    }
  }

  static Future<Map<String, dynamic>> markCustomerHardDeleteStorageCleaned(
    String jobId,
  ) async {
    final result = await _requiredClient.rpc(
      'mark_customer_hard_delete_storage_cleaned',
      params: {'p_job_id': jobId},
    );
    if (result is! Map) {
      throw const FormatException('Supabase 未返回 Storage 清理状态。');
    }
    return Map<String, dynamic>.from(result);
  }

  static Future<Map<String, dynamic>> failCustomerHardDelete({
    required String jobId,
    required String errorMessage,
  }) async {
    final result = await _requiredClient.rpc(
      'fail_customer_hard_delete',
      params: {'p_job_id': jobId, 'p_error_message': errorMessage},
    );
    if (result is! Map) {
      throw const FormatException('Supabase 未返回永久删除失败状态。');
    }
    return Map<String, dynamic>.from(result);
  }

  static Future<Map<String, dynamic>> completeCustomerHardDelete(
    String jobId,
  ) async {
    final result = await _requiredClient.rpc(
      'complete_customer_hard_delete',
      params: {'p_job_id': jobId},
    );
    if (result is! Map) {
      throw const FormatException('Supabase 未返回永久删除结果。');
    }
    return Map<String, dynamic>.from(result);
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

  static Future<String> createSignedPassportImageUrl(String path) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) {
      throw const FormatException('护照图片路径为空。');
    }
    return _requiredClient.storage
        .from('passport-documents')
        .createSignedUrl(
          normalizedPath,
          300,
          transform: const TransformOptions(
            width: 900,
            height: 1200,
            resize: ResizeMode.contain,
            quality: 72,
          ),
        );
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

  static String _dateOnly(DateTime value) {
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }

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
