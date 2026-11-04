#!/bin/bash
# Publishes a Paneflo release from a clean main. The checklist around it is docs/releasing.md.
#
#   scripts/release.sh <version>           e.g. scripts/release.sh 1.2.5
#   scripts/release.sh --check <version>   run only the checks and report; changes nothing
#
# Expects a `## <version> — <date>` section in CHANGELOG.md (written by hand). Before changing anything it checks
# that gh is signed in and sees the repo, main is clean and not behind origin/main, the version has no GitHub
# release yet, and the "Paneflo Dev" identity is in the keychain. Then it bumps CFBundleShortVersionString and
# CFBundleVersion, builds, installs and zips the signed release app, commits, tags v<version>, pushes main and the
# tag, creates the GitHub release with the zip, and waits until GitHub serves it as the latest release.
#
# Resume: if tag v<version> already exists at HEAD with no GitHub release (the tag went out, the release didn't),
# the same command skips the bump, build, commit and tag. It checks that dist/Paneflo-<version>.zip holds that
# version signed by Paneflo Dev, pushes main and the tag if needed, and creates the release.
#
# The notes are every CHANGELOG section since the last version with a GitHub release, so versions never
# published get listed too.
set -euo pipefail

PLIST=Resources/Info.plist
IDENTITY="Paneflo Dev"
BUNDLE_ID="dev.paneflo.Paneflo"

usage() { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}/usage: /' >&2; exit 2; }
say() { printf '==> %s\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
# A failed check stops a release; --check reports it and goes on.
fail() {
  if (( CHECK )); then printf '  FAIL  %s\n' "$*"; FAILED=1; else die "$*"; fi
}

# The notes for VERSION from a CHANGELOG on stdin: its section down to the LAST version's (empty: to the end).
release_notes() {
  local version=$1 last=$2 notes
  notes=$(awk -v v="$version" -v last="$last" '
    $0 ~ "^## "v" " {on=1}
    on && last != "" && $0 ~ "^## "last" " {exit}
    on')
  # With only this version unreleased, its own heading is left out.
  if [[ "$(grep -c '^## ' <<<"$notes")" == 1 ]]; then notes=$(sed '1d' <<<"$notes"); fi
  sed '/./,$!d' <<<"$notes"
}

# The newest v* tag behind HEAD, other than v<version>, with a published release. $RELEASED lists those tags.
last_released_tag() {
  local version=$1 tag
  while read -r tag; do
    [[ "$tag" == "v$version" ]] && continue
    if grep -Fxq -- "$tag" <<<"$RELEASED"; then echo "$tag"; return 0; fi
    echo "  note  $tag has no GitHub release; its CHANGELOG section goes into these notes" >&2
  done < <(git tag --merged HEAD --list 'v*' --sort=-v:refname)
  return 0
}

# Succeeds if ZIP holds Paneflo.app at VERSION, intact and signed by Paneflo Dev; otherwise prints why.
verify_zip() (
  version=$1 zip=$2
  [[ -f "$zip" ]] || { echo "$zip is missing"; exit 1; }
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' EXIT
  ditto -x -k "$zip" "$dir" 2>/dev/null || { echo "$zip can't be unzipped"; exit 1; }
  app="$dir/Paneflo.app"
  [[ -d "$app" ]] || { echo "$zip has no Paneflo.app"; exit 1; }
  info="$app/Contents/Info.plist"
  [[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$info" 2>/dev/null)" == "$BUNDLE_ID" ]] \
    || { echo "the app in $zip isn't $BUNDLE_ID"; exit 1; }
  got=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info" 2>/dev/null || true)
  [[ "$got" == "$version" ]] || { echo "the app in $zip is version ${got:-unknown}, not $version"; exit 1; }
  codesign --verify --deep --strict "$app" 2>/dev/null \
    || { echo "the app in $zip fails codesign --verify --deep --strict"; exit 1; }
  # Read in full first: grep -q in a pipe could cut codesign off, and pipefail would report that as a failure.
  details=$(codesign -dvv "$app" 2>&1 || true)
  grep -Fxq "Authority=$IDENTITY" <<<"$details" || { echo "the app in $zip isn't signed by \"$IDENTITY\""; exit 1; }
)

# Every check that needs no change. Sets REPO, RESUME, NEWEST, LAST and NOTES.
preflight() {
  REPO="" RESUME=0 NEWEST=1 LAST="" NOTES="" RELEASES="" RELEASED=""
  local head remote remote_main remote_tag local_tag state newest changelog
  head=$(git rev-parse HEAD)

  if ! command -v gh >/dev/null; then fail "the gh CLI is needed to create the release"
  elif ! gh auth status >/dev/null 2>&1; then fail "gh isn't signed in: run gh auth login"
  elif ! REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null); then
    REPO=""; fail "gh can't see this repository (gh repo view failed)"
  else ok "gh is signed in and sees $REPO"
  fi

  if [[ "$(git branch --show-current)" == main ]]; then ok "on main"; else fail "not on main"; fi
  if git diff --quiet -- . ':!CHANGELOG.md' && git diff --cached --quiet; then ok "no uncommitted changes besides CHANGELOG.md"
  else fail "uncommitted changes besides CHANGELOG.md"
  fi

  # ls-remote rather than fetch: it reads origin's state without changing any local ref.
  if remote=$(git ls-remote origin refs/heads/main "refs/tags/v$VERSION" 2>/dev/null); then
    remote_main=$(awk '$2 == "refs/heads/main" {print $1}' <<<"$remote")
    remote_tag=$(awk -v t="refs/tags/v$VERSION" '$2 == t {print $1}' <<<"$remote")
    if [[ -z "$remote_main" ]]; then fail "origin has no main branch"
    elif [[ "$remote_main" == "$head" ]]; then ok "main is up to date with origin/main"
    elif git merge-base --is-ancestor "$remote_main" HEAD 2>/dev/null; then ok "main is ahead of origin/main"
    else fail "main is behind or has diverged from origin/main (${remote_main:0:7}): pull first"
    fi
  else
    remote_tag=""; fail "can't reach origin (git ls-remote failed)"
  fi

  if [[ -n "$REPO" ]]; then
    if RELEASES=$(gh api --paginate "repos/$REPO/releases" \
        --jq '.[] | [.tag_name, (if .draft then "draft" else "published" end)] | @tsv' 2>/dev/null); then
      RELEASED=$(awk -F'\t' '$2 == "published" {print $1}' <<<"$RELEASES")
      state=$(awk -F'\t' -v t="v$VERSION" '$1 == t {print $2; exit}' <<<"$RELEASES")
      case "$state" in
        published) fail "v$VERSION already has a GitHub release" ;;
        draft) fail "a draft GitHub release for v$VERSION exists: delete it (gh release delete v$VERSION --yes keeps the tag), then run this again" ;;
        *) ok "no GitHub release for v$VERSION yet" ;;
      esac
      newest=$(sed 's/^v//' <<<"$RELEASED" | sort -V | tail -n 1)
      if [[ -n "$newest" && "$(printf '%s\n%s\n' "$newest" "$VERSION" | sort -V | tail -n 1)" != "$VERSION" ]]; then
        NEWEST=0
        echo "  note  $VERSION is older than the latest release ($newest), so it won't be marked latest"
      fi
    else
      fail "can't list the GitHub releases of $REPO"
    fi
  fi

  local_tag=$(git rev-parse -q --verify "refs/tags/v$VERSION" || true)
  if [[ -n "$local_tag" ]]; then
    if [[ "$(git rev-parse "v$VERSION^{commit}")" != "$head" ]]; then fail "tag v$VERSION exists and isn't at HEAD"
    elif [[ -n "$remote_tag" && "$remote_tag" != "$local_tag" ]]; then fail "tag v$VERSION exists and differs from origin's"
    elif [[ -z "$REPO" || -n "${state:-}" ]]; then fail "tag v$VERSION exists"
    else RESUME=1; ok "tag v$VERSION is at HEAD with no release: resuming"
    fi
  elif [[ -n "$remote_tag" ]]; then
    fail "tag v$VERSION exists on origin but not here: run git fetch --tags, then this again"
  fi

  # Resuming, the notes come from the tagged CHANGELOG, as committed.
  if (( RESUME )); then changelog=$(git show "v$VERSION:CHANGELOG.md"); else changelog=$(cat CHANGELOG.md); fi
  if grep -q "^## $VERSION " <<<"$changelog"; then
    LAST=$(last_released_tag "$VERSION")
    NOTES=$(release_notes "$VERSION" "${LAST#v}" <<<"$changelog")
    if [[ -n "${NOTES//[[:space:]]/}" ]]; then ok "CHANGELOG notes since ${LAST:-the start}"
    else fail "the $VERSION section in CHANGELOG.md is empty"
    fi
  else
    fail "no '## $VERSION — <date>' section in CHANGELOG.md"
  fi

  if (( RESUME )); then
    local why
    if why=$(verify_zip "$VERSION" "dist/Paneflo-$VERSION.zip"); then ok "dist/Paneflo-$VERSION.zip is $VERSION, signed by $IDENTITY"
    else fail "$why"
    fi
  # Without it build.sh signs ad hoc, and every installed copy would refuse the release as an update (its signing certificate must match).
  elif security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then ok "\"$IDENTITY\" signing identity is in the keychain"
  else fail "no \"$IDENTITY\" signing identity in the keychain"
  fi
}

# Creates the GitHub release for v$VERSION from $ZIP and $NOTES. The tag must already be on origin.
create_release() {
  local notes_file latest=true
  (( NEWEST )) || latest=false
  notes_file=$(mktemp)
  {
    printf '%s\n\n' "$NOTES"
    printf '### Install\n\nDownload `Paneflo-%s.zip`, unzip, and move **Paneflo.app** to `/Applications`. Not notarized yet: on first open, go to **System Settings › Privacy & Security › Open Anyway**. Requires macOS 26+ on Apple silicon. Paneflo asks for Accessibility, Input Monitoring and Screen Recording.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' "$VERSION"
  } > "$notes_file"
  if ! gh release create "v$VERSION" "$ZIP" --verify-tag --latest="$latest" --title "Paneflo $VERSION" --notes-file "$notes_file"; then
    rm -f "$notes_file"
    die "gh release create failed; the tag v$VERSION is pushed but may have no release. Retry with: scripts/release.sh $VERSION"
  fi
  rm -f "$notes_file"
}

# Waits up to about 60 s for GitHub to serve the release (as latest, unless it's older) with the zip uploaded.
verify_published() {
  local name endpoint size digest jq got="" tag asset_state asset_size asset_digest _
  name=$(basename "$ZIP")
  size=$(stat -f %z "$ZIP")
  digest="sha256:$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
  endpoint="repos/$REPO/releases/latest"
  (( NEWEST )) || endpoint="repos/$REPO/releases/tags/v$VERSION"
  jq='[.tag_name, ((first(.assets[] | select(.name == "'"$name"'")) | [.state, .size, (.digest // "-")]) // ["missing", "-", "-"])[]] | map(tostring) | join(" ")'
  for _ in $(seq 1 12); do
    # On an error gh prints GitHub's message to stdout, so a failed call counts as no answer.
    got=$(gh api "$endpoint" --jq "$jq" 2>/dev/null) || got=""
    read -r tag asset_state asset_size asset_digest <<<"$got" || true
    if [[ "$tag" == "v$VERSION" && "$asset_state" == uploaded && "$asset_size" == "$size" ]] \
        && [[ "$asset_digest" == - || "$asset_digest" == "$digest" ]]; then
      say "GitHub serves v$VERSION$( (( NEWEST )) && echo ' as latest') with $name uploaded ($size bytes)"
      return 0
    fi
    sleep 5
  done
  {
    echo "error: GitHub isn't serving the $VERSION release correctly after 60 s ($endpoint)."
    echo "  The website, install.sh and the in-app updater read releases/latest, so they may still offer the old version."
    if [[ -z "$got" ]]; then echo "  GitHub returned no release. Check https://github.com/$REPO/releases"
    elif [[ "$tag" != "v$VERSION" ]]; then echo "  Latest is $tag. If v$VERSION is published, mark it: gh release edit v$VERSION --latest"
    elif [[ "$asset_state" == missing ]]; then echo "  The release has no $name. Upload it: gh release upload v$VERSION $ZIP"
    else echo "  $name is '$asset_state', $asset_size bytes ($asset_digest); the local zip is $size bytes ($digest). Replace it: gh release upload v$VERSION $ZIP --clobber"
    fi
    echo "  If v$VERSION has no release at all (or only a draft, deleted with gh release delete v$VERSION --yes), resume with: scripts/release.sh $VERSION"
  } >&2
  exit 1
}

main() {
  cd "$(dirname "$0")/.." >/dev/null
  CHECK=0 FAILED=0
  if [[ "${1:-}" == --check ]]; then CHECK=1; shift; fi
  [[ $# == 1 ]] || usage
  VERSION=$1
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the version must look like 1.2.3, not '$VERSION'"
  ZIP="dist/Paneflo-$VERSION.zip"

  say "Checking release $VERSION"
  preflight
  if (( CHECK )); then
    (( FAILED )) && die "not ready to release $VERSION"
    if (( RESUME )); then say "Ready: scripts/release.sh $VERSION would create the release for the existing tag v$VERSION"
    else say "Ready: scripts/release.sh $VERSION would build, tag and release $VERSION"
    fi
    exit 0
  fi

  if (( RESUME )); then
    say "Resuming $VERSION from tag v$VERSION"
    git push -q origin main "v$VERSION"
  else
    local build why
    build=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $build" "$PLIST"

    scripts/test.sh >/dev/null
    scripts/build.sh --install --run --zip
    why=$(verify_zip "$VERSION" "$ZIP") || die "$why"

    git add "$PLIST" CHANGELOG.md
    git commit -q -m "chore(release): $VERSION

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
    git tag -a "v$VERSION" -m "Paneflo $VERSION"
    git push -q origin main "v$VERSION"
  fi

  create_release
  verify_published
  say "Released $VERSION"
}

# Sourcing the script only defines the functions, so they can be tried on their own.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
