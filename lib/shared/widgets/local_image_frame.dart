import 'dart:io';

import 'package:flutter/material.dart';

class LocalImageFrame extends StatelessWidget {
  const LocalImageFrame({
    super.key,
    required this.path,
    this.width,
    this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.backgroundColor = const Color(0xFF171717),
    this.padding = const EdgeInsets.all(8),
    this.onTap,
  });

  final String path;
  final double? width;
  final double? height;
  final BorderRadius borderRadius;
  final Color backgroundColor;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  static bool exists(String path) {
    return path.trim().isNotEmpty && File(path).existsSync();
  }

  @override
  Widget build(BuildContext context) {
    final content = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: borderRadius,
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding,
        child: Image.file(
          File(path),
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    if (onTap == null) {
      return content;
    }

    return InkWell(onTap: onTap, borderRadius: borderRadius, child: content);
  }
}

class LocalImageViewerPage extends StatelessWidget {
  const LocalImageViewerPage({super.key, required this.path, this.title});

  final String path;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title ?? '查看图片'),
      ),
      body: SafeArea(
        child: Center(
          child: InteractiveViewer(
            minScale: 0.8,
            maxScale: 4,
            child: LocalImageFrame(
              path: path,
              borderRadius: BorderRadius.circular(0),
              backgroundColor: Colors.black,
              padding: const EdgeInsets.all(16),
            ),
          ),
        ),
      ),
    );
  }
}
