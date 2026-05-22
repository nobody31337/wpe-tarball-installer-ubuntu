#!/usr/bin/env bash
set -euo pipefail

PREFIX="/opt/wpe"
SRCDIR="$HOME/tmp/wpe-tarballs"

JOBS=$(nproc)

WPEWEBKIT_VERSION="2.52.3"
WPEBACKEND_FDO_VERSION="1.16.1"
LIBWPE_VERSION="1.16.3"
COG_VERSION="0.18.5"

WPEWEBKIT="wpewebkit-$WPEWEBKIT_VERSION"
WPEBACKEND_FDO="wpebackend-fdo-$WPEBACKEND_FDO_VERSION"
LIBWPE="libwpe-$LIBWPE_VERSION"
COG="cog-$COG_VERSION"

TEST=false
NO_APT=false
UNINSTALL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -j|--jobs)
      JOBS="$2"
      shift # past argument
      shift # past value
      ;;
    --test)
      TEST=true
      CURDIR=$(dirname "$(readlink -f "$0")")
      PREFIX="$CURDIR/~tmp/usr"
      SRCDIR="$CURDIR/~tmp/tarballs"
      shift
      ;;
    --no-apt)
      NO_APT=true
      shift
      ;;
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    esac
done

# Helpful during the staged build
# especially if pkg-config on the system does not search /usr/local/lib/pkgconfig by default.
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

install_build_dependencies_ubuntu() {
  echo "==> Installing build dependencies"

  if $NO_APT; then
    echo "NO_APT set to true. Skipping dependency installation..."
    return
  fi

  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "Detected OS: ${PRETTY_NAME:-unknown}"
  fi

  local dependencies=(
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

  sudo apt install -y "${dependencies[@]}"
}

download_tarball() {
  local file="$1"
  local url="https://wpewebkit.org/releases/$file"

  mkdir -p "$SRCDIR"
  cd "$SRCDIR"

  if [[ -f "$file" ]]; then
    echo "==> Using existing $file"
  else
    echo "==> Downloading $file"
    curl -fLO "$url"
  fi
}

extract_clean() {
  local archive="$1"
  local dir="$2"

  cd "$SRCDIR"

  echo "==> Extracting $archive"
  rm -rf "$dir"
  tar -xf "$archive"
}

build_meson_project() {
  local dir="$1"

  cd "$SRCDIR/$dir"

  echo "==> Configuring $dir"
  sleep 0.5
  meson setup _build \
    --prefix="$PREFIX" \
    --libdir=lib \
    --buildtype=release

  echo "==> Building $dir"
  sleep 0.5
  meson compile -C _build

  echo "==> Installing $dir"
  sleep 0.5
  sudo meson install -C _build
  sudo ldconfig
}

build_wpewebkit() {
  local dir="wpewebkit-$WPEWEBKIT_VERSION"

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
    -D ENABLE_DOCUMENTATION=ON
    -D ENABLE_SPEECH_SYNTHESIS=OFF
    -D USE_FLITE=OFF
    -D USE_LIBBACKTRACE=OFF
    -D PORT=WPE
  )

  cd "$SRCDIR/$dir"

  echo "==> Configuring $dir"
  echo "    Using clang/clang++ and lld to reduce final-link memory pressure"
  sleep 1

  CC=clang CXX=clang++ cmake -S . -B _build -G Ninja "${cmake_options[@]}"

  echo "==> Building $dir with JOBS=$JOBS"
  sleep 0.5
  cmake --build _build --parallel "$JOBS"

  echo "==> Installing $dir"
  sleep 0.5
  sudo cmake --install _build
  sudo ldconfig
}

verify_installation() {
  echo
  echo "==> Verifying installation"

  echo
  echo "Commands:"
  command -v cog || true
  command -v cogctl || true
  command -v WPEWebDriver || true

  echo
  echo "pkg-config versions:"
  pkg-config --modversion wpe-1.0
  pkg-config --modversion wpebackend-fdo-1.0
  pkg-config --modversion wpe-webkit-2.0

  echo
  echo "Dynamic linker cache:"
  ldconfig -p | grep -Ei 'wpe|webkit' || true

  echo
  echo "Installed WPE-related files under $PREFIX:"
  find "$PREFIX" \
    \( -path "$PREFIX/bin/*" -o -path "$PREFIX/lib/wpe-webkit-2.0/*" -o -path "$PREFIX/lib/pkgconfig/*wpe*" \) \
    -print 2>/dev/null | sort || true
}

uninstall_wpe() {
  echo "Uninstalling WPE..."

  sudo rm -fv /usr/local/bin/cog
  sudo rm -fv /usr/local/bin/cogctl
  sudo rm -fv /usr/local/bin/WPEWebDriver

  sudo rm -fv /etc/ld.so.conf.d/wpe.conf
  sudo ldconfig

  sudo rm -rfv "$PREFIX"
  sudo rm -rfv "$SRCDIR"

  echo "Successfully Uninstalled."
}

main() {
  echo "============================================================"
  echo " WPEWebKit tarball installer"
  echo "============================================================"
  echo "Prefix:      $PREFIX"
  echo "Source dir:  $SRCDIR"
  echo "Jobs:        $JOBS"
  echo
  echo "Versions:"
  echo "  libwpe:          $LIBWPE_VERSION"
  echo "  wpebackend-fdo:  $WPEBACKEND_FDO_VERSION"
  echo "  wpewebkit:       $WPEWEBKIT_VERSION"
  echo "  cog:             $COG_VERSION"
  echo

  if $UNINSTALL; then
    uninstall_wpe
    exit
  fi

  echo "$PREFIX/lib" | sudo tee /etc/ld.so.conf.d/wpe.conf >/dev/null 2>&1
  sudo ldconfig

  install_build_dependencies_ubuntu

  require_command curl
  require_command tar
  require_command meson
  require_command cmake
  require_command ninja
  require_command clang
  require_command clang++
  require_command ld.lld
  require_command pkg-config

  echo
  echo "==> Retrieving tarballs"
  download_tarball "$LIBWPE.tar.xz"
  download_tarball "$WPEBACKEND_FDO.tar.xz"
  download_tarball "$WPEWEBKIT.tar.xz"
  download_tarball "$COG.tar.xz"

  echo
  echo "==> Building libwpe"
  sleep 0.5
  extract_clean "$LIBWPE.tar.xz" "$LIBWPE"
  build_meson_project "$LIBWPE"

  echo
  echo "==> Building WPEBackend-fdo"
  sleep 0.5
  extract_clean "$WPEBACKEND_FDO.tar.xz" "$WPEBACKEND_FDO"
  build_meson_project "$WPEBACKEND_FDO"

  echo
  echo "==> Building WPEWebKit"
  sleep 0.5
  extract_clean "$WPEWEBKIT.tar.xz" "$WPEWEBKIT"
  build_wpewebkit
  sudo ln -sf "$PREFIX/bin/WPEWebDriver" /usr/local/bin/WPEWebDriver

  echo
  echo "==> Building Cog"
  sleep 0.5
  extract_clean "$COG.tar.xz" "$COG"
  build_meson_project "$COG"
  sudo ln -sf "$PREFIX/bin/cog" /usr/local/bin/cog
  sudo ln -sf "$PREFIX/bin/cogctl" /usr/local/bin/cogctl

  verify_installation

  echo
  echo "============================================================"
  echo " Installation complete"
  echo "============================================================"
  echo
  echo "Try:"
  echo "  cog https://wpewebkit.org"
  echo
  echo "Or:"
  echo "  $PREFIX/lib/wpe-webkit-2.0/MiniBrowser https://wpewebkit.org"
}

main "$@"
