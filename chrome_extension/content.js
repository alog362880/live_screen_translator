// Injected on demand by background.js. Draws translated-text chips over the
// original text and provides the drag-to-select region picker.
// Port of lib/ui/translation_overlay_stack.dart.
(() => {
  if (window.__screenTranslateLoaded) return;
  window.__screenTranslateLoaded = true;

  const HOST_ID = '__screen-translate-host';
  let host = null;
  let root = null;
  let toastTimer = null;

  function ensureHost() {
    if (host && host.isConnected) return;
    host = document.createElement('div');
    host.id = HOST_ID;
    host.style.cssText =
      'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none;';
    // Shadow DOM keeps page CSS from leaking into the chips.
    root = host.attachShadow({ mode: 'open' });
    root.innerHTML = `
      <style>
        .chip{position:fixed;box-sizing:border-box;display:flex;align-items:center;
          padding:1px 4px;background:rgba(0,0,0,.82);color:#fff;border-radius:4px;
          font:14px/1.15 system-ui,sans-serif;overflow:hidden;pointer-events:auto;
          cursor:text;user-select:text;white-space:normal}
        .toast{position:fixed;top:16px;right:16px;max-width:360px;padding:10px 14px;
          background:#1e1e2e;color:#fff;border-radius:8px;font:13px system-ui,sans-serif;
          box-shadow:0 4px 16px rgba(0,0,0,.4);pointer-events:auto}
        .toast.error{background:#8b1e1e}
        .sel{position:fixed;inset:0;cursor:crosshair;pointer-events:auto;
          background:rgba(0,0,0,.3)}
        .box{position:fixed;border:2px solid #29b6f6;background:transparent;
          box-shadow:0 0 0 9999px rgba(0,0,0,.3)}
      </style>`;
    document.documentElement.appendChild(host);
  }

  function clearChips() {
    root?.querySelectorAll('.chip').forEach((n) => n.remove());
  }

  function toast(text, kind) {
    ensureHost();
    root.querySelector('.toast')?.remove();
    clearTimeout(toastTimer);
    const t = document.createElement('div');
    t.className = 'toast' + (kind === 'error' ? ' error' : '');
    t.textContent = text;
    root.appendChild(t);
    if (kind === 'error') toastTimer = setTimeout(() => t.remove(), 6000);
  }

  function render({ blocks, scale, offset }) {
    ensureHost();
    clearChips();
    root.querySelector('.toast')?.remove();
    for (const b of blocks) {
      const [l, t, w, h] = b.bbox;
      const chip = document.createElement('div');
      chip.className = 'chip';
      chip.textContent = b.translated ?? b.text;
      chip.title = b.text; // hover shows the original
      Object.assign(chip.style, {
        left: `${offset.x + l * scale}px`,
        top: `${offset.y + t * scale}px`,
        width: `${Math.max(w * scale, 24)}px`,
        minHeight: `${h * scale}px`,
        // Shrink long translations to roughly fit the original box height.
        fontSize: `${Math.max(10, Math.min(16, h * scale * 0.8))}px`,
      });
      root.appendChild(chip);
    }
    if (!blocks.length) toast('No translatable text found.');
  }

  function dismiss() {
    clearChips();
    root?.querySelector('.toast')?.remove();
  }

  function pickRegion() {
    ensureHost();
    return new Promise((resolve) => {
      const sel = document.createElement('div');
      sel.className = 'sel';
      const box = document.createElement('div');
      box.className = 'box';
      box.style.display = 'none';
      root.append(sel, box);

      let start = null;
      const rectOf = (e) => ({
        x: Math.min(start.x, e.clientX), y: Math.min(start.y, e.clientY),
        w: Math.abs(e.clientX - start.x), h: Math.abs(e.clientY - start.y),
      });
      const finish = (result) => {
        window.removeEventListener('keydown', onKey, true);
        sel.remove();
        box.remove();
        resolve(result);
      };
      const onKey = (e) => { if (e.key === 'Escape') finish(null); };
      window.addEventListener('keydown', onKey, true);

      sel.addEventListener('mousedown', (e) => {
        start = { x: e.clientX, y: e.clientY };
        box.style.display = 'block';
      });
      sel.addEventListener('mousemove', (e) => {
        if (!start) return;
        const r = rectOf(e);
        Object.assign(box.style, {
          left: `${r.x}px`, top: `${r.y}px`, width: `${r.w}px`, height: `${r.h}px`,
        });
      });
      sel.addEventListener('mouseup', (e) => {
        if (!start) return finish(null);
        const r = rectOf(e);
        // Treat an accidental click as a cancel.
        finish(r.w < 8 || r.h < 8 ? null : r);
      });
    });
  }

  window.addEventListener('keydown', (e) => { if (e.key === 'Escape') dismiss(); });

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    switch (msg.type) {
      case 'viewport':
        sendResponse({ dpr: window.devicePixelRatio || 1 });
        break;
      case 'status':
        toast(msg.text, msg.kind);
        break;
      case 'render':
        render(msg);
        break;
      case 'pickRegion':
        pickRegion().then(sendResponse);
        return true; // async response
    }
  });
})();
