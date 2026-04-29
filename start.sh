#!/bin/bash
set -e

echo "[startup] H200 Worker v4 init (image+layer-decomp+inpaint+identity+video+embeddings)"

# ── 0. Constants ──────────────────────────────────────────────
# v4: volume mount migrated from /runpod-volume/models to /workspace/model
#     (singular `model` per user spec). Variable name `NET_VOL` kept for
#     minimal diff vs v3; the value is what changed.
NET_VOL="/workspace/model"
LOCAL_MODELS="/comfyui/models"
SEETHROUGH_NODE_DIR="/comfyui/custom_nodes/ComfyUI-See-through"

# ── 1. RIFE49 baked-into-image symlink ────────────────────────
BAKED_RIFE="/comfyui/custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/rife/rife49.pth"
RIFE_UPPER_DIR="/comfyui/custom_nodes/ComfyUI-Frame-Interpolation/vfi_models/RIFE"
mkdir -p "$RIFE_UPPER_DIR"
if [ -f "$BAKED_RIFE" ]; then
    ln -sf "$BAKED_RIFE" "$RIFE_UPPER_DIR/rife49.pth"
    echo "[startup] ✓ Baked RIFE49 ready."
else
    echo "[startup] ✗ WARNING: rife49.pth not found at $BAKED_RIFE — frame interp will fail."
fi

# ── 2. Workspace volume binding ───────────────────────────────
if [ ! -d "$NET_VOL" ]; then
    echo "[startup] ✗ WARNING: /workspace/model NOT mounted! Continuing without volume."
    exec python3 -u /handler.py
fi

echo "[startup] ✓ Workspace volume mounted at $NET_VOL."

# ── 2a. Ensure all volume-side dirs exist (idempotent) ────────
# A fresh / partially-populated volume must not crash the worker.
# Each mkdir is a noop if the dir already exists.
mkdir -p "$NET_VOL/diffusion_models"
mkdir -p "$NET_VOL/clip"
mkdir -p "$NET_VOL/text_encoders"
mkdir -p "$NET_VOL/clip_vision"
mkdir -p "$NET_VOL/vae"
mkdir -p "$NET_VOL/loras"
mkdir -p "$NET_VOL/checkpoints"        # SDXL/Illustrious-XL v2.0-stable + JANKU v7.77
mkdir -p "$NET_VOL/controlnet"         # reference-only / depth CN
mkdir -p "$NET_VOL/ipadapter"          # IP-Adapter Plus SDXL
mkdir -p "$NET_VOL/pulid"              # PuLID-SDXL v1.1
mkdir -p "$NET_VOL/inpaint"            # BrushNet (per its README)
mkdir -p "$NET_VOL/insightface"        # PuLID antelopev2
mkdir -p "$NET_VOL/rmbg"               # BEN2/SDMatte/BiRefNet
mkdir -p "$NET_VOL/seethrough"         # LayerDiff3D + Marigold
mkdir -p "$NET_VOL/upscale_models"     # forward-compat
mkdir -p "$NET_VOL/embeddings"         # v4 NEW: Lazy Embeddings

# ── 2b. Ensure local mount points exist ───────────────────────
mkdir -p "$LOCAL_MODELS/diffusion_models"
mkdir -p "$LOCAL_MODELS/clip"
mkdir -p "$LOCAL_MODELS/checkpoints"
mkdir -p "$LOCAL_MODELS/controlnet"
mkdir -p "$LOCAL_MODELS/ipadapter"
mkdir -p "$LOCAL_MODELS/pulid"
mkdir -p "$LOCAL_MODELS/inpaint"
mkdir -p "$LOCAL_MODELS/insightface"
mkdir -p "$LOCAL_MODELS/rmbg"
mkdir -p "$LOCAL_MODELS/SeeThrough"
mkdir -p "$LOCAL_MODELS/embeddings"     # v4 NEW

# ── 3. Symlinks: per-file (v2/v3 carryover) ───────────────────
echo "[startup] ⚡ Symlinking heavy models (no NVMe copy)..."

# [video] WAN 2.2 UNET
if [ -f "$NET_VOL/diffusion_models/wan22_i2vHighV21.safetensors" ]; then
    ln -sf "$NET_VOL/diffusion_models/wan22_i2vHighV21.safetensors" \
           "$LOCAL_MODELS/diffusion_models/wan22_i2vHighV21.safetensors"
    echo "  - wan22_i2vHighV21.safetensors linked."
else
    echo "[startup] ✗ WARNING: wan22_i2vHighV21.safetensors not found in volume."
fi

# [video] UMT5_XXL
if [ -f "$NET_VOL/clip/umt5_xxl_fp16.safetensors" ]; then
    ln -sf "$NET_VOL/clip/umt5_xxl_fp16.safetensors" \
           "$LOCAL_MODELS/clip/umt5_xxl_fp16.safetensors"
    echo "  - umt5_xxl_fp16.safetensors linked."
else
    echo "[startup] ✗ WARNING: umt5_xxl_fp16.safetensors not found in volume."
fi

# ── 4. Symlinks: per-directory (v3 + v4) ──────────────────────
# Big categories use directory-level symlinks so that newly-added
# .safetensors files become available without start.sh edits.
# `ln -sfn` (-n: prevent traversal when target is a dir) is used.

# Anime SDXL checkpoints (Illustrious-XL v2.0-stable + JANKU v7.77 + others)
ln -sfn "$NET_VOL/checkpoints" "$LOCAL_MODELS/checkpoints_volume"

# PuLID-SDXL v1.1 weights
ln -sfn "$NET_VOL/pulid" "$LOCAL_MODELS/pulid_volume"

# IP-Adapter Plus SDXL weights
ln -sfn "$NET_VOL/ipadapter" "$LOCAL_MODELS/ipadapter_volume"

# BrushNet weights (BrushNet 노드는 models/inpaint 를 본다)
ln -sfn "$NET_VOL/inpaint" "$LOCAL_MODELS/inpaint_volume"

# ControlNet
ln -sfn "$NET_VOL/controlnet" "$LOCAL_MODELS/controlnet_volume"

# InsightFace (PuLID antelopev2)
ln -sfn "$NET_VOL/insightface" "$LOCAL_MODELS/insightface_volume"

# RMBG / BEN2 / SDMatte / SAM2 / SAM3 / GroundingDINO
ln -sfn "$NET_VOL/rmbg" "$LOCAL_MODELS/rmbg_volume"

# v4 NEW: Lazy Embeddings (textual inversion)
# ComfyUI core resolves embeddings via models/embeddings/ — bind the volume.
ln -sfn "$NET_VOL/embeddings" "$LOCAL_MODELS/embeddings_volume"

# ── 5. See-through node-internal model dirs ───────────────────
# jtydhr88/ComfyUI-See-through 의 README:
#   "models 자동 다운로드, 또는 ComfyUI/models/SeeThrough/ 에 수동 배치."
# 아래 두 symlink 가 `pod_model_downloads.ipynb` 가 받아둔 weights 를
# 노드 기본 lookup 경로로 노출. → cold-start HF 재다운로드 회피.
if [ -d "$NET_VOL/seethrough/layerdiff3d" ]; then
    ln -sfn "$NET_VOL/seethrough/layerdiff3d" "$LOCAL_MODELS/SeeThrough/layerdiff3d"
    echo "  - SeeThrough/layerdiff3d linked."
else
    echo "[startup] ⚠ WARN: $NET_VOL/seethrough/layerdiff3d missing — See-through 첫 호출 시 12GB HF 재다운로드 발생."
fi
if [ -d "$NET_VOL/seethrough/marigold" ]; then
    ln -sfn "$NET_VOL/seethrough/marigold" "$LOCAL_MODELS/SeeThrough/marigold"
    echo "  - SeeThrough/marigold linked."
else
    echo "[startup] ⚠ WARN: $NET_VOL/seethrough/marigold missing — See-through Marigold 재다운로드 발생."
fi

# 일부 빌드의 See-through 노드가 자기 디렉토리 내에서 lookup 하는 케이스 대비:
# custom_nodes 안의 models/ 에도 동일 symlink 를 설치 (중복 무해).
mkdir -p "$SEETHROUGH_NODE_DIR/models"
if [ -d "$NET_VOL/seethrough/layerdiff3d" ]; then
    ln -sfn "$NET_VOL/seethrough/layerdiff3d" "$SEETHROUGH_NODE_DIR/models/layerdiff3d"
fi
if [ -d "$NET_VOL/seethrough/marigold" ]; then
    ln -sfn "$NET_VOL/seethrough/marigold" "$SEETHROUGH_NODE_DIR/models/marigold"
fi

echo "[startup] ✓ v4 symlinks complete."

# ── 6. Launch ─────────────────────────────────────────────────
echo "[startup] Starting handler.py ..."
exec python3 -u /handler.py
