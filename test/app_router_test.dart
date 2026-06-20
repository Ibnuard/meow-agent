import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:meow_agent/app/router.dart';

void main() {
  test('database result action target has a registered route', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final router = container.read(goRouterProvider);
    final registered = router.configuration.routes.whereType<GoRoute>().any(
      (route) => route.path == AppRoutes.databaseManager,
    );

    expect(AppRoutes.databaseManager, '/database');
    expect(registered, isTrue);
  });
}
