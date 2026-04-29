import json
import os
import subprocess
import sys
import time
import traceback
import urllib.request
import uuid
import base64

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

# ── Cloudinary credentials ────────────────────────────────────
# Cloudinary credentials are read from env vars set on the RunPod
# endpoint config; never hardcoded for public docker push.
# Required env vars (configure in RunPod web UI → endpoint → Environment Variables):
#   RUNPOD_CLOUDINARY_CLOUD_NAME
#   RUNPOD_CLOUDINARY_API_KEY
#   RUNPOD_CLOUDINARY_API_SECRET
#   RUNPOD_CLOUDINARY_UPLOAD_PRESET   (e.g. "n8n insta")
# If any of the four are missing, video-upload paths will hard-fail
# with a clear message (image-only workflows still work).
_CLD_CLOUD       = os.environ.get("RUNPOD_CLOUDINARY_CLOUD_NAME", "")
_CLD_KEY         = os.environ.get("RUNPOD_CLOUDINARY_API_KEY", "")
_CLD_SECRET      = os.environ.get("RUNPOD_CLOUDINARY_API_SECRET", "")
CLOUDINARY_UPLOAD_PRESET = os.environ.get("RUNPOD_CLOUDINARY_UPLOAD_PRESET", "n8n insta")

CLOUDINARY_ENABLED = bool(_CLD_CLOUD and _CLD_KEY and _CLD_SECRET)

if CLOUDINARY_ENABLED:
    cloudinary.config(
        cloud_name=_CLD_CLOUD,
        api_key=_CLD_KEY,
        api_secret=_CLD_SECRET,
        secure=True,
    )
else:
    # Image-only workflows do not need Cloudinary; only warn.
    print("[handler] WARN: Cloudinary env vars missing — video upload disabled.", flush=True)

comfy_process = None

def log(msg: str):
    print(f"[handler] {msg}", flush=True)

# ── ComfyUI lifecycle ───────────────────────────
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
    # H200 최적화: --highvram 추가, --bf16-unet 추가
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

# ── Output Processing (Video → Cloudinary, Image → Base64) ────
def get_and_upload_outputs(prompt_id: str):
    history = json.loads(urllib.request.urlopen(f"{COMFY_URL}/history/{prompt_id}", timeout=30).read())
    outputs = history.get(prompt_id, {}).get("outputs", {})

    video_urls = []
    image_results = []

    for node_id, node_out in outputs.items():
        # 1. Video / GIF processing (Cloudinary upload).
        for vkey in ("videos", "gifs"):
            for vid_info in node_out.get(vkey, []):
                if vid_info.get("type") == "temp": continue

                fname = vid_info.get("filename", "")
                subfolder = vid_info.get("subfolder", "")
                if not fname: continue

                local_file_path = os.path.join(COMFY_DIR, "output", subfolder, fname)
                if not os.path.exists(local_file_path): continue

                if not CLOUDINARY_ENABLED:
                    log(f"⚠ Skipping video upload (Cloudinary disabled): {fname}")
                    continue

                log(f"Uploading Video to Cloudinary [Preset: {CLOUDINARY_UPLOAD_PRESET}]: {fname}")
                upload_resp = cloudinary.uploader.upload(
                    local_file_path,
                    resource_type="video",
                    upload_preset=CLOUDINARY_UPLOAD_PRESET,
                    chunk_size=6000000
                )

                video_urls.append({"filename": fname, "url": upload_resp.get("secure_url")})

                try: os.remove(local_file_path)
                except Exception as e: log(f"Cleanup failed: {e}")

        # 2. Image processing (base64 for n8n / direct return).
        for img_info in node_out.get("images", []):
            if img_info.get("type") == "temp": continue

            fname = img_info.get("filename", "")
            subfolder = img_info.get("subfolder", "")
            if not fname: continue

            local_file_path = os.path.join(COMFY_DIR, "output", subfolder, fname)
            if not os.path.exists(local_file_path): continue

            log(f"Encoding Image to Base64: {fname}")
            with open(local_file_path, "rb") as f:
                img_bytes = f.read()
                b64_data = base64.b64encode(img_bytes).decode('utf-8')

            image_results.append({
                "filename": fname,
                "data": b64_data
            })

            try: os.remove(local_file_path)
            except Exception as e: log(f"Cleanup failed: {e}")

    return video_urls, image_results

# ── RunPod handler ────────────────────────────────────────────
def handler(event: dict) -> dict:
    try:
        job_input = event.get("input", {})
        workflow  = job_input.get("workflow")
        if not workflow: return {"error": "No workflow provided"}

        # Image URL staging — explicit node_id wins, else first LoadImage.
        for img_entry in job_input.get("images", []):
            url = img_entry.get("image", "")
            if not url:
                continue

            actual_name = upload_image_to_comfyui(img_entry.get("name", "input_image.png"), url)

            target_node_id = str(img_entry.get("node_id", ""))
            if target_node_id and target_node_id in workflow:
                workflow[target_node_id]["inputs"]["image"] = actual_name
                log(f"Image mapped to explicit node_id={target_node_id}")
                continue

            matched = False
            for node_id, node_data in workflow.items():
                if node_data.get("class_type") == "LoadImage":
                    workflow[node_id]["inputs"]["image"] = actual_name
                    log(f"Image mapped to LoadImage node (auto-detected node_id={node_id})")
                    matched = True
                    break

            if not matched:
                log(f"WARNING: No LoadImage node found for image '{img_entry.get('name')}' — skipping.")

        client_id = str(uuid.uuid4())
        result = queue_prompt(workflow, client_id)
        prompt_id = result.get("prompt_id")

        wait_for_execution(prompt_id, client_id)

        video_results, image_results = get_and_upload_outputs(prompt_id)

        if not video_results and not image_results:
            return {"error": "No videos or images generated"}

        response = {"status": "success"}
        if video_results:
            response["video_count"] = len(video_results)
            response["videos"] = video_results

        if image_results:
            response["image_count"] = len(image_results)
            response["images"] = image_results

        return response

    except Exception:
        return {"error": traceback.format_exc()}

if __name__ == "__main__":
    start_comfyui()
    if not wait_for_comfyui(): sys.exit(1)
    runpod.serverless.start({"handler": handler})
