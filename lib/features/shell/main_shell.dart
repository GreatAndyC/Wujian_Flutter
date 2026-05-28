import 'package:flutter/material.dart';

import '../home/home_page.dart';
import '../settings/settings_page.dart';
import '../view/items_page.dart';
import 'app_controller.dart';
import 'app_scope.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  AppController? _controller;
  String? _lastHandledMessage;

  @override
  void dispose() {
    _controller?.removeListener(_handleControllerChanged);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextController = AppScope.of(context);
    if (identical(_controller, nextController)) {
      return;
    }
    _controller?.removeListener(_handleControllerChanged);
    _controller = nextController;
    _controller!.addListener(_handleControllerChanged);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller ?? AppScope.of(context);
    final pages = const [HomePage(), ItemsPage(), SettingsPage()];
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Scaffold(
          body: SafeArea(
            child: IndexedStack(
              index: controller.currentIndex,
              children: pages,
            ),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: controller.currentIndex,
            onDestinationSelected: controller.setCurrentIndex,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.camera_alt_outlined),
                selectedIcon: Icon(Icons.camera_alt),
                label: '主页',
              ),
              NavigationDestination(
                icon: Icon(Icons.inventory_2_outlined),
                selectedIcon: Icon(Icons.inventory_2),
                label: '视图',
              ),
              NavigationDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune),
                label: '设置',
              ),
            ],
          ),
        );
      },
    );
  }

  void _handleControllerChanged() {
    final controller = _controller;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!mounted || controller == null || messenger == null) {
      return;
    }

    final message = controller.message;
    if (message == null) {
      _lastHandledMessage = null;
      return;
    }
    if (_lastHandledMessage == message) {
      return;
    }

    _lastHandledMessage = message;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    controller.clearMessage();
  }
}
