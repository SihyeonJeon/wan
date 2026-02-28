#!/bin/bash
set -e

echo "[startup] H200 WAN 2.2 I2V + RIFE Worker Initialization"

# ── RIFE49 모델 심볼릭 링크 (대소문자 문제 방지) ──
# Docker 빌드 시 구워둔 모델을 노드가 인식할 수 있도록 처리
BAKED_RIFE="/comfyui/custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/rife/rife49.pth"
RIFE_UPPER_DIR="/comfyui/custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/RIFE"

mkdir -p "$RIFE_UPPER_DIR"
if [ -f "$BAKED_RIFE" ]; then
    ln -sf "$BAKED_RIFE" "$RIFE_UPPER_DIR/rife49.pth"
    echo "[startup] ✓ Baked RIFE49 ready."
fi

# ── 네트워크 볼륨 마운트 확인 ──
if [ -d "/runpod-volume/models" ]; then
    echo "[startup] ✓ Network volume mounted."
else
    echo "[startup] ✗ FATAL: /runpod-volume/models NOT found! Models are missing."
    # 볼륨이 없으면 ComfyUI가 모델을 찾지 못해 터지므로 경고를 띄웁니다.
fi

echo "[startup] Starting handler.py ..."
exec python3 -u /handler.py
