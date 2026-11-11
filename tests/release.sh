#!/usr/bin/env bash
set -euo pipefail
root=$(dirname "$(dirname "$(realpath "$0")")")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/dist" "$work/remote"
export MOCK_STATE="$work/state" MOCK_REMOTE="$work/remote" GITHUB_REPOSITORY=example/amp-appimage
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state=$(cat "$MOCK_STATE")
if [[ $1 == api ]]; then
    if [[ $3 == *'/releases?per_page=100' ]]; then
        case "$state" in
            draft) printf 'draft\n' ;;
            duplicate) printf 'draft\ndraft\n' ;;
            missing) : ;;
            *) exit 1 ;;
        esac
        exit 0
    fi
    case "$state" in
        missing|draft|duplicate|listing-unavailable) printf 'HTTP/2.0 404 Not Found\r\n\r\n{}\n'; exit 1 ;;
        unavailable) printf 'HTTP/2.0 503 Service Unavailable\r\n\r\n{}\n'; exit 1 ;;
        denied) printf 'HTTP/2.0 403 Forbidden\r\n\r\n{}\n'; exit 1 ;;
        published) printf 'HTTP/2.0 200 OK\r\n\r\n{"draft":false}\n' ;;
        *) exit 1 ;;
    esac
elif [[ $1 == release && $2 == create ]]; then
    [[ $state == missing ]]
    echo draft > "$MOCK_STATE"
elif [[ $1 == release && $2 == upload ]]; then
    [[ ${MOCK_FAIL_UPLOAD:-false} != true ]]
    shift 3
    while (($#)); do
        case "$1" in
            --repo) shift 2 ;;
            --clobber) shift ;;
            *) cp "$1" "$MOCK_REMOTE/"; shift ;;
        esac
    done
elif [[ $1 == release && $2 == edit ]]; then
    echo published > "$MOCK_STATE"
else
    exit 1
fi
SH
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"
version=0.1.12345678
image="Amp-$version-x86_64.AppImage"
printf 'test image\n' > "$work/dist/$image"
printf 'test provenance\n' > "$work/dist/$image.build-info.txt"
(cd "$work/dist" && sha256sum "$image" > "$image.sha256")

for state in missing draft published; do
    echo "$state" > "$MOCK_STATE"
    expected=true
    [[ $state != published ]] || expected=false
    [[ $("$root/release.sh" check "$version") == "$expected" ]]
done
echo 'PASS: only missing and draft releases need a build'
for state in denied unavailable; do
    echo "$state" > "$MOCK_STATE"
    if "$root/release.sh" check "$version" >/dev/null 2>&1; then exit 1; fi
done
echo 'PASS: API failures are not mistaken for missing releases'

echo published > "$MOCK_STATE"
printf 'original published image\n' > "$MOCK_REMOTE/$image"
"$root/release.sh" publish "$version" test-commit "$work/dist" >/dev/null
[[ $(cat "$MOCK_STATE") == published && $(cat "$MOCK_REMOTE/$image") == 'original published image' ]]
echo 'PASS: published releases are never modified'

for state in listing-unavailable duplicate; do
    echo "$state" > "$MOCK_STATE"
    if "$root/release.sh" publish "$version" test-commit "$work/dist" >/dev/null 2>&1; then exit 1; fi
    [[ $(cat "$MOCK_STATE") == "$state" ]]
done
echo 'PASS: failed or ambiguous draft discovery prevents publication'

echo missing > "$MOCK_STATE"
if MOCK_FAIL_UPLOAD=true "$root/release.sh" publish "$version" test-commit "$work/dist" >/dev/null; then exit 1; fi
[[ $(cat "$MOCK_STATE") == draft ]]
"$root/release.sh" publish "$version" test-commit "$work/dist" >/dev/null
[[ $(cat "$MOCK_STATE") == published ]]
for asset in "$image" "$image.sha256" "$image.build-info.txt"; do
    cmp "$work/dist/$asset" "$MOCK_REMOTE/$asset"
done
echo 'PASS: failed uploads stay draft and a retry completes the release'

echo missing > "$MOCK_STATE"
printf 'corruption\n' >> "$work/dist/$image"
if "$root/release.sh" publish "$version" test-commit "$work/dist" >/dev/null 2>&1; then exit 1; fi
[[ $(cat "$MOCK_STATE") == missing && $(cat "$MOCK_REMOTE/$image") == 'test image' ]]
echo 'PASS: checksum mismatch prevents release creation'
