#!/bin/bash

set -eo pipefail

# Clears the current row of text
blank_row() {
    local blank_string=''
    local blanks=$(tput cols)
    blank_string=$(printf " %.0s" $(seq "$blanks") )
    echo -en "$blank_string\r"
}

# Prints a progress bar that extends the entire bottom row
# for example:
# 00:23:45 [=======================================>]  99%
progress_bar() {
    trap 'exit' TERM

    if (( percentage < 0 || percentage > 100 )); then
        return 1
    fi

    local width=$(tput cols)
    local cols=$(( width - 16 ))
    local percentage=$(printf "%3d" "$1")
    local equals=$(( cols * percentage / 100 ))
    local blanks=$(( cols - equals - 1 ))

    elapsed_time=$(date -d@$(( $(date +%s) - start )) -u '+%H:%M:%S')

    local progress_bar="$elapsed_time ["
    (( equals > 0 )) && progress_bar+=$(printf "=%.0s" $(seq "$equals"))
    (( equals < cols )) && progress_bar+=">"
    (( blanks > 0 )) && progress_bar+=$(printf " %.0s" $(seq "$blanks"))
    progress_bar+="] $percentage%"

    echo -en "$progress_bar\r"
}

# Calculates and shows the progress of the encoding job
show_progress() {
    progressline=$(tail -n 1 "$ffmpeg_progress" 2>/dev/null | awk -F '\r' '{ print $(NF - 1) }')
    if [[ "$progressline" ]]; then
        progress=$(grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}" <<< "$progressline")
        progress_s=$(awk -F ':' '{ print $1 * 3600 + $2 * 60 + $3 }' <<< "$progress")
        percentage=$(( 100 * progress_s / source_duration_s ))
        progress_bar "$percentage"
    fi
}

# Waits for a background process to finish, but only until a specified timeout
timeout_wait() {
    local timeout=$1
    local pid=$2

    local sleep_start=$(date +%s)
    while sleep 1; do
        elapsed=$(( $(date +%s) - sleep_start ))
        if ! kill -0 "$pid" || (( elapsed >= timeout )); then
            break
        fi
    done
}

# Actions to take when the program exits
exit_hook() {
    rm -f "$ffmpeg_progress"
    (
        if kill -0 "$ffmpeg_pid"; then
            kill "$ffmpeg_pid"

            # Allow ffmpeg 10 seconds to clean up
            timeout_wait 10 "$ffmpeg_pid"

            if kill -0 "$ffmpeg_pid"; then
                kill -9 "$ffmpeg_pid"
            fi
        fi &>/dev/null
        if [[ "$ffmpeg_exit_status" != 0 ]] && "$rm_partial"; then
            rm -f "$outputfile"
        fi
    ) &>/dev/null &
}

# Actions to take on interrupt (Ctrl+C)
int_hook() {
    echo -e "\n$videoname will finish encoding and the program will exit."
    echo "Ctrl-C again to kill the encoding."
    while sleep 0.5; do
        kill -0 "$ffmpeg_pid" &>/dev/null || break
        show_progress &
        bg_pids+=( "$!" )
    done

    if ! kill -0 "$ffmpeg_pid" &>/dev/null; then
        wait "$ffmpeg_pid"
        ffmpeg_exit_status=$?
    fi

    print_result
    exit 1
}

# Converts string in form of 'HH h MM min SS s' to seconds
HMS_to_seconds() {
    local duration=$1

    local hours=$(grep -Eo "[0-9]+ h" <<< "$duration" | sed 's/ h//g')
    local minutes=$(grep -Eo "[0-9]+ min" <<< "$duration" | sed 's/ min//g')
    local seconds=$(grep -Eo "[0-9]+ s" <<< "$duration" | sed 's/ s//g')

    echo "$(( hours*60**2 + minutes*60 + seconds ))"
}

# Converts seconds to string in form of 'HH hours, MM minutes, SS seconds'
seconds_to_HMS() {
    local tally_seconds=$1

    local hours=$(( tally_seconds / 60 ** 2 ))
    tally_seconds=$(( tally_seconds - ${hours:-0} * 60 ** 2 ))
    local minutes=$(( tally_seconds / 60 ))
    tally_seconds=$(( tally_seconds - ${minutes:-0} * 60 ))
    local seconds=$tally_seconds

    [[ "$hours" == 0 ]] && unset "hours"
    [[ "$minutes" == 0 ]] && unset "minutes"

    echo "${hours:+#$hours hours, }${minutes:+#$minutes minutes, }${seconds:+#$seconds seconds}" |
        sed -re 's/, $//' -e 's/#(1 [a-z]+)s/#\1/g' -e 's/#//g'
}

# Wrapper function to run ffmpeg asynchronously
ffmpeg_wrapper() {
    trap '' INT
    trap 'kill "$!" &>/dev/null' TERM

    # Windows ffmpeg.exe is more performant than WSL's version
    /mnt/d/Programs/bin/ffmpeg.exe "$@" >/dev/null 2>"$ffmpeg_progress" & wait
}

usage() {
    cat <<EOF | less

$0 [OPTIONS]

Options:
    --help, -h          display this help text

    --input, -i         specify input files or directories (multiple -i flags allowed)
                        default: /mnt/e/transcoding/source

    --output, -o        specify output directory
                        default: Same as input, with source replaced with sink

    --file-format,-f    specify file format MP4 or MKV

    --codec             select a codec to encode the video stream with
                        options: x264, x265
                        default: x265

    --crf, -c           set x264 or x265 constant rate factor
                        range: [0 - 51]
                        default: 24

    --preset, -p        set x264 or x265 preset
                        default: medium

    --hwaccel           use NVENC hardware acceleration
                        default: off

    --nocopysubs        do not copy subtitles from source file
                        default: copy

    --deletesource      delete the source file on successful encode
                        default: keep

    --overwrite,-w      overwrite previous encodes
                        default: don't clobber

    --rm-partial,-r     remove partial encodes
                        default: keep

    --ps5               convert videos from Playstation 5 (overwrites file-format, crf, preset, and codec)

EOF
    exit 1
}

print_result() {
    for i in "${!bg_pids[@]}"; do
        pid=${bg_pids[$i]}
        if kill -0 "$pid"; then
            kill "$pid"
        fi
    done &>/dev/null
    unset "bg_pids"
    local duration=$(( $(date +%s) - start ))
    if [[ "$ffmpeg_exit_status" == 0 ]]; then
        progress_bar 100
        echo
        echo "Encoding finished in $(seconds_to_HMS "$duration") at $(date "+%I:%M:%S %p")"
        if "$deletesource"; then
            rm "$videofile"
        fi
    else
        trap '' INT
        echo
        echo "Error: encode failed after $(seconds_to_HMS "$duration") at $(date "+%I:%M:%S %p")"
        touch "$outputfile.failed"
        exit 1
    fi
}

user=$(whoami)
if [[ "$user" == root ]]; then
    echo "You must run this job as a regular user."
    exit 1
fi

# Set defaults
copysubs=true
deletesource=false
overwrite=false
rm_partial=false
hwaccel=false

shopt -s nocasematch
while (( $# )); do
    flag=$1
    shift
    case "$flag" in
        --help|-h)          usage ;;
        --input|-i)         input+=( "$1" )
                            shift
                            ;;
        --output|-o)        user_outputdir="$1"
                            shift
                            ;;
        --codec)            codec="$1"
                            shift
                            ;;
        --mydefaults)       crf=24
                            preset=medium
                            copysubs=true
                            deletesource=true
                            overwrite=true
                            ;;
        --crf|-c)           crf=$(sed 's/[^0-9]//g' <<< "$1")
                            shift
                            ;;
        --preset|-p)        preset="$1"
                            shift
                            ;;
        --nocopysubs)       copysubs=false ;;
        --deletesource)     deletesource=true ;;
        --overwrite|-w)     overwrite=true ;;
        --rm-partial|-r)    rm_partial=true ;;
        --ps5)              ps5=true ;;
        --hwaccel)          hwaccel=true ;;
        *)                  echo "Error: unrecognized flag '$flag'"
                            exit 1
                            ;;
    esac
done
shopt -u nocasematch

if (( ${#input[@]} == 0 )); then
    input=( '/mnt/e/transcoding/source' )
fi

for filepath in "${input[@]}"; do
    if ! [[ -r "$filepath" && -w "$filepath" ]]; then
        echo "You must choose a path that we can read and write to."
        echo "Path given: '$filepath'"
        echo "ownership and permissions: $(stat -c '%U:%G %A' "$filepath")"
        exit 1
    fi
done

crf=$(sed 's/[^0-9]//g' <<< "${crf:-24}")

if (( crf < 0 || crf > 51 )); then
    echo "Error: CRF given is out of range [0 - 51]. Setting to closest value."
    (( crf < 0 )) && crf=0
    (( crf > 51 )) && crf=51
fi

if "$hwaccel"; then
    case "${codec,,}" in
        *264*|avc)   codec=h264_nvenc ;;
        *265*|hevc)  codec=h265_nvenc ;;
    esac
else
    case "${codec,,}" in
        *264*|avc)   codec=libx264 ;;
        *265*|hevc)  codec=libx265 ;;
    esac
fi

preset="${preset:-medium}"
if grep -q "nvenc" <<< "$codec"; then
    case "${preset,,}" in
        *fast*) preset=fast ;;
        medium) preset=medium ;;
        slow)   preset=slow ;;
        *)      preset=medium ;;
    esac
else
    case "${preset,,}" in
        ultrafast)  preset=${preset,,} ;;
        superfast)  preset=${preset,,} ;;
        veryfast)   preset=${preset,,} ;;
        faster)     preset=${preset,,} ;;
        fast)       preset=${preset,,} ;;
        medium)     preset=${preset,,} ;;
        slow)       preset=${preset,,} ;;
        slower)     preset=${preset,,} ;;
        veryslow)   preset=${preset,,} ;;
        placebo)    preset=${preset,,} ;;
        *)          preset=medium ;;
    esac
fi

if [[ -z "$ps5" ]]; then
    echo "Codec: $codec"

    echo -n "CRF: "
    if grep -q "nvenc" <<< "$codec"; then
        echo "n/a (nvenc)"
    else
        echo "$crf"
    fi
    echo "Preset: $preset"
fi

if "$copysubs"; then
    copy_codecs=( -c:a copy -c:s copy )
    mapping=( -map 0 )
    echo "Will copy subtitles"
else
    copy_codecs=( -c:a copy )
    mapping=( -map 0:v -map 0:a )
    echo "Will not copy subtitles"
fi


if "$overwrite"; then
    overwrite='-y'
    echo "Will overwrite previous encodes"
else
    unset overwrite
    echo "Will not overwrite previous encodes"
fi

if "$deletesource"; then
    echo "Will delete the source file on a successful encode."
else
    echo "Will not delete the source file."
fi

read -rsp "Press enter to continue."
echo

num_files=$(find "${input[@]}" -type f -name "*.mkv" -or -name "*.mp4" -or -name "*.webm" | wc -l)
total_size=$(du -bch "${input[@]}" | tail -n 1 | awk '{ print $1 }')

echo "Encoding $num_files videos totaling $total_size in ${input[*]}"

trap exit_hook EXIT
trap int_hook INT

ffmpeg_progress=$(mktemp)

while read -r videofile; do
    declare -a bg_pids
    echo
    source_duration=$(mediainfo "$videofile" | awk -F ' +: +' '/^Duration/ { print $2 }' | head -n 1)
    source_duration_s=$(HMS_to_seconds "$source_duration")
    video_extension=$(awk -F '.' '{ print $NF }' <<< "$videofile")
    videoname=$(basename "$videofile")
    videopath=$(dirname "$videofile")
    outputdir=${outputdir:-${videopath//source/sink}}
    if [[ "$user_outputdir" ]]; then
        outputdir="$user_outputdir"
    else
        outputdir=${outputdir:-${videopath//source/sink}}
    fi
    mkdir -p "$outputdir"
    find "$outputdir" -name "*.failed" -delete
    outputfile="$outputdir/$(sed "s/$video_extension$/mkv/" <<< "$videoname")"
    if [[ "$outputfile" == "$videofile" ]]; then
        echo "Error: Cannot encode file onto itself."
        exit 1
    fi
    w_videofile=$(wslpath -w "$videofile")
    w_outputdir=$(wslpath -w "$outputdir")
    w_output="$w_outputdir\\$(sed "s/$video_extension$/mkv/" <<< "$videoname")"
    start=$(date +%s)
    if [[ "$ps5" ]]; then
        ffmpeg_wrapper \
            -nostdin \
            $overwrite \
            -i "$w_videofile" \
            -c:v libx264 \
            -preset medium \
            -crf 24 \
            -vf 'zscale=transfer=linear,tonemap=hable,zscale=transfer=bt709,format=yuv420p' \
            -c:a aac \
            -map 0 \
            "$(sed 's/mkv$/mp4/' <<< "$w_output")" &
    else
        ffmpeg_wrapper \
            -nostdin \
            $overwrite \
            -i "$w_videofile" \
            -c:v "$codec" \
            -profile:v main10 \
            -pix_fmt yuv420p10le \
            ${crf:+-crf "$crf"} \
            -preset "$preset" \
            "${copy_codecs[@]}" \
            "${mapping[@]}" \
            "$w_output" &
    fi
    ffmpeg_pid=$!
    echo "Encoding $videoname"
    while sleep 0.5; do
        kill -0 "$ffmpeg_pid" &>/dev/null || break
        show_progress &
        bg_pids+=( "$!" )
    done
    wait "$ffmpeg_pid"
    ffmpeg_exit_status=$?
    print_result
done < <(find "${input[@]}" -type f -iregex ".*\.\(mp4\|mkv\|webm\|avi\|mov\|wmv\|mpe?g\)$" | sort)
