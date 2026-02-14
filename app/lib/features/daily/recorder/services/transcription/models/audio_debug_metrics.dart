/// Audio debug metrics for visualization
class AudioDebugMetrics {
  final double rawEnergy;
  final double cleanEnergy;
  final double filterReduction; // Percentage
  final double vadThreshold;
  final bool isSpeech;
  final DateTime timestamp;

  AudioDebugMetrics({
    required this.rawEnergy,
    required this.cleanEnergy,
    required this.filterReduction,
    required this.vadThreshold,
    required this.isSpeech,
    required this.timestamp,
  });
}
