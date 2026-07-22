/** Tunnel lifecycle used by the coordinator process, with the native SDK kept optional. */
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

export class NgrokUnavailableError extends Error {
  constructor(message) { super(message); this.name = 'NgrokUnavailableError'; }
}

export function loadCoordinatorNgrokSdk() {
  return loadNgrokSdkFromRuntime(path.join(root, 'coordinator'));
}

export function loadNgrokSdkFromRuntime(runtimePath) {
  try {
    // The host-only dependency resolves from private coordinator state, so a
    // member's installed Federation package never loads or carries it.
    const requireCoordinator = createRequire(path.join(runtimePath, 'package.json'));
    return requireCoordinator('@ngrok/ngrok');
  } catch (error) {
    // Native prebuild failures do not use one stable Node error code across
    // N-API/OS/libc combinations. This boundary is optional, so every load
    // failure receives the same guided fallback rather than a raw require
    // stack (the coordinator still reports network/session failures normally).
    throw new NgrokUnavailableError(error && error.message ? error.message : String(error));
  }
}

export async function startNgrokTunnel({ port, authtoken, domain, loadSdk = loadCoordinatorNgrokSdk }) {
  let ngrok;
  try { ngrok = loadSdk(); } catch (error) {
    if (error instanceof NgrokUnavailableError) throw error;
    throw new NgrokUnavailableError(`could not load @ngrok/ngrok: ${error.message}`);
  }
  // Invites embed the coordinator URL, so it must survive restarts. A free
  // endpoint dialed without `domain` gets a session-random URL; pinning the
  // previously assigned hostname keeps outstanding invites valid. If the
  // pinned domain is rejected (revoked/changed account), retry unpinned so
  // the collective comes back reachable instead of staying down; the caller
  // must surface the changed URL to the operator.
  try {
    const listener = await ngrok.forward({ addr: `127.0.0.1:${port}`, authtoken, proto: 'http', ...(domain ? { domain } : {}) });
    return { url: listener.url(), close: () => listener.close() };
  } catch (error) {
    if (domain) {
      const listener = await ngrok.forward({ addr: `127.0.0.1:${port}`, authtoken, proto: 'http' })
        .catch((retryError) => { throw new Error(`ngrok could not create a tunnel: ${retryError.message}`); });
      return { url: listener.url(), close: () => listener.close(), domainFellBack: true, domainError: error.message };
    }
    throw new Error(`ngrok could not create a tunnel: ${error.message}`);
  }
}

export function ngrokUnavailableGuidance() {
  return 'ngrok’s built-in connector is unavailable on this platform. Install the ngrok agent from https://ngrok.com/download, then run it against the local coordinator port, or restart with --tunnel url:<https://your-address>.';
}
