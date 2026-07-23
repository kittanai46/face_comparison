part of '../main.dart';

enum LivenessClassification { realPerson, photo }

enum _ChallengeColor { red, green, blue, white }

extension on _ChallengeColor {
  String get thaiName => switch (this) {
    _ChallengeColor.red => 'แดง',
    _ChallengeColor.green => 'เขียว',
    _ChallengeColor.blue => 'น้ำเงิน',
    _ChallengeColor.white => 'ขาว',
  };
}

class _LightPulse {
  const _LightPulse({
    required this.color,
    required this.intensity,
    required this.duration,
    required this.checkEyes,
  });

  final _ChallengeColor color;
  final double intensity;
  final Duration duration;
  final bool checkEyes;

  Color get displayColor {
    final level = (255 * intensity).round().clamp(0, 255);
    return switch (color) {
      _ChallengeColor.red => Color.fromARGB(255, level, 0, 0),
      _ChallengeColor.green => Color.fromARGB(255, 0, level, 0),
      _ChallengeColor.blue => Color.fromARGB(255, 0, 0, level),
      _ChallengeColor.white => Color.fromARGB(255, level, level, level),
    };
  }
}

class _RgbReading {
  const _RgbReading(
    this.r,
    this.g,
    this.b, {
    this.saturatedFraction = 0,
    this.highFrequencyChromaFraction = 0,
  });

  final double r;
  final double g;
  final double b;
  final double saturatedFraction;
  final double highFrequencyChromaFraction;

  double get luminance => 0.2126 * r + 0.7152 * g + 0.0722 * b;

  double channelShare(_ChallengeColor color) {
    final total = r + g + b;
    if (total <= 0) return 0;
    return switch (color) {
      _ChallengeColor.red => r / total,
      _ChallengeColor.green => g / total,
      _ChallengeColor.blue => b / total,
      _ChallengeColor.white => luminance / 255,
    };
  }
}

class _FaceRgbRegions {
  const _FaceRgbRegions(this.values);

  final List<_RgbReading> values;
}

enum _CapturedPixelFormat { bgra8888, nv12, nv21, i420 }

class _BestFaceFrame {
  const _BestFaceFrame({
    required this.width,
    required this.height,
    required this.bytes,
    required this.pixelFormat,
    required this.bytesPerRow,
    required this.rotation,
    required this.score,
    required this.sharpness,
  });

  final int width;
  final int height;
  final Uint8List bytes;
  final _CapturedPixelFormat pixelFormat;
  final int bytesPerRow;
  final CameraFrameRotation? rotation;
  final double score;
  final double sharpness;
}

class _ScanSummaryItem {
  const _ScanSummaryItem({
    required this.title,
    required this.detail,
    required this.passed,
  });

  final String title;
  final String detail;
  final bool? passed;
}

LivenessClassification classifyLiveness({
  required bool turnOneDetected,
  required bool turnTwoDetected,
  required double? depthRatio,
  required double? minDepthRatio,
  required double? maxDepthRatio,
  required double? meshScore,
  required bool lightChallengePassed,
  bool motionCoherencePassed = true,
  bool parallaxPassed = true,
  bool replayScreenPassed = true,
  bool timedChallengePassed = true,
  bool blinkChallengePassed = true,
  bool temporalCorrelationPassed = true,
  bool passiveAntiSpoofPassed = true,
}) {
  // A passive detector/mesh can also produce convincing values from a photo.
  // Never approve unless the user completed both requested head turns
  // and their face reacted to the screen illumination challenge.
  if (!turnOneDetected ||
      !turnTwoDetected ||
      !lightChallengePassed ||
      !motionCoherencePassed ||
      !parallaxPassed ||
      !replayScreenPassed ||
      !timedChallengePassed ||
      !blinkChallengePassed ||
      !temporalCorrelationPassed ||
      !passiveAntiSpoofPassed) {
    return LivenessClassification.photo;
  }

  final referenceDepth = maxDepthRatio ?? minDepthRatio ?? depthRatio;
  final depthEvidence = referenceDepth != null && referenceDepth > 0.0015;
  final meshEvidence = meshScore != null && meshScore > 0.75;
  if (depthEvidence || meshEvidence) {
    return LivenessClassification.realPerson;
  }

  return LivenessClassification.photo;
}

String livenessClassificationLabel(LivenessClassification classification) =>
    classification == LivenessClassification.realPerson ? 'คนจริง' : 'ภาพถ่าย';
