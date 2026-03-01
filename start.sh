#!/bin/bash
set -e

echo "[startup] H200 Worker Initialization (WAN 2.2 I2V + Image Generation)"

# ── 1. RIFE49 모델 심볼릭 링크 ──
BAKED_RIFE="/comfyui/custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/rife/rife49.pth"
RIFE_UPPER_DIR="/comfyui/custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/RIFE"

mkdir -p "$RIFE_UPPER_DIR"
if [ -f "$BAKED_RIFE" ]; then
    ln -sf "$BAKED_RIFE" "$RIFE_UPPER_DIR/rife49.pth"
    echo "[startup] ✓ Baked RIFE49 ready."
fi

# ── 2. 네트워크 볼륨 확인 및 로컬 NVMe 캐싱 ──
NET_VOL="/runpod-volume/models"
LOCAL_MODELS="/comfyui/models"

if [ -d "$NET_VOL" ]; then
    echo "[startup] ✓ Network volume mounted."
    
    mkdir -p "$LOCAL_MODELS/diffusion_models"
    mkdir -p "$LOCAL_MODELS/clip"
    mkdir -p "$LOCAL_MODELS/checkpoints" # 이미지 모델용 디렉토리
    
    echo "[startup] ⚡ Caching heavy models to local NVMe..."
    
    # [비디오] Wan 2.2 UNET 캐싱
    if [ ! -f "$LOCAL_MODELS/diffusion_models/wan22_i2vHighV21.safetensors" ]; then
        if [ -f "$NET_VOL/diffusion_models/wan22_i2vHighV21.safetensors" ]; then
            cp "$NET_VOL/diffusion_models/wan22_i2vHighV21.safetensors" "$LOCAL_MODELS/diffusion_models/"
            echo "  - wan22_i2vHighV21.safetensors cached."
        fi
    fi
    
    # [비디오] UMT5_XXL 캐싱
    if [ ! -f "$LOCAL_MODELS/clip/umt5_xxl_fp16.safetensors" ]; then
        if [ -f "$NET_VOL/clip/umt5_xxl_fp16.safetensors" ]; then
            cp "$NET_VOL/clip/umt5_xxl_fp16.safetensors" "$LOCAL_MODELS/clip/"
            echo "  - umt5_xxl_fp16.safetensors cached."
        fi
    fi

    # [이미지] Image Generation 전용 모델 캐싱 (예: SDXL / Flux - 사용하는 파일명으로 수정 필요)
    # if [ ! -f "$LOCAL_MODELS/checkpoints/your_image_model.safetensors" ]; then
    #     if [ -f "$NET_VOL/checkpoints/your_image_model.safetensors" ]; then
    #         cp "$NET_VOL/checkpoints/your_image_model.safetensors" "$LOCAL_MODELS/checkpoints/"
    #         echo "  - your_image_model.safetensors cached."
    #     fi
    # fi
    
else
    echo "[startup] ✗ FATAL: /runpod-volume/models NOT found! Models are missing."
fi

echo "[startup] Starting handler.py ..."
exec python3 -u /handler.py
