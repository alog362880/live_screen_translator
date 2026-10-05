// Reference-only raw JS glue for navigator.mediaDevices.getDisplayMedia.
//
// lib/services/service_web.dart implements capture using package:web's
// typed dart:js_interop bindings directly (the modern, type-safe
// replacement for hand-written `@JS()` externs bound to a file like this
// one) — so this file is NOT loaded by index.html and nothing in lib/
// references it.
//
// Keep it only if you need to interop with a JS library that doesn't
// ship its own package:web-compatible types, e.g. a third-party
// screen-capture polyfill: add `<script src="screen_capture_interop.js">`
// to web/index.html, then bind to `window.ScreenCaptureInterop.capture`
// from Dart with `@JS('ScreenCaptureInterop.capture') external JSPromise
// capture();`.

window.ScreenCaptureInterop = {
  /**
   * @returns {Promise<{pngDataUrl: string, width: number, height: number}>}
   */
  async capture() {
    const stream = await navigator.mediaDevices.getDisplayMedia({ video: true });
    const video = document.createElement('video');
    video.srcObject = stream;
    video.muted = true;
    await video.play();

    // Wait one frame so videoWidth/videoHeight are populated.
    await new Promise((resolve) => {
      if (video.readyState >= 2) return resolve();
      video.onloadedmetadata = () => resolve();
    });

    const canvas = document.createElement('canvas');
    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;
    const ctx = canvas.getContext('2d');
    ctx.drawImage(video, 0, 0);

    stream.getTracks().forEach((track) => track.stop());

    return {
      pngDataUrl: canvas.toDataURL('image/png'),
      width: canvas.width,
      height: canvas.height,
    };
  },
};
