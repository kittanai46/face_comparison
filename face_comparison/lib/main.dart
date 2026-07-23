import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:face_detection_tflite/face_detection_tflite.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_litert/flutter_litert.dart'
    show CameraFrameRotation, YuvLayout, packYuv420, rotationForFrame;
import 'package:object_detection/object_detection.dart' as od;
import 'package:permission_handler/permission_handler.dart';
import 'package:screen_brightness/screen_brightness.dart';

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

class _FaceGuidePainter extends CustomPainter {
  const _FaceGuidePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * 0.50, size.height * 0.02)
      ..cubicTo(
        size.width * 0.18,
        size.height * 0.02,
        size.width * 0.07,
        size.height * 0.24,
        size.width * 0.10,
        size.height * 0.52,
      )
      ..cubicTo(
        size.width * 0.13,
        size.height * 0.79,
        size.width * 0.34,
        size.height * 0.97,
        size.width * 0.50,
        size.height * 0.99,
      )
      ..cubicTo(
        size.width * 0.66,
        size.height * 0.97,
        size.width * 0.87,
        size.height * 0.79,
        size.width * 0.90,
        size.height * 0.52,
      )
      ..cubicTo(
        size.width * 0.93,
        size.height * 0.24,
        size.width * 0.82,
        size.height * 0.02,
        size.width * 0.50,
        size.height * 0.02,
      )
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _FaceGuidePainter oldDelegate) =>
      oldDelegate.color != color;
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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FaceComparisonApp());
}

class FaceComparisonApp extends StatelessWidget {
  const FaceComparisonApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Face Comparison',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF006C66),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F7F6),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(20)),
          ),
        ),
        useMaterial3: true,
      ),
      home: const FaceComparisonHomePage(),
    );
  }
}

class FaceComparisonHomePage extends StatefulWidget {
  const FaceComparisonHomePage({super.key});

  @override
  State<FaceComparisonHomePage> createState() => _FaceComparisonHomePageState();
}

class _FaceComparisonHomePageState extends State<FaceComparisonHomePage> {
  bool _livenessVerified = false;
  bool? _blinkDetected;
  bool? _antiSpoofPassed;
  String _scanMessage = 'กล้องกำลังเตรียมความพร้อม...';
  String _scanClassification = 'ยังไม่ทราบ';
  List<_ScanSummaryItem>? _scanSummary;
  Uint8List? _capturedFaceImage;

  /// Only the device's own front-facing camera is ever used. There is no
  /// fallback to the back camera or any other capture source.
  CameraDescription? _frontCamera;
  bool _cameraReady = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final frontCameras = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      if (!mounted) return;
      setState(() {
        if (frontCameras.isEmpty) {
          _cameraReady = false;
          _frontCamera = null;
          _scanMessage = 'ไม่พบกล้องหน้าบนอุปกรณ์นี้ ไม่สามารถสแกนใบหน้าได้';
        } else {
          _frontCamera = frontCameras.first;
          _cameraReady = true;
          _scanMessage = 'กล้องหน้าพร้อมแล้ว สามารถเริ่มสแกนได้';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cameraReady = false;
        _scanMessage = 'ไม่สามารถเข้าถึงกล้องหน้าของเครื่องได้';
      });
    }
  }

  Future<void> _startScan() async {
    if (!_cameraReady || _frontCamera == null) {
      setState(() {
        _scanMessage = 'ไม่พบกล้องหน้าบนอุปกรณ์นี้ ไม่สามารถสแกนใบหน้าได้';
      });
      return;
    }

    if (Platform.isAndroid || Platform.isIOS) {
      final cameraStatus = await Permission.camera.request();
      if (!cameraStatus.isGranted) {
        if (!mounted) return;
        setState(() {
          _scanMessage = 'กรุณาอนุญาตกล้องเพื่อเปิดหน้าสแกน';
        });
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _livenessVerified = false;
      _blinkDetected = null;
      _antiSpoofPassed = null;
      _capturedFaceImage = null;
      _scanMessage = 'กำลังตรวจสอบว่าเป็นใบหน้าจริง กรุณาทำตามคำแนะนำบนจอ';
    });

    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => LivenessCaptureView(cameraDescription: _frontCamera!),
      ),
    );

    if (!mounted) return;
    setState(() {
      final classificationLabel = result?['classificationLabel'] as String?;
      final isRealPerson = classificationLabel == 'คนจริง';
      final failureReason = result?['failureReason'] as String?;
      _livenessVerified = isRealPerson;
      final blinkAttempted = result?['blinkChallengeAttempted'] == true;
      _blinkDetected = blinkAttempted
          ? (result?['blinkDetected'] as bool?)
          : null;
      _antiSpoofPassed = result?['passiveAntiSpoofPassed'] as bool?;
      _capturedFaceImage = result?['bestFaceImage'] as Uint8List?;
      _scanClassification = classificationLabel ?? 'ยังไม่ทราบ';
      _scanMessage = isRealPerson
          ? 'ผลลัพธ์: ใบหน้าถูกจัดว่าเป็นคนจริง'
          : failureReason != null
          ? 'ยังยืนยันว่าเป็นคนจริงไม่ได้: $failureReason'
          : 'ผลลัพธ์: ใบหน้าถูกจัดว่าเป็นภาพถ่าย';

      if (result == null) {
        _scanSummary = null;
      } else {
        final firstTurnPassed = result['turnOneDetected'] == true;
        final secondTurnPassed = result['turnTwoDetected'] == true;
        final movementPassed =
            result['motionCoherencePassed'] == true &&
            result['parallaxPassed'] == true;
        final blinkPassed = result['blinkDetected'] == true;
        final lightPassed = result['lightChallengePassed'] == true;
        final temporalPassed = result['temporalCorrelationPassed'] == true;
        final matchedColors = result['matchedColorCount'] as int? ?? 0;
        final replayRisk =
            result['replayScreenPassed'] != true ||
            result['frameReplayDetected'] == true;
        final antiSpoofPassed = result['passiveAntiSpoofPassed'] == true;
        _scanSummary = [
          _ScanSummaryItem(
            title: 'ผลการยืนยัน',
            detail: classificationLabel ?? 'ยังไม่ทราบผล',
            passed: isRealPerson,
          ),
          _ScanSummaryItem(
            title: 'หันหน้าด้านแรก',
            detail: firstTurnPassed ? 'ตรวจพบแล้ว' : 'ยังไม่สำเร็จ',
            passed: firstTurnPassed,
          ),
          _ScanSummaryItem(
            title: 'หันหน้าอีกด้าน',
            detail: secondTurnPassed ? 'ตรวจพบแล้ว' : 'ยังไม่สำเร็จ',
            passed: secondTurnPassed,
          ),
          _ScanSummaryItem(
            title: 'การเคลื่อนไหวใบหน้า 3 มิติ',
            detail: movementPassed
                ? 'จมูกและแก้มเคลื่อนไหวสัมพันธ์กัน'
                : 'ยังตรวจความลึกจากการเคลื่อนไหวไม่ได้',
            passed: movementPassed,
          ),
          _ScanSummaryItem(
            title: 'การกะพริบหรือหรี่ตา',
            detail: !blinkAttempted
                ? 'ยังไม่ถึงขั้นตอนตรวจดวงตา'
                : blinkPassed
                ? 'ตรวจพบการตอบสนองของดวงตา'
                : 'ยังตรวจไม่พบการตอบสนอง',
            passed: blinkAttempted ? blinkPassed : null,
          ),
          _ScanSummaryItem(
            title: 'สีสะท้อนบนใบหน้า',
            detail: '$matchedColors/3 สี',
            passed: lightPassed,
          ),
          _ScanSummaryItem(
            title: 'แสงหลายบริเวณบนใบหน้า',
            detail: temporalPassed
                ? 'รูปแบบแสงตรงกับรหัสสุ่ม'
                : 'รูปแบบแสงยังไม่ตรงตามเกณฑ์',
            passed: temporalPassed,
          ),
          _ScanSummaryItem(
            title: 'การป้องกันภาพหรือวิดีโอ',
            detail: replayRisk
                ? 'พบสัญญาณที่อาจเป็นภาพหรือวิดีโอซ้ำ'
                : antiSpoofPassed
                ? 'ไม่พบสัญญาณการเล่นภาพซ้ำ'
                : 'ยังตรวจหลักฐานไม่ครบทุกขั้นตอน',
            passed: replayRisk ? false : (antiSpoofPassed ? true : null),
          ),
        ];
      }
    });
  }

  void _showCapturedFaceImage() {
    final imageBytes = _capturedFaceImage;
    if (imageBytes == null) return;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (dialogContext) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: SafeArea(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 5,
                  boundaryMargin: const EdgeInsets.all(80),
                  child: Center(
                    child: Image.memory(
                      imageBytes,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  color: Colors.black.withValues(alpha: 0.62),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'ภาพจากการสแกน',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'ปิด',
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: const Icon(Icons.close_rounded),
                        color: Colors.white,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 20,
              child: SafeArea(
                top: false,
                child: Text(
                  'ใช้สองนิ้วเพื่อซูมและเลื่อนภาพ',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasResult = _scanClassification != 'ยังไม่ทราบ';
    final resultColor = _livenessVerified
        ? const Color(0xFF137A52)
        : hasResult
        ? const Color(0xFFB54732)
        : colors.primary;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Face Secure',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'ความพร้อม',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              _buildStepCard(
                icon: Icons.camera_front,
                title: 'กล้องหน้า',
                subtitle: _cameraReady ? 'พร้อมใช้งาน' : 'กำลังตรวจสอบอุปกรณ์',
                isDone: _cameraReady,
              ),
              const SizedBox(height: 10),
              _buildStepCard(
                icon: Icons.remove_red_eye_outlined,
                title: 'การกะพริบตา',
                subtitle: _blinkDetected == null
                    ? 'จะตรวจแบบสุ่มระหว่างแสงสีขาว'
                    : _blinkDetected!
                    ? 'ตรวจพบลำดับตาเปิด–ปิด–เปิด'
                    : 'ยังตรวจไม่พบการกะพริบตา',
                isDone: _blinkDetected == true,
              ),
              const SizedBox(height: 10),
              _buildStepCard(
                icon: Icons.security_rounded,
                title: 'ป้องกันภาพและวิดีโอ',
                subtitle: _antiSpoofPassed == null
                    ? 'ตรวจรหัสแสงหลายจุด ความลึก และเฟรมซ้ำ'
                    : _antiSpoofPassed!
                    ? 'หลักฐานป้องกันการเล่นซ้ำผ่านเกณฑ์'
                    : 'หลักฐานป้องกันการเล่นซ้ำยังไม่ผ่าน',
                isDone: _antiSpoofPassed == true,
              ),
              const SizedBox(height: 10),
              _buildStepCard(
                icon: Icons.verified_user_outlined,
                title: 'Liveness check',
                subtitle: _livenessVerified
                    ? 'ยืนยันคนจริงสำเร็จ'
                    : 'ตรวจแสงสีและการเคลื่อนไหวใบหน้า',
                isDone: _livenessVerified,
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: resultColor.withValues(alpha: 0.08),
                  border: Border.all(
                    color: resultColor.withValues(alpha: 0.22),
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: resultColor.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _livenessVerified
                            ? Icons.check_rounded
                            : hasResult
                            ? Icons.info_outline_rounded
                            : Icons.shield_outlined,
                        color: resultColor,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasResult
                                ? 'ผลการตรวจ: $_scanClassification'
                                : 'พร้อมเริ่มตรวจสอบ',
                            style: TextStyle(
                              color: resultColor,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            _scanMessage,
                            style: const TextStyle(height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _cameraReady ? _startScan : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.face_6_outlined),
                label: Text(hasResult ? 'สแกนใหม่อีกครั้ง' : 'เริ่มสแกนใบหน้า'),
              ),
              const SizedBox(height: 12),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline, size: 15, color: Colors.black45),
                  SizedBox(width: 6),
                  Text(
                    'ประมวลผลบนอุปกรณ์ผ่านกล้องหน้าเท่านั้น',
                    style: TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ],
              ),
              if (_capturedFaceImage != null) ...[
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Semantics(
                          button: true,
                          label: 'แตะเพื่อดูภาพจากการสแกนแบบเต็มหน้าจอ',
                          child: Material(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(14),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: _showCapturedFaceImage,
                              child: SizedBox(
                                width: 120,
                                height: 160,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Image.memory(
                                      _capturedFaceImage!,
                                      fit: BoxFit.contain,
                                      filterQuality: FilterQuality.high,
                                      gaplessPlayback: true,
                                    ),
                                    Positioned(
                                      right: 8,
                                      bottom: 8,
                                      child: Container(
                                        width: 30,
                                        height: 30,
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.62,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.zoom_in_rounded,
                                          color: Colors.white,
                                          size: 19,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.photo_camera_front_outlined,
                                    size: 20,
                                    color: Color(0xFF006C66),
                                  ),
                                  SizedBox(width: 7),
                                  Expanded(
                                    child: Text(
                                      'ภาพจากการสแกน',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 7),
                              Text(
                                'เฟรมที่คมชัดที่สุดซึ่งตรวจพบว่าลืมตาและมองตรง',
                                style: TextStyle(
                                  color: Colors.black54,
                                  fontSize: 13,
                                  height: 1.35,
                                ),
                              ),
                              SizedBox(height: 7),
                              Text(
                                'แตะภาพเพื่อดูเต็มจอและซูมได้\n'
                                'เก็บชั่วคราวในหน่วยความจำเท่านั้น',
                                style: TextStyle(
                                  color: Color(0xFF137A52),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (_scanSummary != null) ...[
                const SizedBox(height: 14),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: ExpansionTile(
                    leading: const Icon(Icons.fact_check_outlined),
                    title: const Text('รายละเอียดการตรวจ'),
                    subtitle: const Text('แตะเพื่อดูผลแต่ละขั้นตอน'),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F8F7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            for (var i = 0; i < _scanSummary!.length; i++) ...[
                              _buildSummaryRow(_scanSummary![i]),
                              if (i < _scanSummary!.length - 1)
                                const Divider(height: 1, indent: 52),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryRow(_ScanSummaryItem item) {
    final color = item.passed == true
        ? const Color(0xFF137A52)
        : item.passed == false
        ? const Color(0xFFB54732)
        : const Color(0xFF667571);
    final icon = item.passed == true
        ? Icons.check_circle_rounded
        : item.passed == false
        ? Icons.cancel_rounded
        : Icons.schedule_rounded;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  item.detail,
                  style: TextStyle(color: color, fontSize: 13, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isDone,
  }) {
    final color = isDone ? const Color(0xFF137A52) : Colors.blueGrey;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE3EAE8)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
          ),
          Icon(
            isDone ? Icons.check_circle_rounded : Icons.circle_outlined,
            color: color,
          ),
        ],
      ),
    );
  }
}

enum _LivenessStep {
  farPresence,
  moveCloser,
  lightPreparing,
  lightBaseline,
  lightFlash,
  turnOne,
  turnTwo,
  success,
  failed,
}

/// Real-time liveness check built directly on `face_detection_tflite`'s raw
/// mesh/blendshape output (the same underlying signals ML Kit exposes —
/// head-turn angle and eye-open probability — computed here ourselves rather
/// than trusting an opaque third-party "spoof score").
///
/// The user must first present one face at a controlled far size, approach
/// the camera, respond to active screen illumination, and turn in both
/// directions. Mesh/depth is supporting evidence; it can never approve a
/// result without all active challenges because inferred geometry alone is
/// also available for photos.
class LivenessCaptureView extends StatefulWidget {
  const LivenessCaptureView({super.key, required this.cameraDescription});

  final CameraDescription cameraDescription;

  @override
  State<LivenessCaptureView> createState() => _LivenessCaptureViewState();
}

class _LivenessCaptureViewState extends State<LivenessCaptureView> {
  static const _turnAngleThreshold = 16.0;
  static const _neutralAngleThreshold = 8.0;
  static const _stableFramesRequired = 6;
  static const _totalTimeout = Duration(seconds: 75);
  static const _noFaceGraceFrames = 18;
  static const _farFaceMinFraction = 0.20;
  static const _farFaceMaxFraction = 0.42;
  // The colour challenge needs the phone display to illuminate a meaningful
  // portion of the skin. 39% was still too far away on many phones, especially
  // in bright rooms, so stage two now requires a genuinely close face.
  static const _nearFaceMinFraction = 0.50;
  static const _nearFaceMaxFraction = 0.90;
  static const _baselineFramesRequired = 12;
  static const _preCalibrationFramesRequired = 10;
  static const _minimumNeutralSamples = 2;
  static const _minimumColorSamples = 2;
  static const _initialNeutralDuration = Duration(milliseconds: 200);
  static const _colorPulseDuration = Duration(milliseconds: 400);
  static const _whitePulseDuration = Duration(milliseconds: 800);
  static const _lightBurstDuration = Duration(seconds: 2);
  static const _lightBurstDeadlineSlack = Duration(milliseconds: 180);
  static const _blinkClosedThreshold = 0.45;
  static const _blinkDropFromBaseline = 0.10;
  static const _minimumAcceptedEyeProbabilityDrop = 0.14;
  static const _minimumAcceptedEyeAspectDrop = 0.16;
  static const _minimumOpenEyeAspectRatio = 0.18;
  static const _minimumWhiteLumaChange = 18.0;
  static const _minimumColorShareChange = 0.008;
  static const _minimumColorOnsetChange = 0.004;
  // A white wall can have high mean luma without being a harmful light source.
  // Treat the background as backlighting only when the face itself is severely
  // underexposed; face quality, not background colour, is the decisive signal.
  static const _maximumBacklightRatio = 2.20;
  static const _minimumBrightBackgroundLuma = 210.0;
  static const _maximumBacklitFaceLuma = 80.0;
  static const _backlightFramesRequired = 6;
  static const _backlightRecoveryFramesRequired = 3;
  static const _maximumBaselineLuma = 210.0;
  static const _maximumBaselineSaturation = 0.16;
  static const _maximumFlashLuma = 242.0;
  static const _maximumFlashSaturation = 0.48;
  static const _maximumHighFrequencyChroma = 0.30;
  static const _nearStageMediaFramesRequired = 6;
  static const _screenArtifactFramesRequired = 8;
  static const _minimumParallaxDelta = 0.018;
  static const _minimumPoseLandmarkOffset = 0.008;
  static const _parallaxSamplesRequired = 5;
  static const _capturedFrameLongEdge = 800;
  static const _minimumCaptureEyeOpen = 0.58;
  static const _minimumCaptureEyeAspect = 0.19;
  static const _maximumCaptureYaw = 12.0;
  static const _maximumCapturePitch = 15.0;
  static const _maximumCaptureRoll = 12.0;
  static const _minimumColorOnset = Duration(milliseconds: 25);
  static const _maximumColorOnset = Duration(seconds: 2);

  CameraController? _cameraController;
  FaceDetector? _faceDetector;
  od.ObjectDetector? _objectDetector;

  _LivenessStep _step = _LivenessStep.farPresence;
  String _instruction = 'ยืนห่างจากกล้อง แล้วจัดศีรษะให้อยู่ในกรอบเล็ก';
  String _depthReadout = '';

  bool _busy = false;
  bool _finished = false;
  bool _detectorReady = false;
  bool _detectorInitInProgress = false;
  bool _detectorInitFailed = false;
  bool _initializationFailed = false;
  int _stableFrameCount = 0;
  double _firstTurnSign = 0;
  int _noFaceFrames = 0;
  int _objectScanFrame = 0;
  List<od.DetectedObject> _latestObjects = const [];
  int _suspiciousObjectFrames = 0;
  int _cleanObjectFrames = 0;
  int _screenArtifactFrames = 0;
  int _frameProcessingErrors = 0;
  int _totalFrameProcessingErrors = 0;
  bool _suspiciousObjectActive = false;
  String? _suspiciousObjectLabel;
  Timer? _timeoutTimer;
  Timer? _lightBurstDeadlineTimer;

  bool _turnOneDetected = false;
  bool _turnTwoDetected = false;
  double? _lastDepthRatio;
  double? _minDepthRatio;
  double? _maxDepthRatio;
  double? _lastMeshScore;
  final List<_RgbReading> _baselineRgb = [];
  final List<_RgbReading> _preCalibrationRgb = [];
  final List<_RgbReading> _neutralColorSamples = [];
  final List<List<_RgbReading>> _neutralRegionSamples = List.generate(
    4,
    (_) => <_RgbReading>[],
  );
  final List<_RgbReading> _colorSamples = [];
  final List<List<_RgbReading>> _colorRegionSamples = List.generate(
    4,
    (_) => <_RgbReading>[],
  );
  final List<_RgbReading> _pulseReadings = [];
  final List<_RgbReading> _pulseBaselines = [];
  late final List<_LightPulse> _challengePulses;
  _RgbReading? _currentPulseBaseline;
  List<_RgbReading>? _currentRegionBaselines;
  final List<List<_RgbReading>> _pulseRegionBaselines = [];
  final List<List<_RgbReading>> _pulseRegionReadings = [];
  List<double> _regionCorrelationScores = const [];
  bool _temporalCorrelationPassed = false;
  final List<int> _faceFrameHashes = [];
  double _frameUniquenessScore = 0;
  bool _frameReplayDetected = false;
  double? _passiveAntiSpoofScore;
  bool _passiveAntiSpoofPassed = false;
  int _challengeIndex = 0;
  int _flashSettlingFrames = 0;
  bool _flashNeutralPhase = true;
  Duration? _currentColorOnset;
  double? _lightResponse;
  double? _lightResponseMagnitude;
  int _matchedColorCount = 0;
  double? _lastBacklightRatio;
  double? _latestFaceLuma;
  bool _lightChallengePassed = false;
  bool _blinkChallengePassed = false;
  bool _blinkChallengeAttempted = false;
  bool _whiteReflectionPassed = false;
  bool _blinkSawClosed = false;
  bool _eyeResponseArmed = false;
  double? _whiteEyeOpenBaseline;
  double? _whiteEyeAspectBaseline;
  double _maximumEyeProbabilityDrop = 0;
  double _maximumEyeAspectDrop = 0;
  final List<double> _whiteEyeBaselineSamples = [];
  final List<double> _whiteEyeAspectBaselineSamples = [];
  bool _timedChallengePassed = false;
  bool _motionCoherencePassed = false;
  bool _parallaxPassed = false;
  bool _replayScreenPassed = true;
  double? _firstTurnParallax;
  double? _secondTurnParallax;
  final List<double> _neutralParallaxSamples = [];
  final List<double> _firstTurnParallaxSamples = [];
  final List<double> _secondTurnParallaxSamples = [];
  bool _turnNeutralReady = false;
  DateTime? _lightBurstStartedAt;
  DateTime? _flashStartedAt;
  DateTime? _neutralStartedAt;
  final List<Duration> _flashResponseTimes = [];
  double _calibratedBaselineMaxLuma = _maximumBaselineLuma;
  double _calibratedFlashMaxLuma = _maximumFlashLuma;
  bool _lightCalibrated = false;
  bool _screenTextureSuspected = false;
  late final String _cameraProfile;
  bool _brightnessOverridden = false;
  bool _distanceWarningActive = false;
  bool _backlightWarningActive = false;
  int _backlightFrames = 0;
  int _backlightRecoveryFrames = 0;
  bool _faceWarningActive = false;
  String? _failureReason;
  _BestFaceFrame? _bestFaceFrame;

  @override
  void initState() {
    super.initState();
    _challengePulses = _createChallengePulses();
    _cameraProfile = widget.cameraDescription.name.trim().isEmpty
        ? 'front-camera-default'
        : widget.cameraDescription.name;
    _initialize();
    _timeoutTimer = Timer(
      _totalTimeout,
      () => _fail('หมดเวลาการสแกน กรุณาลองใหม่อีกครั้ง'),
    );
  }

  List<_LightPulse> _createChallengePulses() {
    final random = Random.secure();
    final colors = <_ChallengeColor>[
      _ChallengeColor.red,
      _ChallengeColor.green,
      _ChallengeColor.blue,
      _ChallengeColor.white,
    ]..shuffle(random);
    final eyePulseIndex = colors.indexOf(_ChallengeColor.white);
    return [
      for (var i = 0; i < colors.length; i++)
        _LightPulse(
          color: colors[i],
          intensity: 1.0,
          duration: i == eyePulseIndex
              ? _whitePulseDuration
              : _colorPulseDuration,
          checkEyes: i == eyePulseIndex,
        ),
    ];
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _lightBurstDeadlineTimer?.cancel();
    unawaited(_restoreScreenBrightness());
    _cameraController?.dispose();
    _faceDetector?.dispose();
    _objectDetector?.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final controller = CameraController(
        widget.cameraDescription,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.bgra8888,
      );

      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      try {
        await controller.setFocusMode(FocusMode.auto);
        await controller.setExposureMode(ExposureMode.auto);
      } catch (error) {
        // Some front cameras are fixed-focus. Continue with the device default
        // instead of failing the liveness flow.
        debugPrint('Unable to enable automatic capture focus: $error');
      }

      if (mounted) {
        setState(() {
          _cameraController = controller;
          _instruction = 'กล้องเปิดอยู่แล้ว กำลังเตรียมระบบตรวจจับใบหน้า...';
        });
      }

      await controller.startImageStream(_processCameraImage);
      unawaited(_initializeDetector());
    } catch (e, st) {
      debugPrint('Camera initialization failed: $e');
      debugPrint('$st');
      if (mounted) {
        setState(() {
          _initializationFailed = true;
          _instruction = 'ไม่สามารถเปิดกล้องได้ กรุณาลองใหม่อีกครั้ง';
        });
      }
    }
  }

  Future<void> _initializeDetector() async {
    if (_detectorInitInProgress || _finished) return;
    _detectorInitInProgress = true;
    _detectorInitFailed = false;
    if (mounted) {
      setState(() {
        _instruction = 'กำลังเตรียมโมเดลตรวจใบหน้า...';
      });
    }

    try {
      if (_faceDetector == null) {
        final detector = await _createFaceDetectorWithRetry();
        if (!mounted) {
          await detector.dispose();
          return;
        }
        _faceDetector = detector;
      }

      setState(() {
        _instruction = 'ตรวจใบหน้าพร้อมแล้ว กำลังเตรียมโมเดลตรวจวัตถุ...';
      });

      if (_objectDetector == null) {
        try {
          _objectDetector = await od.ObjectDetector.create();
        } catch (e, st) {
          debugPrint('Object detector default initialization failed: $e');
          debugPrint('$st');
          if (mounted) {
            setState(() {
              _instruction = 'กำลังลองเปิดตัวตรวจวัตถุด้วยโหมด CPU...';
            });
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
          _objectDetector = await od.ObjectDetector.create(
            performanceConfig: od.PerformanceConfig.disabled,
          );
        }
      }

      if (!mounted) {
        await _objectDetector?.dispose();
        _objectDetector = null;
        return;
      }
      setState(() {
        _detectorReady = true;
        _instruction =
            'ระบบตรวจใบหน้าและวัตถุพร้อมแล้ว กรุณาจัดใบหน้าให้ตรงกรอบ';
      });
    } catch (e, st) {
      debugPrint('Detector initialization failed: $e');
      debugPrint('$st');
      if (mounted) {
        setState(() {
          _detectorReady = false;
          _detectorInitFailed = true;
          _instruction = _faceDetector == null
              ? 'เปิดโมเดลตรวจใบหน้าไม่สำเร็จ กรุณากดลองใหม่'
              : 'เปิดโมเดลตรวจวัตถุไม่สำเร็จ กรุณากดลองใหม่';
        });
      }
    } finally {
      _detectorInitInProgress = false;
      if (mounted) setState(() {});
    }
  }

  Future<FaceDetector> _createFaceDetectorWithRetry() async {
    Future<FaceDetector> create() => FaceDetector.create(
      model: FaceDetectionModel.frontCamera,
      minScore: 0.5,
      minFaceSize: 0.08,
    );

    try {
      return await create();
    } catch (e, st) {
      debugPrint('Face detector first initialization failed: $e');
      debugPrint('$st');
      if (mounted) {
        setState(() {
          _instruction = 'เปิดตัวตรวจใบหน้าครั้งแรกไม่สำเร็จ กำลังลองใหม่...';
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
      return create();
    }
  }

  Future<void> _finish(bool success) async {
    if (_finished) return;
    _finished = true;
    _timeoutTimer?.cancel();
    _lightBurstDeadlineTimer?.cancel();
    unawaited(_restoreScreenBrightness());
    _cameraController?.stopImageStream().catchError((_) {});

    final classification = classifyLiveness(
      turnOneDetected: _turnOneDetected,
      turnTwoDetected: _turnTwoDetected,
      depthRatio: _lastDepthRatio,
      minDepthRatio: _minDepthRatio,
      maxDepthRatio: _maxDepthRatio,
      meshScore: _lastMeshScore,
      lightChallengePassed: _lightChallengePassed,
      motionCoherencePassed: _motionCoherencePassed,
      parallaxPassed: _parallaxPassed,
      replayScreenPassed: _replayScreenPassed,
      timedChallengePassed: _timedChallengePassed,
      blinkChallengePassed: _blinkChallengePassed,
      temporalCorrelationPassed: _temporalCorrelationPassed,
      passiveAntiSpoofPassed: _passiveAntiSpoofPassed,
    );
    final isLive =
        success && classification == LivenessClassification.realPerson;
    final bestFrameSize = _bestFaceFrame == null
        ? null
        : _capturedFrameOutputSize(_bestFaceFrame!);
    final bestFaceImage = await _encodeBestFaceImage();
    if (!mounted) return;

    Navigator.pop(context, {
      'isLive': isLive,
      'classification': classification.name,
      'classificationLabel': livenessClassificationLabel(classification),
      'turnOneDetected': _turnOneDetected,
      'turnTwoDetected': _turnTwoDetected,
      'lastDepthRatio': _lastDepthRatio?.toStringAsFixed(3),
      'minDepthRatio': _minDepthRatio?.toStringAsFixed(3),
      'maxDepthRatio': _maxDepthRatio?.toStringAsFixed(3),
      'meshScore': _lastMeshScore?.toStringAsFixed(3),
      'lightResponse': _lightResponse?.toStringAsFixed(1),
      'lightResponseMagnitude': _lightResponseMagnitude?.toStringAsFixed(1),
      'matchedColorCount': _matchedColorCount,
      'backlightRatio': _lastBacklightRatio?.toStringAsFixed(2),
      'lightChallengePassed': _lightChallengePassed,
      'blinkDetected': _blinkChallengePassed,
      'blinkChallengeAttempted': _blinkChallengeAttempted,
      'whiteReflectionPassed': _whiteReflectionPassed,
      'eyeProbabilityDrop': _maximumEyeProbabilityDrop.toStringAsFixed(3),
      'eyeAspectDrop': _maximumEyeAspectDrop.toStringAsFixed(3),
      'motionCoherencePassed': _motionCoherencePassed,
      'parallaxPassed': _parallaxPassed,
      'timedChallengePassed': _timedChallengePassed,
      'replayScreenPassed': _replayScreenPassed,
      'screenTextureSuspected': _screenTextureSuspected,
      'temporalCorrelationPassed': _temporalCorrelationPassed,
      'regionCorrelationScores': _regionCorrelationScores
          .map((score) => score.toStringAsFixed(3))
          .join(','),
      'frameUniquenessScore': _frameUniquenessScore.toStringAsFixed(3),
      'frameReplayDetected': _frameReplayDetected,
      'passiveAntiSpoofScore': _passiveAntiSpoofScore?.toStringAsFixed(3),
      'passiveAntiSpoofPassed': _passiveAntiSpoofPassed,
      'lightChallengeCode': _challengePulses
          .map(
            (pulse) =>
                '${pulse.color.name[0].toUpperCase()}${(pulse.intensity * 100).round()}-${pulse.duration.inMilliseconds}${pulse.checkEyes ? "E" : ""}',
          )
          .join(','),
      'rgbOnsetMs': _flashResponseTimes
          .map((value) => value.inMilliseconds)
          .join(','),
      'calibratedBaselineMaxLuma': _calibratedBaselineMaxLuma.toStringAsFixed(
        1,
      ),
      'frameProcessingErrors': _totalFrameProcessingErrors,
      'cameraProfile': _cameraProfile,
      'failureReason': _failureReason,
      'bestFaceImage': bestFaceImage,
      'bestFaceSharpness': _bestFaceFrame?.sharpness.toStringAsFixed(2),
      'bestFaceResolution': bestFrameSize == null
          ? null
          : '${bestFrameSize.width}x${bestFrameSize.height}',
    });
  }

  void _fail(String message) {
    if (_finished || !mounted) return;
    _failureReason = message;
    setState(() {
      _step = _LivenessStep.failed;
      _instruction = message;
    });
    unawaited(_finish(false));
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_busy || _finished || _faceDetector == null) return;
    _busy = true;
    try {
      final rotation = rotationForFrame(
        width: image.width,
        height: image.height,
        sensorOrientation: widget.cameraDescription.sensorOrientation,
        isFrontCamera: true,
        deviceOrientation:
            _cameraController?.value.deviceOrientation ??
            DeviceOrientation.portraitUp,
      );
      final shouldScanObjects = switch (_step) {
        _LivenessStep.lightBaseline || _LivenessStep.lightFlash => false,
        _ => true,
      };
      var didScanObjects = false;
      if (shouldScanObjects &&
          _objectDetector != null &&
          _objectScanFrame++ % 4 == 0) {
        _latestObjects = await _objectDetector!.detectFromCameraImage(
          image,
          rotation: rotation,
          options: const od.ObjectDetectorOptions(
            scoreThreshold: 0.42,
            maxResults: 8,
          ),
          maxDim: 640,
        );
        didScanObjects = true;
      }
      final faces = await _faceDetector!.detectFacesFromCameraImage(
        image,
        mode: FaceDetectionMode.full,
        rotation: rotation,
      );
      final rawFaceRoi = faces.length == 1
          ? _faceRoiInRawFrame(faces.first, rotation)
          : null;
      final centerRgb = rawFaceRoi == null
          ? null
          : _sampleFaceRgb(image, rawFaceRoi);
      final faceRegions = rawFaceRoi == null
          ? null
          : _sampleFaceRegions(image, rawFaceRoi);
      final faceHash = rawFaceRoi == null
          ? null
          : _perceptualFaceHash(image, rawFaceRoi);
      if (faceHash != null) _recordFaceFrameHash(faceHash);
      final backgroundLuma = _backgroundLuminance(image, rawFaceRoi);
      if (didScanObjects) _evaluateSuspiciousObjects(_latestObjects, faces);
      if (faces.length == 1 && rawFaceRoi != null && centerRgb != null) {
        _considerBestFaceFrame(
          image,
          faces.first,
          rotation,
          rawFaceRoi,
          centerRgb,
        );
      }
      _evaluateFaces(faces, centerRgb, backgroundLuma, faceRegions);
      _frameProcessingErrors = 0;
    } catch (error, stackTrace) {
      _frameProcessingErrors++;
      _totalFrameProcessingErrors++;
      debugPrint('Frame processing error #$_frameProcessingErrors: $error');
      debugPrint('$stackTrace');
      if (_frameProcessingErrors >= 12 && mounted && !_finished) {
        _fail('ระบบประมวลผลภาพผิดพลาดต่อเนื่อง กรุณาเริ่มสแกนใหม่');
      }
    } finally {
      _busy = false;
    }
  }

  void _evaluateSuspiciousObjects(
    List<od.DetectedObject> objects,
    List<Face> faces,
  ) {
    const presentationMedia = {'cell phone', 'tv', 'laptop', 'book'};
    if (faces.length != 1) return;
    final faceBox = faces.first.boundingBox;
    od.DetectedObject? suspicious;
    for (final object in objects) {
      final box = object.boundingBox;
      final intersectionWidth = max(
        0.0,
        min(box.topRight.x, faceBox.right) - max(box.topLeft.x, faceBox.left),
      );
      final intersectionHeight = max(
        0.0,
        min(box.bottomLeft.y, faceBox.bottom) - max(box.topLeft.y, faceBox.top),
      );
      final faceArea = max(1.0, faceBox.width * faceBox.height);
      final objectArea = max(1.0, box.width * box.height);
      final faceCoverage = intersectionWidth * intersectionHeight / faceArea;
      final extendsBeyondFace =
          box.topLeft.x < faceBox.left - faceBox.width * 0.06 &&
          box.topRight.x > faceBox.right + faceBox.width * 0.06 &&
          box.topLeft.y < faceBox.top - faceBox.height * 0.06 &&
          box.bottomLeft.y > faceBox.bottom + faceBox.height * 0.06;
      final hasReplayGeometry =
          faceCoverage >= 0.72 &&
          objectArea >= faceArea * 1.18 &&
          extendsBeyondFace;
      final minimumScore = _step == _LivenessStep.farPresence ? 0.48 : 0.60;
      if (hasReplayGeometry &&
          object.score >= minimumScore &&
          presentationMedia.contains(object.categoryName.toLowerCase())) {
        suspicious = object;
        break;
      }
    }
    if (suspicious != null) {
      _suspiciousObjectFrames++;
      _cleanObjectFrames = 0;
      _suspiciousObjectLabel = suspicious.categoryName;
    } else {
      _suspiciousObjectFrames = max(0, _suspiciousObjectFrames - 1);
      if (_suspiciousObjectFrames == 0) {
        _suspiciousObjectLabel = null;
        _cleanObjectFrames = min(3, _cleanObjectFrames + 1);
      }
    }
    final requiredFrames = _step == _LivenessStep.farPresence
        ? 2
        : _nearStageMediaFramesRequired;
    _suspiciousObjectActive = _suspiciousObjectFrames >= requiredFrames;
    if (_suspiciousObjectActive && _step != _LivenessStep.farPresence) {
      _replayScreenPassed = false;
      _fail('ตรวจพบอุปกรณ์แสดงภาพใกล้ใบหน้า กรุณานำโทรศัพท์ จอ หรือรูปภาพออก');
    }
  }

  /// Maps the detector's upright face box back to normalized raw-camera
  /// coordinates. This invisible ROI follows the detected face every frame.
  Offset _uprightToRawPoint(Offset point, CameraFrameRotation? rotation) =>
      switch (rotation) {
        CameraFrameRotation.cw90 => Offset(point.dy, 1 - point.dx),
        CameraFrameRotation.cw180 => Offset(1 - point.dx, 1 - point.dy),
        CameraFrameRotation.cw270 => Offset(1 - point.dy, point.dx),
        null => point,
      };

  Rect _faceRoiInRawFrame(Face face, CameraFrameRotation? rotation) {
    final size = face.originalSize;
    final box = face.boundingBox;
    final upright = Rect.fromLTRB(
      box.left / size.width,
      box.top / size.height,
      box.right / size.width,
      box.bottom / size.height,
    );

    final points = [
      _uprightToRawPoint(upright.topLeft, rotation),
      _uprightToRawPoint(upright.topRight, rotation),
      _uprightToRawPoint(upright.bottomLeft, rotation),
      _uprightToRawPoint(upright.bottomRight, rotation),
    ];
    final left = points.map((p) => p.dx).reduce(min).clamp(0.0, 1.0);
    final top = points.map((p) => p.dy).reduce(min).clamp(0.0, 1.0);
    final right = points.map((p) => p.dx).reduce(max).clamp(0.0, 1.0);
    final bottom = points.map((p) => p.dy).reduce(max).clamp(0.0, 1.0);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  double? _cameraPixelLuma(CameraImage image, int x, int y) {
    if (image.planes.isEmpty) return null;
    if (image.planes.length >= 3) {
      final plane = image.planes.first;
      final index = y * plane.bytesPerRow + x * (plane.bytesPerPixel ?? 1);
      if (index < 0 || index >= plane.bytes.length) return null;
      return plane.bytes[index].toDouble();
    }
    final plane = image.planes.first;
    final stride = plane.bytesPerPixel ?? 4;
    final index = y * plane.bytesPerRow + x * stride;
    if (index < 0 || index + 2 >= plane.bytes.length) return null;
    final b = plane.bytes[index];
    final g = plane.bytes[index + 1];
    final r = plane.bytes[index + 2];
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  double? _captureSharpness(CameraImage image, Rect rawFaceRoi) {
    const longAxisSamples = 40;
    final roiPixelWidth = rawFaceRoi.width * image.width;
    final roiPixelHeight = rawFaceRoi.height * image.height;
    if (roiPixelWidth < 2 || roiPixelHeight < 2) return null;
    final columns = roiPixelWidth >= roiPixelHeight
        ? longAxisSamples
        : (longAxisSamples * roiPixelWidth / roiPixelHeight).round().clamp(
            20,
            longAxisSamples,
          );
    final rows = roiPixelHeight >= roiPixelWidth
        ? longAxisSamples
        : (longAxisSamples * roiPixelHeight / roiPixelWidth).round().clamp(
            20,
            longAxisSamples,
          );
    final lumaGrid = List.generate(
      rows,
      (_) => List<double>.filled(columns, double.nan),
    );
    for (var row = 0; row < rows; row++) {
      final fy = 0.12 + (row + 0.5) * 0.76 / rows;
      final y = ((rawFaceRoi.top + rawFaceRoi.height * fy) * image.height)
          .floor()
          .clamp(0, image.height - 1);
      for (var column = 0; column < columns; column++) {
        final fx = 0.12 + (column + 0.5) * 0.76 / columns;
        final x = ((rawFaceRoi.left + rawFaceRoi.width * fx) * image.width)
            .floor()
            .clamp(0, image.width - 1);
        final luma = _cameraPixelLuma(image, x, y);
        if (luma != null) lumaGrid[row][column] = luma;
      }
    }

    var laplacianEnergy = 0.0;
    var gradientEnergy = 0.0;
    var sampleCount = 0;
    for (var row = 1; row < rows - 1; row++) {
      for (var column = 1; column < columns - 1; column++) {
        final center = lumaGrid[row][column];
        final left = lumaGrid[row][column - 1];
        final right = lumaGrid[row][column + 1];
        final above = lumaGrid[row - 1][column];
        final below = lumaGrid[row + 1][column];
        if (center.isNaN ||
            left.isNaN ||
            right.isNaN ||
            above.isNaN ||
            below.isNaN) {
          continue;
        }
        final laplacian = 4 * center - left - right - above - below;
        final horizontalGradient = right - left;
        final verticalGradient = below - above;
        laplacianEnergy += laplacian * laplacian;
        gradientEnergy +=
            horizontalGradient * horizontalGradient +
            verticalGradient * verticalGradient;
        sampleCount++;
      }
    }
    if (sampleCount == 0) return null;
    final laplacianRms = sqrt(laplacianEnergy / sampleCount);
    final gradientRms = sqrt(gradientEnergy / sampleCount);
    // Laplacian energy responds strongly to focus blur; the smaller gradient
    // component stabilizes the score on naturally smooth skin.
    return laplacianRms * 0.78 + gradientRms * 0.22;
  }

  ({Uint8List bytes, _CapturedPixelFormat pixelFormat, int bytesPerRow})?
  _copyCameraPixels(CameraImage image) {
    if (image.planes.isEmpty) return null;
    final firstPlane = image.planes.first;
    if (image.format.group == ImageFormatGroup.bgra8888 ||
        (image.planes.length == 1 && (firstPlane.bytesPerPixel ?? 0) >= 4)) {
      return (
        bytes: Uint8List.fromList(firstPlane.bytes),
        pixelFormat: _CapturedPixelFormat.bgra8888,
        bytesPerRow: firstPlane.bytesPerRow,
      );
    }
    if (image.format.group == ImageFormatGroup.nv21 &&
        image.planes.length == 1) {
      return (
        bytes: Uint8List.fromList(firstPlane.bytes),
        pixelFormat: _CapturedPixelFormat.nv21,
        bytesPerRow: image.width,
      );
    }
    if (image.planes.length < 2) return null;
    final packed = packYuv420(
      width: image.width,
      height: image.height,
      y: (
        bytes: image.planes[0].bytes,
        rowStride: image.planes[0].bytesPerRow,
        pixelStride: image.planes[0].bytesPerPixel ?? 1,
      ),
      u: (
        bytes: image.planes[1].bytes,
        rowStride: image.planes[1].bytesPerRow,
        pixelStride: image.planes[1].bytesPerPixel ?? 1,
      ),
      v: image.planes.length > 2
          ? (
              bytes: image.planes[2].bytes,
              rowStride: image.planes[2].bytesPerRow,
              pixelStride: image.planes[2].bytesPerPixel ?? 1,
            )
          : null,
    );
    if (packed == null) return null;
    final pixelFormat = switch (packed.layout) {
      YuvLayout.nv12 => _CapturedPixelFormat.nv12,
      YuvLayout.nv21 => _CapturedPixelFormat.nv21,
      YuvLayout.i420 => _CapturedPixelFormat.i420,
    };
    return (
      bytes: packed.bytes,
      pixelFormat: pixelFormat,
      bytesPerRow: packed.width,
    );
  }

  void _considerBestFaceFrame(
    CameraImage image,
    Face face,
    CameraFrameRotation? rotation,
    Rect rawFaceRoi,
    _RgbReading faceRgb,
  ) {
    if (_finished ||
        _suspiciousObjectActive ||
        _step == _LivenessStep.farPresence ||
        _step == _LivenessStep.lightFlash ||
        _step == _LivenessStep.success ||
        _step == _LivenessStep.failed) {
      return;
    }

    final leftEye = face.leftEyeOpenProbability;
    final rightEye = face.rightEyeOpenProbability;
    final probabilityEyesOpen =
        leftEye != null &&
        rightEye != null &&
        min(leftEye, rightEye) >= _minimumCaptureEyeOpen;
    final eyeAspect = _eyeAspectRatio(face);
    final aspectEyesOpen =
        eyeAspect != null && eyeAspect >= _minimumCaptureEyeAspect;
    if (!probabilityEyesOpen && !aspectEyesOpen) return;

    final yaw = face.headEulerAngleY?.abs() ?? 0.0;
    final pitch = face.headEulerAngleX?.abs() ?? 0.0;
    final roll = face.headEulerAngleZ?.abs() ?? 0.0;
    if (yaw > _maximumCaptureYaw ||
        pitch > _maximumCapturePitch ||
        roll > _maximumCaptureRoll ||
        face.widthFraction < 0.38 ||
        face.widthFraction > _nearFaceMaxFraction ||
        faceRgb.luminance < 45 ||
        faceRgb.luminance > 232 ||
        faceRgb.saturatedFraction > 0.28) {
      return;
    }

    final sharpness = _captureSharpness(image, rawFaceRoi);
    if (sharpness == null) return;
    final sharpnessScore = 1 - exp(-sharpness / 24);
    final poseScore =
        1 -
        (yaw / _maximumCaptureYaw * 0.50 +
                pitch / _maximumCapturePitch * 0.30 +
                roll / _maximumCaptureRoll * 0.20)
            .clamp(0.0, 1.0);
    final probabilityScore = leftEye == null || rightEye == null
        ? 0.0
        : min(leftEye, rightEye).clamp(0.0, 1.0);
    final aspectScore = eyeAspect == null
        ? 0.0
        : ((eyeAspect - 0.12) / 0.16).clamp(0.0, 1.0);
    final eyeScore = max(probabilityScore, aspectScore);
    final exposureScore = (1 - (faceRgb.luminance - 138).abs() / 120).clamp(
      0.0,
      1.0,
    );
    final sizeScore = (face.widthFraction / 0.62).clamp(0.0, 1.0);
    final meshScore = (face.meshScore ?? 0.0).clamp(0.0, 1.0);
    final score =
        sharpnessScore * 0.76 +
        poseScore * 0.08 +
        eyeScore * 0.06 +
        exposureScore * 0.06 +
        sizeScore * 0.03 +
        meshScore * 0.01;
    final current = _bestFaceFrame;
    if (current != null) {
      final meaningfulSharpnessGain = max(0.30, current.sharpness * 0.015);
      final isMeaningfullySharper =
          sharpness >= current.sharpness + meaningfulSharpnessGain;
      final isSimilarButBetterOverall =
          sharpness >= current.sharpness * 0.985 &&
          score >= current.score + 0.008;
      if (!isMeaningfullySharper && !isSimilarButBetterOverall) return;
    }
    final copiedPixels = _copyCameraPixels(image);
    if (copiedPixels == null) return;

    _bestFaceFrame = _BestFaceFrame(
      width: image.width,
      height: image.height,
      bytes: copiedPixels.bytes,
      pixelFormat: copiedPixels.pixelFormat,
      bytesPerRow: copiedPixels.bytesPerRow,
      rotation: rotation,
      score: score,
      sharpness: sharpness,
    );
  }

  ({int width, int height}) _capturedFrameOutputSize(_BestFaceFrame frame) {
    final swapsAxes =
        frame.rotation == CameraFrameRotation.cw90 ||
        frame.rotation == CameraFrameRotation.cw270;
    final uprightWidth = swapsAxes ? frame.height : frame.width;
    final uprightHeight = swapsAxes ? frame.width : frame.height;
    final longEdge = max(uprightWidth, uprightHeight);
    final scale = min(1.0, _capturedFrameLongEdge / longEdge);
    return (
      width: max(1, (uprightWidth * scale).round()),
      height: max(1, (uprightHeight * scale).round()),
    );
  }

  ({Uint8List pixels, int width, int height}) _renderCapturedFrame(
    _BestFaceFrame frame,
  ) {
    final outputSize = _capturedFrameOutputSize(frame);
    final output = Uint8List(outputSize.width * outputSize.height * 4);
    for (var outputY = 0; outputY < outputSize.height; outputY++) {
      final uprightY = (outputY + 0.5) / outputSize.height;
      for (var outputX = 0; outputX < outputSize.width; outputX++) {
        // Mirror the complete front-camera frame so it matches the preview.
        final uprightX = 1 - (outputX + 0.5) / outputSize.width;
        final rawPoint = _uprightToRawPoint(
          Offset(uprightX, uprightY),
          frame.rotation,
        );
        final rawX = (rawPoint.dx * frame.width).floor().clamp(
          0,
          frame.width - 1,
        );
        final rawY = (rawPoint.dy * frame.height).floor().clamp(
          0,
          frame.height - 1,
        );
        var red = 0;
        var green = 0;
        var blue = 0;
        switch (frame.pixelFormat) {
          case _CapturedPixelFormat.bgra8888:
            final index = rawY * frame.bytesPerRow + rawX * 4;
            if (index + 2 < frame.bytes.length) {
              blue = frame.bytes[index];
              green = frame.bytes[index + 1];
              red = frame.bytes[index + 2];
            }
          case _CapturedPixelFormat.nv12 || _CapturedPixelFormat.nv21:
            final yIndex = rawY * frame.bytesPerRow + rawX;
            if (yIndex >= frame.bytes.length) break;
            final luminance = frame.bytes[yIndex];
            // Always retain a visible luma fallback. If a device exposes an
            // unusual/truncated chroma plane, the image becomes grayscale
            // instead of an all-black rectangle.
            red = luminance;
            green = luminance;
            blue = luminance;
            final ySize = frame.width * frame.height;
            final uvIndex = ySize + (rawY ~/ 2) * frame.width + (rawX ~/ 2) * 2;
            if (uvIndex + 1 >= frame.bytes.length) break;
            final firstChroma = frame.bytes[uvIndex] - 128.0;
            final secondChroma = frame.bytes[uvIndex + 1] - 128.0;
            final u = frame.pixelFormat == _CapturedPixelFormat.nv12
                ? firstChroma
                : secondChroma;
            final v = frame.pixelFormat == _CapturedPixelFormat.nv12
                ? secondChroma
                : firstChroma;
            final adjustedY = max(0.0, luminance - 16.0) * 1.164;
            red = (adjustedY + 1.596 * v).round().clamp(0, 255);
            green = (adjustedY - 0.392 * u - 0.813 * v).round().clamp(0, 255);
            blue = (adjustedY + 2.017 * u).round().clamp(0, 255);
          case _CapturedPixelFormat.i420:
            final yIndex = rawY * frame.bytesPerRow + rawX;
            if (yIndex >= frame.bytes.length) break;
            final luminance = frame.bytes[yIndex];
            red = luminance;
            green = luminance;
            blue = luminance;
            final ySize = frame.width * frame.height;
            final uvWidth = frame.width ~/ 2;
            final uvHeight = frame.height ~/ 2;
            final uvX = rawX ~/ 2;
            final uvY = rawY ~/ 2;
            final uIndex = ySize + uvY * uvWidth + uvX;
            final vIndex = ySize + uvWidth * uvHeight + uvY * uvWidth + uvX;
            if (uIndex >= frame.bytes.length || vIndex >= frame.bytes.length) {
              break;
            }
            final u = frame.bytes[uIndex] - 128.0;
            final v = frame.bytes[vIndex] - 128.0;
            final adjustedY = max(0.0, luminance - 16.0) * 1.164;
            red = (adjustedY + 1.596 * v).round().clamp(0, 255);
            green = (adjustedY - 0.392 * u - 0.813 * v).round().clamp(0, 255);
            blue = (adjustedY + 2.017 * u).round().clamp(0, 255);
        }
        final outputIndex = (outputY * outputSize.width + outputX) * 4;
        output[outputIndex] = red;
        output[outputIndex + 1] = green;
        output[outputIndex + 2] = blue;
        output[outputIndex + 3] = 255;
      }
    }
    return (pixels: output, width: outputSize.width, height: outputSize.height);
  }

  bool _capturedFacePixelsAreUsable(Uint8List pixels) {
    var lumaSum = 0.0;
    var sampled = 0;
    var visible = 0;
    for (var index = 0; index + 2 < pixels.length; index += 64) {
      final luma =
          0.2126 * pixels[index] +
          0.7152 * pixels[index + 1] +
          0.0722 * pixels[index + 2];
      lumaSum += luma;
      if (luma >= 12) visible++;
      sampled++;
    }
    if (sampled == 0) return false;
    return lumaSum / sampled >= 12 && visible / sampled >= 0.10;
  }

  Future<Uint8List?> _encodeBestFaceImage() async {
    final frame = _bestFaceFrame;
    if (frame == null) return null;
    try {
      final rendered = _renderCapturedFrame(frame);
      if (!_capturedFacePixelsAreUsable(rendered.pixels)) {
        debugPrint(
          'Discarded unusable captured face frame (${frame.pixelFormat.name})',
        );
        return null;
      }
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rendered.pixels,
        rendered.width,
        rendered.height,
        ui.PixelFormat.rgba8888,
        completer.complete,
        rowBytes: rendered.width * 4,
      );
      final image = await completer.future;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) return null;
      return Uint8List.fromList(
        byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Unable to encode the best face frame: $error');
      debugPrint('$stackTrace');
      return null;
    }
  }

  /// Samples only the inner portion of the dynamic face ROI. Android delivers
  /// YUV420 and Apple platforms deliver BGRA8888; both become one RGB reading.
  _RgbReading? _sampleFaceRgb(
    CameraImage image,
    Rect faceRoi, {
    double leftFraction = 0.20,
    double topFraction = 0.18,
    double rightFraction = 0.80,
    double bottomFraction = 0.82,
  }) {
    if (image.planes.isEmpty) return null;
    final inner = Rect.fromLTRB(
      faceRoi.left + faceRoi.width * leftFraction,
      faceRoi.top + faceRoi.height * topFraction,
      faceRoi.left + faceRoi.width * rightFraction,
      faceRoi.top + faceRoi.height * bottomFraction,
    );
    final startY = (image.height * inner.top).floor().clamp(
      0,
      image.height - 1,
    );
    final endY = (image.height * inner.bottom).ceil().clamp(1, image.height);
    final startX = (image.width * inner.left).floor().clamp(0, image.width - 1);
    final endX = (image.width * inner.right).ceil().clamp(1, image.width);
    var sumR = 0.0;
    var sumG = 0.0;
    var sumB = 0.0;
    var count = 0;
    var saturatedCount = 0;
    var highFrequencyChromaCount = 0;
    var neighborCount = 0;

    for (var y = startY; y < endY; y += 4) {
      double? previousR;
      double? previousG;
      double? previousB;
      for (var x = startX; x < endX; x += 4) {
        if (image.planes.length >= 3) {
          final yPlane = image.planes[0];
          final uPlane = image.planes[1];
          final vPlane = image.planes[2];
          final yIndex =
              y * yPlane.bytesPerRow + x * (yPlane.bytesPerPixel ?? 1);
          final uvX = x ~/ 2;
          final uvY = y ~/ 2;
          final uIndex =
              uvY * uPlane.bytesPerRow + uvX * (uPlane.bytesPerPixel ?? 1);
          final vIndex =
              uvY * vPlane.bytesPerRow + uvX * (vPlane.bytesPerPixel ?? 1);
          if (yIndex >= yPlane.bytes.length ||
              uIndex >= uPlane.bytes.length ||
              vIndex >= vPlane.bytes.length) {
            continue;
          }
          final yy = yPlane.bytes[yIndex].toDouble();
          final u = uPlane.bytes[uIndex] - 128.0;
          final v = vPlane.bytes[vIndex] - 128.0;
          final r = (yy + 1.402 * v).clamp(0, 255);
          final g = (yy - 0.344136 * u - 0.714136 * v).clamp(0, 255);
          final b = (yy + 1.772 * u).clamp(0, 255);
          sumR += r;
          sumG += g;
          sumB += b;
          if (r >= 250 || g >= 250 || b >= 250) saturatedCount++;
          if (previousR != null) {
            final chromaJump =
                (r - previousR).abs() +
                (g - previousG!).abs() +
                (b - previousB!).abs();
            if (chromaJump > 105) highFrequencyChromaCount++;
            neighborCount++;
          }
          previousR = r.toDouble();
          previousG = g.toDouble();
          previousB = b.toDouble();
          count++;
        } else {
          final plane = image.planes.first;
          final stride = plane.bytesPerPixel ?? 4;
          final index = y * plane.bytesPerRow + x * stride;
          if (index + 2 >= plane.bytes.length) continue;
          final b = plane.bytes[index];
          final g = plane.bytes[index + 1];
          final r = plane.bytes[index + 2];
          sumB += b;
          sumG += g;
          sumR += r;
          if (r >= 250 || g >= 250 || b >= 250) saturatedCount++;
          if (previousR != null) {
            final chromaJump =
                (r - previousR).abs() +
                (g - previousG!).abs() +
                (b - previousB!).abs();
            if (chromaJump > 105) highFrequencyChromaCount++;
            neighborCount++;
          }
          previousR = r.toDouble();
          previousG = g.toDouble();
          previousB = b.toDouble();
          count++;
        }
      }
    }
    return count == 0
        ? null
        : _RgbReading(
            sumR / count,
            sumG / count,
            sumB / count,
            saturatedFraction: saturatedCount / count,
            highFrequencyChromaFraction: neighborCount == 0
                ? 0
                : highFrequencyChromaCount / neighborCount,
          );
  }

  /// Samples four separated skin regions so a single bright rectangle or a
  /// global display change cannot stand in for a face-shaped reflection.
  _FaceRgbRegions? _sampleFaceRegions(CameraImage image, Rect faceRoi) {
    final readings = <_RgbReading?>[
      _sampleFaceRgb(
        image,
        faceRoi,
        leftFraction: 0.28,
        topFraction: 0.10,
        rightFraction: 0.72,
        bottomFraction: 0.31,
      ),
      _sampleFaceRgb(
        image,
        faceRoi,
        leftFraction: 0.12,
        topFraction: 0.38,
        rightFraction: 0.43,
        bottomFraction: 0.70,
      ),
      _sampleFaceRgb(
        image,
        faceRoi,
        leftFraction: 0.57,
        topFraction: 0.38,
        rightFraction: 0.88,
        bottomFraction: 0.70,
      ),
      _sampleFaceRgb(
        image,
        faceRoi,
        leftFraction: 0.37,
        topFraction: 0.28,
        rightFraction: 0.63,
        bottomFraction: 0.74,
      ),
    ];
    if (readings.any((reading) => reading == null)) return null;
    return _FaceRgbRegions(readings.cast<_RgbReading>());
  }

  /// A compact appearance hash is intentionally insensitive to global
  /// brightness. It catches a static image and short repeated frame loops
  /// while the RGB temporal test separately verifies colour illumination.
  int? _perceptualFaceHash(CameraImage image, Rect faceRoi) {
    if (image.planes.isEmpty) return null;
    final luma = <double>[];
    const columns = 9;
    const rows = 7;
    for (var row = 0; row < rows; row++) {
      final fy = 0.18 + (row + 0.5) * 0.64 / rows;
      final y = ((faceRoi.top + faceRoi.height * fy) * image.height)
          .floor()
          .clamp(0, image.height - 1);
      for (var column = 0; column < columns; column++) {
        final fx = 0.18 + (column + 0.5) * 0.64 / columns;
        final x = ((faceRoi.left + faceRoi.width * fx) * image.width)
            .floor()
            .clamp(0, image.width - 1);
        if (image.planes.length >= 3) {
          final plane = image.planes.first;
          final index = y * plane.bytesPerRow + x * (plane.bytesPerPixel ?? 1);
          if (index >= plane.bytes.length) return null;
          luma.add(plane.bytes[index].toDouble());
        } else {
          final plane = image.planes.first;
          final stride = plane.bytesPerPixel ?? 4;
          final index = y * plane.bytesPerRow + x * stride;
          if (index + 2 >= plane.bytes.length) return null;
          final b = plane.bytes[index];
          final g = plane.bytes[index + 1];
          final r = plane.bytes[index + 2];
          luma.add(0.2126 * r + 0.7152 * g + 0.0722 * b);
        }
      }
    }
    final mean = luma.reduce((a, b) => a + b) / luma.length;
    var hash = 0;
    for (var i = 0; i < luma.length; i++) {
      if (luma[i] >= mean) hash |= 1 << i;
    }
    return hash;
  }

  int _hammingDistance(int first, int second) {
    var difference = first ^ second;
    var count = 0;
    while (difference != 0) {
      difference &= difference - 1;
      count++;
    }
    return count;
  }

  void _recordFaceFrameHash(int hash) {
    _faceFrameHashes.add(hash);
    if (_faceFrameHashes.length > 180) _faceFrameHashes.removeAt(0);

    final representatives = <int>[];
    for (final candidate in _faceFrameHashes) {
      if (representatives.every(
        (known) => _hammingDistance(candidate, known) > 4,
      )) {
        representatives.add(candidate);
      }
    }
    _frameUniquenessScore = (representatives.length / 12).clamp(0.0, 1.0);

    var maximumAdjacentChange = 0;
    for (var i = 1; i < _faceFrameHashes.length; i++) {
      maximumAdjacentChange = max(
        maximumAdjacentChange,
        _hammingDistance(_faceFrameHashes[i - 1], _faceFrameHashes[i]),
      );
    }
    final staticSequence =
        _faceFrameHashes.length >= 45 &&
        representatives.length <= 3 &&
        maximumAdjacentChange <= 6;
    _frameReplayDetected = staticSequence || _hasRepeatedFrameLoop();
  }

  bool _hasRepeatedFrameLoop() {
    const window = 8;
    final frames = _faceFrameHashes;
    if (frames.length < window * 3) return false;
    final latestStart = frames.length - window;
    var matchingWindows = 0;
    var lastMatchingStart = -window;
    for (var start = 0; start <= latestStart - window; start++) {
      var matchingFrames = 0;
      for (var offset = 0; offset < window; offset++) {
        if (_hammingDistance(
              frames[start + offset],
              frames[latestStart + offset],
            ) <=
            2) {
          matchingFrames++;
        }
      }
      if (matchingFrames >= window - 1 && start - lastMatchingStart >= window) {
        matchingWindows++;
        lastMatchingStart = start;
        if (matchingWindows >= 2) return true;
      }
    }
    return false;
  }

  /// Mean brightness outside an expanded dynamic face ROI. Comparing this
  /// with face-only RGB catches strong backlighting without reading the face.
  double? _backgroundLuminance(CameraImage image, Rect? faceRoi) {
    if (image.planes.isEmpty) return null;
    final plane = image.planes.first;
    final stride = plane.bytesPerPixel ?? 1;
    var sum = 0.0;
    var count = 0;
    final excluded = faceRoi == null
        ? Rect.zero
        : Rect.fromCenter(
            center: faceRoi.center,
            width: min(1.0, faceRoi.width * 1.5),
            height: min(1.0, faceRoi.height * 1.5),
          );
    for (var y = 0; y < image.height; y += 12) {
      for (var x = 0; x < image.width; x += 12) {
        final normalizedPoint = Offset(x / image.width, y / image.height);
        if (excluded.contains(normalizedPoint)) continue;
        final isOuterBand =
            x < image.width * 0.18 ||
            x > image.width * 0.82 ||
            y < image.height * 0.16 ||
            y > image.height * 0.84;
        if (!isOuterBand) continue;
        final index = y * plane.bytesPerRow + x * stride;
        if (index < 0 || index >= plane.bytes.length) continue;
        if (image.planes.length >= 3 || index + 2 >= plane.bytes.length) {
          sum += plane.bytes[index];
        } else {
          final b = plane.bytes[index];
          final g = plane.bytes[index + 1];
          final r = plane.bytes[index + 2];
          sum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
        }
        count++;
      }
    }
    return count == 0 ? null : sum / count;
  }

  double? _depthRatio(Face face) {
    final mesh = face.mesh;
    final width = face.boundingBox.width;
    if (mesh == null || width <= 0) return null;
    double? minZ;
    double? maxZ;
    for (final point in mesh.points) {
      final z = point.z;
      if (z == null) continue;
      minZ = (minZ == null || z < minZ) ? z : minZ;
      maxZ = (maxZ == null || z > maxZ) ? z : maxZ;
    }
    if (minZ == null || maxZ == null) return null;
    return (maxZ - minZ) / width;
  }

  /// Horizontal displacement of the nose relative to both cheeks, normalized
  /// by face width. A real 3-D face produces opposite values on opposite turns;
  /// translating or rotating a flat photo in the image plane does not.
  double? _noseCheekParallax(Face face) {
    final mesh = face.mesh;
    final width = face.boundingBox.width;
    if (mesh == null || mesh.length <= 454 || width <= 0) return null;
    final nose = mesh[1];
    final cheekA = mesh[234];
    final cheekB = mesh[454];
    final cheekMidX = (cheekA.x + cheekB.x) / 2;
    return (nose.x - cheekMidX) / width;
  }

  void _evaluateFaces(
    List<Face> faces,
    _RgbReading? centerRgb,
    double? backgroundLuma,
    _FaceRgbRegions? faceRegions,
  ) {
    if (_finished || !mounted) return;

    if (faces.length != 1) {
      _noFaceFrames++;
      _stableFrameCount = 0;
      if (_noFaceFrames > _noFaceGraceFrames) {
        _faceWarningActive = true;
        setState(() {
          _instruction = faces.isEmpty
              ? 'ไม่พบใบหน้า กรุณาจัดใบหน้าให้อยู่ในกรอบ'
              : 'พบมากกว่าหนึ่งใบหน้า กรุณาให้มีใบหน้าเดียวในกรอบ';
        });
      }
      return;
    }
    _noFaceFrames = 0;
    if (_faceWarningActive) {
      _faceWarningActive = false;
      setState(() => _instruction = _normalInstructionForStep());
    }

    final face = faces.first;
    if (centerRgb != null) _latestFaceLuma = centerRgb.luminance;
    final requiresNearFace = switch (_step) {
      _LivenessStep.lightPreparing ||
      _LivenessStep.lightBaseline ||
      _LivenessStep.lightFlash ||
      _LivenessStep.turnOne ||
      _LivenessStep.turnTwo => true,
      _ => false,
    };
    if (requiresNearFace &&
        (face.widthFraction < _nearFaceMinFraction ||
            face.widthFraction > _nearFaceMaxFraction)) {
      if (_step == _LivenessStep.lightFlash && _lightBurstStartedAt != null) {
        _fail(
          'ใบหน้าหลุดจากระยะระหว่างรหัสแสง 2 วินาที กรุณาอยู่นิ่งและลองใหม่',
        );
        return;
      }
      _distanceWarningActive = true;
      _resetCurrentStageSamplesForDistance();
      final message = face.widthFraction < _nearFaceMinFraction
          ? 'กรุณาขยับใบหน้าเข้ามาใกล้และรักษาระยะไว้ในกรอบใหญ่'
          : 'ใบหน้าใกล้กล้องเกินไป กรุณาถอยออกเล็กน้อยให้เห็นทั้งใบหน้า';
      if (_instruction != message) {
        setState(() {
          _instruction = message;
        });
      }
      return;
    }
    if (_distanceWarningActive) {
      _distanceWarningActive = false;
      setState(() => _instruction = _normalInstructionForStep());
    }
    if (_step == _LivenessStep.lightBaseline &&
        centerRgb != null &&
        backgroundLuma != null) {
      final faceLuma = centerRgb.luminance;
      if (faceLuma > 0) {
        _lastBacklightRatio = backgroundLuma / faceLuma;
      }
      final isStronglyBacklit =
          backgroundLuma > _minimumBrightBackgroundLuma &&
          faceLuma < _maximumBacklitFaceLuma &&
          _lastBacklightRatio != null &&
          _lastBacklightRatio! > _maximumBacklightRatio;
      if (isStronglyBacklit) {
        _backlightFrames++;
        _backlightRecoveryFrames = 0;
        // Do not let one auto-exposure fluctuation erase a good baseline.
        // Pause briefly and warn only after sustained backlighting.
        if (_backlightFrames < _backlightFramesRequired) return;
        _backlightWarningActive = true;
        _baselineRgb.clear();
        const message =
            'พื้นหลังสว่างกว่าใบหน้ามาก กรุณาหันหน้าเข้าหาแสง '
            'หรือขยับให้หน้าต่างไม่อยู่ด้านหลัง';
        if (_instruction != message) setState(() => _instruction = message);
        return;
      }
      _backlightFrames = max(0, _backlightFrames - 1);
      if (_backlightWarningActive) {
        _backlightRecoveryFrames++;
        if (_backlightRecoveryFrames < _backlightRecoveryFramesRequired) {
          return;
        }
        _backlightWarningActive = false;
        _backlightFrames = 0;
        _backlightRecoveryFrames = 0;
        setState(() => _instruction = _normalInstructionForStep());
      }
    }

    final depthRatio = _depthRatio(face);
    if (depthRatio != null) {
      _lastDepthRatio = depthRatio;
      _minDepthRatio = _minDepthRatio == null
          ? depthRatio
          : (depthRatio < _minDepthRatio! ? depthRatio : _minDepthRatio);
      _maxDepthRatio = _maxDepthRatio == null
          ? depthRatio
          : (depthRatio > _maxDepthRatio! ? depthRatio : _maxDepthRatio);
      final readout =
          'ความลึกใบหน้า (depth ratio): ${depthRatio.toStringAsFixed(3)}';
      if (readout != _depthReadout) {
        setState(() {
          _depthReadout = readout;
        });
      }
    }

    final meshScore = face.meshScore;
    if (meshScore != null) {
      _lastMeshScore = meshScore;
    }

    switch (_step) {
      case _LivenessStep.farPresence:
        _handleFarPresence(face);
        break;
      case _LivenessStep.moveCloser:
        _handleMoveCloser(face);
        break;
      case _LivenessStep.lightPreparing:
        break;
      case _LivenessStep.lightBaseline:
        _handleLightBaseline(centerRgb);
        break;
      case _LivenessStep.lightFlash:
        _handleLightFlash(centerRgb, face, faceRegions);
        break;
      case _LivenessStep.turnOne:
        _handleTurnOne(face);
        break;
      case _LivenessStep.turnTwo:
        _handleTurnTwo(face);
        break;
      case _LivenessStep.success:
      case _LivenessStep.failed:
        break;
    }
  }

  void _resetCurrentStageSamplesForDistance() {
    switch (_step) {
      case _LivenessStep.lightBaseline:
        _baselineRgb.clear();
        break;
      case _LivenessStep.lightFlash:
        _neutralColorSamples.clear();
        for (final samples in _neutralRegionSamples) {
          samples.clear();
        }
        _whiteEyeBaselineSamples.clear();
        _whiteEyeAspectBaselineSamples.clear();
        _colorSamples.clear();
        for (final samples in _colorRegionSamples) {
          samples.clear();
        }
        _flashSettlingFrames = 0;
        _currentColorOnset = null;
        _lightBurstStartedAt = null;
        _flashStartedAt = null;
        _neutralStartedAt = null;
        _flashNeutralPhase = true;
        _currentPulseBaseline = null;
        _currentRegionBaselines = null;
        if (_challengeIndex < _challengePulses.length) {
          if (_challengePulses[_challengeIndex].checkEyes) {
            _blinkChallengeAttempted = false;
            _blinkChallengePassed = false;
            _blinkSawClosed = false;
            _eyeResponseArmed = false;
            _whiteEyeOpenBaseline = null;
            _whiteEyeAspectBaseline = null;
            _maximumEyeProbabilityDrop = 0;
            _maximumEyeAspectDrop = 0;
          }
        }
        break;
      case _LivenessStep.turnOne:
        _firstTurnParallaxSamples.clear();
        _firstTurnSign = 0;
        break;
      case _LivenessStep.turnTwo:
        _secondTurnParallaxSamples.clear();
        break;
      default:
        break;
    }
  }

  void _handleFarPresence(Face face) {
    if (!_detectorReady || _objectDetector == null) {
      _stableFrameCount = 0;
      return;
    }
    if (_suspiciousObjectActive) {
      _stableFrameCount = 0;
      final label = _suspiciousObjectLabel ?? 'อุปกรณ์แสดงภาพ';
      final message =
          'ตรวจพบ $label กรุณานำโทรศัพท์ จอ หนังสือ หรือรูปภาพออกจากกล้อง';
      if (_instruction != message) setState(() => _instruction = message);
      return;
    }
    if (_cleanObjectFrames < 3 || _suspiciousObjectFrames > 0) {
      _stableFrameCount = 0;
      final message = _suspiciousObjectFrames > 0
          ? 'กำลังตรวจสอบวัตถุใกล้ใบหน้าซ้ำ กรุณาอยู่นิ่ง'
          : 'กำลังตรวจโทรศัพท์ จอ และรูปภาพก่อนเริ่มสแกนใบหน้า '
                '(${_cleanObjectFrames + 1}/3)';
      if (_instruction != message) setState(() => _instruction = message);
      return;
    }
    final angleY = face.headEulerAngleY ?? 999;
    final isNeutral = angleY.abs() < _neutralAngleThreshold;
    final size = face.widthFraction;
    final isFarEnough =
        size >= _farFaceMinFraction && size <= _farFaceMaxFraction;
    if (isNeutral && isFarEnough && face.score >= 0.75) {
      _stableFrameCount++;
      if (_instruction != 'ระยะพอดีแล้ว กรุณามองตรงและอยู่นิ่ง') {
        setState(() => _instruction = 'ระยะพอดีแล้ว กรุณามองตรงและอยู่นิ่ง');
      } else if (_stableFrameCount % 2 == 0) {
        setState(() {});
      }
    } else {
      _stableFrameCount = 0;
      final message = size > _farFaceMaxFraction
          ? 'ถอยออกจากกล้อง ให้ศีรษะพอดีกับกรอบเล็ก'
          : size < _farFaceMinFraction
          ? 'ขยับเข้าเล็กน้อย เพื่อให้ระบบเห็นว่าเป็นใบหน้าคน'
          : 'มองตรงและอยู่นิ่ง เพื่อยืนยันว่าเป็นใบหน้าคน';
      if (_instruction != message) setState(() => _instruction = message);
    }

    if (_stableFrameCount >= _stableFramesRequired) {
      _stableFrameCount = 0;
      setState(() {
        _step = _LivenessStep.moveCloser;
        _instruction =
            'ผ่านการตรวจใบหน้าและวัตถุแล้ว กรุณาขยับใบหน้าเข้ามาในกรอบใหญ่';
      });
    }
  }

  void _handleMoveCloser(Face face) {
    final size = face.widthFraction;
    final valid = size >= _nearFaceMinFraction && size <= _nearFaceMaxFraction;
    _stableFrameCount = valid ? _stableFrameCount + 1 : 0;
    if (valid) {
      if (_instruction != 'ระยะใบหน้าพอดีแล้ว กรุณาอยู่นิ่ง') {
        setState(() => _instruction = 'ระยะใบหน้าพอดีแล้ว กรุณาอยู่นิ่ง');
      } else if (_stableFrameCount % 2 == 0) {
        setState(() {});
      }
    }
    if (!valid) {
      final message = size < _nearFaceMinFraction
          ? 'ขยับใบหน้าเข้ามาใกล้อีก ให้พอดีกับกรอบใหญ่'
          : 'ใกล้เกินไป กรุณาถอยออกเล็กน้อย';
      if (_instruction != message) setState(() => _instruction = message);
    }
    if (_stableFrameCount >= _stableFramesRequired) {
      _stableFrameCount = 0;
      setState(() {
        _step = _LivenessStep.lightPreparing;
        _instruction = 'กำลังเพิ่มความสว่างหน้าจอเพื่อเตรียมตรวจแสงสี';
      });
      unawaited(_prepareLightChallenge());
    }
  }

  Future<void> _prepareLightChallenge() async {
    try {
      // Drive the display at the maximum application brightness immediately.
      // A nearly opaque white/colour illumination layer is rendered for the
      // whole light challenge so the screen reflection dominates the face ROI.
      await ScreenBrightness.instance.setAnimate(false);
      await ScreenBrightness.instance.setApplicationScreenBrightness(1.0);
      _brightnessOverridden = true;
    } catch (e) {
      debugPrint('Unable to raise application brightness: $e');
    }
    // Give the display and camera auto-exposure time to stabilize before the
    // baseline is recorded.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) {
      await _restoreScreenBrightness();
      return;
    }
    if (_finished || _step != _LivenessStep.lightPreparing) return;
    await _applyAdaptiveExposure();
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted || _finished || _step != _LivenessStep.lightPreparing) return;
    setState(() {
      _step = _LivenessStep.lightBaseline;
      _instruction = 'ปรับความสว่างพร้อมแล้ว อยู่นิ่งเพื่อวัดแสงพื้นฐาน';
    });
  }

  Future<void> _applyAdaptiveExposure() async {
    final controller = _cameraController;
    final luma = _latestFaceLuma;
    if (controller == null || luma == null) return;
    final requestedOffset = luma > 195
        ? -0.8
        : luma > 160
        ? -0.4
        : luma < 70
        ? 0.6
        : luma < 105
        ? 0.25
        : 0.0;
    try {
      final minExposure = await controller.getMinExposureOffset();
      final maxExposure = await controller.getMaxExposureOffset();
      await controller.setExposureOffset(
        requestedOffset.clamp(minExposure, maxExposure),
      );
    } catch (e) {
      debugPrint('Unable to tune camera exposure: $e');
    }
  }

  Future<void> _restoreScreenBrightness() async {
    if (!_brightnessOverridden) return;
    _brightnessOverridden = false;
    try {
      await ScreenBrightness.instance.resetApplicationScreenBrightness();
    } catch (e) {
      debugPrint('Unable to restore application brightness: $e');
    }
  }

  void _handleLightBaseline(_RgbReading? reading) {
    if (reading == null) return;
    _observeScreenTexture(reading);
    if (!_lightCalibrated) {
      if (reading.luminance >= 250 || reading.saturatedFraction >= 0.65) {
        _preCalibrationRgb.clear();
        const message =
            'ภาพสว่างจนข้อมูลสีหาย กรุณาลดแสงที่ส่องหน้าแล้วอยู่นิ่ง';
        if (_instruction != message) setState(() => _instruction = message);
        return;
      }
      _preCalibrationRgb.add(reading);
      if (_preCalibrationRgb.length % 2 == 0) setState(() {});
      if (_preCalibrationRgb.length < _preCalibrationFramesRequired) return;
      final sortedLuma =
          _preCalibrationRgb.map((sample) => sample.luminance).toList()..sort();
      final upperBaseline = sortedLuma[(sortedLuma.length * 0.8).floor()];
      _calibratedBaselineMaxLuma = min(235.0, max(170.0, upperBaseline + 28.0));
      _calibratedFlashMaxLuma = min(250.0, max(220.0, upperBaseline + 85.0));
      _lightCalibrated = true;
      _baselineRgb.clear();
      setState(() {
        _instruction = 'ปรับค่ากล้องตามสภาพแสงแล้ว อยู่นิ่งเพื่อวัดสีพื้นฐาน';
      });
      return;
    }
    if (reading.luminance > _calibratedBaselineMaxLuma ||
        reading.saturatedFraction > _maximumBaselineSaturation) {
      _baselineRgb.clear();
      const message =
          'แสงบนใบหน้าจ้าเกินไป กรุณาหลีกเลี่ยงแสงแดดหรือไฟที่ส่องหน้าตรงๆ';
      if (_instruction != message) setState(() => _instruction = message);
      return;
    }
    if (_instruction != _normalInstructionForStep()) {
      setState(() => _instruction = _normalInstructionForStep());
    }
    _baselineRgb.add(reading);
    if (_baselineRgb.length % 3 == 0) setState(() {});
    if (_baselineRgb.length >= _baselineFramesRequired) {
      setState(() {
        _step = _LivenessStep.lightFlash;
        _flashNeutralPhase = true;
        _neutralStartedAt = DateTime.now();
        _instruction = 'อยู่นิ่ง กำลังวัดแสงก่อนเริ่มรหัส RGBW 2 วินาที';
      });
    }
  }

  double? _eyeOpenLevel(Face face) {
    final left = face.leftEyeOpenProbability;
    final right = face.rightEyeOpenProbability;
    if (left == null || right == null) return null;
    return (left + right) / 2;
  }

  double? _eyeAspectRatio(Face face) {
    final mesh = face.mesh;
    if (mesh == null || mesh.length <= 387) return null;

    double distance(int first, int second) {
      final a = mesh[first];
      final b = mesh[second];
      final dx = a.x - b.x;
      final dy = a.y - b.y;
      return sqrt(dx * dx + dy * dy);
    }

    double ratio(List<int> indices) {
      final vertical =
          distance(indices[1], indices[5]) + distance(indices[2], indices[4]);
      final horizontal = 2 * distance(indices[0], indices[3]);
      return horizontal <= 0 ? 0 : vertical / horizontal;
    }

    final left = ratio(const [33, 160, 158, 133, 153, 144]);
    final right = ratio(const [362, 385, 387, 263, 373, 380]);
    if (left <= 0 || right <= 0) return null;
    return (left + right) / 2;
  }

  double _upperQuartile(List<double> values) {
    final sorted = List<double>.of(values)..sort();
    return sorted[(sorted.length * 0.75).floor().clamp(0, sorted.length - 1)];
  }

  void _handleLightFlash(
    _RgbReading? reading,
    Face face,
    _FaceRgbRegions? faceRegions,
  ) {
    if (reading == null || faceRegions == null) return;
    _observeScreenTexture(reading);
    final activePulse = _challengePulses[_challengeIndex];
    final activeColor = activePulse.color;
    final eyeOpen = _eyeOpenLevel(face);
    final eyeAspect = _eyeAspectRatio(face);
    if (_flashNeutralPhase) {
      _neutralStartedAt ??= DateTime.now();
      if (reading.luminance > _calibratedBaselineMaxLuma ||
          reading.saturatedFraction > _maximumBaselineSaturation) {
        _neutralColorSamples.clear();
        for (final samples in _neutralRegionSamples) {
          samples.clear();
        }
        _whiteEyeBaselineSamples.clear();
        _whiteEyeAspectBaselineSamples.clear();
        const message =
            'แสงกลางก่อนฉายสีไม่คงที่ กรุณาลดแสงที่ส่องหน้าและอยู่นิ่ง';
        if (_instruction != message) setState(() => _instruction = message);
        return;
      }
      _neutralColorSamples.add(reading);
      for (var i = 0; i < faceRegions.values.length; i++) {
        _neutralRegionSamples[i].add(faceRegions.values[i]);
      }
      if (eyeOpen != null) {
        _whiteEyeBaselineSamples.add(eyeOpen);
      }
      if (eyeAspect != null) {
        _whiteEyeAspectBaselineSamples.add(eyeAspect);
      }
      final neutralElapsed = DateTime.now().difference(_neutralStartedAt!);
      if (_neutralColorSamples.length < _minimumNeutralSamples ||
          _neutralRegionSamples.any(
            (samples) => samples.length < _minimumNeutralSamples,
          ) ||
          neutralElapsed < _initialNeutralDuration) {
        return;
      }
      _currentPulseBaseline = _averageRgb(_neutralColorSamples);
      _currentRegionBaselines = [
        for (final samples in _neutralRegionSamples) _averageRgb(samples),
      ];
      if (_whiteEyeBaselineSamples.isNotEmpty) {
        _whiteEyeOpenBaseline = _upperQuartile(_whiteEyeBaselineSamples);
      }
      if (_whiteEyeAspectBaselineSamples.isNotEmpty) {
        _whiteEyeAspectBaseline = _upperQuartile(
          _whiteEyeAspectBaselineSamples,
        );
      }
      _blinkSawClosed = false;
      _eyeResponseArmed = false;
      _blinkChallengePassed = false;
      _maximumEyeProbabilityDrop = 0;
      _maximumEyeAspectDrop = 0;
      _neutralColorSamples.clear();
      for (final samples in _neutralRegionSamples) {
        samples.clear();
      }
      _whiteEyeBaselineSamples.clear();
      _whiteEyeAspectBaselineSamples.clear();
      _colorSamples.clear();
      for (final samples in _colorRegionSamples) {
        samples.clear();
      }
      _flashSettlingFrames = 0;
      _currentColorOnset = null;
      final burstStartedAt = DateTime.now();
      _lightBurstStartedAt = burstStartedAt;
      _flashStartedAt = burstStartedAt;
      _lightBurstDeadlineTimer?.cancel();
      _lightBurstDeadlineTimer = Timer(
        _lightBurstDuration + _lightBurstDeadlineSlack,
        () {
          if (!mounted ||
              _finished ||
              _step != _LivenessStep.lightFlash ||
              _flashNeutralPhase) {
            return;
          }
          _fail(
            'กล้องเก็บรหัสแสง RGBW ไม่ทันภายใน 2 วินาที กรุณาอยู่นิ่งและลองใหม่',
          );
        },
      );
      setState(() {
        _flashNeutralPhase = false;
        if (activePulse.checkEyes) {
          _blinkChallengeAttempted = true;
        }
        _instruction =
            'อยู่นิ่ง กำลังฉายแสงสี${activeColor.thaiName} (${_challengeIndex + 1}/${_challengePulses.length})';
      });
      return;
    }
    if (activePulse.checkEyes && (eyeOpen != null || eyeAspect != null)) {
      final eyesOpenAfterChallenge =
          (eyeOpen != null && eyeOpen >= 0.52) ||
          (eyeAspect != null && eyeAspect >= _minimumOpenEyeAspectRatio);
      if (!_eyeResponseArmed && eyesOpenAfterChallenge) {
        // Arm only from an open-eye frame captured after the random pulse
        // began. A blink already underway before the challenge cannot pass.
        _eyeResponseArmed = true;
        if (eyeOpen != null &&
            (_whiteEyeOpenBaseline == null ||
                eyeOpen > _whiteEyeOpenBaseline!)) {
          _whiteEyeOpenBaseline = eyeOpen;
        }
        if (eyeAspect != null &&
            (_whiteEyeAspectBaseline == null ||
                eyeAspect > _whiteEyeAspectBaseline!)) {
          _whiteEyeAspectBaseline = eyeAspect;
        }
        _maximumEyeProbabilityDrop = 0;
        _maximumEyeAspectDrop = 0;
      } else if (_eyeResponseArmed) {
        final baseline = _whiteEyeOpenBaseline;
        final probabilityDrop = baseline == null || eyeOpen == null
            ? 0.0
            : max(0.0, baseline - eyeOpen);
        _maximumEyeProbabilityDrop = max(
          _maximumEyeProbabilityDrop,
          probabilityDrop,
        );
        final aspectBaseline = _whiteEyeAspectBaseline;
        final aspectDrop = aspectBaseline == null || eyeAspect == null
            ? 0.0
            : max(0.0, (aspectBaseline - eyeAspect) / aspectBaseline);
        _maximumEyeAspectDrop = max(_maximumEyeAspectDrop, aspectDrop);
        final closedRelativeToBaseline =
            probabilityDrop >= _blinkDropFromBaseline || aspectDrop >= 0.10;
        if (!_blinkSawClosed &&
            ((eyeOpen != null && eyeOpen <= _blinkClosedThreshold) ||
                closedRelativeToBaseline)) {
          _blinkSawClosed = true;
          _currentColorOnset ??= DateTime.now().difference(_flashStartedAt!);
        }
        final probabilityRecovered =
            baseline != null && eyeOpen != null && eyeOpen >= baseline - 0.06;
        final aspectRecovered =
            aspectBaseline != null &&
            eyeAspect != null &&
            eyeAspect >= aspectBaseline * 0.90;
        if (_blinkSawClosed && (probabilityRecovered || aspectRecovered)) {
          _blinkChallengePassed = true;
        }
        if (_maximumEyeProbabilityDrop >= _minimumAcceptedEyeProbabilityDrop ||
            _maximumEyeAspectDrop >= _minimumAcceptedEyeAspectDrop) {
          // A sustained squint is also accepted after the post-challenge arm.
          _blinkChallengePassed = true;
          _currentColorOnset ??= DateTime.now().difference(_flashStartedAt!);
        }
      }
    }
    // White is an eye-response challenge. In a bright room its reflected luma
    // can be clipped or barely change, while the eye landmarks remain useful.
    // Therefore overexposure only blocks chromatic RGB sampling.
    final isOverexposed =
        activeColor != _ChallengeColor.white &&
        (reading.luminance > _calibratedFlashMaxLuma ||
            reading.saturatedFraction > _maximumFlashSaturation);
    if (isOverexposed) {
      _colorSamples.clear();
      for (final samples in _colorRegionSamples) {
        samples.clear();
      }
      _flashSettlingFrames = 0;
      const message =
          'ภาพอิ่มแสงจนอ่านสีสะท้อนไม่ได้ กรุณาลดแสงที่ส่องหน้าและอยู่นิ่ง';
      if (_instruction != message) setState(() => _instruction = message);
      final pulseStartedAt = _flashStartedAt;
      if (pulseStartedAt != null &&
          DateTime.now().difference(pulseStartedAt) >= activePulse.duration) {
        _fail(
          'ภาพอิ่มแสงจนอ่านรหัสสีภายใน 2 วินาทีไม่ได้ กรุณาลดแสงที่ส่องหน้าแล้วลองใหม่',
        );
      }
      return;
    }
    final normalInstruction = _normalInstructionForStep();
    if (_instruction != normalInstruction) {
      setState(() => _instruction = normalInstruction);
    }
    final colorBaseline = _currentPulseBaseline!;
    final instantaneousChange = activeColor == _ChallengeColor.white
        ? (reading.luminance - colorBaseline.luminance) / 255
        : reading.channelShare(activeColor) -
              colorBaseline.channelShare(activeColor);
    if (activeColor == _ChallengeColor.white &&
        !activePulse.checkEyes &&
        _currentColorOnset == null) {
      // White reflection can disappear into camera clipping in a bright room.
      // Keep this pulse in the secret code without making its luma decisive.
      _currentColorOnset = DateTime.now().difference(_flashStartedAt!);
    }
    if (!activePulse.checkEyes &&
        _currentColorOnset == null &&
        instantaneousChange >=
            (activeColor == _ChallengeColor.white
                ? _minimumWhiteLumaChange / 255
                : _minimumColorOnsetChange)) {
      _currentColorOnset = DateTime.now().difference(_flashStartedAt!);
    }
    // Let display brightness and camera auto-exposure begin reacting before
    // collecting the illuminated samples. Onset detection above still observes
    // these frames, so timing measures the response rather than batch duration.
    if (_flashSettlingFrames < 1) {
      _flashSettlingFrames++;
      return;
    }
    _colorSamples.add(reading);
    for (var i = 0; i < faceRegions.values.length; i++) {
      _colorRegionSamples[i].add(faceRegions.values[i]);
    }
    if (_colorSamples.length % 3 == 0) setState(() {});
    final pulseElapsed = DateTime.now().difference(_flashStartedAt!);
    final requiredPulseDuration = activePulse.duration;
    if (_colorSamples.length < _minimumColorSamples ||
        pulseElapsed < requiredPulseDuration) {
      if (pulseElapsed >
          requiredPulseDuration + const Duration(milliseconds: 150)) {
        _fail('กล้องเก็บข้อมูลแสงไม่ทันภายใน 2 วินาที กรุณาลองใหม่อีกครั้ง');
      }
      return;
    }

    final responseTime = _currentColorOnset;
    if (responseTime == null ||
        responseTime < _minimumColorOnset ||
        responseTime > _maximumColorOnset) {
      _fail(
        activePulse.checkEyes
            ? 'ไม่พบการตอบสนองของดวงตาในช่วงแสงสีขาว กรุณาลองใหม่'
            : 'ไม่พบการเริ่มตอบสนองต่อแสงสีในช่วงเวลาที่กำหนด กรุณาลองใหม่',
      );
      return;
    }
    _flashResponseTimes.add(responseTime);
    final averagedReading = _averageRgb(_colorSamples);
    _pulseBaselines.add(colorBaseline);
    _pulseReadings.add(averagedReading);
    _pulseRegionBaselines.add(List<_RgbReading>.of(_currentRegionBaselines!));
    _pulseRegionReadings.add([
      for (final samples in _colorRegionSamples) _averageRgb(samples),
    ]);
    if (activeColor == _ChallengeColor.white) {
      _whiteReflectionPassed =
          _whiteReflectionPassed ||
          averagedReading.luminance - colorBaseline.luminance >=
              _minimumWhiteLumaChange;
      if (activePulse.checkEyes && !_blinkChallengePassed) {
        _fail('ไม่พบลำดับการกะพริบตาระหว่างแสงสีขาว กรุณาลองใหม่');
        return;
      }
    }
    _colorSamples.clear();
    for (final samples in _colorRegionSamples) {
      samples.clear();
    }
    _flashSettlingFrames = 0;
    _challengeIndex++;

    if (_challengeIndex < _challengePulses.length) {
      final nextPulse = _challengePulses[_challengeIndex];
      final completedDuration = _challengePulses
          .take(_challengeIndex)
          .fold<Duration>(
            Duration.zero,
            (total, pulse) => total + pulse.duration,
          );
      _currentColorOnset = null;
      if (nextPulse.checkEyes) {
        _blinkChallengeAttempted = true;
        _blinkSawClosed = false;
        _eyeResponseArmed = false;
        _maximumEyeProbabilityDrop = 0;
        _maximumEyeAspectDrop = 0;
      }
      setState(() {
        _flashNeutralPhase = false;
        _flashStartedAt = _lightBurstStartedAt!.add(completedDuration);
        _instruction =
            'อยู่นิ่ง กำลังฉายแสงสี${nextPulse.color.thaiName} (${_challengeIndex + 1}/${_challengePulses.length})';
      });
      return;
    }

    final matchedColors = <_ChallengeColor>{};
    var strongestChange = 0.0;
    for (var i = 0; i < _challengePulses.length; i++) {
      final color = _challengePulses[i].color;
      if (color == _ChallengeColor.white) continue;
      final illuminated = _pulseReadings[i];
      final baseline = _pulseBaselines[i];
      final change =
          illuminated.channelShare(color) - baseline.channelShare(color);
      if (change > strongestChange) strongestChange = change;
      final requiredChange = baseline.luminance >= 175
          ? _minimumColorShareChange * 0.55
          : _minimumColorShareChange;
      if (change >= requiredChange) matchedColors.add(color);
    }
    _lightResponse = strongestChange * 100;
    _lightResponseMagnitude = _lightResponse!.abs();
    _matchedColorCount = matchedColors.length;
    _lightChallengePassed = matchedColors.length >= 2 && _blinkChallengePassed;
    _timedChallengePassed =
        _flashResponseTimes.length == _challengePulses.length;
    _lightBurstDeadlineTimer?.cancel();
    if (!_lightChallengePassed) {
      _fail(
        'สีสะท้อนบนใบหน้าตรงกับคำสั่งเพียง ${matchedColors.length}/3 สี '
        '(คะแนน ${_lightResponseMagnitude!.toStringAsFixed(1)}) '
        'กรุณาเพิ่มความสว่างหน้าจอและหลีกเลี่ยงแสงจ้าด้านหลัง',
      );
      return;
    }
    _evaluateTemporalRegionCorrelation();
    if (!_temporalCorrelationPassed) {
      _fail('การสะท้อนแสงตามรหัสสุ่มไม่สอดคล้องกันบนหลายบริเวณของใบหน้า');
      return;
    }
    setState(() {
      _step = _LivenessStep.turnOne;
      _instruction = 'ตรวจแสงผ่านแล้ว กรุณามองตรงและอยู่นิ่งสักครู่';
    });
  }

  _RgbReading _averageRgb(List<_RgbReading> values) {
    var r = 0.0;
    var g = 0.0;
    var b = 0.0;
    var saturatedFraction = 0.0;
    var highFrequencyChromaFraction = 0.0;
    for (final value in values) {
      r += value.r;
      g += value.g;
      b += value.b;
      saturatedFraction += value.saturatedFraction;
      highFrequencyChromaFraction += value.highFrequencyChromaFraction;
    }
    return _RgbReading(
      r / values.length,
      g / values.length,
      b / values.length,
      saturatedFraction: saturatedFraction / values.length,
      highFrequencyChromaFraction: highFrequencyChromaFraction / values.length,
    );
  }

  void _evaluateTemporalRegionCorrelation() {
    if (_pulseRegionBaselines.length != _challengePulses.length ||
        _pulseRegionReadings.length != _challengePulses.length) {
      _regionCorrelationScores = const [];
      _temporalCorrelationPassed = false;
      return;
    }

    final scores = <double>[];
    for (var region = 0; region < 4; region++) {
      final expected = <double>[];
      final observed = <double>[];
      for (
        var pulseIndex = 0;
        pulseIndex < _challengePulses.length;
        pulseIndex++
      ) {
        final pulse = _challengePulses[pulseIndex];
        final baseline = _pulseRegionBaselines[pulseIndex][region];
        final illuminated = _pulseRegionReadings[pulseIndex][region];
        final scale = max(35.0, baseline.luminance);
        expected.addAll([
          pulse.intensity *
              (pulse.color == _ChallengeColor.red ||
                      pulse.color == _ChallengeColor.white
                  ? 1
                  : 0),
          pulse.intensity *
              (pulse.color == _ChallengeColor.green ||
                      pulse.color == _ChallengeColor.white
                  ? 1
                  : 0),
          pulse.intensity *
              (pulse.color == _ChallengeColor.blue ||
                      pulse.color == _ChallengeColor.white
                  ? 1
                  : 0),
        ]);
        observed.addAll([
          (illuminated.r - baseline.r) / scale,
          (illuminated.g - baseline.g) / scale,
          (illuminated.b - baseline.b) / scale,
        ]);
      }
      scores.add(_pearsonCorrelation(expected, observed));
    }
    _regionCorrelationScores = scores;
    final mean = scores.reduce((a, b) => a + b) / scores.length;
    final minimum = scores.reduce(min);
    final maximum = scores.reduce(max);
    final correlatedRegions = scores.where((score) => score >= 0.08).length;
    _temporalCorrelationPassed =
        correlatedRegions >= 3 && mean >= 0.10 && maximum - minimum <= 0.75;
  }

  double _pearsonCorrelation(List<double> first, List<double> second) {
    if (first.length != second.length || first.isEmpty) return 0;
    final firstMean = first.reduce((a, b) => a + b) / first.length;
    final secondMean = second.reduce((a, b) => a + b) / second.length;
    var numerator = 0.0;
    var firstVariance = 0.0;
    var secondVariance = 0.0;
    for (var i = 0; i < first.length; i++) {
      final firstDelta = first[i] - firstMean;
      final secondDelta = second[i] - secondMean;
      numerator += firstDelta * secondDelta;
      firstVariance += firstDelta * firstDelta;
      secondVariance += secondDelta * secondDelta;
    }
    final denominator = sqrt(firstVariance * secondVariance);
    return denominator <= 0 ? 0 : numerator / denominator;
  }

  void _observeScreenTexture(_RgbReading reading) {
    if (reading.highFrequencyChromaFraction > _maximumHighFrequencyChroma) {
      _screenArtifactFrames++;
    } else {
      _screenArtifactFrames = max(0, _screenArtifactFrames - 1);
    }
    if (_screenArtifactFrames >= _screenArtifactFramesRequired) {
      // Texture alone is not decisive: hair, beard, glasses and sensor noise
      // can look screen-like. Keep it as supporting/debug evidence and only
      // reject when an enclosing presentation-media object is also detected.
      _screenTextureSuspected = true;
    }
  }

  void _handleTurnOne(Face face) {
    final angleY = face.headEulerAngleY;
    final parallax = _noseCheekParallax(face);
    if (angleY == null || parallax == null) return;

    if (!_turnNeutralReady) {
      if (angleY.abs() < _neutralAngleThreshold) {
        _neutralParallaxSamples.add(parallax);
        if (_neutralParallaxSamples.length >= _parallaxSamplesRequired) {
          _turnNeutralReady = true;
          setState(() {
            _instruction =
                'ค่าหน้าตรงพร้อมแล้ว กรุณาหันหน้าไปด้านหนึ่งช้าๆ และค้างไว้เล็กน้อย';
          });
        }
      } else {
        _neutralParallaxSamples.clear();
      }
      return;
    }

    if (angleY.abs() > _turnAngleThreshold) {
      if (_firstTurnSign == 0) _firstTurnSign = angleY.sign;
      if (angleY.sign == _firstTurnSign &&
          _firstTurnParallaxSamples.length < _parallaxSamplesRequired + 3) {
        _firstTurnParallaxSamples.add(parallax);
      }
      return;
    }
    if (_firstTurnSign != 0 &&
        angleY.abs() < _neutralAngleThreshold &&
        _firstTurnParallaxSamples.length >= _parallaxSamplesRequired) {
      _firstTurnParallax = _median(_firstTurnParallaxSamples);
      _turnOneDetected = true;
      setState(() {
        _step = _LivenessStep.turnTwo;
        _instruction =
            'ดีมาก กรุณาหันหน้าไปอีกด้านหนึ่งช้าๆ และค้างไว้เล็กน้อย';
      });
    }
  }

  void _handleTurnTwo(Face face) {
    final angleY = face.headEulerAngleY;
    final parallax = _noseCheekParallax(face);
    if (angleY == null || parallax == null) return;

    final oppositeDirectionReached =
        angleY.sign != _firstTurnSign && angleY.abs() > _turnAngleThreshold;

    if (oppositeDirectionReached) {
      if (_secondTurnParallaxSamples.length < _parallaxSamplesRequired + 3) {
        _secondTurnParallaxSamples.add(parallax);
      }
      return;
    }
    if (_secondTurnParallaxSamples.length >= _parallaxSamplesRequired &&
        angleY.abs() < _neutralAngleThreshold) {
      _secondTurnParallax = _median(_secondTurnParallaxSamples);
      final first = _firstTurnParallax;
      final second = _secondTurnParallax;
      final neutral = _median(_neutralParallaxSamples);
      final firstDelta = first == null ? null : first - neutral;
      final secondDelta = second == null ? null : second - neutral;
      _motionCoherencePassed =
          firstDelta != null &&
          secondDelta != null &&
          firstDelta.abs() >= _minimumPoseLandmarkOffset &&
          secondDelta.abs() >= _minimumPoseLandmarkOffset &&
          firstDelta.sign != secondDelta.sign;
      _parallaxPassed =
          firstDelta != null &&
          secondDelta != null &&
          (firstDelta - secondDelta).abs() >= _minimumParallaxDelta;
      if (!_motionCoherencePassed || !_parallaxPassed) {
        _fail('การเคลื่อนไหวของจมูกและแก้มไม่สัมพันธ์กับการหันศีรษะแบบสามมิติ');
        return;
      }
      _turnTwoDetected = true;
      _calculatePassiveAntiSpoofScore();
      if (!_passiveAntiSpoofPassed) {
        _fail(
          _frameReplayDetected
              ? 'พบลำดับภาพนิ่งหรือเฟรมซ้ำที่คล้ายการเล่นภาพบันทึก กรุณาลองใหม่'
              : 'หลักฐานรวมสำหรับแยกใบหน้าจริงจากภาพยังไม่เพียงพอ กรุณาลองใหม่',
        );
        return;
      }
      setState(() {
        _step = _LivenessStep.success;
        _instruction = 'ยืนยันว่าเป็นใบหน้าจริงสำเร็จ';
      });
      unawaited(_finish(true));
    }
  }

  void _calculatePassiveAntiSpoofScore() {
    final averageCorrelation = _regionCorrelationScores.isEmpty
        ? 0.0
        : _regionCorrelationScores.reduce((a, b) => a + b) /
              _regionCorrelationScores.length;
    final correlationEvidence = ((averageCorrelation - 0.05) / 0.45)
        .clamp(0.0, 1.0)
        .toDouble();
    final textureEvidence = _screenTextureSuspected ? 0.0 : 1.0;
    final depthEvidence = _motionCoherencePassed && _parallaxPassed ? 1.0 : 0.0;
    final eyeEvidence = _blinkChallengePassed ? 1.0 : 0.0;
    final replayEvidence = _frameReplayDetected ? 0.0 : 1.0;
    _passiveAntiSpoofScore =
        correlationEvidence * 0.25 +
        _frameUniquenessScore * 0.20 +
        textureEvidence * 0.10 +
        depthEvidence * 0.25 +
        eyeEvidence * 0.15 +
        replayEvidence * 0.05;
    _passiveAntiSpoofPassed =
        _passiveAntiSpoofScore! >= 0.58 &&
        !_frameReplayDetected &&
        _temporalCorrelationPassed &&
        _replayScreenPassed;
  }

  double _median(List<double> values) {
    final sorted = List<double>.of(values)..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }

  double get _scanProgress {
    return switch (_step) {
      _LivenessStep.farPresence =>
        0.18 * (_stableFrameCount / _stableFramesRequired).clamp(0, 1),
      _LivenessStep.moveCloser =>
        0.18 + 0.14 * (_stableFrameCount / _stableFramesRequired).clamp(0, 1),
      _LivenessStep.lightPreparing => 0.34,
      _LivenessStep.lightBaseline =>
        0.36 +
            0.09 * (_baselineRgb.length / _baselineFramesRequired).clamp(0, 1),
      _LivenessStep.lightFlash =>
        0.45 +
            0.35 *
                ((_challengeIndex + _currentColorPhaseProgress) /
                        _challengePulses.length)
                    .clamp(0, 1),
      _LivenessStep.turnOne => 0.82,
      _LivenessStep.turnTwo => 0.91,
      _LivenessStep.success => 1,
      _LivenessStep.failed => 0,
    };
  }

  double get _currentColorPhaseProgress {
    if (_flashNeutralPhase || _flashStartedAt == null) return 0;
    final elapsed = DateTime.now().difference(_flashStartedAt!);
    final pulse =
        _challengePulses[min(_challengeIndex, _challengePulses.length - 1)];
    final duration = pulse.duration;
    return (elapsed.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  String _normalInstructionForStep() {
    return switch (_step) {
      _LivenessStep.farPresence => 'จัดใบหน้าให้อยู่ในกรอบและมองตรง',
      _LivenessStep.moveCloser => 'ขยับใบหน้าเข้ามาให้พอดีกับกรอบใหญ่',
      _LivenessStep.lightPreparing => 'กำลังเตรียมความสว่างสำหรับตรวจแสงสี',
      _LivenessStep.lightBaseline => 'อยู่นิ่ง ระบบกำลังวัดแสงพื้นฐานบนใบหน้า',
      _LivenessStep.lightFlash =>
        _flashNeutralPhase
            ? 'อยู่นิ่ง กำลังวัดแสงก่อนเริ่มรหัส RGBW 2 วินาที'
            : 'อยู่นิ่ง กำลังฉายแสงสี${_challengePulses[min(_challengeIndex, _challengePulses.length - 1)].color.thaiName} (${min(_challengeIndex + 1, _challengePulses.length)}/${_challengePulses.length})',
      _LivenessStep.turnOne =>
        'กรุณาหันหน้าไปทางด้านหนึ่งช้าๆ แล้วหันกลับมามองตรง',
      _LivenessStep.turnTwo => 'กรุณาหันหน้าไปอีกด้านหนึ่ง แล้วหันกลับมามองตรง',
      _LivenessStep.success => 'ยืนยันว่าเป็นใบหน้าจริงสำเร็จ',
      _LivenessStep.failed => _failureReason ?? 'การตรวจสอบไม่สำเร็จ',
    };
  }

  Widget _buildAspectCorrectCameraPreview(CameraController controller) {
    final previewSize = controller.value.previewSize;
    if (previewSize == null) return CameraPreview(controller);
    final orientation = controller.value.deviceOrientation;
    final isLandscape =
        orientation == DeviceOrientation.landscapeLeft ||
        orientation == DeviceOrientation.landscapeRight;
    final displayWidth = isLandscape ? previewSize.width : previewSize.height;
    final displayHeight = isLandscape ? previewSize.height : previewSize.width;

    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          alignment: Alignment.center,
          child: SizedBox(
            width: displayWidth,
            height: displayHeight,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }

  String get _stageTitle => switch (_step) {
    _LivenessStep.farPresence => 'จัดตำแหน่งใบหน้า',
    _LivenessStep.moveCloser => 'ขยับเข้าใกล้',
    _LivenessStep.lightPreparing ||
    _LivenessStep.lightBaseline => 'เตรียมตรวจแสง',
    _LivenessStep.lightFlash => 'ตรวจ RGBW 2 วินาที',
    _LivenessStep.turnOne ||
    _LivenessStep.turnTwo => 'ตรวจการเคลื่อนไหว 3 มิติ',
    _LivenessStep.success => 'ตรวจสอบสำเร็จ',
    _LivenessStep.failed => 'ตรวจสอบไม่สำเร็จ',
  };

  IconData get _stageIcon => switch (_step) {
    _LivenessStep.farPresence => Icons.center_focus_strong_rounded,
    _LivenessStep.moveCloser => Icons.zoom_in_rounded,
    _LivenessStep.lightPreparing ||
    _LivenessStep.lightBaseline ||
    _LivenessStep.lightFlash => Icons.light_mode_rounded,
    _LivenessStep.turnOne || _LivenessStep.turnTwo => Icons.threed_rotation,
    _LivenessStep.success => Icons.verified_rounded,
    _LivenessStep.failed => Icons.error_outline_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;
    final isFarStage = _step == _LivenessStep.farPresence;
    final isLightFlash = _step == _LivenessStep.lightFlash;
    final isColorPulse = isLightFlash && !_flashNeutralPhase;
    final isIlluminationStage =
        _step == _LivenessStep.lightPreparing ||
        _step == _LivenessStep.lightBaseline ||
        isLightFlash;
    final challengeColor =
        isColorPulse && _challengeIndex < _challengePulses.length
        ? _challengePulses[_challengeIndex].displayColor
        : const Color(0xFF202827);
    final nearGuideWidth = min(MediaQuery.sizeOf(context).width * 0.98, 420.0);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: controller != null && controller.value.isInitialized
                ? _buildAspectCorrectCameraPreview(controller)
                : const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
          ),
          if (isIlluminationStage)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: challengeColor.withValues(alpha: 0.94),
                ),
              ),
            ),
          if (_initializationFailed)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'ไม่สามารถเปิดกล้องได้ กรุณาอนุญาตกล้องและลองใหม่อีกครั้ง',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B1716).withValues(alpha: 0.86),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.white12,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            _stageIcon,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _stageTitle,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                isFarStage
                                    ? 'ขั้นตอนที่ 1 จาก 2'
                                    : 'ขั้นตอนที่ 2 จาก 2',
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'ยกเลิก',
                          onPressed: () => unawaited(_finish(false)),
                          icon: const Icon(Icons.close_rounded),
                          color: Colors.white70,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: LinearProgressIndicator(
                              value: _scanProgress,
                              minHeight: 7,
                              backgroundColor: Colors.white12,
                              color: isColorPulse
                                  ? challengeColor
                                  : const Color(0xFF64D8CB),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 38,
                          child: Text(
                            '${(_scanProgress * 100).round()}%',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (!_detectorReady && !_initializationFailed) ...[
                      const SizedBox(height: 8),
                      if (_detectorInitInProgress)
                        const LinearProgressIndicator(minHeight: 2),
                      if (_detectorInitFailed)
                        TextButton.icon(
                          onPressed: _detectorInitInProgress
                              ? null
                              : _initializeDetector,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('ลองเปิดระบบตรวจจับอีกครั้ง'),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 142,
            bottom: 154,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final desiredHeight = isFarStage ? 315.0 : 530.0;
                  final guideHeight = min(desiredHeight, constraints.maxHeight);
                  final aspectRatio = isFarStage ? 240 / 315 : 420 / 530;
                  final guideWidth = min(
                    isFarStage ? 240.0 : nearGuideWidth,
                    guideHeight * aspectRatio,
                  );
                  return Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeInOut,
                      width: guideWidth,
                      height: guideHeight,
                      child: CustomPaint(
                        painter: _FaceGuidePainter(
                          color: isColorPulse ? challengeColor : Colors.white70,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          Positioned(
            bottom: 10,
            left: 16,
            right: 16,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B1716).withValues(alpha: 0.90),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        _stageIcon,
                        color: isColorPulse ? challengeColor : Colors.white,
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Text(
                        _instruction,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
