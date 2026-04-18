#!/usr/bin/env bash
# =============================================================================
# Bootstrap script for building LLVM toolchain dependencies from source
# Target: Ubuntu 16.04 (glibc 2.23) amd64
#
# Builds: GCC 14.2, CMake 3.31, Python 3.12, Ninja 1.12, SWIG 4.3,
#         zlib, zstd, libxml2, ncurses, libedit, libffi, xz/liblzma
#
# Usage: BOOTSTRAP_PREFIX=/opt/bootstrap ./scripts/bootstrap.sh
# =============================================================================
set -euo pipefail

: "${BOOTSTRAP_PREFIX:=/opt/bootstrap}"
: "${BUILD_DIR:=/tmp/bootstrap-build}"
: "${NPROC:=$(nproc)}"
: "${DOWNLOAD_DIR:=/tmp/bootstrap-downloads}"

# Component versions
GCC_VERSION=14.2.0
CMAKE_VERSION=3.31.7
PYTHON_VERSION=3.12.11
NINJA_VERSION=1.12.1
SWIG_VERSION=4.3.0
ZLIB_VERSION=1.3.1
ZSTD_VERSION=1.5.7
LIBXML2_VERSION=2.13.8
NCURSES_VERSION=6.5
LIBEDIT_VERSION=20250104-3.1
LIBFFI_VERSION=3.4.7
XZ_VERSION=5.8.1
PCRE2_VERSION=10.45

export PATH="${BOOTSTRAP_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${BOOTSTRAP_PREFIX}/lib64:${BOOTSTRAP_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="${BOOTSTRAP_PREFIX}/lib64/pkgconfig:${BOOTSTRAP_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CFLAGS="-I${BOOTSTRAP_PREFIX}/include"
export CXXFLAGS="-I${BOOTSTRAP_PREFIX}/include"
export LDFLAGS="-L${BOOTSTRAP_PREFIX}/lib64 -L${BOOTSTRAP_PREFIX}/lib -Wl,-rpath,${BOOTSTRAP_PREFIX}/lib64 -Wl,-rpath,${BOOTSTRAP_PREFIX}/lib"

mkdir -p "${BOOTSTRAP_PREFIX}" "${BUILD_DIR}" "${DOWNLOAD_DIR}"

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------
log() { echo "===> $(date '+%H:%M:%S') $*"; }

download() {
    local url="$1" dest="$2"
    if [[ ! -f "${dest}" ]]; then
        log "Downloading ${url}"
        curl -fSL --retry 3 --retry-delay 5 -o "${dest}" "${url}"
    fi
}

# Check if a component is already built (marker file)
is_built() {
    [[ -f "${BOOTSTRAP_PREFIX}/.built-$1" ]]
}

mark_built() {
    touch "${BOOTSTRAP_PREFIX}/.built-$1"
}

# -----------------------------------------------------------------------------
# 0. Install system prerequisites (apt packages available on 16.04)
# -----------------------------------------------------------------------------
install_system_deps() {
    log "Installing system dependencies via apt..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        wget \
        file \
        texinfo \
        bison \
        flex \
        gawk \
        m4 \
        patch \
        patchelf \
        libcurl4-openssl-dev \
        tar \
        xz-utils \
        bzip2 \
        unzip \
        pkg-config \
        libssl-dev \
        zlib1g-dev \
        libbz2-dev \
        libsqlite3-dev \
        libreadline-dev \
        libgdbm-dev \
        libdb-dev \
        tk-dev \
        uuid-dev \
        autoconf \
        automake \
        libtool \
        git \
        gperf
}

# -----------------------------------------------------------------------------
# 1. Build GCC 14.2 (bootstrap compiler for LLVM)
# -----------------------------------------------------------------------------
build_gcc() {
    if is_built "gcc-${GCC_VERSION}"; then
        log "GCC ${GCC_VERSION} already built, skipping"
        return
    fi
    log "Building GCC ${GCC_VERSION}..."

    local src="${BUILD_DIR}/gcc-${GCC_VERSION}"
    local build="${BUILD_DIR}/gcc-build"
    local tarball="${DOWNLOAD_DIR}/gcc-${GCC_VERSION}.tar.xz"

    download "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz" "${tarball}"

    cd "${BUILD_DIR}"
    [[ -d "${src}" ]] || tar xf "${tarball}"

    cd "${src}"
    ./contrib/download_prerequisites

    mkdir -p "${build}" && cd "${build}"
    "${src}/configure" \
        --prefix="${BOOTSTRAP_PREFIX}" \
        --enable-languages=c,c++,fortran \
        --enable-threads=posix \
        --enable-shared \
        --enable-linker-build-id \
        --disable-multilib \
        --disable-bootstrap \
        --disable-nls \
        --with-system-zlib \
        --enable-default-pie

    make -j"${NPROC}"
    make install-strip

    # Create cc symlink
    ln -sf gcc "${BOOTSTRAP_PREFIX}/bin/cc"

    mark_built "gcc-${GCC_VERSION}"
    log "GCC ${GCC_VERSION} installed to ${BOOTSTRAP_PREFIX}"

    # Update environment for subsequent builds
    export CC="${BOOTSTRAP_PREFIX}/bin/gcc"
    export CXX="${BOOTSTRAP_PREFIX}/bin/g++"
}

# -----------------------------------------------------------------------------
# 2. Build CMake 3.31
# -----------------------------------------------------------------------------
build_cmake() {
    if is_built "cmake-${CMAKE_VERSION}"; then
        log "CMake ${CMAKE_VERSION} already built, skipping"
        return
    fi
    log "Building CMake ${CMAKE_VERSION}..."

    local tarball="${DOWNLOAD_DIR}/cmake-${CMAKE_VERSION}.tar.gz"
    download "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}.tar.gz" "${tarball}"

    cd "${BUILD_DIR}"
    tar xf "${tarball}"
    cd "cmake-${CMAKE_VERSION}"

    ./bootstrap \
        --prefix="${BOOTSTRAP_PREFIX}" \
        --parallel="${NPROC}" \
        -- \
        -DCMAKE_USE_OPENSSL=ON

    make -j"${NPROC}"
    make install

    mark_built "cmake-${CMAKE_VERSION}"
    log "CMake ${CMAKE_VERSION} installed"
}

# -----------------------------------------------------------------------------
# 3. Build Ninja 1.12
# -----------------------------------------------------------------------------
build_ninja() {
    if is_built "ninja-${NINJA_VERSION}"; then
        log "Ninja ${NINJA_VERSION} already built, skipping"
        return
    fi
    log "Building Ninja ${NINJA_VERSION}..."

    local tarball="${DOWNLOAD_DIR}/ninja-${NINJA_VERSION}.tar.gz"
    download "https://github.com/ninja-build/ninja/archive/refs/tags/v${NINJA_VERSION}.tar.gz" "${tarball}"

    cd "${BUILD_DIR}"
    tar xf "${tarball}"
    cd "ninja-${NINJA_VERSION}"

    cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${BOOTSTRAP_PREFIX}"
    cmake --build build -j"${NPROC}"
    cmake --install build

    mark_built "ninja-${NINJA_VERSION}"
    log "Ninja ${NINJA_VERSION} installed"
}

# -----------------------------------------------------------------------------
# 4. Build Python 3.12 (needed for LLDB scripting + SWIG bindings)
# -----------------------------------------------------------------------------
build_python() {
    if is_built "python-${PYTHON_VERSION}"; then
        log "Python ${PYTHON_VERSION} already built, skipping"
        return
    fi
    log "Building Python ${PYTHON_VERSION}..."

    local tarball="${DOWNLOAD_DIR}/Python-${PYTHON_VERSION}.tar.xz"
    download "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz" "${tarball}"

    cd "${BUILD_DIR}"
    tar xf "${tarball}"
    cd "Python-${PYTHON_VERSION}"

    # Build Python as shared library (required for LLDB embedding)
    ./configure \
        --prefix="${BOOTSTRAP_PREFIX}" \
        --enable-shared \
        --enable-optimizations \
        --with-lto \
        --with-ensurepip=install \
        --with-system-ffi \
        LDFLAGS="-L${BOOTSTRAP_PREFIX}/lib64 -L${BOOTSTRAP_PREFIX}/lib -Wl,-rpath,${BOOTSTRAP_PREFIX}/lib64 -Wl,-rpath,${BOOTSTRAP_PREFIX}/lib"

    make -j"${NPROC}"
    make install

    # Create python3 -> python symlink if missing
    [[ -f "${BOOTSTRAP_PREFIX}/bin/python3" ]] || ln -sf python3.12 "${BOOTSTRAP_PREFIX}/bin/python3"

    mark_built "python-${PYTHON_VERSION}"
    log "Python ${PYTHON_VERSION} installed"
}

# -----------------------------------------------------------------------------
# 5. Build SWIG 4.3 (needed for LLDB Python bindings)
# -----------------------------------------------------------------------------
build_swig() {
    if is_built "swig-${SWIG_VERSION}"; then
        log "SWIG ${SWIG_VERSION} already built, skipping"
        return
    fi
    log "Building SWIG ${SWIG_VERSION}..."

    local tarball="${DOWNLOAD_DIR}/swig-${SWIG_VERSION}.tar.gz"
    # Use release tarball (includes pre-generated configure), NOT GitHub archive
    download "https://github.com/swig/swig/releases/download/v${SWIG_VERSION}/swig-${SWIG_VERSION}.tar.gz" "${tarball}"

    cd "${BUILD_DIR}"
    tar xf "${tarball}"
    cd "swig-${SWIG_VERSION}"

    # SWIG requires PCRE2
    if ! is_built "pcre2-${PCRE2_VERSION}"; then
        build_pcre2
    fi

    ./configure \
        --prefix="${BOOTSTRAP_PREFIX}" \
        --with-pcre2-prefix="${BOOTSTRAP_PREFIX}"

    make -j"${NPROC}"
    make install

    mark_built "swig-${SWIG_VERSION}"
    log "SWIG ${SWIG_VERSION} installed"
}

build_pcre2() {
    log "Building PCRE2 ${PCRE2_VERSION}..."

    local tarball="${DOWNLOAD_DIR}/pcre2-${PCRE2_VERSION}.tar.bz2"
    download "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.bz2" "${tarball}"

    cd "${BUILD_DIR}"
    tar xf "${tarball}"
    cd "pcre2-${PCRE2_VERSION}"

    cmake -G Ninja -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${BOOTSTRAP_PREFIX}" \
        -DBUILD_SHARED_LIBS=ON \
        -DPCRE2_BUILD_PCRE2GREP=OFF \
        -DPCRE2_BUILD_TESTS=OFF

    cmake --build build -j"${NPROC}"
    cmake --install build

    mark_built "pcre2-${PCRE2_VERSION}"
    log "PCRE2 ${PCRE2_VERSION} installed"
}

# -----------------------------------------------------------------------------
# 6. Build shared library dependencies for LLVM/LLDB
# -----------------------------------------------------------------------------
build_zlib() {
    if is_built "zlib-${ZLIB_VERSION}"; then return; fi
    log "Building zlib ${ZLIB_VERSION}..."

    local tarball="${DOWNLOAD_DIR}/zlib-${ZLIB_VERSION}.tar.xz"
    download "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.xz" "${tarball}"

    cd "${BUILD_DIR}"
    tar xf "${tarball}"
    cd "zlib-${ZLIB_VERSION}"

    cmake -G Ninja -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${BOOTSTRAP_PREFIX}" \
        -DBUILD_SHARED_LIBS=ON

    cmake --build build -j"${NPROC}"
    cmake --install build

    mark_built "zlib-${ZLIB_VERSION}"
}

build_zstd() {
    if is_built "zstd-${ZSTD_VERSION}"; then return; fi
    log "Building zstd ${ZSTD_VERSION}..."

    local tarball="${DOWNLOAD_DIR}/zstd-${ZSTD_VERSION}.tar.gz"
    download "https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz" "${tarball}"

    cd "${BUILD_DIR}"
    tar xf "${tarball}"
    cd "zstd-${ZSTD_VERSION}"

    cmake -G Ninja -B build/cmake -S build/cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${BOOTSTRAP_PREFIX}" \
        -DBUILD_SHARED_LIBS=ON \
        -DZSTD_BUILD_PROGRAMS=OFF \
        -DZSTD_BUILD_TESTS=OFF

    cmake --build build/cmake -j"${NPROC}"
    cmake --install build/cmake

    mark_built "zstd-${ZSTD_VERSION}"
}

build_libxml2() {
    if is_built "libxml2-${LIBXML2_VERSION}"; then return; fi
    log "Building libxml2 ${LIBXML2_VERSION}..."

    local tarball="${DOWNLOAD_DIR}/libxml2-${LIBXML2_VERSION}.tar.xz"
    download "https://download.gnome.org/sources/libxml2/2.13/libxml2-${LIBXML2_VERSION}.tar.xz" "${tarball}"

    cd "${BUILD_DIR}"
    tar xf "${tarball}"
    cd "libxml2-${LIBXML2_VERSION}"

    cmake -G Ninja -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${BOOTSTRAP_PREFIX}" \
        -DBUILD_SHARED_LIBS=ON \
        -DLIBXML2_WITH_PYTHON=OFF \
        -DLIBXML2_WITH_TESTS=OFF \
        -DLIBXML2_WITH_LZMA=ON \
        -DLIBXML2_WITH_ZLIB=ON \
        -DLIBXML2_WITH_ICU=OFF

    cmake --build build -j"${NPROC}"
    cmake --install build

    mark_built "libxml2-${LIBXML2_VERSION}"
}

build_ncurses() {
    if is_built "ncurses-${NCURSES_VERSION}"; then return; fi
    log "Building ncurses ${NCURSES_VERSION}..."

    local tarball="${DOWNLOAD_DIR}/ncurses-${NCURSES_VERSION}.tar.gz"
    download "https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VERSION}.tar.gz" "${tarball}"

    cd "${BUILD_DIR}"
    tar xf "${tarball}"
    cd "ncurses-${NCURSES_VERSION}"

    ./configure \
        --prefix="${BOOTSTRAP_PREFIX}" \
        --with-shared \
        --with-cxx-shared \
        --without-debug \
        --without-ada \
        --enable-widec \
        --enable-overwrite \
        --enable-pc-files \
        --with-pkg-config-libdir="${BOOTSTRAP_PREFIX}/lib/pkgconfig"

    make -j"${NPROC}"
    make install

    # Create non-wide symlinks (many programs expect -lncurses not -lncursesw)
    for lib in ncurses form panel menu; do
        ln -sf "lib${lib}w.so" "${BOOTSTRAP_PREFIX}/lib/lib${lib}.so"
        ln -sf "${lib}w.pc" "${BOOTSTRAP_PREFIX}/lib/pkgconfig/${lib}.pc"
    done
    ln -sf "libncursesw.so" "${BOOTSTRAP_PREFIX}/lib/libcurses.so"

    mark_built "ncurses-${NCURSES_VERSION}"
}

build_libedit() {
    if is_built "libedit-${LIBEDIT_VERSION}"; then return; fi
    log "Building libedit ${LIBEDIT_VERSION}..."

    local tarball="${DOWNLOAD_DIR}/libedit-${LIBEDIT_VERSION}.tar.gz"
    download "https://thrysoee.dk/editline/libedit-${LIBEDIT_VERSION}.tar.gz" "${tarball}"

    cd "${BUILD_DIR}"
    tar xf "${tarball}"
    cd libedit-${LIBEDIT_VERSION}

    ./configure \
        --prefix="${BOOTSTRAP_PREFIX}" \
        --enable-shared \
        --disable-static

    make -j"${NPROC}"
    make install

    mark_built "libedit-${LIBEDIT_VERSION}"
}

build_libffi() {
    if is_built "libffi-${LIBFFI_VERSION}"; then return; fi
    log "Building libffi ${LIBFFI_VERSION}..."

    local tarball="${DOWNLOAD_DIR}/libffi-${LIBFFI_VERSION}.tar.gz"
    download "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz" "${tarball}"

    cd "${BUILD_DIR}"
    tar xf "${tarball}"
    cd "libffi-${LIBFFI_VERSION}"

    ./configure \
        --prefix="${BOOTSTRAP_PREFIX}" \
        --enable-shared \
        --disable-static

    make -j"${NPROC}"
    make install

    mark_built "libffi-${LIBFFI_VERSION}"
}

build_xz() {
    if is_built "xz-${XZ_VERSION}"; then return; fi
    log "Building xz/liblzma ${XZ_VERSION}..."

    local tarball="${DOWNLOAD_DIR}/xz-${XZ_VERSION}.tar.xz"
    download "https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.xz" "${tarball}"

    cd "${BUILD_DIR}"
    tar xf "${tarball}"
    cd "xz-${XZ_VERSION}"

    cmake -G Ninja -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${BOOTSTRAP_PREFIX}" \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_TESTING=OFF

    cmake --build build -j"${NPROC}"
    cmake --install build

    mark_built "xz-${XZ_VERSION}"
}

# -----------------------------------------------------------------------------
# Main build sequence
# -----------------------------------------------------------------------------
main() {
    log "Bootstrap build starting"
    log "  PREFIX: ${BOOTSTRAP_PREFIX}"
    log "  BUILD:  ${BUILD_DIR}"
    log "  NPROC:  ${NPROC}"

    install_system_deps

    # Build order matters: GCC first (compiler), then CMake+Ninja (build system),
    # then library deps (needed by Python and LLVM), then Python, then SWIG
    build_gcc

    # Update CC/CXX to use new GCC
    export CC="${BOOTSTRAP_PREFIX}/bin/gcc"
    export CXX="${BOOTSTRAP_PREFIX}/bin/g++"
    hash -r

    build_cmake
    build_ninja

    # Library dependencies (order: zlib before libxml2, ncurses before libedit)
    build_zlib
    build_zstd
    build_xz
    build_libffi
    build_ncurses
    build_libedit
    build_libxml2

    # Python needs libffi, zlib, xz, ncurses
    build_python

    # SWIG needs PCRE2 and Python
    build_swig

    log "Bootstrap complete! All tools installed to ${BOOTSTRAP_PREFIX}"
    log "Add to PATH: export PATH=${BOOTSTRAP_PREFIX}/bin:\$PATH"

    # Print versions
    log "Installed versions:"
    "${BOOTSTRAP_PREFIX}/bin/gcc" --version | head -1
    "${BOOTSTRAP_PREFIX}/bin/cmake" --version | head -1
    "${BOOTSTRAP_PREFIX}/bin/ninja" --version
    "${BOOTSTRAP_PREFIX}/bin/python3" --version
    "${BOOTSTRAP_PREFIX}/bin/swig" -version | grep "SWIG Version"
}

main "$@"

