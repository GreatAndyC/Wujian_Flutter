import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../../shared/widgets/local_image_frame.dart';
import '../shell/app_scope.dart';

class CameraCapturePage extends StatefulWidget {
  const CameraCapturePage({super.key, this.captureBox});

  final String? captureBox;

  @override
  State<CameraCapturePage> createState() => _CameraCapturePageState();
}

class _CameraCapturePageState extends State<CameraCapturePage>
    with WidgetsBindingObserver {
  static const MethodChannel _platformChannel = MethodChannel(
    'com.wujian.app.icheck/file_saver',
  );
  CameraController? _cameraController;
  List<CameraDescription> _cameras = const [];
  Map<String, _NativeCameraMetadata> _cameraMetadataById = const {};
  int _cameraIndex = 0;
  double _minZoomLevel = 1;
  double _maxZoomLevel = 1;
  double _selectedZoomLevel = 1;
  int? _mainBackCameraIndex;
  int? _wideBackCameraIndex;
  int? _teleBackCameraIndex;
  bool _isInitializing = true;
  bool _isCapturing = false;
  bool _isTorchEnabled = false;
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

  List<CameraLensDirection> get _directions {
    return {for (final camera in _cameras) camera.lensDirection}.toList();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;
    final size = MediaQuery.sizeOf(context);
    final canSwitchDirection = _directions.length > 1;
    final captureBox = widget.captureBox?.trim() ?? '';
    final activeCamera = _cameras.isEmpty ? null : _cameras[_cameraIndex];
    final isBackCamera = activeCamera != null && _isBackCamera(activeCamera);
    final zoomPresets = isBackCamera ? _zoomPresetsFor() : const <double>[];

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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton.filledTonal(
                    onPressed:
                        controller == null ||
                            !controller.value.isInitialized ||
                            _isCapturing
                        ? null
                        : _toggleTorch,
                    icon: Icon(
                      _isTorchEnabled ? Icons.flash_on : Icons.flash_off,
                    ),
                    tooltip: _isTorchEnabled ? '关闭常亮闪光灯' : '打开常亮闪光灯',
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: !canSwitchDirection || _isCapturing
                        ? null
                        : _switchDirection,
                    icon: const Icon(Icons.cameraswitch_outlined),
                    tooltip: '切换前后摄像头',
                  ),
                ],
              ),
            ),
            if (captureBox.isNotEmpty)
              Positioned(
                left: 20,
                right: 72,
                top: 72,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.58),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      '当前箱子：$captureBox',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            if (activeCamera != null)
              Positioned(
                left: 20,
                right: 20,
                top: captureBox.isNotEmpty ? 118 : 72,
                child: _InfoBadge(
                  label: '当前镜头：${_cameraFullLabel(activeCamera)}',
                ),
              ),
            if (_lastCapturedPreview != null)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                right: _thumbnailDocked ? 20 : (size.width - 140) / 2,
                bottom: _thumbnailDocked ? 150 : 196,
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
                    const SizedBox(height: 0)
                  else
                    const SizedBox.shrink(),
                  if (_capturedCount > 0)
                    _InfoBadge(label: '已加入 $_capturedCount 张，后台识别中'),
                  if (zoomPresets.length > 1) ...[
                    const SizedBox(height: 14),
                    _ZoomSelector(
                      zoomLevels: zoomPresets,
                      currentZoomLevel: _selectedZoomLevel,
                      isCapturing: _isCapturing,
                      onSelected: _setZoomLevel,
                      labelBuilder: _zoomLabel,
                    ),
                  ],
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
      _cameraMetadataById = await _loadCameraMetadata();
      if (_cameras.isEmpty) {
        throw CameraException('no_camera', '没有找到可用相机');
      }
      final backOptions = _cameras.where(_isBackCamera).toList()
        ..sort(
          (a, b) => _preferredBackCameraScore(
            a,
          ).compareTo(_preferredBackCameraScore(b)),
        );
      final preferred = backOptions.isNotEmpty
          ? backOptions.first
          : _cameras.first;
      _mainBackCameraIndex = _resolveMainBackCameraIndex();
      _wideBackCameraIndex = _resolveWideBackCameraIndex();
      _teleBackCameraIndex = _resolveTeleBackCameraIndex();
      _logCameraMapping();
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
    final camera = _cameras[index];
    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller.initialize();
      await controller.setFocusMode(FocusMode.auto);
      _minZoomLevel = await controller.getMinZoomLevel();
      _maxZoomLevel = await controller.getMaxZoomLevel();
      final defaultZoom = _defaultZoomLevelFor(camera);
    final enableTorch = _isTorchEnabled && _isBackCamera(camera);
    await controller.setFlashMode(
      enableTorch ? FlashMode.torch : FlashMode.off,
    );
      await controller.setZoomLevel(defaultZoom);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _cameraController = controller;
        _cameraIndex = index;
        _selectedZoomLevel = defaultZoom;
        _isTorchEnabled = enableTorch;
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
    final candidates = _cameras
        .where((camera) => camera.lensDirection == nextDirection)
        .toList();
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

  Future<void> _setZoomLevel(double zoomLevel) async {
    if (_isCapturing) {
      return;
    }

    final targetCameraIndex = _preferredBackCameraIndexForZoom(zoomLevel);
    if (targetCameraIndex != null && targetCameraIndex != _cameraIndex) {
      setState(() => _isInitializing = true);
      await _openCamera(targetCameraIndex);
    }

    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    final target = zoomLevel.clamp(_minZoomLevel, _maxZoomLevel).toDouble();
    await controller.setZoomLevel(target);
    if (!mounted) {
      return;
    }
    setState(() => _selectedZoomLevel = target);
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
      await appController.queueCapturedFile(
        File(photo.path),
        box: widget.captureBox,
      );
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

  Future<void> _toggleTorch() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    final nextValue = !_isTorchEnabled;
    try {
      await controller.setFlashMode(
        nextValue ? FlashMode.torch : FlashMode.off,
      );
      if (!mounted) {
        return;
      }
      setState(() => _isTorchEnabled = nextValue);
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.description ?? error.code)));
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

  String _cameraFullLabel(CameraDescription camera) {
    if (camera.lensDirection == CameraLensDirection.front) {
      return '前置';
    }
    if (camera.lensDirection == CameraLensDirection.external) {
      return '外接';
    }
    return '后置 · ${_cameraRoleLabel(camera)}';
  }

  String _zoomLabel(double zoomLevel) {
    if ((zoomLevel - 0.6).abs() < 0.11 || (zoomLevel - 0.5).abs() < 0.11) {
      return '广角';
    }
    if ((zoomLevel - 1).abs() < 0.11) {
      return '1x';
    }
    if ((zoomLevel - 2).abs() < 0.11) {
      return '2x';
    }
    return '${zoomLevel.toStringAsFixed(1)}x';
  }

  double? _primaryFocalLength(CameraDescription camera) {
    final metadata = _lookupMetadata(camera);
    if (metadata == null || metadata.focalLengths.isEmpty) {
      return null;
    }
    return metadata.focalLengths.first;
  }

  _NativeCameraMetadata? _lookupMetadata(CameraDescription camera) {
    final direct = _cameraMetadataById[camera.name];
    if (direct != null) {
      return direct;
    }
    final normalizedId = _extractCameraId(camera.name);
    if (normalizedId == null) {
      return null;
    }
    return _cameraMetadataById[normalizedId];
  }

  bool _isBackCamera(CameraDescription camera) {
    final metadata = _lookupMetadata(camera);
    if (metadata != null) {
      return metadata.facing == 'back';
    }
    return camera.lensDirection == CameraLensDirection.back;
  }

  String? _extractCameraId(String rawName) {
    final match = RegExp(r'(\d+)').firstMatch(rawName);
    return match?.group(1);
  }

  Future<Map<String, _NativeCameraMetadata>> _loadCameraMetadata() async {
    try {
      final rawList = await _platformChannel.invokeListMethod<dynamic>(
        'getCameraMetadata',
      );
      if (rawList == null) {
        return const {};
      }
      final result = <String, _NativeCameraMetadata>{};
      for (final entry in rawList) {
        if (entry is! Map) {
          continue;
        }
        final map = Map<Object?, Object?>.from(entry);
        final cameraId = map['cameraId']?.toString();
        if (cameraId == null || cameraId.isEmpty) {
          continue;
        }
        final focalLengths =
            (map['focalLengths'] as List?)
                ?.map((value) => (value as num).toDouble())
                .toList() ??
            const <double>[];
        result[cameraId] = _NativeCameraMetadata(
          cameraId: cameraId,
          facing: map['facing']?.toString() ?? 'unknown',
          focalLengths: focalLengths,
        );
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  int _preferredBackCameraScore(CameraDescription camera) {
    final focal = _primaryFocalLength(camera);
    final base = switch (camera.lensType) {
      CameraLensType.wide => 0,
      CameraLensType.ultraWide => 1000,
      CameraLensType.telephoto => 2000,
      CameraLensType.unknown => 3000,
    };
    if (focal == null) {
      return base + 9999;
    }
    return base + _targetFocalLengthDistance(focal, 3.2);
  }

  double _defaultZoomLevelFor(CameraDescription camera) {
    if (!_isBackCamera(camera)) {
      return _minZoomLevel.clamp(1.0, 1.0).toDouble();
    }
    final wideIndex = _wideBackCameraIndex;
    final isWideCamera =
        wideIndex != null && identical(_cameras[wideIndex], camera);
    if (isWideCamera && _minZoomLevel <= 0.6 && _maxZoomLevel >= 0.6) {
      return 0.6;
    }
    return 1.0.clamp(_minZoomLevel, _maxZoomLevel).toDouble();
  }

  List<double> _zoomPresetsFor() {
    if (_mainBackCameraIndex == null) {
      return const [];
    }
    final presets = <double>[
      if (_wideBackCameraIndex != null) 0.6,
      1.0,
      if (_teleBackCameraIndex != null) 2.0,
    ];
    if (presets.isEmpty) {
      return [_selectedZoomLevel];
    }
    return presets;
  }

  int? _resolveMainBackCameraIndex() {
    var bestIndex = -1;
    var bestScore = 9999;
    for (var index = 0; index < _cameras.length; index++) {
      final camera = _cameras[index];
      if (!_isBackCamera(camera)) {
        continue;
      }
      final score = _preferredBackCameraScore(camera);
      if (score < bestScore) {
        bestScore = score;
        bestIndex = index;
      }
    }
    return bestIndex < 0 ? null : bestIndex;
  }

  int? _resolveWideBackCameraIndex() {
    var bestIndex = -1;
    var bestFocal = 9999.0;
    for (var index = 0; index < _cameras.length; index++) {
      final camera = _cameras[index];
      if (!_isBackCamera(camera)) {
        continue;
      }
      final focal = _primaryFocalLength(camera);
      if (focal == null) {
        continue;
      }
      if (focal < bestFocal) {
        bestFocal = focal;
        bestIndex = index;
      }
    }
    if (bestIndex < 0) {
      return null;
    }
    final mainIndex = _mainBackCameraIndex;
    if (mainIndex != null && mainIndex == bestIndex) {
      return null;
    }
    return bestIndex;
  }

  int? _resolveTeleBackCameraIndex() {
    var bestIndex = -1;
    var bestFocal = -1.0;
    for (var index = 0; index < _cameras.length; index++) {
      final camera = _cameras[index];
      if (!_isBackCamera(camera)) {
        continue;
      }
      final focal = _primaryFocalLength(camera);
      if (focal == null) {
        continue;
      }
      if (focal > bestFocal) {
        bestFocal = focal;
        bestIndex = index;
      }
    }
    if (bestIndex < 0) {
      return null;
    }
    final mainIndex = _mainBackCameraIndex;
    if (mainIndex != null && mainIndex == bestIndex) {
      return null;
    }
    return bestIndex;
  }

  int? _preferredBackCameraIndexForZoom(double zoomLevel) {
    if (zoomLevel < 0.9) {
      return _wideBackCameraIndex;
    }
    if (zoomLevel >= 1.6) {
      return _teleBackCameraIndex ?? _mainBackCameraIndex;
    }
    return _mainBackCameraIndex;
  }

  String _cameraRoleLabel(CameraDescription camera) {
    final metadata = _lookupMetadata(camera);
    final focal = _primaryFocalLength(camera);
    final lensType = camera.lensType;
    if (metadata == null) {
      return '${_lensTypeLabel(lensType)} · ${_zoomLabel(_selectedZoomLevel)}';
    }
    final focalText = focal == null ? '未知焦段' : '${focal.toStringAsFixed(1)}mm';
    return '${_lensTypeLabel(lensType)} · ${metadata.cameraId} · $focalText';
  }

  String _lensTypeLabel(CameraLensType type) {
    return switch (type) {
      CameraLensType.ultraWide => '广角',
      CameraLensType.wide => '主摄',
      CameraLensType.telephoto => '长焦',
      CameraLensType.unknown => '镜头',
    };
  }

  int _targetFocalLengthDistance(double focal, double target) {
    return ((focal - target).abs() * 100).round();
  }

  void _logCameraMapping() {
    if (!kDebugMode) {
      return;
    }
    for (final camera in _cameras) {
      final metadata = _lookupMetadata(camera);
      debugPrint(
        '[camera] name=${camera.name}, '
        'direction=${camera.lensDirection}, '
        'type=${camera.lensType}, '
        'role=${_cameraRoleName(camera)}, '
        'metadataId=${metadata?.cameraId ?? "-"}, '
        'facing=${metadata?.facing ?? "-"}, '
        'focal=${metadata?.focalLengths.join(",") ?? "-"}',
      );
    }
  }

  String _cameraRoleName(CameraDescription camera) {
    if (camera.lensDirection != CameraLensDirection.back) {
      return camera.lensDirection.name;
    }
    final wideIndex = _wideBackCameraIndex;
    if (wideIndex != null && identical(_cameras[wideIndex], camera)) {
      return 'wide';
    }
    final teleIndex = _teleBackCameraIndex;
    if (teleIndex != null && identical(_cameras[teleIndex], camera)) {
      return 'tele';
    }
    final mainIndex = _mainBackCameraIndex;
    if (mainIndex != null && identical(_cameras[mainIndex], camera)) {
      return 'main';
    }
    return 'back';
  }

}

class _NativeCameraMetadata {
  const _NativeCameraMetadata({
    required this.cameraId,
    required this.facing,
    required this.focalLengths,
  });

  final String cameraId;
  final String facing;
  final List<double> focalLengths;
}

class _InfoBadge extends StatelessWidget {
  const _InfoBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _ZoomSelector extends StatelessWidget {
  const _ZoomSelector({
    required this.zoomLevels,
    required this.currentZoomLevel,
    required this.isCapturing,
    required this.onSelected,
    required this.labelBuilder,
  });

  final List<double> zoomLevels;
  final double currentZoomLevel;
  final bool isCapturing;
  final ValueChanged<double> onSelected;
  final String Function(double zoomLevel) labelBuilder;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final zoomLevel in zoomLevels)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _LensButton(
                label: labelBuilder(zoomLevel),
                selected: (zoomLevel - currentZoomLevel).abs() < 0.05,
                onTap: isCapturing ? null : () => onSelected(zoomLevel),
              ),
            ),
        ],
      ),
    );
  }
}

class _LensButton extends StatelessWidget {
  const _LensButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.white : Colors.white.withValues(alpha: 0.16),
      shape: const StadiumBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.black : Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
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
