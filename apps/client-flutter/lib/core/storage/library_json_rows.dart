import 'package:sqflite_common/sqlite_api.dart';

// Android CursorWindow limits individual result rows, regardless of LIMIT.
// Fetch large JSON as bounded SQL substrings inside the same read transaction.
const _chunkCharacters = 64 * 1024;

Future<List<Map<String, Object?>>> readLibraryJsonRows(
  DatabaseExecutor database,
  String table, {
  List<String> columns = const [],
  String? where,
  List<Object?>? whereArgs,
  String? orderBy,
  int? limit,
}) {
  Future<List<Map<String, Object?>>> read(DatabaseExecutor executor) async {
    final rows = await executor.query(
      table,
      columns: [
        ...columns,
        'rowid AS _json_rowid',
        'length(payload) AS _json_characters',
        'CASE WHEN length(payload) <= $_chunkCharacters THEN payload END AS payload',
      ],
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
    );
    final result = <Map<String, Object?>>[];
    for (final row in rows) {
      final value = <String, Object?>{
        for (final column in columns) column: row[column],
      };
      if (row['payload'] is String) {
        value['payload'] = row['payload'];
      } else {
        final buffer = StringBuffer();
        final length = row['_json_characters'] as int;
        for (var offset = 0; offset < length; offset += _chunkCharacters) {
          final chunk = await executor.rawQuery(
            'SELECT substr(payload, ?, ?) AS payload FROM $table WHERE rowid = ?',
            [offset + 1, _chunkCharacters, row['_json_rowid']],
          );
          if (chunk.length != 1 || chunk.single['payload'] is! String) {
            throw StateError('Library JSON changed during its read');
          }
          buffer.write(chunk.single['payload']);
        }
        value['payload'] = buffer.toString();
      }
      result.add(value);
    }
    return result;
  }

  return database is Database ? database.transaction(read) : read(database);
}
