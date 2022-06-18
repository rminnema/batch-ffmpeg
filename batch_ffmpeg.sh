#!/bin/bash

readonly RED=$(tput setaf 1)
readonly NON=$(tput sgr0)

die() {
    if [[ "$1" && -t 2 ]]; then
        echo "${RED}Error: $*$NON" >&2
    elif [[ "$1" ]]; then
        echo "Error: $*" >&2
    fi
    exit 1
}

# Prints a progress bar that extends the entire bottom row
# for example:
# 00:23:45 [=======================================>]  99%
display_progress_bar() {
    if (( percentage < 0 || percentage > 100 )); then
        return 1
    fi

    local bar_width=$(( $(tput cols) - 16 ))
    local percentage=$(printf "%3d" "$1")
    local equals_signs=$(( bar_width * percentage / 100 ))
    local spaces=$(( bar_width - equals_signs - 1 ))

    if (( ${BASH_VERSION::1} >= 5 )); then
        local elapsed_seconds=$(( EPOCHSECONDS - encoding_start_time ))
    else
        local elapsed_seconds=$(( $(date +%s) - encoding_start_time ))
    fi
    local elapsed_hhmmss=$(seconds_to_hhmmss "$elapsed_seconds")

    # Build the progress bar piece by piece
    local progress_bar="$elapsed_hhmmss ["
    (( equals_signs > 0 )) && progress_bar+=$(printf "=%.0s" $(seq "$equals_signs"))
    (( equals_signs < bar_width )) && progress_bar+=">"
    (( spaces > 0 )) && progress_bar+=$(printf " %.0s" $(seq "$spaces"))
    progress_bar+="] $percentage%"

    echo -en "$progress_bar\r"
}

# Calculates and shows the progress of the encoding task in seconds
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
    kill "${bg_pids[@]}" &>/dev/null
    rm -f "$ffmpeg_progress" "$thumbnail"
    if [[ "$ffmpeg_exit_status" != 0 ]] && "$rm_partial"; then
        rm -f "$output_video"
    fi
}

# Converts seconds to string in form of HH:MM:SS
seconds_to_hhmmss() {
    local hours=$(( $1 / 60 ** 2 ))
    local minutes=$(( ($1 % 60 ** 2) / 60 ))
    local seconds=$(( $1 % 60 ))

    printf "%02d:%02d:%02d\n" "$hours" "$minutes" "$seconds"
}

# Converts seconds to string in form of 'HH hours, MM minutes, SS seconds'
seconds_to_english() {
    IFS=':' read -r hours minutes seconds < <(seconds_to_hhmmss "$1"); IFS=$' \t\n'
    local hours=$(sed -re 's/^0([0-9])/\1/' -e 's/^0//' <<< "$hours")
    local minutes=$(sed -re 's/^0([0-9])/\1/' -e 's/^0//' <<< "$minutes")
    local seconds=$(sed -r 's/^0([0-9])/\1/' <<< "$seconds")

    echo "${hours:+#$hours hours, }${minutes:+#$minutes minutes, }${seconds:+#$seconds seconds}" |
        sed -re 's/, $//' -e 's/#(1 [a-z]+)s/#\1/g' -e 's/#//g'
}

usage() {
    cat <<EOF | less

$0 [OPTIONS]

Options:
    --help, -h, -?          display this help text

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
                            default: 22

    --preset, -p            set x264 or x265 preset
                            default: slow

    --hdr_sdr_convert       convert HDR source video to SDR

    --height                change the video's vertical resolution
                            if you do not set width, aspect ratio will be preserved

    --width                 change the video's horizontal resolution
                            if you do not set height, aspect ratio will be preserved

    --framerate             change the frame rate of the output video

    --hwaccel               use NVENC hardware acceleration
                            default: off

    --nosubs, --no-subs     do not copy subtitles from source file
                            default: copy

    --resume_on_failure     continue with the queue instead of exiting on failure

    --deletesource          delete the source file on successful encode
                            default: keep

    --overwrite,-w          overwrite previous encodes
                            default: don't overwrite

    --keep-partial,-r       keep partial encodes
                            default: remove

    --ps5-defaults,--ps5    set reasonable defaults for PS5 videos
                            h264, AAC, CRF 22, preset slow, HDR tone mapping

    --update-interval,-n    time in seconds (decimal allowed) between updates of the progress bar.
                            default: 1

    --no-progress-bar       disable the progress bar

    --draw-thumbnails       draw thumbnails as the encode progresses

    --preview-only          do not save the output to a file, simply preview it in VLC

    --debug                 print debugging information (namely the parameters passed to ffmpeg)

EOF
    die
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
        duration=$(( EPOCHSECONDS - encoding_start_time ))
    else
        duration=$(( $(date +%s) - encoding_start_time ))
    fi

    # Since the encoding has stopped, kill the asynchronous processes updating the progress bar or drawing thumbnails
    kill "${bg_pids[@]}" &>/dev/null
    unset "bg_pids"
    rm -f "$thumbnail"

    # Successful encode
    if [[ "$ffmpeg_exit_status" == 0 && -s "$output_video" ]]; then
        display_progress_bar 100
        echo
        echo "Encoding finished successfully in $(seconds_to_english "$duration") at $(date "+%I:%M:%S %p")"
        input_size=$(stat -c '%s' "$input_video")
        output_size=$(stat -c '%s' "$output_video")
        cr=$(awk -v i="$input_size" -v o="$output_size" 'BEGIN { printf "%.2f",i/o }')
        echo "Input size: $(print_size <<< "$input_size")"
        echo "Output size: $(print_size <<< "$output_size")"
        echo "Compression ratio: $cr"
        if (( $(awk -v cr="$cr" 'BEGIN { print cr <= 1 }') )); then
            echo "Warning: Low compression ratio"
            echo "Check settings"
        fi
        echo
        if "$deletesource"; then
            rm -f "$input_video"
        fi
    # Canceled encode
    elif "$encode_cancelled"; then
        echo
        echo "Encode cancelled after $(seconds_to_english "$duration") at $(date "+%I:%M:%S %p")"
        echo
        die
    # Failed encode
    else
        echo
        echo "Error: encode failed after $(seconds_to_english "$duration") at $(date "+%I:%M:%S %p")"
        echo "Here are the logs generated:"
        echo
        printf "#%.0s" $(seq $(tput cols))
        tail "$ffmpeg_progress"
        printf "#%.0s" $(seq $(tput cols))
        echo
        echo
        echo "Encoding options were:"
        echo
        print_cmdline
        echo
        echo
        touch "$output_video.failed_encode"
        if ! "$resume_on_failure"; then
            die
        fi
        if "$rm_partial"; then
            rm "$output_video"
        fi
        failure_detected=true
    fi
}

draw_thumbnail() {
    if progress=$(calculate_progress); then
        if "$windows"; then
            "$ffmpeg_path" -nostdin -ss "$progress" -i "$ffmpeg_input_file" -vframes 1 -an "$(wslpath -w "$thumbnail")" &>/dev/null
        else
            "$ffmpeg_path" -nostdin -ss "$progress" -i "$ffmpeg_input_file" -vframes 1 -an "$thumbnail" &>/dev/null
        fi

        ascii-image-converter -Cc "$thumbnail"
        rm -f "$thumbnail"
    fi
}

print_cmdline() {
    echo -n "$ffmpeg_path" | sed "s/^.*\s.*$/'&'/"
    for opt in "${ffmpeg_opts[@]}"; do
        if grep -Eq "[\s()]" <<< "$opt"; then
            echo -n " ${opt@Q}"
        else
            echo -n " $opt"
        fi
    done
    echo
}

user=$(whoami)
if [[ "$user" == root ]]; then
    die "You must run this script as a regular user."
fi

# If there's an ffmpeg.exe, use that
if ffmpeg_path=$(command -v ffmpeg.exe); then
    vlc_path=$(command -v vlc.exe)
    echo "Using Windows ffmpeg.exe"
    windows=true
elif ffmpeg_path=$(command -v ffmpeg); then
    vlc_path=$(command -v vlc)
    echo "Using Linux ffmpeg"
    windows=false
else
    die "ffmpeg was not found on this machine."
fi

# Set defaults
crf=22
preset=slow
file_format=mkv
video_codec=x265
audio_codec=copy
copysubs=true
deletesource=false
overwrite=false
rm_partial=true
hwaccel=false
resume_on_failure=false
show_progress_bar=true
draw_thumbnails=false
debugging=false
preview_only=false

# Parse user-provided options
shopt -s nocasematch
while (( $# )); do
    flag=$1
    shift
    case "$flag" in
        --help|-h|-\?)
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
        --ps5-defaults|--ps5)
            file_format=mp4
            video_codec=x264
            audio_codec=libfdk_aac
            hdr_sdr_convert=true
            ps5_options=( -colorspace 2020 -color_trc smpte2084 -color_primaries 2020 )
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
        --height)
            height=$(sed 's/[^0-9]//g' <<< "$1")
            shift
            ;;
        --width)
            width=$(sed 's/[^0-9]//g' <<< "$1")
            shift
            ;;
        --framerate)
            framerate=$(sed 's/[^0-9]//g' <<< "$1")
            shift
            ;;
        --nosubs|--no-subs)
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
            ;;
        --no-progress-bar)
            show_progress_bar=false ;;
        --draw-thumbnails)
            draw_thumbnails=true ;;
        --debug)
            debugging=true ;;
        --preview-only)
            preview_only=true ;;
        *)
            die "unrecognized flag '$flag'"
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
        die
    fi
done

crf=$(sed 's/[^0-9]//g' <<< "$crf")

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

if (( crf == 0 )) && [[ "$video_codec" == libx265 ]]; then
    x265_params="lossless"
fi

case "${audio_codec,,}" in
    *flac*)
        audio_codec=flac ;;
    *aac*)
        audio_codec=libfdk_aac
        audio_bitrate=320k
        ;;
    *)
        audio_codec=copy ;;
esac

preset="${preset:-medium}"
if "$hwaccel"; then
    case "${preset,,}" in
        fastest)
            preset=p1 ;;
        faster)
            preset=p2 ;;
        fast)
            preset=p3 ;;
        slow)
            preset=p5 ;;
        slower)
            preset=p6 ;;
        slowest)
            preset=p7 ;;
        lossless)
            preset=lossless ;;
        *)
            preset=p4 ;;
    esac
elif ! "$preview_only"; then
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
else
    preset=ultrafast
fi

update_interval=${update_interval:-1}
if (( $(echo "$update_interval < 0.1" | bc -l) )); then
    update_interval=0.1
fi

"$preview_only" || echo "File format: ${file_format^^}"

echo "Codec: $video_codec"

echo -n "CRF: "
if grep -q "nvenc" <<< "$video_codec"; then
    echo "n/a (nvenc)"
else
    echo "$crf"
fi
echo "Preset: $preset"

if [[ "$height" || "$width" ]]; then
    if (( width > 10000 || height > 10000 )); then
        die "Dimension out of bounds"
    fi

    [[ "$height" ]] || height=-1
    [[ "$width" ]] || width=-1

    video_filters="zscale=h=$height:w=$width"
fi

if "$copysubs"; then
    stream_codecs=( -c:a "$audio_codec" -c:s copy )
    mapping=( -map 0 )
    echo "Will copy subtitles"
else
    stream_codecs=( -c:a "$audio_codec" )
    mapping=( -map 0:v -map 0:a )
    echo "Will not copy subtitles"
fi

if ! "$preview_only"; then
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
fi

declare -A stream_parameters
if [[ "$hdr_sdr_convert" ]]; then
    echo "Will perform HDR->SDR color conversion"
    if [[ "$video_filters" ]]; then
        video_filters="$video_filters:t=linear,tonemap=hable,zscale=t=709"
    else
        video_filters="zscale=t=linear,tonemap=hable,zscale=t=709"
    fi
else
    echo "Will preserve any HDR metadata in the source"
fi

echo
read -rsn 1 -p "Press any key to continue."
echo

# Generate the array of video files
mapfile -t input_videos < <(find "${input[@]}" -type f -iregex '.*\.\(mp4\|mkv\|webm\|avi\|mov\|wmv\|mpe?g\)$' | sort)

total_size=$(du -bch "${input_videos[@]}" | tail -n 1 | awk '{ print $1 }')

echo "Encoding ${#input_videos[@]} videos totaling $total_size in ${input[*]}"
echo "Press Q to cancel the queue at any time"
"$preview_only" || echo "Press P to preview the current video encoding."

trap exit_hook EXIT

ffmpeg_progress=$(mktemp)
encode_cancelled=false
failure_detected=false
polling_interval=0.005

# Loop over every file in the directories provided by the user
for input_video in "${input_videos[@]}"; do
    if [[ "$signal1" =~ Q|q ]]; then
        die
    fi

    echo
    source_duration=$(
        mediainfo --Inform="Video;%Duration%" "$input_video" 2>/dev/null |
        head -n 1 |
        awk 'function roundup(x) { y=int(x); return x-y>=0.5?y+1:y; } { printf "%0d\n",roundup($1 / 1000) }'
    )

    if [[ -z "$hdr_sdr_convert" ]]; then
        if [[ "$video_codec" == libx265 || "$video_codec" == hevc_nvenc ]]; then
            videoparams=$(ffprobe -prefix -unit -show_streams -select_streams v "$input_video" 2>/dev/null | sed '/^\[/d')
            while IFS='=' read -r parameter value; do
                stream_parameters["$parameter"]="$value"
            done <<< "$videoparams"

            pix_fmt=${stream_parameters[pix_fmt]}
            color_range=${stream_parameters[color_range]}
            chroma_sample_location=${stream_parameters[chroma_location]}
            colorspace=${stream_parameters[color_space]}
            color_trc=${stream_parameters[color_transfer]}
            color_primaries=${stream_parameters[color_primaries]}

            if [[ "$colorspace" == bt2020nc && "$color_primaries" == bt2020 && "$color_trc" == smpte2084 ]]; then
                case "$color_range" in
                    tv)
                        range=limited ;;
                    pc)
                        range=full ;;
                esac
                x265_params="${x265_params:+$x265_params:}colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=$range:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"
                profile=main10
                pix_fmt=yuv420p10le
            elif grep "lossless" <<< "$x265_params"; then
                x265_params='lossless'
            else
                x265_params=''
            fi
        else
            x265_params=''
        fi
    fi

    videoname=$(basename "$input_video")
    videopath=$(dirname "$input_video")
    if [[ "$user_outputdir" ]]; then
        outputdir="$user_outputdir"
    else
        outputdir=${videopath//source/sink}
    fi
    output_videoname="${videoname%.*}.$file_format"
    output_video="$outputdir/$output_videoname"
    mkdir -p "$outputdir" || die
    rm -f "$output_video.failed_encode"

    if [[ "$output_video" == "$input_video" ]] && ! "$preview_only"; then
        echo "Warning: output and input file are the same. Skipping."
        echo
        continue
    fi

    if [[ -f "$output_video" ]] && ! "$overwrite" && ! "$preview_only"; then
        echo "Warning: Output file $(basename "$output_video") exists but overwrite flag was not given. Skipping."
        echo
        continue
    fi

    if "$windows"; then
        ffmpeg_input=$(wslpath -w "$input_video")
        ffmpeg_output="$(wslpath -w "$outputdir")\\$output_videoname"
    else
        ffmpeg_input=$input_video
        ffmpeg_output=$output_video
    fi

    if "$preview_only"; then
        container_format=matroska
        ffmpeg_output='-'
    fi

    ffmpeg_opts=(
        -stats_period 0.1
        $overwrite_flag
        -nostdin
        ${ps5_options[@]:+"${ps5_options[@]}"}
        -i "$ffmpeg_input"
        ${video_codec:+-c:v "$video_codec"}
        ${profile:+-profile:v "$profile"}
        ${crf:+-crf "$crf"}
        ${preset:+-preset:v "$preset"}
        ${pix_fmt:+-pix_fmt "$pix_fmt"}
        ${x265_params:+-x265-params "$x265_params"}
        ${video_filters:+-filter:v "$video_filters"}
        ${framerate:+-r "$framerate"}
        "${stream_codecs[@]}"
        ${audio_bitrate:+-b:a "$audio_bitrate"}
        "${mapping[@]}"
        ${container_format:+-f "$container_format"}
        ${ffmpeg_output:+"$ffmpeg_output"}
    )

    if (( "${BASH_VERSION::1}" >= 5 )); then
        encoding_start_time=$EPOCHSECONDS
    else
        encodeing_start_time=$(date +%s)
    fi
    echo "Encoding $videoname"
    if "$debugging"; then
        print_cmdline
    fi


    # Start the encoding task
    if "$preview_only"; then
        "$ffmpeg_path" "${ffmpeg_opts[@]}" 2>"$ffmpeg_progress" | "$vlc_path" - &>/dev/null &
        ffmpeg_pid=$!
    else
        "$ffmpeg_path" "${ffmpeg_opts[@]}" >/dev/null 2>"$ffmpeg_progress" &
        ffmpeg_pid=$!
    fi


    if "$debugging"; then
        echo "ffmpeg PID: '$ffmpeg_pid'"
        echo "progress file: '$ffmpeg_progress'"
        echo
    fi

    bg_pids=()

    if "$show_progress_bar"; then
        while true; do
            kill -0 "$ffmpeg_pid" &>/dev/null || break
            if progress=$(calculate_progress); then
                pct_progress=$(( 100 * progress / source_duration ))
                display_progress_bar "$pct_progress"
            fi
            sleep "$update_interval"
        done &
        bg_pids+=( "$!" )
    fi

    if "$draw_thumbnails"; then
        thumbnail=$(mktemp --suffix=.png)
        while true; do
            kill -0 "$ffmpeg_pid" &>/dev/null || break
            draw_thumbnail
        done &
        bg_pids+=( "$!" )
    fi

    # Poll for the cancellation signal.
    while kill -0 "$ffmpeg_pid" &>/dev/null; do
        if read -rsn 1 -t "$polling_interval" signal1 < /dev/tty && [[ $signal1 =~ Q|q ]]; then
            echo
            echo "The queue has been cancelled."
            echo "$videoname will finish encoding."
            echo "Press Q again to cancel encoding."
            echo
            break
        elif [[ $signal1 =~ P|p ]] && ! "$preview_only"; then
            "$vlc_path" "$ffmpeg_output" &>/dev/null &
        fi
    done

    # If the queue has been cancelled, the encode is probably still running.
    # If it is, poll for another cancellation signal.
    while kill -0 "$ffmpeg_pid" &>/dev/null; do
        if read -rsn 1 -t "$polling_interval" signal2 < /dev/tty && [[ $signal2 =~ Q|q ]]; then
            kill "$ffmpeg_pid"
            encode_cancelled=true
            break
        elif [[ $signal2 =~ P|p ]] && ! "$preview_only"; then
            "$vlc_path" "$ffmpeg_output" &>/dev/null &
        fi
    done

    wait "$ffmpeg_pid"
    ffmpeg_exit_status=$?

    "$preview_only" || print_result
done

"$failure_detected" && die
exit 0
