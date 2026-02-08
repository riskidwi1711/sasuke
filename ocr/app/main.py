import io
import os
from typing import Optional

from fastapi import FastAPI, File, UploadFile, Query
from fastapi.responses import JSONResponse
from PIL import Image
import pytesseract
import requests

app = FastAPI(title="OCR Service", version="1.0.0")

IPFS_API_URL = os.getenv("IPFS_API_URL")
DEFAULT_LANG = "eng"


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/ocr")
async def ocr(
    file: UploadFile = File(...),
    lang: str = Query(DEFAULT_LANG, description="Tesseract language code, e.g., eng, ind"),
    store: bool = Query(False, description="Store OCR result to IPFS if configured"),
):
    # Read uploaded content into PIL Image
    content = await file.read()
    try:
        image = Image.open(io.BytesIO(content))
        # Convert to a mode Tesseract can handle well
        if image.mode not in ("L", "RGB"):
            image = image.convert("RGB")
    except Exception as e:
        return JSONResponse(status_code=400, content={"error": f"Invalid image: {e}"})

    try:
        text = pytesseract.image_to_string(image, lang=lang or DEFAULT_LANG)
    except pytesseract.pytesseract.TesseractNotFoundError:
        return JSONResponse(status_code=500, content={"error": "Tesseract not found in container"})
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": f"OCR failed: {e}"})

    result = {"text": text, "lang": lang or DEFAULT_LANG}

    if store and IPFS_API_URL:
        try:
            # Prepare a text file content for IPFS add
            files = {"file": (f"{file.filename or 'ocr'}.txt", text.encode("utf-8"))}
            resp = requests.post(f"{IPFS_API_URL}/api/v0/add", files=files, timeout=60)
            resp.raise_for_status()
            data = resp.json() if resp.headers.get("content-type", "").startswith("application/json") else None
            if not data:
                # Fallback when IPFS returns non-JSON (some versions)
                # Expect lines like: {"Name":"..","Hash":"..","Size":".."}
                try:
                    data = resp.json()
                except Exception:
                    data = None
            if data and isinstance(data, dict) and data.get("Hash"):
                result["ipfsHash"] = data["Hash"]
                result["ipfsGateway"] = f"http://localhost:8080/ipfs/{data['Hash']}"
            else:
                # Try to parse text format
                try:
                    import json
                    data = json.loads(resp.text)
                    if data.get("Hash"):
                        result["ipfsHash"] = data["Hash"]
                        result["ipfsGateway"] = f"http://localhost:8080/ipfs/{data['Hash']}"
                except Exception:
                    pass
        except Exception as e:
            result["ipfsError"] = str(e)

    return result

