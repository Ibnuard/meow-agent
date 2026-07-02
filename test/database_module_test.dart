import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:meow_agent/features/modules/db/user_db_repository.dart';
import 'package:meow_agent/features/modules/db/user_database.dart';
import 'package:meow_agent/services/agent_runtime/tool_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('User Database Tools Registration', () {
    final router = ToolRouter();

    test('db.list_tables is registered as safe and retrieval', () {
      final def = router.getDefinition('db.list_tables');
      expect(def, isNotNull);
      expect(def!.risk, 'safe');
      expect(def.requiresConfirmation, false);
      expect(def.isRetrieval, true);
    });

    test(
      'db.create_table is registered as sensitive-lite and requires confirmation',
      () {
        final def = router.getDefinition('db.create_table');
        expect(def, isNotNull);
        expect(def!.risk, 'sensitive-lite');
        expect(def.requiresConfirmation, true);
        expect(def.isRetrieval, false);
        expect(def.verificationProbe, isNotNull);
        expect(def.verificationProbe!.kind, 'tool_result_data');
      },
    );

    test(
      'db.drop_table is registered as sensitive and requires confirmation',
      () {
        final def = router.getDefinition('db.drop_table');
        expect(def, isNotNull);
        expect(def!.risk, 'sensitive');
        expect(def.requiresConfirmation, true);
      },
    );

    test('db.insert is registered as safe', () {
      final def = router.getDefinition('db.insert');
      expect(def, isNotNull);
      expect(def!.risk, 'safe');
      expect(def.requiresConfirmation, false);
    });

    test('db.query is registered as safe and retrieval', () {
      final def = router.getDefinition('db.query');
      expect(def, isNotNull);
      expect(def!.risk, 'safe');
      expect(def.requiresConfirmation, false);
      expect(def.isRetrieval, true);
    });

    test('all 8 db.* tools are registered', () {
      const tools = [
        'db.list_tables',
        'db.describe_table',
        'db.create_table',
        'db.drop_table',
        'db.insert',
        'db.query',
        'db.update',
        'db.delete',
      ];
      for (final t in tools) {
        expect(router.isRegistered(t), true, reason: '$t not registered');
      }
    });
  });

  group('UserDbRepository CRUD operations', () {
    late UserDbRepository repo;

    setUp(() async {
      repo = UserDbRepository();
      for (final table in await repo.listTables()) {
        await repo.dropTable(table.name);
      }
    });

    tearDown(() async {
      await UserDatabase.instance.close();
    });

    test('can create, describe, insert, query, and drop tables', () async {
      // 1. List tables (should be empty initially)
      final initial = await repo.listTables();
      expect(initial, isEmpty);

      // 2. Create table
      final cols = [
        const UserTableColumn(name: 'title', type: 'TEXT', notNull: true),
        const UserTableColumn(
          name: 'amount',
          type: 'REAL',
          defaultValue: '0.0',
        ),
      ];
      final createRes = await repo.createTable('expenses', cols);
      expect(
        createRes.created,
        true,
        reason: 'Failed to create table: ${createRes.error}',
      );

      // 3. Describe table
      final desc = await repo.describeTable('expenses');
      expect(desc, isNotNull);
      expect(desc!.name, 'expenses');
      expect(desc.columns.any((c) => c.name == 'title'), true);
      expect(
        desc.columns.any((c) => c.name == '_id'),
        false,
      ); // hidden from public columns list

      // 4. Insert row
      final insertRes = await repo.insert('expenses', {
        'title': 'Kopi Latte',
        'amount': 35000.0,
      });
      expect(insertRes.id, isNotNull);

      // 5. Query
      final queryRes = await repo.query('SELECT * FROM expenses');
      expect(queryRes.rows, isNotNull);
      expect(queryRes.rows!.length, 1);
      expect(queryRes.rows!.first['title'], 'Kopi Latte');
      expect(queryRes.rows!.first['amount'], 35000.0);
      expect(queryRes.rows!.first['_id'], insertRes.id);

      // 6. Update
      final updateRes = await repo.update(
        'expenses',
        {'amount': 38000.0},
        whereClause: '_id = ?',
        whereArgs: [insertRes.id!],
      );
      expect(updateRes.updated, 1);

      // Verify update
      final queryRes2 = await repo.query(
        'SELECT * FROM expenses WHERE _id = ?',
        params: [insertRes.id!],
      );
      expect(queryRes2.rows!.first['amount'], 38000.0);

      // 7. Delete row
      final deleteRes = await repo.delete(
        'expenses',
        whereClause: '_id = ?',
        whereArgs: [insertRes.id!],
      );
      expect(deleteRes.deleted, 1);

      final queryRes3 = await repo.query('SELECT * FROM expenses');
      expect(queryRes3.rows, isEmpty);

      // 8. Drop table
      final dropRes = await repo.dropTable('expenses');
      expect(dropRes.dropped, true);

      final postDrop = await repo.listTables();
      expect(postDrop, isEmpty);
    });

    test('protects metadata and internal structures', () async {
      // Trying to drop or mutate internal structures should fail or be blocked by repository guardrails
      final res = await repo.dropTable('sqlite_master');
      expect(res.dropped, false);
      expect(res.error, contains('Table not found'));

      final res2 = await repo.createTable('sqlite_test', [
        const UserTableColumn(name: 'x', type: 'INTEGER'),
      ]);
      expect(res2.created, false);
    });

    test(
      'resolves table names case-insensitively using stored casing',
      () async {
        const storedName = 'FabelCaseProbe';
        await repo.dropTable(storedName);

        final created = await repo.createTable(storedName, [
          const UserTableColumn(name: 'title', type: 'TEXT'),
        ]);
        expect(created.created, true);

        final described = await repo.describeTable('fabelcaseprobe');
        expect(described, isNotNull);
        expect(described!.name, storedName);

        final duplicate = await repo.createTable('FABELCASEPROBE', [
          const UserTableColumn(name: 'title', type: 'TEXT'),
        ]);
        expect(duplicate.created, false);
        expect(duplicate.error, contains('already exists'));

        final dropped = await repo.dropTable('fabelcaseprobe');
        expect(dropped.dropped, true);
        expect(await repo.describeTable(storedName), isNull);
      },
    );
  });
}
