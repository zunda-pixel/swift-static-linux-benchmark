# syntax=docker/dockerfile:1
#
# Builds the three benchmark variants. Each final stage contains only the binary and
# build metadata, meant to be exported with `--output type=local,dest=bin/<variant>`:
#
#   glibc          Ubuntu glibc + glibc malloc, Swift runtime statically linked
#   musl           Swift Static Linux SDK (musl + musl malloc), fully static
#   musl-mimalloc  Swift Static Linux SDK with mimalloc.o overriding malloc, fully static
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
RUN swift build -c release --product BenchmarkServer --static-swift-stdlib \
    && mkdir -p /out \
    && cp "$(swift build -c release --static-swift-stdlib --show-bin-path)/BenchmarkServer" /out/ \
    && swift --version > /out/swift-version.txt 2>&1 \
    && printf '{"variant":"glibc","libc":"glibc","allocator":"glibc malloc","swift_stdlib":"static","build_flags":"-c release --static-swift-stdlib"}\n' > /out/build-info.json

# ================================
# musl
# ================================
FROM source AS build-musl
RUN SDK="$(uname -m)-swift-linux-musl" \
    && swift build -c release --product BenchmarkServer --swift-sdk "$SDK" \
    && mkdir -p /out \
    && cp "$(swift build -c release --swift-sdk "$SDK" --show-bin-path)/BenchmarkServer" /out/ \
    && swift --version > /out/swift-version.txt 2>&1 \
    && swift sdk list > /out/swift-sdk.txt \
    && printf '{"variant":"musl","libc":"musl","allocator":"musl malloc","swift_stdlib":"static","build_flags":"-c release --swift-sdk %s"}\n' "$SDK" > /out/build-info.json

# ================================
# musl + mimalloc
# ================================
FROM source AS build-musl-mimalloc
ARG MIMALLOC_VERSION
RUN SDK="$(uname -m)-swift-linux-musl" \
    && swift build -c release --product BenchmarkServer --swift-sdk "$SDK" -Xlinker /mimalloc/mimalloc.o \
    && mkdir -p /out \
    && cp "$(swift build -c release --swift-sdk "$SDK" -Xlinker /mimalloc/mimalloc.o --show-bin-path)/BenchmarkServer" /out/ \
    && swift --version > /out/swift-version.txt 2>&1 \
    && swift sdk list > /out/swift-sdk.txt \
    && printf '{"variant":"musl-mimalloc","libc":"musl","allocator":"mimalloc %s","swift_stdlib":"static","build_flags":"-c release --swift-sdk %s -Xlinker mimalloc.o"}\n' "$MIMALLOC_VERSION" "$SDK" > /out/build-info.json

# ================================
# Export stages
# ================================
FROM scratch AS glibc
COPY --from=build-glibc /out/ /

FROM scratch AS musl
COPY --from=build-musl /out/ /

FROM scratch AS musl-mimalloc
COPY --from=build-musl-mimalloc /out/ /
