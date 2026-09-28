# syntax=docker/dockerfile:1
#
# Builds the three benchmark variants. Each final stage contains only the binary and
# build metadata, meant to be exported with `--output type=local,dest=bin/<variant>`:
#
#   glibc          Ubuntu glibc + glibc malloc, Swift runtime dynamically linked (bundled in lib/)
#   musl-sdk          Swift Static Linux SDK as shipped, fully static. The SDK already replaces
#                     musl's allocator in libc.a with mimalloc (swiftlang/swift-docker#488).
#   musl-mimalloc-v3  Swift Static Linux SDK with our mimalloc v3 mimalloc.o linked in, which
#                     takes precedence over the SDK's bundled mimalloc, fully static
#
# The toolchain and SDK versions match zunda-pixel/blindlog-api#379.

ARG SWIFT_IMAGE=swift:6.4.0-noble
ARG MIMALLOC_VERSION=v3.5.3

# ================================
# Toolchain + Static Linux SDK + mimalloc.o
# ================================
FROM ${SWIFT_IMAGE} AS toolchain

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
# `--static-swift-stdlib` fails to link Foundation with Swift 6.4.0 (unresolved CoreFoundation
# symbols from libFoundation.a, the issue mentioned in blindlog-api#379), so the Swift runtime
# is linked dynamically and its shared libraries are shipped next to the binary.
RUN swift build -c release --product BenchmarkServer \
    && mkdir -p /out/lib \
    && cp "$(swift build -c release --show-bin-path)/BenchmarkServer" /out/ \
    && cp -a /usr/lib/swift/linux/*.so* /out/lib/ \
    && swift --version > /out/swift-version.txt 2>&1 \
    && printf '{"variant":"glibc","libc":"glibc","allocator":"glibc malloc","swift_stdlib":"dynamic","build_flags":"-c release"}\n' > /out/build-info.json

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
# Export stages
# ================================
FROM scratch AS glibc
COPY --from=build-glibc /out/ /

FROM scratch AS musl-sdk
COPY --from=build-musl-sdk /out/ /

FROM scratch AS musl-mimalloc-v3
COPY --from=build-musl-mimalloc-v3 /out/ /
