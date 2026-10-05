# Wiring `screen_capture_channel` into the Windows runner

Already done in this template — `flutter_window.cpp` registers the channel
in `FlutterWindow::OnCreate()` and `CMakeLists.txt` builds
`screen_capture_channel.cpp` + links `windowscodecs.lib` (WIC, used for
PNG encoding). Verified with `flutter build windows` (requires a complete
Visual Studio "Desktop development with C++" workload — run
`flutter doctor` to check). If you copy this channel into a *different*
Flutter Windows project's runner from scratch, repeat both edits:

1. In `flutter_window.cpp`, `#include "screen_capture_channel.h"` and call
   it right after `RegisterPlugins(...)`, inside `FlutterWindow::OnCreate()`
   (see the block right below that call in this file for the exact code).

2. Add `screen_capture_channel.cpp` to `CMakeLists.txt`'s
   `add_executable(${BINARY_NAME} ...)` source list, and link
   `windowscodecs.lib` alongside the existing Flutter Windows libs.

## Overlay window transparency (`desktop_multi_window` + `window_manager`)

The secondary overlay window spawned in `service_windows.dart`
(`DesktopMultiWindow.createWindow`) runs the same compiled exe re-entered
at `main(args)` with `args.first == 'multi_window'` (see `lib/main.dart`).
Inside that window's own Flutter engine instance, call once at startup
(e.g. top of `_OverlayWindowApp`'s `initState` if you convert it to a
`StatefulWidget`):

```dart
await windowManager.ensureInitialized();
await windowManager.setAsFrameless();
await windowManager.setBackgroundColor(Colors.transparent);
await windowManager.setAlwaysOnTop(true);
await windowManager.setSkipTaskbar(true);
await windowManager.setIgnoreMouseEvents(true, forward: true);
// forward: true lets clicks pass through empty space to the desktop/apps
// below while still hitting the translated-text chips themselves; toggle
// setIgnoreMouseEvents(false) only while the pointer is over a chip if you
// want the chips to be tappable (e.g. to copy the translated text).
```

`window_manager`'s Windows implementation sets `WS_EX_LAYERED | WS_EX_TRANSPARENT`
under the hood for frameless + transparent + click-through, which is the
same mechanism apps like PowerToys' text extractor overlay use.

## Region capture (`captureRegion`) performance

`RegionSelector::Render()` in `screen_capture_channel.cpp` redraws the
*entire* virtual-screen-sized ARGB buffer on every `WM_MOUSEMOVE` (using
`std::fill_n` per row, not a naive per-pixel loop, so it's cheaper than it
sounds — but it's still O(width × height) per frame). This is smooth
enough on a single 1080p–1440p monitor; on a large multi-monitor virtual
screen (e.g. three 4K displays) you may notice drag lag. If so, switch to
a dirty-rect update: only re-render the bounding box of
`old_selection ∪ new_selection` (expanded by the border width) instead of
the full buffer, and call `UpdateLayeredWindow` with that sub-rect via its
`pptDst`/`psize` parameters offset into the same persistent DIB section
rather than reallocating one every call.

## Multi-window CMake requirement

`desktop_multi_window` requires the Windows runner to be built with
`FLUTTER_TARGET_PLATFORM=windows-x64` and the plugin's own generated
`generated_plugin_registrant.cc` include — this is handled automatically
by `flutter pub get` + `flutter build windows` once the package is in
`pubspec.yaml`; no manual CMake edit needed beyond step 2 above.
