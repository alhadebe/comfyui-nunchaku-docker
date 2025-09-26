# syntax=docker/dockerfile:1.7

############################
# 1) BUILDER (has compilers)
############################
FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-devel AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:$PATH \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH \
    PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1

ARG APP_DIR=/opt/app
ARG NUNCHAKU_WHEEL_URL
ARG COMFYUI_REF=master

# System deps only in builder
RUN --mount=type=cache,id=apt-builder,target=/var/cache/apt \
    apt-get update && apt-get install -y --no-install-recommends \
      git build-essential pkg-config cmake ninja-build \
      libssl-dev libffi-dev ca-certificates curl jq \
    && rm -rf /var/lib/apt/lists/*

# Create venv so we can copy just it later
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH

# Minimal pip bootstrap
RUN python -m pip install --upgrade pip wheel setuptools

# --- Python deps (Torch already in base image) ---
# NOTE: opencv-python-headless avoids GUI/X dependencies
RUN --mount=type=cache,id=pip-cache,target=/root/.cache/pip \
    pip install \
      diffusers transformers accelerate sentencepiece protobuf \
      huggingface_hub comfy-cli simpleeval \
      toml opencv-python-headless \
      insightface onnxruntime-gpu \
      facexlib basicsr scikit-image \
      peft gradio spaces timm xformers lark

# --- ComfyUI (source only in builder; we’ll copy to final) ---
RUN mkdir -p ${APP_DIR}
WORKDIR ${APP_DIR}
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI ${APP_DIR}/ComfyUI || \
    (git clone https://github.com/comfyanonymous/ComfyUI ${APP_DIR}/ComfyUI)

WORKDIR ${APP_DIR}/ComfyUI
RUN git fetch --all --tags || true && git checkout ${COMFYUI_REF} || true

# Install ComfyUI requirements into the venv
RUN --mount=type=cache,id=pip-cache,target=/root/.cache/pip \
    pip install -r requirements.txt

# Custom nodes
WORKDIR ${APP_DIR}/ComfyUI/custom_nodes
RUN git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager comfyui-manager || true
RUN git clone --depth=1 https://github.com/nunchaku-tech/ComfyUI-nunchaku || true

# Copy example workflows (optional)
RUN mkdir -p ${APP_DIR}/ComfyUI/user/default/workflows \
 && if [ -d "ComfyUI-nunchaku/workflows" ]; then \
      cp -r ComfyUI-nunchaku/workflows/* ${APP_DIR}/ComfyUI/user/default/workflows/; \
    fi

# --- Install Nunchaku wheel (required) ---
WORKDIR /tmp
RUN test -n "$NUNCHAKU_WHEEL_URL" || (echo "NUNCHAKU_WHEEL_URL is required. Pass it via --build-arg." && exit 1)
RUN curl -fLO "$NUNCHAKU_WHEEL_URL" \
 && ls -lh *.whl \
 && pip install --no-cache-dir ./*.whl

# (Optional) strip caches from venv to shrink copy
RUN find /opt/venv -type d -name '__pycache__' -prune -exec rm -rf {} + || true


################################
# 2) FINAL RUNTIME (no compilers)
################################
FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:/opt/venv/bin:$PATH \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH \
    PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1

ARG APP_DIR=/opt/app

# Runtime-only system libs.
# If you don’t need OpenGL/X11 at runtime, keep this minimal.
# (opencv-python-headless does NOT require libgl1)
RUN --mount=type=cache,id=apt-final,target=/var/cache/apt \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates tini \
    && rm -rf /var/lib/apt/lists/*

# App dirs
RUN mkdir -p ${APP_DIR} /models

# Copy only what we need from the builder
#  - Python venv with all packages
#  - ComfyUI sources + custom nodes + workflows
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder ${APP_DIR}/ComfyUI ${APP_DIR}/ComfyUI

# Non-root user
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser ${APP_DIR} /models
USER appuser

WORKDIR ${APP_DIR}/ComfyUI

EXPOSE 8188
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    COMFYUI_MODELS_DIR=/models

ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["python","main.py","--listen","--port","8188"]
