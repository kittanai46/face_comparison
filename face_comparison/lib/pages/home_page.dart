part of '../main.dart';

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

class FaceComparisonHomePage extends StatefulWidget {
  const FaceComparisonHomePage({super.key});

  @override
  State<FaceComparisonHomePage> createState() => _FaceComparisonHomePageState();
}

class _FaceComparisonHomePageState extends State<FaceComparisonHomePage> {
  bool _livenessVerified = false;
  bool? _blinkDetected;
  bool? _antiSpoofPassed;
  String _scanMessage = 'พร้อมเรียกใช้ระบบสแกนจาก active_face_liveness';
  String _scanClassification = 'ยังไม่ทราบ';
  List<_ScanSummaryItem>? _scanSummary;
  Uint8List? _capturedFaceImage;
  bool _scanning = false;

  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _livenessVerified = false;
      _blinkDetected = null;
      _antiSpoofPassed = null;
      _capturedFaceImage = null;
      _scanMessage = 'กำลังตรวจสอบว่าเป็นใบหน้าจริง กรุณาทำตามคำแนะนำบนจอ';
    });

    final result = await ActiveFaceLiveness.start(
      context,
      config: const LivenessConfig(
        imageOutput: LivenessImageOutput.pngBytes,
        capturedImageContrast: 1,
        capturedImageMaxLongEdge: 800,
      ),
    );

    if (!mounted) return;
    if (result.cancelled) {
      setState(() {
        _scanning = false;
        _scanMessage = 'ยกเลิกการสแกนแล้ว';
      });
      return;
    }

    setState(() {
      _scanning = false;
      final classificationLabel = livenessClassificationLabel(
        result.classification,
      );
      final isRealPerson = result.isLive;
      final failureReason = result.failureReason;
      final evidence = result.evidence;
      final technical = result.technicalDetails;
      _livenessVerified = isRealPerson;
      final blinkAttempted = technical['blinkChallengeAttempted'] == true;
      _blinkDetected = blinkAttempted ? evidence.blinkChallengePassed : null;
      _antiSpoofPassed = evidence.passiveAntiSpoofPassed;
      _capturedFaceImage = result.pngBytes;
      _scanClassification = classificationLabel;
      _scanMessage = isRealPerson
          ? 'ผลลัพธ์: ใบหน้าถูกจัดว่าเป็นคนจริง'
          : failureReason != null
          ? 'ยังยืนยันว่าเป็นคนจริงไม่ได้: $failureReason'
          : 'ผลลัพธ์: ใบหน้าถูกจัดว่าเป็นภาพถ่าย';

      final movementPassed =
          evidence.motionCoherencePassed && evidence.parallaxPassed;
      final replayRisk =
          !evidence.replayScreenPassed ||
          technical['frameReplayDetected'] == true;
      _scanSummary = [
        _ScanSummaryItem(
          title: 'ผลการยืนยัน',
          detail: classificationLabel,
          passed: isRealPerson,
        ),
        _ScanSummaryItem(
          title: 'หันหน้าด้านแรก',
          detail: evidence.firstTurnPassed ? 'ตรวจพบแล้ว' : 'ยังไม่สำเร็จ',
          passed: evidence.firstTurnPassed,
        ),
        _ScanSummaryItem(
          title: 'หันหน้าอีกด้าน',
          detail: evidence.secondTurnPassed ? 'ตรวจพบแล้ว' : 'ยังไม่สำเร็จ',
          passed: evidence.secondTurnPassed,
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
              : evidence.blinkChallengePassed
              ? 'ตรวจพบการตอบสนองของดวงตา'
              : 'ยังตรวจไม่พบการตอบสนอง',
          passed: blinkAttempted ? evidence.blinkChallengePassed : null,
        ),
        _ScanSummaryItem(
          title: 'สีสะท้อนบนใบหน้า',
          detail: '${evidence.matchedColorCount}/3 สี',
          passed: evidence.lightChallengePassed,
        ),
        _ScanSummaryItem(
          title: 'แสงหลายบริเวณบนใบหน้า',
          detail: evidence.temporalCorrelationPassed
              ? 'รูปแบบแสงตรงกับรหัสสุ่ม'
              : 'รูปแบบแสงยังไม่ตรงตามเกณฑ์',
          passed: evidence.temporalCorrelationPassed,
        ),
        _ScanSummaryItem(
          title: 'การป้องกันภาพหรือวิดีโอ',
          detail: replayRisk
              ? 'พบสัญญาณที่อาจเป็นภาพหรือวิดีโอซ้ำ'
              : evidence.passiveAntiSpoofPassed
              ? 'ไม่พบสัญญาณการเล่นภาพซ้ำ'
              : 'ยังตรวจหลักฐานไม่ครบทุกขั้นตอน',
          passed: replayRisk
              ? false
              : (evidence.passiveAntiSpoofPassed ? true : null),
        ),
      ];
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
                subtitle: 'แพ็กเกจจะเลือกกล้องหน้าเมื่อเริ่มสแกน',
                isDone: true,
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
                onPressed: _scanning ? null : _startScan,
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
