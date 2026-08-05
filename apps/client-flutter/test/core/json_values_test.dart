import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/json_values.dart';

void main() {
  test('jsonObjectOrEmpty accepts missing optional objects', () {
    expect(jsonObjectOrEmpty(null), isEmpty);
    expect(jsonObjectOrEmpty('not an object'), isEmpty);
  });

  test('jsonObjectOrEmpty preserves JSON object fields', () {
    expect(
      jsonObjectOrEmpty(<dynamic, dynamic>{'title': 'Track', 'year': 2026}),
      <String, dynamic>{'title': 'Track', 'year': 2026},
    );
  });
}
