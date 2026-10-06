const LANGS = [
  'English', 'Spanish', 'Vietnamese', 'Japanese', 'French', 'German',
  'Chinese (Simplified)', 'Korean',
];

const $ = (id) => document.getElementById(id);
const P = self.PROVIDERS;

async function init() {
  // Merged view (storage over config.local.js defaults) from the service worker.
  const s = await chrome.runtime.sendMessage({ type: 'getSettings' });
  const keys = { ...s.keys };     // working copies, saved on Translate
  const models = { ...s.models };
  let current = s.provider;

  $('provider').innerHTML = Object.entries(P)
    .map(([id, p]) => `<option value="${id}">${p.label}</option>`).join('');
  $('lang').innerHTML = LANGS.map((l) => `<option>${l}</option>`).join('');
  $('lang').value = s.targetLanguage;
  $('url').value = s.proxyUrl;
  $('token').value = s.proxyToken;
  $('ownKey').checked = s.useOwnKey;

  const showProvider = () => {
    $('provider').value = current;
    $('personalKey').value = keys[current] || '';
    $('personalKey').placeholder = P[current].keyHint;
    $('personalKeyLabel').textContent = `${P[current].label} API key`;
    $('model').value = models[current] || '';
    $('model').placeholder = P[current].defaultModel;
  };
  const applyMode = () => {
    const own = $('ownKey').checked;
    $('ownKeyFields').classList.toggle('hidden', !own);
    $('proxyFields').classList.toggle('hidden', own);
  };
  const stash = () => { // remember what's typed for the provider being left
    keys[current] = $('personalKey').value.trim();
    models[current] = $('model').value.trim();
  };

  showProvider();
  applyMode();
  $('ownKey').addEventListener('change', applyMode);
  $('provider').addEventListener('change', () => {
    stash();
    current = $('provider').value;
    showProvider();
  });

  const go = async (mode) => {
    stash();
    const useOwnKey = $('ownKey').checked;
    const proxyUrl = $('url').value.trim();
    const proxyToken = $('token').value.trim();

    // Must run inside this click handler: chrome.permissions.request needs a
    // user gesture. Grants access to just the one origin actually needed.
    try {
      const origin = useOwnKey ? P[current].origin : new URL(proxyUrl).origin + '/*';
      const has = await chrome.permissions.contains({ origins: [origin] });
      if (!has && !(await chrome.permissions.request({ origins: [origin] }))) return;
    } catch {
      (useOwnKey ? $('personalKey') : $('url')).focus();
      return;
    }
    await chrome.storage.local.set({
      provider: current, proxyUrl, proxyToken, useOwnKey, keys, models,
      targetLanguage: $('lang').value,
    });
    await chrome.runtime.sendMessage({ type: 'translate', mode });
    window.close(); // popup would otherwise cover the page being captured
  };
  $('full').addEventListener('click', () => go('full'));
  $('region').addEventListener('click', () => go('region'));
}

init();
