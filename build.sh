#!/usr/bin/env bash
# Runs inside an archlinux container with the repo mounted at /work.
set -euo pipefail

REPO_NAME="linux-cachyos-dongle"  # pacman repo name; must match the [section] in pacman.conf
TAG="repo"                        # release tag that hosts the files
PKGBASE="linux-cachyos-dongle"    # package name; differs from the stock linux-cachyos

pacman -Syu --noconfirm --needed base-devel git sudo github-cli pacman-contrib

useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder

LTO_MODE="thin"                # "thin" or "full" keeps LTO; "none" builds much faster; "" uses the PKGBUILD default
PROCESSOR_OPT="generic_v3"     # target x86-64-v3 instead of the CPU of the GitHub runner

as_builder() {
  sudo -u builder -H env MAKEFLAGS="-j$(nproc)" \
    _processor_opt="$PROCESSOR_OPT" ${LTO_MODE:+_use_llvm_lto="$LTO_MODE"} \
    bash -c "cd /build && $*"
}

# ---- 1. Detect changes -------------------------------------------------------
git clone --filter=blob:none https://github.com/CachyOS/linux-cachyos.git /tmp/upstream
UP_COMMIT=$(git -C /tmp/upstream log -1 --format=%H -- linux-cachyos)

shopt -s nullglob
patches=(/work/patches/*.patch)
if (( ${#patches[@]} )); then
  PATCH_HASH=$(cat "${patches[@]}" | sha256sum | cut -d' ' -f1)
else
  PATCH_HASH=none
fi
SCRIPT_HASH=$(sha256sum /work/build.sh | cut -d' ' -f1)

NEW_STATE="$UP_COMMIT $PATCH_HASH $SCRIPT_HASH"
OLD_STATE=$(curl -fsSL "https://github.com/${GITHUB_REPOSITORY}/releases/download/${TAG}/state.txt" || true)

if [ "${FORCE:-false}" != "true" ] && [ "$OLD_STATE" = "$NEW_STATE" ]; then
  echo "No changes since last build."
  exit 0
fi

# ---- 2. Prepare the PKGBUILD -------------------------------------------------
install -d -o builder -g builder /build
cp -a /tmp/upstream/linux-cachyos/. /build/
chown -R builder:builder /build
cd /build

# Rename so it doesn't clash with the stock linux-cachyos package
sed -i -E 's/^([[:space:]]*_pkgsuffix=).*/\1"cachyos-custom"/' PKGBUILD

# Add your patches to the end of the source list (applied after the CachyOS patches)
names=()
for p in "${patches[@]}"; do
  cp "$p" /build/
  chown builder:builder "/build/$(basename "$p")"
  names+=("'$(basename "$p")'")
done
if (( ${#names[@]} )); then
  printf '\nsource+=(%s)\n' "${names[*]}" >> PKGBUILD
fi

SRCINFO=$(as_builder "makepkg --printsrcinfo")
if ! grep -qx "pkgbase = ${PKGBASE}" <<<"$SRCINFO"; then
  echo "pkgbase rename failed: adjust the sed line in build.sh to match the upstream PKGBUILD." >&2
  exit 1
fi

# ---- 3. Signing key ----------------------------------------------------------
printf '%s\n' "$GPG_PRIVATE_KEY" | sudo -u builder -H gpg --batch --import
KEYID=$(sudo -u builder -H gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')

# ---- 4. Fetch, patch (fail fast if a patch doesn't apply), then build --------
as_builder "updpkgsums"
as_builder "makepkg -so --noconfirm --skippgpcheck" 2>&1 | tee /tmp/prepare.log

for p in "${patches[@]}"; do
  grep -q "Applying patch $(basename "$p")" /tmp/prepare.log \
    || { echo "Patch $(basename "$p") was not applied by the PKGBUILD." >&2; exit 1; }
done

as_builder "makepkg -e --noconfirm --sign --key '$KEYID' --skippgpcheck" 2>&1 | tee /tmp/build.log

# ---- 5. Create the repo database ---------------------------------------------
as_builder "repo-add --sign --key '$KEYID' ${REPO_NAME}.db.tar.zst *.pkg.tar.zst"

mkdir -p /out /state
cp /build/*.pkg.tar.zst /build/*.pkg.tar.zst.sig /out/
for f in db files; do
  cp --remove-destination "/build/${REPO_NAME}.${f}.tar.zst" "/out/${REPO_NAME}.${f}"
  if [ -f "/build/${REPO_NAME}.${f}.tar.zst.sig" ]; then
    cp --remove-destination "/build/${REPO_NAME}.${f}.tar.zst.sig" "/out/${REPO_NAME}.${f}.sig"
  fi
done
sudo -u builder -H gpg --armor --export "$KEYID" > "/out/${REPO_NAME}.pub.asc"
echo "$NEW_STATE" > /state/state.txt

# ---- 6. Publish to the GitHub release ----------------------------------------
if ! gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  gh release create "$TAG" --repo "$GITHUB_REPOSITORY" --title "Pacman repo" \
    --notes "Automatically built pacman repository. Do not edit."
fi

gh release upload "$TAG" /out/* --repo "$GITHUB_REPOSITORY" --clobber

# Remove assets left over from older builds
for a in $(gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json assets -q '.assets[].name'); do
  if [ "$a" != "state.txt" ] && [ ! -e "/out/$a" ]; then
    gh release delete-asset "$TAG" "$a" --repo "$GITHUB_REPOSITORY" --yes
  fi
done

# Only record the new state once everything above succeeded
gh release upload "$TAG" /state/state.txt --repo "$GITHUB_REPOSITORY" --clobber
