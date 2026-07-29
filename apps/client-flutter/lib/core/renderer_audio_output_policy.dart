/// Native audio properties used by desktop renderer players.
///
/// IntMusic currently cannot discover reliable channel capabilities for every
/// CoreAudio and WASAPI endpoint. A safe stereo output prevents uncommon
/// multichannel music files from being sent unchanged to a stereo endpoint.
class RendererAudioOutputPolicy {
  const RendererAudioOutputPolicy({
    required this.channelLayout,
    required this.normalizeDownmix,
  });

  const RendererAudioOutputPolicy.safeStereo()
    : channelLayout = 'stereo',
      normalizeDownmix = true;

  final String channelLayout;
  final bool normalizeDownmix;

  Map<String, String> get nativeProperties => <String, String>{
    'audio-channels': channelLayout,
    'audio-normalize-downmix': normalizeDownmix ? 'yes' : 'no',
  };
}

const rendererAudioOutputPolicy = RendererAudioOutputPolicy.safeStereo();
