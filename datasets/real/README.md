# Real-world OMR evaluation set

- `images/real-NNN.(jpg|png)`: 50 collected 弹唱六线谱 pages (sources and notes in `index.json`, `tools/omr-real/sources.md`).
- `gt/real-NNN.agr.json` + `.meta.json`: hand-transcribed, independently verified ground truth for 18 pages (AGR v2). See `gt/VERIFICATION.md`.
- Grayscale `.pgm` files used by the Linux OMR harness are not committed; regenerate with `tools/omr-real/convert.py`.
- Dev split: 000 001 002 013 014 015 019 022 025. Held-out test: 028 031 035 038 040 042 043 045 049.
