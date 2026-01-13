# macOSネットワーク帯域制限ガイド

## 1. 概要・目的

このドキュメントは、macOS上でネットワーク帯域制限や遅延をエミュレートするための実践的なガイドです。研究環境において、低速ネットワークや不安定な通信状態を再現し、アプリケーションの動作を検証するために使用します。

**主な用途:**
- 農業現場やビニールハウスなど、電波が不安定な環境のシミュレーション
- 低帯域環境でのWebアプリケーション（点群データビューアなど）の動作検証
- パケットロスや遅延がシステムに与える影響の評価

---

## 2. 基礎知識

### 2.1 ツールの説明

#### dnctl (Dummy Net Control)

**役割:** macOS（およびFreeBSD）に搭載されている「トラフィック・シェイパー（通信整形器）」を操作するツールです。

**イメージ:** インターネットという水の流れに対して、「蛇口の締め具合」や「管の長さ（遅延）」を管理するコントローラーです。これ自体は「どのデータを絞るか」は決めず、あくまで「絞り方（ルール）」を定義します。

```bash
# 基本コマンド
dnctl pipe list          # 現在の設定を表示
dnctl -q flush          # 全ての設定をクリア
```

#### pfctl (Packet Filter Control)

**役割:** パケットフィルタリング（通信の選別）を行うツールです。どの通信を許可・遮断するか、どの通信をdnctlのパイプに流すかを制御します。

**イメージ:** 「入館ゲート」のような存在で、通信パケットがシステムを通過する際の交通整理を担当します。

```bash
# 基本コマンド
sudo pfctl -E           # パケットフィルターを有効化
sudo pfctl -d           # パケットフィルターを無効化
sudo pfctl -s rules     # 現在のルールを表示
```

#### Network Link Conditioner (GUI)

あなたがマウスでポチポチ操作する画面ツールです。中身は `dnctl` と `pfctl` を裏で自動実行しているだけです。本ガイドでは、より細かい制御が可能なコマンドラインツールを使用します。

### 2.2 主要パラメータ一覧

| パラメータ | 意味 | 単位 | 研究での使い所 |
|:----------|:-----|:-----|:--------------|
| `bw` | 帯域幅 | Mbit/s, Kbit/s | スループット制限（基本） |
| `delay` | 遅延 | ms | 物理的な距離や中継による遅れ |
| `plr` | パケットロス率 | 0.0〜1.0 | 不安定な無線環境の再現 |
| `queue` | キュー容量 | slots / KB | 大量リクエスト時の耐性テスト |

---

## 3. 仕組みの詳細

### 3.1 アンカー（Anchor）の概念

macOSの通信制御システムである PF (Packet Filter) は、役割ごとに「棚（アンカー）」の種類を分けて管理します。

#### 役割の決定的な違い

| 項目 | dummynet-anchor | anchor |
|:-----|:---------------|:-------|
| **役割** | 通信の「加工」 | 通信の「選別」 |
| **中身** | 帯域制限、遅延、パケットロスなどのルール | 通信を許可(pass)、遮断(block)などのルール |
| **命令語** | `dummynet in/out pipe X` | `pass`, `block`, `nat`, `rdr` など |
| **イメージ** | 「加工ライン」の指示書 | 「入館ゲート」の指示書 |

#### なぜ両方書く必要があるのか？

PFシステムは、通信パケットが届いたときに以下の2段階でチェックを行います：

1. **第1段階:** このパケットの「スピード」はどうする？
   - `dummynet-anchor` の中身を見に行く
   - 「1番パイプ（10Mbps）に通せ」と書いてあれば、パケットを土管に送る

2. **第2段階:** このパケット自体を「通して」いいのか？
   - `anchor` の中身を見に行く
   - 「この通信は許可（pass）」と書いてあれば、そのまま目的地へ流す

もし片方しか書かないと、システムは「スピードのルールはわかったけど、そもそもこれを通すべきかどうかの棚が定義されていないぞ？」と混乱してしまい、正しく動作しません。

#### 同じ名前を使う理由

```bash
dummynet-anchor "my_limit"
anchor "my_limit"
```

両方に同じ名前（例: `my_limit`）をつけているのは、「この実験用セットアップに関するルールは、スピードも許可設定もこの名前のグループでまとめて管理する」という整理整頓のためです。

OS内部では、同じ名前でも「スピード用の my_limit」と「許可・遮断用の my_limit」として別々の領域に保存されています。

### 3.2 シェルスクリプトの構文解説

シェルスクリプト独特の書き方は、初めて見ると「暗号」のように見えますが、これらは「複数の行をひとまとめにして、次のコマンドに一気に放り込む」ためのテクニックです。

#### cat とは何？

**Catenate（連結する）の略です。**

- **本来の役割:** ファイルの中身を表示したり、複数のファイルを繋げたりするコマンド
- **このスクリプトでの役割:** ヒアドキュメントと組み合わせることで、「ファイルを作らずに、その場で書いた文章をテキストデータとして出力する」

#### ヒアドキュメント（<<EOF）

**「ヒアドキュメント」と呼ばれる機能です。**

- **意味:** 「次に EOF という文字が出てくるまで、書かれた内容を全部データとして扱え」という命令
- **EOF:** End Of File の略で、単なる「しるし」。実は `EOF` という名前である必要はなく、`STOP` でも `APPLE` でも、最初と最後が一致していれば何でも動きます（慣習的に `EOF` が使われます）

#### サブシェル（カッコ）

```bash
(cat <<EOF
  dummynet-anchor "my_limit"
  anchor "my_limit"
EOF
) | sudo pfctl -f -
```

**役割:** カッコの中にある複数の命令を「一つのグループ（一つの出力）」としてまとめます。

**なぜ必要か:** カッコでまとめないと、パイプ（`|`）がどの部分を pfctl に渡せばいいのか混乱してしまうため、一つの「箱」に入れています。

**パイプの意味:**
- `| sudo pfctl -f -`: パイプを使って、上の内容を pfctl に読み込ませる
- `-f -`: 「標準入力から設定ファイルを読み込む」という意味
- `2>/dev/null`: macOS特有の「ALTQがありません」といった不要な警告メッセージを非表示にする

### 3.3 ルール設定の構文

#### 基本構文

```bash
#    [予約語]  [方向] [対象] [予約語] [ID]
echo "dummynet   in    all    pipe     1"
```

各要素の意味：
- **dummynet:** これは帯域制限ルールですよ、という宣言
- **in/out:** `in` = 入ってくる通信（ダウンロード）、`out` = 出ていく通信（アップロード）
- **all:** 全ての通信が対象（後述の表を参照）
- **pipe:** パイプ（土管）を指定する予約語
- **1:** パイプのID番号

#### なぜ "all" が必要なのか？

もし `all` を書かずに `dummynet in pipe 1` と書くと、PF は「in（入ってくる通信）なのはわかったけど、具体的にどのパケット？ TCP だけ？ それとも特定のサイト宛だけ？」と迷ってしまい、`Syntax error` を出して何も設定してくれません。

#### "all" 以外の指定方法

研究が進んで、「点群データのサーバー（TCP）だけ制限して、Zoom（UDP）は快適にしたい」といった場合に、`all` を書き換えることで対象を絞り込めます。

| 書き方 | 意味 | 使い道 |
|:------|:-----|:------|
| `all` | 全部 | 基本（今の実験はこれでOK） |
| `proto tcp` | TCP 通信だけ | Web ブラウザの通信だけを狙い撃ちする |
| `to 1.2.3.4` | 特定の IP 宛だけ | 特定のサーバーとの通信だけを遅くする |
| `port 80` | 80番ポートだけ | 暗号化されていない HTTP 通信だけを制限する |

---

## 4. 実装例

### 4.1 original_network.sh の解説

以下は、`original_network.sh` の実装を段階的に解説します。

#### ステップ0: 設定の初期化

```bash
# 既存のルールをリセットする
echo "y" | sudo dnctl -q flush
sudo pfctl -d 2>/dev/null || true
```

**説明:**
- 以前の設定が残っていると混乱するため、まずクリーンな状態にします
- `echo "y"` で確認プロンプトに自動応答
- `|| true` でエラーが出ても続行

#### ステップ1: アンカーの作成

```bash
DUMMYNET_ANCHOR="test-network-limit"

sudo pfctl -f - <<EOF
$(cat /etc/pf.conf)
dummynet-anchor "$DUMMYNET_ANCHOR"
anchor "$DUMMYNET_ANCHOR"
EOF
```

**説明:**
- Mac全体の元々の通信ルール（`/etc/pf.conf`）を保持しつつ、自分専用の「砂場（my_limit）」を作成
- これで安全に実験できます

#### ステップ2: パイプの定義

```bash
# ダウンリンク（下り）の設定
DOWN_PIPE_ID="1"
DOWN_BANDWIDTH="100Mbit/s"
DOWN_PACKETS_DROPPED="0.0"
DOWN_DELAY="0ms"

sudo dnctl pipe "$DOWN_PIPE_ID" config \
    bw "$DOWN_BANDWIDTH" \
    plr "$DOWN_PACKETS_DROPPED" \
    delay "$DOWN_DELAY"

# アップリンク（上り）の設定
UP_PIPE_ID="2"
UP_BANDWIDTH="100Mbit/s"
UP_PACKETS_DROPPED="0.0"
UP_DELAY="0ms"

sudo dnctl pipe "$UP_PIPE_ID" config \
    bw "$UP_BANDWIDTH" \
    plr "$UP_PACKETS_DROPPED" \
    delay "$UP_DELAY"
```

**説明:**
- パイプ1: ダウンロード（in）用の土管
- パイプ2: アップロード（out）用の土管
- それぞれに帯域幅、パケットロス率、遅延を設定

#### ステップ3: 配管の接続

```bash
PROTOCOL="tcp"
echo "dummynet out quick proto $PROTOCOL from any to any pipe $UP_PIPE_ID" | \
    sudo pfctl -a "$DUMMYNET_ANCHOR" -f -
echo "dummynet in quick proto $PROTOCOL from any to any pipe $DOWN_PIPE_ID" | \
    sudo pfctl -a "$DUMMYNET_ANCHOR" -f -
```

**説明:**
- `-a "$DUMMYNET_ANCHOR"`: 先ほど作った専用の棚に格納
- `quick`: 最初にマッチしたルールで即座に処理（以降のルールを無視）
- `from any to any`: 送信元・宛先を問わず全ての通信

#### ステップ4: ネットワーク設定を有効化

```bash
sudo pfctl -E
```

**説明:**
- これでOS上の全てのアプリ、サービスがこの制約を受けます
- 設定を無効化するには `sudo pfctl -d`

### 4.2 設定変更の方法

実験中に設定を変更する場合：

| 操作 | コマンド | 備考 |
|:-----|:--------|:-----|
| 速度を変えたい | `sudo dnctl pipe 1 config bw [速度]Mbit/s` | pfctl はそのままでOK |
| 遅延を消したい | `sudo dnctl pipe 1 config delay 0ms` | 瞬時に反映されます |
| 完全に解除したい | `sudo pfctl -d` | これで元の高速通信に戻ります |

---

## 5. テスト・検証方法

### 5.1 測定ツールの使い方

#### iperf3（推奨）

**インストール:**
```bash
brew install iperf3
```

**使い方:**
```bash
# 1. サーバーモードで起動（別ターミナルで実行）
iperf3 -s

# 2. 上り（Uplink）のテスト
iperf3 -c localhost -t 5

# 3. 下り（Downlink）のテスト
iperf3 -c localhost -t 5 -R
```

**オプション:**
- `-c`: 接続先サーバー
- `-t`: 秒数
- `-R`: サーバーから送信（下り）

#### speedtest-cli

**インストール:**
```bash
brew install speedtest-cli
```

**使い方:**
```bash
speedtest
```

実際のインターネット経由で測定するため、設定が正しく機能しているか確認できます。

#### networkQuality（macOS標準）

```bash
networkQuality -s
```

macOS Monterey以降で利用可能な標準ツールです。

#### fast.com（Webベース）

ブラウザで https://fast.com にアクセスするだけで測定できます。

### 5.2 測定結果の読み方

#### 理論値と実効速度の違い

「10Mbpsに設定したのに、なぜ結果が8.378 Mbpsになるのか」という疑問について：

**これは実は、設定が正しく効いている証拠です。**

10Mbps（理論値）でセットしても、実際にデータが流れる際には「オーバーヘッド（通信の梱包材）」が必要だからです。

- **データの梱包:** 100のデータを送るには、送り先やエラーチェックなどの「ヘッダー情報」が付加されます
- **実効速度:** ネットワークの理論値が10Mbpsの場合、実際に私たちが使える有効な速度（スループット）は、その **80%〜90%程度** になるのが一般的です

$$10 \text{ Mbps} \times 0.85 (\text{効率}) \approx 8.5 \text{ Mbps}$$

**結論:** Downlinkに関しては、設定した10Mbpsの土管（パイプ）をパケットがパンパンに詰まって通っている状態と言えます。

---

## 6. 高度な活用

### 6.1 追加パラメータの活用

#### パケットロス率 (plr: Packet Loss Rate)

データのパケットを意図的に「捨てる」確率を設定します。

```bash
sudo dnctl pipe 1 config bw 10Mbit/s plr 0.05
```

**設定方法:** `plr 0.05`（5%の確率でパケットを捨てる）

**研究への影響:**
- 農業現場やビニールハウスの端など、電波が不安定な場所ではパケットロスが頻繁に起きます
- 点群データのバイナリが一部欠落した際、システムがフリーズせずに再送を待てるか？
- 描画が「穴あき」にならないか？ といった **「堅牢性（ロバストネス）」** の評価に必須

#### キューサイズ (queue / slots)

土管の中にどれだけのデータを溜めておけるか（待ち行列の長さ）を設定します。

```bash
sudo dnctl pipe 1 config bw 10Mbit/s queue 100
```

**設定方法:** `queue 50`（デフォルト）や `queue 100`
**制約:** macOSでは 2 <= queue size <= 100

**研究への影響:**
- **小さすぎると:** すぐにデータがあふれてパケットロスが発生し、通信が不安定になります
- **大きすぎると:** 「バッファブロート（Bufferbloat）」が発生します。データは届くものの、行列が長すぎて「ものすごく遅延（Delay）が増えた」ように感じます
- 巨大な点群を「一気に」リクエストした際に、ブラウザの通信が破綻するかどうかを調べるのに使います

### 6.2 今後の検証項目

#### ステップ1: シングル vs マルチストリームの飽和攻撃

```bash
# シングルストリーム（TCP 1本）
iperf3 -c localhost -t 5

# マルチストリーム（TCP 10本並列）
iperf3 -c localhost -t 5 -P 10
```

**分析:** 100Mbps設定時、1本だと40Mbpsに落ちるのか、10本なら98Mbps出るのか。これにより、「3Dアプリが、通信をどれだけ並列化（HTTP/2等の多重化）すべきか」の理論的根拠が得られます。

#### ステップ2: UDPによる「パケット損失」の可視化

WebGPUを用いた可視化では、将来的に WebTransport (UDP) を使う可能性もあります。

```bash
# UDPで 100Mbps を流し込み、ロス率を測る
iperf3 -c localhost -u -b 100M -t 5
```

**分析:** TCPはロスを自動で隠蔽（再送）しますが、UDPは生のロスを表示します。dnctl の plr（パケットロス率）設定が、アプリのレンダリングにどう直結するかを分離して評価できます。

#### ステップ3: レイテンシとスループットの相関（BDP検証）

`delay` を 0ms, 50ms, 150ms と変えて、iperf3 のスループットがどう反比例するかをプロットします。

### 6.3 OSI参照モデルとの対応

実験環境として、以下のレイヤーでの制約を考慮する必要があります：

| レイヤー | 内容 | 本ツールでの制御 |
|:--------|:-----|:----------------|
| **L7（アプリケーション層）** | HTTP/HTTPS、DNS、SMTP、SSH など | △（プロトコル指定で間接的） |
| **L6（プレゼンテーション層）** | TLS/SSL、JSON/XML、UTF-8、gzip など | - |
| **L5（セッション層）** | セッション管理（RPC、NetBIOS等） | - |
| **L4（トランスポート層）** | TCP、UDP、QUIC | ○（proto tcp/udp で制御） |
| **L3（ネットワーク層）** | IP（IPv4/IPv6）、ICMP、ルーティング | ○（bw, delay, plr で制御） |
| **L2（データリンク層）** | Ethernet、Wi-Fi、ARP、VLAN | △（物理層に近い制御は困難） |
| **L1（物理層）** | 電気/光/電波（UTP、光ファイバー、無線） | - |

**今後の方向性:** L4〜L7までを実験環境として用意し、トランスポート層においてもUDP（HTTP/3/QUIC）での評価を行う予定。

**代替手段:** Linuxでは `tc + netem` を使うことで、より低レイヤーの制御が可能です。

---

## 7. トラブルシューティング

### 7.1 設定の完全リセット方法

```bash
# 方法1: dnctlとpfctlを両方リセット
sudo dnctl -q flush
sudo pfctl -d

# 方法2: バックアップから復元
sudo cp /etc/pf.conf.bak /etc/pf.conf
sudo dnctl -q flush
sudo pfctl -f /etc/pf.conf
```

### 7.2 現在の設定を確認

```bash
# dnctlのパイプ設定を確認
sudo dnctl pipe list

# pfctlのルールを確認
sudo pfctl -s rules

# pfctlのアンカーを確認
sudo pfctl -s Anchors
```

### 7.3 よくある問題と対処法

| 問題 | 原因 | 対処法 |
|:-----|:-----|:------|
| 設定したのに速度が変わらない | pfctl が無効化されている | `sudo pfctl -E` で有効化 |
| エラーが大量に出る | 既存の設定と競合 | `sudo pfctl -d` でリセット後、再設定 |
| 設定が残り続ける | OS再起動後も残る場合がある | 上記の完全リセット方法を実行 |

---

## 8. 参考資料

### 8.1 公式ドキュメント・学術論文

- [ネットワークエミュレーションツール「dummynet」- 明石邦夫](https://www.jstage.jst.go.jp/article/itej/64/10/64_1473/_pdf)

### 8.2 技術ブログ・解説記事

- [Macで自由にパケットのフィルタリング、帯域制限、パケロス率の設定をする](https://spring-mt.hatenablog.com/entry/2022/09/22/234405)
- [pfctlコマンドの使い方](https://scrapbox.io/rantarn0326-93726445/pfctl%E3%82%B3%E3%83%9E%E3%83%B3%E3%83%89%E3%81%AE%E4%BD%BF%E3%81%84%E6%96%B9)

### 8.3 GitHub Gist・サンプルコード

- [Simulating Different Network Conditions - HeadSpin Blog](https://www.headspin.io/blog/simulating-different-network-conditions-for-virtual-devices)
- [Network Link Conditioner Script Examples](https://gist.github.com/mefellows/4f6ecd2e83de8b591726)

---

## 付録: クイックリファレンス

### よく使うコマンド一覧

```bash
# 設定の開始
./original_network.sh

# 現在の設定確認
sudo dnctl pipe list

# 設定の停止
sudo pfctl -d

# 完全リセット
sudo dnctl -q flush && sudo pfctl -f /etc/pf.conf

# 測定（iperf3の場合）
iperf3 -s                    # サーバー起動
iperf3 -c localhost -t 5     # Uplink測定
iperf3 -c localhost -t 5 -R  # Downlink測定
```

### 設定例テンプレート

```bash
# 低速回線（4G LTE 程度）
sudo dnctl pipe 1 config bw 50Mbit/s delay 50ms plr 0.01

# 超低速回線（3G 程度）
sudo dnctl pipe 1 config bw 5Mbit/s delay 150ms plr 0.05

# 不安定な回線（農業現場想定）
sudo dnctl pipe 1 config bw 10Mbit/s delay 80ms plr 0.10 queue 30
```

---

**最終更新:** 2026-01-13
