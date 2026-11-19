/*
 * OAgents SDK shim — minimal v1.0 stub.
 *
 * Chat modules that `require('oagents-sdk')` resolve to this file (loaded
 * via rootBundle from di.dart's `sdkSdkSourceProvider`). The full helper
 * surface from the predecessor project (browser, fetch, wallet, TOTP, …)
 * is intentionally NOT bundled in OAgents v1.0: opencode is the sole
 * agent brain and runs embedded, and modules are expected to drive it
 * through the tool interface rather than a JavaScript SDK. This stub
 * keeps `require('oagents-sdk')` resolvable so a legacy module does not
 * crash on import; every export is a safe no-op that returns null / empty
 * / a rejected promise. Replace with a real helper surface when needed.
 */
(function () {
  const noop = function () {};
  const empty = function () { return null; };
  const reject = function () { return Promise.reject(new Error('oagents-sdk stub: not implemented')); };

  module.exports = {
    version: 'oagents-sdk-1.0.0-stub',
    fetch: reject,
    browser: {
      navigate: empty,
      click: empty,
      type: empty,
      scroll: empty,
      extractText: empty,
      screenshot: empty,
    },
    storage: {
      get: empty,
      set: function () { return false; },
      remove: function () { return false; },
    },
    crypto: {
      randomBytes: function (n) {
        const b = new Array(n);
        for (let i = 0; i < n; i++) b[i] = 0;
        return b;
      },
      sha256: reject,
    },
    on: noop,
    emit: noop,
  };
})();
