# batch\_ffmpeg

batch\_ffmpeg is a script intended to encode a number of videos with easily configurable options and interesting features.

## Usage

For a full list of options, invoke batch\_ffmpeg with the `-h` flag, i.e. `./batch\_ffmpeg.sh -h`

The most important parameter that batch\_ffmpeg takes is the input parameter, which tells batch\_ffmpeg which file to encode or which directory tree contains files to encode.
By default, batch\_ffmpeg will encode all videos found in `~/transcoding/source` and place them in `~/transcoding/sink`. This can be changed with the `--input` or `-i` flag, followed by the path.

You can also change the output directory that ffmpeg will write encoded videos to. Simply pass the `--output` or `-o` flag.

batch\_ffmpeg sets reasonable defaults for various encoding parameters, but you can change some of them like CRF, preset, height, width, framerate, codec, and a few others. Just pass the appropriate flag according to the help text.

## Features

### Stopping the queue

While a video is encoding, you may cancel the rest of the queue while allowing the current encoding job to finish by pressing `q` on your keyboard. A message will display indicating that you have canceled the queue, but the current job will finish. If you press `q` again, the current job will be aborted.

### VLC Preview

As a video is encoding, you may wish to try playing back the output file to check its quality. Simply press `p` on your keyboard during the encoding and VLC will open and play back the output file for the current encoding job. Please note that this only works with output files in the MKV container format, not the MP4 format.

Additionally, the user can pass the `--preview-only` flag and instead of saving output to a file, ffmpeg will send the encoded video directly to VLC for display.

### Debugging output

batch\_ffmpeg can show you the underlying ffmpeg command line invocation if you pass the `--debug` flag. This allows you to determine exactly what parameters were passed to ffmpeg.

### HDR Tone Mapping

batch\_ffmpeg is capable of tone mapping HDR videos into SDR videos. This is useful for converting content that was recorded or mastered in HDR so that it can be played back on devices that do not support HDR.

### Hardware acceleration

NVENC hardware accelerated video encoding is enabled via the `--hwaccel` flag, which can provide a significant reduction in encoding time in return for increased file size and reduced quality.

### Live ASCII Thumbnails

batch\_ffmpeg can draw ASCII thumbnails of the encode as it progresses at regular intervals. This is enabled thanks to [ascii-image-converter](https://github.com/TheZoraiz/ascii-image-converter) by TheZoraiz. For best fidelity (although thumbnails will be drawn slowly), maximize your terminal window and set your font size to the minimum value.
