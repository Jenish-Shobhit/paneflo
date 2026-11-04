# Releasing

Releases are built, signed and published from the owner's Mac. The "Paneflo Dev" certificate lives only in that keychain, and installed copies accept only updates signed with it, so building and signing never move to CI. The website (`docs/index.html`), `docs/install.sh` and the in-app updater all read the GitHub API's `releases/latest`; a tag without a release leaves them offering the previous version. Nothing on the website needs editing per release.

## Before

- [ ] CI is green on `main` ([macOS build and tests](../.github/workflows/macos.yml)).
- [ ] Hands-on QA per [QA.md](QA.md) for the changed areas, on a release build installed in `/Applications`.
- [ ] `CHANGELOG.md` has a `## X.Y.Z — YYYY-MM-DD` section at the top (rename `## Unreleased`), and its `[X.Y.Z]` link at the bottom.
- [ ] Commit it on a clean `main`, up to date with `origin/main`.
- [ ] `scripts/release.sh --check X.Y.Z` reports every check ok. It changes nothing.

## Release

- [ ] Run `scripts/release.sh X.Y.Z`.

It needs the "Paneflo Dev" identity, the `gh` CLI signed in, and no uncommitted changes besides `CHANGELOG.md`. It bumps the bundle version, runs the tests, builds, installs and zips the signed app (`dist/Paneflo-X.Y.Z.zip`), commits, tags `vX.Y.Z`, pushes `main` and the tag, creates the GitHub release with the zip, and waits until `releases/latest` is `vX.Y.Z` with the zip uploaded at its local size. The notes are every CHANGELOG section since the last version with a GitHub release.

## After

- [ ] The [release check](../.github/workflows/release-check.yml) run for the tag is green. It fails if no published release with `Paneflo-X.Y.Z.zip` appears within 15 minutes, or if `releases/latest` is another, older tag.
- [ ] The website's download label shows X.Y.Z.
- [ ] `curl -fsSL https://jenish-shobhit.github.io/paneflo/install.sh | bash` installs X.Y.Z, or at least its checks would pass: the zip's size and SHA-256 match GitHub's, and the app is X.Y.Z signed by Paneflo Dev.
- [ ] Check for Updates in a copy of the previous version finds X.Y.Z. (The release script installs X.Y.Z on the release Mac.)

## Recovery

- **Tag pushed, no release.** Run the same `scripts/release.sh X.Y.Z` again. With `vX.Y.Z` at HEAD and no GitHub release, it skips the bump, build, commit and tag, checks that `dist/Paneflo-X.Y.Z.zip` is X.Y.Z signed by Paneflo Dev, and creates the release. A leftover draft release must be deleted first (`gh release delete vX.Y.Z --yes` keeps the tag).
- **Release without the zip, or a wrong zip.** `gh release upload vX.Y.Z dist/Paneflo-X.Y.Z.zip --clobber`.
- **Release not marked latest.** `gh release edit vX.Y.Z --latest`.
- **A bad release went out.** Mark the previous release latest (`gh release edit vPREV --latest`) so the website, installer and updater stop offering it, then publish a fix release with a new version. Never re-use, move or delete a published tag.

## Repository rules

- `main` is protected: force pushes and deletion are blocked, and pull requests need the `build-and-test` check. The owner can still push the release commit directly.
- Release tags `v*` can't be deleted or moved.
