# =============================================================
# RunPod Serverless Worker
# Pipeline: Image Generation (n8n Base64) + Video (WAN 2.2 I2V)
# GPU Target: H200 / A100 80GB
# Base: runpod/pytorch 2.4.0 + Python 3.11 + CUDA 12.4.1
# =============================================================

FROM runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV COMFY_DIR=/comfyui

# ── System dependencies ───────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    git wget curl ffmpeg \
    libgl1-mesa-glx libglib2.0-0 libsm6 libxext6 libxrender-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Clone latest ComfyUI ──────────────────────────────────────
RUN git clone https://github.com/Comfy-Org/ComfyUI.git ${COMFY_DIR}
WORKDIR ${COMFY_DIR}

# ── ComfyUI core dependencies ─────────────────────────────────
RUN python3 -m pip install --no-cache-dir -r requirements.txt

# ── RunPod + handler dependencies ──
RUN python3 -m pip install --no-cache-dir \
    runpod \
    websocket-client \
    requests \
    Pillow \
    "imageio[ffmpeg]" \
    av \
    typing_extensions \
    cloudinary

# ── Custom Nodes ──
RUN cd ${COMFY_DIR}/custom_nodes && \
    git clone https://github.com/rgthree/rgthree-comfy.git && \
    (cd rgthree-comfy && python3 -m pip install --no-cache-dir -r requirements.txt 2>/dev/null || true)

RUN cd ${COMFY_DIR}/custom_nodes && \
    git clone https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git

RUN cd ${COMFY_DIR}/custom_nodes && \
    git clone https://github.com/yolain/ComfyUI-Easy-Use.git && \
    (cd ComfyUI-Easy-Use && python3 -m pip install --no-cache-dir -r requirements.txt 2>/dev/null || true)

RUN cd ${COMFY_DIR}/custom_nodes && \
    git clone https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git

RUN cd ${COMFY_DIR}/custom_nodes && \
    git clone https://github.com/kijai/ComfyUI-KJNodes.git && \
    (cd ComfyUI-KJNodes && python3 -m pip install --no-cache-dir -r requirements.txt 2>/dev/null || true)

RUN cd ${COMFY_DIR}/custom_nodes && \
    git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git && \
    (cd ComfyUI-VideoHelperSuite && python3 -m pip install --no-cache-dir -r requirements.txt || true)

RUN cd ${COMFY_DIR}/custom_nodes && \
    git clone https://github.com/wallen0322/ComfyUI-Wan22FMLF.git && \
    (cd ComfyUI-Wan22FMLF && python3 -m pip install --no-cache-dir -r requirements.txt || true)

RUN cd ${COMFY_DIR}/custom_nodes && \
    git clone https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git && \
    (cd ComfyUI-Frame-Interpolation && python3 -m pip install --no-cache-dir -r requirements.txt || true) && \
    (cd ComfyUI-Frame-Interpolation && python3 install.py || true)

# ── RIFE 4.9 Baking ──
RUN mkdir -p ${COMFY_DIR}/custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/rife && \
    curl -L -A "Mozilla/5.0" -o ${COMFY_DIR}/custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/rife/rife49.pth \
    "https://huggingface.co/Isi99999/Frame_Interpolation_Models/resolve/main/rife49.pth"

# ── Config files ──────────────────────────────────────────────
COPY extra_model_paths.yaml ${COMFY_DIR}/extra_model_paths.yaml
COPY handler.py /handler.py
COPY start.sh /start.sh
RUN chmod +x /start.sh

# ── Verify ────────────────────────────────────────────────────
WORKDIR /
CMD ["/start.sh"]
