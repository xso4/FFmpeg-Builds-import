#!/bin/bash
set -xe
shopt -s globstar
cd "$(dirname "$0")"
source util/vars.sh

source "variants/${TARGET}-${VARIANT}.sh"

for addin in ${ADDINS[*]}; do
    source "addins/${addin}.sh"
done

if docker info -f "{{println .SecurityOptions}}" | grep rootless >/dev/null 2>&1; then
    UIDARGS=()
else
    UIDARGS=( -u "$(id -u):$(id -g)" )
fi

rm -rf ffbuild
mkdir ffbuild

FFMPEG_REPO="${FFMPEG_REPO:-https://github.com/FFmpeg/FFmpeg.git}"
FFMPEG_REPO="${FFMPEG_REPO_OVERRIDE:-$FFMPEG_REPO}"
GIT_BRANCH="${GIT_BRANCH:-master}"
GIT_BRANCH="${GIT_BRANCH_OVERRIDE:-$GIT_BRANCH}"

BUILD_SCRIPT="$(mktemp)"
trap "rm -f -- '$BUILD_SCRIPT'" EXIT

cat <<EOF >"$BUILD_SCRIPT"
    set -xe
    cd /ffbuild
    rm -rf ffmpeg prefix

    git clone --filter=blob:none --branch='$GIT_BRANCH' '$FFMPEG_REPO' ffmpeg
    cd ffmpeg

    ./configure --prefix=/ffbuild/prefix --pkg-config-flags="--static" \$FFBUILD_TARGET_FLAGS \$FF_CONFIGURE \
        --extra-cflags="\$FF_CFLAGS" --extra-cxxflags="\$FF_CXXFLAGS" --extra-libs="\$FF_LIBS" \
        --extra-ldflags="\$FF_LDFLAGS" --extra-ldexeflags="\$FF_LDEXEFLAGS" \
        --cc="\$CC" --cxx="\$CXX" --ar="\$AR" --ranlib="\$RANLIB" --nm="\$NM" \
        --extra-version="\$(date +%Y%m%d)"
    make -j\$(nproc) V=1
    make install install-doc
    DOC_DIR="/ffbuild/prefix/share/doc/ffmpeg"
    echo "Checking DOC_DIR: \$DOC_DIR"
    if [ -d "\$DOC_DIR" ]; then
        echo "DOC_DIR exists. Listing content:"
        ls -F "\$DOC_DIR"
        if ! command -v doxygen >/dev/null 2>&1; then
            echo "Doxygen not found. Attempting installation..."
            if [ "\$(id -u)" -eq 0 ]; then
                echo "Running as root. Installing via apt..."
                apt-get -y update
                apt-get -y install --no-install-recommends doxygen graphviz
            else
                echo "Not root. Downloading static doxygen..."
                DOXYGEN_VER="1.10.0"
                wget -q -O doxygen.tar.gz "https://www.doxygen.nl/files/doxygen-\${DOXYGEN_VER}.linux.bin.tar.gz"
                if [ -f doxygen.tar.gz ]; then
                    tar -xf doxygen.tar.gz
                    export PATH="\$PWD/doxygen-\${DOXYGEN_VER}/bin:\$PATH"
                fi
            fi
        fi
        if command -v doxygen >/dev/null 2>&1; then
             echo "Generating API documentation..."
             make apidoc
             if [ -d "doc/doxy/html" ]; then
                 mkdir -p "\$DOC_DIR/api"
                 cp -r doc/doxy/html/* "\$DOC_DIR/api"
             else
                 echo "API documentation generation failed or output not found."
             fi
        fi
        # Try to install pandoc if missing, or download static binary
        if ! command -v pandoc >/dev/null 2>&1; then
            echo "Pandoc not found. Attempting installation..."
            if [ "\$(id -u)" -eq 0 ]; then
                echo "Running as root. Installing via apt..."
                apt-get -y update
                apt-get -y install --no-install-recommends pandoc
            else
                echo "Not root (UID: \$(id -u)). Downloading static pandoc..."
                PANDOC_VER="3.8.3"
                ARCH="\$(uname -m)"
                PANDOC_ARCH=""
                if [ "\$ARCH" = "x86_64" ]; then PANDOC_ARCH="amd64"; 
                elif [ "\$ARCH" = "aarch64" ]; then PANDOC_ARCH="arm64"; fi
                if [ -n "\$PANDOC_ARCH" ]; then
                    echo "Downloading pandoc-\${PANDOC_VER}-linux-\${PANDOC_ARCH}.tar.gz ..."
                    wget -q -O pandoc.tar.gz "https://github.com/jgm/pandoc/releases/download/\${PANDOC_VER}/pandoc-\${PANDOC_VER}-linux-\${PANDOC_ARCH}.tar.gz"
                    if [ -f pandoc.tar.gz ]; then
                        echo "Download successful. Extracting..."
                        tar -xf pandoc.tar.gz
                        export PATH="\$PWD/pandoc-\${PANDOC_VER}/bin:\$PATH"
                        echo "Pandoc path updated: \$(command -v pandoc)"
                        pandoc --version | head -n 1
                    else
                        echo "Download failed!"
                    fi
                else
                     echo "Unsupported architecture for static pandoc: \$ARCH"
                fi
            fi
        else
            echo "Pandoc already installed: \$(command -v pandoc)"
        fi
        if command -v pandoc >/dev/null 2>&1; then
            echo "Starting HTML to Markdown/Text conversion..."
            find "\$DOC_DIR" -type f -name "*.html" -print0 | while IFS= read -r -d "" html; do
                base="\$(basename "\$html" .html)"
                dir="\$(dirname "\$html")"
                echo "Converting \$base.html -> \$base.md / \$base.txt"
                pandoc -f html -t markdown "\$html" -o "\$dir/\$base.md"
                pandoc -f html -t plain "\$html" -o "\$dir/\$base.txt"
            done
        else
            echo "Pandoc command not found, skipping Markdown/Text generation."
        fi
        if command -v makeinfo >/dev/null 2>&1; then
            echo "Starting Texi to Text conversion..."
            for texi in doc/*.texi; do
                [ -f "\$texi" ] || continue
                base="\$(basename "\$texi" .texi)"
                echo "Converting \$base.texi -> \$base.txt"
                makeinfo --force --no-headers -o "\$DOC_DIR/\$base.txt" "\$texi"
            done
        else
            echo "makeinfo command not found, skipping Text generation."
        fi
        echo "Final DOC_DIR content:"
        ls -F "\$DOC_DIR"
        # Cleanup if we downloaded
        if [ -n "\$PANDOC_VER" ] && [ -d "pandoc-\${PANDOC_VER}" ]; then
            rm -rf "pandoc-\${PANDOC_VER}" pandoc.tar.gz
        fi
        if [ -n "\$DOXYGEN_VER" ] && [ -d "doxygen-\${DOXYGEN_VER}" ]; then
            rm -rf "doxygen-\${DOXYGEN_VER}" doxygen.tar.gz
        fi
        # Cleanup if we installed via apt
        if [ "\$(id -u)" -eq 0 ]; then
             apt-get -y purge pandoc doxygen graphviz || true
             apt-get -y autoremove
             apt-get -y clean
             rm -rf /var/lib/apt/lists/*
        fi
    else
        echo "DOC_DIR \$DOC_DIR does not exist! Skipping doc generation."
    fi
EOF

[[ -t 1 ]] && TTY_ARG="-t" || TTY_ARG=""

docker run --rm -i $TTY_ARG "${UIDARGS[@]}" -v "$PWD/ffbuild":/ffbuild -v "$BUILD_SCRIPT":/build.sh "$IMAGE" bash /build.sh

if [[ -n "$FFBUILD_OUTPUT_DIR" ]]; then
    mkdir -p "$FFBUILD_OUTPUT_DIR"
    package_variant ffbuild/prefix "$FFBUILD_OUTPUT_DIR"
    [[ -n "$LICENSE_FILE" ]] && cp "ffbuild/ffmpeg/$LICENSE_FILE" "$FFBUILD_OUTPUT_DIR/LICENSE.txt"
    rm -rf ffbuild
    exit 0
fi

mkdir -p artifacts
ARTIFACTS_PATH="$PWD/artifacts"
BUILD_NAME="ffmpeg-$(./ffbuild/ffmpeg/ffbuild/version.sh ffbuild/ffmpeg)-${TARGET}-${VARIANT}${ADDINS_STR:+-}${ADDINS_STR}"

mkdir -p "ffbuild/pkgroot/$BUILD_NAME"
package_variant ffbuild/prefix "ffbuild/pkgroot/$BUILD_NAME"

[[ -n "$LICENSE_FILE" ]] && cp "ffbuild/ffmpeg/$LICENSE_FILE" "ffbuild/pkgroot/$BUILD_NAME/LICENSE.txt"

cd ffbuild/pkgroot
if [[ "${TARGET}" == win* ]]; then
    OUTPUT_FNAME="${BUILD_NAME}.zip"
    docker run --rm -i $TTY_ARG "${UIDARGS[@]}" -v "${ARTIFACTS_PATH}":/out -v "${PWD}/${BUILD_NAME}":"/${BUILD_NAME}" -w / "$IMAGE" zip -9 -r "/out/${OUTPUT_FNAME}" "$BUILD_NAME"
else
    OUTPUT_FNAME="${BUILD_NAME}.tar.xz"
    docker run --rm -i $TTY_ARG "${UIDARGS[@]}" -v "${ARTIFACTS_PATH}":/out -v "${PWD}/${BUILD_NAME}":"/${BUILD_NAME}" -w / "$IMAGE" tar cJf "/out/${OUTPUT_FNAME}" "$BUILD_NAME"
fi
cd -

rm -rf ffbuild

if [[ -n "$GITHUB_ACTIONS" ]]; then
    echo "build_name=${BUILD_NAME}" >> "$GITHUB_OUTPUT"
    echo "${OUTPUT_FNAME}" > "${ARTIFACTS_PATH}/${TARGET}-${VARIANT}${ADDINS_STR:+-}${ADDINS_STR}.txt"
fi
