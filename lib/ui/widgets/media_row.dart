import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import 'common.dart';
import 'scroll_arrows.dart';

const double contentLeft = Zs.railCollapsed + 56;

double posterGridCardWidth(double width, int columns) =>
    ((width - contentLeft - 120 - Zs.cardGap * (columns - 1)) / columns).clamp(100.0, 600.0);

class MediaRow extends StatefulWidget {
  const MediaRow({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    required this.height,
    this.trailingTitle,
    this.gap = Zs.cardGap,
    this.left = contentLeft,
    this.initialIndex,
    this.itemExtent,
  });

  final double left;

  final String title;
  final Widget? trailingTitle;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  final double height;
  final double gap;

  /// Item to line up with [left] the first time the row appears, instead of
  /// starting at the first card. Used by the details page so that opening
  /// episode 201 doesn't show episode 1. Needs [itemExtent] to compute the
  /// offset, because the cards beyond the viewport are not laid out yet.
  final int? initialIndex;

  /// Card width plus [gap].
  final double? itemExtent;

  @override
  State<MediaRow> createState() => _MediaRowState();
}

class _MediaRowState extends State<MediaRow> {
  RevealController? _controller;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// Where a card at [MediaRow.initialIndex] would sit after the row has been
  /// anchored on it. The content is the same arithmetic the anchored reveal
  /// does later, just applied before the first layout instead of after.
  double _initialOffset(BuildContext context) {
    final index = widget.initialIndex;
    final extent = widget.itemExtent;
    if (index == null || extent == null || index <= 0) return 0;
    final viewport = MediaQuery.sizeOf(context).width;
    final content = widget.itemCount * extent - widget.gap + 2 * widget.left;
    final max = (content - viewport).clamp(0.0, double.infinity);
    return (index * extent).clamp(0.0, max);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller ??= RevealController(
      mode: RevealMode.anchored,
      anchor: widget.left,
      initialScrollOffset: _initialOffset(context),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: EdgeInsets.only(left: widget.left, bottom: 18),
        child: Row(children: [
          Text(widget.title, style: Zt.rowTitle),
          if (widget.trailingTitle != null) ...[const SizedBox(width: 16), widget.trailingTitle!],
        ]),
      ),
      SizedBox(
        height: widget.height,
        child: PointerScrollArrows(
          controller: controller,
          leftInset: widget.left,
          child: FocusZone(
            debugLabel: 'row:${widget.title}',
            child: ListView.separated(
              controller: controller,
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
              padding: EdgeInsets.symmetric(horizontal: widget.left),
              itemCount: widget.itemCount,
              separatorBuilder: (_, _) => SizedBox(width: widget.gap),
              itemBuilder: widget.itemBuilder,
            ),
          ),
        ),
      ),
    ]);
  }
}

/// Small focusable chip for a row's title line - the episode sort toggle sits
/// here rather than among the action buttons, since it acts on the row below
/// it and not on the title itself.
///
/// Only the icon is drawn while the chip is idle: a permanent pill with text
/// next to every row title reads as content, and the sort direction is
/// something the viewer looks up once, on the way into the row. Focusing (or
/// hovering) it expands the label so the current direction is still readable,
/// exactly like the collapsed action buttons on the details page.
class RowTitleButton extends StatelessWidget {
  const RowTitleButton({super.key, required this.label, this.icon, this.onSelect, this.focusNode, this.iconQuarterTurns = 3});

  final String label;
  final IconData? icon;
  final VoidCallback? onSelect;
  final FocusNode? focusNode;

  /// Counter-clockwise quarter turns applied to [icon]. The default rotates a
  /// vertical glyph (swap_vert) a quarter turn to the left, so the arrows read
  /// as "order", not as "scroll up/down".
  final int iconQuarterTurns;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: focusNode,
      onSelect: onSelect,
      builder: (context, focused) {
        final fg = focused ? Zc.background : Zc.textMuted;
        return AnimatedContainer(
          duration: Zm.fast,
          curve: Zm.curve,
          height: 42,
          padding: EdgeInsets.only(left: 11, right: focused ? 20 : 11),
          decoration: BoxDecoration(
            color: focused ? Colors.white : Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(21),
          ),
          child: AnimatedSize(
            duration: Zm.fast,
            curve: Zm.curve,
            alignment: Alignment.centerLeft,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null)
                RotatedBox(quarterTurns: iconQuarterTurns, child: Icon(icon, size: 20, color: fg)),
              if (focused && icon != null) const SizedBox(width: 8),
              if (focused)
                Text(label, style: Zt.label.copyWith(fontSize: 19, color: fg)),
            ]),
          ),
        );
      },
    );
  }
}

class SkeletonRow extends StatelessWidget {
  const SkeletonRow({super.key, required this.cardWidth, required this.cardHeight, this.count = 8});

  final double cardWidth;
  final double cardHeight;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(
        padding: EdgeInsets.only(left: contentLeft, bottom: 18),
        child: SkeletonBox(width: 240, height: 28, radius: 6),
      ),
      SizedBox(
        height: cardHeight,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: contentLeft),
          itemCount: count,
          separatorBuilder: (_, _) => const SizedBox(width: Zs.cardGap),
          itemBuilder: (_, _) => SkeletonBox(width: cardWidth, height: cardHeight),
        ),
      ),
    ]);
  }
}
