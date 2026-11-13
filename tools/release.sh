#!/usr/bin/env bash
# Packages the addon and publishes a GitHub release that WowUp can install from the repo URL.
# On a tag: releases that tag. Otherwise: if Data.lua changed, commits it, tags the next
# patch version and releases that; if not, does nothing.
set -euo pipefail

if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
	tag="$GITHUB_REF_NAME"
	notes="See the README for what the addon does and its current limits."
else
	if git diff --quiet -- Data.lua; then
		echo "Data.lua unchanged, nothing to release"
		exit 0
	fi
	last=$(git tag --list 'v*' --sort=-v:refname | head -n 1)
	if [[ -z "$last" ]]; then
		echo "No release tag yet; push a first tag by hand" >&2
		exit 1
	fi
	IFS=. read -r major minor patch <<<"${last#v}"
	tag="v$major.$minor.$((patch + 1))"
	notes="Data refresh from https://github.com/wowsims/forever (stat weights and items)."
	git config user.name "github-actions[bot]"
	git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
	git commit --quiet -m "Update data from wowsims" Data.lua
	git tag "$tag"
	git push --quiet origin "HEAD:${GITHUB_REF_NAME}" "$tag"
fi

interface=$(sed -n 's/^## Interface: //p' GearOrSkill.toc)
out=$(mktemp -d)
mkdir "$out/GearOrSkill"
cp GearOrSkill.toc Data.lua Core.lua UI.lua Probe.lua "$out/GearOrSkill/"
sed -i "s/^## Version: .*/## Version: ${tag#v}/" "$out/GearOrSkill/GearOrSkill.toc"
# WowUp picks the zip for the Forever client by the "-forever" suffix or by release.json.
zip="GearOrSkill-$tag-forever.zip"
(cd "$out" && zip -qr "$zip" GearOrSkill)
printf '{"releases":[{"name":"GearOrSkill","version":"%s","filename":"%s","nolib":false,"metadata":[{"flavor":"forever","interface":%s}]}]}\n' \
	"$tag" "$zip" "$interface" >"$out/release.json"
gh release create "$tag" "$out/$zip" "$out/release.json" --title "$tag" --notes "$notes"
