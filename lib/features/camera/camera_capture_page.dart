import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../shared/widgets/local_image_frame.dart';
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
  Offset? _focusIndicatorPosition;
  File? _lastCapturedPreview;
  bool _thumbnailDocked = true;
  Timer? _focusIndicatorTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void dispose() {
    _focusIndicatorTimer?.cancel();
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

  List<CameraDescription> get _currentDirectionCameras {
    if (_cameras.isEmpty) {
      return const [];
    }
    final currentDirection = _cameras[_cameraIndex].lensDirection;
    final matches =
        _cameras
            .where((camera) => camera.lensDirection == currentDirection)
            .toList()
          ..sort((a, b) => _lensOrder(a).compareTo(_lensOrder(b)));
    return matches;
  }

  List<CameraLensDirection> get _directions {
    return {for (final camera in _cameras) camera.lensDirection}.toList();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;
    final size = MediaQuery.sizeOf(context);
    final lensOptions = _currentDirectionCameras;
    final canSwitchDirection = _directions.length > 1;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _buildPreview(controller)),
            if (_focusIndicatorPosition != null)
              Positioned(
                left: _focusIndicatorPosition!.dx - 28,
                top: _focusIndicatorPosition!.dy - 28,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: 1,
                    duration: const Duration(milliseconds: 120),
                    child: const _FocusIndicator(),
                  ),
                ),
              ),
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
                onPressed: !canSwitchDirection || _isCapturing
                    ? null
                    : _switchDirection,
                icon: const Icon(Icons.cameraswitch_outlined),
                tooltip: '切换前后摄像头',
              ),
            ),
            if (lensOptions.length > 1)
              Positioned(
                left: 20,
                right: 20,
                top: 72,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final camera in lensOptions)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(_cameraLabel(camera)),
                            selected: camera == _cameras[_cameraIndex],
                            onSelected: _isCapturing
                                ? null
                                : (_) => _selectCamera(camera),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (_lastCapturedPreview != null)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                right: _thumbnailDocked ? 20 : (size.width - 140) / 2,
                bottom: _thumbnailDocked ? 118 : 164,
                width: _thumbnailDocked ? 88 : 140,
                height: _thumbnailDocked ? 88 : 140,
                child: _CaptureThumbnail(image: _lastCapturedPreview!),
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

    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _handleFocusTap(details, constraints.biggest),
          child: Center(child: CameraPreview(controller)),
        );
      },
    );
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
      final backOptions =
          _cameras
              .where(
                (camera) => camera.lensDirection == CameraLensDirection.back,
              )
              .toList()
            ..sort((a, b) => _lensOrder(a).compareTo(_lensOrder(b)));
      final preferred = backOptions.isNotEmpty
          ? backOptions.first
          : _cameras.first;
      _cameraIndex = _cameras.indexOf(preferred);
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
      await controller.setFocusMode(FocusMode.auto);
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

  Future<void> _switchDirection() async {
    final currentDirection = _cameras[_cameraIndex].lensDirection;
    final directions = _directions;
    final currentIndex = directions.indexOf(currentDirection);
    final nextDirection = directions[(currentIndex + 1) % directions.length];
    final candidates =
        _cameras
            .where((camera) => camera.lensDirection == nextDirection)
            .toList()
          ..sort((a, b) => _lensOrder(a).compareTo(_lensOrder(b)));
    if (candidates.isEmpty) {
      return;
    }
    await _selectCamera(candidates.first);
  }

  Future<void> _selectCamera(CameraDescription camera) async {
    final nextIndex = _cameras.indexOf(camera);
    if (nextIndex == _cameraIndex) {
      return;
    }
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
      _playCaptureThumbnailAnimation(
        appController.latestImage ?? File(photo.path),
      );
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

  Future<void> _handleFocusTap(TapDownDetails details, Size size) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    final normalizedPoint = Offset(
      (details.localPosition.dx / size.width).clamp(0.0, 1.0),
      (details.localPosition.dy / size.height).clamp(0.0, 1.0),
    );

    setState(() {
      _focusIndicatorPosition = details.localPosition;
    });
    _focusIndicatorTimer?.cancel();
    _focusIndicatorTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() => _focusIndicatorPosition = null);
      }
    });

    try {
      await controller.setFocusMode(FocusMode.auto);
      if (controller.value.focusPointSupported) {
        await controller.setFocusPoint(normalizedPoint);
      }
      if (controller.value.exposurePointSupported) {
        await controller.setExposurePoint(normalizedPoint);
      }
    } on CameraException {
      // Keep tap-to-focus as a best-effort enhancement.
    }
  }

  void _playCaptureThumbnailAnimation(File preview) {
    setState(() {
      _lastCapturedPreview = preview;
      _thumbnailDocked = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      setState(() => _thumbnailDocked = true);
    });
  }

  int _lensOrder(CameraDescription camera) {
    return switch (camera.lensType) {
      CameraLensType.ultraWide => 0,
      CameraLensType.wide => 1,
      CameraLensType.telephoto => 2,
      CameraLensType.unknown => 3,
    };
  }

  String _cameraLabel(CameraDescription camera) {
    if (camera.lensDirection == CameraLensDirection.front) {
      return '前置';
    }
    if (camera.lensDirection == CameraLensDirection.external) {
      return '外接';
    }
    return switch (camera.lensType) {
      CameraLensType.ultraWide => '0.5x',
      CameraLensType.wide => '1x',
      CameraLensType.telephoto => '2x',
      CameraLensType.unknown => '镜头',
    };
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

class _FocusIndicator extends StatelessWidget {
  const _FocusIndicator();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white, width: 2),
        borderRadius: BorderRadius.circular(16),
      ),
    );
  }
}

class _CaptureThumbnail extends StatelessWidget {
  const _CaptureThumbnail({required this.image});

  final File image;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white, width: 2),
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 14,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: LocalImageFrame(
        path: image.path,
        width: double.infinity,
        height: double.infinity,
        borderRadius: BorderRadius.circular(16),
        backgroundColor: Colors.black,
        padding: const EdgeInsets.all(6),
      ),
    );
  }
}
