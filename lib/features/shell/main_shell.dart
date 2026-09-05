import 'package:flutter/material.dart';

import '../../shared/widgets/app_ui.dart';
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                final useRail = constraints.maxWidth >= 600;
                final pageStack = IndexedStack(
                  index: controller.currentIndex,
                  children: pages,
                );
                if (!useRail) {
                  return pageStack;
                }
                return Row(
                  children: [
                    NavigationRail(
                      selectedIndex: controller.currentIndex,
                      onDestinationSelected: controller.setCurrentIndex,
                      extended: constraints.maxWidth >= 960,
                      minExtendedWidth: 196,
                      groupAlignment: -0.72,
                      leading: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.xs,
                          AppSpacing.lg,
                          AppSpacing.xs,
                          AppSpacing.xl,
                        ),
                        child: Tooltip(
                          message: '物见',
                          child: CircleAvatar(
                            radius: 22,
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primaryContainer,
                            child: Icon(
                              Icons.auto_awesome_mosaic_outlined,
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ),
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.camera_alt_outlined),
                          selectedIcon: Icon(Icons.camera_alt),
                          label: Text('拍摄'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.inventory_2_outlined),
                          selectedIcon: Icon(Icons.inventory_2),
                          label: Text('物品'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.tune_outlined),
                          selectedIcon: Icon(Icons.tune),
                          label: Text('设置'),
                        ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: pageStack),
                  ],
                );
              },
            ),
          ),
          bottomNavigationBar: MediaQuery.sizeOf(context).width < 600
              ? NavigationBar(
                  selectedIndex: controller.currentIndex,
                  onDestinationSelected: controller.setCurrentIndex,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.camera_alt_outlined),
                      selectedIcon: Icon(Icons.camera_alt),
                      label: '拍摄',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.inventory_2_outlined),
                      selectedIcon: Icon(Icons.inventory_2),
                      label: '物品',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.tune_outlined),
                      selectedIcon: Icon(Icons.tune),
                      label: '设置',
                    ),
                  ],
                )
              : null,
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
