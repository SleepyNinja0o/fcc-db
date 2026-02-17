#!/bin/sh
# shellcheck disable=SC3043

# This file is part of the fcc-db ULS Amateur import project.
# Updated 2026 for HTTPS support and robust header parsing.

ts=$(date +%s)
readable=$(date -d "@$ts" +"%Y-%m-%d %r")
echo "***** ULS fetch script started at: $readable *****"

warn() { printf "%s\n" "$@" >&2; }
die() { warn "$@"; exit 1; }

usage_exit() {
        cat <<_EOF
SYNOPSIS:
$0 [-b BASEDIR] [-m] [-i INFODIR] [-z ZIPDIR] [-t TMPBASE] [-A|-L]

USAGE:
Either -b or all of -i, -z, and -t must to be defined.
-m permits creating missing directories.
-A (Apps only) or -L (Licenses only).
_EOF
        exit 0
}

parse_opts() {
        ULS_APP=defined ULS_LIC=defined
        local missingok=""
        while getopts b:i:z:t:ALmh opt; do
          case "$opt" in
                b) [ -d "$OPTARG" ] || die "Error: BASEDIR must exist"; [ "$OPTARG" != "${OPTARG#/}" ] || die "Error: BASEDIR must be absolute"; BASEDIR="$OPTARG" ;;
                i) [ "$OPTARG" = "${OPTARG#/}" ] && INFODIR="${BASEDIR:-$PWD}/$OPTARG" || INFODIR="$OPTARG"
                   if [ ! -d "$INFODIR" ]; then [ -n "$missingok" ] || die "INFODIR missing: create or use -m"; mkdir -p "$INFODIR"; fi ;;
                z) [ "$OPTARG" = "${OPTARG#/}" ] && ZIPDIR="${BASEDIR:-$PWD}/$OPTARG" || ZIPDIR="$OPTARG"
                   if [ ! -d "$ZIPDIR" ]; then [ -n "$missingok" ] || die "ZIPDIR missing: create or use -m"; mkdir -p "$ZIPDIR"; fi ;;
                t) [ "$OPTARG" = "${OPTARG#/}" ] && TMPBASE="${BASEDIR:-$PWD}/$OPTARG" || TMPBASE="$OPTARG"
                   if [ ! -d "$TMPBASE" ]; then [ -n "$missingok" ] || die "TMPBASE missing: create or use -m"; mkdir -p "$TMPBASE"; fi ;;
                A) ULS_LIC="" ;;
                L) ULS_APP="" ;;
                m) missingok=defined ;;
                h) usage_exit ;;
                *) die "Bad arguments" ;;
          esac
        done
        [ -n "$BASEDIR" ] && { [ -z "$INFODIR" ] && INFODIR="$BASEDIR"; [ -z "$ZIPDIR" ] && ZIPDIR="$BASEDIR"; [ -z "$TMPBASE" ] && TMPBASE="$BASEDIR"; }
        [ -n "$INFODIR" ] && [ -n "$ZIPDIR" ] && [ -n "$TMPBASE" ] || die "Directories not fully defined."
}

# last_mod() - Improved to handle Windows line endings and case sensitivity
last_mod() {
        grep -i '^Last-Modified: ' "$1" 2>/dev/null | tr -d '\r'
}

uls_fetch() {
        local info="" outs="" urls=""
        local uri_base="https://data.fcc.gov/download/pub/uls"
        local status="%{filename_effective} %{size_download} %{speed_download} %{url_effective}\n"
        local ext=zip

        OPTIND=1
        while getopts iW:l:a: opt; do
          case "$opt" in
                i) status="%{filename_effective}\n"; ext=info; info=defined ;;
                W) outs="$outs -o weekly_$OPTARG.$ext"; urls="$urls $uri_base/complete/${OPTARG}_amat.zip" ;;
                l) outs="$outs -o daily_l_#1.$ext"; urls="$urls $uri_base/daily/l_am_{$OPTARG}.zip" ;;
                a) outs="$outs -o daily_a_#1.$ext"; urls="$urls $uri_base/daily/a_am_{$OPTARG}.zip" ;;
          esac
        done

        if [ -n "$info" ]; then
                # Metadata fetch: stay silent
                # shellcheck disable=SC2086
                curl -f -sS -L -I -w "$status" $outs $urls
        else
                # Actual file fetch: show progress (#) so we know it's not frozen
                warn "Downloading large files from FCC..."
                # shellcheck disable=SC2086
                curl -f -L -# -w "$status" $outs $urls
        fi
}

main() {
        ULSDIR=$(mktemp -d "$TMPBASE/uls-temp.XXXXXX") || die "mktemp failed"
        SAVEDPWD="$PWD"
        trap cleanup INT TERM EXIT
        cd "$ULSDIR" || die "failed to cd to ULSDIR"

        days="sat,sun,mon,tue,wed,thu,fri"
        uls_fetch -i ${ULS_LIC:+-W l -l "$days"} ${ULS_APP:+-W a -a "$days"} || die "fetch failed for ULS metadata"

        local args="" days_l="" days_a=""
        for fn in *.info; do
                new_mod=$(last_mod "$fn")
                [ -z "$new_mod" ] && { warn "Warning: No Last-Modified header in $fn"; continue; }

                old_mod=$(last_mod "$INFODIR/$fn")
                [ "$old_mod" = "$new_mod" ] && continue

                kind="${fn%%_*}"
                al_type="${fn#*_}"
                al_type="${al_type%%_*}"
                al_type="${al_type%.*}"

                if [ "$kind" = "weekly" ]; then
                        args="$args -W $al_type"
                        continue
                fi

                day="${fn##*_}"; day="${day%.*}"
                case "$al_type" in
                        l) days_l="${days_l:+$days_l,}$day" ;;
                        a) days_a="${days_a:+$days_a,}$day" ;;
                esac
        done

        [ -n "$days_l" ] && args="$args -l $days_l"
        [ -n "$days_a" ] && args="$args -a $days_a"
        [ -z "$args" ] && { warn "All files are up to date."; exit 0; }

        uls_fetch $args || die "fetch failed for ULS zips"

        local err=0 cnt=0
        for fn in *.zip; do
                cnt=$((cnt+1))
                mv "$fn" "$ZIPDIR/" || err=1
                mv "${fn%.*}.info" "$INFODIR/" || err=1
        done

        if [ $err -eq 0 ]; then
                warn "Success, updated $cnt zips from ULS"
                exit 0
        fi
        die "Error moving files. Check $ULSDIR"
}

cleanup() {
        cd "$SAVEDPWD" || warn "failed to restore dir"
        [ -d "$ULSDIR" ] && rm -rf "$ULSDIR"
}

parse_opts "$@"
main "$@"
