import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../../../core/storage/meow_database.dart';
import 'miniapp_model.dart';

class MiniAppRepository {
  MiniAppRepository();

  static final _globalChangeController = StreamController<void>.broadcast();

  Stream<void> get onChange => _globalChangeController.stream;

  static void notifyChange() {
    _globalChangeController.add(null);
  }

  Future<MiniApp> saveMiniApp(MiniApp app) async {
    final db = await MeowDatabase.instance.database;
    await db.insert(
      'miniapps',
      app.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    notifyChange();
    return app;
  }

  Future<List<MiniApp>> listMiniApps() async {
    final db = await MeowDatabase.instance.database;
    final rows = await db.query('miniapps', orderBy: 'created_at DESC');
    return rows.map(MiniApp.fromMap).toList();
  }

  Future<MiniApp?> getMiniApp(String id) async {
    final db = await MeowDatabase.instance.database;
    final rows = await db.query('miniapps', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return MiniApp.fromMap(rows.first);
  }

  Future<void> deleteMiniApp(String id) async {
    final db = await MeowDatabase.instance.database;
    await db.delete('miniapps', where: 'id = ?', whereArgs: [id]);
    notifyChange();
  }

  void dispose() {}
}

final miniAppRepositoryProvider = Provider<MiniAppRepository>((ref) {
  final repo = MiniAppRepository();
  ref.onDispose(repo.dispose);
  return repo;
});
