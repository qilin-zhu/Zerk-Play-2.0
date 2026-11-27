import 'package:flutter/widgets.dart';

import '../core/input_mode.dart';
import '../focus/focus_zone.dart';

class RowsScrollView extends StatelessWidget {
  const RowsScrollView({
    super.key,
    required this.controller,
    required this.children,
    this.top = 20,
    this.bottom,
    this.physics,
  });

  final RevealController controller;
  final List<Widget> children;
  final double top;

  /// Overrides the bottom padding. The home page pages its rows by hand and
  /// needs enough slack under the last one for it to reach the same slot as
  /// every other row.
  final double? bottom;

  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return ValueListenableBuilder(
      valueListenable: InputMode.pointer,
      builder: (context, pointer, _) => SingleChildScrollView(
        controller: controller,
        physics: physics,
        child: Padding(
          padding: EdgeInsets.only(top: top, bottom: bottom ?? (pointer ? 60 : height * 0.5)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ),
    );
  }
}

class PageScrollView extends StatelessWidget {
  const PageScrollView({super.key, this.controller, required this.padding, required this.children});

  final ScrollController? controller;
  final EdgeInsets padding;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        controller: controller,
        padding: padding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );
}
