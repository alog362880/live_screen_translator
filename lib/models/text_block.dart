/// A single OCR-recognized text block, in the coordinate space of the
/// captured screen image (physical pixels, origin top-left).
class TextBlock {
  final String id;
  final String originalText;
  final double left;
  final double top;
  final double width;
  final double height;

  /// Filled in after the AI translation call returns.
  String? translatedText;

  TextBlock({
    required this.id,
    required this.originalText,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.translatedText,
  });

  TextBlock copyWith({String? translatedText}) => TextBlock(
        id: id,
        originalText: originalText,
        left: left,
        top: top,
        width: width,
        height: height,
        translatedText: translatedText ?? this.translatedText,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': originalText,
        'bbox': [left, top, width, height],
      };

  factory TextBlock.fromJson(Map<String, dynamic> json) {
    final bbox = (json['bbox'] as List).cast<num>();
    return TextBlock(
      id: json['id'] as String,
      originalText: json['text'] as String,
      left: bbox[0].toDouble(),
      top: bbox[1].toDouble(),
      width: bbox[2].toDouble(),
      height: bbox[3].toDouble(),
      translatedText: json['translated'] as String?,
    );
  }
}
