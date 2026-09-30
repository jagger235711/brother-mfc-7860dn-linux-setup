#!/bin/sh
# marker: brother-mfc-7860dn-copies-fix
#
# CUPS wrapper for the `universal` filter (cups-filters 2.x / libcupsfilters).
# Installed by install.sh as /usr/lib/cups/filter/universal; the distro
# binary is kept next to it as universal.real.
#
# Why this exists
# ---------------
# cupsd passes the job copy count as argv[4] and strips `copies` out of the
# options string (argv[5]). pdftopdf inside libcupsfilters <= 2.2.1 only
# honours a `copies=N` key that is present in the options string; the
# argv[4] -> data->copies fallback exists only in upstream master. Result:
# every `lp -n 3` job printed exactly one copy, with no error anywhere.
#
# This wrapper re-injects argv[4] as `copies=N` into the options string
# before handing the job to the real filter, so pdftopdf performs the
# software copies (in collated order, so duplex jobs stay correctly ordered:
# 1,2,1,2,...). For multi-copy duplex jobs it also makes sure pdftopdf's
# odd-page blank-page padding actually survives, without letting the forced
# layout path flip the back sides 180 degrees (see "Odd-page duplex
# multi-copy padding" below).
#
# No double copying: downstream filters on this printer's chains (gstopxl,
# ghostscript pxlmono, the Brother PS path) ignore the copies option, and
# the upstream fix itself is written as a fallback
# (`if data->copies > 1 && filter_options->copies <= 1`), so if a future
# libcupsfilters starts honouring argv[4] as well, the injected value and
# argv[4] are the same number and nothing is applied twice.
#
# NOTE: a cups-filters package upgrade overwrites this wrapper with the
# original ELF binary and the bug comes back. Re-run install.sh to restore
# the fix (it is idempotent).

REAL="$(dirname "$0")/universal.real"
if [ ! -x "$REAL" ]; then
    echo "brother-mfc-7860dn-copies-fix: missing $REAL" >&2
    exit 1
fi

# Filter contract: job-id user title copies options [file]
if [ "$#" -lt 5 ]; then
    exec "$REAL" "$@"
fi

job_id="$1"
user="$2"
title="$3"
copies="$4"
options="$5"
shift 5

[ -n "$copies" ] || copies=1

# Drop any pre-existing copies key (queue defaults), then prepend ours so the
# first occurrence - the one cupsGetOption() returns - is the real job count.
new_opts="copies=$copies"
for opt in $options; do
    case "$opt" in
        copies=*) ;;
        *) new_opts="$new_opts $opt" ;;
    esac
done

# Odd-page duplex multi-copy padding
# ----------------------------------
# Copy N of an odd-page duplex job must not start on the back of copy N-1's
# last sheet; pdftopdf therefore pads the document to an even page count so
# each copy in the copies loop repeats an even-length block. The padding
# itself exists upstream (libcupsfilters pdftopdf.c: `if ((d->last_page & 1)
# && duplex) d->last_page ++`), but it only survives when pdftopdf takes its
# LAYOUT path: the FAST path copies pages with
# `if (outpage->input[0]) pdfioPageCopy(...)` and silently drops the padded
# slot, because pdfioFileGetPage() returns NULL for the page that does not
# exist in the input document. Result without this fix: 3-page job x 2
# copies duplex came out as 6 pages 1,2,3,1,2,3 -> sheets 1|2, 3|1, 2|3,
# i.e. copy 2 started on the back of copy 1.
#
# Two inputs decide that path / the padding, so for multi-copy duplex jobs
# this wrapper rewrites the options it passes to the real filter (cupsd
# gives every filter in the chain its own copy of the original options
# string, so downstream gstopxl/pdftops are NOT affected by the rewrite):
#
#   1. orientation-requested=3 (portrait, an identity transform) forces the
#      layout path, where the padded slot is emitted as a real blank page
#      (`pdfio_start_page()` is called unconditionally). Neither queue's
#      PPD defines *OrientationRequested, so nothing re-reads the injected
#      value; an orientation-requested already sent by the application is
#      left untouched (any explicit value already forces the layout path).
#
#   2. sides is forced to `two-sided-short-edge` - a deliberate lie about a
#      value pdftopdf is the only consumer of here. pdftopdf hardcodes
#      sheet_back="rotated" (libcupsfilters 2.2.1, no option to change it)
#      and on the layout path that ROTATES EVERY BACK SIDE 180 degrees when
#      sides=two-sided-long-edge:
#        `(!strcmp(sheet_back, "rotated") && !strcmp(sides, "two-sided-long-edge"))`
#      -> duplex_xform = [-1 0; 0 -1] (rotate 180).
#      The fast path never applied this transform, which is why long-edge
#      duplex looked correct before this wrapper forced the layout path -
#      and wrong (backs upside down) after. With sides=two-sided-short-edge
#      the branch does not fire (no transform at all = pre-fix rendering),
#      while the padding still triggers, because pdftopdf's duplex test is
#      only `strncmp(sides, "two-sided-", 10)`.
#      Downstream is unaffected: gstopxl derives -dDuplex from the PPD
#      `Duplex=` option (untouched) and cfGetBackSideOrientation() reads
#      printer attributes, never the job's sides value.
case "$copies" in
    ''|0|1|*[!0-9]*) multi=0 ;;
    *) multi=1 ;;
esac

if [ "$multi" = 1 ]; then
    duplex=0 has_orientation=0
    for opt in $new_opts; do
        case "$opt" in
            sides=two-sided-*)       duplex=1 ;;
            Duplex=Duplex*)          duplex=1 ;;   # DuplexTumble/NoTumble, not Duplex=None
            orientation-requested=*) has_orientation=1 ;;
        esac
    done

    if [ "$duplex" = 1 ]; then
        # Drop the original sides= value(s), then hand pdftopdf the
        # rotation-neutral one (see above).
        rebuilt=""
        for opt in $new_opts; do
            case "$opt" in
                sides=*) ;;
                *) rebuilt="$rebuilt $opt" ;;
            esac
        done
        new_opts="$rebuilt sides=two-sided-short-edge"

        if [ "$has_orientation" = 0 ]; then
            new_opts="$new_opts orientation-requested=3"
        fi
    fi
fi

exec "$REAL" "$job_id" "$user" "$title" "$copies" "$new_opts" "$@"
