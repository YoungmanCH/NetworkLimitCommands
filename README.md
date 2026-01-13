# NetworkLimitCommands

macOS用のネットワーク帯域制限ツール（dnctl + pfctl）

## 概要

このプロジェクトは、macOSの`dnctl`（dummynet）と`pfctl`（Packet Filter）を使用して、ネットワーク帯域を制限する仮想ネットワーク環境を構築します。

**参考記事**: [Bandwidth Throttling on Mac](https://blog.leiy.me/post/bw-throttling-on-mac/)

## ファイル構成

- **rules.txt** - トラフィック制御ルール（dummynetパイプへの振り分け）
- **network.sh** - ネットワーク制限を有効化するスクリプト
- **test_network.sh** - 現在の設定状態を確認するスクリプト
- **cleanup.sh** - ネットワーク制限を解除するスクリプト

## 仕組み

1. **/etc/pf.conf** にアンカー（ルールのグループ）を定義（初回のみ）
2. **dnctl** で帯域制限を行うパイプを作成
3. **rules.txt** でトラフィックをパイプに振り分けるルールを定義
4. **pfctl** でルールをロードし、パケットフィルタを有効化

## セットアップ

### 初回のみ: /etc/pf.confの編集

ネットワーク制限を使用する前に、システムの`/etc/pf.conf`にアンカーを追加する必要があります。

1. `/etc/pf.conf`をバックアップ:
```bash
sudo cp /etc/pf.conf /etc/pf.conf.backup
```

2. `/etc/pf.conf`を編集（適切な位置にアンカーを追加）:
```bash
sudo nano /etc/pf.conf
```

3. 以下の2行を、**Apple filtering anchorsの前**に追加:
```
dummynet-anchor "test_limit"
anchor "test_limit"
```

完成形は以下のようになります:
```
#
# Default PF configuration for macOS.
#

# Normalization
scrub-anchor "com.apple/*"

# Translation
nat-anchor "com.apple/*"
rdr-anchor "com.apple/*"

# Filtering (Custom rules before Apple defaults)
dummynet-anchor "test_limit"
anchor "test_limit"

# Apple filtering anchors
dummynet-anchor "com.apple/*"
anchor "com.apple/*"
load anchor "com.apple" from "/etc/pf.anchors/com.apple"
```

4. 設定を確認:
```bash
sudo pfctl -f /etc/pf.conf -n
```

エラーが出なければ成功です。

## 使い方

### 1. ネットワーク制限を有効化

```bash
./network.sh
```

デフォルト設定:
- ダウンロード（inbound）: 10Mbps、遅延0ms、パケットロス0%
- アップロード（outbound）: 10Mbps、遅延0ms

### 2. 設定状態を確認

```bash
./test_network.sh
```

または個別に確認:

```bash
# dummynetパイプの状態を確認
sudo dnctl pipe list

# パケットフィルタのdummynetルールを確認
sudo pfctl -a test_limit -s dummynet

# PFの全体状態を確認
sudo pfctl -s info
```

### 3. ネットワーク速度をテスト

```bash
# macOS標準のネットワーク品質テスト
networkQuality

# アップロード/ダウンロードを個別に確認
networkQuality -s

# curlでダウンロード速度テスト
curl -o /dev/null https://speed.cloudflare.com/__down?bytes=10000000
```

### 4. ネットワーク制限を解除

```bash
./cleanup.sh
```

または手動で:

```bash
sudo pfctl -a test_limit -F all
sudo dnctl -q flush
sudo pfctl -d
```

## カスタマイズ

### 帯域幅を変更

`network.sh`の以下の行を編集:

```bash
sudo dnctl pipe 1 config bw 10Mbit/s delay 0ms plr 0.0  # ダウンロード
sudo dnctl pipe 2 config bw 10Mbit/s delay 0ms          # アップロード
```

例:
- `bw 1Mbit/s` - 1Mbps
- `bw 100Kbit/s` - 100Kbps
- `delay 100ms` - 100ms遅延を追加
- `plr 0.01` - 1%のパケットロス

### 特定のポートのみ制限

`rules.txt`を編集:

```bash
# ポート8080のみ制限
dummynet out proto tcp from any to any port 8080 pipe 1
dummynet in proto tcp from any port 8080 to any pipe 2
```

## 注意事項

- このツールはシステム全体のネットワークに影響します
- sudo権限が必要です
- 設定後は必ず`./cleanup.sh`で解除してください
- "No ALTQ support in kernel"の警告は無視して問題ありません（macOSの仕様）

## トラブルシューティング

### 設定が反映されない場合

```bash
# 既存の設定をクリーンアップ
./cleanup.sh

# 再度設定を適用
./network.sh
```

### PFが有効にならない場合

```bash
# PFを手動で有効化
sudo pfctl -E

# 状態確認
sudo pfctl -s info
```

## ライセンス

MIT


