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

part 'models/liveness_models.dart';
part 'pages/home_page.dart';
part 'pages/liveness_capture_page.dart';
part 'widgets/face_guide_painter.dart';

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
