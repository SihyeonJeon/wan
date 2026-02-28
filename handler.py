import json
import os
import subprocess
import sys
import time
import traceback
import urllib.request
import uuid

import runpod
import cloudinary
import cloudinary.uploader

# ── Config ────────────────────────────────────────────────────
COMFY_HOST = "127.0.0.1"
COMFY_PORT = 8188
COMFY_URL  = f"http://{COMFY_HOST}:{COMFY_PORT}"
COMFY_DIR  = os.environ.get("COMFY_DIR", "/comfyui")

STARTUP_TIMEOUT   = int(os.environ.get("STARTUP_TIMEOUT", 300))
EXECUTION_TIMEOUT = int(os.environ.get("EXECUTION_TIMEOUT", 2400))

# Cloudinary 설정 (RunPod Environment Variables에서 CLOUDINARY_URL을 읽어옵니다)
# 예: CLOUDINARY_URL=cloudinary://API_KEY:API_SECRET@CLOUD_NAME
cloudinary.config(secure=True)

comfy_process = None

def log(msg: str):
    print(f"[handler] {msg}", flush=True)

# (start_comfyui, wait_for_comfyui, upload_image_to_comfyui, queue_prompt, wait_for_execution 함수는 기존과 동일하게 유지)

# ── Output retrieval & Cloudinary Upload ──────────────────────
def get_and_upload_outputs(prompt_id: str):
    """
    ComfyUI 출력 폴더에서 직접 파일을 읽어 Cloudinary에 업로드하고 URL만 반환합니다.
    Base64 인코딩/디코딩 오버헤드를 완전히 제거합니다.
    """
    history = json.loads(
        urllib.request.urlopen(f"{COMFY_URL}/history/{prompt_id}", timeout=30).read()
    )
    if prompt_id not in history:
        raise RuntimeError(f"Prompt {prompt_id} not found in history")

    outputs = history[prompt_id].get("outputs", {})
    video_urls = []

    for node_id, node_out in outputs.items():
        # VHS 노드는 보통 "gifs" 또는 "videos" 키로 출력 정보를 넘깁니다.
        for vkey in ("videos", "gifs"):
            for vid_info in node_out.get(vkey, []):
                if vid_info.get("type") == "temp":
                    continue
                
                fname = vid_info.get("filename", "")
                subfolder = vid_info.get("subfolder", "")
                if not fname:
                    continue

                # 1. ComfyUI 로컬 디스크에서 다이렉트로 파일 경로 구성
                local_file_path = os.path.join(COMFY_DIR, "output", subfolder, fname)
                
                if not os.path.exists(local_file_path):
                    log(f"WARNING: File not found on disk -> {local_file_path}")
                    continue

                # 2. Cloudinary 다이렉트 업로드 (스트리밍 업로드)
                log(f"Uploading to Cloudinary: {fname} ({os.path.getsize(local_file_path)//1024} KB)")
                upload_resp = cloudinary.uploader.upload(
                    local_file_path,
                    resource_type="video",
                    folder="wan22_i2v_outputs", # Cloudinary 내 폴더명
                    chunk_size=6000000          # 대용량 비디오를 위한 청크 업로드(6MB)
                )
                
                video_url = upload_resp.get("secure_url")
                log(f"Upload Complete! URL: {video_url}")
                
                video_urls.append({
                    "filename": fname,
                    "url": video_url
                })

                # 3. 업로드 완료 후 로컬 파일 삭제 (H200 디스크 공간 확보 및 I/O 최적화)
                try:
                    os.remove(local_file_path)
                except Exception as e:
                    log(f"Failed to remove local file: {e}")

    return video_urls

# ── RunPod handler ────────────────────────────────────────────
def handler(event: dict) -> dict:
    try:
        job_input = event.get("input", {})
        workflow  = job_input.get("workflow")
        if not workflow:
            return {"error": "No 'workflow' key in input"}

        # 이전 단계(싼 GPU)에서 만든 Z-Image의 URL을 받아 ComfyUI에 주입
        for img_entry in job_input.get("images", []):
            name = img_entry.get("name", "input_image.png")
            url  = img_entry.get("image", "")
            if url:
                actual_name = upload_image_to_comfyui(name, url)
                # LoadImage 노드를 찾아서 파일명 업데이트
                for node_id, node_data in workflow.items():
                    if node_data.get("class_type") == "LoadImage":
                        node_data["inputs"]["image"] = actual_name
                        break # 하나만 처리한다고 가정

        client_id = str(uuid.uuid4())
        log(f"Queuing prompt (client={client_id})")

        result    = queue_prompt(workflow, client_id)
        prompt_id = result.get("prompt_id")
        if not prompt_id:
            return {"error": f"Failed to queue: {result}"}

        log(f"Prompt ID: {prompt_id}")
        wait_for_execution(prompt_id, client_id)

        # Base64 대신 Cloudinary URL 리스트 반환
        video_results = get_and_upload_outputs(prompt_id)
        
        if not video_results:
            return {"error": "No videos generated or uploaded"}

        return {
            "status": "success",
            "video_count": len(video_results),
            "videos": video_results
        }

    except Exception:
        log(f"Handler exception:\n{traceback.format_exc()}")
        return {"error": traceback.format_exc()}

# (Entry point __main__ 부분은 기존과 동일하게 유지)
