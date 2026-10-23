---
name: release-app
description: Use when publishing a new LiteCode release — cutting a version, building the .app/.dmg, signing the Sparkle appcast, and creating the GitHub release. Triggers on "release", "ship a version", "cut a release", "tag a new version", or /release-app.
---

# release-app

Cut a new LiteCode release: build the distributable, generate its signed Sparkle feed, tag it,
and publish a GitHub Release with the `.dmg` attached. Wraps `scripts/package.sh`,
`scripts/generate-appcast.sh`, and `gh`. Installed copies pick the release up from
**LiteCode ▸ Check for Updates…**, which reads `appcast.xml` on `main`.

## Preflight (verify before doing anything)

1. `git status` — working tree must be **clean**. If not, stop and report; `--generate-notes`
   and the tag must point at a real, pushed commit.
2. `git rev-parse --abbrev-ref HEAD` — should be `main`. Warn if not.
3. `git push` any unpushed commits on the branch first.
4. `gh auth status` — must be logged in with access to `luanzt/LiteCode`.
5. `swift test` must pass.
6. Sparkle's `litecode-ed25519` EdDSA private key must be in the macOS Keychain. After
   `swift build -c release`, verify
   `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account litecode-ed25519 -p`
   prints `eqs3YlfUb49i1elAd530Q0hWtG8t4YNpfqQvSL9C9No=` (the `SUPublicEDKey` in
   `scripts/bundle.sh`). If it differs or is missing, stop: a release signed with another key
   is rejected by every installed copy. Never generate a replacement key.
7. `security find-identity -v -p codesigning` should list `mTerm Self-Signed` (or
   `$LITECODE_SIGN_IDENTITY`). A stable identity keeps macOS folder-access grants across
   updates; without it `bundle.sh` warns and signs ad-hoc. Warn, don't stop.

## Choose the version

- Latest tag: `git tag -l 'v*' --sort=-v:refname | head -1`.
- **Auto-increment PATCH** (`v0.1.3` → `v0.1.4`) and proceed without asking. With no tags yet,
  the first release is `v0.1.0`.
- If the user names a version (or asks for a minor/major bump), use that instead.
- Refuse to reuse a tag: `git tag -l v<version>` and `gh release view v<version>` must both be
  empty.

## Publish

Run in order — **build and sign the appcast first**, so a failed build or missing key never
leaves a dangling tag:

```bash
./scripts/package.sh <version>          # → build/LiteCode-<version>.dmg
./scripts/generate-appcast.sh <version> # → build/appcast.xml (signed, verified)
git tag v<version>
git push origin v<version>
gh release create v<version> build/LiteCode-<version>.dmg --title "LiteCode <version>" --generate-notes
```

After the release asset exists, publish the prepared feed:

```bash
cp build/appcast.xml appcast.xml
git add appcast.xml
git commit -m "Update appcast for v<version>"
git push origin main
```

Then verify:

- `gh release view v<version> --json assets --jq '.assets[].name'` lists `LiteCode-<version>.dmg`.
- `curl -sL https://raw.githubusercontent.com/luanzt/LiteCode/main/appcast.xml` shows
  `<sparkle:version><version></sparkle:version>` and an enclosure URL ending in
  `/v<version>/LiteCode-<version>.dmg` (raw.githubusercontent.com can lag a minute; retry).
- `curl -sIL <enclosure url>` returns 200.

Report the release URL, the version, and the signing identity used (stable or ad-hoc).

## Rules

- **No extra confirmation**: invoking this skill authorizes the tag, the release, and the
  appcast commit on `main` for that one version. Proceed once preflight passes.
- Commit messages and release text are in English, with no authorship trailers.
- The app is signed with a self-signed identity (or ad-hoc) and is **not notarized**. The
  Sparkle EdDSA signature authenticates updates; it is not Apple notarization. Don't claim
  otherwise. A first manual install needs right-click ▸ Open.
- If the build, tests, appcast generation, or signature verification fails, stop — do **not**
  create the tag or the release.
- Retry transient failures (network timeouts, GitHub 5xx) up to 2 times before giving up.
- Source-only release (user asks for no binary): skip `package.sh`/`generate-appcast.sh`, drop
  the `.dmg` from `gh release create`, and leave `appcast.xml` untouched.
- Don't install over `/Applications/LiteCode.app` as part of a release; the user updates
  through Check for Updates (or `./scripts/bundle.sh --install` if asked).

## Rollback (if published by mistake)

```bash
gh release delete v<version> --yes
git push origin :refs/tags/v<version>   # delete remote tag
git tag -d v<version>                   # delete local tag
```

If the appcast commit was already pushed, revert it (`git revert <sha>` + push) so installed
copies stop being offered the withdrawn version.
