import 'dart:io';

void main() {
  final failures = <String>[];
  final lib = Directory('lib');
  if (!lib.existsSync()) {
    stderr.writeln('Run this check from apps/client-flutter.');
    exitCode = 2;
    return;
  }

  final dartFiles = lib
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList(growable: false);

  for (final file in dartFiles) {
    final relativePath = file.path.replaceAll('\\', '/');
    final source = file.readAsStringSync();
    final lineCount = '\n'.allMatches(source).length + 1;
    if (lineCount > 1100) {
      failures.add(
        '$relativePath has $lineCount lines; split source files before they exceed 1100.',
      );
    }
    if (relativePath.contains('/dashboard_') && lineCount > 850) {
      failures.add(
        '$relativePath has $lineCount lines; dashboard feature extensions are limited to 850.',
      );
    }
    if (relativePath != 'lib/src/platform_integration.dart' &&
        source.contains('MethodChannel(')) {
      failures.add(
        '$relativePath creates a MethodChannel outside platform_integration.dart.',
      );
    }
  }

  _checkMaximumLines(failures, File('lib/main.dart'), 30);
  _checkMaximumLines(failures, File('lib/intmusic_client.dart'), 550);
  _checkMaximumLines(failures, File('../../crates/core-api/src/lib.rs'), 500);
  _checkMaximumLines(failures, File('../../crates/core-db/src/lib.rs'), 200);
  _checkRustModules(failures, Directory('../../crates/core-api/src'));
  _checkRustModules(failures, Directory('../../crates/core-db/src'));

  final applicationSource = File('lib/intmusic_client.dart').readAsStringSync();
  if (applicationSource.contains('Timer.periodic(')) {
    failures.add(
      'lib/intmusic_client.dart schedules periodic work directly; use PeriodicTaskScheduler.',
    );
  }
  for (final file in Directory(
    '../../crates/core-api/src',
  ).listSync().whereType<File>().where((file) => file.path.endsWith('.rs'))) {
    if (file.readAsStringSync().contains('sqlx::')) {
      failures.add(
        '${file.path} accesses SQL directly; move persistence into core-db.',
      );
    }
  }

  if (failures.isEmpty) {
    stdout.writeln(
      'Architecture checks passed for ${dartFiles.length} Dart source files.',
    );
    return;
  }

  stderr.writeln('Architecture checks failed:');
  for (final failure in failures) {
    stderr.writeln('  - $failure');
  }
  exitCode = 1;
}

void _checkRustModules(List<String> failures, Directory directory) {
  for (final file in directory.listSync().whereType<File>().where(
    (file) => file.path.endsWith('.rs'),
  )) {
    final lineCount = '\n'.allMatches(file.readAsStringSync()).length + 1;
    final maximum = file.path.endsWith('tests.rs') ? 1100 : 850;
    if (lineCount > maximum) {
      failures.add(
        '${file.path} has $lineCount lines; Rust modules are limited to $maximum.',
      );
    }
  }
}

void _checkMaximumLines(List<String> failures, File file, int maximum) {
  final lineCount = '\n'.allMatches(file.readAsStringSync()).length + 1;
  if (lineCount > maximum) {
    failures.add(
      '${file.path} has $lineCount lines; expected at most $maximum.',
    );
  }
}
