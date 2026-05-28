import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../shell/app_scope.dart';

class CameraCapturePage extends StatefulWidget {
  const CameraCapturePage({super.key});

  @override
  State<CameraCapturePage> createState() => _CameraCapturePageState();
}

class _CameraCapturePageState extends State<CameraCapturePage>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  bool _isInitializing = true;
  bool _isCapturing = false;
  String? _error;
  int _capturedCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      controller.dispose();
      _cameraController = null;
    } else if (state == AppLifecycleState.resumed) {
      _openCamera(_cameraIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _buildPreview(controller)),
            Positioned(
              left: 12,
              top: 12,
              child: IconButton.filledTonal(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
                tooltip: '退出拍摄',
              ),
            ),
            Positioned(
              right: 12,
              top: 12,
              child: IconButton.filledTonal(
                onPressed: _cameras.length < 2 || _isCapturing
                    ? null
                    : _switchCamera,
                icon: const Icon(Icons.cameraswitch_outlined),
                tooltip: '切换摄像头',
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 24,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_capturedCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.58),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        '已加入 $_capturedCount 张，后台识别中',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _CaptureButton(
                        isCapturing: _isCapturing,
                        onPressed:
                            controller == null ||
                                !controller.value.isInitialized ||
                                _isCapturing
                            ? null
                            : _capture,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(CameraController? controller) {
    if (_isInitializing) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ),
      );
    }

    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: Text('相机不可用', style: TextStyle(color: Colors.white)),
      );
    }

    return Center(child: CameraPreview(controller));
  }

  Future<void> _initialize() async {
    setState(() {
      _isInitializing = true;
      _error = null;
    });

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        throw CameraException('no_camera', '没有找到可用相机');
      }
      final backIndex = _cameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );
      _cameraIndex = backIndex < 0 ? 0 : backIndex;
      await _openCamera(_cameraIndex);
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.description ?? error.code;
        _isInitializing = false;
      });
    }
  }

  Future<void> _openCamera(int index) async {
    await _cameraController?.dispose();
    final controller = CameraController(
      _cameras[index],
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _cameraController = controller;
        _cameraIndex = index;
        _isInitializing = false;
        _error = null;
      });
    } on CameraException catch (error) {
      await controller.dispose();
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.description ?? error.code;
        _isInitializing = false;
      });
    }
  }

  Future<void> _switchCamera() async {
    final nextIndex = (_cameraIndex + 1) % _cameras.length;
    setState(() => _isInitializing = true);
    await _openCamera(nextIndex);
  }

  Future<void> _capture() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || _isCapturing) {
      return;
    }

    setState(() => _isCapturing = true);
    try {
      final appController = AppScope.of(context);
      final photo = await controller.takePicture();
      await appController.queueCapturedFile(File(photo.path));
      if (!mounted) {
        return;
      }
      setState(() => _capturedCount++);
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.description ?? error.code)));
    } finally {
      if (mounted) {
        setState(() => _isCapturing = false);
      }
    }
  }
}

class _CaptureButton extends StatelessWidget {
  const _CaptureButton({required this.isCapturing, required this.onPressed});

  final bool isCapturing;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 76,
      height: 76,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          disabledBackgroundColor: Colors.white70,
        ),
        child: isCapturing
            ? const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              )
            : const Icon(Icons.camera_alt, size: 34),
      ),
    );
  }
}
