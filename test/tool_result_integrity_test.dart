import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/features/modules/data/module_model.dart';
import 'package:meow_agent/features/modules/data/module_repository.dart';
import 'package:meow_agent/features/modules/db/db_tools.dart';
import 'package:meow_agent/features/modules/db/user_database.dart';
import 'package:meow_agent/features/modules/db/user_db_repository.dart';
import 'package:meow_agent/features/modules/notes/notes_database.dart';
import 'package:meow_agent/features/modules/notes/notes_tools.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    await UserDatabase.instance.close();
    await NotesDatabase.instance.close();
  });

  test('db tools return read-back evidence for row mutations', () async {
    final repo = UserDbRepository();
    final tools = DbTools(
      repository: repo,
      moduleRepository: _AllowModuleRepository(ModuleRegistry.database),
    );
    await repo.dropTable('accuracy_probe');

    final create = await tools.executeCreateTable({
      'table': 'accuracy_probe',
      'columns': [
        {'name': 'title', 'type': 'TEXT', 'notNull': true},
        {'name': 'amount', 'type': 'REAL'},
      ],
    });
    expect(create.success, true, reason: create.error);
    expect(create.data?['persisted'], true);
    expect(create.data?['verifiedColumns'], 2);

    final insert = await tools.executeInsert({
      'table': 'accuracy_probe',
      'data': {'title': 'Kopi', 'amount': 12.5},
    });
    expect(insert.success, true, reason: insert.error);
    expect(insert.data?['persisted'], true);
    expect(insert.data?['verifiedFields'], 2);

    final id = insert.data?['id'] as String;
    final update = await tools.executeUpdate({
      'table': 'accuracy_probe',
      'data': {'title': 'Teh'},
      'where': '_id = ?',
      'whereArgs': [id],
    });
    expect(update.success, true, reason: update.error);
    expect(update.data?['updated'], 1);
    expect(update.data?['verifiedRows'], 1);

    final delete = await tools.executeDelete({
      'table': 'accuracy_probe',
      'where': '_id = ?',
      'whereArgs': [id],
    });
    expect(delete.success, true, reason: delete.error);
    expect(delete.data?['deleted'], 1);
    expect(delete.data?['verifiedDeleted'], 1);

    final drop = await tools.executeDropTable({'table': 'accuracy_probe'});
    expect(drop.success, true, reason: drop.error);
    expect(drop.data?['absent'], true);
  });

  test(
    'notes tools return persisted evidence and reject missing deletes',
    () async {
      final db = await NotesDatabase.instance.database;
      await db.delete('notes');

      final tools = NotesTools(
        moduleRepository: _AllowModuleRepository(ModuleRegistry.notes),
      );

      final create = await tools.executeCreate({
        'title': 'Accuracy Probe',
        'content': 'read-back content',
        'tags': ['runtime'],
        'source': 'test',
      });
      expect(create.success, true, reason: create.error);
      expect(create.data?['persisted'], true);
      expect(create.data?['verifiedFields'], 4);

      final noteId = create.data?['noteId'] as String;
      final update = await tools.executeUpdate({
        'noteId': noteId,
        'title': 'Accuracy Probe Updated',
        'content': 'updated content',
      });
      expect(update.success, true, reason: update.error);
      expect(update.data?['persisted'], true);
      expect(update.data?['verifiedFields'], 2);

      final pin = await tools.executeSetPinned({
        'noteId': noteId,
      }, pinned: true);
      expect(pin.success, true, reason: pin.error);
      expect(pin.data?['stateVerified'], true);

      final unpin = await tools.executeSetPinned({
        'noteId': noteId,
      }, pinned: false);
      expect(unpin.success, true, reason: unpin.error);
      expect(unpin.data?['stateVerified'], true);

      final append = await tools.executeAppend({
        'noteId': noteId,
        'content': 'tail',
        'separator': '\n',
      });
      expect(append.success, true, reason: append.error);
      expect(append.data?['stateVerified'], true);

      final delete = await tools.executeDelete({'noteId': noteId});
      expect(delete.success, true, reason: delete.error);
      expect(delete.data?['deleted'], 1);
      expect(delete.data?['absent'], true);

      final missingDelete = await tools.executeDelete({'noteId': noteId});
      expect(missingDelete.success, false);
    },
  );
}

class _AllowModuleRepository extends ModuleRepository {
  _AllowModuleRepository(this.module);

  final ModuleModel module;

  @override
  Future<List<ModuleModel>> getInstalled() async {
    return [
      module.copyWith(
        enabled: true,
        settings: {for (final key in module.settings.keys) key: true},
      ),
    ];
  }
}
