part of '../main.dart';

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
