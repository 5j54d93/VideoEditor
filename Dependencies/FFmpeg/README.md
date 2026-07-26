# VideoEditor FFmpeg tools

This directory contains the self-contained Universal 2 `ffmpeg` and `ffprobe`
executables embedded in `VideoEditor.app/Contents/MacOS`. End users do not need
Homebrew, MacPorts, FFmpeg, or x264 installed.

## Rebuild

Requirements are the Xcode command-line tools plus the standard macOS tools
used by the script (`bash`, `curl`, `make`, `tar`, and `shasum`). No Homebrew
build packages are required.

```sh
./Dependencies/FFmpeg/build-macos.sh
```

The script verifies both source archive checksums, builds arm64 and x86_64
slices separately, merges them with `lipo`, and rejects non-system dynamic
library references. The Intel x264 slice intentionally disables assembly so
the build does not depend on NASM; the Apple Silicon slice retains ARM assembly
optimizations.

The checked-in source archives make the binary distribution self-contained for
GPL source availability. If a source archive is absent, the script downloads
the same pinned archive and verifies it before building.

## Updating

1. Choose and pin the new FFmpeg version and x264 commit.
2. Update URLs and SHA-256 values in `build-macos.sh` and version data in
   `VERSION`.
3. Replace the exact archives in `Sources/`.
4. Run `build-macos.sh` and the app's release validation.
5. Review upstream license changes before publishing.

The paths and Xcode references remain stable, so normal version updates do not
require changes to `project.pbxproj` or Swift code.

