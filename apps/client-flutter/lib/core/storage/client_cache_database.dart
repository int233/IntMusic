import 'package:sqflite_common/sqlite_api.dart';

Future<void> configureClientCacheDatabase(Database database) async {
  await database.rawQuery('PRAGMA journal_mode = WAL');
  await database.rawQuery('PRAGMA synchronous = NORMAL');
  await database.rawQuery('PRAGMA busy_timeout = 5000');
}
