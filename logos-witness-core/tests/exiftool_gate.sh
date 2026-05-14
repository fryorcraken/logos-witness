#!/usr/bin/env bash
# SPEC §7.1 / Phase 4.2 — residual-metadata gate.
#
# Runs exiftool -a -G1 over every stripped JPEG produced by
# test_exif_strip and asserts that nothing identifying survives.
#
# The filter excludes five groups that are either derived from the
# filesystem (System), the JPEG structure itself (File, JFIF), the
# tool that wrote them (ExifTool), or computed from other fields
# (Composite). Any tag *outside* those groups is by definition
# identifying — typical residue would be IFD0/ExifIFD/GPS/XMP-*/ICC_*.
#
# Usage:  exiftool_gate.sh <stripped-dir>
#
# Exit codes:
#   0 — every file in <stripped-dir> is clean
#   1 — at least one file retained identifying metadata
#   2 — invocation problem (missing dir, no fixtures, exiftool missing)

set -eu

if [ $# -ne 1 ]; then
    echo "usage: $0 <stripped-dir>" >&2
    exit 2
fi
DIR=$1

if [ ! -d "$DIR" ]; then
    echo "exiftool_gate: directory does not exist: $DIR" >&2
    exit 2
fi

if ! command -v exiftool > /dev/null; then
    echo "exiftool_gate: exiftool not on PATH" >&2
    exit 2
fi

shopt -s nullglob
files=("$DIR"/*.jpg)
if [ ${#files[@]} -eq 0 ]; then
    echo "exiftool_gate: no *.jpg in $DIR — did test_exif_strip run?" >&2
    exit 2
fi

fail=0
for f in "${files[@]}"; do
    # --GROUP:all excludes the group from the readout. What remains is
    # tags from any group we did NOT whitelist.
    residue=$(exiftool -a -G1 \
                       --ExifTool:all \
                       --System:all \
                       --File:all \
                       --JFIF:all \
                       --Composite:all \
                       "$f")
    if [ -n "$residue" ]; then
        echo "::error::exiftool_gate: residual metadata in $(basename "$f"):"
        echo "$residue"
        fail=1
    else
        echo "exiftool_gate: clean $(basename "$f")"
    fi
done

exit "$fail"
