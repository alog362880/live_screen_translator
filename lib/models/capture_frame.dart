import 'dart:typed_data';

/// A single captured screen frame plus the coordinate-mapping info needed
/// to place translated text back over the original screen.
class CaptureFrame {
  /// PNG-encoded image bytes (already decoded/re-encoded to a format both
  /// ML Kit and the overlay renderer can consume).
  final Uint8List pngBytes;

  /// Size of [pngBytes] in physical pixels.
  final int pixelWidth;
  final int pixelHeight;

  /// Logical (DPI-independent) size of the screen region this frame came
  /// from — used to scale OCR bounding boxes back to the overlay's
  /// logical coordinate space.
  final double logicalWidth;
  final double logicalHeight;

  /// Top-left offset of the captured region in logical desktop
  /// coordinates (0,0 for a full-screen or web-tab capture).
  final double originX;
  final double originY;

  const CaptureFrame({
    required this.pngBytes,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.logicalWidth,
    required this.logicalHeight,
    this.originX = 0,
    this.originY = 0,
  });

  double get scaleX => logicalWidth / pixelWidth;
  double get scaleY => logicalHeight / pixelHeight;
}
