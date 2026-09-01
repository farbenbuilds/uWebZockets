FROM gcr.io/oss-fuzz-base/base-builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl git xz-utils zip && \
    rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.16.0
RUN zig_archive=/tmp/zig.tar.xz && \
    curl -fsSL -o "$zig_archive" \
    "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" && \
    printf '%s  %s\n' \
    "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00" \
    "$zig_archive" | sha256sum -c - && \
    tar -xJf "$zig_archive" -C /opt && \
    rm "$zig_archive" && \
    ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

RUN git clone --depth 1 --recurse-submodules \
    https://github.com/farbenbuilds/uWebZockets.git \
    "$SRC/uWebZockets"
RUN cd "$SRC/uWebZockets" && zig build --fetch=all

COPY build.sh "$SRC/build.sh"
WORKDIR "$SRC/uWebZockets"
