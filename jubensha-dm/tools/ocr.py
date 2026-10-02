"""扫描版 PDF / 图片 → 文字。

用法：
  python -m tools.ocr 剧本/*.pdf --out work
  python -m tools.ocr DM手册.pdf --engine vision          # 用视觉大模型识别（更准，需要 config.yaml 配置）
  python -m tools.ocr 角色本.pdf --split                   # 扫描件一页是左右两页时，切成两半再识别
  python -m tools.ocr 照片文件夹/ --out work               # 也支持一个文件夹的 jpg/png

识别引擎：
  rapidocr  （默认）本地运行，免费，中文效果好。pip install rapidocr_onnxruntime
  vision    用视觉大模型逐页转写（Qwen-VL、GPT-4o、Claude 等），版面复杂时更准
  tesseract 需要自己装 tesseract 和中文语言包 chi_sim

识别过的页会跳过，中途断了重新运行会接着做。
输出：work/<文件名>.txt（整本，带 === 第N页 === 标记），work/<文件名>/p0001.txt（每页）
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

IMG_EXT = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff"}
END_PUNCT = tuple("。！？!?…」』”\"：:）)")


# ---------------- 读取页面图片 ----------------
def iter_pages(path: Path, dpi: int):
    """逐页产出 PIL 图片。"""
    from PIL import Image
    if path.is_dir():
        for f in sorted(p for p in path.iterdir() if p.suffix.lower() in IMG_EXT):
            yield Image.open(f).convert("RGB")
    elif path.suffix.lower() in IMG_EXT:
        yield Image.open(path).convert("RGB")
    elif path.suffix.lower() == ".pdf":
        import pypdfium2 as pdfium
        pdf = pdfium.PdfDocument(str(path))
        for i in range(len(pdf)):
            yield pdf[i].render(scale=dpi / 72).to_pil().convert("RGB")
    else:
        raise SystemExit(f"不支持的文件：{path}")


def count_pages(path: Path) -> int:
    if path.is_dir():
        return len([p for p in path.iterdir() if p.suffix.lower() in IMG_EXT])
    if path.suffix.lower() == ".pdf":
        import pypdfium2 as pdfium
        return len(pdfium.PdfDocument(str(path)))
    return 1


def split_halves(img):
    w, h = img.size
    return [img.crop((0, 0, w // 2, h)), img.crop((w // 2, 0, w, h))]


# ---------------- 识别引擎 ----------------
class RapidEngine:
    def __init__(self):
        try:
            from rapidocr_onnxruntime import RapidOCR
            self.new_api = False
        except ImportError:
            try:
                from rapidocr import RapidOCR
                self.new_api = True
            except ImportError:
                raise SystemExit("没装 RapidOCR：请运行  pip install rapidocr_onnxruntime")
        self.ocr = RapidOCR()

    def recognize(self, img) -> str:
        import numpy as np
        arr = np.array(img)
        if self.new_api:
            out = self.ocr(arr)
            boxes, txts = (out.boxes if out.boxes is not None else []), (out.txts or [])
            items = [(b, t) for b, t in zip(boxes, txts)]
        else:
            result, _ = self.ocr(arr)
            items = [(r[0], r[1]) for r in (result or [])]
        return layout_text(items, img.size[0])


class TesseractEngine:
    def __init__(self, lang: str):
        import shutil
        if not shutil.which("tesseract"):
            raise SystemExit("没找到 tesseract 命令。建议改用默认的 rapidocr 引擎。")
        self.lang = lang

    def recognize(self, img) -> str:
        import subprocess, tempfile
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            img.save(f.name)
            r = subprocess.run(["tesseract", f.name, "-", "-l", self.lang, "--psm", "6"],
                               capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit(f"tesseract 出错（是否装了 {self.lang} 语言包？）：{r.stderr[:200]}")
        lines = [l.replace(" ", "") if self.lang.startswith("chi") else l for l in r.stdout.splitlines()]
        return "\n".join(lines).strip()


VISION_PROMPT = ("这是一页剧本杀剧本的扫描图。请逐字转写图中所有文字，保持原有的段落和顺序，"
                 "标题单独成行，表格用 | 分隔。看不清的字用□代替。不要总结、不要解释、不要加任何额外内容，只输出转写的文字。")


class VisionEngine:
    def __init__(self, cfg: dict):
        from jubensha.llm import LLM
        vc = {**(cfg.get("llm") or {}), **{k: v for k, v in (cfg.get("vision") or {}).items() if v}}
        vc["max_tokens"] = 4000
        self.llm = LLM(vc)

    async def recognize_async(self, img) -> str:
        w, h = img.size
        if max(w, h) > 2000:   # 太大的图缩一下，省流量
            s = 2000 / max(w, h)
            img = img.resize((int(w * s), int(h * s)))
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=88)
        return (await self.llm.vision(base64.b64encode(buf.getvalue()).decode(), VISION_PROMPT, "image/jpeg")).strip()


def layout_text(items, page_width: int) -> str:
    """把一堆文字框按阅读顺序排好，再把被换行切断的句子接回段落。"""
    if not items:
        return ""
    boxes = []
    for box, text in items:
        xs = [p[0] for p in box]
        ys = [p[1] for p in box]
        boxes.append({"x0": min(xs), "x1": max(xs), "y0": min(ys), "y1": max(ys),
                      "yc": (min(ys) + max(ys)) / 2, "h": max(ys) - min(ys), "t": str(text).strip()})
    boxes.sort(key=lambda b: (b["yc"], b["x0"]))
    lines: list[list[dict]] = []
    for b in boxes:
        if lines and abs(lines[-1][-1]["yc"] - b["yc"]) < 0.5 * max(b["h"], lines[-1][-1]["h"]):
            lines[-1].append(b)
        else:
            lines.append([b])
    rows = []
    for ln in lines:
        ln.sort(key=lambda b: b["x0"])
        rows.append({"t": "".join(b["t"] for b in ln), "x0": ln[0]["x0"], "x1": ln[-1]["x1"],
                     "y0": min(b["y0"] for b in ln), "y1": max(b["y1"] for b in ln),
                     "h": sum(b["h"] for b in ln) / len(ln)})
    left = min(r["x0"] for r in rows)
    right = max(r["x1"] for r in rows)
    out, para = [], ""
    for i, r in enumerate(rows):
        prev = rows[i - 1] if i else None
        new_para = (
            not para
            or para.endswith(END_PUNCT)
            or (prev and r["y0"] - prev["y1"] > 1.0 * r["h"])             # 行距明显变大
            or r["x0"] - left > 1.5 * r["h"]                              # 首行缩进
            or (prev and prev["x1"] < right - 3 * r["h"])                 # 上一行没写满
        )
        if new_para and para:
            out.append(para)
            para = ""
        para += r["t"]
    if para:
        out.append(para)
    return "\n".join(out)


# ---------------- 主流程 ----------------
async def run(files: list[Path], out: Path, engine_name: str, dpi: int, split: bool, lang: str, cfg: dict):
    if engine_name == "vision":
        engine = VisionEngine(cfg)
    elif engine_name == "tesseract":
        engine = TesseractEngine(lang)
    else:
        engine = RapidEngine()

    for f in files:
        stem = f.stem if not f.is_dir() else f.name
        page_dir = out / stem
        page_dir.mkdir(parents=True, exist_ok=True)
        total = count_pages(f)
        print(f"\n《{stem}》共 {total} 页 → {page_dir}")
        texts = []
        for i, img in enumerate(iter_pages(f, dpi), 1):
            parts = split_halves(img) if split else [img]
            page_texts = []
            for j, part in enumerate(parts):
                name = f"p{i:04d}" + (f"{'ab'[j]}" if split else "")
                tf = page_dir / f"{name}.txt"
                if tf.exists():
                    page_texts.append(tf.read_text(encoding="utf-8"))
                    continue
                try:
                    if engine_name == "vision":
                        t = await engine.recognize_async(part)
                    else:
                        t = await asyncio.to_thread(engine.recognize, part)
                except Exception as e:  # noqa: BLE001
                    print(f"  第{i}页识别失败：{e}（重新运行会重试这一页）")
                    continue
                tf.write_text(t, encoding="utf-8")
                page_texts.append(t)
            texts.append((i, "\n".join(page_texts)))
            n_chars = sum(len(t) for t in page_texts)
            print(f"  第{i}/{total}页  {n_chars}字" + ("  ⚠ 几乎没识别出字，检查一下这页" if n_chars < 20 else ""))
        full = out / f"{stem}.txt"
        full.write_text("\n\n".join(f"=== 第{i}页 ===\n{t}" for i, t in texts), encoding="utf-8")
        print(f"  完成 → {full}")
    print("\n下一步：python -m tools.draft " + " ".join(str(out / ((f.stem if not f.is_dir() else f.name) + '.txt')) for f in files)
          + " --out scripts/我的剧本")


def main():
    ap = argparse.ArgumentParser(description="扫描版剧本 → 文字")
    ap.add_argument("files", nargs="+", help="PDF、图片或图片文件夹")
    ap.add_argument("--out", default="work")
    ap.add_argument("--engine", choices=["rapidocr", "vision", "tesseract"], default="rapidocr")
    ap.add_argument("--dpi", type=int, default=220, help="渲染清晰度，字小就调高（300）")
    ap.add_argument("--split", action="store_true", help="每页切成左右两半（扫描的是摊开的两页时用）")
    ap.add_argument("--lang", default="chi_sim", help="tesseract 语言")
    ap.add_argument("--config", default=str(ROOT / "config.yaml"))
    a = ap.parse_args()
    cfg = {}
    if a.engine == "vision":
        import yaml
        p = Path(a.config)
        if not p.exists():
            raise SystemExit("用 vision 引擎需要先配置 config.yaml（llm 或 vision 部分）")
        cfg = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    files = [Path(x) for x in a.files]
    for f in files:
        if not f.exists():
            raise SystemExit(f"找不到：{f}")
    asyncio.run(run(files, Path(a.out), a.engine, a.dpi, a.split, a.lang, cfg))


if __name__ == "__main__":
    main()
