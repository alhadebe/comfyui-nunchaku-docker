# ==============================================================================
# STAGE 1: BUILDER
# ==============================================================================
FROM nvidia/cuda:12.6.1-devel-ubuntu24.04 AS builder

# Define build arguments for version control
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
RUN uv pip install torch==2.5.1 torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
RUN uv pip install setuptools wheel packaging ninja

# Compile SageAttention (Sticking to main/latest for compatibility)
ENV TORCH_CUDA_ARCH_LIST="8.0 8.6 8.9 9.0"
RUN git clone https://github.com/woct0rdho/SageAttention.git && \
    cd SageAttention && \
    uv pip install . 

# Compile Nunchaku (Using specific version)
RUN git clone --recursive --branch ${NUNCHAKU_VERSION} https://github.com/nunchaku-tech/nunchaku.git && \
    cd nunchaku && \
    uv pip install .

# ==============================================================================
# STAGE 2: RUNTIME
# ==============================================================================
FROM nvidia/cuda:12.6.1-runtime-ubuntu24.04

# Define build arguments again for the runtime stage
ARG COMFYUI_VERSION=master
ARG NUNCHAKU_VERSION=v0.3.2

# Add Metadata Labels so the checker workflow can see what's inside
LABEL org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY}
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
RUN uv venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN uv pip install torch==2.5.1 torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124

COPY --from=builder /opt/venv /opt/venv

# Install ComfyUI (Using specific version/tag)
# Note: We use a fetch loop here to handle both tags and branches safely
RUN git clone https://github.com/comfyanonymous/ComfyUI.git . && \
    git checkout ${COMFYUI_VERSION} && \
    uv pip install -r requirements.txt

WORKDIR /app/custom_nodes
RUN git clone https://github.com/ltdrdata/ComfyUI-Manager.git && \
    cd ComfyUI-Manager && \
    uv pip install -r requirements.txt

WORKDIR /app
EXPOSE 8188
CMD ["python", "main.py", "--listen", "0.0.0.0"]
