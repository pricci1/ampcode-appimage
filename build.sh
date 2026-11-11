#!/usr/bin/env bash
# Repackage the official amd64 Debian payload; never install it on the host.
set -euo pipefail

check_only=false
if [[ ${1:-} == --check-version ]]; then
    check_only=true
    shift
fi
if (($# > 1)) || { [[ $check_only == true ]] && (($# > 0)); }; then
    echo 'Usage: build.sh [OUTPUT_DIR] | --check-version' >&2
    exit 1
fi

if [[ $(uname -m) != x86_64 ]]; then
    echo 'This builder currently supports x86-64 Linux only.' >&2
    exit 1
fi
for command in curl gpg gpgv dpkg-deb sha256sum awk sed realpath; do
    command -v "$command" >/dev/null || { echo "Missing build dependency: $command" >&2; exit 1; }
done

source_dir=$(dirname "$(realpath "$0")")
output_dir=${1:-"$source_dir/dist"}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -m 700 "$work/gnupg"
export GNUPGHOME="$work/gnupg"

repo=https://static.ampcode.com/linux
key_fingerprint=26B08A8375D99B8A42DF4A1C4D51480EEEEC728B
tool_url=https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
tool_sha=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
runtime_url=https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64
runtime_sha=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d

download() {
    curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' "$1" -o "$2"
}
verify() {
    printf '%s  %s\n' "$1" "$2" | sha256sum --check --status
}

download "$repo/amp.sources" "$work/amp.sources"
awk '/^ -----BEGIN PGP PUBLIC KEY BLOCK-----/{key=1} key {sub(/^ /, ""); if ($0 == ".") print ""; else print} /^-----END PGP PUBLIC KEY BLOCK-----/{exit}' \
    "$work/amp.sources" > "$work/key.asc"
fingerprint=$(gpg --batch --show-keys --with-colons "$work/key.asc" | awk -F: '
    $1 == "pub" {primaries++}
    $1 == "fpr" && !fingerprint {fingerprint=$10}
    END {if (primaries == 1) print fingerprint}')
[[ "$fingerprint" == "$key_fingerprint" ]] || { echo 'Amp signing key fingerprint mismatch' >&2; exit 1; }
gpg --batch --dearmor --output "$work/key.gpg" "$work/key.asc"
download "$repo/dists/stable/InRelease" "$work/InRelease"
gpgv --keyring "$work/key.gpg" --output "$work/Release" "$work/InRelease"

index=main/binary-amd64/Packages
index_sha=$(awk -v path="$index" '/^SHA256:/{sha=1; next} sha && /^[^ ]/{sha=0} sha && $3 == path {print $1}' "$work/Release")
[[ "$index_sha" =~ ^[0-9a-f]{64}$ ]] || { echo 'Missing signed package-index checksum' >&2; exit 1; }
download "$repo/dists/stable/$index" "$work/Packages"
verify "$index_sha" "$work/Packages"
read -r version filename deb_sha < <(awk '
    BEGIN {RS=""; FS="\n"}
    {delete field; for (i=1; i<=NF; i++) {split($i, parts, ": "); field[parts[1]]=parts[2]}}
    field["Package"] == "amp-desktop" && field["Architecture"] == "amd64" {
        print field["Version"], field["Filename"], field["SHA256"]; exit
    }' "$work/Packages")
[[ "$version" =~ ^[0-9][0-9.]*$ && "$filename" == "$version/amp-desktop-$version-amd64.deb" && "$deb_sha" =~ ^[0-9a-f]{64}$ ]] || {
    echo 'Unexpected Amp package metadata' >&2; exit 1;
}
if [[ $check_only == true ]]; then
    printf '%s\n' "$version"
    exit 0
fi
mkdir -p "$output_dir"
output_dir=$(realpath "$output_dir")
download "$repo/$filename" "$work/amp.deb"
verify "$deb_sha" "$work/amp.deb"
[[ $(dpkg-deb -f "$work/amp.deb" Package) == amp-desktop && $(dpkg-deb -f "$work/amp.deb" Architecture) == amd64 && $(dpkg-deb -f "$work/amp.deb" Version) == "$version" ]]

appdir="$work/Amp.AppDir"
dpkg-deb --extract "$work/amp.deb" "$appdir"
# AppImages cannot use a root-owned setuid helper. Keep the user-namespace sandbox.
chmod 0755 "$appdir/opt/amp/chrome-sandbox"
install -m 0755 "$source_dir/AppRun" "$appdir/AppRun"
sed 's|^Exec=/opt/amp/amp-desktop|Exec=AppRun|' \
    "$appdir/usr/share/applications/amp-desktop.desktop" > "$appdir/amp-desktop.desktop"
cp "$appdir/amp-desktop.desktop" "$appdir/usr/share/applications/amp-desktop.desktop"
ln -s usr/share/icons/hicolor/512x512/apps/amp-desktop.png "$appdir/amp-desktop.png"
ln -s amp-desktop.png "$appdir/.DirIcon"

download "$tool_url" "$work/appimagetool"
verify "$tool_sha" "$work/appimagetool"
download "$runtime_url" "$work/runtime"
verify "$runtime_sha" "$work/runtime"
chmod +x "$work/appimagetool"
image="Amp-$version-x86_64.AppImage"
# Extracting the build tool avoids requiring FUSE on the build host.
ARCH=x86_64 VERSION="$version" "$work/appimagetool" --appimage-extract-and-run \
    --no-appstream --runtime-file "$work/runtime" --comp zstd \
    "$appdir" "$work/$image"
install -m 0755 "$work/$image" "$output_dir/$image"
(
    cd "$output_dir"
    sha256sum "$image" > "$image.sha256"
)
cat > "$output_dir/$image.build-info.txt" <<EOF
Unofficial Amp AppImage repack
Version: $version
Architecture: x86_64
Debian source: $repo/$filename
Debian SHA256: $deb_sha
APT signing key: $key_fingerprint
APT index SHA256: $index_sha
appimagetool: $tool_url
appimagetool SHA256: $tool_sha
Runtime: $runtime_url
Runtime SHA256: $runtime_sha
EOF
printf '\nBuilt: %s/%s\n' "$output_dir" "$image"
