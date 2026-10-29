#!/usr/bin/env bash
# TwinPose を Docker コンテナ内でビルド・実行するための補助スクリプト。
# ホスト側に残るものは Docker イメージと名前付きボリューム (ビルド成果物) だけ。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${TWINPOSE_IMAGE:-twinpose-dev:ubuntu24.04}"
VOL="${TWINPOSE_VOLUME_PREFIX:-twinpose}"
JOBS="${JOBS:-$(nproc)}"

usage() {
  cat <<USAGE
使い方: docker/twinpose.sh <コマンド> [オプション]

  image            テスト用イメージをビルドする (ネットワークを使う唯一の操作)
  configure        CMake 構成 (Ninja / Release)
  build            ビルド (未構成なら configure も行う)
  smoke [--load]   Xvfb 上でヘッドレス起動し、docker/out/ にログとスクリーンショットを保存
                   --load で "Load Dataset" を自動クリックし Shelf データセットを読み込む
  check            docker run を使わず BuildKit だけでビルド + ヘッドレス起動テストを行い、
                   結果を docker/out/buildcheck/ に取り出す (docker run が使えない環境向け)
  run [--gpu]      ホストの X11 にウィンドウを出して対話実行 (既定は Mesa ソフトウェア GL)
                   --gpu で NVIDIA GPU を CDI 経由で渡す
                   ウィンドウは既定で最大化。TWINPOSE_WINDOW_SIZE=1920x1080 のように指定も可能
  shell            コンテナ内で bash を開く (デバッグ用)
  status           イメージとボリュームの状態を表示
  clean            ビルド成果物のボリュームを削除 (確認あり)

環境変数: TWINPOSE_IMAGE, TWINPOSE_VOLUME_PREFIX, JOBS, SMOKE_SECONDS, TWINPOSE_WINDOW_SIZE
USAGE
}

die() { echo "エラー: $*" >&2; exit 1; }

# すべてのコンテナ起動に共通する最小権限設定
#   - ホストと同じ UID/GID で実行、root 権限なし、capability 全削除、権限昇格禁止
#   - ルート FS は読み取り専用、書き込み先は /tmp (tmpfs) とボリュームのみ
#   - ネットワークなし
#   - リポジトリを /work に bind mount し、build/binaries/intermediate は名前付きボリュームで上書き
#     (exFAT 上ではシンボリックリンクが作れず共有ライブラリのビルドが失敗するため)
base_opts() {
  mkdir -p "$ROOT/build" "$ROOT/binaries" "$ROOT/intermediate" "$ROOT/docker/out"
  BASE=(
    --rm --init
    --user "$(id -u):$(id -g)"
    --cap-drop ALL
    --security-opt no-new-privileges
    --read-only
    --tmpfs "/tmp:rw,noexec,nosuid,nodev,size=2g"
    --pids-limit 4096
    --network none
    -e HOME=/tmp/home
    -e TERM="${TERM:-xterm}"
    -v "$ROOT:/work"
    -v "${VOL}-build:/work/build"
    -v "${VOL}-binaries:/work/binaries"
    -v "${VOL}-intermediate:/work/intermediate"
    -w /work
  )
}

# 引数のコマンドをコンテナ内で実行する。EXTRA 配列に追加オプションを入れておく。
run_in_container() {
  base_opts
  docker run "${BASE[@]}" "${EXTRA[@]}" "$IMAGE" \
    bash -c 'mkdir -p "$HOME" && exec "$@"' -- "$@"
}

cmd_image() {
  docker build --pull -t "$IMAGE" -f "$ROOT/docker/Dockerfile" "$ROOT/docker"
}

cmd_configure() {
  EXTRA=()
  run_in_container cmake -S /work -B /work/build -G Ninja -DCMAKE_BUILD_TYPE=Release
}

cmd_build() {
  EXTRA=()
  run_in_container bash -c \
    '[ -f /work/build/build.ninja ] || cmake -S /work -B /work/build -G Ninja -DCMAKE_BUILD_TYPE=Release
     exec cmake --build /work/build -j'"$JOBS"
}

cmd_check() {
  # BuildKit のサンドボックス内 (ネットワークなし、ホストのマウントなし) で実行される。
  # ビルド成果物は BuildKit のキャッシュマウントに残り、ホストにはスクリーンショットとログだけが書き出される。
  docker build --progress=plain -f "$ROOT/docker/Dockerfile.buildcheck" \
    --output "type=local,dest=$ROOT/docker/out/buildcheck" "$ROOT"
  echo "結果: $ROOT/docker/out/buildcheck (smoke_rc.txt が 0 なら成功)"
}

cmd_smoke() {
  local load=0
  [ "${1:-}" = "--load" ] && load=1
  EXTRA=( -e "SMOKE_LOAD=$load" -e "SMOKE_SECONDS=${SMOKE_SECONDS:-15}" )
  run_in_container bash /work/docker/smoke_test.sh
}

# ホストの X11 を共有する。共有するのは「使用中のディスプレイのソケット 1 本」と
# 「Xauthority (読み取り専用)」だけ。xhost + のような全開放はしない。
x11_opts() {
  [ -n "${DISPLAY:-}" ] || die "DISPLAY が未設定です (X11 セッションから実行してください)"
  local n="${DISPLAY#:}"; n="${n%%.*}"
  local sock="/tmp/.X11-unix/X$n"
  [ -S "$sock" ] || die "X ソケットが見つかりません: $sock"
  EXTRA+=( -e "DISPLAY=:$n" -v "$sock:$sock" --hostname "$(hostname)" )
  if [ -n "${XAUTHORITY:-}" ] && [ -r "$XAUTHORITY" ]; then
    EXTRA+=( -v "$XAUTHORITY:/tmp/.Xauthority:ro" -e XAUTHORITY=/tmp/.Xauthority )
  elif [ -r "$HOME/.Xauthority" ]; then
    EXTRA+=( -v "$HOME/.Xauthority:/tmp/.Xauthority:ro" -e XAUTHORITY=/tmp/.Xauthority )
  else
    echo "警告: Xauthority が見つかりません。X 接続に失敗する場合は xhost +SI:localuser:$(id -un) を検討してください" >&2
  fi
}

cmd_run() {
  EXTRA=( -e "TWINPOSE_WINDOW_SIZE=${TWINPOSE_WINDOW_SIZE:-max}" )
  x11_opts
  if [ "${1:-}" = "--gpu" ]; then
    EXTRA+=( --device nvidia.com/gpu=all )
  else
    EXTRA+=( -e LIBGL_ALWAYS_SOFTWARE=1 )
  fi
  run_in_container /work/binaries/TwinPose
}

cmd_shell() {
  EXTRA=( -it )
  run_in_container bash
}

cmd_status() {
  echo "== イメージ =="; docker images "$IMAGE" --format '{{.Repository}}:{{.Tag}}  {{.Size}}  {{.CreatedSince}}'
  echo "== ボリューム =="; docker volume ls --format '{{.Name}}' | grep -E "^${VOL}-" || echo "(なし)"
}

cmd_clean() {
  local vols
  vols=$(docker volume ls --format '{{.Name}}' | grep -E "^${VOL}-(build|binaries|intermediate)$" || true)
  [ -n "$vols" ] || { echo "削除対象のボリュームはありません"; return 0; }
  echo "次のボリュームを削除します:"; echo "$vols"
  read -r -p "よろしいですか? [y/N] " ans
  [ "$ans" = "y" ] || { echo "中止しました"; return 0; }
  echo "$vols" | xargs docker volume rm
}

cmd="${1:-}"; shift || true
case "$cmd" in
  image)     cmd_image "$@" ;;
  configure) cmd_configure "$@" ;;
  build)     cmd_build "$@" ;;
  smoke)     cmd_smoke "$@" ;;
  check)     cmd_check "$@" ;;
  run)       cmd_run "$@" ;;
  shell)     cmd_shell "$@" ;;
  status)    cmd_status "$@" ;;
  clean)     cmd_clean "$@" ;;
  ""|-h|--help|help) usage ;;
  *) usage; die "不明なコマンド: $cmd" ;;
esac
