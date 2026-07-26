# Bundled FFmpeg notices

VideoEditor bundles the `ffmpeg` and `ffprobe` command-line programs. They are
built from FFmpeg 8.1.2 with x264 enabled and are distributed under the GNU
General Public License, version 2 or later. The build deliberately does not use
FFmpeg's `--enable-nonfree` option.

The exact upstream source archives used for the checked-in binaries are in
`Sources/`. The corresponding license texts are in `Licenses/`, and
`build-macos.sh` contains the complete macOS build recipe.

The bundled programs are built from the unmodified upstream source archives;
VideoEditor changes no FFmpeg or x264 source files. In particular, there are no
additions, deletions, or other changes to FFmpeg's `libavcodec/jfdctfst.c`,
`libavcodec/jfdctint_template.c`, or `libavcodec/jrevdct.c`. The only build
differences are the documented configure and compiler options in
`build-macos.sh`.

This software is based in part on the work of the Independent JPEG Group.

Upstream projects:

- FFmpeg: <https://ffmpeg.org/>
- x264: <https://code.videolan.org/videolan/x264>

VideoEditor is not affiliated with or endorsed by either upstream project.
