import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/env_loader.dart';

void main() {
  test('debug — print current dir and env loading', () {
    print('Directory.current: ${Directory.current.path}');
    final envAtRoot = File(r'D:\Dev\Personal\PROJECT_MEOW\.env');
    print('.env at project root exists: ${envAtRoot.existsSync()}');
    final envAtCwd = File('${Directory.current.path}/.env');
    print('.env at cwd exists: ${envAtCwd.existsSync()}');

    EnvLoader.load(projectRoot: r'D:\Dev\Personal\PROJECT_MEOW');
    print('baseUrl: ${EnvLoader.baseUrl}');
    print('apiKey: ${EnvLoader.apiKey.isNotEmpty ? "SET" : "EMPTY"}');
    print('model: ${EnvLoader.model}');
    print('isAvailable: ${EnvLoader.isAvailable}');
  });
}