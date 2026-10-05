import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/translation_controller.dart';
import 'floating_trigger_button.dart';
import 'settings_page.dart';
import 'translation_overlay_stack.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<TranslationController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Screen Translate'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StatusView(controller: controller),
                const SizedBox(height: 12),
                // No-op on Windows/Web (prepareCaptureSession() is a
                // default no-op there — captureOnce() is self-contained
                // on those platforms). On iOS this shows the system
                // ReplayKit broadcast picker, which the user must start
                // once before the floating trigger has any live frame to
                // capture — see ScreenTranslationService.prepareCaptureSession.
                TextButton.icon(
                  onPressed: controller.prepareCaptureSession,
                  icon: const Icon(Icons.screen_share_outlined),
                  label: const Text('Start live capture (iOS)'),
                ),
              ],
            ),
          ),
          // On Web, the captured frame + translated chips render right
          // here in-app (see service_web.dart's showOverlay note). On
          // Windows/iOS this is normally empty because the overlay lives
          // in its own window / Live Activity.
          if (controller.lastFrame != null && controller.lastBlocks.isNotEmpty)
            Positioned.fill(
              child: TranslationOverlayStack.fromFrame(
                frame: controller.lastFrame!,
                blocks: controller.lastBlocks,
                onDismiss: controller.dismissOverlay,
              ),
            ),
        ],
      ),
      floatingActionButton: const FloatingTriggerButton(),
    );
  }
}

class _StatusView extends StatelessWidget {
  const _StatusView({required this.controller});

  final TranslationController controller;

  @override
  Widget build(BuildContext context) {
    switch (controller.status) {
      case CaptureStatus.idle:
        return const Text('Tap the translate button to capture your screen.');
      case CaptureStatus.capturing:
        return const Text('Capturing screen…');
      case CaptureStatus.recognizing:
        return const Text('Recognizing text…');
      case CaptureStatus.translating:
        return const Text('Translating…');
      case CaptureStatus.showing:
        return const Text('Rendering overlay…');
      case CaptureStatus.error:
        return Text(
          'Error: ${controller.errorMessage}',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        );
    }
  }
}
