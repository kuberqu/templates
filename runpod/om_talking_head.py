#!/usr/bin/env python3
"""TalkingHead-Render mit Word-Captions über das OpenMontage-Tool.

Rendert einen Clip mit der Remotion-Composition `TalkingHead` und wortweisen
Untertiteln (Highlight pro Wort) — der technische Kern der OM-Pipeline
`talking-head.yaml`, ohne den agentischen Stage-Gate-Lauf.

Aufruf (OM-venv):
  /workspace/OpenMontage/.venv/bin/python /workspace/om_talking_head.py \
      <input.mp4> <captions.srt> <output.mp4> [words_per_page] [font_size]
"""
import json
import sys
import time

sys.path.insert(0, "/workspace/OpenMontage")

from tools.tool_registry import registry  # noqa: E402


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: om_talking_head.py <input.mp4> <captions.srt> <output.mp4> "
              "[words_per_page] [font_size]")
        return 2
    inp, srt, out = sys.argv[1:4]
    wpp = int(sys.argv[4]) if len(sys.argv) > 4 else 4
    fsize = int(sys.argv[5]) if len(sys.argv) > 5 else 52

    registry.discover()
    tool = registry.get("remotion_caption_burn")
    print(f"Tool: {type(tool).__name__} | remotion_available="
          f"{getattr(tool, '_remotion_available', lambda: '?')()}", flush=True)

    t0 = time.time()
    res = tool.execute({
        "input_path": inp,
        "output_path": out,
        "srt_path": srt,
        "words_per_page": wpp,
        "font_size": fsize,
        "highlight_color": "#22D3EE",
    })
    print(f"success={getattr(res, 'success', None)} "
          f"duration={getattr(res, 'duration_seconds', time.time()-t0):.1f}s")
    for attr in ("output_path", "error", "message", "metadata", "artifacts"):
        v = getattr(res, attr, None)
        if v not in (None, "", [], {}):
            print(f"  {attr}: {json.dumps(v, default=str)[:400]}")
    return 0 if getattr(res, "success", False) else 1


if __name__ == "__main__":
    sys.exit(main())
