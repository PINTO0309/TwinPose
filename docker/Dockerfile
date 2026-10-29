# TwinPose Linux ビルド/テスト用コンテナ
# - std::format を使うため GCC 13 以上 (Ubuntu 24.04 の既定) が必要
# - ネットワークはこのイメージのビルド時 (apt) にのみ使用する。実行時は --network none で動かす
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        # ビルドツール
        build-essential cmake ninja-build pkg-config \
        # SDL2 (X11 バックエンド) のビルドに必要な開発ヘッダ
        libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev \
        libxinerama-dev libxss-dev libxfixes-dev libxkbcommon-dev \
        # OpenGL (glvnd) 開発ヘッダ
        libgl-dev libegl-dev libglvnd-dev \
        # 実行時: Mesa (llvmpipe によるソフトウェア GL) と glvnd
        libgl1 libglx-mesa0 libgl1-mesa-dri libegl1 libegl-mesa0 \
        # ヘッドレス実行・スクリーンショット・自動操作
        xvfb x11-utils x11-apps mesa-utils xdotool imagemagick \
    && rm -rf /var/lib/apt/lists/*

# 成果物ディレクトリ (実行時に名前付きボリュームをここへマウントする)
RUN mkdir -p /work/build /work/binaries /work/intermediate \
    && chown -R 1000:1000 /work

WORKDIR /work
USER 1000:1000
