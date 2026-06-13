import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'meow_database.dart';

/// Global Riverpod provider for the core database singleton.
///
/// All repositories access the same [MeowDatabase] instance.
final meowDatabaseProvider = Provider<MeowDatabase>(
  (ref) => MeowDatabase.instance,
);
