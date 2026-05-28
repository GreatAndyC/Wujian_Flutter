import 'package:flutter/widgets.dart';

import 'app_controller.dart';

class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required AppController controller,
    required super.child,
  }) : _controller = controller;

  final AppController _controller;

  static AppController of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found in widget tree.');
    return scope!._controller;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) {
    return !identical(_controller, oldWidget._controller);
  }
}
