# syntax=docker/dockerfile:1

# ==============================================================================
# GLOBAL ARGS & BASE
# ==============================================================================
ARG CUDA_VER=12.9.1
ARG UBUNTU_VER=24.04
ARG TORCH_VERSION=2.8.0
ARG PY_VER=3.12

# Base builder image with common tools
FROM nvidia/cuda:${CUDA_VER}-devel-ubuntu${UBUNTU_VER} AS base_builder
ARG PY_VER
ARG TORCH_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
    python${PY_VER} python${PY_VER}-dev git build-essential \
    && ln -s /usr/bin/python${PY_VER} /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

# Install uv
ADD https://github.com/astral-sh/uv/releases/download/0.8.6/uv-x86_64-unknown-linux-gnu.tar.gz /tmp/uv.tar.gz
RUN tar -xzf /tmp/uv.tar.gz --strip-components=1 && mv uv /usr/local/bin/uv

WORKDIR /build
RUN uv venv venv
ENV VIRTUAL_ENV=/build/venv
ENV PATH="/build/venv/bin:$PATH"

# Install PyTorch & Build Deps
RUN uv pip install torch==${TORCH_VERSION} --extra-index-url https://download.pytorch.org/whl/cu126 \
    ninja wheel packaging setuptools

# ==============================================================================
# STAGE: Build xFormers (Pinned Version)
# ==============================================================================
FROM base_builder AS builder_xformers
ARG XFORMERS_VER=v0.0.32.post2

# Architectures: 8.0(A100), 8.6(3090/4090), 8.9(Ada), 9.0(Hopper)
ENV TORCH_CUDA_ARCH_LIST="8.0 8.6 8.9+PTX 12.0"
RUN git clone --depth 1 --branch ${XFORMERS_VER} --recurse-submodules https://github.com/facebookresearch/xformers.git xformers && \
    cd xformers && \
    uv build --wheel

# ==============================================================================
# STAGE: Build FlashAttention-2 (Pinned Version)
# ==============================================================================
FROM base_builder AS builder_flashattn
ARG FLASH_VER=v2.8.3

ENV MAX_JOBS=2
RUN git clone --depth 1 --branch ${FLASH_VER} --recurse-submodules https://github.com/Dao-AILab/flash-attention.git flash-attention && \
    cd flash-attention && \
    uv build --wheel --no-build-isolation

# ==============================================================================
# STAGE: Build SageAttention (Pinned Version)
# ==============================================================================
FROM base_builder AS builder_sage
ARG SAGE_VER=v2.2.0-windows.post2

ENV TORCH_CUDA_ARCH_LIST="8.0 8.6 8.9 9.0 12.0+PTX"
ENV SAGEATTENTION_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST}
RUN git clone --depth 1 --branch ${SAGE_VER} --recurse-submodules https://github.com/woct0rdho/SageAttention.git SageAttention && \
    cd SageAttention && \
    uv build --wheel

# ==============================================================================
# STAGE: Build Nunchaku (Dynamic - Tracks Repo)
# ==============================================================================
FROM base_builder AS builder_nunchaku
# This ARG comes from the GitHub Workflow
ARG NUNCHAKU_REF=main

RUN git clone --recursive https://github.com/nunchaku-tech/nunchaku.git && \
    cd nunchaku && \
    git checkout ${NUNCHAKU_REF} && \
    git submodule update --init --recursive && \
    export NUNCHAKU_INSTALL_MODE=ALL && \
    export NUNCHAKU_BUILD_WHEELS=1 && \
    export MAX_JOBS=4 && \
    uv build --wheel

# ==============================================================================
# STAGE: Final Runtime (ComfyUI + Extensions)
# ==============================================================================
FROM nvidia/cuda:${CUDA_VER}-runtime-ubuntu${UBUNTU_VER}
ARG PY_VER
ARG TORCH_VERSION

# Runtime System Deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    python${PY_VER} python${PY_VER}-dev libgl1 libglib2.0-0 libgthread-2.0-0 libgtk-3-0 git curl \
    && ln -s /usr/bin/python${PY_VER} /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

# Install uv
ADD https://github.com/astral-sh/uv/releases/download/0.8.6/uv-x86_64-unknown-linux-gnu.tar.gz /tmp/uv.tar.gz
RUN tar -xzf /tmp/uv.tar.gz --strip-components=1 && mv uv /usr/local/bin/uv

WORKDIR /comfyui

# Setup Runtime Venv
RUN uv venv venv
ENV VIRTUAL_ENV=/comfyui/venv
ENV PATH="/comfyui/venv/bin:$PATH"

# 1. Install PyTorch
RUN uv pip install torch==${TORCH_VERSION} torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu126

# 2. Install Common Comfy Deps
RUN uv pip install \
    einops tokenizers pyyaml pillow scipy tqdm psutil kornia spandrel soundfile \
    huggingface_hub[cli] huggingface_hub[hf_transfer] \
    diffusers transformers accelerate sentencepiece protobuf torchsde

# 3. Gather and Install Custom Wheels (xFormers, FlashAttn, Sage, Nunchaku)
COPY --from=builder_xformers /build/xformers/dist /tmp/wheels
COPY --from=builder_flashattn /build/flash-attention/dist /tmp/wheels
COPY --from=builder_sage     /build/SageAttention/dist /tmp/wheels
COPY --from=builder_nunchaku /build/nunchaku/dist /tmp/wheels

# Install all wheels found in /tmp/wheels
RUN uv pip install /tmp/wheels/*.whl && rm -rf /tmp/wheels

# 4. Install ComfyUI (Dynamic)
ARG COMFYUI_REF=master
RUN git clone --depth 1 --branch ${COMFYUI_REF} https://github.com/comfyanonymous/ComfyUI . && \
    git init . && \
    git remote add origin https://github.com/comfyanonymous/ComfyUI && \
    uv pip install -r requirements.txt

# 5. Install ComfyUI Manager (Extensions)
ENV COMFYUI_PATH=/comfyui
RUN git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager /comfyui-manager && \
    uv pip install -r /comfyui-manager/requirements.txt && \
    python /comfyui-manager/cm-cli.py update all && \
    mv /comfyui/user/default/ComfyUI-Manager/cache /comfyui-manager-cache

# 6. Entrypoint (Simulates entrypoint.extensions.sh)
COPY <<EOF /entrypoint.sh
#!/bin/bash
set -e

# Setup Extensions/Manager links
mkdir -p /comfyui/custom_nodes
ln -sf /comfyui-manager /comfyui/custom_nodes/ComfyUI-Manager
mkdir -p /comfyui/user/default/ComfyUI-Manager
ln -sf /comfyui-manager-cache /comfyui/user/default/ComfyUI-Manager/cache

# Generate Config
python - <<'PYCFG'
import configparser, pathlib
cfg_path = pathlib.Path('/comfyui/user/default/ComfyUI-Manager/config.ini')
cfg_path.parent.mkdir(parents=True, exist_ok=True)
if not cfg_path.exists():
    cfg_path.write_text('[default]\nuse_uv = True\nnetwork_mode = offline\n')
else:
    cfg = configparser.ConfigParser()
    cfg.read(cfg_path)
    if 'default' not in cfg:
        cfg['default'] = {}
    cfg['default']['use_uv'] = 'True'
    with cfg_path.open('w') as f:
        cfg.write(f)
PYCFG

python /comfyui-manager/cm-cli.py fix all

# Env flags needed for custom kernels
export XFORMERS_IGNORE_FLASH_VERSION_CHECK=1

echo "Starting ComfyUI..."
exec python main.py --listen "\$@"
EOF

RUN chmod +x /entrypoint.sh
EXPOSE 8188
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["/entrypoint.sh"]
