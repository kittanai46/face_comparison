import 'package:active_face_liveness/active_face_liveness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyLiveness', () {
    test('accepts only a complete active liveness challenge', () {
      final result = classifyLiveness(
        turnOneDetected: true,
        turnTwoDetected: true,
        depthRatio: 0.02,
        minDepthRatio: 0.01,
        maxDepthRatio: 0.03,
        meshScore: 0.9,
        lightChallengePassed: true,
      );

      expect(result, LivenessClassification.realPerson);
    });

    test('rejects a photo even when face mesh confidence is high', () {
      final result = classifyLiveness(
        turnOneDetected: false,
        turnTwoDetected: false,
        depthRatio: 0.02,
        minDepthRatio: 0.01,
        maxDepthRatio: 0.03,
        meshScore: 0.99,
        lightChallengePassed: true,
      );

      expect(result, LivenessClassification.photo);
    });

    test('rejects replay when the light challenge does not respond', () {
      final result = classifyLiveness(
        turnOneDetected: true,
        turnTwoDetected: true,
        depthRatio: 0.02,
        minDepthRatio: 0.01,
        maxDepthRatio: 0.03,
        meshScore: 0.99,
        lightChallengePassed: false,
      );

      expect(result, LivenessClassification.photo);
    });

    test('rejects flat motion without coherent landmark parallax', () {
      final result = classifyLiveness(
        turnOneDetected: true,
        turnTwoDetected: true,
        depthRatio: 0.02,
        minDepthRatio: 0.01,
        maxDepthRatio: 0.03,
        meshScore: 0.99,
        lightChallengePassed: true,
        motionCoherencePassed: false,
        parallaxPassed: false,
      );

      expect(result, LivenessClassification.photo);
    });

    test('rejects an untimed or screen replay challenge', () {
      final result = classifyLiveness(
        turnOneDetected: true,
        turnTwoDetected: true,
        depthRatio: 0.02,
        minDepthRatio: 0.01,
        maxDepthRatio: 0.03,
        meshScore: 0.99,
        lightChallengePassed: true,
        timedChallengePassed: false,
        replayScreenPassed: false,
      );

      expect(result, LivenessClassification.photo);
    });

    test('rejects a replay that does not blink during the white challenge', () {
      final result = classifyLiveness(
        turnOneDetected: true,
        turnTwoDetected: true,
        depthRatio: 0.02,
        minDepthRatio: 0.01,
        maxDepthRatio: 0.03,
        meshScore: 0.99,
        lightChallengePassed: true,
        blinkChallengePassed: false,
      );

      expect(result, LivenessClassification.photo);
    });

    test('rejects illumination without multi-region temporal correlation', () {
      final result = classifyLiveness(
        turnOneDetected: true,
        turnTwoDetected: true,
        depthRatio: 0.02,
        minDepthRatio: 0.01,
        maxDepthRatio: 0.03,
        meshScore: 0.99,
        lightChallengePassed: true,
        temporalCorrelationPassed: false,
      );

      expect(result, LivenessClassification.photo);
    });

    test('rejects when the combined anti-spoof score does not pass', () {
      final result = classifyLiveness(
        turnOneDetected: true,
        turnTwoDetected: true,
        depthRatio: 0.02,
        minDepthRatio: 0.01,
        maxDepthRatio: 0.03,
        meshScore: 0.99,
        lightChallengePassed: true,
        passiveAntiSpoofPassed: false,
      );

      expect(result, LivenessClassification.photo);
    });
  });
}
