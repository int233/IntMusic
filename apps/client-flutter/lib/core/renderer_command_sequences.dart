/// Tracks all renderer commands separately from transport commands.
///
/// Core can send a volume command immediately after play. The later volume
/// sequence must not make the earlier playing state look stale.
class RendererCommandSequences {
  final Map<String, int> _latestByOutput = <String, int>{};
  final Map<String, int> _latestTransportByOutput = <String, int>{};

  int? latest(String outputId) => _latestByOutput[outputId];

  int? latestTransport(String outputId) => _latestTransportByOutput[outputId];

  void record(String outputId, int sequence, {required bool isTransport}) {
    _latestByOutput[outputId] = sequence;
    if (isTransport) {
      _latestTransportByOutput[outputId] = sequence;
    }
  }

  bool playbackPrecedesTransport(String outputId, int? sequence) {
    final transport = latestTransport(outputId);
    return sequence != null && transport != null && sequence < transport;
  }

  void clear() {
    _latestByOutput.clear();
    _latestTransportByOutput.clear();
  }
}
