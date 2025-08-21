# syntax=docker/dockerfile:1.7
# Torch 2.6 + CUDA 12.4 + cuDNN9 + nvcc included
FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-devel

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=${CUDA_HOME}/bin:${PATH}
ENV LD_LIBRARY_PATH=${CUDA_HOME}/lib64:${LD_LIBRARY_PATH}
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1

# ------------ system deps ------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      git build-essential pkg-config cmake ninja-build \
      libssl-dev libffi-dev ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN nvcc --version

# ------------ layout ------------
ARG APP_DIR=/opt/app
RUN mkdir -p ${APP_DIR} /models
WORKDIR ${APP_DIR}

# ------------ python deps (torch already present) ------------
RUN pip install --upgrade pip wheel setuptools \
 && pip install \
      diffusers transformers accelerate sentencepiece protobuf \
      huggingface_hub comfy-cli simpleeval

# ------------ ComfyUI ------------
# Build-arg lets you pin to a commit/branch from your workflow
ARG COMFYUI_REF=master
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI ${APP_DIR}/ComfyUI \
 || (git clone https://github.com/comfyanonymous/ComfyUI ${APP_DIR}/ComfyUI)
WORKDIR ${APP_DIR}/ComfyUI
RUN git fetch --all --tags || true && git checkout ${COMFYUI_REF} || true
RUN pip install -r requirements.txt

# ComfyUI Manager
WORKDIR ${APP_DIR}/ComfyUI/custom_nodes
RUN git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager comfyui-manager

# ------------ ComfyUI-nunchaku node ------------
RUN git clone --depth=1 https://github.com/mit-han-lab/ComfyUI-nunchaku
# (optional) ship example workflows
RUN mkdir -p ${APP_DIR}/ComfyUI/user/default/workflows \
 && cp -r ComfyUI-nunchaku/workflows/* ${APP_DIR}/ComfyUI/user/default/workflows/ || true

# ------------ Nunchaku backend: wheel OR source ------------
# If you provide a wheel URL, we install it (preferred: faster/leaner on GH runners)
# Example wheel URL (update as releases change):
# https://github.com/mit-han-lab/nunchaku/releases/download/v0.2.0/nunchaku-0.2.0+torch2.6-cp311-cp311-linux_x86_64.whl
ARG NUNCHAKU_WHEEL_URL=""
RUN if [ -n "$NUNCHAKU_WHEEL_URL" ]; then \
      echo "Installing Nunchaku wheel: $NUNCHAKU_WHEEL_URL" && \
      pip install "$NUNCHAKU_WHEEL_URL"; \
    else \
      echo "No wheel URL supplied; building Nunchaku from source (uses nvcc)"; \
      cd ${APP_DIR} && git clone --depth=1 https://github.com/nunchaku-tech/nunchaku nunchaku && \
      cd nunchaku && git submodule update --init --recursive && \
      # Avoid PEP517 isolation to reduce extra downloads; tmpfs holds build temps in RAM
      --mount=type=tmpfs,target=/tmp true; \
    fi

# Separate layer for the source build (uses BuildKit tmpfs)
RUN --mount=type=tmpfs,target=/tmp \
    if [ -z "$NUNCHAKU_WHEEL_URL" ]; then \
      cd ${APP_DIR}/nunchaku && \
      PIP_NO_BUILD_ISOLATION=1 \
      NUNCHAKU_INSTALL_MODE=ALL \
      pip install -e . --prefer-binary; \
    else \
      echo "Wheel path provided; skipping source build."; \
    fi

# ------------ non-root runtime ------------
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser ${APP_DIR} /models
USER appuser

# ------------ runtime ------------
WORKDIR ${APP_DIR}/ComfyUI
EXPOSE 8188
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV COMFYUI_MODELS_DIR=/models
ENTRYPOINT ["python", "main.py", "--listen", "--port", "8188"]
