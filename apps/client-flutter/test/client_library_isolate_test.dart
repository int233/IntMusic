import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/intmusic_client.dart';

void main() {
  test('client file inspection sends only isolate-safe values', () async {
    final directory = await Directory.systemTemp.createTemp(
      'intmusic-client-library-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}sample.mp3');
    await file.writeAsBytes(<int>[0, 1, 2, 3]);

    final manifests = await inspectClientFilesInBackground(
      rootPath: directory.path,
      filePaths: <String>[file.path],
    );

    expect(manifests, hasLength(1));
    expect(manifests.single['external_id'], 'sample.mp3');
    expect(manifests.single['size_bytes'], 4);
    expect(manifests.single['metadata_status'], 'tag_parse_error');
    final metadata = (manifests.single['metadata'] as Map)
        .cast<String, dynamic>();
    expect(metadata['title'], '');
    expect(metadata['track_artists'], isEmpty);
  });
}
