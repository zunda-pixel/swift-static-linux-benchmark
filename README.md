# swift-static-linux-benchmark

Swift + [Hummingbird](https://github.com/hummingbird-project/hummingbird) の HTTP サーバーで、
**libc（glibc / musl）と allocator の違いがスループット・レイテンシにどう出るか**を、GitHub Actions 上で再現可能な形で比較するベンチマークです。

## 背景

[zunda-pixel/blindlog-api#379](https://github.com/zunda-pixel/blindlog-api/pull/379) で、
glibc + Swift runtime 静的リンク + jemalloc の構成から、Swift 6.4.0 の
[Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)（musl ベース、完全 static binary）へ移行しました。
musl では Ubuntu の jemalloc が使えないため musl 標準の malloc に戻り、allocation-heavy な処理で性能が落ちる懸念がありますが、数値はありませんでした。

検証する仮説:

> Static Linux SDK そのものが遅いのではなく、allocation-heavy / high-concurrency な workload では
> musl の標準 allocator がボトルネックになり得る。mimalloc に差し替えると、その差は縮まる可能性がある。

## 比較する条件

| Variant | libc | allocator | Build |
|---|---|---|---|
| `glibc` | glibc（動的） | glibc malloc | `swift build -c release`（Swift runtime は動的リンク） |
| `musl` | musl（静的） | musl malloc | `swift build -c release --swift-sdk x86_64-swift-linux-musl` |
| `musl-mimalloc` | musl（静的） | mimalloc | 上記 + `-Xlinker mimalloc.o` |

- Swift 6.4.0（`swift:6.4.0-noble`）、Static Linux SDK `swift-6.4.0-RELEASE_static-linux-0.1.0`、mimalloc v3.5.3。
  バージョンは [`docker/Dockerfile`](docker/Dockerfile) の `ARG` で固定しています。
- glibc 版は本来 `--static-swift-stdlib` で Swift runtime も静的リンクにしたいところですが、Swift 6.4.0 では Foundation がリンクできない（CoreFoundation のシンボルが未解決になる）ため、Swift runtime を動的リンクにして `bin/glibc/lib/` に同梱しています。
  そのため glibc 版と musl 版の間には「Swift runtime が動的か静的か」の差も含まれます。
- mimalloc は[公式の static override 方式](https://github.com/microsoft/mimalloc#static-override)に従い、
  `src/static.c` を musl sysroot 向けに `mimalloc.o` へコンパイルして最終リンクに渡しています（[`scripts/build-mimalloc.sh`](scripts/build-mimalloc.sh)）。
- glibc + jemalloc は意図的に含めていません。libc・allocator・static/dynamic の差が混ざるためです（第2フェーズ参照）。

### allocator が本当に切り替わっているかの検証

`musl-mimalloc` が実は musl malloc を使っていた、ではベンチマーク全体が無意味になるため、
[`scripts/verify.sh`](scripts/verify.sh) で以下を確認し、失敗したら CI を落とします。

1. `file` / `ldd`: musl 系は `statically linked`、glibc 版は同梱した `lib/` から Swift runtime が解決される
2. `nm`: `musl-mimalloc` では `malloc` のアドレスが `mi_malloc` と一致する。他の variant には `mi_malloc` が無い
3. 実行時: `MIMALLOC_VERBOSE=1` で起動したとき、`musl-mimalloc` だけが mimalloc の出力を出す
4. 全 variant・全 endpoint が 200 を返す

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
- variant の実行順は rep ごとにローテーションします（`glibc→musl→musl-mimalloc`、`musl→musl-mimalloc→glibc`、…）。
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
scripts/build.sh                       # bin/{glibc,musl,musl-mimalloc}/ を生成
# 以下は Linux (x86_64) 上で実行
scripts/verify.sh
python3 scripts/collect_env.py
REPS=1 DURATION=5 WARMUP=2 scripts/benchmark.sh
python3 scripts/summarize.py
```

サーバー単体は macOS でも `swift run -c release BenchmarkServer` で起動できます（`PORT` / `HOST` 環境変数で変更可）。

## 結果の読み方

このベンチマークは以下を**主張しません**。

> This benchmark does not attempt to prove that musl is generally slower than glibc.
> It evaluates Swift server workloads under different libc and allocator configurations.

たとえば musl のスループットが 40% 低かった場合も「musl は glibc より 40% 遅い」ではなく、
"Under this workload and runner configuration, the musl build achieved 40% lower throughput." と書きます。
GitHub-hosted runner は共有 VM でノイズがあるため、rep 間の stdev も合わせて見てください。

注目するパターン:

- **Pattern A** — `/plaintext` では 3 者がほぼ同等、かつ `/allocation`・高 concurrency で `glibc > musl`、`glibc ≒ musl-mimalloc`
  → allocator が主因である可能性が高い。
- **Pattern B** — 全 endpoint で `glibc > musl ≒ musl-mimalloc`
  → allocator 以外（libc の他の部分、static リンク、Foundation の実装差など）を疑う。
- **Pattern C** — 全 endpoint で 3 者がほぼ同等
  → 少なくともこの workload では musl allocator は重大な問題にならなかった、という結果。

スループット低下と同時にサーバーの CPU% も下がっている場合は、allocator の lock 待ち（contention）を疑う手掛かりになります。

## 第2フェーズ

- `glibc + jemalloc` を 4 つ目の variant として追加（blindlog-api の移行前の本番構成の再現）
- ARM64 runner での比較
- 差が出た条件で `perf stat` / `perf record` による解析（`futex`、`malloc` / `free`、lock 周辺）
