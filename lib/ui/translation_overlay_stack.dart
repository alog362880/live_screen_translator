import 'package:flutter/material.dart';

import '../models/capture_frame.dart';
import '../models/text_block.dart';

/// Transparent Stack that positions a translated-text chip directly over
/// each recognized block's original location.
///
/// Coordinate mapping: OCR/vision boxes come back in the *captured
/// frame's pixel space* ([TextBlock.left]/top/width/height). To draw them
/// over the logical-pixel widget tree, scale by [scaleX]/[scaleY]
/// (== logicalSize / pixelSize, accounting for device pixel ratio / OS
/// display scaling) and add the origin offset for region captures.
class TranslationOverlayStack extends StatelessWidget {
  const TranslationOverlayStack({
    super.key,
    required this.blocks,
    this.scaleX = 1.0,
    this.scaleY = 1.0,
    this.originX = 0.0,
    this.originY = 0.0,
    this.onDismiss,
  });

  /// Convenience constructor for the common case of rendering straight
  /// from a just-captured [CaptureFrame] (used by home_page.dart's
  /// in-app Web overlay).
  factory TranslationOverlayStack.fromFrame({
    Key? key,
    required CaptureFrame frame,
    required List<TextBlock> blocks,
    VoidCallback? onDismiss,
  }) =>
      TranslationOverlayStack(
        key: key,
        blocks: blocks,
        scaleX: frame.scaleX,
        scaleY: frame.scaleY,
        originX: frame.originX,
        originY: frame.originY,
        onDismiss: onDismiss,
      );

  final List<TextBlock> blocks;
  final double scaleX;
  final double scaleY;
  final double originX;
  final double originY;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Tapping empty space dismisses the overlay; chips themselves
        // stop propagation so tapping translated text doesn't dismiss.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        for (final block in blocks)
          Positioned(
            left: (block.left + originX) * scaleX,
            top: (block.top + originY) * scaleY,
            width: block.width * scaleX,
            height: block.height * scaleY,
            child: _TranslationChip(block: block),
          ),
      ],
    );
  }
}

class _TranslationChip extends StatelessWidget {
  const _TranslationChip({required this.block});

  final TextBlock block;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        // withOpacity kept (not withValues) for compatibility with older
        // Flutter SDKs than this template's declared minimum.
        // ignore: deprecated_member_use
        color: Colors.black.withOpacity(0.78),
        borderRadius: BorderRadius.circular(4),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          block.translatedText ?? block.originalText,
          style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.1),
        ),
      ),
    );
  }
}
