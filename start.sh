#!/bin/bash
set -e

echo "[startup] H200 WAN 2.2 I2V + RIFE Worker Initialization"

# ── 1. RIFE49 모델 심볼릭 링크 ──
BAKED_RIFE="/comfyui/custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/rife/rife49.pth"
RIFE_UPPER_DIR="/comfyui/custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/RIFE"

mkdir -p "$RIFE_UPPER_DIR"
if [ -f "$BAKED_RIFE" ]; then
    ln -sf "$BAKED_RIFE" "$RIFE_UPPER_DIR/rife49.pth"
    echo "[startup] ✓ Baked RIFE49 ready."
fi

# ── 2. 네트워크 볼륨 확인 및 로컬 NVMe 캐싱 (핵심 최적화) ──
NET_VOL="/runpod-volume/models"
LOCAL_MODELS="/comfyui/models"

if [ -d "$NET_VOL" ]; then
    echo "[startup] ✓ Network volume mounted."
    
    # 캐싱할 로컬 디렉토리 생성
    mkdir -p "$LOCAL_MODELS/diffusion_models"
    mkdir -p "$LOCAL_MODELS/clip"
    
    echo "[startup] ⚡ Caching heavy models to local NVMe..."
    # 💡 팁: S3 직접 다운로드(s5cmd)가 가능하다면 cp 대신 s5cmd를 쓰면 3~5배 더 빠릅니다.
    # 여기서는 네트워크 볼륨에서 컨테이너 로컬로 복사하여 I/O 병목을 제거합니다.
    
    # Wan 2.2 UNET 캐싱
    if [ ! -f "$LOCAL_MODELS/diffusion_models/wan22_i2vHighV21.safetensors" ]; then
        cp "$NET_VOL/diffusion_models/wan22_i2vHighV21.safetensors" "$LOCAL_MODELS/diffusion_models/"
        echo "  - wan22_i2vHighV21.safetensors cached."
    fi
    
    # UMT5_XXL 캐싱
    if [ ! -f "$LOCAL_MODELS/clip/umt5_xxl_fp16.safetensors" ]; then
        cp "$NET_VOL/clip/umt5_xxl_fp16.safetensors" "$LOCAL_MODELS/clip/"
        echo "  - umt5_xxl_fp16.safetensors cached."
    fi
    
else
    echo "[startup] ✗ FATAL: /runpod-volume/models NOT found! Models are missing."
fi

echo "[startup] Starting handler.py ..."
exec python3 -u /handler.py
