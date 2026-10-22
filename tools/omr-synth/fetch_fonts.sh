#!/bin/sh
# Download the open-licensed fonts listed in fonts.txt into ./fonts (run from tools/omr-synth).
set -e
mkdir -p fonts
[ -s fonts/NotoSansSC.ttf ] || curl -fsSL -o fonts/NotoSansSC.ttf "https://github.com/google/fonts/raw/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf"
[ -s fonts/NotoSerifSC.ttf ] || curl -fsSL -o fonts/NotoSerifSC.ttf "https://github.com/google/fonts/raw/main/ofl/notoserifsc/NotoSerifSC%5Bwght%5D.ttf"
[ -s fonts/LXGWWenKai-Regular.ttf ] || curl -fsSL -o fonts/LXGWWenKai-Regular.ttf "https://github.com/lxgw/LxgwWenKai/releases/download/v1.330/LXGWWenKai-Regular.ttf"
[ -s fonts/ZCOOLXiaoWei-Regular.ttf ] || curl -fsSL -o fonts/ZCOOLXiaoWei-Regular.ttf "https://github.com/google/fonts/raw/main/ofl/zcoolxiaowei/ZCOOLXiaoWei-Regular.ttf"
[ -s fonts/DejaVuSans.ttf ] || curl -fsSL -o fonts/DejaVuSans.ttf "https://github.com/dejavu-fonts/dejavu-fonts/raw/version_2_37/ttf/DejaVuSans.ttf"
[ -s fonts/DejaVuSans-Bold.ttf ] || curl -fsSL -o fonts/DejaVuSans-Bold.ttf "https://github.com/dejavu-fonts/dejavu-fonts/raw/version_2_37/ttf/DejaVuSans-Bold.ttf"
[ -s fonts/Arimo.ttf ] || curl -fsSL -o fonts/Arimo.ttf "https://github.com/google/fonts/raw/main/ofl/arimo/Arimo%5Bwght%5D.ttf"
[ -s fonts/Roboto.ttf ] || curl -fsSL -o fonts/Roboto.ttf "https://github.com/google/fonts/raw/main/ofl/roboto/Roboto%5Bwdth%2Cwght%5D.ttf"
[ -s fonts/Tinos-Regular.ttf ] || curl -fsSL -o fonts/Tinos-Regular.ttf "https://github.com/google/fonts/raw/main/ofl/tinos/Tinos-Regular.ttf"
[ -s fonts/NotoSans.ttf ] || curl -fsSL -o fonts/NotoSans.ttf "https://github.com/google/fonts/raw/main/ofl/notosans/NotoSans%5Bwdth%2Cwght%5D.ttf"
[ -s fonts/NotoSansMono.ttf ] || curl -fsSL -o fonts/NotoSansMono.ttf "https://github.com/google/fonts/raw/main/ofl/notosansmono/NotoSansMono%5Bwdth%2Cwght%5D.ttf"
