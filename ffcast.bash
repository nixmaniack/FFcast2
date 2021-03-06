#!/bin/bash
#
# FFcast @VERSION@
# Copyright (C) 2011  lolilolicon <lolilolicon@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

set -e +m -o pipefail
shopt -s extglob lastpipe

readonly progname=ffcast progver='@VERSION@'
readonly cast_cmd_pattern='@(ffmpeg|byzanz-record|recordmydesktop)'
declare -a head_ids=()
declare -- modulus=2 region_select_action=
declare -i borderless=1 print_geometry_only=0 use_format_string=0
declare -i verbosity=0

#---
# Functions

_msg() {
    local prefix=$1
    shift || return 0
    local fmt=$1
    shift || return 0
    printf '%s' "$prefix"
    printf -- "$fmt\n" "$@"
}

_quote_cmd_line() {
    local prefix=$1
    shift || return 0
    local cmd=$1
    shift || return 0
    printf '%s' "$prefix"
    printf '%q' "$cmd"
    (( $# )) && printf ' %q' "$@"
    printf '\n'
}

debug_dryrun() {
    (( verbosity >=2 )) || return 0
    _quote_cmd_line 'debug: command: ' "$@"
} >&2

debug_run() {
    debug_dryrun "$@" && "$@"
}

debug_pipestatus() {
    set -- "${PIPESTATUS[@]}"
    (( verbosity >=2 )) || return 0
    printf 'debug: pipestatus:'
    (( $# )) && printf ' %d' "$@"
    printf '\n'
} >&2

debug() {
    (( verbosity >= 2 )) || return 0
    _msg 'debug: ' "$@"
} >&2

verbose() {
    (( verbosity >= 1 )) || return 0
    _msg 'verbose: ' "$@"
} >&2

msg() {
    (( verbosity >= 0 )) || return 0
    _msg ':: ' "$@"
} >&2

warn() {
    (( verbosity >= -1 )) || return 0
    _msg 'warning: ' "$@"
} >&2

error() {
    (( verbosity >= -1 )) || return 0
    _msg 'error: ' "$@"
} >&2

format_to_string() {
    local fmt=$1 str c
    printf %s "$fmt" | {
    while IFS= read -r -n 1 -d '' c; do
        if [[ $c == '%' ]]; then
            IFS= read -r -n 1 -d '' c || :
            case $c in
                '%')
                    str+=%
                    ;;
                'd')
                    str+=$DISPLAY
                    ;;
                'h')
                    str+=$h
                    ;;
                'w')
                    str+=$w
                    ;;
                'x')
                    str+=$_x
                    ;;
                'y')
                    str+=$_y
                    ;;
                'X')
                    str+=$x_
                    ;;
                'Y')
                    str+=$y_
                    ;;
                *)
                    str+=%$c
                    ;;
            esac
        else
            str+=$c
        fi
    done
    printf %s "$str"; }
}

# $1: array variable to assign corners list to, i.e. =([id]=corners ...)
# $2: array variable of heads, e.g. =([0]=1440x900+0+124 [1]=1280x1024+1440+0)
# $3: array variable of head IDs, e.g. =(0 1 2)
# $4: array variable to assign bad head IDs to, e.g. =(2)
heads_get_corners_list_by_ref() {
    eval local heads=\(\"\$\{$2\[@\]\}\"\)
    eval local head_ids=\(\"\$\{$3\[@\]\}\"\)
    local i w h _x _y x_ y_
    for i in "${head_ids[@]}"; do
        if [[ -n ${heads[i]} ]]; then
            IFS='x+' read w h _x _y <<< "${heads[i]}"
            (( x_ = rootw - _x - w )) || :
            (( y_ = rooth - _y - h )) || :
            printf -v "$1[$i]" "%d,%d %d,%d" $_x $_y $x_ $y_
        else
            printf -v "$4[$i]" %d $i
        fi
    done
}

list_cast_cmds() {
    local -a cmds
    IFS='|' read -a cmds <<< "${cast_cmd_pattern:2: -1}"
    printf "%s\n" "${cmds[@]}"
}

parse_geospec_get_corners() {
    local geospec=$1
    local _x _y x_ y_ w h
    local n='?([-+])+([0-9])'
    local m='?(-)+([0-9])'
    local N='+([0-9])'
    # strip whitespaces
    IFS=$' \t' read -r geospec <<< "$geospec"
    case $geospec in
        $n,$n+([' \t'])$n,$n)  # x1,y1 x2,y2
            IFS=$', \t' read _x _y x_ y_ <<< "$geospec"
            ;;
        ${N}x${N}\+${m}\+${m})  # wxh+x+y
            IFS='x+' read w h _x _y <<< "$geospec"
            (( x_ = rootw - _x - w )) || :
            (( y_ = rooth - _y - h )) || :
            ;;
        *)
            error "invalid geometry specification: \`%s'" "$geospec"
            return 1
            ;;
    esac
    printf '%d,%d %d,%d\n' $_x $_y $x_ $y_
}

region_intersect_corners() {
    local corners
    local _x _y x_ y_
    local _X _Y X_ Y_
    # Initialize variable- otherwise bash will fallback to 0
    IFS=' ,' read _X _Y X_ Y_ <<< "$1"
    shift || return 1
    for corners in "$@"; do
        IFS=' ,' read _x _y x_ y_ <<< "$corners"
        (( _X = _x > _X ? _x : _X )) || :
        (( _Y = _y > _Y ? _y : _Y )) || :
        (( X_ = x_ > X_ ? x_ : X_ )) || :
        (( Y_ = y_ > Y_ ? y_ : Y_ )) || :
    done
    printf '%d,%d %d,%d\n' $_X $_Y $X_ $Y_
}

region_union_corners() {
    local corners
    local _x _y x_ y_
    local _X _Y X_ Y_
    # Initialize variable- otherwise bash will fallback to 0
    IFS=' ,' read _X _Y X_ Y_ <<< "$1"
    shift || return 1
    for corners in "$@"; do
        IFS=' ,' read _x _y x_ y_ <<< "$corners"
        (( _X = _x < _X ? _x : _X )) || :
        (( _Y = _y < _Y ? _y : _Y )) || :
        (( X_ = x_ < X_ ? x_ : X_ )) || :
        (( Y_ = y_ < Y_ ? y_ : Y_ )) || :
    done
    printf '%d,%d %d,%d\n' $_X $_Y $X_ $Y_
}

select_region_get_corners() {
    msg "%s" "please select a region using mouse"
    xrectsel_get_corners
}

select_window_get_corners() {
    msg "%s" "please click once in target window"
    LC_ALL=C xwininfo | xwininfo_get_corners
}

# stdin: xdpyinfo -ext XINERAMA (preferably sanitized)
# $1: array variable to assign heads to, i.e. =([id]=geometry ...)
xdpyinfo_get_heads_by_ref() {
    local line
    local i w h x y
    local n='+([0-9])'
    # See print_xinerama_info() in xdpyinfo.c
    local head="head #$n: ${n}x$n @ $n,$n"
    while IFS=' ' read -r line; do
        if [[ $line == $head ]]; then
            line=${line#head #}
            IFS=' :x@,' read i w h x y <<< "$line"
            printf -v "$1[$i]" "%dx%d+%d+%d" $w $h $x $y
        fi
    done
    [[ -n $i ]]
}

xdpyinfo_list_heads() {
    xdpyinfo -ext XINERAMA | grep '^  head #' | sed 's/^ *//'
}

# stdout: x1,y1 x2,y2
xrectsel_get_corners() {
    # Note: requires xrectsel 0.3
    xrectsel "%x,%y %X,%Y"$'\n'
}

# stdin: xwininfo output (locale: C)
# stdout: ${width}x${height}
xwininfo_get_dimensions() {
    local line
    local w h
    while IFS=$' \t' read -r line; do
        if [[ $line == 'Width: '+([0-9]) ]]; then
            w=${line#'Width: '}
        elif [[ $line == 'Height: '+([0-9]) ]]; then
            h=${line#'Height: '}
        else
            continue
        fi
        if (( w && h )); then
            printf '%dx%d\n' $w $h
            return
        fi
    done
    return 1
}

# stdin: xwininfo output (locale: C)
# stdout: x1,y1 x2,y2
xwininfo_get_corners() {
    local line
    local _x _y x_ y_ b
    local n='-?[0-9]+'
    local corners="^Corners: *\\+($n)\\+($n) *-$n\\+$n *-($n)-($n) *\\+$n-$n\$"
    # Note: explicitly set IFS to ensure stripping of whitespaces
    while IFS=$' \t' read -r line; do
        if [[ $line == 'Border width: '+([0-9]) ]]; then
            b=${line#'Border width: '}
        elif [[ $line =~ $corners ]]; then
            _x=${BASH_REMATCH[1]}
            _y=${BASH_REMATCH[2]}
            x_=${BASH_REMATCH[3]}
            y_=${BASH_REMATCH[4]}
        else
            continue
        fi
        [[ -n $_x ]] || continue
        if  (( ! borderless )); then
            :
        elif [[ -n $b ]]; then
            (( _x += b )) || :
            (( _y += b )) || :
            (( x_ += b )) || :
            (( y_ += b )) || :
        else
            continue
        fi
        printf '%d,%d %d,%d\n' $_x $_y $x_ $y_
        return
    done
    return 1
}

#---
# Process arguments passed to ffcast

usage() {
    cat <<EOF
$progname $progver
Usage:
  ${0##*/} [options] [<geospec>] % [command [args]]
  ${0##*/} [options] [<geospec>] [command [args] [--] [args]]

  Options:
    -s           select a rectangular region by mouse
    -w           select a window by mouse click
    -x <n|list>  select the Xinerama head of id n
    -b           include window borders hereafter
    -m <n>       trim region to be divisible by n
    -p           print region geometry only
    -l           list recognized screencast commands
    -q           be less verbose
    -v           be more verbose
    -h           print this help and exit

  If no region-selecting argument is passed, select fullscreen.
  All the options can be repeated, and are processed in order.
EOF
  exit $1
}

OPTIND=1
while getopts ':bhlm:pqsvwx:' opt; do
    case $opt in 
        h)
            usage 0
            ;;
        l)
            list_cast_cmds
            exit
            ;;
        m)
            if [[ $OPTARG == [1-9]*([0-9]) ]]; then
                modulus=$OPTARG
            else
                error "invalid modulus: \`%s'" "$OPTARG"
                exit 1
            fi
            ;;
        s)
            region_select_action+='s'
            ;;
        w)
            region_select_action+='w'
            ;;
        x)
            if [[ $OPTARG == 'list' ]]; then
                xdpyinfo_list_heads
                exit
            fi
            IFS=' ,' read -a _head_ids <<< "$OPTARG"
            for i in "${_head_ids[@]}"; do
                if [[ $i != +([0-9]) ]]; then
                    error "invalid head IDs: \'%s'" "$OPTARG"
                    exit 1
                fi
                (( i = 10#$i )) || :
                # Note: use i as key to discard duplicates
                head_ids[i]=$i
            done
            ;;
        b)
            region_select_action+='b'
            ;;
        p)
            print_geometry_only=1
            ;;
        q)
            (( verbosity-- )) || :
            ;;
        v)
            (( verbosity++ )) || :
            ;;
        '?')
            error "invalid option: \`%s'" "$OPTARG"
            exit 1
            ;;
        ':')
            error "option requires an argument: \`%s'" "$OPTARG"
            exit 1
            ;;
    esac
done
shift $(( OPTIND -1 ))

#---
# Process region geometry

declare rootw=0 rooth=0 _x=0 _y=0 x_=0 y_=0 w=0 h=0
if ! LC_ALL=C xwininfo -root | xwininfo_get_dimensions |
    IFS=x read rootw rooth; then
    debug_pipestatus
    error 'failed to get root window dimensions'
    exit 1
fi
# Note: this is safe because xwininfo_get_dimensions ensures that its output is
# either {int}x{int} or null, a random string like "rootw" is impossible.
if ! (( rootw && rooth )); then
    error 'invalid root window dimensions: %dx%d' "$rootw" "$rooth"
    exit 1
fi

declare -- i=0
declare -a corners_list=() heads=() head_ids_bad=()

if (( ${#head_ids[@]} )); then
    if ! xdpyinfo_list_heads | xdpyinfo_get_heads_by_ref heads; then
        error 'failed to get head list'
        exit 1
    fi
    debug '%s' "$(declare -p heads)"
    heads_get_corners_list_by_ref corners_list heads head_ids head_ids_bad
    debug '%s' "$(declare -p corners_list)"
    i=${#corners_list[@]}
    if (( ! i )); then
        error 'none of the specified head IDs exists'
        exit 1
    fi
    if (( ${#head_ids_bad[@]} )); then
        warn "ignored non-existent head ids: %s" "${head_ids_bad[*]}"
    fi
    corners_list=("${corners_list[@]}")  # indexing
fi

while (( $# )); do
    if [[ $1 == '%' ]]; then
        use_format_string=1
        shift
        break
    elif [[ $1 == $cast_cmd_pattern ]]; then
        break
    fi
    # The rest are geometry specifications
    corners_list[i++]=$(parse_geospec_get_corners "$1")
    debug "corners: %s" "${corners_list[-1]}"
    shift
done

printf %s "$region_select_action" |
while read -n 1; do
    case $REPLY in
        's')
            corners_list[i++]=$(select_region_get_corners)
            debug "corners: %s" "${corners_list[-1]}"
            ;;
        'w')
            corners_list[i++]=$(select_window_get_corners)
            debug "corners: %s" "${corners_list[-1]}"
            ;;
        'b')
            borderless=0
            verbose "windows: now including borders"
            ;;
    esac
done

if (( i )); then
    corners=$(region_union_corners "${corners_list[@]}")
    debug "corners union all selections: %s" "${corners}"
    corners=$(region_intersect_corners "$corners" "0,0 0,0")
    debug "corners rootwin intersection: %s" "${corners}"
    IFS=' ,' read _x _y x_ y_ <<< "$corners"
fi

if ! (( (w = rootw - _x - x_) > 0 )); then
    error 'region: invalid width: %d' "$w"
    exit 1
fi
if ! (( (h = rooth - _y - y_) > 0 )); then
    error 'region: invalid height: %d' "$h"
    exit 1
fi

if (( print_geometry_only )); then
    printf "%dx%d+%d+%d\n" $w $h $_x $_y
    exit
fi

#---
# Post-process region geometry

if (( modulus > 1 )); then
    w_old=$w
    h_old=$h

    if ! (( w = modulus * (w / modulus) )); then
        error 'region: width too small for modulus %d: %d' $modulus $w_old
        exit 1
    fi
    if ! (( h = modulus * (h / modulus) )); then
        error 'region: height too small for modulus %d: %d' $modulus $h_old
        exit 1
    fi

    if (( w < w_old )); then
        verbose 'region: trim width from %d to %d' $w_old $w
        (( x_ += w_old - w ))
    fi
    if (( h < h_old )); then
        verbose 'region: trim height from %d to %d' $h_old $h
        (( y_ += h_old - h ))
    fi
fi

#---
# Inject selection geometry into cast command line and execute

declare -- cast_cmd=$1
declare -a cast_args

if shift; then
    if (( use_format_string )); then
        while (( $# )); do
            cast_args+=("$(format_to_string "$1")")
            shift
        done
    else
        declare -a x11grab_opts
        case $cast_cmd in
            byzanz-record)
                x11grab_opts=(--x="$_x" --y="$_y" --width="$w" --height="$h" \
                    --display="$DISPLAY")
                ;;
            ffmpeg)
                x11grab_opts=(-f x11grab -s "${w}x$h" -i "$DISPLAY+$_x,$_y")
                ;;
            recordmydesktop)
                x11grab_opts=(-display "$DISPLAY" -width "$w" -height "$h")
                # As of recordMyDesktop 0.3.8.1, x- and y-offsets default to 0,
                # but -x and -y don't accept 0 as an argument. #FAIL
                (( _x )) && x11grab_opts+=(-x "$_x")
                (( _y )) && x11grab_opts+=(-y "$_y")
                ;;
            *)
                error "invalid cast command: \`%s'" "$cast_cmd"
                exit 1
                ;;
        esac

        while (( $# )) && [[ $1 != '--' ]]; do
            cast_args+=("$1")
            shift
        done
        if shift; then
            cast_args+=("${x11grab_opts[@]}" "$@")
        else
            cast_args=("${x11grab_opts[@]}" "${cast_args[@]}")
        fi
    fi
else
    cast_cmd=ffmpeg
    cast_args=(-r 25 -f x11grab -s "${w}x$h" -i "$DISPLAY+$_x,$_y" -vcodec
        libx264 "$(printf '%s-%(%Y%m%d-%H%M%S)T.mkv' "$progname" -1)")
fi

debug_run exec "$cast_cmd" "${cast_args[@]}"

# vim:ts=4:sw=4:et:cc=80:
