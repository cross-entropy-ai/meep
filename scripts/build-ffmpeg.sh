#!/bin/bash
# Build a minimal, LGPL-only, static ffmpeg (arm64, macOS 15.0+) into vendor/ffmpeg/bin/ffmpeg.
# build.sh copies it into MeetingRecorder.app/Contents/Helpers/ffmpeg.
# Source: https://git.ffmpeg.org/ffmpeg.git (release tag, override with FFMPEG_REF)
# Needs: Xcode Command Line Tools only (no nasm on arm64, no pkg-config, no external libraries).
#
# Only what the app runs (Sources/Mixer.swift, Sources/EchoCanceller.swift) plus common audio inputs:
#   ffmpeg [-progress pipe:1] -i <x.caf|m4a|wav|mp3|flac|ogg> \
#       -af aformat=…,ebur128=… -f null -                      # loudness
#       -filter_complex …aformat,volume,amix,alimiter… -ar 48000 -ac 1 -c:a aac out.m4a   # mix
#       -ac 1 -ar 48000 -f s16le -                             # PCM stream for echo cancellation
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
SRC=build/ffmpeg-src
OBJ=build/ffmpeg-obj
OUT=vendor/ffmpeg
REF=${FFMPEG_REF:-n9.0.2}   # pinned release tag (2026-09-18); must be a tag

if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC"
  git clone -q --depth 1 --branch "$REF" https://git.ffmpeg.org/ffmpeg.git "$SRC"
elif [ "$(git -C "$SRC" rev-parse HEAD)" != "$(git -C "$SRC" rev-parse -q --verify "$REF^{commit}" || true)" ]; then
  git -C "$SRC" fetch -q --depth 1 origin tag "$REF"
  git -C "$SRC" checkout -q "$REF"
  rm -rf "$OBJ"   # different source: configure again
fi

# Match the app's minimum macOS (Info.plist LSMinimumSystemVersion / build.sh -target).
export MACOSX_DEPLOYMENT_TARGET=15.0
FLAGS="-arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"

CONFIGURE=(
  --cc=clang --arch=arm64
  --extra-cflags="$FLAGS" --extra-ldflags="$FLAGS"
  # LGPL 2.1+: never --enable-gpl / --enable-version3 / --enable-nonfree.
  --enable-static --disable-shared
  --disable-autodetect          # no AudioToolbox, VideoToolbox, zlib, SDL, …: no external deps
  --disable-iconv               # still probed in libc unless disabled explicitly (only for subtitles)
  --disable-everything          # then enable components one by one
  --disable-programs --enable-ffmpeg
  --disable-doc --disable-debug --disable-network
  --disable-avdevice --disable-swscale
  --enable-protocol=file,pipe
  # data: tiny; without it rawdec.c's raw_data_read_header() (not under #if upstream) is unused
  # and clang warns.
  --enable-demuxer=caf,wav,mov,aac,mp3,flac,ogg,data
  --enable-decoder=pcm_s16le,pcm_s24le,pcm_f32le,pcm_s16be,aac,mp3,flac,vorbis,opus
  --enable-parser=aac,mpegaudio,flac,vorbis,opus
  --enable-encoder=aac,pcm_s16le
  --enable-muxer=ipod,mp4,caf,wav,pcm_s16le,null   # pcm_s16le = `-f s16le`; ipod = .m4a
  --enable-filter=aformat,aresample,volume,amix,alimiter,ebur128,anull
)

mkdir -p "$OBJ"
cd "$OBJ"
# Out-of-tree build; reconfigure only when the options changed.
if [ ! -f ffbuild/config.mak ] || [ "$(cat .configure-args 2>/dev/null)" != "${CONFIGURE[*]}" ]; then
  "$ROOT/$SRC/configure" "${CONFIGURE[@]}"
  printf '%s' "${CONFIGURE[*]}" > .configure-args
fi
# The link line keeps -Llibswscale even with --disable-swscale; an empty dir avoids an ld warning.
mkdir -p libswscale
LICENSE=$(sed -n 's/^#define FFMPEG_LICENSE "\(.*\)"$/\1/p' config.h)
[ "$LICENSE" = "LGPL version 2.1 or later" ] || { echo "error: ffmpeg license is '$LICENSE', want LGPL 2.1" >&2; exit 1; }
make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" ffmpeg   # ffmpeg = stripped ffmpeg_g

cd "$ROOT"
rm -rf "$OUT"; mkdir -p "$OUT/bin"
cp "$OBJ/ffmpeg" "$OUT/bin/ffmpeg"
{ cat "$SRC/LICENSE.md"; echo; echo "-----"; echo; cat "$SRC/COPYING.LGPLv2.1"; } > "$OUT/LICENSE"
{
  echo "ffmpeg $REF ($(git -C "$SRC" rev-parse HEAD))"
  echo "source: https://git.ffmpeg.org/ffmpeg.git"
  echo "license: $LICENSE"
  echo "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
  echo
  printf 'configure'
  for a in "${CONFIGURE[@]}"; do
    case $a in *' '*) printf " %s='%s'" "${a%%=*}" "${a#*=}" ;; *) printf ' %s' "$a" ;; esac
  done
  echo
} > "$OUT/BUILDINFO"
echo "OK: $OUT/bin/ffmpeg"
