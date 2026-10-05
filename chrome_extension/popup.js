const LANGS = [
  'English', 'Spanish', 'Vietnamese', 'Japanese', 'French', 'German',
  'Chinese (Simplified)', 'Korean',
];

const $ = (id) => document.getElementById(id);

function applyMode(useOwnKey) {
  $('ownKeyFields').classList.toggle('hidden', !useOwnKey);
  $('proxyFields').classList.toggle('hidden', useOwnKey);
}

async function init() {
  // Merged view (storage over config.local.js defaults) from the service worker.
  const {
    proxyUrl = '', proxyToken = '', useOwnKey = false, personalApiKey = '',
    targetLanguage = 'English',
  } = await chrome.runtime.sendMessage({ type: 'getSettings' });

  $('lang').innerHTML = LANGS.map((l) => `<option>${l}</option>`).join('');
  $('lang').value = targetLanguage;
  $('url').value = proxyUrl;
  $('token').value = proxyToken;
  $('ownKey').checked = useOwnKey;
  $('personalKey').value = personalApiKey;
  applyMode(useOwnKey);

  $('ownKey').addEventListener('change', () => applyMode($('ownKey').checked));

  const go = async (mode) => {
    const useOwnKey = $('ownKey').checked;
    const proxyUrl = $('url').value.trim();
    const proxyToken = $('token').value.trim();
    const personalApiKey = $('personalKey').value.trim();

    // Must run inside this click handler: chrome.permissions.request needs a
    // user gesture. Grants access to just the one origin actually needed,
    // nothing broader.
    try {
      const origin = useOwnKey ? 'https://api.anthropic.com/*' : new URL(proxyUrl).origin + '/*';
      const has = await chrome.permissions.contains({ origins: [origin] });
      if (!has && !(await chrome.permissions.request({ origins: [origin] }))) return;
    } catch {
      (useOwnKey ? $('personalKey') : $('url')).focus();
      return;
    }
    await chrome.storage.local.set({
      proxyUrl, proxyToken, useOwnKey, personalApiKey, targetLanguage: $('lang').value,
    });
    await chrome.runtime.sendMessage({ type: 'translate', mode });
    window.close(); // popup would otherwise cover the page being captured
  };
  $('full').addEventListener('click', () => go('full'));
  $('region').addEventListener('click', () => go('region'));
}

init();
