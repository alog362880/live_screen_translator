import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/translation_controller.dart';

/// The tap target described in the spec: a small persistent button that,
/// on Windows, lives in a separate always-on-top transparent window (see
/// windows overlay wiring in service_windows.dart) and, on Web/iOS,
/// renders in-app since neither platform allows a true system-wide
/// floating widget from a regular app.
class FloatingTriggerButton extends StatelessWidget {
  const FloatingTriggerButton({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<TranslationController>();
    final busy = controller.status != CaptureStatus.idle &&
        controller.status != CaptureStatus.error;

    return FloatingActionButton(
      tooltip: 'Capture & translate screen',
      onPressed: busy ? null : controller.runCaptureAndTranslate,
      child: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.translate),
    );
  }
}
