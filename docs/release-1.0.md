# CineNotch 1.0.0: release notes (draft)

Ships when Creem approves the store. Steps: "Go live" in [LICENSING.md](LICENSING.md). This branch
(`release-1.0`) already has the version (1.0.0, build 8), `LicensingEnabled` true and the paid README;
`LicensePublicKey` goes in on release day, from the live signing key.

## Update window (Sparkle)

Copy into `build/notes-1.0.0.txt` and run `RELEASE_NOTES=build/notes-1.0.0.txt scripts/release.sh`.

```
- CineNotch 1.0 is here. From now on it's a $14.99 one-time purchase for new users.
- You used CineNotch before 1.0, so it stays free for you, this update and the ones after it. There's no key to enter and nothing to do. Thank you for being early!
- New: Settings → License, where people who buy CineNotch enter their key.
```

## GitHub release

Title: `CineNotch 1.0.0`

```markdown
CineNotch 1.0: the first paid version.

- **Already using CineNotch? It stays free for you.** Every copy that ran a version before 1.0
  updates to 1.0 and keeps working, updates included, with no key and nothing sent anywhere.
- **New here?** CineNotch is a $14.99 one-time purchase, with no subscription: buy a license at
  [cinenotch.cam](https://cinenotch.cam/#pricing) and paste the key in **Settings → License**. One
  license covers up to 3 of your Macs and every 1.x update, with a 30-day money-back guarantee.
- The code stays open under the GPLv3: you can always build it yourself for free.

Already on 0.2.0 or later? CineNotch offers this update itself, or use **Check for Updates…** in the menu.

**Needs:** macOS 14 or later, Apple silicon or Intel. Signed with Developer ID and notarized by Apple.

SHA-256 of `CineNotch.dmg`: `<from scripts/release.sh>`
```

## Before tagging

- `swift test` passes; a build with the live public key activates a real (live) key, relaunches
  licensed, and an existing 0.7.0 install that updates through Sparkle shows "You're an early
  supporter" in Settings → License.
- The site is flipped (`scripts/flip-to-paid.py <checkout URL>` in the site repo) the same day, and
  the privacy page's "Updated" date is bumped.
