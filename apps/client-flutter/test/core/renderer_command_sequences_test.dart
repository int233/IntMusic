import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/renderer_command_sequences.dart';

void main() {
  test('volume commands do not supersede transport playback state', () {
    final sequences = RendererCommandSequences();

    sequences.record('renderer:a:default', 10, isTransport: true);
    sequences.record('renderer:a:default', 11, isTransport: false);

    expect(sequences.latest('renderer:a:default'), 11);
    expect(sequences.latestTransport('renderer:a:default'), 10);
    expect(
      sequences.playbackPrecedesTransport('renderer:a:default', 10),
      isFalse,
    );
  });

  test('newer transport commands reject older playback state', () {
    final sequences = RendererCommandSequences();

    sequences.record('renderer:a:default', 12, isTransport: true);

    expect(
      sequences.playbackPrecedesTransport('renderer:a:default', 10),
      isTrue,
    );
    expect(
      sequences.playbackPrecedesTransport('renderer:a:default', 12),
      isFalse,
    );
  });
}
