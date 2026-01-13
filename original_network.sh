#!/bin/bash

# 0. 設定の初期化 ---

# 既存のルールをリセットする
echo "y" | sudo dnctl -q flush
sudo pfctl -d 2>/dev/null || true


# 1. ネットワークルールの定義—

# 予約語:            dummynet-anchor, anchor
# dummynet-anchor:  帯域制限、遅延、パケットロスなどのルール。
# anchor:           通信を許可する(pass)、遮断する(block)などのルール。
DUMMYNET_ANCHOR="test-network-limit"

sudo pfctl -f - <<EOF
$(cat /etc/pf.conf)
dummynet-anchor "$DUMMYNET_ANCHOR"
anchor "$DUMMYNET_ANCHOR"
EOF


# 2. ネットワークのパイプを定義

# pipe id（ID表記）
# bandwidth（スループット）: Mbps / Kbps, 
# Delay（レイテンシー）: 遅延 ms, 
# plr（Packet Loss Rate）: データの損失率 (0.0~1.0)
# queue（キューの設定）: デフォルト値 50 (MacOS制約 2 <= queue size <= 100)

DOWN_PIPE_ID="1"
DOWN_BANDWIDTH="100Mbit/s"
DOWN_PACKETS_DROPPED="0.0"
DOWN_DELAY="0ms"
# DOWN_QUEUE="100"

UP_PIPE_ID="2"
UP_BANDWIDTH="100Mbit/s"
UP_PACKETS_DROPPED="0.0"
UP_DELAY="0ms"
# UP_QUEUE="100"

sudo dnctl pipe "$DOWN_PIPE_ID" config \
    bw "$DOWN_BANDWIDTH" \
    plr "$DOWN_PACKETS_DROPPED" \
    delay "$DOWN_DELAY"

sudo dnctl pipe "$UP_PIPE_ID" config \
    bw "$UP_BANDWIDTH" \
    plr "$UP_PACKETS_DROPPED" \
    delay "$UP_DELAY"


# 3. ネットワークのパイプの配管整備
# [予約語] [方向] [対象(プロトコル / IP / PORT)] [予約語] [ID]
PROTOCOL="tcp"
echo "dummynet in quick proto $PROTOCOL from any to any pipe $DOWN_PIPE_ID" | sudo pfctl -a "$DUMMYNET_ANCHOR" -f -
echo "dummynet out quick proto $PROTOCOL from any to any pipe $UP_PIPE_ID" | sudo pfctl -a "$DUMMYNET_ANCHOR" -f -


# 4. ネットワーク設定ON（OS上の全てのアプリ、サービスがこの制約を受ける）
sudo pfctl -E


echo "--------------------------------------------------"
echo "状態確認: sudo dnctl pipe list"
echo "停止: sudo pfctl -d"
echo "完全にリセット: sudo dnctl -q flush && sudo pfctl -f /etc/pf.conf"
echo "--------------------------------------------------"


echo "<-------------------計測方法----------------------->"

echo "1. iperf でネットワーク測定する"
echo "iperfのインストール: brew install iperf3"
echo "セットアップ / 起動: iperf3 -s"

echo "Uplinkの計測: iperf3 -c localhost -t 5"
echo "Downlinkの計測: iperf3 -c localhost -t 5 -R"


echo "2. speedtest でネットワーク測定する"
echo "brew install speedtest-cli"

echo "Uplink / Downlink の計測: speedtest"


echo "3. fast.com でネットワーク測定する"
echo "Uplink / Downlink の計測: fast.comにアクセス"


echo "4. networkQuality でネットワーク測定する"
echo "Uplink / Downlink の計測: networkQuality -s"

echo "--------------------------------------------------"
