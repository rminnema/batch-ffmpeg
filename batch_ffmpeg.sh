#!/bin/bash

# Clears the current row of text
blank_row() {
    local blank_string=''

    # Get the width of the terminal window
    local spaces=$(tput cols)

    # This fancy printf construct will print $spaces number of spaces
    blank_string=$(printf " %.0s" $(seq "$spaces") )
    echo -en "$blank_string\r"
}

# Prints a progress bar that extends the entire bottom row
# for example:
# 00:23:45 [=======================================>]  99%
display_progress_bar() {
    if (( percentage < 0 || percentage > 100 )); then
        return 1
    fi

    # Get the width of the terminal window
    local window_width=$(tput cols)
    local bar_width=$(( window_width - 16 ))
    local percentage=$(printf "%3d" "$1")
    local equals_signs=$(( bar_width * percentage / 100 ))
    local spaces=$(( bar_width - equals_signs - 1 ))

    elapsed_seconds=$(( $(date +%s) - start ))
    elapsed_time=$(date -d "@$elapsed_seconds" -u '+%H:%M:%S')

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

# Waits for a background process to finish, but only until a specified timeout
timeout_wait() {
    local timeout=$1
    local pid=$2

    local wait_start=$(date +%s)
    while true; do
        local wait_elapsed=$(( $(date +%s) - wait_start ))
        if ! kill -0 "$pid" || (( wait_elapsed >= timeout )); then
            break
        fi
        sleep 1
    done
}

# Actions to take when the program exits
exit_hook() {
    # This bit runs asynchronously (note the last &) so that the terminal window is returned to the user
    (
        rm -f "$ffmpeg_progress"
        if kill -0 "$ffmpeg_pid"; then
            kill "$ffmpeg_pid"

            # Allow ffmpeg 10 seconds to clean up
            timeout_wait 10 "$ffmpeg_pid"

            if kill -0 "$ffmpeg_pid"; then
                kill -9 "$ffmpeg_pid"
            fi
        fi
        if [[ "$ffmpeg_exit_status" != 0 ]] && "$rm_partial"; then
            rm -f "$outputfile"
        fi
    ) &>/dev/null &
}

# Actions to take on interrupt (Ctrl+C)
int_hook() {
    echo -e "\n$videoname will finish encoding and the program will exit."
    echo "Ctrl-C again to kill the encoding."

    # Every $update_interval seconds, check if the ffmpeg process is finished
    # and asynchronously update the progress bar
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

    # Simultaneously, every second, check that the ffmpeg progress is done.
    while sleep 1; do
        kill -0 "$ffmpeg_pid" &>/dev/null || break
    done &
    wait "$!"

    # If the process is gone, get its exit status.
    # Otherwise we don't want to call wait otherwise it will actually wait
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
    tally_seconds=$(( tally_seconds - hours * 60 ** 2 ))
    local minutes=$(( tally_seconds / 60 ))
    tally_seconds=$(( tally_seconds - minutes * 60 ))
    local seconds=$tally_seconds

    (( hours == 0 )) && unset "hours"
    (( minutes == 0 )) && unset "minutes"

    echo "${hours:+#$hours hours, }${minutes:+#$minutes minutes, }${seconds:+#$seconds seconds}" |
        sed -re 's/, $//' -e 's/#(1 [a-z]+)s/#\1/g' -e 's/#//g'
}

# Wrapper function to run ffmpeg asynchronously
ffmpeg_wrapper() {
    # Don't respond to SIGINT, but send pass SIGTERM to ffmpeg
    trap '' INT
    trap 'kill "$!" &>/dev/null' TERM

    # Performance is better on WSL1 with the Windows ffmpeg.exe than on WSL1 or WSL2 with ffmpeg on Linux native
    # No idea why
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
    local duration=$(( $(date +%s) - start ))

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
        echo "Encoding finished successfully in $(seconds_to_HMS "$duration") at $(date "+%I:%M:%S %p")"
        input_size=$(stat -c '%s' "$video_file")
        output_size=$(stat -c '%s' "$outputfile")
        cr=$(awk -v i="$input_size" -v o="$output_size" 'BEGIN { printf "%.2f",i/o }')
        echo "Input size: $(print_size <<< "$input_size")"
        echo "Output size: $(print_size <<< "$output_size")"
        echo "Compression ratio: $cr"
        if (( $(awk -v cr="$cr" 'BEGIN { print cr <= 1 }') )); then
            echo "Error: Low compression ratio!"
            echo "Check settings!"
            exit 1
        elif (( $(awk -v cr="$cr" 'BEGIN { print cr > 10 }') )); then
            echo "Error: Highly implausible compression ratio!"
            echo "Check settings/code!"
            exit 1
        fi
        echo
        if "$deletesource"; then
            rm -f "$video_file"
        fi
    # Failed or canceled encode
    else
        echo
        echo "Error: encode failed or canceled after $(seconds_to_HMS "$duration") at $(date "+%I:%M:%S %p")"
        echo "The reason given was:"
        tail -n 3 "$ffmpeg_progress"
        touch "$outputfile.failed_encode"
        if ! "$keep_partial"; then
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
        --help|-h)              usage ;;
        --input|-i)             input+=( "$1" )
                                shift
                                ;;
        --output|-o)            user_outputdir="$1"
                                shift
                                ;;
        --vcodec)               video_codec="$1"
                                shift
                                ;;
        --plex-defaults|--plex) crf=22
                                preset=slow
                                copysubs=true
                                video_codec=x265
                                ;;
        --ps5-defaults|--ps5)   crf=22
                                preset=slow
                                file_format=mp4
                                video_codec=x264
                                audio_codec=aac
                                hdr_sdr_convert=true
                                ;;
        --acodec)               audio_codec="$1"
                                shift
                                ;;
        --format|-f)            file_format=$1
                                shift
                                ;;
        --crf|-c)               crf=$(sed 's/[^0-9]//g' <<< "$1")
                                shift
                                ;;
        --preset|-p)            preset="$1"
                                shift
                                ;;
        --update-interval|-n)   update_interval=$(sed 's/[^0-9\.]//g' <<< "$1")
                                shift
                                ;;
        --nocopysubs)           copysubs=false ;;
        --deletesource)         deletesource=true ;;
        --overwrite|-w)         overwrite=true ;;
        --keep-partial|-k)      rm_partial=false ;;
        --hdr_sdr_convert)      hdr_sdr_convert=true ;;
        --resume_on_failure)    resume_on_failure=true ;;
        --hwaccel)              hwaccel=true ;;
        --no-progress-bar)      show_progress_bar=false ;;
        --draw-thumbnails)      draw_thumbnails=true ;;
        *)                      echo "Error: unrecognized flag '$flag'"
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
    mp4)    file_format=mp4 ;;
    *)      file_format=mkv ;;
esac

# Select appropriate ffmpeg codecs based upon user selections of h264/h265 and NVENC hardware acceleration
if "$hwaccel"; then
    case "${video_codec,,}" in
        *264*|avc)      video_codec=h264_nvenc
                        profile=main
                        pix_fmt=yuv420p
                        ;;
        *265*|hevc|*)   video_codec=h265_nvenc
                        profile=main10
                        pix_fmt=yuv420p10le
                        ;;
    esac
else
    case "${video_codec,,}" in
        *264*|avc)      video_codec=libx264
                        profile=main
                        pix_fmt=yuv420p
                        ;;
        *265*|hevc|*)   video_codec=libx265
                        profile=main10
                        pix_fmt=yuv420p10le
                        ;;
    esac
fi

case "${audio_codec,,}" in
    flac)   audio_codec=flac ;;
    aac)    audio_codec=aac ;;
    *)      audio_codec=copy ;;
esac

preset="${preset:-medium}"
if "$hwaccel"; then
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

if [[ "$hdr_sdr_convert" ]]; then
    video_filter="zscale=transfer=linear,tonemap=hable,zscale=transfer=bt709,format=$pix_fmt"
else
    video_filter="format=$pix_fmt"
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
mapfile -t video_files < <(find "${input[@]}" -type f -iregex '.*\.\(mp4\|mkv\|webm\|avi\|mov\|wmv\|mpe?g\)$')

total_size=$(du -bch "${video_files[@]}" | tail -n 1 | awk '{ print $1 }')

echo "Encoding ${#video_files[@]} videos totaling $total_size in ${input[*]}"

trap exit_hook EXIT

ffmpeg_progress=$(mktemp)

# Loop over every file in the directories provided by the user
for video_file in "${video_files[@]}"; do
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
    start=$(date +%s)


    ffmpeg_opts=(
        -nostdin
        $overwrite_flag
        -i "$w_video_file"
        -c:v "$video_codec"
        -profile:v "$profile"
        ${crf:+-crf "$crf"}
        -preset "$preset"
        ${video_filter:+-vf "$video_filter"}
        "${stream_codecs[@]}"
        "${mapping[@]}"
        "$w_outputfile"
    )
    ffmpeg_wrapper "${ffmpeg_opts[@]}" &


    trap int_hook INT
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
    while sleep 1; do
        kill -0 "$ffmpeg_pid" &>/dev/null || break
    done &
    wait "$ffmpeg_pid"
    ffmpeg_exit_status=$?
    print_result
done
