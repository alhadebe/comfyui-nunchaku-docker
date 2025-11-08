# syntax=docker/dockerfile:1.7

############################
# 1) BUILDER STAGE
############################
# *** CHANGED LINE ***
# Use a valid and existing PyTorch image tag from Docker Hub
FROM pytorch/pytorch:2.3.1-cuda12.1-cudnn8-devel AS builder

# Set environment variables for non-interactive installation
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    PATH=/opt/venv/bin:$PATH \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# ARG for ComfyUI version, defaults to master
ARG COMFYUI_REF=master
ARG APP_DIR=/opt/app

# Install build-time system dependencies
RUN --mount=type=cache,id=apt-builder,target=/var/cache/apt \
    apt-get update && apt-get install -y --no-install-recommends \
      git \
      build-essential \
      cmake \
    && rm -rf /var/lib/apt/lists/*

# Create a virtual environment
RUN python3 -m venv /opt/venv

# --- Install Python Dependencies ---
# Install ComfyUI's core requirements first
# Note: torch is already in the base image
RUN --mount=type=cache,id=pip-cache,target=/root/.cache/pip \
    pip install \
      torchvision \
      torchaudio

# --- Clone ComfyUI and Custom Nodes ---
WORKDIR ${APP_DIR}
RUN git clone https://github.com/comfyanonymous/ComfyUI.git
WORKDIR ${APP_DIR}/ComfyUI
# Check out a specific version if needed for reproducibility
RUN git checkout ${COMFYUI_REF}

# Install ComfyUI's python requirements
RUN --mount=type=cache,id=pip-cache,target=/root/.cache/pip \
    pip install -r requirements.txt

# Clone custom nodes
WORKDIR ${APP_DIR}/ComfyUI/custom_nodes
RUN git clone https://github.com/ltdrdata/ComfyUI-Manager.git
RUN git clone https://github.com/nunchaku-tech/ComfyUI-nunchaku.git

# Install requirements for custom nodes
RUN --mount=type=cache,id=pip-cache,target=/root/.cache/pip \
    pip install -r ComfyUI-nunchaku/requirements.txt

# Clean up caches in the venv to reduce size
RUN find /opt/venv -type d -name '__pycache__' -prune -exec rm -rf {} +


############################
# 2) FINAL RUNTIME STAGE
############################
# *** CHANGED LINE ***
# Use the matching 'runtime' version of the valid image tag
FROM pytorch/pytorch:2.3.1-cuda12.1-cudnn8-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    PATH=/opt/venv/bin:$PATH \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

ARG APP_DIR=/opt/app

# Install runtime-only system dependencies like 'tini'
RUN --mount=type=cache,id=apt-final,target=/var/cache/apt \
    apt-get update && apt-get install -y --no-install-recommends \
      tini \
    && rm -rf /var/lib/apt/lists/*

# Copy the Python environment and application code from the builder stage
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder ${APP_DIR}/ComfyUI ${APP_DIR}/ComfyUI

# Create a non-root user and set up permissions
RUN useradd -m -u 1000 appuser && \
    mkdir -p /models && \
    chown -R appuser:appuser ${APP_DIR} /models

USER appuser
WORKDIR ${APP_DIR}/ComfyUI

EXPOSE 8188

# Use tini as the entrypoint to properly manage the application process
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python3", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
