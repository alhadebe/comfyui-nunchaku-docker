# ==============================================================================
# STAGE 1: BUILDER
# ==============================================================================
FROM nvidia/cuda:12.6.1-devel-ubuntu24.04 AS builder

ARG NUNCHAKU_VERSION=v0.3.2

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 python3.12-dev python3-pip git build-essential ninja-build \
    && ln -s /usr/bin/python3.12 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy

WORKDIR /build
RUN uv venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install PyTorch & dependencies (Cached)
# Using --no-cache-dir to save space in the final image layer if uv keeps it
RUN uv pip install --no-cache torch==2.5.1 torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
RUN uv pip install --no-cache setuptools wheel packaging ninja

# Compile SageAttention
ENV TORCH_CUDA_ARCH_LIST="8.0 8.6 8.9 9.0"
RUN git clone https://github.com/woct0rdho/SageAttention.git && \
    cd SageAttention && \
    uv pip install . 

# Compile Nunchaku
RUN git clone --recursive --branch ${NUNCHAKU_VERSION} https://github.com/nunchaku-tech/nunchaku.git && \
    cd nunchaku && \
    uv pip install .

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

# COPY THE VIRTUAL ENV FROM BUILDER (Contains Torch, Nunchaku, SageAttention)
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install ComfyUI
RUN git clone https://github.com/comfyanonymous/ComfyUI.git . && \
    git checkout ${COMFYUI_VERSION} && \
    # Install requirements but skip torch (already in venv) to save bandwidth/time
    uv pip install --no-cache -r requirements.txt

WORKDIR /app/custom_nodes
RUN git clone https://github.com/ltdrdata/ComfyUI-Manager.git && \
    cd ComfyUI-Manager && \
    uv pip install --no-cache -r requirements.txt

WORKDIR /app
EXPOSE 8188
CMD ["python", "main.py", "--listen", "0.0.0.0"]
