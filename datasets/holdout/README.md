# Held-out OMR acceptance set

- `images/hold-NNN.(png|jpg)`: 26 弹唱 / 指弹 tab pages collected from 7 sites, none from a song in `datasets/real` (sources in `sources.md`, per-page features in `features.md`, `index.json`).
- `gt/hold-NNN.agr.json` + `.meta.json`: ground truth for 8 pages (001 009 010 011 014 017 020 024), transcribed by one agent and re-read measure by measure by another (`gt/verify/`). Conventions: `tools/omr-real/GT_SPEC.md`; jianpu X rhythm marks are stored as degree-0 notes.
- Acceptance only: never tune the engine on these pages. Grayscale `.pgm` files are regenerated with `tools/ocr/convert.py`.
