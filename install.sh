#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

WPEWEBKIT_VERSION="2.52.4"
WPEBACKEND_FDO_VERSION="1.16.1"
LIBWPE_VERSION="1.16.3"
COG_VERSION="0.18.5"

WPEWEBKIT="wpewebkit-$WPEWEBKIT_VERSION"
WPEBACKEND_FDO="wpebackend-fdo-$WPEBACKEND_FDO_VERSION"
LIBWPE="libwpe-$LIBWPE_VERSION"
COG="cog-$COG_VERSION"

JOBS=$(nproc)
PREFIX="/opt/wpe-tarballs"
LDCONF="/etc/ld.so.conf.d/wpe-tarballs.conf"

CACHE_DIR="/var/cache/wpe-tarballs"

DEPS_ONLY=false
SKIP_DEPS=false
UNINSTALL=false
CLEAR_CACHE=false

while [[ $# -gt 0 ]]; do
    case $1 in
    -j | --jobs)
        JOBS="$2"
        shift # past argument
        shift # past value
        ;;
    --deps-only)
        DEPS_ONLY=true
        shift
        ;;
    --skip-deps)
        SKIP_DEPS=true
        shift
        ;;
    -u | --uninstall)
        UNINSTALL=true
        shift
        ;;
    -cc | --clear-cache)
        CLEAR_CACHE=true
        shift
        ;;
    *)
        # ignore
        shift
        ;;
    esac
done

# Helpful during the staged build
# especially if pkg-config on the system does not search /usr/local/lib/pkgconfig by default.
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"

# CMake Ninja build status
export NINJA_STATUS="[%p](%f/%t) "

info() {
    printf '\033[1m%s\033[0m\n' "$*"
}

noti() {
    printf '\033[1;34m::\033[1;37m %s\033[0m\n' "$*" >&2
    sleep 1
}

step() {
    printf '\033[1;32m==>\033[1;37m %s\033[0m\n' "$*" >&2
    sleep .5
}

warn() {
    printf '\033[1;33m==> WARNING:\033[1;37m %s\033[0m\n' "$*" >&2
    sleep .5
}

ask_yn() {
    read -p $'\033[1;34m::\033[1;37m '"$*"$' [Y/n]:\033[0m ' yesno
    echo
    case $yesno in
    [Nn]*) return 1 ;;
    [Yy]* | *) return 0 ;;
    esac
}

die() {
    printf '\033[1;31m==> ERROR: \033[1;37m%s\033[0m\n\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

install_build_deps() {
    noti "Installing build dependencies"

    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        step "Detected OS: ${PRETTY_NAME:-unknown}"
    fi

    if $SKIP_DEPS; then
        step "SKIP_DEPS set to true. Skipping dependency installation..."
        return
    fi

    local deps=(
        build-essential
        clang
        cmake
        ccache
        lld
        ninja-build
        meson
        pkg-config
        python3
        ruby
        gperf
        bison
        flex
        git
        curl
        ca-certificates
        xz-utils
        gi-docgen
        gobject-introspection
        libgirepository1.0-dev
        libglib2.0-dev
        libegl1-mesa-dev
        libgles2-mesa-dev
        libgl1-mesa-dev
        libgtk-4-dev
        libepoxy-dev
        libdrm-dev
        libgbm-dev
        libwayland-dev
        wayland-protocols
        libxkbcommon-dev
        libinput-dev
        libudev-dev
        libcairo2-dev
        libsystemd-dev
        libsoup-3.0-dev
        libxml2-dev
        libxml2-utils
        libxslt1-dev
        libsqlite3-dev
        libicu-dev
        libgcrypt20-dev
        libgpg-error-dev
        libtasn1-6-dev
        libseccomp-dev
        bubblewrap
        xdg-dbus-proxy
        libfontconfig-dev
        libfreetype-dev
        libharfbuzz-dev
        libhyphen-dev
        libjpeg-dev
        libpng-dev
        libwebp-dev
        libavif-dev
        libjxl-dev
        libopenjp2-7-dev
        liblcms2-dev
        libwoff-dev
        libwoff1
        unifdef
        libatk1.0-dev
        libatk-bridge2.0-dev
        libgstreamer1.0-dev
        libgstreamer-plugins-base1.0-dev
        gstreamer1.0-plugins-base
        gstreamer1.0-plugins-good
        gstreamer1.0-plugins-bad
        gstreamer1.0-libav
        shared-mime-info
        fonts-dejavu-core
        fonts-liberation
        fonts-noto-core
        weston
    )

    sudo apt update -y

    # Helps avoid exact-version runtime/-dev mismatches on Ubuntu.
    sudo apt full-upgrade -y
    sudo apt --fix-broken install -y

    sudo apt install -y "${deps[@]}"
}

download_tarball() {
    local file="$1"
    local url="https://wpewebkit.org/releases/$file"

    mkdir -p "$CACHE_DIR"
    cd "$CACHE_DIR"

    if [[ -f "$file" ]]; then
        step "Using existing $file"
    else
        step "Downloading $file"
        curl -fLO "$url"
    fi
}

extract_clean() {
    local archive="$1"
    local dir="$2"

    cd "$CACHE_DIR"

    step "Extracting $archive"

    rm -rf "$dir"
    tar -xf "$archive"
}

build_meson_project() {
    local meson_options=(
        --prefix="$PREFIX"
        --libdir=lib
        --buildtype=release
    )

    local dir="$1"

    if [[ "$#" -gt 1 ]]; then
        shift
        meson_options+=("$@")
    fi

    cd "$CACHE_DIR/$dir"

    step "Configuring $dir"
    meson setup _build "${meson_options[@]}"

    echo
    step "Building $dir"
    meson compile -C _build

    echo
    step "Installing $dir"
    sudo meson install -C _build
    sudo ldconfig
}

build_wpewebkit() {
    local cmake_options=(
        -D CMAKE_BUILD_TYPE=Release
        -D CMAKE_INSTALL_LIBDIR=lib
        -D CMAKE_INSTALL_LIBEXECDIR=lib
        -D CMAKE_INSTALL_PREFIX="$PREFIX"
        -D CMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld"
        -D CMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld"
        -D CMAKE_MODULE_LINKER_FLAGS="-fuse-ld=lld"
        -D ENABLE_MINIBROWSER=ON
        -D ENABLE_WPE_PLATFORM=ON
        -D ENABLE_DOCUMENTATION=OFF
        -D ENABLE_SPEECH_SYNTHESIS=OFF
        -D USE_FLITE=OFF
        -D USE_LIBBACKTRACE=OFF
        -D PORT=WPE
    )

    local dir="wpewebkit-$WPEWEBKIT_VERSION"

    cd "$CACHE_DIR/$dir"

    step "Configuring $dir"
    step "Using clang/clang++ and lld to reduce final-link memory pressure"
    CC=clang CXX=clang++ cmake -S . -B _build -G Ninja "${cmake_options[@]}"

    echo
    step "Building $dir (JOBS: $JOBS)"
    cmake --build _build --parallel "$JOBS"

    echo
    step "Installing $dir"
    sudo cmake --install _build
    sudo ldconfig
}

verify_installation() {
    noti "Verifying installation"

    echo
    info "Commands:"
    command -v cog || true
    command -v cogctl || true
    command -v WPEWebDriver || true

    echo
    info "pkg-config versions:"
    pkg-config --modversion wpe-1.0
    pkg-config --modversion wpebackend-fdo-1.0
    pkg-config --modversion wpe-webkit-2.0

    echo
    info "Dynamic linker cache:"
    ldconfig -p | grep -Ei 'wpe|webkit' || true

    echo
    info "Installed WPE-related files under $PREFIX:"
    find "$PREFIX" -path "$PREFIX/share/doc" -prune -o \
        -type f \
        \( -path "$PREFIX/bin/*" -o -ipath "$PREFIX/lib/*" -o -path "$PREFIX/share/*" \) \
        -print 2>/dev/null | sort || true
}

uninstall_wpe() {
    echo
    ask_yn "Continue uninstalling WPEWebKit?" || return 1

    noti "Uninstalling WPE..."

    sudo rm -fv /usr/local/bin/cog
    sudo rm -fv /usr/local/bin/cogctl
    sudo rm -fv /usr/local/bin/WPEWebDriver

    sudo rm -rfv "$PREFIX"

    sudo rm -fv "$LDCONF"
    sudo ldconfig

    echo
    noti "Successfully Uninstalled."
    echo
}

clear_cache() {
    echo
    ask_yn "Do you wish to delete ALL files from cache($CACHE_DIR)?" || return 1

    noti "Deleting files in $CACHE_DIR..."

    sudo rm -rfv "$CACHE_DIR"
    echo
}

main() {
    echo -e '\033[0;32m'
    cat <<EOF
============================================================
 WPEWebKit tarball installer
============================================================
Prefix:      $PREFIX
Cache dir:   $CACHE_DIR
Jobs:        $JOBS

Versions:
  libwpe:          $LIBWPE_VERSION
  wpebackend-fdo:  $WPEBACKEND_FDO_VERSION
  wpewebkit:       $WPEWEBKIT_VERSION
  cog:             $COG_VERSION
EOF
    echo -e '\033[0m'

    if $CLEAR_CACHE; then
        clear_cache || die "Aborted."
        exit
    fi

    if $UNINSTALL; then
        uninstall_wpe || die "Aborted."
        clear_cache || true
        exit
    fi

    install_build_deps

    if $DEPS_ONLY; then
        exit
    fi

    need curl
    need tar
    need meson
    need cmake
    need ninja
    need clang
    need clang++
    need ld.lld
    need pkg-config

    echo
    noti "Retrieving tarballs"
    download_tarball "$LIBWPE.tar.xz"
    download_tarball "$WPEBACKEND_FDO.tar.xz"
    download_tarball "$WPEWEBKIT.tar.xz"
    download_tarball "$COG.tar.xz"

    echo
    noti "Building libwpe"
    extract_clean "$LIBWPE.tar.xz" "$LIBWPE"
    build_meson_project "$LIBWPE"

    echo
    noti "Building WPEBackend-fdo"
    extract_clean "$WPEBACKEND_FDO.tar.xz" "$WPEBACKEND_FDO"
    build_meson_project "$WPEBACKEND_FDO"

    echo
    noti "Building WPEWebKit"
    extract_clean "$WPEWEBKIT.tar.xz" "$WPEWEBKIT"
    build_wpewebkit
    sudo ln -sf "$PREFIX/bin/WPEWebDriver" /usr/local/bin/WPEWebDriver

    echo
    noti "Building Cog"
    extract_clean "$COG.tar.xz" "$COG"
    build_meson_project "$COG" -Dplatforms=wayland,gtk4,headless,drm
    sudo ln -sf "$PREFIX/bin/cog" /usr/local/bin/cog
    sudo ln -sf "$PREFIX/bin/cogctl" /usr/local/bin/cogctl

    echo "$PREFIX/lib" | sudo tee "$LDCONF" >/dev/null 2>&1
    sudo ldconfig

    cd / # To work around the "sh: 0: getcwd() failed: No such file or directory" error after clearing the cache

    clear_cache || true

    verify_installation

    echo -e '\033[0;32m'
    cat <<EOF
============================================================
 Installation complete
============================================================

Try:
  cog https://wpewebkit.org

Or:
  $PREFIX/lib/wpe-webkit-2.0/MiniBrowser https://wpewebkit.org
EOF
    echo -e '\033[0m'
}

main "$@"
