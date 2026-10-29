#!/usr/bin/env bash
# コンテナ内で実行される: Xvfb + Mesa llvmpipe 上で TwinPose を起動し、
# ログとスクリーンショットを /work/docker/out に保存する。ホストの X11 には一切触れない。
set -uo pipefail

OUT=/work/docker/out
BIN=/work/binaries/TwinPose
SECS="${SMOKE_SECONDS:-15}"
LOAD="${SMOKE_LOAD:-0}"
DISP=:99

mkdir -p "$OUT"
rm -f "$OUT"/*.png "$OUT"/*.log
[ -x "$BIN" ] || { echo "NG: $BIN がありません。先に docker/twinpose.sh build を実行してください" >&2; exit 2; }

export DISPLAY="$DISP" LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
# ウィンドウマネージャなしで 1280x720 のアプリウィンドウが (0,0) に来るよう画面サイズを合わせる
Xvfb "$DISP" -screen 0 1280x720x24 -nolisten tcp >"$OUT/xvfb.log" 2>&1 &
XVFB=$!
APP=
cleanup() {
  if [ -n "$APP" ]; then kill "$APP" 2>/dev/null; wait "$APP" 2>/dev/null; fi
  kill "$XVFB" 2>/dev/null; wait "$XVFB" 2>/dev/null
}
trap cleanup EXIT

for _ in $(seq 1 100); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done
xdpyinfo >/dev/null 2>&1 || { echo "NG: Xvfb が起動しません"; cat "$OUT/xvfb.log"; exit 1; }
glxinfo -B >"$OUT/glxinfo.log" 2>&1 || true

# リポジトリ直下の imgui.ini (ユーザーのウィンドウ配置) に左右されないよう、
# assets/ と dataset/ だけを参照する一時ディレクトリから既定サイズで起動する
RUN_DIR=/tmp/twinpose-run
mkdir -p "$RUN_DIR" && ln -sfn /work/assets "$RUN_DIR/assets" && ln -sfn /work/dataset "$RUN_DIR/dataset"
cd "$RUN_DIR" || exit 1
TWINPOSE_WINDOW_SIZE=1280x720 "$BIN" >"$OUT/twinpose.log" 2>&1 &
APP=$!
sleep 5
if ! kill -0 "$APP" 2>/dev/null; then
  wait "$APP"; rc=$?
  echo "NG: 起動後 5 秒以内に終了しました (exit=$rc)"; cat "$OUT/twinpose.log"; exit 1
fi
import -window root "$OUT/01_startup.png"
echo "OK: 起動を確認 -> docker/out/01_startup.png"

if [ "$LOAD" = 1 ]; then
  # "Load Dataset" ウィンドウ (位置 40,40 / 640x640、初期レイアウト前提) を README の手順どおり操作する:
  #   1. "Import Dataset JSON" と "Import Algorithm JSON" ボタン (既定値 dataset/shelf/*.json) をクリック
  #   2. 最下部までスクロールし、左下に現れる "Load Dataset" ボタンをクリック
  xdotool mousemove 552 107 sleep 0.3 click 1 sleep 0.5
  xdotool mousemove 552 133 sleep 0.3 click 1 sleep 0.5
  import -window root "$OUT/02_imported.png"
  xdotool mousemove 360 400 click --repeat 60 --delay 20 5
  sleep 0.5
  xdotool mousemove 128 661 sleep 0.3 click 1
  sleep "$SECS"
  import -window root "$OUT/03_loaded.png"
  echo "OK: Load Dataset 後 -> docker/out/03_loaded.png"
else
  sleep "$SECS"
  import -window root "$OUT/02_running.png"
  echo "OK: ${SECS}秒後 -> docker/out/02_running.png"
fi

if ! kill -0 "$APP" 2>/dev/null; then
  wait "$APP"; rc=$?
  echo "NG: 実行中に終了しました (exit=$rc)"; cat "$OUT/twinpose.log"; exit 1
fi

echo "---- twinpose.log ----"; cat "$OUT/twinpose.log"
echo "---- OpenGL ----"; grep -E 'OpenGL (vendor|renderer|core profile version)' "$OUT/glxinfo.log" || true
echo "SMOKE_OK"
