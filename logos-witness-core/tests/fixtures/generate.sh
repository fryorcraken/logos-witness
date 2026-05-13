#!/usr/bin/env bash
# Regenerate the strip-pipeline test fixtures.
#
# These outputs are committed to the repo; this script exists so a future
# agent (or human) can rebuild them deterministically without guessing what
# metadata they're meant to carry. Run from this directory:
#
#   nix shell nixpkgs#exiftool nixpkgs#imagemagick nixpkgs#colord --command bash generate.sh
#
# Tools used:
#   - magick   (ImageMagick 7) for the baseline image
#   - exiftool to embed metadata variants without changing pixel data
#
# Each fixture carries one *category* of identifying metadata that the
# strip pipeline must remove (SPEC §7.1). The `clean.jpg` baseline carries
# none and is the expected decoded-pixel output for every variant.

set -euo pipefail
cd "$(dirname "$0")"

require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: '$1' not on PATH. Try: nix shell nixpkgs#exiftool nixpkgs#imagemagick --command bash $0" >&2
        exit 2
    }
}
require magick
require exiftool

# Baseline: a 64x64 plasma fractal. Plasma gives non-uniform DCT
# coefficients (so coefficient-copy strip exercises real data, not all
# zeros). -quality 85 is the libjpeg-turbo default-ish setting and keeps
# the file under 4 KB. -define preserves an exact baseline JPEG.
echo "[fixgen] clean.jpg"
magick -size 64x64 plasma:fractal \
    -quality 85 \
    -define jpeg:optimize-coding=false \
    -strip \
    clean.jpg

# All variants start as a byte-for-byte copy of clean.jpg, then exiftool
# adds metadata in-place. exiftool *does not re-encode pixels*, so the
# DCT coefficients (and therefore decoded pixels) remain identical.
#
# `-overwrite_original` skips the *_original sidecar; we don't need it.

mkvariant() {
    local out="$1"; shift
    cp clean.jpg "$out"
    exiftool -q -overwrite_original "$@" "$out" >/dev/null
}

echo "[fixgen] exif_rich.jpg"
mkvariant exif_rich.jpg \
    -EXIF:Make="ACME Cameras" \
    -EXIF:Model="Witness-9000" \
    -EXIF:Software="logos-witness-fixgen" \
    -EXIF:DateTimeOriginal="2026:03:14 09:26:53" \
    -EXIF:GPSLatitude=51.5074 -EXIF:GPSLatitudeRef=N \
    -EXIF:GPSLongitude=-0.1278 -EXIF:GPSLongitudeRef=W \
    -EXIF:Artist="Mallory Identifiable" \
    -EXIF:UserComment="hello from exif"

echo "[fixgen] xmp_rich.jpg"
mkvariant xmp_rich.jpg \
    -XMP:Creator="Mallory Identifiable" \
    -XMP:Rights="(c) 2026 ACME" \
    -XMP:Title="A photo of a thing" \
    -XMP:Description="XMP metadata that must not survive"

echo "[fixgen] icc_tagged.jpg"
# Embed an actual ICC profile. Use the bundled sRGB profile that
# ImageMagick ships in its color/ tree; fall back to a synthetic minimal
# profile if not present.
ICC_SOURCE=""
# Prefer the nix-shipped colord profile (deterministic across machines);
# fall back to whatever the host has if someone runs this outside of the
# nix shell.
for cand in \
    /nix/store/*-colord-*/share/color/icc/colord/sRGB.icc \
    /run/current-system/sw/share/color/icc/colord/sRGB.icc \
    /usr/share/color/icc/colord/sRGB.icc \
    /etc/colord/icc/sRGB.icc
do
    # `compgen -G` returns the first matching path or nothing.
    match=$(compgen -G "$cand" 2>/dev/null | head -1) || true
    if [ -n "${match:-}" ] && [ -f "$match" ]; then ICC_SOURCE="$match"; break; fi
done
if [ -z "$ICC_SOURCE" ]; then
    echo "error: no sRGB.icc found. Re-run with: nix shell nixpkgs#colord ..." >&2
    exit 5
fi
cp clean.jpg icc_tagged.jpg
exiftool -q -overwrite_original "-icc_profile<=$ICC_SOURCE" icc_tagged.jpg >/dev/null

echo "[fixgen] thumbnail.jpg"
# An embedded JPEG thumbnail lives inside the EXIF IFD1. Build one by
# scaling the baseline down to 16x16 and asking exiftool to embed it.
magick clean.jpg -resize 16x16 thumb_tmp.jpg
cp clean.jpg thumbnail.jpg
exiftool -q -overwrite_original \
    "-ThumbnailImage<=thumb_tmp.jpg" \
    -IFD1:Compression=6 \
    thumbnail.jpg >/dev/null
rm -f thumb_tmp.jpg

echo "[fixgen] jfif_comment.jpg"
# JPEG COM (0xFFFE) segments hold arbitrary user-supplied text that the
# `-comment` flag of libjpeg's `cjpeg` and Photoshop write. Strip must
# drop this too. We also bolt on an IPTC keyword (Photoshop IRB, APP13)
# so this fixture exercises *two* metadata channels at once.
cp clean.jpg jfif_comment.jpg
exiftool -q -overwrite_original \
    "-Comment=mallory was here" \
    "-IPTC:Keywords=mallory,witness,leak" \
    jfif_comment.jpg >/dev/null

# Verify the fixtures actually carry what they claim. Bail if exiftool
# reports zero identifying tags on a variant — that means we built a
# trivial fixture and the test would falsely pass.
verify_has_metadata() {
    local f="$1"
    local pat="$2"
    # `grep -q` exits on first match → SIGPIPE to exiftool → with
    # `pipefail` the pipeline reports failure even on success. Drop -q,
    # redirect, and check grep's exit code directly.
    local out; out=$(exiftool -a -G1 "$f")
    if ! printf '%s\n' "$out" | grep -qE "$pat"; then
        echo "error: fixture $f does not contain expected $pat metadata" >&2
        exit 3
    fi
}
verify_has_metadata exif_rich.jpg     '^\[(IFD0|ExifIFD|GPS)\]'
verify_has_metadata xmp_rich.jpg      '^\[XMP'
verify_has_metadata icc_tagged.jpg    '^\[ICC[-_]'
verify_has_metadata thumbnail.jpg     'Thumbnail (Image|Length)'
verify_has_metadata jfif_comment.jpg  'Comment'
verify_has_metadata jfif_comment.jpg  '^\[IPTC'

# And confirm clean.jpg is genuinely clean — anything other than JFIF
# (which is structural, not identifying) means our baseline leaks.
leaks=$(exiftool -a -G1 -s clean.jpg | grep -vE '^\[(JFIF|ExifTool|File|System|Composite)\]')
if [ -n "$leaks" ]; then
    echo "error: clean.jpg baseline contains identifying metadata:" >&2
    echo "$leaks" >&2
    exit 4
fi

ls -la *.jpg
echo "[fixgen] done."
