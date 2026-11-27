# Licensing

CineNotch's paid version is a **$14.99 one-time license**: up to 3 Macs, every 1.x update, no
subscription. A new Mac gets a **7-day free trial** with everything unlocked, then the soft lock below. The key arrives by email from [Creem](https://creem.io), the merchant of
record. The source stays public under the GPLv3, so the gate is deliberately light: it keeps honest
people honest, nothing more. There is no obfuscation and no anti-tamper, and anyone can build the app
from source.

**All of this ships switched off.** With `LicensingEnabled` false in `Resources/Info.plist` (as it is
today) the app is fully free and unrestricted: nothing is locked, nothing is read from the Keychain,
nothing is sent anywhere, no License tab or lock pill exists. The Worker's endpoints answer
`503 licensing_not_enabled` until its own switch is on. Neither side needs the other to be ready.

## How it works

```
 CineNotch.app ──(key, hashed device id)──▶ cinenotch.cam /api/license/*  ──(x-api-key)──▶ Creem /v1/licenses/*
      ▲                                       Worker, src/license.js (site repo)
      └────── token signed with Ed25519 ◀──────┘
```

- The app can't hold Creem's secret API key, so it talks to a small proxy in the site's Worker. The
  proxy calls Creem and answers with a **signed token**: `cn1.<payload>.<signature>`, where the payload is
  `{v, kh, dh, iid, pid, iat, exp}` (key hash, device id hash, Creem instance id, product id, issued at,
  expires), signed with Ed25519 over `"CINENOTCH-LICENSE-V1\n" + payload`.
- The private key is a Worker secret (`LICENSE_SIGNING_KEY`). The public key is in the app's Info.plist
  (`LicensePublicKey`). The app checks the token **offline**: valid signature, this Mac's device hash,
  this key's hash. No server is needed to start the app.
- Device id: SHA-256 of `"cinenotch.device.v1:" + IOPlatformUUID`. Nothing that identifies the person.
  It names the activation in Creem as `<hardware model> <first 12 hex of the hash>` (for example `MacBookAir10,1 3fa9c01b22de`).
- Storage: the key, the token and the dates are one generic-password item in the macOS Keychain
  (service `com.cinenotch.CineNotch.license`), so deleting the app doesn't lose the activation.
- Re-validation: about every 14 days the app asks the server again (checked hourly whether it's due).
  If that fails for any reason except "this license is not valid" (offline, server down, Creem down,
  licensing switched off server-side, a captive portal), nothing happens and it tries again 6 hours
  later. After 45 days without a successful check, Settings → License shows a reminder to go online.
  **The app is never disabled because the network is down.** Only a clear answer from the server
  (`not_found` or `revoked`, as JSON from the proxy) locks it: that is what a refund looks like. Even then it
  has to be said twice, at least 6 hours apart, and the key stays in the Keychain: a locked Mac asks again
  at launch and about once a day (and on *Check Again*), and unlocks itself if the answer changes. So a
  server mistake (say, a wrong `CREEM_PRODUCT_ID`) can't wipe out paid Macs; they recover once it's fixed.
  The proxy also never answers `not_found` for its own problems: a validated key of a product it doesn't
  list is a 502, and an unknown endpoint is `unknown_endpoint`.
- A Keychain that can't be read (locked right after login, say) is not "no license": nothing is decided,
  written or sent until it can be read, and the app retries for a few minutes, then hourly.
- **Early supporters: free for good.** At the first launch of a build with licensing on, the app looks for
  what earlier versions leave in its defaults (`onboardingDone`, `onboardingResume` from 0.1.0 on, Sparkle's
  `SUHasLaunchedBefore` from 0.2.0 on), read at the very start of `main`, before this launch writes any of it.
  The answer is stored once in the Keychain (`activation.early-access`) and never changes: an early supporter
  is unlocked for good, never asked for a key and never checked online (the License tab says "Free for good");
  a new Mac stays new even after its own onboarding writes those defaults. Someone could download an old
  version first to get in free: like building from source, that's accepted.
- **7-day trial.** A Mac that was never activated and isn't an early supporter gets every feature for 7 days from
  its first launch of a build with licensing on. It needs no network and no account. Details:
  - The start date and the last time the app ran (`TrialRecord`) are stored twice: a Keychain item
    (`activation.trial`, same service and `AfterFirstUnlockThisDeviceOnly` as the license) and the defaults
    (`CNTrialStart`, `CNTrialLastSeen`). Deleting one doesn't reset the trial: the other restores it and is written
    back. If the two disagree, the earlier start and the later last-seen win, and both are rewritten.
  - Days left count from `max(now, last-seen)`, so setting the clock back doesn't add days (the count just waits
    until the clock catches up), and a clock set to before the start doesn't start a new 7 days. Last-seen never
    moves back. "7 days left" on the first day, one less per full 24 hours, "1 day left" on the last day, ended at
    exactly 7 × 24 hours.
  - A Keychain that can't be read is not "no trial": nothing new is recorded until it can be.
  - It's decided once per launch, on the first real license state (after the Keychain is read). Licensed and
    early-supporter Macs never start a trial, never see it and never write its record. A revoked or damaged license
    stays locked even with trial days left: the trial only covers "never activated". Activating during the trial
    hides it (the dates stay, unused). The license itself (`LicenseState.isUnlocked`) is unchanged; the app's
    `FeatureGate` unlocks features for the license *or* an active trial (`TrialAccess`).
  - While it runs, the menu shows "Free trial: N days left" and Settings → License shows the days left, the key
    field and *Buy license*. After it: the soft lock below, with *Buy license* (`https://cinenotch.cam/?ref=trial`)
    and *Enter key* (opens the License tab) for a Mac that was never activated.
  - Like the rest, it keeps honest people honest. Deleting both copies, or a rebuild from source, gets around it;
    the Keychain plus the defaults is reasonably tamper-resistant, not DRM.
- Unlicensed (licensing on, no activation, no trial left): the PiP window is not docked and stays an ordinary
  floating window (so the user's video is never taken away), the camera glance doesn't run (it only
  runs while a video is docked), a small "Activate CineNotch to dock this video" pill with *Enter Key*
  and *Buy* appears while a PiP video exists ("×" hides it until the next video), and the menu bar
  menu shows the same with *Buy license* and *Enter key* after the trial (*Enter License Key…* and *Buy CineNotch…*
  for a revoked or damaged license). Settings and Quit always work.
- Sparkle updates, `/appcast.xml` and `/download` stay public. A license is not needed to update; the
  app checks the license itself.

Code: `Sources/CineNotchLicense/` (no UI; unit-tested: token, device id, Keychain store, server client,
state machine, trial in `Trial.swift`) and, in the app target, `Support/Licensing.swift` (setup from Info.plist,
`FeatureGate`), `Windows/LockPill.swift`,
the License tab in `Windows/Settings.swift`, the locked menu in `StatusMenu.swift` and `PiPController.setLocked`.
The gaze engine isn't touched.

## Creem facts this relies on

From https://docs.creem.io/features/addons/licenses (checked 2026-10-26):

- Product: add a **License key** delivery item to the product (there's no other switch); set *Limit
  activations* (3) and optionally an expiration (leave empty: updates are tied to 1.x by the app, not
  by Creem).
- Base URLs: live `https://api.creem.io`, test `https://test-api.creem.io`. Header `x-api-key`.
  Keys from Creem dashboard → Settings → API Keys (test and live keys are different).
- `POST /v1/licenses/activate {key, instance_name}`, `/validate {key, instance_id}`,
  `/deactivate {key, instance_id}`. Documented status codes: 400 bad parameters, 401 bad API key, 403
  activation limit reached (activate), 404 unknown key or instance, 409 instance already deactivated,
  410 revoked or expired (validate). See below for what test mode really answers. License `status` is `active`, `inactive`, `expired` or `disabled`.
- The key goes to the customer in the order confirmation page (when the checkout has no success URL),
  the receipt email and the customer portal. Don't set a success URL on the checkout link, or the
  key won't show on the confirmation page.
- Customer portal for "Manage": https://www.creem.io/my-orders/login (email magic link).

What Creem's test mode actually answered (2026-10-28, where it differs from the docs above), and
what the proxy does about it (`src/license.js`, mirrored in `scripts/mock-creem.mjs`):

- The activation limit is **400** `"Activation limit reached"`, not 403: the proxy turns it into
  `limit_reached`.
- Deactivating an instance that's already deactivated is **400** `"... already deactivated"`, not 409:
  the proxy answers ok.
- Every activate makes a **new instance**, even with the same name, so re-activating a Mac takes another
  slot. The proxy avoids that two ways: the app sends the instance it holds for the same key, and the
  proxy reuses it when it's still active for this Mac; after a fresh activation it lists the license's
  instances (`GET /v1/licenses/{id}/instances`) and deactivates this Mac's older ones. A Mac that lost
  its Keychain item when all 3 slots are taken still gets `limit_reached` (free one in the Creem
  dashboard).
- Validating a deactivated instance is 200 with `instance.status` `"deactivated"`; `instance` is an
  object; an unknown key or instance is 404 with `message` as a list of strings.
- The first test purchase still went to `https://cinenotch.cam/thanks` after the success URL was
  removed from the product (the checkout itself said `success_url: null`). Check for a store-wide
  redirect in Creem's settings; `/thanks` points to the email in any case.

- **A refund doesn't touch the license.** After a full refund in test mode (transaction `refunded`) the
  key stayed `active`: it still validated and even activated a new Mac. The API has no call to disable a
  key, so after each refund disable it by hand in the Creem dashboard (the refund page promises the key
  ends). A `disabled` key validates as `status: "disabled"` and its activation is a 400 "License key is disabled"; the proxy answers both with 410 (`revoked`) and the app
  locks on the second answer like that (6 hours apart, at the next 14-day check at the latest).

## Privacy

When licensing is on, activating sends the **license key and the hashed device id** (plus the
hardware model, as the activation name) to cinenotch.cam, which checks them with Creem; about every
two weeks the app repeats the check with the key, instance id and device hash. Never video, camera
or screen content. The Worker logs no key or device id and counts only action, outcome and country.
The site's privacy page and the permission strings must say this **before licensing is switched on**
(it currently says the only thing the app asks the internet is whether there's an update). Suggested
sentence for the privacy page:

> If you buy a license, CineNotch sends your license key and a hashed ID of your Mac (not your name,
> not the Mac's serial number) to cinenotch.cam when you activate it and about every two weeks after,
> where it is checked with our payment provider, Creem. Nothing else leaves your Mac.

## Go live

Do these in order. Nothing before step 7 changes what users get.

1. **Creem**: create the product ($14.99 one-time, *License key* delivery item, activation limit 3,
   no success URL). Note its product id (`prod_…`). Start in test mode; repeat for live.
2. **Keys**: `node scripts/gen-license-keys.mjs` in the site repo. It prints a private and a public
   key once. Keep the private key in your password manager only.
3. **Worker secrets and variables** (site repo):
   ```bash
   npx wrangler secret put CREEM_API_KEY        # Creem dashboard → Settings → API Keys
   npx wrangler secret put LICENSE_SIGNING_KEY  # the private key from step 2
   ```
   In `wrangler.jsonc` set `CREEM_PRODUCT_ID` to the product id (and `CREEM_API_BASE` to
   `https://test-api.creem.io` while testing). Leave `LICENSING_ENABLED` `"false"` for now.
4. **Test mode end to end**: set `LICENSING_ENABLED` `"true"` and deploy (or run `wrangler dev` with a
   `.dev.vars` holding the test values). Buy the test product with Creem's test card, then run the app with
   `--debug-license-enabled --debug-license-server https://cinenotch.cam --debug-license-public-key <public key>`
   (it uses its own Keychain item). Check: activate, a 4th Mac is refused, deactivate frees a slot,
   a refunded/disabled license locks after the next check. Fix the proxy where Creem differs from the
   guesses above. `GET https://cinenotch.cam/api/license/status` shows `enabled`/`configured`/the public key.
5. **Live**: switch `CREEM_API_BASE` back to `https://api.creem.io`, put the live API key and product
   id in (the product id variable accepts `prod_test,prod_live` while you're moving over), deploy.
6. **App**: in `Resources/Info.plist` set `LicensePublicKey` to the public key and `LicensingEnabled` to
   `true`; check `LicenseBuyURL` (`https://cinenotch.cam/buy`), `LicenseManageURL` and
   `LicenseSupportEmail`. The paid version is **1.0.0** (the license covers 1.x): bump
   `CFBundleShortVersionString` / `CFBundleVersion`.
   `scripts/release.sh` refuses to build with licensing on and an empty public key.
7. **Privacy page**: the license paragraphs are already in `public/privacy.html` as FLIP blocks, so step 9
   switches them on. Bump its "Updated" date then.
8. **Release** the new version (`scripts/release.sh`, GitHub release, appcast). Existing installs update
   to it and stay free (early supporters): say so in the release notes.
9. **Flip the site** to paid: `python3 scripts/flip-to-paid.py` in the site repo (see its README section
   "Flipping to paid"), set the real Creem checkout URL, publish `/buy`, then the app README.
10. Keep an eye on the `license` counters (`README.md` in the site repo, *Stats*).

To go back: set `LicensingEnabled` false in a new release (existing installs just stop checking), or set the
Worker's `LICENSING_ENABLED` to `"false"` (the app then keeps working: "not enabled" is never a verdict).

## Trying it locally

Unit tests: `swift test` (token vectors made by the real Worker code, state machine, config, Keychain-free).

Against a local Worker and a mock Creem (no real account needed), from the site repo:

```bash
node scripts/gen-license-keys.mjs --dev   # writes .dev.vars, prints the public key
node scripts/mock-creem.mjs               # keys: CN-TEST-ACTIVE-0001/0002, CN-TEST-REVOKED-0001, CN-TEST-EXPIRED-0001
npx wrangler dev --port 4321
```

and from this repo:

```bash
CINENOTCH_LICENSE_TEST_SERVER=http://127.0.0.1:4321 CINENOTCH_LICENSE_TEST_PUBLIC_KEY=<public key> swift test
./scripts/run.sh --debug-fake-pip --debug-license-enabled --debug-license-server http://127.0.0.1:4321 \
    --debug-license-public-key <public key>
```

Developer switches (`Support/LaunchOptions.swift`):

| Argument | Does |
| --- | --- |
| `--debug-license-enabled` | licensing on without the Info.plist flag; uses its own Keychain item (`debug-activation`) |
| `--debug-license-server <url>` | where activation goes |
| `--debug-license-public-key <base64>` | the key that checks tokens |
| `--debug-license-state off\|unlicensed\|revoked\|licensed\|stale\|early` | pins the state: see the locked island, menu and License tab. No server, no Keychain |
| `--debug-license-prior-install` | debug runs count as a new install; this makes one an early supporter (if nothing is decided yet) |
| `--debug-license-reset` | forgets the debug activation, the debug early-supporter decision and the debug trial first (not the slot on the server) |
| `--debug-trial-reset` | forgets the debug trial (`debug-activation.trial`, `CNDebugTrialStart` / `CNDebugTrialLastSeen`) first. Never the real one |
| `--debug-trial-days-left <n>` | pins the trial for this run: n > 0 days left, 0 for ended. Writes nothing. A licensed or early state still wins |
| `--debug-license-activate <key>` / `--debug-license-deactivate` | does it at launch, as the License tab would (debug Keychain only); the result is in the log |

Debug runs (`--debug-license-enabled`, `-server`, `-public-key`) keep their trial in `debug-activation.trial` and
`CNDebugTrial*`, never the real record. With `--debug-license-state` the trial is in memory only (a fresh 7 days each
run), like the license.

`--debug-license-state unlicensed --debug-fake-pip` starts a trial (everything unlocked); add
`--debug-trial-days-left 0` for the lock pill and the locked menu. Add
`--debug-windows <dir>` for pictures of the Settings tabs and the lock pill (without Screen Recording permission the
windows are drawn from their views, without the title bar).
A debug-activated Mac holds a slot in the mock/test Creem: deactivate in the License tab afterwards.

## Decisions to review

- **Light by design.** A GPLv3 app can be rebuilt without the check, and the proxy only verifies keys.
  We accept that; don't add anti-tamper. The signed token only stops casual editing of the Keychain item.
- **Fail open.** Licensing on but no/invalid public key (a build mistake) leaves the app unrestricted
  and logs why. A server that says "not enabled", or can't be reached, is never a verdict.
- **Slots.** Creem counts activations per instance name, which the app sets from the device hash, so
  reinstalling on the same Mac reuses its slot. A Mac that's wiped or sold should be deactivated first;
  otherwise the slot is freed by hand in Creem's dashboard (or by writing to support).
- **Refunds.** Creem disables the license on refund: the next check (≤ 14 days, plus hours) locks that Mac.
- **Existing free users** keep it free for good, automatically (see *Early supporters* above). Decided 2026-10-27.
- **Trial.** 7 days, from the first launch with licensing on, offline. Rolling the clock back pauses the count at
  the last day seen rather than locking (no honest user is locked by a wrong clock). Decided 2026-11-27.
- **Locked means not docked, not broken.** The user's video keeps playing in its normal PiP window.
- **Token lifetime.** 730 days (or the license's own expiry if sooner). Past it the app only reminds.
