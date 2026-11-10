FROM gcr.io/oss-fuzz-base/base-builder:v1

COPY install_toolchain.sh /tmp/install_toolchain.sh
RUN bash /tmp/install_toolchain.sh

# The hosted/external OSS-Fuzz helper builds a clean default-branch checkout.
# ClusterFuzzLite uses the checked-out revision through .clusterfuzzlite/.
RUN git clone --depth 1 \
    https://github.com/farbenbuilds/uWebZockets.git \
    "$SRC/uWebZockets"
RUN cd "$SRC/uWebZockets" && zig build --fetch=all

COPY build.sh "$SRC/build.sh"
WORKDIR "$SRC/uWebZockets"
