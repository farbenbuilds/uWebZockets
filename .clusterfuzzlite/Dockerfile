FROM gcr.io/oss-fuzz-base/base-builder:v1

COPY oss-fuzz/install_toolchain.sh /tmp/install_toolchain.sh
RUN bash /tmp/install_toolchain.sh

COPY . "$SRC/uWebZockets"
RUN cd "$SRC/uWebZockets" && zig build --fetch=all

COPY .clusterfuzzlite/build.sh "$SRC/build.sh"
WORKDIR "$SRC/uWebZockets"
