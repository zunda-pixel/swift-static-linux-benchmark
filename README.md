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
| `glibc` | glibc（動的） | glibc malloc | `swift build -c release -Xswiftc -static-stdlib` |
| `musl-sdk` | musl（静的） | mimalloc（SDK 同梱の版） | `swift build -c release --swift-sdk x86_64-swift-linux-musl` |
| `musl-mimalloc-v3` | musl（静的） | mimalloc v3.5.3 | 上記 + `-Xlinker mimalloc.o` |

- Swift 6.4.0（`swift:6.4.0-resolute`、Ubuntu 26.04）、Static Linux SDK `swift-6.4.0-RELEASE_static-linux-0.1.0`、mimalloc v3.5.3。
  バージョンは [`docker/Dockerfile`](docker/Dockerfile) の `ARG` で固定しています。
  SDK 同梱の mimalloc の版は `verify.sh` が実行時に読み取り、`environment.json` と Job Summary に記録します。
- glibc 系の variant はすべて `-Xswiftc -static-stdlib` で Swift runtime（Foundation を含む）を静的リンクしています。musl 系も Swift runtime は静的なので、両者の差は libc と allocator（とリンク方式）に絞られます。
  SwiftPM の `--static-swift-stdlib` は、Swift 6.4.0 のデフォルトのビルドシステム（swiftbuild）では Foundation がリンクできない（CoreFoundation のシンボルが未解決になる）ため使っていません
  （[swiftlang/swift-package-manager#10592](https://github.com/swiftlang/swift-package-manager/issues/10592)）。
  **2026-09-28 / 09-29 の結果は、glibc 系の Swift runtime を動的リンクにしていた時点のもの**です。
- `musl-mimalloc-v3` は[公式の static override 方式](https://github.com/microsoft/mimalloc#static-override)に従い、
  `src/static.c` を musl sysroot 向けに `mimalloc.o` へコンパイルして最終リンクに渡しています（[`scripts/build-mimalloc.sh`](scripts/build-mimalloc.sh)）。
  object file として直接リンクされるため、`libc.a` 内の SDK 同梱 mimalloc より優先されます。

### glibc のバージョン差を切り分けるための variant

2026-09-28 と 09-29 の結果の違いが CPU によるものか glibc（2.39 → 2.43）によるものかを切り分けるため、
Ubuntu 24.04 でビルドした glibc 版を 2 つ用意しています。どちらも同じバイナリです。

| Variant | ビルドイメージ | 実行時の glibc | `glibc` との比較で分かること |
|---|---|---|---|
| `glibc` | `swift:6.4.0-resolute`（26.04） | host（26.04 runner では 2.43） | — |
| `glibc-noble` | `swift:6.4.0-noble`（24.04） | host（2.43） | ビルドイメージの差 |
| `glibc-noble-2.39` | `swift:6.4.0-noble`（24.04） | 同梱の 2.39 | `glibc-noble` との差 = glibc 2.39 と 2.43 の差 |

`glibc-noble-2.39` はコンテナを使わず、Ubuntu 24.04 の `libc.so.6` などを `bin/glibc-noble-2.39/glibc/` に同梱し、
同梱した動的ローダー（`ld-linux-x86-64.so.2 --library-path …`）経由でホスト上で起動します。
これで同じ runner・同じ CPU のまま glibc のバージョンだけを変えられます。
`verify.sh` は、実行中のプロセスに実際にどの `libc.so.6` がマップされているかと、その glibc のバージョンを確認します。

これらは通常のフル計測には含まれません。`workflow_dispatch` の `variants` に指定して計測します
（例: `glibc glibc-noble glibc-noble-2.39 musl-sdk`）。

### 移行前の本番構成を再現する variant: `glibc-noble-2.39-jemalloc`

blindlog-api の #379 直前（commit eecd754）の Dockerfile と同じ構成です。

| | 移行前の blindlog-api | `glibc-noble-2.39-jemalloc` |
|---|---|---|
| ビルドイメージ | `swift:6.4.0-noble` | `swift:6.4.0-noble` |
| ビルド | `-Xswiftc -static-stdlib -Xlinker -ljemalloc` | 同じ |
| 実行時の glibc | `ubuntu:noble`（2.39） | 同梱の 2.39 |
| jemalloc | Ubuntu の `libjemalloc2` | 同じパッケージの `libjemalloc.so.2` を同梱 |

`glibc-noble-2.39` と同じ仕組みで、同梱した動的ローダー経由でホスト上で起動します。
比べると次のことが分かります。

- `musl-sdk` との比較: blindlog-api#379 の移行で、本番の性能がどう変わったか
- `glibc-noble-2.39` との比較: 同じ glibc 2.39・同じビルド方法での、glibc malloc と jemalloc の差
- allocation 系で `musl-sdk` とほぼ同じなら、musl 系の優位は allocator（glibc malloc と比べた新しい allocator）によるもの

### musl の allocator と memcpy を切り分ける variant

| Variant | allocator | memcpy | 分かること |
|---|---|---|---|
| `musl-mallocng` | musl 本来の mallocng（musl 1.2.5 をソースからビルド） | musl | SDK が mimalloc にしていなかった場合（Swift 6.4.0 より前の SDK 相当）の性能 |
| `musl-sdk-fastmemcpy` | mimalloc（SDK 同梱） | 小さなコピーが速い memcpy（x86_64 のみ） | x64 で musl-sdk が jemalloc 版に負ける原因が memcpy かどうか |

- `musl-mallocng`: SDK は `libc.a` から musl の allocator を、`libc++abi.a` から `operator new/delete` を取り除いて mimalloc に置き換えています。
  そこで SDK と同じ musl 1.2.5 をソースからビルドし、allocator のオブジェクトと、malloc の上に書いた `operator new/delete`（[`native/new_delete.cpp`](native/new_delete.cpp)）を最終リンクに渡します（[`scripts/build-musl-malloc.sh`](scripts/build-musl-malloc.sh)）。
  オブジェクトは `libc.a` のメンバーより優先されるので、SDK の mimalloc は取り込まれません。musl のビルドオプションは SDK と同じとは限りません。
- `musl-sdk-fastmemcpy`: musl の x86_64 の memcpy は `rep movsq` によるもので、小さなコピーでは起動のコストが目立ちます。
  256 バイトまでをベクトルのロード / ストアで、それより大きいものを `rep movsb` でコピーする memcpy（[`native/fast_memcpy.c`](native/fast_memcpy.c)）に置き換えます。
  Docker のビルド中に、長さ・アライメント・前方向の重なりを総当たりで確かめるテスト（[`native/test_fast_memcpy.c`](native/test_fast_memcpy.c)）を通してからリンクします。
  aarch64 では musl の memcpy がすでに最適化されているので置き換えず、`musl-sdk` と同じバイナリになります。

### allocator が本当に想定どおりかの検証

variant 名と実際の allocator が食い違っていてはベンチマーク全体が無意味になるため（実際に上記の前提違いはこれで見つかりました）、
[`scripts/verify.sh`](scripts/verify.sh) で以下を確認し、失敗したら CI を落とします。

1. `file` / `ldd`: musl 系は `statically linked`。glibc 系は Swift runtime への動的依存がないこと、
   `libc.so.6` が想定したもの（host か同梱）に解決されること、jemalloc 版では `libjemalloc.so.2` が同梱したものに解決されること
2. `nm`: musl 系では `malloc` のアドレスが `mi_malloc` と一致する。glibc 版には `mi_malloc` が無い
3. 実行時（`MIMALLOC_VERBOSE=1`、`MALLOC_CONF=stats_print:true`）: glibc 系と `musl-mallocng` は mimalloc の出力なし、`musl-mimalloc-v3` は v3.5.3、`musl-sdk` はそれ以外の版（SDK 同梱）。
   `musl-mallocng` は mallocng のシンボル（`__malloc_context`）があること、`musl-sdk-fastmemcpy` は（x86_64 で）`memcpy` が `native/fast_memcpy.c` に解決されること。
   glibc 系は実行中のプロセスにマップされた `libc.so.6` とそのバージョンを確認し、jemalloc 版だけが `libjemalloc.so.2` をマップして jemalloc の統計を出力すること
4. 全 variant・全 endpoint が 200 を返す

## 結果

条件の異なる runner でフル計測を 5 回（x64 4 回、ARM64 1 回）、コア数スケーリングを 1 回、`perf` による調査を 2 回（x64 / ARM64）行いました。
いずれも 4 vCPU で、フル計測は 5 rep × 30 秒の median、エラー 0 件です。
x64 の runner は物理 2 コア × SMT 2 スレッドなので、「サーバー 2 vCPU / oha 2 vCPU」は物理コアを 1 つずつ分けた構成です（[計測方法](#計測方法)）。

| 計測日 | 内容 | runner | CPU | host glibc | 全データ |
|---|---|---|---|---|---|
| 2026-09-30 | perf | `ubuntu-26.04-arm` | Neoverse-N2 | 2.43 | [`docs/results/2026-09-30-aarch64-profile.md`](docs/results/2026-09-30-aarch64-profile.md) |
| 2026-09-30 | perf | `ubuntu-26.04` | AMD EPYC 9V74 | 2.43 | [`docs/results/2026-09-30-x86_64-profile.md`](docs/results/2026-09-30-x86_64-profile.md) |
| 2026-09-30 | コア数スケーリング | `ubuntu-26.04` | AMD EPYC 7763 | 2.43 | [`docs/results/2026-09-30-x86_64-cpu-scaling.md`](docs/results/2026-09-30-x86_64-cpu-scaling.md) |
| 2026-09-30 | フル計測（ARM64） | `ubuntu-26.04-arm` | Neoverse-N2 | 2.43 | [`docs/results/2026-09-30-aarch64.md`](docs/results/2026-09-30-aarch64.md) |
| 2026-09-29 | フル計測（jemalloc） | `ubuntu-26.04` | AMD EPYC 9V74 | 2.43 | [`docs/results/2026-09-29-x86_64-jemalloc.md`](docs/results/2026-09-29-x86_64-jemalloc.md) |
| 2026-09-29 | フル計測（glibc 切り分け） | `ubuntu-26.04` | Intel Xeon Platinum 8370C | 2.43 | [`docs/results/2026-09-29-x86_64-glibc-split.md`](docs/results/2026-09-29-x86_64-glibc-split.md) |
| 2026-09-29 | フル計測 | `ubuntu-26.04` | AMD EPYC 7763 | 2.43 | [`docs/results/2026-09-29-x86_64-ubuntu26.md`](docs/results/2026-09-29-x86_64-ubuntu26.md) |
| 2026-09-28 | フル計測 | `ubuntu-24.04` | AMD EPYC 9V45 | 2.39 | [`docs/results/2026-09-28-x86_64.md`](docs/results/2026-09-28-x86_64.md) |

実行時の allocator はどの回も `glibc` 系 = glibc malloc、`glibc-noble-2.39-jemalloc` = jemalloc 5.3.0、`musl-sdk` = mimalloc v2.2.4（SDK 同梱）、`musl-mimalloc-v3` = mimalloc v3.5.3 でした。
2026-09-29（jemalloc）以降の回は、全 variant の Swift runtime を静的リンクにしています（それ以前の回は glibc 系が動的リンク）。

**まとめ**（この workload と runner の条件下での結果です）:

- **移行前の本番構成（glibc 2.39 + jemalloc）と比べた Static Linux SDK（musl + mimalloc）版は、アーキテクチャで向きが変わりました。**

  | | x64（EPYC 9V74） | ARM64（Neoverse-N2） |
  |---|---:|---:|
  | allocation | −2%（c=1 は −5%） | +4〜7% |
  | parallel-allocation | −4% | +2〜4% |
  | plaintext | +3〜6% | +2〜16% |
  | json | +1〜4% | −3〜+12% |

  allocation 系の差は、どちらも rep 間のばらつき（stdev 1.5% 未満）より大きい差です。
- **x64 で musl 版が allocation 系で負けるのは、memcpy が遅いため**と考えられます。
  allocation の CPU 時間のうち、musl 版は約 10% が `memcpy` / `memmove` / `memset` でした。glibc 版では同じ関数が 2% 以下です。
  ARM64 では musl 版の memcpy 系は約 2.4% にとどまり、mimalloc の速さがそのまま出て jemalloc より速くなりました。
- **glibc malloc は jemalloc より allocation 系で約 10〜15% 遅い**結果が、x64 でも ARM64 でも出ました。plaintext / json では差がありません。
  glibc malloc 版は allocation の CPU 時間の約 20% を libc（主に malloc の内部関数）で使っていて、jemalloc 版の約 2 倍です。
- **glibc malloc と比べると、Static Linux SDK 版はどの回も下回りませんでした**（allocation 系で 0〜15% 速い。差は CPU によって違う）。
- **コア数を増やしても、variant の順位と差はほぼ変わりませんでした**（1〜3 vCPU、x64）。allocator の lock contention でスループットが伸びなくなる様子は、3 vCPU までは見えません。
- **p99 レイテンシは、どの回・どのアーキテクチャでも c≥10 で musl 系のほうが低い**結果でした（plaintext / json では glibc 系の約半分）。
  perf では、musl 版は 1 リクエストあたりのコンテキストスイッチと wakeup が多く、`epoll_wait` の回数が半分以下でした。スレッドの起こし方の違いがレイテンシの分布に効いている可能性がありますが、原因までは特定できていません。
- **glibc 2.39 → 2.43 で plaintext / json が約 14% 遅くなったのは、Intel Xeon 8370C の回だけ**でした。AMD EPYC 9V74 と Neoverse-N2 では差がない（ARM64 ではむしろ 2.43 がわずかに速い）ので、特定の CPU での現象と考えられます。
  なお glibc 2.43 の malloc は、allocation 系で `futex` の呼び出しが 2.39 の 4〜25 倍に増えていましたが、スループットはほぼ同じでした。
- **ビルドイメージ（Ubuntu 24.04 と 26.04）による差はありませんでした**（±2% 以内）。
- **RSS は musl 系が多く**、jemalloc 版と比べて約 13 MB 多い結果でした（x64 / ARM64 とも）。
- SDK 同梱の mimalloc v2.2.4 と v3.5.3 の間には、意味のある差はありませんでした。

blindlog-api#379 について: Swift 6.4.0 の Static Linux SDK は標準で mimalloc を使うため、「musl malloc に戻って大きく遅くなる」という懸念は当たりませんでした。
移行前の本番構成（jemalloc）と比べると、x64 では allocation の多い処理が数 % 遅く、ARM64 では逆に数 % 速くなります。どちらでもメモリは 10 MB 余り増え、p99 レイテンシは下がります。

### 2026-09-30: ARM64 / Neoverse-N2

[run 36674131223](https://github.com/zunda-pixel/swift-static-linux-benchmark/actions/runs/36674131223)、commit 1a78495、`ubuntu-26.04-arm`（Neoverse-N2、4 コア、SMT なし）。全 variant とも Swift runtime は静的リンクです。

`glibc-noble-2.39-jemalloc`（移行前の本番構成）に対する req/s の差（median）:

| endpoint | variant | c=1 | c=10 | c=25 | c=50 | c=100 |
|---|---|---:|---:|---:|---:|---:|
| plaintext | glibc（2.43） | +3.0% | +4.8% | +2.6% | +1.5% | +1.7% |
| | glibc-noble-2.39 | +2.5% | +3.9% | +2.9% | +3.6% | +1.3% |
| | musl-sdk | +14.7% | +15.5% | +4.9% | +1.6% | +3.0% |
| json | glibc（2.43） | +0.5% | +3.6% | +2.2% | +1.0% | +0.7% |
| | glibc-noble-2.39 | −0.7% | +3.3% | +4.7% | +0.4% | +1.2% |
| | musl-sdk | +12.4% | +6.8% | −2.8% | −3.4% | −1.6% |
| allocation | glibc（2.43） | −9.1% | −10.6% | −11.9% | −12.1% | −12.7% |
| | glibc-noble-2.39 | −10.5% | −9.6% | −11.4% | −12.0% | −12.9% |
| | musl-sdk | +3.9% | +6.9% | +5.7% | +4.7% | +3.9% |
| parallel-allocation | glibc（2.43） | −10.8% | −13.6% | −13.9% | −14.2% | −14.6% |
| | glibc-noble-2.39 | −9.2% | −13.4% | −13.9% | −14.3% | −15.3% |
| | musl-sdk | +3.7% | +1.8% | +1.8% | +1.6% | +1.5% |

rep 間のばらつき（stdev）は、plaintext / json の glibc 系（2〜5%）を除いて 1.5% 未満です。

p99 レイテンシ（ms、median、c=100）:

| endpoint | glibc（2.43） | glibc-noble-2.39 | glibc-noble-2.39-jemalloc | musl-sdk |
|---|---:|---:|---:|---:|
| plaintext | 7.72 | 7.88 | 8.28 | 3.88 |
| json | 7.09 | 7.30 | 7.75 | 4.28 |
| allocation | 57.67 | 44.19 | 38.23 | 31.20 |
| parallel-allocation | 226.50 | 207.25 | 172.10 | 166.55 |

読み取れること:

- ARM64 では **musl-sdk が allocation 系で jemalloc 版より速い**結果でした（allocation +4〜7%、parallel-allocation +2〜4%）。x64 の結果とは逆です（理由は perf の節）。
- glibc malloc は jemalloc より allocation 系で約 10〜15% 遅く、x64 と同じ傾向でした。
- glibc 2.39 と 2.43 の差はほぼありません（±2% 程度）。
- p99 は x64 と同じく musl-sdk が最も低く、plaintext / json では glibc 系の約半分でした。
- RSS は glibc-noble-2.39 約 25 MB、jemalloc 版 約 28 MB、musl-sdk 約 41 MB でした。host の glibc 2.43 を使う `glibc` 版も約 40 MB と多く、glibc 2.39 版との差の理由は調べていません。

### 2026-09-30: コア数スケーリング（x64 / AMD EPYC 7763）

[run 36676880127](https://github.com/zunda-pixel/swift-static-linux-benchmark/actions/runs/36676880127)、commit 3f67ebd。サーバーの CPU を 1 / 2 / 3 vCPU に変えて（oha は残り）、同じ job の中で allocation 系を計測しました。
この runner は物理 2 コア × SMT 2 スレッドなので、1 → 2 vCPU は同じ物理コアのもう 1 スレッドを足すだけ、3 vCPU で物理コアが 2 つになります。

req/s（median、c=100）と、1 vCPU に対する倍率:

| endpoint | variant | 1 vCPU | 2 vCPU | 3 vCPU |
|---|---|---:|---:|---:|
| allocation | glibc-noble-2.39 | 1,738 | 2,157（×1.24） | 3,841（×2.21） |
| | glibc-noble-2.39-jemalloc | 2,039 | 2,482（×1.22） | 4,383（×2.15） |
| | musl-sdk | 1,908 | 2,461（×1.29） | 4,311（×2.26） |
| parallel-allocation | glibc-noble-2.39 | 274 | 316（×1.15） | 580（×2.12） |
| | glibc-noble-2.39-jemalloc | 331 | 368（×1.11） | 675（×2.04） |
| | musl-sdk | 310 | 365（×1.17） | 653（×2.10） |

`glibc-noble-2.39-jemalloc` に対する差（c=100）:

| endpoint | variant | 1 vCPU | 2 vCPU | 3 vCPU |
|---|---|---:|---:|---:|
| allocation | glibc-noble-2.39 | −14.8% | −13.1% | −12.4% |
| | musl-sdk | −6.4% | −0.9% | −1.6% |
| parallel-allocation | glibc-noble-2.39 | −17.4% | −14.1% | −14.1% |
| | musl-sdk | −6.4% | −0.8% | −3.3% |

rep 間のばらつき（stdev）は 2.4% 未満です。

読み取れること:

- どの variant も CPU を使い切っていて（1 vCPU あたり約 100%）、スループットは CPU に比例して伸びました。3 vCPU までで allocator の lock contention による頭打ちは見えません。
- 1 vCPU では musl-sdk と jemalloc 版の差が約 6% に広がり、2 vCPU 以上では 1〜3% に縮みました。musl-sdk はスレッドが増えたときの伸びがわずかに大きい結果です。
- glibc malloc は、どの CPU 数でも jemalloc より 12〜17% 遅い結果でした。
- 4 vCPU を超える環境での contention は、GitHub の標準 runner では確かめられません。

### 2026-09-30: perf による調査（x64 / AMD EPYC 9V74、ARM64 / Neoverse-N2）

x64: [run 36676882790](https://github.com/zunda-pixel/swift-static-linux-benchmark/actions/runs/36676882790)、ARM64: [run 36676885678](https://github.com/zunda-pixel/swift-static-linux-benchmark/actions/runs/36676885678)（commit 3f67ebd）。
c=50 の負荷を 30 秒かけながら、`perf stat` と `perf record` を取りました（[`scripts/profile.sh`](scripts/profile.sh)）。各条件 1 回だけの計測なので、req/s は参考値です。
x64 の VM ではハードウェアカウンタ（cycles / instructions）が使えず、ARM64 では使えました。
glibc の `libc.so.6` は内部関数のシンボルがなく、`malloc` / `free` 以外の malloc の内部処理や最適化された memcpy は「名前なし」に入ります。

allocation の CPU 時間の内訳（% of samples）:

| | variant | allocator の関数 | memcpy / memmove / memset | libc.so.6（名前なし） |
|---|---|---:|---:|---:|
| x64 | glibc（2.43） | 4.7% | 0.1% | 13.5% |
| | glibc-noble-2.39 | 6.3% | 0.0% | 13.9% |
| | glibc-noble-2.39-jemalloc | 9.7% | 0.1% | 2.2% |
| | musl-sdk | 9.8% | **9.7%** | — |
| ARM64 | glibc（2.43） | 6.1% | 0.4% | 16.2% |
| | glibc-noble-2.39 | 5.7% | 0.5% | 15.3% |
| | glibc-noble-2.39-jemalloc | 10.5% | 0.5% | 1.4% |
| | musl-sdk | 7.4% | 2.4% | — |

1 リクエストあたりの値（allocation、c=50）:

| | variant | CPU µs | 命令数 | コンテキストスイッチ | futex | epoll_wait |
|---|---|---:|---:|---:|---:|---:|
| x64 | glibc（2.43） | 629 | – | 2.31 | 1.17 | 1.66 |
| | glibc-noble-2.39 | 648 | – | 2.23 | 0.069 | 1.67 |
| | glibc-noble-2.39-jemalloc | 576 | – | 2.14 | 0.080 | 1.64 |
| | musl-sdk | 588 | – | 1.83 | 0.651 | 1.15 |
| ARM64 | glibc（2.43） | 592 | 4.14 M | 2.35 | 2.38 | 1.62 |
| | glibc-noble-2.39 | 606 | 4.27 M | 2.24 | 0.097 | 1.61 |
| | glibc-noble-2.39-jemalloc | 565 | 3.75 M | 2.73 | 0.035 | 1.68 |
| | musl-sdk | 493 | 3.62 M | 1.76 | 0.272 | 1.20 |

plaintext の 1 リクエストあたりの値（c=50）:

| | variant | CPU µs | コンテキストスイッチ | wakeup | futex | epoll_wait |
|---|---|---:|---:|---:|---:|---:|
| x64 | glibc-noble-2.39-jemalloc | 42.8 | 0.301 | 0.236 | 0.409 | 0.194 |
| | musl-sdk | 42.7 | 0.536 | 0.286 | 0.556 | 0.087 |
| ARM64 | glibc-noble-2.39-jemalloc | 48.5 | 0.232 | 0.170 | 0.274 | 0.183 |
| | musl-sdk | 50.6 | 0.469 | 0.253 | 0.503 | 0.089 |

読み取れること:

- **musl の memcpy は x64 で遅い**: allocation で musl-sdk は CPU 時間の約 10% を memcpy 系に使っています。
  glibc 版は「名前なし」を含めても libc 全体が jemalloc 版で 2〜3% なので、glibc の memcpy は多くても 2% 程度です。
  musl の x86_64 の memcpy は単純な実装（`rep movsq`）で、glibc の AVX 版より遅いと考えられます。ARM64 では musl の memcpy 系は約 2.4% でした。
  x64 で musl-sdk の allocator の速さ（allocator の関数は jemalloc 版と同程度）が memcpy で相殺され、ARM64 ではそのまま出た、と説明できます。
- **glibc malloc は重い**: glibc malloc 版は「allocator の関数」と「名前なし」を合わせて CPU 時間の約 20% を使い、jemalloc 版（約 12%）の約 2 倍です。
- **glibc 2.43 の malloc は futex が多い**: allocation で 1 リクエストあたりの futex が 2.39 の 17〜25 倍（parallel-allocation で 4〜7 倍）でしたが、CPU 時間はほぼ同じでした。
- **p99 の手がかり**: plaintext で musl-sdk はコンテキストスイッチが約 2 倍、`epoll_wait` が半分以下でした。CPU 時間は同じなので、処理の量ではなく、スレッドの起こし方やイベントのまとめ方の違いがレイテンシの分布（p99）に効いている可能性があります。

### 2026-09-29（jemalloc）: Ubuntu 26.04 / AMD EPYC 9V74

[run 36576271295](https://github.com/zunda-pixel/swift-static-linux-benchmark/actions/runs/36576271295)、commit 62f3dae。
[移行前の本番構成を再現する variant](#移行前の本番構成を再現する-variant-glibc-noble-239-jemalloc) を含む 3 variant を、同じ runner で計測しました。
全 variant とも Swift runtime は静的リンクです。

| Variant | 実行時の glibc | allocator |
|---|---|---|
| `glibc-noble-2.39` | 2.39（同梱） | glibc malloc |
| `glibc-noble-2.39-jemalloc` | 2.39（同梱） | jemalloc 5.3.0（Ubuntu `libjemalloc2`） |
| `musl-sdk` | —（static） | mimalloc v2.2.4（SDK 同梱） |

`glibc-noble-2.39-jemalloc`（移行前の本番構成）に対する req/s の差（median）:

| endpoint | variant | c=1 | c=10 | c=25 | c=50 | c=100 |
|---|---|---:|---:|---:|---:|---:|
| plaintext | glibc-noble-2.39 | +0.5% | +0.3% | +0.5% | −0.0% | +0.5% |
| | musl-sdk | +2.8% | +4.9% | +5.2% | +3.9% | +6.2% |
| json | glibc-noble-2.39 | +0.4% | −0.5% | −0.4% | +0.1% | +0.2% |
| | musl-sdk | +1.2% | +4.1% | +2.2% | +1.2% | +1.6% |
| allocation | glibc-noble-2.39 | −9.7% | −10.9% | −11.1% | −11.5% | −12.1% |
| | musl-sdk | −4.7% | −1.9% | −2.1% | −2.1% | −2.0% |
| parallel-allocation | glibc-noble-2.39 | −11.3% | −11.8% | −12.0% | −12.1% | −12.6% |
| | musl-sdk | −4.3% | −4.1% | −3.9% | −4.1% | −4.3% |

rep 間のばらつき（stdev）は、`musl-sdk` の plaintext c≥25（3〜6%）と jemalloc 版の plaintext / json の一部（2〜3%）を除いて 1.5% 未満です。

p99 レイテンシ（ms、median、c=100）と RSS（MB、median、c=100）:

| endpoint | glibc-noble-2.39 | glibc-noble-2.39-jemalloc | musl-sdk |
|---|---:|---:|---:|
| plaintext p99 | 7.81 | 7.85 | 4.00 |
| json p99 | 6.85 | 6.95 | 4.30 |
| allocation p99 | 66.95 | 44.93 | 39.03 |
| parallel-allocation p99 | 275.50 | 221.06 | 220.74 |
| allocation RSS | 28.8 | 30.3 | 43.4 |

読み取れること:

- **jemalloc と glibc malloc**（同じ glibc 2.39・同じビルド）: allocation / parallel-allocation で jemalloc が約 11〜13% 速く、plaintext / json は同等でした。
- **musl-sdk（移行後）と jemalloc（移行前）**: allocation 系は jemalloc が約 2%（parallel-allocation は約 4%）速く、plaintext / json は musl-sdk が 1〜6% 速い結果でした。
  allocation の c=1 だけは差が約 5% と大きくなっています。
- p99 は plaintext / json で musl-sdk が jemalloc 版の約半分〜6 割、allocation 系でも musl-sdk が最も低い結果でした。
- RSS は musl-sdk が約 43 MB で、jemalloc 版（約 30 MB）より約 13 MB 多くなりました。

### 2026-09-29（glibc 切り分け）: Ubuntu 26.04 / Intel Xeon Platinum 8370C

[run 36532052783](https://github.com/zunda-pixel/swift-static-linux-benchmark/actions/runs/36532052783)、commit 10aa2e5。
[glibc のバージョン差を切り分けるための variant](#glibc-のバージョン差を切り分けるための-variant) を含む 4 variant を、同じ runner で計測しました。

| Variant | ビルドイメージ | 実行時の glibc | allocator |
|---|---|---|---|
| `glibc` | 26.04 | 2.43（host） | glibc malloc |
| `glibc-noble` | 24.04 | 2.43（host） | glibc malloc |
| `glibc-noble-2.39` | 24.04 | 2.39（同梱） | glibc malloc |
| `musl-sdk` | 26.04 + Static Linux SDK | —（static） | mimalloc v2.2.4 |

`glibc` に対する req/s の差（median）:

| endpoint | variant | c=1 | c=10 | c=25 | c=50 | c=100 |
|---|---|---:|---:|---:|---:|---:|
| plaintext | glibc-noble | +0.6% | −0.6% | −0.4% | −0.3% | +0.0% |
| | glibc-noble-2.39 | +6.6% | +15.2% | +13.9% | +14.0% | +13.5% |
| | musl-sdk | +11.8% | +25.1% | +21.6% | +16.1% | +21.4% |
| json | glibc-noble | +0.0% | −0.8% | +0.1% | +0.2% | −0.3% |
| | glibc-noble-2.39 | +8.5% | +13.9% | +14.4% | +15.2% | +14.2% |
| | musl-sdk | +15.0% | +24.5% | +23.5% | +22.4% | +22.6% |
| allocation | glibc-noble | +1.8% | −1.0% | −1.2% | −1.1% | −1.0% |
| | glibc-noble-2.39 | −0.1% | −2.3% | −2.8% | −2.9% | −2.6% |
| | musl-sdk | +0.9% | +6.0% | +6.9% | +7.0% | +7.3% |
| parallel-allocation | glibc-noble | −0.6% | −0.4% | −0.7% | −0.7% | −0.1% |
| | glibc-noble-2.39 | −2.9% | −3.0% | −3.0% | −3.2% | −3.0% |
| | musl-sdk | +7.0% | +5.8% | +5.9% | +5.9% | +6.8% |

rep 間のばらつき（stdev）は、`musl-sdk` の plaintext c≥25（3〜5%）を除いて 2% 未満です。

読み取れること:

- **ビルドイメージの差（`glibc` と `glibc-noble`）はありません**でした（±2% 以内）。
- **glibc のバージョン差（`glibc-noble` と `glibc-noble-2.39`）は、endpoint によって向きが逆**でした。
  - plaintext / json: glibc 2.39 のほうが c≥10 で約 13〜16% 高い（c=1 では約 6〜8%）。allocation をほとんどしない処理で差が出ているので、malloc 以外の glibc の部分（システムコールのラッパー、文字列・メモリ操作、スレッド関連など）の差と考えられますが、どこかはこの計測では特定できていません。
  - allocation / parallel-allocation: 逆に glibc 2.43 のほうが約 2〜3% 高い。
- **musl-sdk は glibc 2.39 と比べても**、plaintext / json で 2〜9%、allocation / parallel-allocation で約 9〜10%（allocation の c=1 のみ 1%）高いスループットでした。
  つまり allocation 系での musl 系の優位は glibc のバージョンでは説明できず、glibc malloc と mimalloc の差（と CPU との相性）によるものと考えられます。
- p99 は musl-sdk が最も低く、glibc 系 3 つの間では大きな差はありませんでした。

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

### 回をまたいだ比較

09-28（EPYC 9V45）から 09-29（EPYC 7763）で、スループットの絶対値は全体に下がりましたが、下がり方が variant によって違います（c=100 の req/s）。

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

この 2 回は CPU と glibc（2.39 → 2.43）が同時に変わっていましたが、glibc 切り分けの計測では glibc 2.39 → 2.43 で allocation 系はほぼ変わらず（±3% 以内）、ビルドイメージの影響もありませんでした。
したがって allocation 系で glibc 版が相対的に下がったのは、glibc のバージョンではなく CPU の違いによるものと考えられます。
glibc malloc と mimalloc の相対的な速さは CPU によって変わり、今回の 3 種類では EPYC 9V45 でほぼ同等、Xeon 8370C で mimalloc が約 7%、EPYC 7763 で約 15% 速い結果でした。
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
  GitHub の x64 runner は物理 2 コア × SMT 2 スレッドで、vCPU 0 と 1 が同じ物理コアのスレッドなので、実際には物理コアを 1 つずつ分けています。
  ARM64 runner（Neoverse-N2）は SMT のない 4 コアです。
- 各 variant をホスト上で直接起動し（コンテナは使わない）、endpoint ごとに warmup 10 秒 → concurrency `1 10 25 50 100` をそれぞれ 30 秒計測。
- 5 rep 実行し、**median** を代表値にします（min / max / stdev も `summary.json` に保存）。
- 計測中は `/proc/<pid>` からサーバーの CPU% と RSS をサンプリングし、peak RSS は計測ごとにリセットして取ります。

デフォルト設定での所要時間は約 2.7 時間です（5 rep × 3 variant × 4 endpoint × (10 + 5 × 30) 秒）。

## 実行

### GitHub Actions

- `pull_request` / `push`（main）: ビルド・検証と、短時間（1 rep、3 秒、concurrency `1 50`）の疎通確認のみ。
- `workflow_dispatch`: フル計測。variant・endpoint・concurrency・rep 数・時間を入力で変更できます。加えて次の入力があります。
  - `runner`: `ubuntu-26.04`（x64）または `ubuntu-26.04-arm`（ARM64）。どちらも 4 vCPU です。
  - `cpu_configs`: サーバーと oha の CPU 割り当てを `server:client` の形で並べると、同じ job の中で順番に計測します
    （例: `0:1-3 0-1:2-3 0-2:3` でサーバー 1 / 2 / 3 コア）。結果は `results/cpus-<server>/` に分かれます。
    コア数を増やしたときに allocator の lock contention でスループットが伸びなくなるかを見るためのものです。
  - `mode`: `benchmark`（oha による計測）または `profile`（後述の `perf` による調査）。

### perf による調査（`mode: profile`）

[`scripts/profile.sh`](scripts/profile.sh) は、variant と endpoint ごとに一定の負荷（c=50）をかけながら `perf` で次を取ります。

- `perf stat`: CPU 時間、命令数（VM で使える場合）、コンテキストスイッチ、wakeup、futex・epoll_wait・read/write・mmap 系のシステムコール回数。
  oha が同じ時間内に処理したリクエスト数で割り、1 リクエストあたりの値にします。
- `perf record`: フラットな CPU プロファイル（共有ライブラリ別・関数別）。Swift のシンボルは `swift demangle` で読める形にします。
- `perf record --call-graph dwarf`（`futex` と `sched_switch`）: futex を呼んでいる箇所と、スレッドが止まる箇所の呼び出し元（`callers.txt`、Job Summary には出しません）。

結果は Job Summary と `results/profile/` に出ます（[`scripts/summarize_profile.py`](scripts/summarize_profile.py)）。
musl 版は libc も含めて 1 つのバイナリなので、共有ライブラリ別の内訳では libc が分かれず、関数別の内訳で見ます。

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

Docker（buildx）が必要です。バイナリは linux/amd64 向けにビルドされます（`PLATFORM=linux/arm64 scripts/build.sh` で ARM64）。

```sh
scripts/build.sh                       # bin/{glibc,musl-sdk,musl-mimalloc-v3}/ を生成
# 以下はビルドしたアーキテクチャの Linux 上で実行
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

- musl 本来の allocator（mallocng）との比較（`musl-mallocng` variant）
- musl 版の memcpy の影響の確認（`musl-sdk-fastmemcpy` variant）
- p99 の差の原因の調査（`futex` / `sched_switch` の呼び出し元を `perf` で記録し、SwiftNIO のイベントループの挙動と合わせて調べる）
- glibc 2.43 の malloc で futex が増えた理由の調査（同上）
- 4 vCPU を超える環境（self-hosted runner など）での計測。GitHub の標準 runner は x64 / ARM64 とも 4 vCPU で、larger runners は個人アカウントでは使えない
- Intel Xeon 8370C で glibc 2.43 の plaintext / json が遅くなった理由の調査。runner の CPU は選べないため、同じ CPU に当たったときに profile を取る
