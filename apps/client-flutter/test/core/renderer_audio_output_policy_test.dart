import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/renderer_audio_output_policy.dart';

void main() {
  test('desktop renderer defaults to normalized stereo output', () {
    expect(rendererAudioOutputPolicy.channelLayout, 'stereo');
    expect(rendererAudioOutputPolicy.normalizeDownmix, isTrue);
    expect(rendererAudioOutputPolicy.nativeProperties, <String, String>{
      'audio-channels': 'stereo',
      'audio-normalize-downmix': 'yes',
    });
  });
}
