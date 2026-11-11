#!/usr/bin/env bash
set -euo pipefail

command=${1:-}
version=${2:-}
if [[ ! $version =~ ^[0-9][0-9.]*$ || ( $command != check && $command != publish ) ]]; then
    echo 'Usage: release.sh check VERSION | publish VERSION COMMIT [OUTPUT_DIR]' >&2
    exit 1
fi
: "${GITHUB_REPOSITORY:?Set GITHUB_REPOSITORY to owner/repo}"
tag="v$version"

# Only a real 404 means a release is absent; API/auth failures must stop the run.
if response=$(gh api --include "repos/$GITHUB_REPOSITORY/releases/tags/$tag"); then
    state=$(sed '1,/^[[:space:]]*$/d' <<< "$response" | jq -er '
        if .draft == true then "draft"
        elif .draft == false then "published"
        else error("Invalid release response") end')
elif [[ $(awk 'NR == 1 {print $2}' <<< "$response") == 404 ]]; then
    state=missing
    if [[ $command == publish ]]; then
        # The tag endpoint only finds published releases. Listings include drafts
        # for the write-permission job, which must resume rather than duplicate them.
        matches=$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" --jq \
            ".[] | select(.tag_name == \"$tag\") | if .draft == true then \"draft\" elif .draft == false then \"published\" else error(\"Invalid release response\") end")
        case "$matches" in
            '') state=missing ;;
            draft|published) state=$matches ;;
            *) echo 'Ambiguous releases for this tag; refusing to publish' >&2; exit 1 ;;
        esac
    fi
else
    echo 'Could not determine GitHub release state' >&2
    exit 1
fi

if [[ $command == check ]]; then
    if [[ $state == published ]]; then printf 'false\n'; else printf 'true\n'; fi
    exit 0
fi
if [[ $state == published ]]; then
    echo "$tag is already published; leaving it unchanged."
    exit 0
fi

commit=${3:?Provide the commit used to build the image}
output_dir=${4:-dist}
image="Amp-$version-x86_64.AppImage"
assets=("$output_dir/$image" "$output_dir/$image.sha256" "$output_dir/$image.build-info.txt")
for asset in "${assets[@]}"; do
    [[ -s "$asset" ]] || { echo "Missing release asset: $asset" >&2; exit 1; }
done
(cd "$output_dir" && sha256sum --check "$image.sha256")

if [[ $state == missing ]]; then
    gh release create "$tag" --repo "$GITHUB_REPOSITORY" --draft --target "$commit" \
        --title "Amp $version (unofficial AppImage)" \
        --notes "Unofficial x86-64 repack of Amp's signed Debian package.

Download the AppImage, make it executable, and run it. Use --appimage-extract-and-run if FUSE is unavailable. Host desktop libraries and working user namespaces are required; the Chromium sandbox is not disabled.

Checksums and build provenance are attached. See the repository README for build instructions."
fi
# A failed upload leaves a draft. A later run can safely replace its partial assets.
gh release upload "$tag" --repo "$GITHUB_REPOSITORY" --clobber "${assets[@]}"
gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --target "$commit" --draft=false --latest
