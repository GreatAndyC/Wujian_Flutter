import 'package:flutter/material.dart';

import '../home/home_page.dart';
import '../settings/settings_page.dart';
import '../view/items_page.dart';
import 'app_scope.dart';

class MainShell extends StatelessWidget {
  const MainShell({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final pages = const [HomePage(), ItemsPage(), SettingsPage()];
        final messenger = ScaffoldMessenger.maybeOf(context);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final message = controller.message;
          if (message != null && messenger != null) {
            messenger
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(message)));
            controller.clearMessage();
          }
        });

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
}
