#!/bin/sh
set -eu

: "${X264_PREFIX:?X264_PREFIX must point to the staged x264 installation}"

case " $* " in
    *" --version "*)
        echo "1.0-videoeditor"
        ;;
    *" --exists "*)
        exit 0
        ;;
    *" --variable=includedir "*)
        echo "${X264_PREFIX}/include"
        ;;
    *" --cflags-only-I "*|*" --cflags "*)
        echo "-I${X264_PREFIX}/include"
        ;;
    *" --libs "*)
        echo "-L${X264_PREFIX}/lib -lx264"
        ;;
    *)
        echo "Unsupported pkg-config query: $*" >&2
        exit 1
        ;;
esac

