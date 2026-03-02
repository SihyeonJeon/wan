# =============================================================
# RunPod Serverless Worker - Optimized for H200 (Hopper)
# Pipeline: Image Generation (n8n Base64) + Video (WAN 2.2 I2V)
# GPU Target: NVIDIA H200
# =============================================================

# 1. Base Image: H200의 성능(HBM3e, Hopper 아키텍처)을 완벽히 지원하는 NVIDIA NGC 공식 이미지 사용
FROM nvcr.io/nvidia/pytorch:25.01-py3

# ── H200 & Serverless 전용 환경 변수 ──
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV COMFY_DIR=/comfyui

# [최적화 1] Serverless 콜드스타트 부팅 속도 향상을 위한 CUDA 지연 로딩
ENV CUDA_MODULE_LOADING=LAZY 
# [최적화 2] H200(Hopper) 아키텍처 전용 타겟팅. 빌드 속도 단축 및 타겟 최적화.
ENV TORCH_CUDA_ARCH_LIST="9.0"

# ── System dependencies ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    git wget curl ffmpeg aria2 \
    libgl1-mesa-glx libglib2.0-0 libsm6 libxext6 libxrender-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── Flash Attention 설치 ──
# TORCH_CUDA_ARCH_LIST="9.0" 덕분에 모든 아키텍처를 순회하며 컴파일하지 않아 빌드가 매우 빠름
ENV MAX_JOBS=8
RUN pip install --no-cache-dir flash-attn --no-build-isolation

# ── Clone latest ComfyUI ──
RUN git clone https://github.com/Comfy-Org/ComfyUI.git ${COMFY_DIR}
WORKDIR ${COMFY_DIR}

# ── Core & Serverless Dependencies ──
# [최적화 3] Requirements와 RunPod 종속성을 한 번의 RUN으로 묶어 이미지 레이어 수 감소
RUN pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir \
    runpod websocket-client requests Pillow "imageio[ffmpeg]" av typing_extensions cloudinary

# ── Custom Nodes ──
# [최적화 4] Serverless는 도커 이미지 레이어가 적을수록 Pull 속도(콜드스타트)가 빠릅니다. 
# 여러 번의 RUN을 단일 RUN으로 병합하고 반복문을 통해 requirements를 한 번에 처리합니다.
RUN cd custom_nodes \
    && git clone https://github.com/rgthree/rgthree-comfy.git \
    && git clone https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git \
    && git clone https://github.com/yolain/ComfyUI-Easy-Use.git \
    && git clone https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git \
    && git clone https://github.com/kijai/ComfyUI-KJNodes.git \
    && git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git \
    && git clone https://github.com/wallen0322/ComfyUI-Wan22FMLF.git \
    && git clone https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git \
    && for dir in */ ; do \
         if [ -f "$dir/requirements.txt" ]; then \
           pip install --no-cache-dir -r "$dir/requirements.txt" || true; \
         fi; \
       done \
    && cd ComfyUI-Frame-Interpolation && python3 install.py || true

# ── RIFE 4.9 Baking ──
RUN mkdir -p custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/rife \
    && curl -L -A "Mozilla/5.0" -o custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/rife/rife49.pth \
    "https://huggingface.co/Isi99999/Frame_Interpolation_Models/resolve/main/rife49.pth" \
    && sed -i \
    's|BASE_MODEL_DOWNLOAD_URLS = \[.*\]|BASE_MODEL_DOWNLOAD_URLS = ["https://huggingface.co/Isi99999/Frame_Interpolation_Models/resolve/main/"]|' \
    custom_nodes/ComfyUI-Frame-Interpolation/vfi_utils.py \
    && grep "BASE_MODEL_DOWNLOAD_URLS" custom_nodes/ComfyUI-Frame-Interpolation/vfi_utils.py

# ── 캐시 정리 (Serverless 이미지 경량화) ──
RUN rm -rf /root/.cache/pip

# ── Config files ──
COPY extra_model_paths.yaml ${COMFY_DIR}/extra_model_paths.yaml
COPY handler.py /handler.py
COPY start.sh /start.sh
RUN chmod +x /start.sh

# ── Verify ──
WORKDIR /
CMD ["/start.sh"]
