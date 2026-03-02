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
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── Flash Attention 설치 ──
# NGC pytorch:25.01 이미지에 flash-attn이 이미 포함되어 있는지 확인 후 미포함 시만 설치
# 사전 빌드 wheel을 우선 탐색하여 소스 컴파일을 회피함으로써 빌드 시간을 대폭 단축
ENV MAX_JOBS=8
RUN python3 -c "import flash_attn; print(f'[build] flash-attn {flash_attn.__version__} already present in base image, skipping install.')" \
    || pip install --no-cache-dir flash-attn \
       --find-links https://github.com/Dao-AILab/flash-attention/releases \
       --no-build-isolation

# ── Clone latest ComfyUI ──
RUN git clone https://github.com/Comfy-Org/ComfyUI.git ${COMFY_DIR}
WORKDIR ${COMFY_DIR}

# ── Core & Serverless Dependencies ──
# [최적화 3] Requirements와 RunPod 종속성을 한 번의 RUN으로 묶어 이미지 레이어 수 감소
RUN pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir \
    runpod websocket-client requests Pillow "imageio[ffmpeg]" av typing_extensions cloudinary

# ── Custom Nodes ──
# [최적화 4] 여러 번의 RUN을 단일 RUN으로 병합하고 반복문으로 requirements를 한 번에 처리
# install.py 실패 시 조용히 무시하지 않고 로그를 남겨 런타임 오류를 빌드 시점에 조기 발견
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

# ── RIFE 4.9 Baking ──
# RIFE 모델은 네트워크 볼륨에 없으므로 이미지에 포함.
# vfi_utils.py URL 패치는 rife49.pth가 이미 존재하면 다운로드 트리거 자체가 발생하지 않으므로 불필요하여 제거.
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

# ── Verify ──
WORKDIR /
CMD ["/start.sh"]
