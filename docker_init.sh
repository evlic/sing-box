#!/usr/bin/env bash

# 脚本更新日期 2024.10.28
WORK_DIR=/sing-box
PORT=$START_PORT
SUBSCRIBE_TEMPLATE="https://raw.githubusercontent.com/fscarmen/client_template/main"

# 自定义字体彩色，read 函数
warning() { echo -e "\033[31m\033[01m$*\033[0m"; }  # 红色
info() { echo -e "\033[32m\033[01m$*\033[0m"; }   # 绿色
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }   # 黄色

# 判断系统架构，以下载相应的应用
check_arch() {
  case "$ARCH" in
    arm64 )
      SING_BOX_ARCH=arm64; JQ_ARCH=arm64; QRENCODE_ARCH=arm64; ARGO_ARCH=arm64
      ;;
    amd64 )
      SING_BOX_ARCH=amd64
      JQ_ARCH=amd64; QRENCODE_ARCH=amd64; ARGO_ARCH=amd64
      ;;
    armv7 )
      SING_BOX_ARCH=armv7; JQ_ARCH=armhf; QRENCODE_ARCH=arm; ARGO_ARCH=arm
      ;;
  esac
}

# 检查 sing-box 最新版本
check_latest_sing-box() {
  local VERSION_LATEST=$(wget -qO- "https://api.github.com/repos/SagerNet/sing-box/releases" | awk -F '["v-]' '/tag_name/{print $5}' | sort -r | sed -n '1p')
  wget -qO- "https://api.github.com/repos/SagerNet/sing-box/releases" | awk -F '["v]' -v var="tag_name.*$VERSION_LATEST" '$0 ~ var {print $5; exit}'
}

# 安装 sing-box 容器
install() {
  # 下载 sing-box
  echo "正在下载 sing-box ..."
  #####local ONLINE=$(check_latest_sing-box)
  local ONLINE='1.11.0-alpha.6'
  wget https://github.com/SagerNet/sing-box/releases/download/v$ONLINE/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz -O- | tar xz -C $WORK_DIR sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box && mv $WORK_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box $WORK_DIR/sing-box && rm -rf $WORK_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH

  # 下载 jq
  echo "正在下载 jq ..."
  wget -O $WORK_DIR/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$JQ_ARCH && chmod +x $WORK_DIR/jq

  # 下载 qrencode
  echo "正在下载 qrencode ..."
  wget -O $WORK_DIR/qrencode https://github.com/fscarmen/client_template/raw/main/qrencode-go/qrencode-go-linux-$QRENCODE_ARCH && chmod +x $WORK_DIR/qrencode

  # 下载 cloudflared
  echo "正在下载 cloudflared ..."
  wget -O $WORK_DIR/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARGO_ARCH && chmod +x $WORK_DIR/cloudflared

  # 生成 sing-box 配置文件
  if [[ "$SERVER_IP" =~ : ]]; then
    local WARP_ENDPOINT=2606:4700:d0::a29f:c101
    local DOMAIN_STRATEG=prefer_ipv6
  else
    local WARP_ENDPOINT=162.159.193.10
    local DOMAIN_STRATEG=prefer_ipv4
  fi

  local REALITY_KEYPAIR=$($WORK_DIR/sing-box generate reality-keypair) && REALITY_PRIVATE=$(awk '/PrivateKey/{print $NF}' <<< "$REALITY_KEYPAIR") && REALITY_PUBLIC=$(awk '/PublicKey/{print $NF}' <<< "$REALITY_KEYPAIR")
  local SHADOWTLS_PASSWORD=$($WORK_DIR/sing-box generate rand --base64 16)
  local UUID=${UUID:-"$($WORK_DIR/sing-box generate uuid)"}
  local NODE_NAME=${NODE_NAME:-"sing-box"}
  local CDN=${CDN:-"skk.moe"}

  # 检测是否解锁 chatGPT
  local SUPPORT_COUNTRY='AD AE AF AG AL AM AO AR AT AU AZ BA BB BD BE BF BG BH BI BJ BN BO BR BS BT BW BZ CA CD CF CG CH CI CL CM CO CR CV CY CZ DE DJ DK DM DO DZ EC EE EG ER ES ET FI FJ FM FR GA GB GD GE GH GM GN GQ GR GT GW GY HN HR HT HU ID IE IL IN IQ IS IT JM JO JP KE KG KH KI KM KN KR KW KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MG MH MK ML MM MN MR MT MU MV MW MX MY MZ NA NE NG NI NL NO NP NR NZ OM PA PE PG PH PK PL PS PT PW PY QA RO RS RW SA SB SC SD SE SG SI SK SL SM SN SO SR SS ST SV SZ TD TG TH TJ TL TM TN TO TR TT TV TW TZ UA UG US UY UZ VA VC VN VU WS YE ZA ZM ZW'
  [[ "${SUPPORT_COUNTRY}" =~ $(wget -qO- --tries=3 --timeout=2 https://chat.openai.com/cdn-cgi/trace | awk -F '=' '/loc/{print $2}') ]] && { CHAT_GPT_OUT_V4=direct && CHAT_GPT_OUT_V6=direct; } || { CHAT_GPT_OUT_V4=warp-IPv4-out && CHAT_GPT_OUT_V6=warp-IPv6-out ; }

  # 生成 dns 配置
  cat > $WORK_DIR/conf/00_log.json << EOF

  {
      "log":{
          "disabled":false,

          "level":"error",
          "output":"$WORK_DIR/logs/box.log",
          "timestamp":true
      }
  }
EOF

  # 生成 outbound 配置
  cat > $WORK_DIR/conf/01_outbounds.json << EOF
  {
      "outbounds":[
          {
              "type":"direct",
              "tag":"direct",
              "domain_strategy":"${DOMAIN_STRATEG}"
          },
          {
              "type":"direct",
              "tag":"v6d",
              "domain_strategy":"prefer_ipv6"
          },
          {
              "type":"direct",
              "tag":"warp-IPv4-out",
              "detour":"wireguard-out",
              "domain_strategy":"ipv4_only"
          },
          {
              "type":"direct",
              "tag":"warp-IPv6-out",
              "detour":"wireguard-out",
              "domain_strategy":"ipv6_only"
          },
          {
              "type":"wireguard",
              "tag":"wireguard-out",
              "server":"${WARP_ENDPOINT}",
              "server_port":2408,
              "local_address":[
                  "172.16.0.2/32",
                  "2606:4700:110:8a36:df92:102a:9602:fa18/128"
              ],
              "private_key":"YFYOAdbw1bKTHlNNi+aEjBM3BO7unuFC5rOkMRAz9XY=",
              "peer_public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
              "reserved":[
                  78,
                  135,
                  76
              ],
              "mtu":1280
          },
          {
              "type":"block",
              "tag":"block"
          }
      ]
  }
EOF

  # 生成 route 配置
  cat > $WORK_DIR/conf/02_route.json << EOF
  {
    "route":{
        "rule_set":[
            {
                "tag":"geosite-openai",
                "type":"remote",
                "format":"binary",
                "url":"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs"
            },
            {
                "tag":"geosite-netflix",
                "type":"remote",
                "format":"binary",
                "url":"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-netflix.srs"
            }
        ],
        "rules":[
            {
                "domain":"api.openai.com",
                "outbound":"$CHAT_GPT_OUT_V4"
            },
            {
                "rule_set":"geosite-openai",
                "outbound":"$CHAT_GPT_OUT_V6"
            },{
                "rule_set":"geosite-netflix",
                "outbound":"v6d"
            }
        ]
    }
  }
EOF

  # 生成缓存文件
  cat > $WORK_DIR/conf/03_experimental.json << EOF
  {
      "experimental": {
          "cache_file": {
              "enabled": true,
              "path": "$WORK_DIR/cache.db"
          }
      }
  }
EOF

  # 生成 dns 配置文件
  cat > $WORK_DIR/conf/04_dns.json << EOF
  {
      "dns":{
          "servers":[
              {
                  "address":"local"
              }
          ]
      }
  }
EOF

  # 生成 XTLS + Reality 配置
  [ "${XTLS_REALITY}" = 'true' ] && ((PORT++)) && PORT_XTLS_REALITY=$PORT && cat > $WORK_DIR/conf/11_xtls-reality_inbounds.json << EOF
  //  "public_key":"${REALITY_PUBLIC}"
  {
      "inbounds":[
          {
              "type":"vless",
              "sniff":true,
              "sniff_override_destination":true,
              "tag":"${NODE_NAME} xtls-reality",
              "listen":"::",
              "listen_port":${PORT_XTLS_REALITY},
              "users":[
                  {
                      "uuid":"${UUID}",
                      "flow":""
                  }
              ],
              "tls":{
                  "enabled":true,
                  "server_name":"addons.mozilla.org",
                  "reality":{
                      "enabled":true,
                      "handshake":{
                          "server":"addons.mozilla.org",
                          "server_port":443
                      },
                      "private_key":"${REALITY_PRIVATE}",
                      "short_id":[
                          ""
                      ]
                  }
              },
              "multiplex":{
                  "enabled":true,
                  "padding":true,
                  "brutal":{
                      "enabled":true,
                      "up_mbps":1000,
                      "down_mbps":1000
                  }
              }
          }
      ]
  }
EOF

  # 生成 Hysteria2 配置
  [ "${HYSTERIA2}" = 'true' ] && ((PORT++)) && PORT_HYSTERIA2=$PORT && cat > $WORK_DIR/conf/12_hysteria2_inbounds.json << EOF
  {
      "inbounds":[
          {
              "type":"hysteria2",
              "sniff":true,
              "sniff_override_destination":true,
              "tag":"${NODE_NAME} hysteria2",
              "listen":"::",
              "listen_port":${PORT_HYSTERIA2},
              "users":[
                  {
                      "password":"${UUID}"
                  }
              ],
              "ignore_client_bandwidth":false,
              "tls":{
                  "enabled":true,
                  "server_name":"",
                  "alpn":[
                      "h3"
                  ],
                  "min_version":"1.3",
                  "max_version":"1.3",
                  "certificate_path":"$WORK_DIR/cert/cert.pem",
                  "key_path":"$WORK_DIR/cert/private.key"
              }
          }
      ]
  }
EOF

  # 生成 Tuic V5 配置
  [ "${TUIC}" = 'true' ] && ((PORT++)) && PORT_TUIC=$PORT && cat > $WORK_DIR/conf/13_tuic_inbounds.json << EOF
  {
      "inbounds":[
          {
              "type":"tuic",
              "sniff":true,
              "sniff_override_destination":true,
              "tag":"${NODE_NAME} tuic",
              "listen":"::",
              "listen_port":${PORT_TUIC},
              "users":[
                  {
                      "uuid":"${UUID}",
                      "password":"${UUID}"
                  }
              ],
              "congestion_control": "bbr",
              "zero_rtt_handshake": false,
              "tls":{
                  "enabled":true,
                  "alpn":[
                      "h3"
                  ],
                  "certificate_path":"$WORK_DIR/cert/cert.pem",
                  "key_path":"$WORK_DIR/cert/private.key"
              }
          }
      ]
  }
EOF

  # 生成 ShadowTLS V5 配置
  [ "${SHADOWTLS}" = 'true' ] && ((PORT++)) && PORT_SHADOWTLS=$PORT && cat > $WORK_DIR/conf/14_ShadowTLS_inbounds.json << EOF
  {
      "inbounds":[
          {
              "type":"shadowtls",
              "sniff":true,
              "sniff_override_destination":true,
              "tag":"${NODE_NAME} ShadowTLS",
              "listen":"::",
              "listen_port":${PORT_SHADOWTLS},
              "detour":"shadowtls-in",
              "version":3,
              "users":[
                  {
                      "password":"${UUID}"
                  }
              ],
              "handshake":{
                  "server":"addons.mozilla.org",
                  "server_port":443
              },
              "strict_mode":true
          },
          {
              "type":"shadowsocks",
              "tag":"shadowtls-in",
              "listen":"127.0.0.1",
              "network":"tcp",
              "method":"2022-blake3-aes-128-gcm",
              "password":"${SHADOWTLS_PASSWORD}",
              "multiplex":{
                  "enabled":true,
                  "padding":true,
                  "brutal":{
                      "enabled":true,
                      "up_mbps":1000,
                      "down_mbps":1000
                  }
              }
          }
      ]
  }
EOF

  # 生成 Shadowsocks 配置
  [ "${SHADOWSOCKS}" = 'true' ] && ((PORT++)) && PORT_SHADOWSOCKS=$PORT && cat > $WORK_DIR/conf/15_shadowsocks_inbounds.json << EOF
  {
      "inbounds":[
          {
              "type":"shadowsocks",
              "sniff":true,
              "sniff_override_destination":true,
              "tag":"${NODE_NAME} shadowsocks",
              "listen":"::",
              "listen_port":${PORT_SHADOWSOCKS},
              "method":"aes-128-gcm",
              "password":"${UUID}",
              "multiplex":{
                  "enabled":true,
                  "padding":true,
                  "brutal":{
                      "enabled":true,
                      "up_mbps":1000,
                      "down_mbps":1000
                  }
              }
          }
      ]
  }
EOF

  # 生成 Trojan 配置
  [ "${TROJAN}" = 'true' ] && ((PORT++)) && PORT_TROJAN=$PORT && cat > $WORK_DIR/conf/16_trojan_inbounds.json << EOF
  {
      "inbounds":[
          {
              "type":"trojan",
              "sniff":true,
              "sniff_override_destination":true,
              "tag":"${NODE_NAME} trojan",
              "listen":"::",
              "listen_port":${PORT_TROJAN},
              "users":[
                  {
                      "password":"${UUID}"
                  }
              ],
              "tls":{
                  "enabled":true,
                  "certificate_path":"$WORK_DIR/cert/cert.pem",
                  "key_path":"$WORK_DIR/cert/private.key"
              },
              "multiplex":{
                  "enabled":true,
                  "padding":true,
                  "brutal":{
                      "enabled":true,
                      "up_mbps":1000,
                      "down_mbps":1000
                  }
              }
          }
      ]
  }
EOF

  # 生成 vmess + ws 配置
  [ "${VMESS_WS}" = 'true' ] && ((PORT++)) && PORT_VMESS_WS=$PORT && cat > $WORK_DIR/conf/17_vmess-ws_inbounds.json << EOF
  //  "CDN": "${CDN}"
  {
      "inbounds":[
          {
              "type":"vmess",
              "sniff":true,
              "sniff_override_destination":true,
              "tag":"${NODE_NAME} vmess-ws",
              "listen":"127.0.0.1",
              "listen_port":${PORT_VMESS_WS},
              "tcp_fast_open":false,
              "proxy_protocol":false,
              "users":[
                  {
                      "uuid":"${UUID}",
                      "alterId":0
                  }
              ],
              "transport":{
                  "type":"ws",
                  "path":"/${UUID}-vmess",
                  "max_early_data":2048,
                  "early_data_header_name":"Sec-WebSocket-Protocol"
              },
              "multiplex":{
                  "enabled":true,
                  "padding":true,
                  "brutal":{
                      "enabled":true,
                      "up_mbps":1000,
                      "down_mbps":1000
                  }
              }
          }
      ]
  }
EOF

  # 生成 vless + ws + tls 配置
  [ "${VLESS_WS}" = 'true' ] && ((PORT++)) && PORT_VLESS_WS=$PORT && cat > $WORK_DIR/conf/18_vless-ws-tls_inbounds.json << EOF
  //  "CDN": "${CDN}"
  {
      "inbounds":[
          {
              "type":"vless",
              "sniff_override_destination":true,
              "sniff":true,
              "tag":"${NODE_NAME} vless-ws-tls",
              "listen":"::",
              "listen_port":${PORT_VLESS_WS},
              "tcp_fast_open":false,
              "proxy_protocol":false,
              "users":[
                  {
                      "name":"sing-box",
                      "uuid":"${UUID}"
                  }
              ],
              "transport":{
                  "type":"ws",
                  "path":"/${UUID}-vless",
                  "max_early_data":2048,
                  "early_data_header_name":"Sec-WebSocket-Protocol"
              },
              "multiplex":{
                  "enabled":true,
                  "padding":true,
                  "brutal":{
                      "enabled":true,
                      "up_mbps":1000,
                      "down_mbps":1000
                  }
              }
          }
      ]
  }
EOF

  # 生成 H2 + Reality 配置
  [ "${H2_REALITY}" = 'true' ] && ((PORT++)) && PORT_H2_REALITY=$PORT && cat > $WORK_DIR/conf/19_h2-reality_inbounds.json << EOF
  //  "public_key":"${REALITY_PUBLIC}"
  {
      "inbounds":[
          {
              "type":"vless",
              "sniff":true,
              "sniff_override_destination":true,
              "tag":"${NODE_NAME} h2-reality",
              "listen":"::",
              "listen_port":${PORT_H2_REALITY},
              "users":[
                  {
                      "uuid":"${UUID}"
                  }
              ],
              "tls":{
                  "enabled":true,
                  "server_name":"addons.mozilla.org",
                  "reality":{
                      "enabled":true,
                      "handshake":{
                          "server":"addons.mozilla.org",
                          "server_port":443
                      },
                      "private_key":"${REALITY_PRIVATE}",
                      "short_id":[
                          ""
                      ]
                  }
              },
              "transport": {
                  "type": "http"
              },
              "multiplex":{
                  "enabled":true,
                  "padding":true,
                  "brutal":{
                      "enabled":true,
                      "up_mbps":1000,
                      "down_mbps":1000
                  }
              }
          }
      ]
  }
EOF

  # 生成 gRPC + Reality 配置
  [ "${GRPC_REALITY}" = 'true' ] && ((PORT++)) && PORT_GRPC_REALITY=$PORT && cat > $WORK_DIR/conf/20_grpc-reality_inbounds.json << EOF
  //  "public_key":"${REALITY_PUBLIC}"
  {
      "inbounds":[
          {
              "type":"vless",
              "sniff":true,
              "sniff_override_destination":true,
              "tag":"${NODE_NAME} grpc-reality",
              "listen":"::",
              "listen_port":${PORT_GRPC_REALITY},
              "users":[
                  {
                      "uuid":"${UUID}"
                  }
              ],
              "tls":{
                  "enabled":true,
                  "server_name":"addons.mozilla.org",
                  "reality":{
                      "enabled":true,
                      "handshake":{
                          "server":"addons.mozilla.org",
                          "server_port":443
                      },
                      "private_key":"${REALITY_PRIVATE}",
                      "short_id":[
                          ""
                      ]
                  }
              },
              "transport": {
                  "type": "grpc",
                  "service_name": "grpc"
              },
              "multiplex":{
                  "enabled":true,
                  "padding":true,
                  "brutal":{
                      "enabled":true,
                      "up_mbps":1000,
                      "down_mbps":1000
                  }
              }
          }
      ]
  }
EOF

  # 判断 argo 隧道类型
  if [[ -n "$ARGO_DOMAIN" && -n "$ARGO_AUTH" ]]; then
    if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
      ARGO_JSON=${ARGO_AUTH//[ ]/}
      ARGO_RUNS="cloudflared tunnel --edge-ip-version auto --config $WORK_DIR/tunnel.yml run"
      echo $ARGO_JSON > $WORK_DIR/tunnel.json
      cat > $WORK_DIR/tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< $ARGO_JSON)
credentials-file: $WORK_DIR/tunnel.json

ingress:
  - hostname: ${ARGO_DOMAIN}
    service: https://localhost:${START_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

    elif [[ "${ARGO_AUTH}" =~ [a-z0-9A-Z=]{120,250} ]]; then
      [[ "{$ARGO_AUTH}" =~ cloudflared.*service ]] && ARGO_TOKEN=$(awk -F ' ' '{print $NF}' <<< "$ARGO_AUTH") || ARGO_TOKEN=$ARGO_AUTH
      ARGO_RUNS="cloudflared tunnel --edge-ip-version auto run --token ${ARGO_TOKEN}"
    fi
  else
    ((PORT++))
    METRICS_PORT=$PORT
    ARGO_RUNS="cloudflared tunnel --edge-ip-version auto --no-autoupdate --no-tls-verify --metrics 0.0.0.0:$METRICS_PORT --url https://localhost:$START_PORT"
  fi

  # 生成 supervisord 配置文件
  mkdir -p /etc/supervisor.d
  SUPERVISORD_CONF="[supervisord]
user=root
nodaemon=true
logfile=/dev/null
pidfile=/run/supervisord.pid

[program:nginx]
command=/usr/sbin/nginx -g 'daemon off;'
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:sing-box]
command=$WORK_DIR/sing-box run -C $WORK_DIR/conf/
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null"

[ -z "$METRICS_PORT" ] && SUPERVISORD_CONF+="

[program:argo]
command=$WORK_DIR/$ARGO_RUNS
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null
"

  echo "$SUPERVISORD_CONF" > /etc/supervisor.d/daemon.ini

  # 如使用临时隧道，先运行 cloudflared 以获取临时隧道域名
  if [ -n "$METRICS_PORT" ]; then
    $WORK_DIR/$ARGO_RUNS >/dev/null 2>&1 &
    sleep 3
    local ARGO_DOMAIN=$(wget -qO- http://localhost:$METRICS_PORT/quicktunnel | awk -F '"' '{print $4}')
  fi

  # 生成 nginx 配置文件
  local NGINX_CONF="user root;

  worker_processes auto;

  error_log  /dev/null;
  pid        /var/run/nginx.pid;

  events {
      worker_connections  1024;
  }

  http {
    map \$http_user_agent \$path {
      default                    /;                # 默认路径
      ~*v2rayN|Neko              /base64;          # 匹配 V2rayN / NekoBox 客户端
      ~*clash                    /clash;           # 匹配 Clash 客户端
      ~*ShadowRocket             /shadowrocket;    # 匹配 ShadowRocket  客户端
      ~*SFM                      /sing-box-pc;     # 匹配 Sing-box pc 客户端
      ~*SFI|SFA                  /sing-box-phone;  # 匹配 Sing-box phone 客户端
   #   ~*Chrome|Firefox|Mozilla  /;                # 添加更多的分流规则
    }

      include       /etc/nginx/mime.types;
      default_type  application/octet-stream;

      log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                        '\$status \$body_bytes_sent "\$http_referer" '
                        '"\$http_user_agent" "\$http_x_forwarded_for"';

      access_log  /dev/null;

      sendfile        on;
      #tcp_nopush     on;

      keepalive_timeout  65;

      #gzip  on;

      #include /etc/nginx/conf.d/*.conf;

    server {
      listen 0.0.0.0:80 ; # sing-box backend
      # http2 on;
      # server_name addons.mozilla.org;

      "

  [ "${VLESS_WS}" = 'true' ] && NGINX_CONF+="
      # 反代 sing-box vless websocket
      location /${UUID}-vless {
        if (\$http_upgrade != "websocket") {
           return 404;
        }
        proxy_pass                          http://127.0.0.1:${PORT_VLESS_WS};
        proxy_http_version                  1.1;
        proxy_set_header Upgrade            \$http_upgrade;
        proxy_set_header Connection         "upgrade";
        proxy_set_header X-Real-IP          \$remote_addr;
        proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
        proxy_set_header Host               \$host;
        proxy_redirect                      off;
      }"

  [ "${VMESS_WS}" = 'true' ] && NGINX_CONF+="
      # 反代 sing-box websocket
      location /${UUID}-vmess {
        if (\$http_upgrade != "websocket") {
           return 404;
        }
        proxy_pass                          http://127.0.0.1:${PORT_VMESS_WS};
        proxy_http_version                  1.1;
        proxy_set_header Upgrade            \$http_upgrade;
        proxy_set_header Connection         "upgrade";
        proxy_set_header X-Real-IP          \$remote_addr;
        proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
        proxy_set_header Host               \$host;
        proxy_redirect                      off;
      }"

  NGINX_CONF+="
      # 来自 /auto 的分流
      location ~ ^/${UUID}/auto {
        default_type 'text/plain; charset=utf-8';
        alias $WORK_DIR/subscribe/\$path;
      }

      location ~ ^/${UUID}/(.*) {
        autoindex on;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        default_type 'text/plain; charset=utf-8';
        alias $WORK_DIR/subscribe/\$1;
      }
    }
  }"

  echo "$NGINX_CONF" > /etc/nginx/nginx.conf

  # IPv6 时的 IP 处理
  if [[ "$SERVER_IP" =~ : ]]; then
    SERVER_IP_1="[$SERVER_IP]"
    SERVER_IP_2="[[$SERVER_IP]]"
  else
    SERVER_IP_1="$SERVER_IP"
    SERVER_IP_2="$SERVER_IP"
  fi

  # 生成各订阅文件
  # 生成 Clash proxy providers 订阅文件
  local CLASH_SUBSCRIBE='proxies:'

  [ "${XTLS_REALITY}" = 'true' ] && local CLASH_XTLS_REALITY="- {name: \"${NODE_NAME} xtls-reality\", type: vless, server: ${SERVER_IP}, port: ${PORT_XTLS_REALITY}, uuid: ${UUID}, network: tcp, udp: true, tls: true, servername: addons.mozilla.org, client-fingerprint: chrome, reality-opts: {public-key: ${REALITY_PUBLIC}, short-id: \"\"}, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_XTLS_REALITY
"
  [ "${HYSTERIA2}" = 'true' ] && local CLASH_HYSTERIA2="- {name: \"${NODE_NAME} hysteria2\", type: hysteria2, server: ${SERVER_IP}, port: ${PORT_HYSTERIA2}, up: \"200 Mbps\", down: \"1000 Mbps\", password: ${UUID}, skip-cert-verify: true}" &&
  local CLASH_SUBSCRIBE+="
  - {name: \"${NODE_NAME} hysteria2\", type: hysteria2, server: ${SERVER_IP}, port: ${PORT_HYSTERIA2}, up: \"200 Mbps\", down: \"1000 Mbps\", password: ${UUID}, skip-cert-verify: true}
"
  [ "${TUIC}" = 'true' ] && local CLASH_TUIC="- {name: \"${NODE_NAME} tuic\", type: tuic, server: ${SERVER_IP}, port: ${PORT_TUIC}, uuid: ${UUID}, password: ${UUID}, alpn: [h3], disable-sni: true, reduce-rtt: true, request-timeout: 8000, udp-relay-mode: native, congestion-controller: bbr, skip-cert-verify: true}" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_TUIC
"
  [ "${SHADOWTLS}" = 'true' ] && local CLASH_SHADOWTLS="- {name: \"${NODE_NAME} ShadowTLS\", type: ss, server: ${SERVER_IP}, port: ${PORT_SHADOWTLS}, cipher: 2022-blake3-aes-128-gcm, password: ${SHADOWTLS_PASSWORD}, plugin: shadow-tls, client-fingerprint: chrome, plugin-opts: {host: addons.mozilla.org, password: \"${UUID}\", version: 3}, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_SHADOWTLS
"
  [ "${SHADOWSOCKS}" = 'true' ] && local CLASH_SHADOWSOCKS="- {name: \"${NODE_NAME} shadowsocks\", type: ss, server: ${SERVER_IP}, port: $PORT_SHADOWSOCKS, cipher: aes-128-gcm, password: ${UUID}, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_SHADOWSOCKS
"
  [ "${TROJAN}" = 'true' ] && local CLASH_TROJAN="- {name: \"${NODE_NAME} trojan\", type: trojan, server: ${SERVER_IP}, port: $PORT_TROJAN, password: ${UUID}, client-fingerprint: random, skip-cert-verify: true, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_TROJAN
"
  [ "${VMESS_WS}" = 'true' ] && local CLASH_VMESS_WS="- {name: \"${NODE_NAME} vmess-ws\", type: vmess, server: ${CDN}, port: 80, uuid: ${UUID}, udp: true, tls: false, alterId: 0, cipher: auto, skip-cert-verify: true, network: ws, ws-opts: { path: \"/${UUID}-vmess\", headers: {Host: ${ARGO_DOMAIN}} }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_VMESS_WS
"
  [ "${VLESS_WS}" = 'true' ] && local CLASH_VLESS_WS="- {name: \"${NODE_NAME} vless-ws-tls\", type: vless, server: ${CDN}, port: 443, uuid: ${UUID}, udp: true, tls: true, servername: ${ARGO_DOMAIN}, network: ws, skip-cert-verify: true, ws-opts: { path: \"/${UUID}-vless\", headers: {Host: ${ARGO_DOMAIN}}, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_VLESS_WS
"
  # Clash 的 H2 传输层未实现多路复用功能，在 Clash.Meta 中更建议使用 gRPC 协议，故不输出相关配置。 https://wiki.metacubex.one/config/proxies/vless/
  [ "${H2_REALITY}" = 'true' ]

  [ "${GRPC_REALITY}" = 'true' ] && local CLASH_GRPC_REALITY="- {name: \"${NODE_NAME} grpc-reality\", type: vless, server: ${SERVER_IP}, port: ${PORT_GRPC_REALITY}, uuid: ${UUID}, network: grpc, tls: true, udp: true, flow:, client-fingerprint: chrome, servername: addons.mozilla.org, grpc-opts: {  grpc-service-name: \"grpc\" }, reality-opts: { public-key: ${REALITY_PUBLIC}, short-id: \"\" }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_GRPC_REALITY
"
  echo -n "${CLASH_SUBSCRIBE}" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' > $WORK_DIR/subscribe/proxies

  # 生成 clash 订阅配置文件
  # 模板: 使用 proxy providers
  wget -qO- --tries=3 --timeout=2 ${SUBSCRIBE_TEMPLATE}/clash | sed "s#NODE_NAME#${NODE_NAME}#g; s#PROXY_PROVIDERS_URL#http://${ARGO_DOMAIN}/${UUID}/proxies#" > $WORK_DIR/subscribe/clash

  # 生成 ShadowRocket 订阅配置文件
  [ "${XTLS_REALITY}" = 'true' ] && local SHADOWROCKET_SUBSCRIBE+="
vless://$(echo -n "auto:${UUID}@${SERVER_IP_2}:${PORT_XTLS_REALITY}" | base64 -w0)?remarks=${NODE_NAME} xtls-reality&obfs=none&tls=1&peer=addons.mozilla.org&mux=1&pbk=${REALITY_PUBLIC}
"
  [ "${HYSTERIA2}" = 'true' ] && local SHADOWROCKET_SUBSCRIBE+="
hysteria2://${UUID}@${SERVER_IP_1}:${PORT_HYSTERIA2}?insecure=1&obfs=none#${NODE_NAME}%20hysteria2
"
  [ "${TUIC}" = 'true' ] && local SHADOWROCKET_SUBSCRIBE+="
tuic://${UUID}:${UUID}@${SERVER_IP_2}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${NODE_NAME}%20tuic
"
  [ "${SHADOWTLS}" = 'true' ] && local SHADOWROCKET_SUBSCRIBE+="
ss://$(echo -n "2022-blake3-aes-128-gcm:${SHADOWTLS_PASSWORD}@${SERVER_IP_2}:${PORT_SHADOWTLS}" | base64 -w0)?shadow-tls=$(echo -n "{\"version\":\"3\",\"host\":\"addons.mozilla.org\",\"password\":\"${UUID}\"}" | base64 -w0)#${NODE_NAME}%20ShadowTLS
"
  [ "${SHADOWSOCKS}" = 'true' ] && local SHADOWROCKET_SUBSCRIBE+="
ss://$(echo -n "aes-128-gcm:${UUID}@${SERVER_IP_2}:$PORT_SHADOWSOCKS" | base64 -w0)#${NODE_NAME}%20shadowsocks
"
  [ "${TROJAN}" = 'true' ] && local SHADOWROCKET_SUBSCRIBE+="
trojan://${UUID}@${SERVER_IP_1}:$PORT_TROJAN?allowInsecure=1#${NODE_NAME}%20trojan
"
  [ "${VMESS_WS}" = 'true' ] && local SHADOWROCKET_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "auto:${UUID}@${CDN}:80" | base64 -w0)?remarks=${NODE_NAME}%20vmess-ws&obfsParam=${ARGO_DOMAIN}&path=/${UUID}-vmess&obfs=websocket&alterId=0
"
  [ "${VLESS_WS}" = 'true' ] && local SHADOWROCKET_SUBSCRIBE+="
----------------------------
vless://$(echo -n "auto:${UUID}@${CDN}:443" | base64 -w0)?remarks=${NODE_NAME} vless-ws-tls&obfsParam=${ARGO_DOMAIN}&path=/${UUID}-vless?ed=2048&obfs=websocket&tls=1&peer=${ARGO_DOMAIN}&allowInsecure=1
"
  [ "${H2_REALITY}" = 'true' ] && local SHADOWROCKET_SUBSCRIBE+="
----------------------------
vless://$(echo -n auto:${UUID}@${SERVER_IP_2}:${PORT_H2_REALITY} | base64 -w0)?remarks=${NODE_NAME}%20h2-reality&path=/&obfs=h2&tls=1&peer=addons.mozilla.org&alpn=h2&mux=1&pbk=${REALITY_PUBLIC}
"
  [ "${GRPC_REALITY}" = 'true' ] && local SHADOWROCKET_SUBSCRIBE+="
vless://$(echo -n "auto:${UUID}@${SERVER_IP_2}:${PORT_GRPC_REALITY}" | base64 -w0)?remarks=${NODE_NAME}%20grpc-reality&path=grpc&obfs=grpc&tls=1&peer=addons.mozilla.org&pbk=${REALITY_PUBLIC}
"
  echo -n "$SHADOWROCKET_SUBSCRIBE" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' | base64 -w0 > $WORK_DIR/subscribe/shadowrocket

  # 生成 V2rayN 订阅文件
  [ "${XTLS_REALITY}" = 'true' ] && local V2RAYN_SUBSCRIBE+="
----------------------------
vless://${UUID}@${SERVER_IP_1}:${PORT_XTLS_REALITY}?encryption=none&security=reality&sni=addons.mozilla.org&fp=chrome&pbk=${REALITY_PUBLIC}&type=tcp&headerType=none#${NODE_NAME// /%20}%20xtls-reality"

  [ "${HYSTERIA2}" = 'true' ] && local V2RAYN_SUBSCRIBE+="
----------------------------
hysteria2://${UUID}@${SERVER_IP_1}:${PORT_HYSTERIA2}/?alpn=h3&insecure=1#${NODE_NAME// /%20}%20hysteria2"

  [ "${TUIC}" = 'true' ] && local V2RAYN_SUBSCRIBE+="
----------------------------
tuic://${UUID}:${UUID}@${SERVER_IP_1}:${PORT_TUIC}?alpn=h3&congestion_control=bbr#${NODE_NAME// /%20}%20tuic

# $(info "请把 tls 里的 inSecure 设置为 true")"

  [ "${SHADOWTLS}" = 'true' ] && local V2RAYN_SUBSCRIBE+="
----------------------------
# $(info "ShadowTLS 配置文件内容，需要更新 sing_box 内核")

{
  \"log\":{
      \"level\":\"warn\"
  },
  \"inbounds\":[
      {
          \"domain_strategy\":\"\",
          \"listen\":\"127.0.0.1\",
          \"listen_port\":${PORT_SHADOWTLS},
          \"sniff\":true,
          \"sniff_override_destination\":false,
          \"tag\": \"ShadowTLS\",
          \"type\":\"mixed\"
      }
  ],
  \"outbounds\":[
      {
          \"detour\":\"shadowtls-out\",
          \"domain_strategy\":\"\",
          \"method\":\"2022-blake3-aes-128-gcm\",
          \"password\":\"${SHADOWTLS_PASSWORD}\",
          \"type\":\"shadowsocks\",
          \"udp_over_tcp\": false,
          \"multiplex\": {
            \"enabled\": true,
            \"protocol\": \"h2mux\",
            \"max_connections\": 8,
            \"min_streams\": 16,
            \"padding\": true
          }
      },
      {
          \"domain_strategy\":\"\",
          \"password\":\"${UUID}\",
          \"server\":\"${SERVER_IP}\",
          \"server_port\":${PORT_SHADOWTLS},
          \"tag\": \"shadowtls-out\",
          \"tls\":{
              \"enabled\":true,
              \"server_name\":\"addons.mozilla.org\",
              \"utls\": {
                \"enabled\": true,
                \"fingerprint\": \"chrome\"
              }
          },
          \"type\":\"shadowtls\",
          \"version\":3
      }
  ]
}"
  [ "${SHADOWSOCKS}" = 'true' ] && local V2RAYN_SUBSCRIBE+="
----------------------------
ss://$(echo -n "aes-128-gcm:${UUID}@${SERVER_IP_1}:$PORT_SHADOWSOCKS" | base64 -w0)#${NODE_NAME// /%20}%20shadowsocks"

  [ "${TROJAN}" = 'true' ] && local V2RAYN_SUBSCRIBE+="
----------------------------
trojan://${UUID}@${SERVER_IP_1}:$PORT_TROJAN?security=tls&type=tcp&headerType=none#${NODE_NAME// /%20}%20trojan

# $(info "ShadowTLS 配置文件内容，需要更新 sing_box 内核")"

  [ "${VMESS_WS}" = 'true' ] && local V2RAYN_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "{ \"v\": \"2\", \"ps\": \"${NODE_NAME} vmess-ws\", \"add\": \"${CDN}\", \"port\": \"80\", \"id\": \"${UUID}\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${ARGO_DOMAIN}\", \"path\": \"/${UUID}-vmess\", \"tls\": \"\", \"sni\": \"\", \"alpn\": \"\" }" | base64 -w0)
"

  [ "${VLESS_WS}" = 'true' ] && local V2RAYN_SUBSCRIBE+="
----------------------------
vless://${UUID}@${CDN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=%2F${UUID}-vless%3Fed%3D2048#${NODE_NAME// /%20}%20vless-ws-tls
"

  [ "${H2_REALITY}" = 'true' ] && local V2RAYN_SUBSCRIBE+="
----------------------------
vless://${UUID}@${SERVER_IP_1}:${PORT_H2_REALITY}?encryption=none&security=reality&sni=addons.mozilla.org&fp=chrome&pbk=${REALITY_PUBLIC}&type=http#${NODE_NAME// /%20}%20h2-reality"

  [ "${GRPC_REALITY}" = 'true' ] && local V2RAYN_SUBSCRIBE+="
----------------------------
vless://${UUID}@${SERVER_IP_1}:${PORT_GRPC_REALITY}?encryption=none&security=reality&sni=addons.mozilla.org&fp=chrome&pbk=${REALITY_PUBLIC}&type=grpc&serviceName=grpc&mode=gun#${NODE_NAME// /%20}%20grpc-reality"

  echo -n "$V2RAYN_SUBSCRIBE" | sed -E '/^[ ]*#|^[ ]+|^--|^\{|^\}/d' | sed '/^$/d' | base64 -w0 > $WORK_DIR/subscribe/v2rayn

  # 生成 NekoBox 订阅文件
  [ "${XTLS_REALITY}" = 'true' ] && local NEKOBOX_SUBSCRIBE+="
----------------------------
vless://${UUID}@${SERVER_IP_1}:${PORT_XTLS_REALITY}?security=reality&sni=addons.mozilla.org&fp=chrome&pbk=${REALITY_PUBLIC}&type=tcp&encryption=none#${NODE_NAME}%20xtls-reality"

  [ "${HYSTERIA2}" = 'true' ] && local NEKOBOX_SUBSCRIBE+="
----------------------------
hy2://${UUID}@${SERVER_IP_1}:${PORT_HYSTERIA2}?insecure=1#${NODE_NAME} hysteria2"

  [ "${TUIC}" = 'true' ] && local NEKOBOX_SUBSCRIBE+="
----------------------------
tuic://${UUID}:${UUID}@${SERVER_IP_1}:${PORT_TUIC}?congestion_control=bbr&alpn=h3&udp_relay_mode=native&allow_insecure=1&disable_sni=1#${NODE_NAME} tuic"

  [ "${SHADOWTLS}" = 'true' ] && local NEKOBOX_SUBSCRIBE+="
----------------------------
nekoray://custom#$(echo -n "{\"_v\":0,\"addr\":\"127.0.0.1\",\"cmd\":[\"\"],\"core\":\"internal\",\"cs\":\"{\n    \\\"password\\\": \\\"${UUID}\\\",\n    \\\"server\\\": \\\"${SERVER_IP_1}\\\",\n    \\\"server_port\\\": ${PORT_SHADOWTLS},\n    \\\"tag\\\": \\\"shadowtls-out\\\",\n    \\\"tls\\\": {\n        \\\"enabled\\\": true,\n        \\\"server_name\\\": \\\"addons.mozilla.org\\\"\n    },\n    \\\"type\\\": \\\"shadowtls\\\",\n    \\\"version\\\": 3\n}\n\",\"mapping_port\":0,\"name\":\"1-tls-not-use\",\"port\":1080,\"socks_port\":0}" | base64 -w0)

nekoray://shadowsocks#$(echo -n "{\"_v\":0,\"method\":\"2022-blake3-aes-128-gcm\",\"name\":\"2-ss-not-use\",\"pass\":\"${SHADOWTLS_PASSWORD}\",\"port\":0,\"stream\":{\"ed_len\":0,\"insecure\":false,\"mux_s\":0,\"net\":\"tcp\"},\"uot\":0}" | base64 -w0)"

  [ "${SHADOWSOCKS}" = 'true' ] && local NEKOBOX_SUBSCRIBE+="
----------------------------
ss://$(echo -n "aes-128-gcm:${UUID}" | base64 -w0)@${SERVER_IP_1}:$PORT_SHADOWSOCKS#${NODE_NAME} shadowsocks"

  [ "${TROJAN}" = 'true' ] && local NEKOBOX_SUBSCRIBE+="
----------------------------
trojan://${UUID}@${SERVER_IP_1}:$PORT_TROJAN?security=tls&allowInsecure=1&fp=random&type=tcp#${NODE_NAME} trojan"

  [ "${VMESS_WS}" = 'true' ] && local NEKOBOX_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "{\"add\":\"${CDN}\",\"aid\":\"0\",\"host\":\"${ARGO_DOMAIN}\",\"id\":\"${UUID}\",\"net\":\"ws\",\"path\":\"/${UUID}-vmess\",\"port\":\"80\",\"ps\":\"${NODE_NAME} vmess-ws\",\"scy\":\"auto\",\"sni\":\"\",\"tls\":\"\",\"type\":\"\",\"v\":\"2\"}" | base64 -w0)
"

  [ "${VLESS_WS}" = 'true' ] && local NEKOBOX_SUBSCRIBE+="
----------------------------
vless://${UUID}@${CDN}:443?security=tls&sni=${ARGO_DOMAIN}&type=ws&path=/${UUID}-vless?ed%3D2048&host=${ARGO_DOMAIN}#${NODE_NAME}%20vless-ws-tls
"

  [ "${H2_REALITY}" = 'true' ] && local NEKOBOX_SUBSCRIBE+="
----------------------------
vless://${UUID}@${SERVER_IP_1}:${PORT_H2_REALITY}?security=reality&sni=addons.mozilla.org&alpn=h2&fp=chrome&pbk=${REALITY_PUBLIC}&type=http&encryption=none#${NODE_NAME}%20h2-reality"

  [ "${GRPC_REALITY}" = 'true' ] && local NEKOBOX_SUBSCRIBE+="
----------------------------
vless://${UUID}@${SERVER_IP_1}:${PORT_GRPC_REALITY}?security=reality&sni=addons.mozilla.org&fp=chrome&pbk=${REALITY_PUBLIC}&type=grpc&serviceName=grpc&encryption=none#${NODE_NAME}%20grpc-reality"

  echo -n "$NEKOBOX_SUBSCRIBE" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' | base64 -w0 > $WORK_DIR/subscribe/neko

  # 生成 Sing-box 订阅文件
  [ "${XTLS_REALITY}" = 'true' ] &&
  local INBOUND_REPLACE+=" { \"type\": \"vless\", \"tag\": \"${NODE_NAME} xtls-reality\", \"server\":\"${SERVER_IP}\", \"server_port\":${PORT_XTLS_REALITY}, \"uuid\":\"${UUID}\", \"flow\":\"\", \"packet_encoding\":\"xudp\", \"tls\":{ \"enabled\":true, \"server_name\":\"addons.mozilla.org\", \"utls\":{ \"enabled\":true, \"fingerprint\":\"chrome\" }, \"reality\":{ \"enabled\":true, \"public_key\":\"${REALITY_PUBLIC}\", \"short_id\":\"\" } }, \"multiplex\": { \"enabled\": true, \"protocol\": \"h2mux\", \"max_connections\": 8, \"min_streams\": 16, \"padding\": true, \"brutal\":{ \"enabled\":true, \"up_mbps\":1000, \"down_mbps\":1000 } } }," &&
  local NODE_REPLACE+="\"${NODE_NAME} xtls-reality\","

  [ "${HYSTERIA2}" = 'true' ] &&
  local INBOUND_REPLACE+=" { \"type\": \"hysteria2\", \"tag\": \"${NODE_NAME} hysteria2\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_HYSTERIA2}, \"up_mbps\": 200, \"down_mbps\": 1000, \"password\": \"${UUID}\", \"tls\": { \"enabled\": true, \"insecure\": true, \"server_name\": \"\", \"alpn\": [ \"h3\" ] } }," &&
  local NODE_REPLACE+="\"${NODE_NAME} hysteria2\","

  [ "${TUIC}" = 'true' ] &&
  local INBOUND_REPLACE+=" { \"type\": \"tuic\", \"tag\": \"${NODE_NAME} tuic\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_TUIC}, \"uuid\": \"${UUID}\", \"password\": \"${UUID}\", \"congestion_control\": \"bbr\", \"udp_relay_mode\": \"native\", \"zero_rtt_handshake\": false, \"heartbeat\": \"10s\", \"tls\": { \"enabled\": true, \"insecure\": true, \"server_name\": \"\", \"alpn\": [ \"h3\" ] } }," &&
  local NODE_REPLACE+="\"${NODE_NAME} tuic\","

  [ "${SHADOWTLS}" = 'true' ] &&
  local INBOUND_REPLACE+=" { \"type\": \"shadowsocks\", \"tag\": \"${NODE_NAME} ShadowTLS\", \"method\": \"2022-blake3-aes-128-gcm\", \"password\": \"${SHADOWTLS_PASSWORD}\", \"detour\": \"shadowtls-out\", \"udp_over_tcp\": false, \"multiplex\": { \"enabled\": true, \"protocol\": \"h2mux\", \"max_connections\": 8, \"min_streams\": 16, \"padding\": true, \"brutal\":{ \"enabled\":true, \"up_mbps\":1000, \"down_mbps\":1000 } } }, { \"type\": \"shadowtls\", \"tag\": \"shadowtls-out\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_SHADOWTLS}, \"version\": 3, \"password\": \"${UUID}\", \"tls\": { \"enabled\": true, \"server_name\": \"addons.mozilla.org\", \"utls\": { \"enabled\": true, \"fingerprint\": \"chrome\" } } }," &&
  local NODE_REPLACE+="\"${NODE_NAME} ShadowTLS\","

  [ "${SHADOWSOCKS}" = 'true' ] &&
  local INBOUND_REPLACE+=" { \"type\": \"shadowsocks\", \"tag\": \"${NODE_NAME} shadowsocks\", \"server\": \"${SERVER_IP}\", \"server_port\": $PORT_SHADOWSOCKS, \"method\": \"aes-128-gcm\", \"password\": \"${UUID}\", \"multiplex\": { \"enabled\": true, \"protocol\": \"h2mux\", \"max_connections\": 8, \"min_streams\": 16, \"padding\": true, \"brutal\":{ \"enabled\":true, \"up_mbps\":1000, \"down_mbps\":1000 } } }," &&
  local NODE_REPLACE+="\"${NODE_NAME} shadowsocks\","

  [ "${TROJAN}" = 'true' ] &&
  local INBOUND_REPLACE+=" { \"type\": \"trojan\", \"tag\": \"${NODE_NAME} trojan\", \"server\": \"${SERVER_IP}\", \"server_port\": $PORT_TROJAN, \"password\": \"${UUID}\", \"tls\": { \"enabled\":true, \"insecure\": true, \"server_name\":\"\", \"utls\": { \"enabled\":true, \"fingerprint\":\"chrome\" } }, \"multiplex\": { \"enabled\":true, \"protocol\":\"h2mux\", \"max_connections\": 8, \"min_streams\": 16, \"padding\": true, \"brutal\":{ \"enabled\":true, \"up_mbps\":1000, \"down_mbps\":1000 } } }," &&
  local NODE_REPLACE+="\"${NODE_NAME} trojan\","

  [ "${VMESS_WS}" = 'true' ] &&
  local INBOUND_REPLACE+=" { \"type\": \"vmess\", \"tag\": \"${NODE_NAME} vmess-ws\", \"server\":\"${CDN}\", \"server_port\":80, \"uuid\": \"${UUID}\", \"security\": \"auto\", \"transport\": { \"type\":\"ws\", \"path\":\"/${UUID}-vmess\", \"headers\": { \"Host\": \"${ARGO_DOMAIN}\" } }, \"multiplex\": { \"enabled\":true, \"protocol\":\"h2mux\", \"max_streams\":16, \"padding\": true, \"brutal\":{ \"enabled\":true, \"up_mbps\":1000, \"down_mbps\":1000 } } }," && local NODE_REPLACE+="\"${NODE_NAME} vmess-ws\","

  [ "${VLESS_WS}" = 'true' ] &&
  local INBOUND_REPLACE+=" { \"type\": \"vless\", \"tag\": \"${NODE_NAME} vless-ws-tls\", \"server\":\"${CDN}\", \"server_port\":443, \"uuid\": \"${UUID}\", \"tls\": { \"enabled\":true, \"server_name\":\"${ARGO_DOMAIN}\", \"utls\": { \"enabled\":true, \"fingerprint\":\"chrome\" } }, \"transport\": { \"type\":\"ws\", \"path\":\"/${UUID}-vless\", \"headers\": { \"Host\": \"${ARGO_DOMAIN}\" }, \"max_early_data\":2048, \"early_data_header_name\":\"Sec-WebSocket-Protocol\" }, \"multiplex\": { \"enabled\":true, \"protocol\":\"h2mux\", \"max_streams\":16, \"padding\": true, \"brutal\":{ \"enabled\":true, \"up_mbps\":1000, \"down_mbps\":1000 } } }," &&
  local NODE_REPLACE+="\"${NODE_NAME} vless-ws-tls\","

  [ "${H2_REALITY}" = 'true' ] &&
  local INBOUND_REPLACE+=" { \"type\": \"vless\", \"tag\": \"${NODE_NAME} h2-reality\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_H2_REALITY}, \"uuid\":\"${UUID}\", \"tls\": { \"enabled\":true, \"server_name\":\"addons.mozilla.org\", \"utls\": { \"enabled\":true, \"fingerprint\":\"chrome\" }, \"reality\":{ \"enabled\":true, \"public_key\":\"${REALITY_PUBLIC}\", \"short_id\":\"\" } }, \"packet_encoding\": \"xudp\", \"transport\": { \"type\": \"http\" } }," &&
  local NODE_REPLACE+="\"${NODE_NAME} h2-reality\","

  [ "${GRPC_REALITY}" = 'true' ] &&
  local INBOUND_REPLACE+=" { \"type\": \"vless\", \"tag\": \"${NODE_NAME} grpc-reality\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_GRPC_REALITY}, \"uuid\":\"${UUID}\", \"tls\": { \"enabled\":true, \"server_name\":\"addons.mozilla.org\", \"utls\": { \"enabled\":true, \"fingerprint\":\"chrome\" }, \"reality\":{ \"enabled\":true, \"public_key\":\"${REALITY_PUBLIC}\", \"short_id\":\"\" } }, \"packet_encoding\": \"xudp\", \"transport\": { \"type\": \"grpc\", \"service_name\": \"grpc\" } }," &&
  local NODE_REPLACE+="\"${NODE_NAME} grpc-reality\","

  # 模板
  local SING_BOX_JSON1=$(wget -qO- --tries=3 --timeout=2 ${SUBSCRIBE_TEMPLATE}/sing-box1)

  echo $SING_BOX_JSON1 | sed 's#, {[^}]\+"tun-in"[^}]\+}##' | sed "s#\"<INBOUND_REPLACE>\",#$INBOUND_REPLACE#; s#\"<NODE_REPLACE>\"#${NODE_REPLACE%,}#g" | $WORK_DIR/jq > $WORK_DIR/subscribe/sing-box-pc

  echo $SING_BOX_JSON1 | sed 's# {[^}]\+"mixed"[^}]\+},##; s#, "auto_detect_interface": true##' | sed "s#\"<INBOUND_REPLACE>\",#$INBOUND_REPLACE#; s#\"<NODE_REPLACE>\"#${NODE_REPLACE%,}#g" | $WORK_DIR/jq > $WORK_DIR/subscribe/sing-box-phone

  # 生成二维码 url 文件
  cat > $WORK_DIR/subscribe/qr << EOF
自适应 Clash / V2rayN / NekoBox / ShadowRocket / SFI / SFA / SFM 客户端:
模版:
http://${ARGO_DOMAIN}/${UUID}/auto

模版:
$($WORK_DIR/qrencode "http://${ARGO_DOMAIN}/${UUID}/auto")
EOF

  # 生成配置文件
  EXPORT_LIST_FILE="*******************************************
┌────────────────┐
│                │
│     $(warning "V2rayN")     │
│                │
└────────────────┘
$(info "${V2RAYN_SUBSCRIBE}")

*******************************************
┌────────────────┐
│                │
│  $(warning "ShadowRocket")  │
│                │
└────────────────┘
----------------------------
$(hint "${SHADOWROCKET_SUBSCRIBE}")

*******************************************
┌────────────────┐
│                │
│   $(warning "Clash Meta")   │
│                │
└────────────────┘
----------------------------

$(info "$(sed '1d' <<< "${CLASH_SUBSCRIBE}")")

*******************************************
┌────────────────┐
│                │
│    $(warning "NekoBox")     │
│                │
└────────────────┘
$(hint "${NEKOBOX_SUBSCRIBE}")

*******************************************
┌────────────────┐
│                │
│    $(warning "Sing-box")    │
│                │
└────────────────┘
----------------------------

$(info "$(echo "{ \"outbounds\":[ ${INBOUND_REPLACE%,} ] }" | $WORK_DIR/jq)

各客户端配置文件路径: $WORK_DIR/subscribe/\n 完整模板可参照:\n https://t.me/ztvps/100\n https://github.com/chika0801/sing-box-examples/tree/main/Tun")
"

EXPORT_LIST_FILE+="

*******************************************

$(hint "Index:
http://${ARGO_DOMAIN}/${UUID}/

QR code:
http://${ARGO_DOMAIN}/${UUID}/qr

V2rayN 订阅:
http://${ARGO_DOMAIN}/${UUID}/v2rayn")

$(hint "NekoBox 订阅:
http://${ARGO_DOMAIN}/${UUID}/neko")

$(hint "Clash 订阅:
http://${ARGO_DOMAIN}/${UUID}/clash

sing-box for pc 订阅:
http://${ARGO_DOMAIN}/${UUID}/sing-box-pc

sing-box for cellphone 订阅:
http://${ARGO_DOMAIN}/${UUID}/sing-box-phone

ShadowRocket 订阅:
http://${ARGO_DOMAIN}/${UUID}/shadowrocket")

*******************************************

$(info " 自适应 Clash / V2rayN / NekoBox / ShadowRocket / SFI / SFA / SFM 客户端:
模版:
http://${ARGO_DOMAIN}/${UUID}/auto

 订阅 QRcode:
模版:
https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=http://${ARGO_DOMAIN}/${UUID}/auto")

$(hint "模版:")
$($WORK_DIR/qrencode http://${ARGO_DOMAIN}/${UUID}/auto)
"

  # 生成并显示节点信息
  echo "$EXPORT_LIST_FILE" > $WORK_DIR/list
  cat $WORK_DIR/list

  # 显示脚本使用情况数据
  hint "\n*******************************************\n"
}

# Sing-box 的最新版本
update_sing-box() {
  #####local ONLINE=$(check_latest_sing-box)
  local ONLINE='1.11.0-alpha.6'
  local LOCAL=$($WORK_DIR/sing-box version | awk '/version/{print $NF}')
  if [ -n "$ONLINE" ]; then
    if [[ "$ONLINE" != "$LOCAL" ]]; then
      wget https://github.com/SagerNet/sing-box/releases/download/v$ONLINE/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz -O- | tar xz -C $WORK_DIR sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box &&
      mv $WORK_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box $WORK_DIR/sing-box &&
      rm -rf $WORK_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH &&
      supervisorctl restart sing-box
      info " Sing-box v${ONLINE} 更新成功！"
    else
      info " Sing-box v${ONLINE} 已是最新版本！"
    fi
  else
    warning " 获取不了在线版本，请稍后再试！"
  fi
}

# 传参
while getopts ":Vv" OPTNAME; do
  case "${OPTNAME,,}" in
    v ) ACTION=update
  esac
done

# 主流程
check_arch

case "$ACTION" in
  update )
    update_sing-box
    ;;
  * )
    install
    # 运行 supervisor 进程守护
    supervisord -c /etc/supervisord.conf
esac
