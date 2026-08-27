import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passport_mdac_app/main.dart';

void main() {
  group('DemoRepository business rules', () {
    test('OCR confirmation creates a pending customer only after all fields are present', () {
      final repository = DemoRepository();
      repository.importDemoDocument(isPdf: false);
      final draft = repository.ocrDrafts.single;

      final error = repository.confirmOcr(draft, {
        'fullName': 'TEST TRAVELLER',
        'passportNumber': 'ZX900001',
        'dateOfBirth': '01/01/1990',
        'placeOfBirth': 'CHINA',
        'nationality': 'CHN',
        'gender': '男',
        'passportExpiryDate': '01/01/2030',
      }, 'Tester');

      expect(error, isNull);
      expect(
        repository.activeCustomers.any(
          (customer) => customer.passportNumber == 'ZX900001',
        ),
        isTrue,
      );
      expect(repository.ocrDrafts, isEmpty);
    });

    test('OCR confirmation blocks a duplicate passport number', () {
      final repository = DemoRepository();
      repository.importDemoDocument(isPdf: false);
      final error = repository.confirmOcr(repository.ocrDrafts.single, {
        'fullName': 'DUPLICATE CUSTOMER',
        'passportNumber': 'EJ1660876',
        'dateOfBirth': '01/01/1990',
        'placeOfBirth': 'CHINA',
        'nationality': 'CHN',
        'gender': '男',
        'passportExpiryDate': '01/01/2030',
      }, 'Tester');

      expect(error, contains('已存在'));
      expect(repository.activeCustomers.length, 4);
    });

    test(
      'manual creation keeps internal PIN spaces and trims only boundaries',
      () {
        final repository = DemoRepository();
        final error = repository.createManualCustomer({
          'fullName': 'Manual Traveller',
          'passportNumber': ' zx 900002 ',
          'dateOfBirth': '01/01/1990',
          'placeOfBirth': 'China',
          'nationality': 'chn',
          'gender': '男',
          'passportExpiryDate': '01/01/2030',
          'pin': '  AB  12 CD  ',
        }, 'Tester');

        expect(error, isNull);
        final customer = repository.activeCustomers.first;
        expect(customer.fullName, 'MANUAL TRAVELLER');
        expect(customer.passportNumber, 'ZX 900002');
        expect(customer.pin, 'AB  12 CD');
      },
    );

    test('editing a customer persists fields and blocks duplicate passport numbers', () {
      final repository = DemoRepository();
      final customer = repository.findCustomer('c-004')!;
      final error = repository.updateCustomer(customer, {
        'fullName': 'Edited Traveller',
        'passportNumber': ' NEW900003 ',
        'dateOfBirth': '02/02/1991',
        'placeOfBirth': 'Malaysia',
        'nationality': 'mys',
        'gender': '女',
        'passportExpiryDate': '02/02/2031',
        'pin': ' P 9 9 ',
      }, 'Tester');

      expect(error, isNull);
      expect(customer.fullName, 'EDITED TRAVELLER');
      expect(customer.passportNumber, 'NEW900003');
      expect(customer.pin, 'P 9 9');

      final duplicateError = repository.updateCustomer(customer, {
        'fullName': 'Edited Traveller',
        'passportNumber': 'EJ1660876',
        'dateOfBirth': '02/02/1991',
        'placeOfBirth': 'Malaysia',
        'nationality': 'mys',
        'gender': '女',
        'passportExpiryDate': '02/02/2031',
        'pin': 'P 9 9',
      }, 'Tester');
      expect(duplicateError, contains('已存在'));
    });

    test('MDAC task rejects exit dates before entry dates', () {
      final repository = DemoRepository();
      final error = repository.createTask(
        type: TaskType.mdacRegistration,
        customerIds: ['c-004'],
        actor: 'Tester',
        entryDate: DateTime(2026, 9, 10),
        exitDate: DateTime(2026, 9, 9),
      );

      expect(error, '出境日期不能早于入境日期。');
      expect(repository.tasks.length, 2);
    });

    test('a customer cannot be included in two active tasks', () async {
      final repository = DemoRepository();
      final firstError = repository.createTask(
        type: TaskType.mdacRegistration,
        customerIds: ['c-004'],
        actor: 'Tester',
        entryDate: DateTime(2026, 9, 10),
        exitDate: DateTime(2026, 9, 12),
      );
      final secondError = repository.createTask(
        type: TaskType.gmailPin,
        customerIds: ['c-004'],
        actor: 'Tester',
      );

      expect(firstError, isNull);
      expect(secondError, contains('运行中的任务'));
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      expect(
        repository.tasks
            .where((task) => task.customerIds.contains('c-004'))
            .length,
        1,
      );
    });

    test('soft delete hides a customer but keeps the record', () {
      final repository = DemoRepository();
      final blocked = repository.deleteCustomers(['c-004'], 'Tester');

      expect(blocked, isEmpty);
      expect(
        repository.activeCustomers.any((customer) => customer.id == 'c-004'),
        isFalse,
      );
      expect(repository.findCustomer('c-004'), isNotNull);
      expect(repository.findCustomer('c-004')!.isDeleted, isTrue);
    });

    test('date validation accepts only real DD/MM/YYYY dates', () {
      expect(isMdacDate('09/08/1990'), isTrue);
      expect(isMdacDate('31/02/1990'), isFalse);
      expect(isMdacDate('9/8/1990'), isFalse);
      expect(isMdacDate('09-08-1990'), isFalse);
    });

    test('customer archive filters creation date independently', () {
      final today = DateTime(2026, 8, 27, 12);
      expect(
        matchesCustomerCreatedDateFilter(
          DateTime(2026, 8, 27, 23),
          '今天',
          today: today,
        ),
        isTrue,
      );
      expect(
        matchesCustomerCreatedDateFilter(
          DateTime(2026, 8, 21),
          '最近 7 天',
          today: today,
        ),
        isTrue,
      );
      expect(
        matchesCustomerCreatedDateFilter(
          DateTime(2026, 8, 20),
          '最近 7 天',
          today: today,
        ),
        isFalse,
      );
      expect(
        matchesCustomerCreatedDateFilter(
          DateTime(2026, 7, 29),
          '最近 30 天',
          today: today,
        ),
        isTrue,
      );
      expect(
        matchesCustomerCreatedDateFilter(
          DateTime(2026, 7, 28),
          '最近 30 天',
          today: today,
        ),
        isFalse,
      );
      expect(
        matchesCustomerCreatedDateFilter(
          DateTime(2026, 7, 15),
          '自定义范围',
          customRange: DateTimeRange(
            start: DateTime(2026, 7, 1),
            end: DateTime(2026, 7, 20),
          ),
        ),
        isTrue,
      );
      expect(
        matchesCustomerCreatedDateFilter(
          DateTime(2026, 7, 21),
          '自定义范围',
          customRange: DateTimeRange(
            start: DateTime(2026, 7, 1),
            end: DateTime(2026, 7, 20),
          ),
        ),
        isFalse,
      );
    });

    test(
      'bulk created_at update changes selected active customers and audits it',
      () async {
        final repository = DemoRepository();
        final target = DateTime(2026, 8, 1, 15, 30);

        final error = await repository.updateCustomersCreatedAtWithSync(
          ['c-004', 'c-002'],
          target,
          'Tester',
        );

        expect(error, isNull);
        expect(repository.findCustomer('c-004')!.createdAt, target);
        expect(repository.findCustomer('c-002')!.createdAt, target);
        expect(repository.auditEvents.first, contains('批量修改 2 位客户'));
      },
    );

    test(
      'bulk created_at update rejects empty and soft-deleted selections',
      () async {
        final repository = DemoRepository();
        final target = DateTime(2026, 8, 1, 15, 30);

        expect(
          await repository.updateCustomersCreatedAtWithSync(
            [],
            target,
            'Tester',
          ),
          '请先选择客户。',
        );
        repository.deleteCustomers(['c-004'], 'Tester');
        expect(
          await repository.updateCustomersCreatedAtWithSync(
            ['c-004'],
            target,
            'Tester',
          ),
          contains('已被删除'),
        );
      },
    );

    test(
      'customer created_at validation rejects dates outside the safe range',
      () {
        expect(
          isValidCustomerCreatedAt(DateTime(1999, 12, 31, 23, 59)),
          isFalse,
        );
        expect(
          isValidCustomerCreatedAt(DateTime.now().add(const Duration(days: 2))),
          isFalse,
        );
        expect(isValidCustomerCreatedAt(DateTime(2026, 8, 1, 15, 30)), isTrue);
      },
    );

    test('passport document paths distinguish image previews from PDFs', () {
      expect(isPassportImagePath('owner/ocr/passport.jpg'), isTrue);
      expect(isPassportImagePath('owner/ocr/passport.png?version=1'), isTrue);
      expect(isPassportImagePath('owner/ocr/passport.pdf'), isFalse);
    });

    test('customer archive nationality filter values are normalized', () {
      final repository = DemoRepository();
      final nationalities = repository.activeCustomers
          .map((customer) => customer.nationality.trim().toUpperCase())
          .toSet();

      expect(nationalities, contains('CHN'));
      expect(nationalities, contains('MYS'));
      expect(
        nationalities.every((value) => value == value.toUpperCase()),
        isTrue,
      );
    });

    test('MDAC settings require a complete business default set', () {
      final empty = MdacSettings.defaults();
      expect(empty.isComplete, isFalse);

      final complete = MdacSettings.fromMap({
        'mdac_email': 'desk@example.com',
        'mdac_phone': '+60123456789',
        'region_code': '60',
        'travel_mode': '1',
        'embark_country': 'chn',
        'vessel': 'MH123',
        'accommodation_stay': '01',
        'address1': '12 Jalan Test',
        'address2': '',
        'state_code': '14',
        'city_code': '0100',
        'postcode': '50000',
        'pob_mode': 'NATIONALITY',
      });

      expect(complete.isComplete, isTrue);
      expect(complete.embarkCountry, 'CHN');
      expect(complete.toRpcParams()['embarkCountry'], 'CHN');
      expect(complete.toRpcParams()['regionCode'], '60');
    });

    test('Gmail settings require a valid App-managed address', () {
      final empty = GmailSettings.defaults();
      expect(empty.isComplete, isFalse);

      final settings = GmailSettings.fromMap({
        'gmail_address': 'MDAC.Company@GMAIL.COM',
        'credential_configured': true,
      });
      expect(settings.isComplete, isTrue);
      expect(settings.gmailAddress, 'mdac.company@gmail.com');
      expect(settings.credentialConfigured, isTrue);
      expect(
        GmailSettings.fromMap({'gmail_address': 'mdac.company@gmail.com'})
            .isComplete,
        isFalse,
      );
    });

    test('manual creation rejects free-text gender and invalid status', () {
      final repository = DemoRepository();
      final values = <String, String>{
        'fullName': 'Invalid Selection',
        'passportNumber': 'ZX900004',
        'dateOfBirth': '01/01/1990',
        'placeOfBirth': 'China',
        'nationality': 'CHN',
        'gender': 'Unknown',
        'passportExpiryDate': '01/01/2030',
        'businessStatus': 'NOT_A_STATUS',
      };

      expect(repository.createManualCustomer(values, 'Tester'), contains('性别'));
    });
  });
}
