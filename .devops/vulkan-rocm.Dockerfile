# Merged Vulkan + ROCm (HIP) + HRX build.
# Base on the ROCm dev container so the runtime image ships the ROCm runtime.
# The plain-ubuntu base used by the vulkan image lacks ROCm libs, so inherit ROCm.
# Vulkan SDK packages are bolted on to the build stage.
ARG UBUNTU_VERSION=26.04

# keep this in sync with the local rocm/dev-ubuntu-26.04:10.0.0-full image
ARG ROCM_VERSION=10.0.0
ARG AMDGPU_VERSION=10.0.0

ARG BASE_ROCM_DEV_CONTAINER=docker.io/rocm/dev-ubuntu-${UBUNTU_VERSION}:${ROCM_VERSION}-full

ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A

ARG NODE_VERSION=24

FROM docker.io/node:$NODE_VERSION AS web

ARG APP_VERSION

WORKDIR /app/tools/ui

COPY tools/ui/package.json tools/ui/package-lock.json ./
RUN npm ci

COPY tools/ui/ ./
RUN LLAMA_BUILD_NUMBER="$APP_VERSION" npm run build

### Build image
FROM ${BASE_ROCM_DEV_CONTAINER} AS build

# fat build over rocBLAS-supported archs
ARG ROCM_DOCKER_ARCH='gfx908;gfx90a;gfx942;gfx1030;gfx1100;gfx1101;gfx1102;gfx1151;gfx1150;gfx1200;gfx1201'

ENV AMDGPU_TARGETS=${ROCM_DOCKER_ARCH}

RUN apt-get update \
    && apt-get install -y \
    build-essential \
    cmake \
    ccache \
    git \
    libssl-dev \
    curl \
    wget \
    libgomp1 \
    # Vulkan SDK deps added on top of the ROCm dev container
    libvulkan1 libxcb-xinput0 libxcb-xinerama0 libxcb-cursor-dev \
    glslc spirv-headers

ENV VULKAN_SDK_VERSION=1.4.357.1
ENV VULKAN_SDK=/opt/vulkan/${VULKAN_SDK_VERSION}/x86_64
ENV PATH=${VULKAN_SDK}/bin:${PATH}
ENV LD_LIBRARY_PATH=${VULKAN_SDK}/lib:/opt/rocm/core-10.0/lib:/opt/rocm/core-10.0/lib/llvm/lib:${LD_LIBRARY_PATH}

# Download and unpack the LunarG Vulkan SDK tarball (replaces libvulkan-dev)
RUN mkdir -p /opt/vulkan && \
    wget -q "https://sdk.lunarg.com/sdk/download/${VULKAN_SDK_VERSION}/linux/vulkansdk-linux-x86_64-${VULKAN_SDK_VERSION}.tar.xz" \
    -O /tmp/vulkansdk.tar.xz && \
    tar -xf /tmp/vulkansdk.tar.xz -C /opt/vulkan && \
    rm /tmp/vulkansdk.tar.xz

WORKDIR /app

# ccache: reuse host cache via a mounted volume (see docker build --volume).
# Lives at /ccache, deliberately NOT under /tmp: the base stage runs `rm -rf /tmp/*`,
# which would remove the bind-mountpoint and fail (Device or resource busy).
ENV CCACHE_DIR=/ccache
ENV CCACHE_SIZE=20G
RUN mkdir -p "$CCACHE_DIR"

# wrap the compiler with ccache via CMake's native launcher; avoids clashing with
# the HIP/clang toolchain the build selects
ENV CMAKE_CXX_COMPILER_LAUNCHER=ccache

COPY . .

COPY --from=web /app/tools/ui/dist tools/ui/dist

RUN ln -s /usr/lib/x86_64-linux-gnu/libvulkan.so.1 /usr/lib/x86_64-linux-gnu/libvulkan.so

# GGML_HIP (rocm) + GGML_VULKAN (vulkan) + GGML_HRX (hrx)
#
# Use GGML_HRX=ON, not GGML_USE_HRX=ON: the latter is only a PRIVATE compile
# definition on the ggml-hrx target, so passing it on the command line does
# nothing. GGML_HRX=ON is the real configure-time trigger (ggml_add_backend(HRX)).
#
# HRX is built from the hrx-system source tree (HRX_SOURCE_DIR) via the
# ggml-hrx-deps ExternalProject, since we pin the submodule rather than consuming
# a packaged hrx/loomc (there are no config files to find_package()).
#
# GGML_HRX_BUNDLE_RUNTIME_LIBS globs for libhrx/libloomc/etc. at CONFIGURE time,
# but the ExternalProject only produces them at BUILD time. So the build is done
# in three passes over the same build dir:
#   1. configure with bundling OFF, build only the ggml-hrx-deps target
#   2. reconfigure with bundling ON, pointing the search path at the freshly built
#      libhrx/libloomc plus the ROCm lib dirs
#   3. build everything (the bundle is copied next to the backend post-build)
#
# These paths come from BUILD_BYPRODUCTS in ggml/src/ggml-hrx/CMakeLists.txt.
ENV HRX_BUILD_DIR=/app/build/ggml/src/ggml-hrx/hrx/src/ggml-hrx-deps-build

# Pass 1: configure (no bundling) + build only hrx-system/loomc
RUN HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake -S . -B build \
        -DGGML_HIP=ON \
        -DAMDGPU_TARGETS="$ROCM_DOCKER_ARCH" \
        -DGGML_VULKAN=ON \
        -DGGML_HRX=ON \
        -DHRX_SOURCE_DIR=$(pwd)/hrx-system \
        -DGGML_HRX_BUNDLE_RUNTIME_LIBS=OFF \
        -DGGML_NATIVE=OFF \
        -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON \
        -DVulkan_INCLUDE_DIR="${VULKAN_SDK}/include" \
        -DCMAKE_BUILD_TYPE=Release -DLLAMA_BUILD_TESTS=OFF \
    && cmake --build build --config Release --target ggml-hrx-deps -j"$(nproc)"

# Pass 2: reconfigure with bundling ON.
# Each library family must be found in exactly ONE of these directories:
#   libhrx                  -> hrx build tree
#   libloomc                -> loomc build tree
#   libhsa-runtime64, libhsa-amd-aqlprofile64,
#   librocprofiler-register,
#   rocm_sysdeps/lib/*      -> /opt/rocm/core-10.0/lib
#   libomp                  -> /opt/rocm/core-10.0/lib/llvm/lib
RUN set -eux; \
    ls -l "${HRX_BUILD_DIR}"/libhrx/src/libhrx/libhrx.so* \
          "${HRX_BUILD_DIR}"/loom/binding/c/libloomc.so*; \
    HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake -S . -B build \
        -DGGML_HRX_BUNDLE_RUNTIME_LIBS=ON \
        "-DGGML_HRX_BUNDLE_LIBRARY_DIRS=${HRX_BUILD_DIR}/libhrx/src/libhrx;${HRX_BUILD_DIR}/loom/binding/c;/opt/rocm/core-10.0/lib;/opt/rocm/core-10.0/lib/llvm/lib"

# Pass 3: full build
RUN cmake --build build --config Release -j"$(nproc)"

# Sanity check the bundle layout: libs and rocm_sysdeps/lib sit next to the
# backend, and the backend's RUNPATH is $ORIGIN:$ORIGIN/rocm_sysdeps/lib.
RUN set -eux; \
    ls -l build/bin/libhrx.so* build/bin/libloomc.so*; \
    ls build/bin/rocm_sysdeps/lib | head; \
    readelf -d build/bin/libggml-hrx.so | grep -Ei 'runpath|rpath'; \
    if ldd build/bin/libggml-hrx.so | grep 'not found'; then exit 1; fi

# Shared libraries + backends, flat. Excludes the IREE internals in the hrx build
# tree (the runtime bundle is already copied into build/bin) and rocm_sysdeps,
# which must keep its own lib/ subdirectory (it is on the backend RUNPATH).
RUN mkdir -p /app/lib \
    && find build \
        \( -path '*/ggml-hrx-deps-build' -o -path '*/rocm_sysdeps' -o -path '*/CMakeFiles' \) -prune \
        -o -name "*.so*" -exec cp -P {} /app/lib \; \
    && cp -a build/bin/rocm_sysdeps /app/lib/rocm_sysdeps

RUN mkdir -p /app/full \
    && cp -a build/bin/. /app/full/ \
    && cp *.py /app/full \
    && cp -r conversion /app/full \
    && cp -r gguf-py /app/full \
    && cp -r requirements /app/full \
    && cp requirements.txt /app/full \
    && cp .devops/tools.sh /app/full/tools.sh

## Base image
FROM ${BASE_ROCM_DEV_CONTAINER} AS base

ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A
ARG IMAGE_URL=https://github.com/ggml-org/llama.cpp
ARG IMAGE_SOURCE=https://github.com/ggml-org/llama.cpp
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.version=$APP_VERSION \
      org.opencontainers.image.revision=$APP_REVISION \
      org.opencontainers.image.title="llama.cpp" \
      org.opencontainers.image.description="LLM inference in C/C++" \
      org.opencontainers.image.url=$IMAGE_URL \
      org.opencontainers.image.source=$IMAGE_SOURCE

# Runtime system configuration for the LunarG SDK loader
ENV VULKAN_SDK_VERSION=1.4.363.0
ENV VULKAN_SDK=/opt/vulkan/${VULKAN_SDK_VERSION}/x86_64
ENV PATH=${VULKAN_SDK}/bin:${PATH}
ENV LD_LIBRARY_PATH=${VULKAN_SDK}/lib:/opt/rocm/core-10.0/lib:/opt/rocm/core-10.0/lib/llvm/lib:${LD_LIBRARY_PATH}
ENV GGML_BACKEND_PATH=/app/libggml-hrx.so

RUN apt-get update \
    && apt-get install -y --no-install-recommends libgomp1 curl ffmpeg \
    mesa-vulkan-drivers libglvnd0 libgl1 libglx0 libegl1 libgles2 \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

COPY --from=build /opt/vulkan/ /opt/vulkan/

# Backends + bundled HRX runtime (libhrx, libloomc, ...) land in /app, and
# /app/rocm_sysdeps/lib keeps its layout so the backend's $ORIGIN RUNPATH works.
COPY --from=build /app/lib/ /app

### Full
FROM base AS full

COPY --from=build /app/full /app

WORKDIR /app

RUN apt-get update \
    && apt-get install -y \
    git \
    python3-pip \
    python3 \
    python3-wheel \
    && pip install --break-system-packages --upgrade setuptools \
    && pip install --break-system-packages -r requirements.txt \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

ENTRYPOINT ["/app/tools.sh"]

### Light, CLI only
FROM base AS light

COPY --from=build /app/full/llama /app/full/llama-cli /app/full/llama-completion /app

WORKDIR /app

ENTRYPOINT [ "/app/llama-cli" ]

### Server, Server only
FROM base AS server

ENV LLAMA_ARG_HOST=0.0.0.0

COPY --from=build /app/full/llama /app/full/llama-server /app

WORKDIR /app

HEALTHCHECK CMD [ "curl", "-f", "http://localhost:8080/health" ]

ENTRYPOINT [ "/app/llama-server" ]
