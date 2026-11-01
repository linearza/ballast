#!/bin/sh
# Builds idevice_id, ideviceinfo, ideviceinstaller and afcclient from pinned upstream
# tarballs, as universal (arm64 + x86_64) executables that need nothing but macOS itself:
# every library is linked in statically. Output: .build/vendor/imobiledevice/bin/
#
# Needs: cmake, pkg-config (brew install cmake pkg-config), curl, and the Command Line Tools.
# Nothing from Homebrew is linked: pkg-config and the compiler only ever see our own prefix.
# The first run takes a few minutes; later runs are instant until this script changes.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$root/.build/vendor/imobiledevice
bin=$work/bin
min=14.0
jobs=$(sysctl -n hw.ncpu)

# name  version  url  sha256. These are the exact sources the GPL/LGPL source offer in
# Resources/ThirdPartyNotices.txt points at: bump a version here and update that file too.
GH=https://github.com
sources='
libplist 2.8.0 '$GH'/libimobiledevice/libplist/releases/download/2.8.0/libplist-2.8.0.tar.bz2 b1f59f7634c58b2481325a23ff4e3bf51574a42d868cbe466d2b39b04550752a
libimobiledevice-glue 1.3.3 '$GH'/libimobiledevice/libimobiledevice-glue/releases/download/1.3.3/libimobiledevice-glue-1.3.3.tar.bz2 920ce01382a32695f49b23292b4979a03f0afd16c58e8755d8b7f41804acc1a9
libusbmuxd 2.1.1 '$GH'/libimobiledevice/libusbmuxd/releases/download/2.1.1/libusbmuxd-2.1.1.tar.bz2 5546f1aba1c3d1812c2b47d976312d00547d1044b84b6a461323c621f396efce
libtatsu 1.0.5 '$GH'/libimobiledevice/libtatsu/releases/download/1.0.5/libtatsu-1.0.5.tar.bz2 536fa228b14f156258e801a7f4d25a3a9dd91bb936bf6344e23171403c57e440
libimobiledevice 1.4.0 '$GH'/libimobiledevice/libimobiledevice/releases/download/1.4.0/libimobiledevice-1.4.0.tar.bz2 23cc0077e221c7d991bd0eb02150a0d49199bcca1ddf059edccee9ffd914939d
ideviceinstaller 1.2.0 '$GH'/libimobiledevice/ideviceinstaller/releases/download/1.2.0/ideviceinstaller-1.2.0.tar.bz2 26115288e50d003bbb7d23c05441c54ea69b255974303bfd44fef6943e042f94
libzip 1.12.1 '$GH'/nih-at/libzip/releases/download/v1.12.1/libzip-1.12.1.tar.xz c40062022a1963c80573d48f6070792297cecd7c6bffe3aefcac0d8b9bee8913
openssl 3.5.4 '$GH'/openssl/openssl/releases/download/openssl-3.5.4/openssl-3.5.4.tar.gz 967311f84955316969bdb1d8d4b983718ef42338639c621ec4c34fddef355e99
'

tools="idevice_id ideviceinfo ideviceinstaller afcclient"
stamp=$work/stamp
want=$(shasum -a 256 "$0" | cut -d' ' -f1)

if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
  ok=1; for t in $tools; do [ -x "$bin/$t" ] || ok=0; done
  if [ "$ok" = 1 ]; then echo "iPhone tools are up to date: $bin"; exit 0; fi
fi

for t in cmake pkg-config curl shasum lipo make clang; do
  command -v "$t" >/dev/null 2>&1 || { echo "vendor-imobiledevice: '$t' is missing (brew install cmake pkg-config)" >&2; exit 2; }
done

mkdir -p "$work/dl"
echo "$sources" | while read -r name version url sha; do
  [ -n "$name" ] || continue
  file=$work/dl/$(basename "$url")
  [ -f "$file" ] || curl -fsSL -o "$file" "$url"
  got=$(shasum -a 256 "$file" | cut -d' ' -f1)
  if [ "$got" != "$sha" ]; then
    rm -f "$file"
    echo "vendor-imobiledevice: $name $version does not match its pinned sha256 (got $got)" >&2
    exit 1
  fi
done

src_of() { echo "$sources" | awk -v n="$1" '$1 == n { print $2 }'; }
tarball() { echo "$sources" | awk -v n="$1" '$1 == n { print $3 }' | xargs basename; }
# Unpacks into $work/src-$arch/<name>-<version>, fresh each time.
unpack() { mkdir -p "$srcdir" && tar -xf "$work/dl/$(tarball "$1")" -C "$srcdir"; }

build_arch() {
  arch=$1
  prefix=$work/prefix-$arch
  srcdir=$work/src-$arch
  rm -rf "$prefix" "$srcdir"
  mkdir -p "$prefix/lib/pkgconfig" "$srcdir"

  case $arch in
    arm64) ssl_target=darwin64-arm64-cc ;;
    x86_64) ssl_target=darwin64-x86_64-cc ;;
  esac
  build_triple=$(uname -m)-apple-darwin
  host_triple=$arch-apple-darwin

  # Only our own prefix is ever searched, never /opt/homebrew or /usr/local.
  unset PKG_CONFIG_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH DYLD_LIBRARY_PATH
  export PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig
  export PKG_CONFIG="pkg-config --static"
  export CC="clang -arch $arch" CXX="clang++ -arch $arch"
  export CFLAGS="-O2 -mmacosx-version-min=$min -I$prefix/include -ffile-prefix-map=$srcdir=. -ffile-prefix-map=$work=."
  export CXXFLAGS="$CFLAGS"
  export CPPFLAGS="-I$prefix/include"
  export LDFLAGS="-mmacosx-version-min=$min -L$prefix/lib"
  export MACOSX_DEPLOYMENT_TARGET=$min

  echo "==> openssl ($arch)"
  unpack openssl
  (cd "$srcdir/openssl-$(src_of openssl)" &&
    ./Configure "$ssl_target" no-shared no-tests no-docs no-apps "-mmacosx-version-min=$min" \
      --prefix="$prefix" --openssldir="$prefix/ssl" >/dev/null &&
    make -j"$jobs" >/dev/null && make install_sw >/dev/null)

  # An autotools library: configure statically, install into the prefix.
  autotools() {
    name=$1; shift
    echo "==> $name ($arch)"
    unpack "$name"
    (cd "$srcdir/$name-$(src_of "$name")" &&
      ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes \
      ./configure --prefix="$prefix" --build="$build_triple" --host="$host_triple" \
        --enable-static --disable-shared --disable-dependency-tracking "$@" >/dev/null &&
      make -j"$jobs" >/dev/null && make install >/dev/null)
  }

  autotools libplist --without-cython
  autotools libimobiledevice-glue
  autotools libusbmuxd
  # libcurl is the one system library libtatsu needs; Apple's own copy.
  autotools libtatsu libcurl_CFLAGS=-DCURL_STATICLIB=0 libcurl_LIBS=-lcurl
  autotools libimobiledevice --with-openssl --without-cython \
    openssl_CFLAGS="-I$prefix/include" openssl_LIBS="-L$prefix/lib -lssl -lcrypto"

  echo "==> libzip ($arch)"
  unpack libzip
  # cmake picks the compiler and flags itself; a CC with arguments in it confuses it.
  (cd "$srcdir/libzip-$(src_of libzip)" && unset CC CFLAGS CPPFLAGS LDFLAGS &&
    cmake -S . -G "Unix Makefiles" -DCMAKE_C_FLAGS="-ffile-prefix-map=$srcdir=."  -B build -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$min" \
      -DCMAKE_PREFIX_PATH="$prefix" \
      -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF \
      -DENABLE_BZIP2=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF -DENABLE_OPENSSL=OFF \
      -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_COMMONCRYPTO=OFF >/dev/null &&
    cmake --build build -j"$jobs" >/dev/null && cmake --install build >/dev/null)

  autotools ideviceinstaller libzip_CFLAGS="-I$prefix/include" libzip_LIBS="-L$prefix/lib -lzip -lz" \
    libplist_CFLAGS="-I$prefix/include" libplist_LIBS="-L$prefix/lib -lplist-2.0"
}

for arch in arm64 x86_64; do build_arch "$arch"; done

rm -rf "$bin"; mkdir -p "$bin"
for t in $tools; do
  a=$work/prefix-arm64/bin/$t; x=$work/prefix-x86_64/bin/$t
  [ -x "$a" ] && [ -x "$x" ] || { echo "vendor-imobiledevice: $t was not built" >&2; exit 1; }
  lipo -create "$a" "$x" -output "$bin/$t"
  strip -x "$bin/$t"
done

# Nothing may point outside macOS itself.
for t in $tools; do
  lipo -info "$bin/$t" | grep -q 'arm64' && lipo -info "$bin/$t" | grep -q 'x86_64' || { echo "vendor-imobiledevice: $t is not universal" >&2; exit 1; }
  if otool -L "$bin/$t" | grep -E '^[[:space:]]' | grep -vE '^[[:space:]]+(/usr/lib/|/System/Library/)'; then
    echo "vendor-imobiledevice: $t links something outside macOS" >&2; exit 1
  fi
done

echo "$want" > "$stamp"
echo "$bin"
