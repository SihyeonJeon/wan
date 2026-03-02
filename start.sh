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
else
    echo "[startup] ✗ WARNING: rife49.pth not found at $BAKED_RIFE — frame interpolation will fail."
fi

# ── 2. 네트워크 볼륨 연동 (Fast Cold Start 최적화) ──
NET_VOL="/runpod-volume/models"
LOCAL_MODELS="/comfyui/models"

if [ -d "$NET_VOL" ]; then
    echo "[startup] ✓ Network volume mounted."

    mkdir -p "$LOCAL_MODELS/diffusion_models"
    mkdir -p "$LOCAL_MODELS/clip"
    mkdir -p "$LOCAL_MODELS/checkpoints"

    echo "[startup] ⚡ Symlinking heavy models (Skipping NVMe copy for speed)..."

    # [비디오] Wan 2.2 UNET 심볼릭 링크 (0.1초 소요)
    if [ -f "$NET_VOL/diffusion_models/wan22_i2vHighV21.safetensors" ]; then
        ln -sf "$NET_VOL/diffusion_models/wan22_i2vHighV21.safetensors" \
               "$LOCAL_MODELS/diffusion_models/wan22_i2vHighV21.safetensors"
        echo "  - wan22_i2vHighV21.safetensors linked."
    else
        echo "[startup] ✗ WARNING: wan22_i2vHighV21.safetensors not found in network volume."
    fi

    # [비디오] UMT5_XXL 심볼릭 링크
    if [ -f "$NET_VOL/clip/umt5_xxl_fp16.safetensors" ]; then
        ln -sf "$NET_VOL/clip/umt5_xxl_fp16.safetensors" \
               "$LOCAL_MODELS/clip/umt5_xxl_fp16.safetensors"
        echo "  - umt5_xxl_fp16.safetensors linked."
    else
        echo "[startup] ✗ WARNING: umt5_xxl_fp16.safetensors not found in network volume."
    fi

    # [이미지] Image Generation 전용 모델 심볼릭 링크 (필요 시 주석 해제)
    # if [ -f "$NET_VOL/checkpoints/your_image_model.safetensors" ]; then
    #     ln -sf "$NET_VOL/checkpoints/your_image_model.safetensors" "$LOCAL_MODELS/checkpoints/your_image_model.safetensors"
    #     echo "  - your_image_model.safetensors linked."
    # fi

else
    # 볼륨이 안 붙었을 때 워커가 아예 죽어버리는 것을 방지하기 위해 경고만 띄움
    echo "[startup] ✗ WARNING: /runpod-volume/models NOT found! Models are missing."
fi

echo "[startup] Starting handler.py ..."
exec python3 -u /handler.py
