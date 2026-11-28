#!/usr/bin/env bash
#
# Compiles the vendored curl tool + libcurl + nghttp2/nghttp3/ngtcp2 into ONE static archive,
# libmvcurl.a, which build.sh links into xhuskydg_helper (the `curl` applet).
#
#   build_curl.sh <cc> <ar> <boringssl-include-dir> <outdir>
#
# Only the curl tool's main() is renamed (-Dmain=run_curl, tool_main.c only); everything else is
# unchanged. Flags mirror the upstream curl-android Android.mk (kept in the config*/ dirs).
# Set MV_CURL_SYNTAX_ONLY=1 to only syntax-check the sources (used on hosts without an NDK).
#
set -euo pipefail
CC="$1"; AR="$2"
# resolve to absolute paths BEFORE the cd below (callers pass paths relative to the repo root)
SSL_INC="$(cd "$3" && pwd)"; mkdir -p "$4"; OUT="$(cd "$4" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
mkdir -p "$OUT/obj"

# curl's config dir is generated for LP64 (config64). 32-bit targets (armeabi-v7a, x86) need different
# SIZEOF_* values, so use config32/ when the tree ships one, otherwise derive it from config64.
CFG=config64
if [[ "$(echo | "$CC" -dM -E - 2>/dev/null | awk '/__SIZEOF_LONG__/{print $3}')" == 4 ]]; then
    if [[ -d config32 ]]; then
        CFG=config32
    else
        CFG="$OUT/config32"
        rm -rf "$CFG"; cp -r config64 "$CFG"
        # only the pointer-width dependent sizes; curl_off_t stays 64-bit on its own
        find "$CFG" -name 'curl_config.h' -exec sed -i \
            -e 's/^\(#define SIZEOF_LONG\) 8/\1 4/' \
            -e 's/^\(#define SIZEOF_SIZE_T\) 8/\1 4/' \
            -e 's/^\(#define SIZEOF_TIME_T\) 8/\1 4/' \
            -e 's/^\(#define SIZEOF_VOIDP\) 8/\1 4/' {} +
        LFS=-D_FILE_OFFSET_BITS=64
        echo "    32-bit target: derived $CFG from config64 (SIZEOF_LONG/SIZE_T/TIME_T/VOIDP -> 4, large files via _FILE_OFFSET_BITS=64)"
    fi
fi

COMMON=(-std=gnu11 -D_GNU_SOURCE ${LFS:-} -Os -ffunction-sections -fdata-sections -fstack-protector-strong -fvisibility=hidden
        -DHAVE_CONFIG_H -w)
DEPINC="-Inghttp2/lib/includes -Inghttp3/lib/includes -Ingtcp2/lib/includes -Ingtcp2/crypto/includes -DNGHTTP2_STATICLIB -DNGHTTP3_STATICLIB -DNGTCP2_STATICLIB"
declare -A INC=(
  [curl/src]="-Icurl/include -Icurl/lib -I$CFG $DEPINC"
  [curl/lib]="-Icurl/include -Icurl/lib -I$CFG -DBUILDING_LIBCURL $DEPINC"
  [nghttp2]="-Inghttp2/lib/includes -Iconfig -DNGHTTP2_STATICLIB"
  [nghttp3]="-Inghttp3/lib -Inghttp3/lib/includes -Iconfig -DNGHTTP3_STATICLIB"
  [ngtcp2/lib]="-Ingtcp2/lib -Ingtcp2/lib/includes -Iconfig -DNGTCP2_STATICLIB"
  [ngtcp2/crypto]="-Ingtcp2/lib -Ingtcp2/lib/includes -Ingtcp2/crypto -Ingtcp2/crypto/includes -Iconfig -DNGTCP2_STATICLIB"
)
flags_for() {
    case "$1" in
        curl/src/*)       echo "${INC[curl/src]}" ;;
        curl/lib/*)       echo "${INC[curl/lib]}" ;;
        nghttp2/*)        echo "${INC[nghttp2]}" ;;
        nghttp3/*)        echo "${INC[nghttp3]}" ;;
        ngtcp2/crypto/*)  echo "${INC[ngtcp2/crypto]} -I$SSL_INC" ;;
        ngtcp2/lib/*)     echo "${INC[ngtcp2/lib]}" ;;
        *) echo "unknown source group: $1" >&2; exit 1 ;;
    esac
}
# curl/lib files include <openssl/...> (vtls) as well
ssl_flag_for() { case "$1" in curl/lib/*|curl/src/*) echo "-I$SSL_INC" ;; esac; }

compile_one() {
    local src="$1" o extra=""
    o="$OUT/obj/$(echo "${src%.c}" | tr '/' '_').o"
    [[ "$src" == curl/src/tool_main.c ]] && extra="-Dmain=run_curl"
    if [[ "${MV_CURL_SYNTAX_ONLY:-0}" == 1 ]]; then
        # shellcheck disable=SC2046
        "$CC" "${COMMON[@]}" $(flags_for "$src") $(ssl_flag_for "$src") $extra -fsyntax-only "$src"
        return
    fi
    # shellcheck disable=SC2046
    "$CC" "${COMMON[@]}" $(flags_for "$src") $(ssl_flag_for "$src") $extra -c "$src" -o "$o"
}
export -f compile_one flags_for ssl_flag_for
export CC OUT SSL_INC MV_CURL_SYNTAX_ONLY
export -n COMMON INC 2>/dev/null || true
# arrays cannot be exported: re-declare them inside the xargs shells
INIT="$(declare -p COMMON INC)"
export INIT

grep -v '^[[:space:]]*\(#\|$\)' sources.txt \
  | xargs -P "$(nproc 2>/dev/null || echo 4)" -I{} bash -c 'eval "$INIT"; compile_one {}'

[[ "${MV_CURL_SYNTAX_ONLY:-0}" == 1 ]] && exit 0
rm -f "$OUT/libmvcurl.a"
"$AR" rcs "$OUT/libmvcurl.a" "$OUT"/obj/*.o
echo "    built $OUT/libmvcurl.a ($(du -h "$OUT/libmvcurl.a" | cut -f1))"
