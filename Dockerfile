# syntax=docker/dockerfile:1.7
FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-devel

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=${CUDA_HOME}/bin:${PATH}
ENV LD_LIBRARY_PATH=${CUDA_HOME}/lib64:${LD_LIBRARY_PATH}
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      git build-essential pkg-config cmake ninja-build \
      libssl-dev libffi-dev ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN nvcc --version

ARG APP_DIR=/opt/app
RUN mkdir -p ${APP_DIR} /models
WORKDIR ${APP_DIR}

# Python deps (Torch already in base)
RUN pip install --upgrade pip wheel setuptools \
 && pip install \
      diffusers transformers accelerate sentencepiece protobuf \
      huggingface_hub comfy-cli simpleeval

# --- ComfyUI ---
ARG COMFYUI_REF=master
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI ${APP_DIR}/ComfyUI \
 || (git clone https://github.com/comfyanonymous/ComfyUI ${APP_DIR}/ComfyUI)
WORKDIR ${APP_DIR}/ComfyUI
RUN git fetch --all --tags || true && git checkout ${COMFYUI_REF} || true
RUN pip install -r requirements.txt

# Manager
WORKDIR ${APP_DIR}/ComfyUI/custom_nodes
RUN git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager comfyui-manager

# --- ComfyUI-nunchaku node ---
RUN git clone --depth=1 https://github.com/mit-han-lab/ComfyUI-nunchaku
RUN mkdir -p ${APP_DIR}/ComfyUI/user/default/workflows \
 && cp -r ComfyUI-nunchaku/workflows/* ${APP_DIR}/ComfyUI/user/default/workflows/ || true

# --- Nunchaku: wheel OR source ---
ARG NUNCHAKU_WHEEL_URL=""
WORKDIR ${APP_DIR}
# Step 1: decide path (NO --mount here)
RUN if [ -n "$NUNCHAKU_WHEEL_URL" ]; then \
      echo "Installing Nunchaku wheel: $NUNCHAKU_WHEEL_URL" && \
      pip install "$NUNCHAKU_WHEEL_URL"; \
    else \
      echo "No wheel URL supplied; cloning Nunchaku for source build"; \
      git clone --depth=1 https://github.com/nunchaku-tech/nunchaku nunchaku && \
      cd nunchaku && git submodule update --init --recursive; \
    fi

# Step 2: if source was cloned, build it with tmpfs for /tmp
WORKDIR ${APP_DIR}/nunchaku
ENV NUNCHAKU_INSTALL_MODE=ALL
RUN --mount=type=tmpfs,target=/tmp \
    if [ -d "${APP_DIR}/nunchaku" ]; then \
      PIP_NO_BUILD_ISOLATION=1 pip install -e . --prefer-binary; \
    else \
      echo "Wheel path used; skipping source build."; \
    fi

# --- non-root runtime ---
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser ${APP_DIR} /models
USER appuser

# --- runtime ---
WORKDIR ${APP_DIR}/ComfyUI
EXPOSE 8188
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV COMFYUI_MODELS_DIR=/models
ENTRYPOINT ["python", "main.py", "--listen", "--port", "8188"]
