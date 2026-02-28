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

# ── Cloudinary 하드코딩 설정 ──────────────────────────────────
cloudinary.config(
    cloud_name="dp2azbanc",
    api_key="132448188878379",
    api_secret="uKoaFbyATfGBdc1RdihQqhwySvE",
    secure=True
)

comfy_process = None

def log(msg: str):
    print(f"[handler] {msg}", flush=True)

# ── ComfyUI lifecycle (기존과 동일) ───────────────────────────
def upload_image_to_comfyui(name: str, url: str) -> str:
    import io
    from PIL import Image
    log(f"Downloading image: {url[:80]}")
    img_bytes = urllib.request.urlopen(url, timeout=30).read()
    img = Image.open(io.BytesIO(img_bytes))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    img_bytes = buf.getvalue()
    upload_name = name.rsplit(".", 1)[0] + ".png"
    boundary = "----ComfyBoundary"
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="image"; filename="{upload_name}"\r\n'
        f"Content-Type: image/png\r\n\r\n"
    ).encode() + img_bytes + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(
        f"{COMFY_URL}/upload/image", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    resp = json.loads(urllib.request.urlopen(req, timeout=30).read())
    return resp.get("name", upload_name)

def start_comfyui():
    global comfy_process
    # H200 최적화: --highvram 추가 (메모리 해제 없이 유지하여 Warm Start 시 0초 로딩)
    #             --bf16-unet 추가 (5090/H200 필수)
    cmd = [
        sys.executable, "main.py", "--listen", "0.0.0.0", "--port", str(COMFY_PORT),
        "--disable-auto-launch", 
        "--extra-model-paths-config", f"{COMFY_DIR}/extra_model_paths.yaml", 
        "--bf16-unet", "--highvram" 
    ]
    comfy_process = subprocess.Popen(cmd, cwd=COMFY_DIR)

def wait_for_comfyui() -> bool:
    start, interval = time.time(), 3
    while time.time() - start < STARTUP_TIMEOUT:
        if comfy_process and comfy_process.poll() is not None:
            return False
        try:
            urllib.request.urlopen(f"{COMFY_URL}/system_stats", timeout=5)
            return True
        except:
            time.sleep(interval)
    return False

def queue_prompt(workflow: dict, client_id: str) -> dict:
    payload = json.dumps({"prompt": workflow, "client_id": client_id}).encode()
    req = urllib.request.Request(f"{COMFY_URL}/prompt", data=payload, headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=30).read())

def wait_for_execution(prompt_id: str, client_id: str):
    import websocket
    ws = websocket.create_connection(f"ws://{COMFY_HOST}:{COMFY_PORT}/ws?clientId={client_id}", timeout=EXECUTION_TIMEOUT)
    try:
        deadline = time.time() + EXECUTION_TIMEOUT
        while time.time() < deadline:
            try: raw = ws.recv()
            except websocket.WebSocketTimeoutException: continue
            if not isinstance(raw, str): continue
            msg = json.loads(raw)
            if msg.get("type") == "executing" and msg["data"].get("node") is None and msg["data"].get("prompt_id") == prompt_id:
                return
            elif msg.get("type") == "execution_error":
                raise RuntimeError(f"Node error: {msg['data'].get('exception_message')}")
        raise TimeoutError("Execution timed out")
    finally:
        ws.close()

# ── Cloudinary Direct Upload ──────────────────────────────────
def get_and_upload_outputs(prompt_id: str):
    history = json.loads(urllib.request.urlopen(f"{COMFY_URL}/history/{prompt_id}", timeout=30).read())
    outputs = history.get(prompt_id, {}).get("outputs", {})
    video_urls = []

    for node_id, node_out in outputs.items():
        for vkey in ("videos", "gifs"):
            for vid_info in node_out.get(vkey, []):
                if vid_info.get("type") == "temp": continue
                
                fname = vid_info.get("filename", "")
                subfolder = vid_info.get("subfolder", "")
                if not fname: continue

                local_file_path = os.path.join(COMFY_DIR, "output", subfolder, fname)
                if not os.path.exists(local_file_path): continue

                log(f"Uploading to Cloudinary [Preset: n8n insta]: {fname}")
                upload_resp = cloudinary.uploader.upload(
                    local_file_path,
                    resource_type="video",
                    upload_preset="n8n insta", # 요청하신 프리셋 하드코딩
                    chunk_size=6000000
                )
                
                video_url = upload_resp.get("secure_url")
                video_urls.append({"filename": fname, "url": video_url})
                
                # 워커 디스크 정리
                try: os.remove(local_file_path)
                except Exception as e: log(f"Cleanup failed: {e}")

    return video_urls

# ── RunPod handler ────────────────────────────────────────────
def handler(event: dict) -> dict:
    try:
        job_input = event.get("input", {})
        workflow  = job_input.get("workflow")
        if not workflow: return {"error": "No workflow provided"}

        # n8n에서 넘겨준 이미지 URL 처리 및 Node 10 맵핑
        for img_entry in job_input.get("images", []):
            url = img_entry.get("image", "")
            if url:
                actual_name = upload_image_to_comfyui(img_entry.get("name", "input_image.png"), url)
                if "10" in workflow and workflow["10"].get("class_type") == "LoadImage":
                    workflow["10"]["inputs"]["image"] = actual_name

        client_id = str(uuid.uuid4())
        result = queue_prompt(workflow, client_id)
        prompt_id = result.get("prompt_id")
        
        wait_for_execution(prompt_id, client_id)
        video_results = get_and_upload_outputs(prompt_id)
        
        if not video_results: return {"error": "No videos generated"}
        return {"status": "success", "video_count": len(video_results), "videos": video_results}

    except Exception:
        return {"error": traceback.format_exc()}

if __name__ == "__main__":
    start_comfyui()
    if not wait_for_comfyui(): sys.exit(1)
    runpod.serverless.start({"handler": handler})
