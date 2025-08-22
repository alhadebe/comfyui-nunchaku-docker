# syntax=docker/dockerfile:1.7
# Torch 2.6 + CUDA 12.4 + cuDNN9 + nvcc
FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-devel

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH} \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# lean build toolchain
RUN apt-get update && apt-get install -y --no-install-recommends \
      git build-essential pkg-config cmake ninja-build \
      libssl-dev libffi-dev ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# sanity check
RUN nvcc --version

ARG APP_DIR=/opt/app
RUN mkdir -p ${APP_DIR} /models
WORKDIR ${APP_DIR}

# Python deps (Torch already present in base image)
RUN pip install --upgrade pip wheel setuptools \
 && pip install \
      diffusers transformers accelerate sentencepiece protobuf \
      huggingface_hub comfy-cli simpleeval

# =========================
# ComfyUI + Manager + Nunchaku node
# =========================
ARG COMFYUI_REF=master
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI ${APP_DIR}/ComfyUI \
  || (git clone https://github.com/comfyanonymous/ComfyUI ${APP_DIR}/ComfyUI)

WORKDIR ${APP_DIR}/ComfyUI
RUN git fetch --all --tags || true && git checkout ${COMFYUI_REF} || true
RUN pip install -r requirements.txt

WORKDIR ${APP_DIR}/ComfyUI/custom_nodes
RUN git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager comfyui-manager || true
RUN git clone --depth=1 https://github.com/mit-han-lab/ComfyUI-nunchaku || true

# copy example workflows only if they exist in that repo
RUN mkdir -p ${APP_DIR}/ComfyUI/user/default/workflows \
 && if [ -d "ComfyUI-nunchaku/workflows" ]; then \
      cp -r ComfyUI-nunchaku/workflows/* ${APP_DIR}/ComfyUI/user/default/workflows/; \
    fi

# =========================
# Nunchaku backend
# =========================
# If provided at build time, we install the wheel (fast).
# Otherwise we fall back to building from source.
ARG NUNCHAKU_WHEEL_URL=""
WORKDIR ${APP_DIR}

RUN if [ -n "$NUNCHAKU_WHEEL_URL" ]; then \
      echo "Installing Nunchaku wheel: $NUNCHAKU_WHEEL_URL" && \
      pip install --no-cache-dir "$NUNCHAKU_WHEEL_URL"; \
    else \
      echo "No wheel URL supplied; cloning Nunchaku for source build"; \
      git clone --depth=1 --recurse-submodules --shallow-submodules \
        https://github.com/nunchaku-tech/nunchaku nunchaku; \
    fi

# Build from source WITHOUT isolation and WITHOUT deps to avoid pulling another PyTorch
WORKDIR ${APP_DIR}/nunchaku
ENV NUNCHAKU_INSTALL_MODE=ALL \
    MAX_JOBS=2
RUN if [ -d "${APP_DIR}/nunchaku" ]; then \
      pip install --no-cache-dir --upgrade pip wheel setuptools ninja cmake && \
      PIP_NO_BUILD_ISOLATION=1 pip install -v --no-deps -e .; \
    else \
      echo "Wheel path used; skipping source build."; \
    fi

# =========================
# runtime
# =========================
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser ${APP_DIR} /models
USER appuser

WORKDIR ${APP_DIR}/ComfyUI
EXPOSE 8188

ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    COMFYUI_MODELS_DIR=/models

ENTRYPOINT ["python", "main.py", "--listen", "--port", "8188"]
