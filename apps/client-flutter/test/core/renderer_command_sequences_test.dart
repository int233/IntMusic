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

  test(
    'adoption retains the volume receipt after its transport acknowledgement',
    () {
      final sequences = RendererCommandSequences();
      sequences.record('renderer:a:default', 14, isTransport: false);
      sequences.record('renderer:a:default', 15, isTransport: false);

      // The HTTP acknowledgement identifies play 14 after volume 15 was
      // already received and deliberately suppressed by the local player.
      sequences.record('renderer:a:default', 14, isTransport: true);

      expect(sequences.latest('renderer:a:default'), 15);
      expect(sequences.latestTransport('renderer:a:default'), 14);
      expect(sequences.latest('renderer:a:default')! + 1, 16);
      expect(
        sequences.playbackPrecedesTransport('renderer:a:default', 14),
        isFalse,
      );
    },
  );
}
