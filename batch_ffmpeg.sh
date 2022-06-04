#!/bin/bash

readonly TERM_WIDTH=$(tput cols)

# Prints a progress bar that extends the entire bottom row
# for example:
# 00:23:45 [=======================================>]  99%
display_progress_bar() {
    if (( percentage < 0 || percentage > 100 )); then
        return 1
    fi

    local bar_width=$(( TERM_WIDTH - 16 ))
    local percentage=$(printf "%3d" "$1")
    local equals_signs=$(( bar_width * percentage / 100 ))
    local spaces=$(( bar_width - equals_signs - 1 ))

    if (( ${BASH_VERSION::1} >= 5 )); then
        elapsed_seconds=$(( EPOCHSECONDS - start ))
    else
        elapsed_seconds=$(( $(date +%s) - start ))
    fi
    elapsed_time=$(seconds_to_HMS_colons "$elapsed_seconds")

    # Build the progress bar piece by piece
    local progress_bar="$elapsed_time ["
    (( equals_signs > 0 )) && progress_bar+=$(printf "=%.0s" $(seq "$equals_signs"))
    (( equals_signs < bar_width )) && progress_bar+=">"
    (( spaces > 0 )) && progress_bar+=$(printf " %.0s" $(seq "$spaces"))
    progress_bar+="] $percentage%"

    echo -en "$progress_bar\r"
}

# Calculates and shows the progress of the encoding job in seconds
calculate_progress() {
    local progressline=$(tail -n 1 "$ffmpeg_progress" 2>/dev/null | awk -F '\r' '{ print $(NF - 1) }')
    if [[ "$progressline" ]]; then
        local progress=$(grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}" <<< "$progressline")
        local progress_s=$(awk -F ':' '{ print $1 * 3600 + $2 * 60 + $3 }' <<< "$progress")
        echo "$progress_s"
        return 0
    fi
    return 1
}

# Actions to take when the program exits
exit_hook() {
    rm -f "$ffmpeg_progress"
    if [[ "$ffmpeg_exit_status" != 0 ]] && "$rm_partial"; then
        rm -f "$outputfile"
    fi
}

# Converts string in form of 'HH h MM min SS s' to seconds
HMS_to_seconds() {
    local duration=$1

    local hours=$(grep -Eo "[0-9]+ h" <<< "$duration" | sed 's/ h//g')
    local minutes=$(grep -Eo "[0-9]+ min" <<< "$duration" | sed 's/ min//g')
    local seconds=$(grep -Eo "[0-9]+ s" <<< "$duration" | sed 's/ s//g')

    echo "$(( hours*60**2 + minutes*60 + seconds ))"
}

# Converts seconds to string in form of HH:MM:SS
seconds_to_HMS_colons() {
    local tally_seconds=$1
    local hours=$(( tally_seconds / 60 ** 2 ))
    tally_seconds=$(( tally_seconds % 60 ** 2 ))
    local minutes=$(( tally_seconds / 60 ))
    local seconds=$(( tally_seconds % 60 ))

    printf "%02d:%02d:%02d\n" "$hours" "$minutes" "$seconds"
}

# Converts seconds to string in form of 'HH hours, MM minutes, SS seconds'
seconds_to_HMS_sentence() {
    local HMS=$(seconds_to_HMS_colons "$1")

    IFS=':' read -r hours minutes seconds <<< "$HMS"; unset IFS
    (( hours == 0 )) && unset "hours"
    (( minutes == 0 )) && unset "minutes"

    echo "${hours:+#$hours hours, }${minutes:+#$minutes minutes, }${seconds:+#$seconds seconds}" |
        sed -re 's/, $//' -e 's/#(1 [a-z]+)s/#\1/g' -e 's/#//g'
}

# Wrapper function to run ffmpeg asynchronously
ffmpeg_wrapper() {
    # Windows' ffmpeg.exe is much faster on WSL than the Linux binary
    # I have no idea why
    ffmpeg.exe "$@" >/dev/null 2>"$ffmpeg_progress" &
    wait "$!"
}

usage() {
    cat <<EOF | less

$0 [OPTIONS]

Options:
    --help, -h              display this help text

    --input, -i             specify input files or directories (multiple -i flags allowed)
                            default: $HOME/transcoding/source

    --output, -o            specify output directory
                            default: Same directory as each input file, with "source"
                                     replaced with "sink"

    --format,-f             specify file format MP4 or MKV

    --vcodec                select a codec to encode the video stream with
                            options: x264, x265
                            default: x265

    --acodec                select a codec to encode the audio stream with
                            options: copy, aac, flac
                            default: copy

    --crf, -c               set x264 or x265 constant rate factor
                            range: [0 - 51]
                            default: 24

    --preset, -p            set x264 or x265 preset
                            default: medium

    --hdr_sdr_convert       convert HDR source video to SDR

    --hwaccel               use NVENC hardware acceleration
                            default: off

    --nocopysubs            do not copy subtitles from source file
                            default: copy

    --resume_on_failure     exit on failure instead of continuing with the queue

    --deletesource          delete the source file on successful encode
                            default: keep

    --overwrite,-w          overwrite previous encodes
                            default: don't clobber

    --keep-partial,-r       keep partial encodes
                            default: remove

    --plex-defaults,--plex  set reasonable defaults for Plex Media Server
                            h265, CRF 22, preset slow, copy subtitles

    --ps5-defaults,--ps5    set reasonable defaults for PS5 videos
                            h264, AAC, CRF 24, preset slow, tone mapping

    --update-interval,-n    time in seconds (decimal allowed) between updates of the progress bar.
                            default: 1

    --no-progress-bar       disable the progress bar

    --draw-thumbnails       draw thumbnails as the encode progresses

EOF
    exit 1
}

print_size() {
    awk '
        function human(x) {
            if (x < 1000) {
                return x
            } else {
                x/=1024
            }
            s="kMGTP"
            while (x >= 1000 && length(s) > 1) {
                x/=1024
                s=substr(s,2)
            }
            return sprintf("%.2f",x) substr(s,1,1)
        }
        {
            print human($0)
        }
    '
}

print_result() {
    local duration
    if (( ${BASH_VERSION::1} >= 5 )); then
        duration=$(( EPOCHSECONDS - start ))
    else
        duration=$(( $(date +%s) - start ))
    fi

    # Since the encoding has stopped, kill the asynchronous processes updating the progress bar
    for i in "${!bg_pids[@]}"; do
        pid=${bg_pids[$i]}
        if kill -0 "$pid"; then
            kill "$pid"
        fi
    done &>/dev/null
    unset "bg_pids"
    rm -f ~/encode_thumbnail.png

    # Successful encode
    if [[ "$ffmpeg_exit_status" == 0 && -s "$outputfile" ]]; then
        display_progress_bar 100
        echo
        echo "Encoding finished successfully in $(seconds_to_HMS_sentence "$duration") at $(date "+%I:%M:%S %p")"
        input_size=$(stat -c '%s' "$video_file")
        output_size=$(stat -c '%s' "$outputfile")
        cr=$(awk -v i="$input_size" -v o="$output_size" 'BEGIN { printf "%.2f",i/o }')
        echo "Input size: $(print_size <<< "$input_size")"
        echo "Output size: $(print_size <<< "$output_size")"
        echo "Compression ratio: $cr"
        if (( $(awk -v cr="$cr" 'BEGIN { print cr <= 1 }') )); then
            echo "Warning!: Low compression ratio!"
            echo "Check settings!"
        fi
        echo
        if "$deletesource"; then
            rm -f "$video_file"
        fi
    # Failed or canceled encode
    else
        echo
        echo "Error: encode failed or canceled after $(seconds_to_HMS_sentence "$duration") at $(date "+%I:%M:%S %p")"
        echo "The reason given was:"
        echo
        tail -n 10 "$ffmpeg_progress"
        echo
        touch "$outputfile.failed_encode"
        if "$rm_partial"; then
            rm "$outputfile"
        fi
        if ! "$resume_on_failure"; then
            exit 1
        fi
    fi
}

draw_thumbnail() {
    if progress=$(calculate_progress); then
        thumbnail="$HOME/encode_thumbnail.png"
        w_thumbnail="$(wslpath -w "$HOME")\\encode_thumbnail.png"
        ffmpeg.exe -nostdin -ss "$progress" -i "$w_video_file" -vframes 1 -an "$w_thumbnail" &>/dev/null
        ascii-image-converter -Cc "$thumbnail"
        rm -f "$thumbnail"
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
rm_partial=true
hwaccel=false
resume_on_failure=false
show_progress_bar=true
draw_thumbnails=false

# Parse user-provided options
shopt -s nocasematch
while (( $# )); do
    flag=$1
    shift
    case "$flag" in
        --help|-h)
            usage ;;
        --input|-i)
            input+=( "$1" )
            shift
            ;;
        --output|-o)
            user_outputdir="$1"
            shift
            ;;
        --vcodec)
            video_codec="$1"
            shift
            ;;
        --plex-defaults|--plex)
            crf=22
            preset=slow
            copysubs=true
            video_codec=x265
            ;;
        --ps5-defaults|--ps5)
            crf=22
            preset=slow
            file_format=mp4
            video_codec=x264
            audio_codec=aac
            hdr_sdr_convert=true
            ;;
        --acodec)
            audio_codec="$1"
            shift
            ;;
        --format|-f)
            file_format=$1
            shift
            ;;
        --crf|-c)
            crf=$(sed 's/[^0-9]//g' <<< "$1")
            shift
            ;;
        --preset|-p)
            preset="$1"
            shift
            ;;
        --update-interval|-n)
            update_interval=$(sed 's/[^0-9\.]//g' <<< "$1")
            shift
            ;;
        --nocopysubs)
            copysubs=false ;;
        --deletesource)
            deletesource=true ;;
        --overwrite|-w)
            overwrite=true ;;
        --keep-partial|-k)
            rm_partial=false ;;
        --hdr_sdr_convert)
            hdr_sdr_convert=true ;;
        --resume_on_failure)
            resume_on_failure=true ;;
        --hwaccel)
            hwaccel=true
            hwaccel_flags="-hwaccel cuda -hwaccel_output_format cuda"
            ;;
        --no-progress-bar)
            show_progress_bar=false ;;
        --draw-thumbnails)
            draw_thumbnails=true ;;
        *)
            echo "Error: unrecognized flag '$flag'"
            exit 1
            ;;
    esac
done
shopt -u nocasematch

if (( ${#input[@]} == 0 )); then
    input=( "$HOME/transcoding/source" )
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
    echo -n "Warning: CRF given is out of range [0 - 51]. Setting to closest value: "
    if (( crf < 0 )); then
        echo "0"
        crf=0
    else
        echo "51"
        crf=51
    fi
fi

# Force MKV unless user explicitly specifies MP4
case "${file_format,,}" in
    *mp4*)
        file_format=mp4 ;;
    *)
        file_format=mkv ;;
esac

# Select appropriate ffmpeg codecs based upon user selections of h264/h265 and NVENC hardware acceleration
if "$hwaccel"; then
    case "${video_codec,,}" in
        *264*|*avc*)
            video_codec=h264_nvenc
            profile=main
            ;;
        *)
            video_codec=hevc_nvenc
            profile=main10
            ;;
    esac
else
    case "${video_codec,,}" in
        *264*|*avc*)
            video_codec=libx264
            profile=main
            pix_fmt=yuv420p
            ;;
        *)
            video_codec=libx265
            profile=main10
            pix_fmt=yuv420p10le
            ;;
    esac
fi

case "${audio_codec,,}" in
    *flac*)
        audio_codec=flac ;;
    *aac*)
        audio_codec=aac ;;
    *)
        audio_codec=copy ;;
esac

preset="${preset:-medium}"
if "$hwaccel"; then
    case "${preset,,}" in
        *fast*)
            preset=fast ;;
        *slow*)
            preset=slow ;;
        *)
            preset=medium ;;
    esac
else
    case "${preset,,}" in
        ultrafast)
            preset=${preset,,} ;;
        superfast)
            preset=${preset,,} ;;
        veryfast)
            preset=${preset,,} ;;
        faster)
            preset=${preset,,} ;;
        fast)
            preset=${preset,,} ;;
        slow)
            preset=${preset,,} ;;
        slower)
            preset=${preset,,} ;;
        veryslow)
            preset=${preset,,} ;;
        placebo)
            preset=${preset,,} ;;
        *)
            preset=medium ;;
    esac
fi

if [[ "$hdr_sdr_convert" ]]; then
    video_filter="zscale=transfer=linear,tonemap=hable,zscale=transfer=bt709,format=$pix_fmt"
fi

update_interval=${update_interval:-1}
if (( $(echo "$update_interval < 0.1" | bc -l) )); then
    update_interval=0.1
fi

echo "File format: ${file_format^^}"

echo "Codec: $video_codec"

echo -n "CRF: "
if grep -q "nvenc" <<< "$video_codec"; then
    echo "n/a (nvenc)"
else
    echo "$crf"
fi
echo "Preset: $preset"

if "$copysubs"; then
    stream_codecs=( -c:a "$audio_codec" -c:s copy )
    mapping=( -map 0 )
    echo "Will copy subtitles"
else
    stream_codecs=( -c:a "$audio_codec" )
    mapping=( -map 0:v -map 0:a )
    echo "Will not copy subtitles"
fi

if "$overwrite"; then
    echo "Will overwrite previous encodes"
    overwrite_flag='-y'
else
    echo "Will not overwrite previous encodes"
fi

if "$deletesource"; then
    echo "Will delete the source file on a successful encode."
else
    echo "Will keep the source file on a successful encode."
fi

if "$rm_partial"; then
    echo "Will remove partially completed encodes."
else
    echo "Will keep partially completed encodes."
fi

if [[ "$hdr_sdr_convert" ]]; then
    echo "Will perform HDR->SDR color conversion"
fi

echo
read -rsp "Press enter to continue."
echo

# Generate the array of video files
mapfile -t video_files < <(find "${input[@]}" -type f -iregex '.*\.\(mp4\|mkv\|webm\|avi\|mov\|wmv\|mpe?g\)$' | sort)

total_size=$(du -bch "${video_files[@]}" | tail -n 1 | awk '{ print $1 }')

echo "Encoding ${#video_files[@]} videos totaling $total_size in ${input[*]}"

trap exit_hook EXIT

ffmpeg_progress=$(mktemp)
cancel_queue=false

# Loop over every file in the directories provided by the user
for video_file in "${video_files[@]}"; do
    "$cancel_queue" && exit 1
    trap - INT
    declare -a bg_pids
    echo
    source_duration=$(mediainfo "$video_file" | awk -F ' +: +' '/^Duration/ { print $2 }' | head -n 1)
    source_duration_s=$(HMS_to_seconds "$source_duration")
    videoname=$(basename "$video_file")
    videopath=$(dirname "$video_file")
    if [[ "$user_outputdir" ]]; then
        outputdir="$user_outputdir"
    else
        outputdir=${videopath//source/sink}
    fi
    mkdir -p "$outputdir"
    find "$outputdir" -name "*.failed_encode" -delete
    output_videoname=$(sed "s/\\..*$/\\.$file_format/" <<< "$videoname")
    outputfile="$outputdir/$output_videoname"
    if [[ "$outputfile" == "$video_file" ]]; then
        echo "Warning: output and input file are the same!"
        echo "Cannot encode $videoname onto itself!"
        echo
        continue
    fi
    if [[ -f "$outputfile" ]] && ! "$overwrite"; then
        echo "Warning: Output file $(basename "$outputfile") exists but overwrite flag was not given."
        echo
        continue
    fi
    w_outputfile="$(wslpath -w "$outputdir")\\$output_videoname"
    w_video_file=$(wslpath -w "$video_file")
    if (( "${BASH_VERSION::1}" >= 5 )); then
        start=$EPOCHSECONDS
    else
        start=$(date +%s)
    fi


    ffmpeg_opts=(
        -nostdin
        $overwrite_flag
        $hwaccel_flags
        -i "$w_video_file"
        ${video_codec:+-c:v "$video_codec"}
        ${profile:+-profile:v "$profile"}
        ${crf:+-crf "$crf"}
        ${preset:+-preset "$preset"}
        ${pix_fmt:+-pix_fmt "$pix_fmt"}
        ${video_filter:+-vf "$video_filter"}
        "${stream_codecs[@]}"
        "${mapping[@]}"
        "$w_outputfile"
    )
    ffmpeg_wrapper "${ffmpeg_opts[@]}" &


    ffmpeg_pid=$!
    echo "Encoding $videoname"
    if "$show_progress_bar"; then
        while true; do
            kill -0 "$ffmpeg_pid" &>/dev/null || break
            if progress=$(calculate_progress); then
                pct_progress=$(( 100 * progress / source_duration_s ))
                display_progress_bar "$pct_progress"
            fi
            sleep "$update_interval"
        done &
        bg_pids+=( "$!" )
    fi
    if "$draw_thumbnails"; then
        while true; do
            kill -0 "$ffmpeg_pid" &>/dev/null || break
            draw_thumbnail
        done &
        bg_pids+=( "$!" )
    fi
    echo "Press q to cancel the queue"
    while kill -0 "$ffmpeg_pid" &>/dev/null; do
        if read -rsn 1 -t 0.2 letter < /dev/tty && [[ "${letter,,}" == q ]]; then
            echo "The queue has been cancelled. Encode of $videoname will finish."
            echo "Ctrl-C to kill the encode."
            cancel_queue=true
            break
        fi
    done
    wait "$ffmpeg_pid"
    ffmpeg_exit_status=$?
    print_result
done
