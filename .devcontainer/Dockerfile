# cmods workspace: MicroPython, CircuitPython, LVGL, and PyDevices repos.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG DEBIAN_FRONTEND=noninteractive

# Build tools for mp-unix, cp-unix, cpy-unix, lv_bindings generator, and usdl2.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    bison \
    ccache \
    cmake \
    flex \
    gawk \
    gcc-mingw-w64 \
    gettext \
    git \
    gperf \
    libffi-dev \
    libsdl2-dev \
    libssl-dev \
    libusb-1.0-0-dev \
    pkg-config \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    texinfo \
    unzip \
    wget \
    && rm -rf /var/lib/apt/lists/*

# CircuitPython requirements-dev.txt may need Rust (minify_html).
USER vscode
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
ENV PATH="/home/vscode/.cargo/bin:${PATH}"
