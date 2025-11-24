# syntax=docker/dockerfile:1

ARG CUDA_VER=12.9.1
ARG UBUNTU_VER=24.04
ARG TORCH_VERSION=2.8.0
ARG PY_VER=3.12

# ------------------------------------------------------------------------------
# Base Builder: Setup Python, UV, PyTorch
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# Heavy Builder: Compile all kernels SEQUENTIALLY to prevent OOM
# ------------------------------------------------------------------------------
FROM base_builder AS builder_heavy

# Limit parallelism to prevent OOM on GitHub Runners (Allocated ~16GB RAM)
# Running 4 heavy compilations in parallel killed the previous runner.
ENV MAX_JOBS=2
ENV NVCC_THREADS=2
# Target Architectures: 8.0(A100), 8.6(3090), 8.9(Ada), 9.0(Hopper)
ENV TORCH_CUDA_ARCH_LIST="8.0 8.6 8.9 9.0"

# 1. Build xFormers
ARG XFORMERS_VER=v0.0.32.post2
RUN git clone --depth 1 --branch ${XFORMERS_VER} --recurse-submodules https://github.com/facebookresearch/xformers.git xformers && \
    cd xformers && \
    uv build --wheel

# 2. Build FlashAttention-2
ARG FLASH_VER=v2.8.3
RUN git clone --depth 1 --branch ${FLASH_VER} --recurse-submodules https://github.com/Dao-AILab/flash-attention.git flash-attention && \
    cd flash-attention && \
    uv build --wheel --no-build-isolation

# 3. Build SageAttention
ARG SAGE_VER=v2.2.0-windows.post2
ENV SAGEATTENTION_CUDA_ARCH_LIST="8.0 8.6 8.9 9.0"
RUN git clone --depth 1 --branch ${SAGE_VER} --recurse-submodules https://github.com/woct0rdho/SageAttention.git SageAttention && \
    cd SageAttention && \
    uv build --wheel

# 4. Build Nunchaku (Dynamic Ref)
ARG NUNCHAKU_REF=main
RUN git clone --recursive https://github.com/nunchaku-tech/nunchaku.git && \
    cd nunchaku && \
    git checkout ${NUNCHAKU_REF} && \
    git submodule update --init --recursive && \
    export NUNCHAKU_INSTALL_MODE=ALL && \
    export NUNCHAKU_BUILD_WHEELS=1 && \
    uv build --wheel

# Gather all wheels into one folder for the final stage
RUN mkdir -p /dist && \
    cp /build/xformers/dist/*.whl /dist/ && \
    cp /build/flash-attention/dist/*.whl /dist/ && \
    cp /build/SageAttention/dist/*.whl /dist/ && \
    cp /build/nunchaku/dist/*.whl /dist/

# ------------------------------------------------------------------------------
# Final Runtime
# ------------------------------------------------------------------------------
FROM nvidia/cuda:${CUDA_VER}-runtime-ubuntu${UBUNTU_VER}
ARG PY_VER
ARG TORCH_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
    python${PY_VER} python${PY_VER}-dev libgl1 libglib2.0-0 libgthread-2.0-0 libgtk-3-0 git curl \
    && ln -s /usr/bin/python${PY_VER} /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

ADD https://github.com/astral-sh/uv/releases/download/0.8.6/uv-x86_64-unknown-linux-gnu.tar.gz /tmp/uv.tar.gz
RUN tar -xzf /tmp/uv.tar.gz --strip-components=1 && mv uv /usr/local/bin/uv

WORKDIR /comfyui
RUN uv venv venv
ENV VIRTUAL_ENV=/comfyui/venv
ENV PATH="/comfyui/venv/bin:$PATH"

# Install PyTorch
RUN uv pip install torch==${TORCH_VERSION} torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu126

# Install Common Comfy Deps
RUN uv pip install \
    einops tokenizers pyyaml pillow scipy tqdm psutil kornia spandrel soundfile \
    huggingface_hub[cli] huggingface_hub[hf_transfer] \
    diffusers transformers accelerate sentencepiece protobuf torchsde

# Install Custom Wheels from builder
COPY --from=builder_heavy /dist /tmp/wheels
RUN uv pip install /tmp/wheels/*.whl && rm -rf /tmp/wheels

# Install ComfyUI
ARG COMFYUI_REF=master
RUN git clone --depth 1 --branch ${COMFYUI_REF} https://github.com/comfyanonymous/ComfyUI . && \
    git init . && \
    git remote add origin https://github.com/comfyanonymous/ComfyUI && \
    uv pip install -r requirements.txt

# Install Manager
ENV COMFYUI_PATH=/comfyui
RUN git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager /comfyui-manager && \
    uv pip install -r /comfyui-manager/requirements.txt && \
    python /comfyui-manager/cm-cli.py update all && \
    mv /comfyui/user/default/ComfyUI-Manager/cache /comfyui-manager-cache

# Entrypoint
COPY <<EOF /entrypoint.sh
#!/bin/bash
set -e
mkdir -p /comfyui/custom_nodes
ln -sf /comfyui-manager /comfyui/custom_nodes/ComfyUI-Manager
mkdir -p /comfyui/user/default/ComfyUI-Manager
ln -sf /comfyui-manager-cache /comfyui/user/default/ComfyUI-Manager/cache

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
export XFORMERS_IGNORE_FLASH_VERSION_CHECK=1
echo "Starting ComfyUI..."
exec python main.py --listen "\$@"
EOF

RUN chmod +x /entrypoint.sh
EXPOSE 8188
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["/entrypoint.sh"]
