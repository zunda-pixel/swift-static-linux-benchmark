# syntax=docker/dockerfile:1
#
# Builds the benchmark variants. Each final stage contains only the binary and
# build metadata, meant to be exported with `--output type=local,dest=bin/<variant>`:
#
#   glibc             Ubuntu 26.04 build, host glibc + glibc malloc. Like every glibc variant,
#                     the Swift runtime is linked statically (-Xswiftc -static-stdlib)
#   glibc-noble       same, but built on Ubuntu 24.04
#   glibc-noble-2.39  Ubuntu 24.04 build that also bundles and runs with glibc 2.39
#   glibc-noble-2.39-jemalloc
#                     blindlog-api's production setup before #379: Ubuntu 24.04 build with
#                     -Xswiftc -static-stdlib -Xlinker -ljemalloc, run with glibc 2.39 and
#                     Ubuntu's libjemalloc2 (both bundled in glibc/)
#   musl-sdk          Swift Static Linux SDK as shipped, fully static. The SDK already replaces
#                     musl's allocator in libc.a with mimalloc (swiftlang/swift-docker#488).
#   musl-mimalloc-v3  Swift Static Linux SDK with our mimalloc v3 mimalloc.o linked in, which
#                     takes precedence over the SDK's bundled mimalloc, fully static
#
# The toolchain and SDK versions match zunda-pixel/blindlog-api#379.

ARG MIMALLOC_VERSION=v3.5.3

# ================================
# Toolchain + Static Linux SDK + mimalloc.o
# ================================
# The image is written out (not an ARG) so Dependabot can update it. The Static Linux SDK
# below must match the toolchain version exactly; update STATIC_SDK_URL/CHECKSUM together.
FROM swift:6.4.0-resolute AS toolchain

ARG STATIC_SDK_URL=https://download.swift.org/swift-6.4.0-release/static-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
ARG STATIC_SDK_CHECKSUM=47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e
RUN swift sdk install "${STATIC_SDK_URL}" --checksum "${STATIC_SDK_CHECKSUM}"

ARG MIMALLOC_VERSION
RUN git clone --depth 1 --branch "${MIMALLOC_VERSION}" https://github.com/microsoft/mimalloc.git /mimalloc
COPY scripts/build-mimalloc.sh /usr/local/bin/build-mimalloc.sh
RUN build-mimalloc.sh /mimalloc /mimalloc/mimalloc.o

# ================================
# Sources
# ================================
FROM toolchain AS source
WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources ./Sources

# ================================
# glibc
# ================================
FROM source AS build-glibc
# The Swift runtime (including Foundation) is linked statically with `-Xswiftc -static-stdlib`,
# as blindlog-api did before #379. SwiftPM's `--static-swift-stdlib` fails to link Foundation
# with Swift 6.4.0 (unresolved CoreFoundation symbols from libFoundation.a), but this works.
RUN swift build -c release --product BenchmarkServer -Xswiftc -static-stdlib \
    && mkdir -p /out \
    && cp "$(swift build -c release --show-bin-path)/BenchmarkServer" /out/ \
    && swift --version > /out/swift-version.txt 2>&1 \
    && printf '{"variant":"glibc","libc":"glibc (host)","allocator":"glibc malloc","swift_stdlib":"static","build_image":"swift:6.4.0-resolute","build_flags":"-c release -Xswiftc -static-stdlib"}\n' > /out/build-info.json

# ================================
# musl-sdk
# ================================
FROM source AS build-musl-sdk
RUN SDK="$(uname -m)-swift-linux-musl" \
    && swift build -c release --product BenchmarkServer --swift-sdk "$SDK" \
    && mkdir -p /out \
    && cp "$(swift build -c release --swift-sdk "$SDK" --show-bin-path)/BenchmarkServer" /out/ \
    && swift --version > /out/swift-version.txt 2>&1 \
    && swift sdk list > /out/swift-sdk.txt \
    && printf '{"variant":"musl-sdk","libc":"musl","allocator":"mimalloc (bundled in the Static Linux SDK)","swift_stdlib":"static","build_flags":"-c release --swift-sdk %s"}\n' "$SDK" > /out/build-info.json

# ================================
# musl + mimalloc v3
# ================================
FROM source AS build-musl-mimalloc-v3
ARG MIMALLOC_VERSION
RUN SDK="$(uname -m)-swift-linux-musl" \
    && swift build -c release --product BenchmarkServer --swift-sdk "$SDK" -Xlinker /mimalloc/mimalloc.o \
    && mkdir -p /out \
    && cp "$(swift build -c release --swift-sdk "$SDK" -Xlinker /mimalloc/mimalloc.o --show-bin-path)/BenchmarkServer" /out/ \
    && swift --version > /out/swift-version.txt 2>&1 \
    && swift sdk list > /out/swift-sdk.txt \
    && printf '{"variant":"musl-mimalloc-v3","libc":"musl","allocator":"mimalloc %s","swift_stdlib":"static","build_flags":"-c release --swift-sdk %s -Xlinker mimalloc.o"}\n' "$MIMALLOC_VERSION" "$SDK" > /out/build-info.json

# ================================
# glibc, built on Ubuntu 24.04 (noble)
# ================================
# Used to separate the effect of the glibc version from the build image and the CPU:
#   glibc-noble       noble build, run against the host glibc
#   glibc-noble-2.39  noble build, run with noble's glibc 2.39 bundled in glibc/ and started
#                     through the bundled dynamic loader (see scripts/lib.sh)
FROM swift:6.4.0-noble AS build-glibc-noble
WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources ./Sources
RUN swift build -c release --product BenchmarkServer -Xswiftc -static-stdlib \
    && mkdir -p /out /glibc \
    && cp "$(swift build -c release --show-bin-path)/BenchmarkServer" /out/ \
    && swift --version > /out/swift-version.txt 2>&1 \
    && ldd /out/BenchmarkServer \
       | awk '$3 ~ /^\// && $3 !~ /^\/out\// { print $3 } $1 ~ /^\/.*ld-linux/ { print $1 }' \
       | xargs -I{} cp -L {} /glibc/ \
    && ls /glibc

FROM build-glibc-noble AS build-glibc-noble-host
RUN printf '{"variant":"glibc-noble","libc":"glibc (host)","allocator":"glibc malloc","swift_stdlib":"static","build_image":"swift:6.4.0-noble","build_flags":"-c release -Xswiftc -static-stdlib"}\n' > /out/build-info.json

FROM build-glibc-noble AS build-glibc-noble-2.39
RUN mv /glibc /out/glibc \
    && printf '{"variant":"glibc-noble-2.39","libc":"glibc (bundled from noble)","allocator":"glibc malloc","swift_stdlib":"static","build_image":"swift:6.4.0-noble","build_flags":"-c release -Xswiftc -static-stdlib"}\n' > /out/build-info.json

# ================================
# glibc + jemalloc, built on Ubuntu 24.04 (noble)
# ================================
# Reproduces blindlog-api's Dockerfile before #379.
FROM swift:6.4.0-noble AS build-glibc-jemalloc
RUN apt-get -q update \
    && DEBIAN_FRONTEND=noninteractive apt-get -q install -y --no-install-recommends libjemalloc-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources ./Sources
RUN swift build -c release --product BenchmarkServer -Xswiftc -static-stdlib -Xlinker -ljemalloc \
    && mkdir -p /out/glibc \
    && cp "$(swift build -c release --show-bin-path)/BenchmarkServer" /out/ \
    && swift --version > /out/swift-version.txt 2>&1 \
    && ldd /out/BenchmarkServer \
       | awk '$3 ~ /^\// && $3 !~ /^\/out\// { print $3 } $1 ~ /^\/.*ld-linux/ { print $1 }' \
       | xargs -I{} cp -L {} /out/glibc/ \
    && ls /out/glibc \
    && JEMALLOC="$(dpkg-query -W -f='${Version}' libjemalloc2)" \
    && printf '{"variant":"glibc-noble-2.39-jemalloc","libc":"glibc (bundled from noble)","allocator":"jemalloc %s (Ubuntu libjemalloc2)","swift_stdlib":"static","build_image":"swift:6.4.0-noble","build_flags":"-c release -Xswiftc -static-stdlib -Xlinker -ljemalloc"}\n' "$JEMALLOC" > /out/build-info.json

# ================================
# Export stages
# ================================
FROM scratch AS glibc
COPY --from=build-glibc /out/ /

FROM scratch AS glibc-noble
COPY --from=build-glibc-noble-host /out/ /

FROM scratch AS glibc-noble-2.39
COPY --from=build-glibc-noble-2.39 /out/ /

FROM scratch AS glibc-noble-2.39-jemalloc
COPY --from=build-glibc-jemalloc /out/ /

FROM scratch AS musl-sdk
COPY --from=build-musl-sdk /out/ /

FROM scratch AS musl-mimalloc-v3
COPY --from=build-musl-mimalloc-v3 /out/ /
