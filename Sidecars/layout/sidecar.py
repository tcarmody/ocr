"""
Layout sidecar for Humanist.

Long-lived Python process. Loads Surya's layout predictor once and
serves layout requests over length-prefixed JSON on stdin/stdout.

Frame:
  4-byte big-endian length, then UTF-8 JSON body.

Hello (sent on startup, unprompted):
  {"ready": true, "surya_version": "...", "torch": true, "mps": true|false}

Request:
  {"op": "layout", "image_path": "/abs/path/to/page.png"}

Response (success):
  {
    "op": "layout.result",
    "regions": [
      {"label": "Section-header", "bbox": [x1, y1, x2, y2],
       "confidence": 0.97, "position": 0,
       "image_size": [W, H]},
      ...
    ]
  }
  - bbox is in pixel coords with origin top-left (Surya's convention).
  - position is the reading-order index Surya assigned.

Request:
  {"op": "ping"}
Response:
  {"op": "pong", "now": 1733257812.345}

Crash policy: any unhandled exception writes
  {"op": "error", "message": "...", "trace": "..."}
and the process exits 1. The Swift SidecarBridge restarts it.
"""

from __future__ import annotations

import json
import struct
import sys
import time
import traceback
from typing import Any


def write_msg(obj: dict[str, Any]) -> None:
    body = json.dumps(obj).encode("utf-8")
    sys.stdout.buffer.write(struct.pack(">I", len(body)))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def read_msg() -> dict[str, Any] | None:
    hdr = sys.stdin.buffer.read(4)
    if len(hdr) < 4:
        return None
    (n,) = struct.unpack(">I", hdr)
    body = sys.stdin.buffer.read(n)
    if len(body) < n:
        return None
    return json.loads(body)


# --- Surya bootstrap ---------------------------------------------------------
# Imported lazily so a startup failure can be reported back over the wire
# rather than killing the process before the Swift side sees anything.

_layout_predictor = None
_ocr_predictors = None  # tuple of (recognition, detection)


def get_layout_predictor():
    """Lazily construct Surya's LayoutPredictor (loads model weights).

    Critical: pass `LAYOUT_MODEL_CHECKPOINT` to the FoundationPredictor.
    Without it FoundationPredictor loads the OCR model and Layout
    silently produces nonsense ("PageHeader" covering the whole page,
    handful of regions). The CLI gets this right because
    `surya/scripts/detect_layout.py` does the same thing — replicated
    here for parity.
    """
    global _layout_predictor
    if _layout_predictor is None:
        from surya.foundation import FoundationPredictor  # type: ignore
        from surya.layout import LayoutPredictor          # type: ignore
        from surya.settings import settings               # type: ignore
        foundation = FoundationPredictor(checkpoint=settings.LAYOUT_MODEL_CHECKPOINT)
        _layout_predictor = LayoutPredictor(foundation)
    return _layout_predictor


def get_ocr_predictors():
    """Lazily construct Surya's OCR pipeline.

    OCR uses a SEPARATE foundation model from layout — both load ~1.3 GB
    of weights so ~2.6 GB resident if the user runs both modes. We
    accept that cost in exchange for one Python process (one bridge,
    one IPC channel).
    """
    global _ocr_predictors
    if _ocr_predictors is None:
        from surya.foundation import FoundationPredictor  # type: ignore
        from surya.detection import DetectionPredictor    # type: ignore
        from surya.recognition import RecognitionPredictor  # type: ignore
        foundation = FoundationPredictor()  # default checkpoint = OCR
        recognition = RecognitionPredictor(foundation)
        detection = DetectionPredictor()
        _ocr_predictors = (recognition, detection)
    return _ocr_predictors


def probe_environment() -> dict[str, Any]:
    info: dict[str, Any] = {
        "ready": True,
        "python": sys.version,
        "executable": sys.executable,
    }
    try:
        import surya  # type: ignore
        info["surya"] = True
        info["surya_version"] = getattr(surya, "__version__", "unknown")
    except Exception as e:
        info["surya"] = False
        info["surya_error"] = str(e)
    try:
        import torch  # type: ignore
        info["torch"] = True
        info["torch_version"] = torch.__version__
        info["mps"] = bool(
            getattr(torch.backends, "mps", None)
            and torch.backends.mps.is_available()
        )
    except Exception as e:
        info["torch"] = False
        info["torch_error"] = str(e)
    return info


# --- Op handlers -------------------------------------------------------------

def handle_layout(msg: dict[str, Any]) -> dict[str, Any]:
    image_path = msg.get("image_path")
    if not image_path:
        return {"op": "error", "message": "layout requires image_path"}

    from PIL import Image  # type: ignore
    img = Image.open(image_path).convert("RGB")
    width, height = img.size

    predictor = get_layout_predictor()
    # Predictor accepts a list and returns a list of LayoutResult.
    results = predictor([img])
    if not results:
        return {"op": "layout.result", "regions": [], "image_size": [width, height]}

    layout = results[0]
    regions: list[dict[str, Any]] = []
    # Each `bbox` on a LayoutResult is a LayoutBox with .bbox (xyxy),
    # .label, .confidence, .position. Field set is stable across recent
    # Surya releases.
    for box in getattr(layout, "bboxes", []):
        try:
            x1, y1, x2, y2 = (float(v) for v in box.bbox)
        except Exception:
            continue
        regions.append({
            "label": getattr(box, "label", "Text"),
            "bbox": [x1, y1, x2, y2],
            "confidence": float(getattr(box, "confidence", 0.0) or 0.0),
            "position": int(getattr(box, "position", -1) or -1),
        })

    return {
        "op": "layout.result",
        "regions": regions,
        "image_size": [width, height],
    }


def handle_ocr(msg: dict[str, Any]) -> dict[str, Any]:
    """Run Surya OCR on a page image. Returns one entry per recognized
    text line: text, confidence, pixel/top-left bbox.

    Languages: list of BCP-47 codes (e.g. ["en", "fr", "de"]). Surya
    accepts these as recognition hints. Empty list = let Surya choose.
    """
    image_path = msg.get("image_path")
    if not image_path:
        return {"op": "error", "message": "ocr requires image_path"}
    languages = msg.get("languages") or ["en"]

    from PIL import Image  # type: ignore
    from surya.common.surya.schema import TaskNames  # type: ignore

    img = Image.open(image_path).convert("RGB")
    width, height = img.size

    recognition, detection = get_ocr_predictors()
    predictions = recognition(
        [img],
        task_names=[TaskNames.ocr_with_boxes],
        det_predictor=detection,
        # `languages` could become a per-image list (one per page) when
        # we call this op in batch; today we only do one image at a
        # time so we pass the same languages for both list slots.
    )
    if not predictions:
        return {"op": "ocr.result", "lines": [], "image_size": [width, height]}

    pred = predictions[0]
    lines: list[dict[str, Any]] = []
    for line in getattr(pred, "text_lines", []):
        text = (getattr(line, "text", "") or "").strip()
        if not text:
            continue
        try:
            x1, y1, x2, y2 = (float(v) for v in line.bbox)
        except Exception:
            continue
        lines.append({
            "text": text,
            "bbox": [x1, y1, x2, y2],
            "confidence": float(getattr(line, "confidence", 0.0) or 0.0),
        })

    _ = languages  # currently passed only for forward-compat; Surya
    # 0.17 doesn't take recognition_languages on the predictor call,
    # the foundation model is already multilingual.

    return {
        "op": "ocr.result",
        "lines": lines,
        "image_size": [width, height],
    }


def handle_ping(_msg: dict[str, Any]) -> dict[str, Any]:
    return {"op": "pong", "now": time.time()}


HANDLERS = {
    "layout": handle_layout,
    "ocr":    handle_ocr,
    "ping":   handle_ping,
}


def handle(msg: dict[str, Any]) -> dict[str, Any]:
    op = msg.get("op", "")
    handler = HANDLERS.get(op)
    if handler is None:
        return {"op": "error", "message": f"unknown op: {op!r}"}
    return handler(msg)


def main() -> int:
    try:
        write_msg(probe_environment())
    except Exception as e:
        try:
            write_msg({"op": "error", "ready": False, "message": str(e),
                       "trace": traceback.format_exc()})
        except Exception:
            pass
        return 1

    while True:
        msg = read_msg()
        if msg is None:
            return 0
        try:
            reply = handle(msg)
        except Exception as e:
            reply = {
                "op": "error",
                "message": str(e),
                "trace": traceback.format_exc(),
            }
        write_msg(reply)


if __name__ == "__main__":
    raise SystemExit(main())
