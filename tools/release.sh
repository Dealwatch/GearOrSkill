#!/usr/bin/env bash
# Packages the addon and publishes a GitHub release that WowUp can install from the repo URL.
# The version comes from GearOrSkill.toc. If the generated files have uncommitted changes (the
# daily refresh), the patch version is raised and they are committed first. A version that
# already has a release is left alone.
set -euo pipefail

toc=GearOrSkill.toc
version=$(sed -n 's/^## Version: //p' "$toc")
notes="See the README for what the addon does and its current limits."

if ! git diff --quiet -- Data.lua Calibration.lua; then
	IFS=. read -r major minor patch <<<"$version"
	version="$major.$minor.$((patch + 1))"
	sed -i "s/^## Version: .*/## Version: $version/" "$toc"
	notes="Data refresh from https://github.com/wowsims/forever (stat weights, items, calibration)."
	git config user.name "github-actions[bot]"
	git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
	git commit --quiet -m "Update data from wowsims, version $version" Data.lua Calibration.lua "$toc"
	git push --quiet origin "HEAD:${GITHUB_REF_NAME}"
fi

tag="v$version"
if gh release view "$tag" >/dev/null 2>&1; then
	echo "$tag is already released"
	exit 0
fi

interface=$(sed -n 's/^## Interface: //p' "$toc")
out=$(mktemp -d)
mkdir "$out/GearOrSkill"
cp "$toc" Data.lua Calibration.lua Core.lua UI.lua Probe.lua "$out/GearOrSkill/"
# WowUp picks the zip for the Forever client by the "-forever" suffix or by release.json.
zip="GearOrSkill-$tag-forever.zip"
(cd "$out" && zip -qr "$zip" GearOrSkill)
printf '{"releases":[{"name":"GearOrSkill","version":"%s","filename":"%s","nolib":false,"metadata":[{"flavor":"forever","interface":%s}]}]}\n' \
	"$tag" "$zip" "$interface" >"$out/release.json"
gh release create "$tag" "$out/$zip" "$out/release.json" --target "$(git rev-parse HEAD)" --title "$tag" --notes "$notes"
