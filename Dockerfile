# =============================================================
# RunPod Serverless Worker - v4 (2026-04-29)
# Pipeline: Image Gen (Z-Image utility + Illustrious-XL v2.0-stable +
#           JANKU v7.77 anime) +
#           Layer Decomposition (See-through) + Inpaint
#           (BrushNet + Inpaint-CropAndStitch) + Identity
#           (PuLID-SDXL + IP-Adapter Plus) + Video (WAN 2.2 I2V) +
#           Lazy Embeddings (lazypos/lazyneg textual inversion)
# GPU Target: NVIDIA H200 (Hopper, HBM3e)
#
# v4 changes vs v3:
#   - NO Dockerfile-level changes required (functionally identical).
#   - Storage path migration /runpod-volume/models/ → /workspace/model/
#     is RUNTIME-ONLY (start.sh + extra_model_paths.yaml). The Dockerfile
#     bakes no host-mount path; the volume is mounted by the RunPod
#     endpoint config.
#   - 3 Civitai resources surveyed (Character Sheet LoRA, Z-Image sampler
#     article, Lazy Embeddings) require no custom-node additions.
#     Lazy Embeddings is loaded by ComfyUI core (textual inversion
#     directory under models/embeddings/).
#   - Tag bumped to v4 for documentation hygiene only.
# =============================================================

# 1. Base Image: NVIDIA NGC PyTorch — H200/Hopper-tuned, CUDA included.
FROM nvcr.io/nvidia/pytorch:25.01-py3

# ── H200 & Serverless 전용 환경 변수 ──
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV COMFY_DIR=/comfyui

# [최적화 1] Serverless 콜드스타트 부팅 속도 향상을 위한 CUDA 지연 로딩.
ENV CUDA_MODULE_LOADING=LAZY
# [최적화 2] H200(Hopper) 아키텍처 전용 타겟팅. 빌드 속도 단축.
ENV TORCH_CUDA_ARCH_LIST="9.0"

# ── System dependencies ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    git wget curl ffmpeg aria2 \
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── Flash Attention ──
ENV MAX_JOBS=8
RUN python3 -c "import flash_attn; print(f'[build] flash-attn {flash_attn.__version__} already present, skipping install.')" \
    || pip install --no-cache-dir flash-attn \
       --find-links https://github.com/Dao-AILab/flash-attention/releases \
       --no-build-isolation

# ── Clone ComfyUI (PINNED to v0.20.1, Apr 27 2026) ──
ARG COMFYUI_REF=64b8457f55cd7fb54ca7a956d9c73b505e903e0c
RUN git clone https://github.com/Comfy-Org/ComfyUI.git ${COMFY_DIR} \
    && cd ${COMFY_DIR} \
    && (git checkout ${COMFYUI_REF} 2>/dev/null \
        || (echo "[build] WARN: ${COMFYUI_REF} not found on Comfy-Org fork; falling back to upstream comfyanonymous." \
            && git remote add upstream https://github.com/comfyanonymous/ComfyUI.git \
            && git fetch upstream \
            && git checkout ${COMFYUI_REF})) \
    && echo "[build] ✓ ComfyUI pinned to $(git rev-parse HEAD)"
WORKDIR ${COMFY_DIR}

# ── Core & Serverless Dependencies ──
RUN pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir \
    runpod websocket-client requests Pillow "imageio[ffmpeg]" av typing_extensions cloudinary

# ── Custom Nodes ──
# v4: No new nodes vs v3. The 3 Civitai resources surveyed for v4 either
# (a) need no node (Lazy Embeddings is core textual inversion), or
# (b) provide no download (Z-Image sampler article is informational), or
# (c) are SKIP-verdict (Character Design Sheet LoRA is out-of-scope for
#     a decomposition pipeline).
RUN cd custom_nodes \
    && git clone https://github.com/rgthree/rgthree-comfy.git \
    && git clone https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git \
    && git clone https://github.com/yolain/ComfyUI-Easy-Use.git \
    && git clone https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git \
    && git clone https://github.com/kijai/ComfyUI-KJNodes.git \
    && git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git \
    && git clone https://github.com/wallen0322/ComfyUI-Wan22FMLF.git \
    && git clone https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git \
    && git clone https://github.com/jtydhr88/ComfyUI-See-through.git \
    && git clone https://github.com/1038lab/ComfyUI-RMBG.git \
    && git clone https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch.git \
    && git clone https://github.com/nullquant/ComfyUI-BrushNet.git \
    && git clone https://github.com/cubiq/PuLID_ComfyUI.git \
    && git clone https://github.com/cubiq/ComfyUI_IPAdapter_plus.git \
    && for dir in */ ; do \
         if [ -f "$dir/requirements.txt" ]; then \
           echo "[build] Installing requirements for $dir..." ; \
           pip install --no-cache-dir -r "$dir/requirements.txt" \
             && echo "[build] ✓ $dir requirements OK" \
             || echo "[build] ✗ WARNING: $dir requirements FAILED — check for conflicts"; \
         fi; \
       done \
    && cd ComfyUI-Frame-Interpolation \
    && python3 install.py 2>&1 | tee /tmp/frame_interp_install.log \
    && echo "[build] ✓ ComfyUI-Frame-Interpolation install.py OK" \
    || { echo "[build] ✗ WARNING: ComfyUI-Frame-Interpolation install.py FAILED"; \
         cat /tmp/frame_interp_install.log; }

# ── Aggregated SOTA-stack pip deps (belt-and-suspenders) ──
RUN pip install --no-cache-dir \
    "diffusers>=0.29.0" \
    "accelerate>=0.29.0,<0.32.0" \
    "peft>=0.7.0" \
    "transformers>=4.30.0" \
    "huggingface-hub>=0.19.0" \
    "opencv-python>=4.7.0" \
    "scikit-learn>=1.0.0" \
    "matplotlib" \
    "bitsandbytes>=0.49.2" \
    "transparent-background>=1.1.2" \
    "segment-anything>=1.0" \
    "groundingdino-py>=0.4.0" \
    "onnxruntime>=1.15.0" \
    "onnxruntime-gpu>=1.15.0" \
    "protobuf>=3.20.2,<6.0.0" \
    "hydra-core>=1.3.0" \
    "omegaconf>=2.3.0" \
    "iopath>=0.1.9" \
    "decord" \
    "ftfy" \
    "facexlib" \
    "insightface" \
    "timm"

# ── RIFE 4.9 Baking ──
RUN mkdir -p custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/rife \
    && curl -L -A "Mozilla/5.0" -o custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/rife/rife49.pth \
    "https://huggingface.co/Isi99999/Frame_Interpolation_Models/resolve/main/rife49.pth" \
    && echo "[build] ✓ rife49.pth downloaded: $(du -sh custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/rife/rife49.pth | cut -f1)"

# ── 캐시 정리 (Serverless 이미지 경량화) ──
RUN rm -rf /root/.cache/pip /tmp/frame_interp_install.log

# ── Config files ──
COPY extra_model_paths.yaml ${COMFY_DIR}/extra_model_paths.yaml
COPY handler.py /handler.py
COPY start.sh /start.sh
RUN chmod +x /start.sh

# ── Entrypoint ──
WORKDIR /
CMD ["/start.sh"]
