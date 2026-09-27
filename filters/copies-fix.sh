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
# 1,2,1,2,...).
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

exec "$REAL" "$job_id" "$user" "$title" "$copies" "$new_opts" "$@"
