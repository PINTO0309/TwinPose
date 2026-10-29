# TwinPose Linux テスト環境 (Docker)

Windows / Visual Studio 向けの本プロジェクトを、ホスト環境を汚さずに Linux 上でビルド・実行するための Docker 構成です。
ホストに残るものは **Docker イメージ 1 つと名前付きボリューム 3 つ** だけで、`docker/twinpose.sh clean` と `docker rmi` で完全に消せます。

## 必要なもの

- Docker Engine (ユーザーが `docker` グループに所属していること)
- 対話実行する場合: X11 セッション (`DISPLAY` が設定されていること)
- GPU を使う場合 (任意): NVIDIA ドライバ + NVIDIA Container Toolkit (CDI 仕様 `/var/run/cdi/nvidia.yaml` が生成済みであること)

サブモジュールは事前に取得しておきます (リポジトリ内にしか書き込みません)。

```
git submodule update --init --depth 1
```

## 使い方

```
docker/twinpose.sh image          # 1. イメージ作成 (apt のためネットワークを使う唯一の操作)
docker/twinpose.sh build          # 2. CMake 構成 + ビルド (OpenCV を含むので初回は数分)
docker/twinpose.sh smoke --load   # 3. ヘッドレス動作確認: Shelf データセットを読み込み docker/out/ にスクリーンショット
docker/twinpose.sh run            # 4. ホストの画面にウィンドウを出して対話操作 (Mesa ソフトウェア GL)
docker/twinpose.sh run --gpu      #    NVIDIA GPU を使う場合
```

`run` のウィンドウは既定で最大化され、ドラッグでサイズ変更できます。固定サイズにしたい場合は `TWINPOSE_WINDOW_SIZE=1920x1080 docker/twinpose.sh run` のように指定します。
パネル (Load Dataset など) はマウスホイールでスクロールでき、右下の角をドラッグすると大きくできます。配置は `imgui.ini` に保存されます。

その他: `configure` / `shell` (コンテナ内 bash) / `status` / `clean` (ボリューム削除)。

`docker run` が使えない環境では `docker/twinpose.sh check` が代替になります。BuildKit (`docker build`) のサンドボックス内でビルドとヘッドレス起動テストを行い、
スクリーンショットとログだけを `docker/out/buildcheck/` に取り出します (ビルド成果物は BuildKit のキャッシュマウントに残り、リポジトリには書き込みません)。
この経路はサンドボックス内で root として動くため、日常の対話実行には `run` を使ってください。

`smoke` の出力は `docker/out/` に入ります (`01_startup.png`, `02_imported.png`, `03_loaded.png`, `twinpose.log`, `glxinfo.log`)。このディレクトリは git 管理外です。

## 隔離とセキュリティの設計

| 項目 | 設定 |
|---|---|
| 実行ユーザー | ホストと同じ UID/GID (`--user`)。コンテナ内でも root にならない |
| 権限 | `--cap-drop ALL`、`--security-opt no-new-privileges` |
| ファイルシステム | ルート FS は読み取り専用 (`--read-only`)。書き込み先は `/tmp` (tmpfs, noexec) と 3 つのボリュームのみ |
| ネットワーク | 常に `--network none` (イメージ作成時の apt を除く) |
| マウント | リポジトリを `/work` に bind mount。`build/` `binaries/` `intermediate/` は名前付きボリュームで上書き |
| X11 (`run` のみ) | 使用中ディスプレイのソケット 1 本と Xauthority (読み取り専用) だけを共有。`xhost +` は使わない |
| GPU (`run --gpu` のみ) | CDI (`--device nvidia.com/gpu=all`) で渡す。`--privileged` や `/dev` の丸ごと共有はしない |
| Docker ソケット | コンテナには渡さない |

`smoke` はコンテナ内の Xvfb (仮想ディスプレイ) と Mesa llvmpipe で動くため、ホストの X11 にも GPU にも触れません。

## 注意点

- **ビルド成果物がボリュームにある理由**: このリポジトリは exFAT 上にあり、シンボリックリンクが作れません。`libopencv_world.so` などの共有ライブラリはバージョン付きシンボリックリンクを必要とするため、`CMakeLists.txt` が固定している `binaries/` `intermediate/` と `build/` をボリュームで差し替えています。ホスト側の同名ディレクトリは空のまま (git 管理外) です。
- **ホストでは実行できません**: イメージは Ubuntu 24.04 (glibc 2.39) なので、生成物は Ubuntu 22.04 のホストでは動きません。`std::format` を使うコードのため GCC 13 以上が必要で、22.04 標準の GCC 11 ではビルドできません。
- **Linux 向けの最小修正**: MSVC では暗黙に通るが GCC では通らない箇所を直しています。`libraries/ink/ink.cpp` (`<cstring>` 追加)、`src/algorithm/Evaluation.h` (`<cfloat>` 追加)、`src/application/Visualization.h` (`std::fmodf` → `std::fmod`)、`src/application/Room.h` (`Assets/` → 実ディレクトリ名の `assets/`。大文字小文字を区別する FS でも動くように)。
- **ウィンドウのリサイズ対応**: 元は 1280×720 固定でした。`Application.h` でリサイズ可能にし、`Room.h` の `resize()` で描画ターゲットを作り直します。`Main.cpp` は環境変数 `TWINPOSE_WINDOW_SIZE` を読みます。
- **`imgui.ini`**: アプリは作業ディレクトリ (`/work` = リポジトリ直下) にウィンドウ配置を保存します。`*.ini` は git 管理外です。
- **ディスク使用量**: イメージ約 1 GB、ビルド成果物のボリューム数 GB が Docker のデータ領域 (`/var/lib/docker`) に置かれます。

## トラブルシューティング

**`docker run` が `namespace {"time" ""} does not exist` で失敗する** (`docker/twinpose.sh check` は影響を受けません)
Docker Engine 29 以降は time namespace を要求するため、runc 1.2 未満では全てのコンテナ起動が失敗します。
`which -a runc` で古い runc (例: `/usr/local/bin/runc` 1.1.x) がパッケージ版 (`/usr/bin/runc`) より前に見つかる場合は、
古い containerd / runc を除去するかパッケージ版の containerd サービスに切り替えてください。

**X ウィンドウが開かない**
`xauth list` に `#ffff#...` (FamilyWild) または `<ホスト名>/unix:<番号>` の項目があるか確認してください。
無い場合は `xhost +SI:localuser:$(id -un)` で「自分のユーザーのローカル接続」だけを許可できます (`xhost +` は使わないでください)。
