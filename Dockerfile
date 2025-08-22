# syntax=docker/dockerfile:1.7

# Torch + CUDA already included to avoid big pip downloads
FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-devel

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:$PATH \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH \
    PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1

# --- Build args that control which wheel we fetch ---
# Matches the base image (Python 3.11 → cp311)
ARG PYTAG=cp311
# Must match the Torch major.minor in the base image
ARG TORCH_MAJOR=2.6
# Platform filter for wheel
ARG WHEEL_PLAT=linux_x86_64

# Where we work + where you’ll mount models
ARG APP_DIR=/opt/app
RUN mkdir -p ${APP_DIR} /models
WORKDIR ${APP_DIR}

# Basic build tools + git
RUN apt-get update && apt-get install -y --no-install-recommends \
      git build-essential pkg-config cmake ninja-build \
      libssl-dev libffi-dev ca-certificates curl jq \
  && rm -rf /var/lib/apt/lists/*

# sanity: nvcc present from base CUDA
RUN nvcc --version || true

# Python libs (Torch already in base)
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

# Manager node
WORKDIR ${APP_DIR}/ComfyUI/custom_nodes
RUN git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager comfyui-manager || true

# Nunchaku custom node (workflows folder is optional)
RUN git clone --depth=1 https://github.com/mit-han-lab/ComfyUI-nunchaku || true
RUN mkdir -p ${APP_DIR}/ComfyUI/user/default/workflows \
 && if [ -d "ComfyUI-nunchaku/workflows" ]; then \
      cp -r ComfyUI-nunchaku/workflows/* ${APP_DIR}/ComfyUI/user/default/workflows/; \
    fi

# --- Install latest matching Nunchaku wheel from Hugging Face ---
# We use huggingface_hub from pip (installed above) and pick the newest filename
# matching "+torch${TORCH_MAJOR}" and "${PYTAG}" and "${WHEEL_PLAT}".
WORKDIR ${APP_DIR}
RUN python - <<'PY'
from huggingface_hub import list_repo_files, hf_hub_download
import os, re, sys
repo = "nunchaku-tech/nunchaku"
torch_major = os.environ.get("TORCH_MAJOR", "2.6")
pytag = os.environ.get("PYTAG", "cp311")
plat = os.environ.get("WHEEL_PLAT", "linux_x86_64")

files = [f for f in list_repo_files(repo) if f.endswith(".whl")]
cands = [f for f in files if f"+torch{torch_major}" in f and pytag in f and plat in f]

if not cands:
    # fallback: pick any wheel for this pytag+plat (even if torch version is newer),
    # sorted so the last item is the newest by filename
    cands = [f for f in files if pytag in f and plat in f]
    if not cands:
        print("No matching Nunchaku wheel found on HF.", file=sys.stderr)
        sys.exit(1)

cands.sort()
chosen = cands[-1]
path = hf_hub_download(repo_id=repo, filename=chosen, local_dir="/tmp")
print(path)
PY
# Install the printed wheel path
RUN pip install "$(tail -n1 /var/lib/docker/containers/*/*-json.log 2>/dev/null | sed -n 's/.*"message":"\\(\\/tmp\\/.*\\.whl\\)".*/\\1/p' | tail -n1)" || \
    (echo "Fallback parse; trying to locate wheel under /tmp" && \
     W=$(find /tmp -maxdepth 1 -name 'nunchaku-*.whl' | sort | tail -n1) && \
     pip install "$W")

# --- Non-root runtime user (optional but recommended) ---
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser ${APP_DIR} /models
USER appuser

# --- Runtime ---
WORKDIR ${APP_DIR}/ComfyUI
EXPOSE 8188
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    COMFYUI_MODELS_DIR=/models
ENTRYPOINT ["python", "main.py", "--listen", "--port", "8188"]
