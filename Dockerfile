# ==============================================================================
# STAGE 1: BUILDER
# ==============================================================================
FROM nvidia/cuda:12.6.1-devel-ubuntu24.04 AS builder

ARG NUNCHAKU_VERSION=v0.3.2

ENV DEBIAN_FRONTEND=noninteractive
# Set these persistently so they are available to all RUN commands
ENV CUDA_HOME="/usr/local/cuda"
ENV TORCH_CUDA_ARCH_LIST="8.0 8.6 8.9 9.0"

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 python3.12-dev python3-pip git build-essential ninja-build \
    && ln -s /usr/bin/python3.12 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy

WORKDIR /build
RUN uv venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# 1. Install PyTorch (CUDA 12.4 version)
RUN uv pip install --no-cache torch==2.5.1 torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124

# 2. Install Build Tools (Numpy is critical for the setup scripts)
RUN uv pip install --no-cache numpy setuptools wheel packaging ninja cmake

# 3. Compile SageAttention
# Use --no-build-isolation to force usage of our pre-installed CUDA-enabled Torch
RUN git clone https://github.com/woct0rdho/SageAttention.git && \
    cd SageAttention && \
    uv pip install --no-build-isolation . 

# 4. Compile Nunchaku
# Use --no-build-isolation to prevent uv from downloading a CPU-only Torch
RUN git clone --recursive --branch ${NUNCHAKU_VERSION} https://github.com/nunchaku-tech/nunchaku.git && \
    cd nunchaku && \
    uv pip install --no-build-isolation -v .

# ==============================================================================
# STAGE 2: RUNTIME
# ==============================================================================
FROM nvidia/cuda:12.6.1-runtime-ubuntu24.04

ARG COMFYUI_VERSION=master
ARG NUNCHAKU_VERSION=v0.3.2

LABEL org.opencontainers.image.source=https://github.com/alhadebe/comfyui-nunchaku-docker
LABEL com.custom.version.comfyui=${COMFYUI_VERSION}
LABEL com.custom.version.nunchaku=${NUNCHAKU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 python3-pip git ffmpeg libgl1 libglib2.0-0 jq \
    && ln -s /usr/bin/python3.12 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /bin/uv
WORKDIR /app

# Copy the populated venv from builder
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install ComfyUI
RUN git clone https://github.com/comfyanonymous/ComfyUI.git . && \
    git checkout ${COMFYUI_VERSION} && \
    uv pip install --no-cache -r requirements.txt

WORKDIR /app/custom_nodes
RUN git clone https://github.com/ltdrdata/ComfyUI-Manager.git && \
    cd ComfyUI-Manager && \
    uv pip install --no-cache -r requirements.txt

WORKDIR /app
EXPOSE 8188
CMD ["python", "main.py", "--listen", "0.0.0.0"]
