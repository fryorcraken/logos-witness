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
#   1 — at least one file retained identifying metadata, OR <stripped-dir>
#       was empty (a strip pipeline that produces no outputs is a SPEC §7.1
#       regression — a "clean" gate that gates nothing isn't actually clean)
#   2 — invocation problem (bad argv, missing dir, exiftool not on PATH,
#       or exiftool itself failed mid-run)

# Deliberately NOT using `set -e` around the per-file exiftool call: under
# `-e`, `residue=$(exiftool …)` aborts the whole script on exiftool's first
# nonzero exit, and the script's exit code becomes whatever exiftool
# returned (typically 1) — indistinguishable from "residue found" in the
# exit-code contract above. We handle exiftool's exit code explicitly
# inside the loop instead.
set -u

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
    # Empty input set is a gate violation, not an invocation problem:
    # something upstream produced zero strip outputs and the gate would
    # otherwise pass-vacuously. Surface as `::error::` so CI annotations
    # render this in the Checks tab.
    echo "::error::exiftool_gate: no *.jpg in $DIR — strip pipeline produced no outputs"
    exit 1
fi

fail=0
for f in "${files[@]}"; do
    # --GROUP:all excludes the group from the readout. What remains is
    # tags from any group we did NOT whitelist.
    if ! residue=$(exiftool -a -G1 \
                            --ExifTool:all \
                            --System:all \
                            --File:all \
                            --JFIF:all \
                            --Composite:all \
                            "$f"); then
        # exiftool itself failed (binary missing mid-run, OOM, unreadable
        # file, etc.) — this is an invocation problem distinct from
        # finding residue. Exit immediately so the contract is preserved.
        echo "::error::exiftool_gate: exiftool exited nonzero on $(basename "$f")" >&2
        exit 2
    fi
    if [ -n "$residue" ]; then
        echo "::error::exiftool_gate: residual metadata in $(basename "$f"):"
        echo "$residue"
        fail=1
    else
        echo "exiftool_gate: clean $(basename "$f")"
    fi
done

exit "$fail"
