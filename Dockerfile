# syntax=docker/dockerfile:1.7

FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-devel

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:$PATH \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH \
    PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1

# Build args (Torch & Python already fixed by base image)
ARG APP_DIR=/opt/app
ARG NUNCHAKU_WHEEL_URL

RUN apt-get update && apt-get install -y --no-install-recommends \
      git build-essential pkg-config cmake ninja-build \
      libssl-dev libffi-dev ca-certificates curl jq \
  && rm -rf /var/lib/apt/lists/*

# OpenCV runtime libs (for cv2)
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
 && rm -rf /var/lib/apt/lists/*
# sanity
RUN nvcc --version || true

RUN mkdir -p ${APP_DIR} /models
WORKDIR ${APP_DIR}

# light Python deps. (Torch is already in base.)
RUN pip install --upgrade pip wheel setuptools \
 && pip install \
      diffusers transformers accelerate sentencepiece protobuf \
      huggingface_hub comfy-cli simpleeval \
      toml opencv-python-headless \
      insightface onnxruntime-gpu \
      facexlib basicsr scikit-image \
      peft gradio spaces timm xformers lark

# --- ComfyUI ---
ARG COMFYUI_REF=master
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI ${APP_DIR}/ComfyUI \
  || (git clone https://github.com/comfyanonymous/ComfyUI ${APP_DIR}/ComfyUI)
WORKDIR ${APP_DIR}/ComfyUI
RUN git fetch --all --tags || true && git checkout ${COMFYUI_REF} || true
RUN pip install -r requirements.txt

# Manager & Nunchaku custom node
WORKDIR ${APP_DIR}/ComfyUI/custom_nodes
RUN git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager comfyui-manager || true
RUN git clone --depth=1 https://github.com/nunchaku-tech/ComfyUI-nunchaku || true
RUN mkdir -p ${APP_DIR}/ComfyUI/user/default/workflows \
 && if [ -d "ComfyUI-nunchaku/workflows" ]; then \
      cp -r ComfyUI-nunchaku/workflows/* ${APP_DIR}/ComfyUI/user/default/workflows/; \
    fi

# --- Nunchaku from GitHub RELEASE wheel (required) ---
WORKDIR /tmp
RUN test -n "$NUNCHAKU_WHEEL_URL" || (echo "NUNCHAKU_WHEEL_URL is required. Pass it via --build-arg." && exit 1) \
 && echo "Installing Nunchaku wheel from: $NUNCHAKU_WHEEL_URL" \
 && curl -fLO "$NUNCHAKU_WHEEL_URL" \
 && ls -lh *.whl \
 && pip install --no-cache-dir ./*.whl

# back to app dir
WORKDIR ${APP_DIR}/ComfyUI

# --- Non-root user (optional) ---
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser ${APP_DIR} /models
USER appuser

# --- Runtime ---
WORKDIR ${APP_DIR}/ComfyUI
EXPOSE 8188
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    COMFYUI_MODELS_DIR=/models
ENTRYPOINT ["python", "main.py", "--listen", "--port", "8188"]
