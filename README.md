# swift-static-linux-benchmark

Swift + [Hummingbird](https://github.com/hummingbird-project/hummingbird) の HTTP サーバーで、
**libc（glibc / musl）と allocator の違いがスループット・レイテンシにどう出るか**を、GitHub Actions 上で再現可能な形で比較するベンチマークです。

## 背景

[zunda-pixel/blindlog-api#379](https://github.com/zunda-pixel/blindlog-api/pull/379) で、
glibc + Swift runtime 静的リンク + jemalloc の構成から、Swift 6.4.0 の
[Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)（musl ベース、完全 static binary）へ移行しました。
musl では Ubuntu の jemalloc が使えないため musl 標準の malloc に戻り、allocation-heavy な処理で性能が落ちる懸念がありますが、数値はありませんでした。

### 前提の訂正: Static Linux SDK は既に mimalloc を使っている

当初は「Static Linux SDK = musl malloc」という前提で `musl` と `musl + mimalloc` を比較する予定でした。
しかし CI で検証したところ、**Swift 6.4.0 の Static Linux SDK でビルドしたバイナリは、何も指定しなくても mimalloc を使っていました**。

- [swiftlang/swift-docker#488](https://github.com/swiftlang/swift-docker/pull/488)（2026-01）以降、SDK のビルドスクリプトが
  `libc.a` から musl の allocator（`malloc.lo`、`free.lo` など）を取り除き、mimalloc を入れています
  （"link mimalloc by default, so programs using the Static SDK for Linux get a better memory allocator out of the box"）。
- このリポジトリの `musl-sdk` バイナリにも `mi_malloc` が含まれ、`MIMALLOC_VERBOSE=1` で mimalloc の出力が出ます。

したがって blindlog-api#379 の構成も、実際には「musl + mimalloc（SDK 同梱）」です。
このベンチマークでは SDK をそのまま使った構成を測り、glibc と比べてどうか、mimalloc を新しい版（v3）に差し替えると変わるかを見ます。

## 比較する条件

| Variant | libc | allocator | Build |
|---|---|---|---|
| `glibc` | glibc（動的） | glibc malloc | `swift build -c release`（Swift runtime は動的リンク） |
| `musl-sdk` | musl（静的） | mimalloc（SDK 同梱の版） | `swift build -c release --swift-sdk x86_64-swift-linux-musl` |
| `musl-mimalloc-v3` | musl（静的） | mimalloc v3.5.3 | 上記 + `-Xlinker mimalloc.o` |

- Swift 6.4.0（`swift:6.4.0-resolute`、Ubuntu 26.04）、Static Linux SDK `swift-6.4.0-RELEASE_static-linux-0.1.0`、mimalloc v3.5.3。
  バージョンは [`docker/Dockerfile`](docker/Dockerfile) の `ARG` で固定しています。
  SDK 同梱の mimalloc の版は `verify.sh` が実行時に読み取り、`environment.json` と Job Summary に記録します。
- glibc 版は本来 `--static-swift-stdlib` で Swift runtime も静的リンクにしたいところですが、Swift 6.4.0 では Foundation がリンクできない（CoreFoundation のシンボルが未解決になる）ため、Swift runtime を動的リンクにして `bin/glibc/lib/` に同梱しています。
  そのため glibc 版と musl 版の間には「Swift runtime が動的か静的か」の差も含まれます。
- `musl-mimalloc-v3` は[公式の static override 方式](https://github.com/microsoft/mimalloc#static-override)に従い、
  `src/static.c` を musl sysroot 向けに `mimalloc.o` へコンパイルして最終リンクに渡しています（[`scripts/build-mimalloc.sh`](scripts/build-mimalloc.sh)）。
  object file として直接リンクされるため、`libc.a` 内の SDK 同梱 mimalloc より優先されます。
- glibc + jemalloc は意図的に含めていません。libc・allocator・static/dynamic の差が混ざるためです（第2フェーズ参照）。

### allocator が本当に想定どおりかの検証

variant 名と実際の allocator が食い違っていてはベンチマーク全体が無意味になるため（実際に上記の前提違いはこれで見つかりました）、
[`scripts/verify.sh`](scripts/verify.sh) で以下を確認し、失敗したら CI を落とします。

1. `file` / `ldd`: musl 系は `statically linked`、glibc 版は同梱した `lib/` から Swift runtime が解決される
2. `nm`: musl 系では `malloc` のアドレスが `mi_malloc` と一致する。glibc 版には `mi_malloc` が無い
3. 実行時（`MIMALLOC_VERBOSE=1`）: glibc 版は mimalloc の出力なし、`musl-mimalloc-v3` は v3.5.3、`musl-sdk` はそれ以外の版（SDK 同梱）
4. 全 variant・全 endpoint が 200 を返す

## 結果

条件の異なる runner で 2 回フル計測しました。どちらも x86_64、4 vCPU（サーバー 2 コア / oha 2 コア）、5 rep × 30 秒、median、エラー 0 件です。

| 計測日 | runner | CPU | host glibc | kernel | 全データ |
|---|---|---|---|---|---|
| 2026-09-29 | `ubuntu-26.04` | AMD EPYC 7763 | 2.43 | 7.0 | [`docs/results/2026-09-29-x86_64-ubuntu26.md`](docs/results/2026-09-29-x86_64-ubuntu26.md) |
| 2026-09-28 | `ubuntu-24.04` | AMD EPYC 9V45 | 2.39 | 6.17 | [`docs/results/2026-09-28-x86_64.md`](docs/results/2026-09-28-x86_64.md) |

実行時の allocator はどちらの回も `glibc` = glibc malloc、`musl-sdk` = mimalloc v2.2.4（SDK 同梱）、`musl-mimalloc-v3` = mimalloc v3.5.3 でした。

**まとめ**（この workload と runner の条件下での結果です）:

- **どちらの回でも、Static Linux SDK（musl + mimalloc）版のスループットは glibc 版を下回りませんでした。**
  09-28 はほぼ同等、09-29 は allocation 系で musl 系が約 15% 高い結果でした。
- **p99 レイテンシは両方の回で、c≥10 のとき musl 系のほうが低い**結果でした。
- **RSS は両方の回で musl 系が 6〜12 MB 多い**です。
- SDK 同梱の mimalloc v2.2.4 と v3.5.3 の間には、どちらの回でも意味のある差はありませんでした。
- 2 回で傾向が違った理由（CPU か、glibc 2.39 → 2.43 か）は、この計測では切り分けられていません（後述）。

blindlog-api#379 について: Swift 6.4.0 の Static Linux SDK は標準で mimalloc を使うため、「musl malloc に戻って遅くなる」という懸念は当たりません。
2 回の計測のどちらでも、glibc からの移行によるスループット低下は確認されませんでした。

### 2026-09-29: Ubuntu 26.04 / AMD EPYC 7763

[run 36513768873](https://github.com/zunda-pixel/swift-static-linux-benchmark/actions/runs/36513768873)、commit fe3ca5f、`swift:6.4.0-resolute` でビルド。

`glibc` に対する req/s の差（median）:

| endpoint | variant | c=1 | c=10 | c=25 | c=50 | c=100 |
|---|---|---:|---:|---:|---:|---:|
| plaintext | musl-sdk | +7.2% | +11.2% | +8.8% | +2.6% | +3.0% |
| | musl-mimalloc-v3 | +6.7% | +11.0% | +7.9% | +1.9% | +3.7% |
| json | musl-sdk | +6.1% | +15.9% | +10.8% | +6.6% | +10.7% |
| | musl-mimalloc-v3 | +6.6% | +15.0% | +9.3% | +10.4% | +14.9% |
| allocation | musl-sdk | +9.2% | +15.3% | +15.5% | +15.3% | +14.8% |
| | musl-mimalloc-v3 | +11.0% | +16.9% | +16.9% | +16.3% | +15.7% |
| parallel-allocation | musl-sdk | +14.5% | +15.0% | +15.1% | +15.3% | +16.6% |
| | musl-mimalloc-v3 | +15.3% | +15.7% | +15.8% | +16.5% | +17.1% |

p99 レイテンシ（ms、median）の例:

| endpoint | c | glibc | musl-sdk | musl-mimalloc-v3 |
|---|---:|---:|---:|---:|
| plaintext | 100 | 9.26 | 7.26 | 7.16 |
| json | 100 | 9.37 | 7.39 | 7.05 |
| allocation | 100 | 96.27 | 55.01 | 52.65 |
| parallel-allocation | 100 | 391.63 | 296.04 | 294.01 |

読み取れること:

- **allocation / parallel-allocation では musl 系が glibc より約 15% 高いスループット**でした。rep 間のばらつき（stdev）は 1% 未満なので、ノイズでは説明できない差です。
- plaintext / json でも musl 系が 2〜16% 高い結果でした。ただし c≥50 では musl 系の stdev が 5〜9% あり、こちらは差の大きさの信頼度が下がります。
- p99 は musl 系が低く、allocation c=100 では glibc の約 55% でした。
- RSS は glibc 約 30〜34 MB、musl 系 約 38〜46 MB です。
- c≥10 ではどの variant もサーバーの 2 コアを使い切っており（CPU 約 200%）、同じ CPU 時間でより多くのリクエストを処理できた、ということになります。

### 2026-09-28: Ubuntu 24.04 / AMD EPYC 9V45

全データ: [`docs/results/2026-09-28-x86_64.md`](docs/results/2026-09-28-x86_64.md)
（[run 36430825652](https://github.com/zunda-pixel/swift-static-linux-benchmark/actions/runs/36430825652)、commit 382dd85）

- 条件: `ubuntu-24.04` runner（AMD EPYC 9V45、4 vCPU、host glibc 2.39）、`swift:6.4.0-noble` でビルド、サーバー 2 コア / oha 2 コア、5 rep × 30 秒、median。エラー 0 件。
- 実行時の allocator: `glibc` = glibc malloc、`musl-sdk` = mimalloc v2.2.4（SDK 同梱）、`musl-mimalloc-v3` = mimalloc v3.5.3。

`glibc` に対する req/s の差（median）:

| endpoint | variant | c=1 | c=10 | c=25 | c=50 | c=100 |
|---|---|---:|---:|---:|---:|---:|
| plaintext | musl-sdk | +5.6% | +9.6% | +2.1% | +1.5% | +4.2% |
| | musl-mimalloc-v3 | +6.1% | +9.4% | +5.2% | +3.2% | +1.9% |
| json | musl-sdk | +4.2% | +9.1% | +1.6% | −1.4% | −1.3% |
| | musl-mimalloc-v3 | +1.3% | +6.3% | −0.2% | −1.7% | +0.5% |
| allocation | musl-sdk | −5.9% | −2.2% | −1.3% | −0.6% | −2.9% |
| | musl-mimalloc-v3 | −2.9% | −0.4% | +1.5% | −1.5% | −3.1% |
| parallel-allocation | musl-sdk | −3.1% | −0.9% | +1.1% | +1.7% | −1.1% |
| | musl-mimalloc-v3 | +0.1% | −1.1% | +0.1% | +0.1% | −1.0% |

p99 レイテンシ（ms、median）の例:

| endpoint | c | glibc | musl-sdk | musl-mimalloc-v3 |
|---|---:|---:|---:|---:|
| plaintext | 100 | 6.52 | 2.77 | 2.81 |
| json | 100 | 5.83 | 3.04 | 3.01 |
| allocation | 100 | 49.55 | 30.63 | 31.51 |
| parallel-allocation | 100 | 228.32 | 217.88 | 211.95 |

読み取れること:

- **スループットは 3 variant でほぼ同等**でした。差の多くは rep 間のばらつき（stdev 1〜5%）の範囲に収まっています。
  plaintext / json は musl 系がやや高く、allocation 系は glibc がわずかに高い傾向ですが、ノイズと区別できるほどではありません。
- **mimalloc の版**（SDK 同梱の v2.2.4 と v3.5.3）による意味のある差は見られませんでした。
- **p99 レイテンシは c≥10 で musl 系が一貫して低く**、glibc のおよそ半分でした。スループットが同じなので、レイテンシのばらつきが小さいことになります。
  原因（allocator か、Swift runtime の動的 / 静的リンクの違いか）は、この計測では特定できていません。
- **RSS は musl 系が 7〜11 MB 多い**です（glibc 約 30 MB、musl 系 約 37〜45 MB）。
- c≥10 ではどの variant もサーバーの 2 コアを使い切っており（CPU 約 200%）、スループットはそこで頭打ちです。
  コア数の多い環境で allocator の lock contention が強く出るかどうかは、この計測では確かめられていません。

### 2 回の比較

09-28 から 09-29 で、スループットの絶対値は全体に下がりましたが、下がり方が variant によって違います（c=100 の req/s）。

| endpoint | variant | 09-28 | 09-29 | 変化 |
|---|---|---:|---:|---:|
| plaintext | glibc | 71,037 | 29,408 | −59% |
| | musl-sdk | 74,016 | 30,287 | −59% |
| allocation | glibc | 3,787 | 2,123 | −44% |
| | musl-sdk | 3,677 | 2,437 | −34% |
| parallel-allocation | glibc | 519 | 307 | −41% |
| | musl-sdk | 513 | 358 | −30% |

plaintext は両者とも同じだけ下がっていて、これは CPU の違い（EPYC 9V45 → 7763）でおおむね説明できます。
一方 allocation 系は glibc 版のほうが大きく下がっており、glibc malloc がこの環境で相対的に不利になったことを示しています。

ただし 09-29 は CPU と glibc（2.39 → 2.43、glibc 版はビルドイメージも 26.04 に変更）が同時に変わっているため、どちらが原因かはこの 2 回からは判断できません。
GitHub-hosted runner は同じラベルでも実行ごとに CPU が変わることがあるので、結果を比べるときは `environment.json` の CPU モデルも確認してください。

## Endpoints

| Endpoint | 内容 | 目的 |
|---|---|---|
| `/plaintext` | `Hello, World!` | ほぼ allocation なし。HTTP / Hummingbird / NIO 自体の baseline |
| `/json` | `Encodable` を毎回 `JSONEncoder` で encode | 一般的な API レスポンス |
| `/string` | `(0..<1000).map(String.init).joined(separator: ",")` | String allocation |
| `/array` | 10,000 要素 append（`reserveCapacity` なし） | 再確保による allocation |
| `/array-reserved` | 同上、`reserveCapacity` あり | `/array` との差分で再確保の影響を見る |
| `/allocation` | class instance / Array / String / Dictionary / Data / JSON を混ぜた小オブジェクト大量生成 | 現実的な Swift サーバーの allocation パターン |
| `/parallel-allocation` | `/allocation` 相当を `withTaskGroup` で 8 task 並列実行 | **stress test**（後述） |

`/parallel-allocation` は通常の API の再現ではなく、**allocator の lock contention を意図的に増幅させる stress test** です。
結果を読むときは他の endpoint と区別してください。

デフォルトで計測するのは `plaintext json allocation parallel-allocation` です。

## 計測方法

- 負荷生成は [oha](https://github.com/hatoo/oha)（v1.16.0）。keep-alive あり、localhost。
- **3 variant を 1 つの job（同一 runner VM）で順番に実行**します。別 job にすると VM 差が混ざるためです。
- variant の実行順は rep ごとにローテーションします（`glibc→musl-sdk→musl-mimalloc-v3`、`musl-sdk→musl-mimalloc-v3→glibc`、…）。
- サーバーと oha は `taskset` で CPU を分けます（4 vCPU なら server: 0-1、oha: 2-3）。
- 各 variant をホスト上で直接起動し（コンテナは使わない）、endpoint ごとに warmup 10 秒 → concurrency `1 10 25 50 100` をそれぞれ 30 秒計測。
- 5 rep 実行し、**median** を代表値にします（min / max / stdev も `summary.json` に保存）。
- 計測中は `/proc/<pid>` からサーバーの CPU% と RSS をサンプリングし、peak RSS は計測ごとにリセットして取ります。

デフォルト設定での所要時間は約 2.7 時間です（5 rep × 3 variant × 4 endpoint × (10 + 5 × 30) 秒）。

## 実行

### GitHub Actions

- `pull_request` / `push`（main）: ビルド・検証と、短時間（1 rep、3 秒、concurrency `1 50`）の疎通確認のみ。
- `workflow_dispatch`: フル計測。endpoint・concurrency・rep 数・時間を入力で変更できます。

結果は Job Summary に表として出力され、生データは Artifact（`results/`）に保存されます。

```
results/
├── environment.json   # CPU, メモリ, kernel, Swift / SDK / mimalloc / oha / Hummingbird のバージョン
├── config.json        # 計測パラメータ
├── runs.jsonl         # 各計測の実行順・開始時刻
├── summary.json       # 集計結果
└── <variant>/<endpoint>/c<concurrency>/rep<n>.json       # oha の JSON 出力
                                        rep<n>.proc.json  # CPU% / RSS
```

### ローカル

Docker（buildx）が必要です。バイナリは linux/amd64 向けにビルドされます。

```sh
scripts/build.sh                       # bin/{glibc,musl-sdk,musl-mimalloc-v3}/ を生成
# 以下は Linux (x86_64) 上で実行
scripts/verify.sh
python3 scripts/collect_env.py
REPS=1 DURATION=5 WARMUP=2 scripts/benchmark.sh
python3 scripts/summarize.py
```

サーバー単体は macOS でも `swift run -c release BenchmarkServer` で起動できます（`PORT` / `HOST` 環境変数で変更可）。

## 依存関係の更新

[Dependabot](.github/dependabot.yml) が週次で以下の更新 PR を作ります。

- GitHub Actions
- Swift のベースイメージ（`docker/Dockerfile` の `FROM swift:…`）
- Swift パッケージ（Hummingbird など、`Package.resolved`）

以下は Dependabot の対象外なので、手動で更新します。

- Static Linux SDK の `STATIC_SDK_URL` / `STATIC_SDK_CHECKSUM`（`docker/Dockerfile`）。toolchain と完全に同じバージョンが必要なので、
  Swift イメージの更新 PR ではこれも合わせて更新してください（合っていないと musl 版のビルドが失敗します）。
- mimalloc の `MIMALLOC_VERSION`（`docker/Dockerfile`）
- oha の `OHA_VERSION`（`.github/workflows/benchmark.yml`）

## 結果の読み方

このベンチマークは以下を**主張しません**。

> This benchmark does not attempt to prove that musl is generally slower than glibc.
> It evaluates Swift server workloads under different libc and allocator configurations.

たとえば musl 版のスループットが 40% 低かった場合も「musl は glibc より 40% 遅い」ではなく、
"Under this workload and runner configuration, the musl build achieved 40% lower throughput." と書きます。
GitHub-hosted runner は共有 VM でノイズがあるため、rep 間の stdev も合わせて見てください。

注目するパターン:

- **`/plaintext` で glibc と musl 系が同等、allocation 系で差が出る** → allocator（glibc malloc と mimalloc）の差が主因の可能性が高い。
- **全 endpoint で `glibc > musl-sdk ≒ musl-mimalloc-v3`** → allocator 以外（libc の他の部分、static リンク、Swift runtime の動的/静的、Foundation の実装差など）を疑う。
- **`musl-sdk` と `musl-mimalloc-v3` の差** → mimalloc のバージョン差（とビルドオプションの差）の影響。
- **全 endpoint で 3 者がほぼ同等** → 少なくともこの workload では、Static Linux SDK への移行で性能は大きく変わらない、という結果。

スループット低下と同時にサーバーの CPU% も下がっている場合は、allocator の lock 待ち（contention）を疑う手掛かりになります。

## 第2フェーズ

- `glibc + jemalloc` を variant として追加（blindlog-api の移行前の本番構成の再現）
- musl 本来の allocator（mallocng）を復元した variant を追加し、「musl malloc だった場合」との比較も行う
- コア数の多い runner での計測（2 コアでは CPU が頭打ちになり、contention が見えにくい）
- ARM64 runner での比較
- p99 の差の原因の切り分け（glibc 版を Swift runtime 静的リンクにできれば、runtime の動的 / 静的の差を除ける）
- 09-28 と 09-29 の差の切り分け（同じ runner 上で、Ubuntu 24.04 と 26.04 のコンテナで glibc 版を動かし、glibc 2.39 と 2.43 を比べる）
- 差が出た条件で `perf stat` / `perf record` による解析（`futex`、`malloc` / `free`、lock 周辺）
