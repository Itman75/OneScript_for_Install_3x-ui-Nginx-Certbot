#!/usr/bin/env bash
#
# Production AutoSetup (Hardened & Multi-Domain Cosmos Steal-Oneself v1.2.3-Fixed)
# Configurable Nginx Stream L4 Router & Mask for 3X-UI
# Supported external ports: 443 (TCP) and 8443 (TCP) simultaneously
# Scenario B: Self-Stealing REALITY with Isolated Certificates (No SAN Leak)
#

set -euo pipefail

# ─────────────────────────── Цвета ───────────────────────────
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${CYAN}[+]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗] $*${NC}" >&2; exit 1; }

trap 'die "Скрипт аварийно прерван на строке $LINENO"' ERR

echo -e "${CYAN}=========================================================${NC}"
echo -e "${GREEN}  Nginx L4 Stream Router & Mask v1.2.3 (Fixed & Verified)${NC}"
echo -e "${CYAN}=========================================================${NC}"

# ─────────────────────── Предусловия ─────────────────────────
if [ "$EUID" -ne 0 ]; then
  die "Пожалуйста, запустите скрипт от имени root (через sudo)."
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        die "Данный скрипт оптимизирован строго под семейства Ubuntu / Debian."
    fi
else
    die "Не удалось определить дистрибутив ОС."
fi

log "Проверка системных утилит..."
declare -A pkg_map=(
    [curl]="curl"
    [bash]="bash"
    [systemctl]="systemd"
    [openssl]="openssl"
    [awk]="gawk"
    [lsb_release]="lsb-release"
    [gpg]="gnupg2"
    [dig]="dnsutils"
)

apt_updated=0
for cmd in "${!pkg_map[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        warn "Не найдена утилита: $cmd. Устанавливаем пакет ${pkg_map[$cmd]}..."
        if [ "$apt_updated" -eq 0 ]; then
            apt-get update -q
            apt_updated=1
        fi
        apt-get install -y "${pkg_map[$cmd]}" -q
    fi
done

prompt_default() {
    local prompt_text="$1"
    local default_val="$2"
    local var_name="$3"
    local input_val
    read -rp "$prompt_text [$default_val]: " input_val
    declare -g "$var_name=${input_val:-$default_val}"
}

# ═════════════════════════════════════════════════════════════
#  ИНТЕРАКТИВНЫЙ ВВОД ПАРАМЕТРОВ С ВЫБОРОМ
# ═════════════════════════════════════════════════════════════
echo
echo -e "${YELLOW}Шаг 1: Настройка Главного Домена сервера${NC}"
echo -e "Этот домен будет использоваться для входа в панель 3X-UI, получения подписок"
echo -e "и отображения официального веб-сайта (декоя) для всех сторонних прохожих."
read -rp "Введите основной домен (например, proxy-hub.ru): " PRIMARY_DOMAIN
[[ "$PRIMARY_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] \
    || die "Некорректный формат главного домена: $PRIMARY_DOMAIN"

DOMAINS=("$PRIMARY_DOMAIN")
REALITY_PORTS=("") 

echo
echo -e "${YELLOW}Шаг 1.2: Добавление Альтернативных Доменов для REALITY (Steal-Oneself)${NC}"
echo -e "Каждому домену будет выпущен СОБСТВЕННЫЙ, независимый SSL-сертификат."
echo -e "Это исключает связь доменов между собой в публичных логах (No SAN Leak)."
echo -e "${CYAN}Для завершения ввода просто нажмите ENTER на пустой строке.${NC}"
echo

while true; do
    read -rp "Введите альтернативный домен REALITY: " ALT_DOMAIN
    if [ -z "$ALT_DOMAIN" ]; then
        break
    fi
    
    if [[ ! "$ALT_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        warn "Некорректный формат домена. Попробуйте еще раз."
        continue
    fi
    
    read -rp "Укажите локальный порт Nginx Stream для $ALT_DOMAIN [45443]: " ALT_PORT
    ALT_PORT="${ALT_PORT:-45443}"
    
    if [[ ! "$ALT_PORT" =~ ^[0-9]+$ ]] || [ "$ALT_PORT" -le 0 ] || [ "$ALT_PORT" -gt 65535 ]; then
        warn "Некорректный порт. Назначен порт по умолчанию: 45443."
        ALT_PORT="45443"
    fi
    
    DOMAINS+=("$ALT_DOMAIN")
    REALITY_PORTS+=("$ALT_PORT")
    ok "Добавлено: $ALT_DOMAIN связывается с локальным портом $ALT_PORT"
    echo
done

if [ ${#DOMAINS[@]} -eq 1 ]; then
    die "Ошибка: Для Сценария Б необходимо указать хотя бы один альтернативный домен!"
fi

echo
echo -e "${YELLOW}Шаг 2: Привязка технических портов панели 3X-UI${NC}"
echo -e "Убедитесь, что порты не заняты другими веб-службами."
prompt_default "Внутренний порт вашей веб-панели 3X-UI" "10443" PANEL_PORT
prompt_default "Секретный пулл-путь к веб-панели (без слэшей)" "sys-control-983" RAW_PATH
PANEL_PATH=$(echo "/${RAW_PATH}/" | tr -s '/')

prompt_default "Выделенный внутренний порт подписок 3X-UI" "55443" SUB_PORT

if [[ ! "$PANEL_PORT" =~ ^[0-9]+$ ]] || [ "$PANEL_PORT" -le 0 ] || [ "$PANEL_PORT" -gt 65535 ]; then
    die "Некорректный порт панели: $PANEL_PORT."
fi
if [[ ! "$SUB_PORT" =~ ^[0-9]+$ ]] || [ "$SUB_PORT" -le 0 ] || [ "$SUB_PORT" -gt 65535 ]; then
    die "Некорректный порт подписок: $SUB_PORT."
fi
if [ "$PANEL_PORT" -eq "$SUB_PORT" ]; then
    die "Конфликт: Порт панели и порт подписок должны различаться!"
fi

echo
echo -e "${GREEN}[i] ИНФОРМАЦИЯ ПО HYSTERIA 2 (UDP):${NC}"
echo -e "    Входные порты 443/UDP и 8443/UDP будут полностью свободны."
echo -e "    Вы сможете привязать их напрямую в инбаундах 3X-UI."

echo
echo -e "${YELLOW}Шаг 3: Выбор визуального камуфляжа (Decoy Front)${NC}"
echo -e " 1) Точная копия CosmosCloud (Страница входа, имитация API-запросов, кастомные заголовки)"
echo -e " 2) Стандартная заглушка Nginx (Классический 'Welcome to nginx!')"
prompt_default "Выберите вариант (1 или 2)" "1" DECOY_TEMPLATE

echo
echo -e "${YELLOW}Шаг 4: Служебные параметры Certbot${NC}"
prompt_default "Email для уведомлений Let's Encrypt (Оставьте пустым для отмены)" "" LE_EMAIL

# Проверка DNS
log "Сканирование DNS-записей перед выпуском SSL..."
WAN_IP=$(curl -s4 --connect-timeout 5 icanhazip.com || curl -s4 --connect-timeout 5 ifconfig.me || echo "")
dns_error=0
if [ -n "$WAN_IP" ]; then
    for d in "${DOMAINS[@]}"; do
        resolved_ip=$(dig +short "$d" @8.8.8.8 | tail -n1 || echo "")
        if [ -z "$resolved_ip" ]; then
            resolved_ip=$(getent ahosts "$d" | awk '{print $1}' | head -n1 || echo "")
        fi
        
        if [ -z "$resolved_ip" ]; then
            warn "Домен $d не указывает ни на один IP. Проверьте A-записи."
            dns_error=1
        elif [ "$resolved_ip" != "$WAN_IP" ]; then
            warn "Несовпадение: домен $d ведет на $resolved_ip, а текущий сервер имеет IP $WAN_IP."
            dns_error=1
        fi
    done
    if [ "$dns_error" -eq 1 ]; then
        read -rp "Обнаружены проблемы с DNS. Выпуск SSL может сорваться. Всё равно продолжить? [y/N]: " dns_ans
        [[ "${dns_ans,,}" == "y" ]] || die "Установка прервана пользователем для корректировки DNS."
    fi
else
    warn "Не удалось получить внешний IP сервера. Проверка DNS пропущена."
fi

# ═════════════════════════════════════════════════════════════
#  ПОДКЛЮЧЕНИЕ REPO NGINX И УСТАНОВКА СЛУЖБ
# ═════════════════════════════════════════════════════════════
log "Интеграция официального репозитория Nginx.org..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install gnupg2 ca-certificates lsb-release ubuntu-keyring openssl snapd -y -q

mkdir -p /usr/share/keyrings
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg --yes

OS_ID=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
OS_CODENAME=$(lsb_release -cs)

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/$OS_ID $OS_CODENAME nginx" \
    | tee /etc/apt/sources.list.d/nginx.list

cat << EOF > /etc/apt/preferences.d/99nginx
Package: nginx*
Pin: origin nginx.org
Pin-Priority: 900
EOF

log "Установка Nginx (Mainline/Stable Сборка)..."
apt-get update -q
apt-get install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nginx -y -q

NGINX_USER="nginx"
if ! id -u nginx >/dev/null 2>&1; then
    NGINX_USER="www-data"
fi

log "Развертывание веб-структуры..."
WEBROOT="/var/www/html"
mkdir -p "$WEBROOT/.well-known/acme-challenge"
chown -R "$NGINX_USER:$NGINX_USER" "$WEBROOT"

rm -f /etc/nginx/sites-enabled/default \
      /etc/nginx/sites-available/default \
      "/etc/nginx/sites-enabled/$PRIMARY_DOMAIN" \
      "/etc/nginx/sites-available/$PRIMARY_DOMAIN"

if [ -f /etc/nginx/conf.d/default.conf ]; then
    mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
fi

mkdir -p /etc/nginx/stream.d
rm -f "/etc/nginx/stream.d/$PRIMARY_DOMAIN.conf"

NGINX_80_SERVER_NAMES="${DOMAINS[*]}"

log "Конфигурация HTTP-порта 80 для прохождения проверок Let's Encrypt..."
cat << EOF > "/etc/nginx/conf.d/$PRIMARY_DOMAIN.conf"
server {
    listen 80;
    server_name $NGINX_80_SERVER_NAMES;
    server_tokens off;
    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        try_files \$uri =404;
    }
    location / { return 301 https://\$host\$request_uri; }
}
EOF

nginx -t || die "Ошибка валидации базовых конфигов Nginx."
systemctl restart nginx || systemctl start nginx

# ═════════════════════════════════════════════════════════════
#  УСТАНОВКА CERTBOT ЧЕРЕЗ SNAP
# ═════════════════════════════════════════════════════════════
log "Инициализация подсистемы Snapd..."
apt-get purge -y certbot || true
systemctl start snapd.socket || true
systemctl enable snapd.socket || true

for i in {1..15}; do
    if snap version >/dev/null 2>&1; then
        log "Демон snapd успешно активирован."
        break
    fi
    sleep 2
done

log "Установка Certbot..."
snap install core || true
snap refresh core || true
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot

# ═════════════════════════════════════════════════════════════
#  ВЫПУСК СЕРТИФИКАТОВ (РАЗДЕЛЬНЫЙ — БЕЗ СВЯЗЫВАНИЯ В CT LOGS)
# ═════════════════════════════════════════════════════════════
log "Генерация SSL для ОСНОВНОГО домена: $PRIMARY_DOMAIN..."
CERTBOT_ARGS=(certonly --webroot -w "$WEBROOT" --agree-tos -n --expand -d "$PRIMARY_DOMAIN")
if [ -n "$LE_EMAIL" ]; then
    CERTBOT_ARGS+=(--email "$LE_EMAIL")
else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
fi

if ! certbot "${CERTBOT_ARGS[@]}"; then
    warn "Не удалось выпустить SSL для главного домена $PRIMARY_DOMAIN."
fi

# Проверка физического наличия сертификата для исключения падения Nginx при старте
if [ ! -f "/etc/letsencrypt/live/$PRIMARY_DOMAIN/fullchain.pem" ]; then
    die "Критическая ошибка: Сертификат для главного домена $PRIMARY_DOMAIN не найден. Дальнейшая настройка прервана."
fi

# Изолированный выпуск для каждого Reality-домена
for ((i=1; i<${#DOMAINS[@]}; i++)); do
    alt_d="${DOMAINS[$i]}"
    log "Генерация ИЗОЛИРОВАННОГО SSL для Reality-домена: $alt_d..."
    ALT_CERT_ARGS=(certonly --webroot -w "$WEBROOT" --agree-tos -n --expand -d "$alt_d")
    if [ -n "$LE_EMAIL" ]; then
        ALT_CERT_ARGS+=(--email "$LE_EMAIL")
    else
        ALT_CERT_ARGS+=(--register-unsafely-without-email)
    fi
    if ! certbot "${ALT_CERT_ARGS[@]}"; then
        warn "Не удалось выпустить SSL для альтернативного домена $alt_d."
    fi
done

chmod 755 /etc/letsencrypt/archive || true
chmod 755 /etc/letsencrypt/live || true

DH_PARAM="/etc/nginx/dhparam.pem"
if [ ! -f "$DH_PARAM" ]; then
    log "Генерация криптографических параметров Диффи-Хеллмана (2048 bit, может занять 1-2 минуты)..."
    openssl dhparam -out "$DH_PARAM" 2048 2>/dev/null
fi

# ═════════════════════════════════════════════════════════════
#  ГЕНЕРАЦИЯ СТРАНИЦЫ МАСКИРОВКИ (ВЫБОР ШАБЛОНА)
# ═════════════════════════════════════════════════════════════
log "Развертывание маскировочного фронтенда..."
if [ "$DECOY_TEMPLATE" = "1" ]; then
    cat << 'EOF' > /var/www/html/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>My Cloud</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, minimum-scale=1.0, maximum-scale=1.0">
    <style>
        body { margin:0; padding:20px; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; background-color:#cbcae0; background-image:linear-gradient(135deg,#e2e1ec 0%,#bcbbcb 100%); display:flex; flex-direction:column; align-items:center; justify-content:center; min-height:100vh; color:#333; box-sizing:border-box; }
        .page-wrapper { width:100%; max-width:420px; display:flex; flex-direction:column; align-items:center; box-shadow:0 15px 35px rgba(0,0,0,0.15); border-radius:12px; overflow:hidden; }
        .banner-img { width:100%; height:auto; display:block; }
        .login-container { background:#fff; width:100%; text-align:center; padding:35px 30px; box-sizing:border-box; }
        .header-title { font-size:20px; color:#4a4557; margin-bottom:25px; font-weight:400; }
        .input-group { position:relative; margin-bottom:14px; }
        input { width:100%; padding:12px 15px; border:1px solid #ccc; border-radius:6px; box-sizing:border-box; font-size:15px; outline:none; transition:border-color .2s,box-shadow .2s; background:#fdfdfd; }
        input:focus { border-color:#735b8c; box-shadow:0 0 0 3px rgba(115,91,140,.15); background:#fff; }
        button { width:100%; padding:12px; background:#735b8c; color:#fff; border:none; border-radius:6px; font-size:16px; font-weight:600; cursor:pointer; margin-top:10px; transition:background .2s,opacity .2s; display:flex; justify-content:center; align-items:center; height:44px; }
        button:hover { background:#5d4874; }
        button:disabled { opacity:.7; cursor:not-allowed; }
        .message-box { background:#e74c3c; color:#fff; padding:11px; border-radius:6px; margin-bottom:20px; font-size:14px; text-align:left; display:none; animation:fadeIn .3s ease; }
        .spinner { display:inline-block; width:18px; height:18px; border:2px solid rgba(255,255,255,.3); border-top:2px solid #fff; border-radius:50%; animation:spin .8s linear infinite; }
        .footer-text { margin-top:25px; color:rgba(60,55,70,.6); font-size:13px; text-align:center; width:100%; }
        .footer-text a { color:#735b8c; text-decoration:none; font-weight:500; }
        @keyframes spin { 100% { transform:rotate(360deg); } }
        @keyframes fadeIn { from { opacity:0; transform:translateY(-5px); } to { opacity:1; transform:translateY(0); } }
    </style>
</head>
<body>
    <div class="page-wrapper">
        <img class="banner-img" src="logo.webp" alt="Cloud Header" onerror="this.style.display='none'">
        <div class="login-container">
            <div class="header-title">Вход в облако</div>
            <div id="errorBox" class="message-box"></div>
            <form id="loginForm" onsubmit="handleLogin(event)">
                <div class="input-group"><input id="user" type="text" placeholder="Имя пользователя или email" autocomplete="username" required></div>
                <div class="input-group"><input id="pass" type="password" placeholder="Пароль" autocomplete="current-password" required></div>
                <button type="submit" id="loginBtn">Войти</button>
            </form>
        </div>
    </div>
    <div class="footer-text">
        <a href="#">Cosmos Cloud</a> – безопасный дом для ваших данных
    </div>
    <script>
        function setFakeCookie() { document.cookie = "cosmos_session=" + Math.random().toString(36).substring(2) + "; path=/; Secure; SameSite=Lax"; }
        async function handleLogin(e) {
            e.preventDefault();
            const btn = document.getElementById("loginBtn"), errBox = document.getElementById("errorBox");
            errBox.style.display = "none"; btn.disabled = true; btn.innerHTML = '<div class="spinner"></div>';
            try {
                const response = await fetch("/api/v1/auth/login", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        user: document.getElementById("user").value,
                        pass: document.getElementById("pass").value
                    })
                });
                const data = await response.json();
                errBox.innerText = data.error || "Wrong nickname or password.";
                errBox.style.display = "block";
            } catch (err) {
                errBox.innerText = "Ошибка сетевого соединения с облаком.";
                errBox.style.display = "block";
            } finally {
                btn.disabled = false; btn.innerHTML = 'Войти';
            }
        }
        setFakeCookie();
    </script>
</body>
</html>
EOF

    log "Загрузка оригинальных графических ассетов Cosmos Cloud..."
    if ! curl -fsSL --connect-timeout 10 "https://raw.githubusercontent.com/Itman75/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/logo.webp" -o "$WEBROOT/logo.webp"; then
        curl -fsSLk --connect-timeout 10 "https://cdn.jsdelivr.net/gh/Itman75/Nginx-L4-Stream-Router-Mask-for-3x-ui@main/logo.webp" -o "$WEBROOT/logo.webp" || warn "Не удалось загрузить логотип."
    fi
else
    cat << 'EOF' > /var/www/html/index.html
<!DOCTYPE html>
<html>
<head><title>Welcome to nginx!</title><style>body { width: 35em; margin: 0 auto; font-family: Tahoma, Verdana, Arial, sans-serif; }</style></head>
<body><h1>Welcome to nginx!</h1><p>If you see this page, the nginx web server is successfully installed and working.</p></body>
</html>
EOF
fi

chown -R "$NGINX_USER:$NGINX_USER" "$WEBROOT"
chmod 644 "$WEBROOT/index.html"

# ═════════════════════════════════════════════════════════════
#  НАСТРОЙКА NGINX CONFIGS (STREAM + HTTP)
# ═════════════════════════════════════════════════════════════
log "Обновление глобальной конфигурации веб-сервера..."
[ -f /etc/nginx/nginx.conf ] && cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak

cat << EOF > /etc/nginx/nginx.conf
user $NGINX_USER;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 10240;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" \$status \$body_bytes_sent';
    access_log /var/log/nginx/access.log main;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    include /etc/nginx/conf.d/*.conf;
}

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF

cat << 'EOF' > /etc/nginx/conf.d/00-maps.conf
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

log "Сборка L4 Stream архитектуры маршрутизации..."
STREAM_MAP_RULES=""
ALL_REALITY_PORTS=()

# Безопасная генерация правил отображения доменов без echo -e
for ((i=1; i<${#DOMAINS[@]}; i++)); do
    STREAM_MAP_RULES+="    ${DOMAINS[$i]}    reality_backend_${REALITY_PORTS[$i]};
"
    ALL_REALITY_PORTS+=("${REALITY_PORTS[$i]}")
done

UNIQUE_PORTS=($(echo "${ALL_REALITY_PORTS[@]}" | tr ' ' '\n' | awk '!x[$0]++'))
REALITY_UPSTREAMS=""
for port in "${UNIQUE_PORTS[@]}"; do
  REALITY_UPSTREAMS+="
upstream reality_backend_$port {
    server 127.0.0.1:$port;
}
"
done

# ИСПРАВЛЕННАЯ СХЕМА: Отправка PROXY-протокола с внешних портов напрямую на HTTP/Xray
cat << EOF > "/etc/nginx/stream.d/$PRIMARY_DOMAIN.conf"
map \$ssl_preread_server_name \$backend_gate {
    ""                 nginx_http_backend;
    $PRIMARY_DOMAIN     nginx_http_backend;
$STREAM_MAP_RULES
    default             nginx_http_backend;
}

upstream nginx_http_backend {
    server 127.0.0.1:9443;
}

$REALITY_UPSTREAMS

server {
    listen 443;
    listen 8443; 
    ssl_preread on;
    proxy_protocol on; # <--- Передаем оригинальный IP клиента дальше без потерь в Xray и HTTP
    proxy_pass \$backend_gate;
    proxy_connect_timeout 5s;
    proxy_timeout 1h;
}
EOF

COSMOS_HEADER=""
COSMOS_MOCK_API=""
if [ "$DECOY_TEMPLATE" = "1" ]; then
  COSMOS_HEADER='add_header X-Cosmoscloud-Version "0.22.18" always;'
  COSMOS_MOCK_API='
    location ~ ^/(api/v1/status|status)$ {
        default_type application/json;
        return 200 '\''{"installed":true,"maintenance":false,"version":"0.22.18","productname":"CosmosCloud"}'\'';
    }
    location = /api/v1/auth/login {
        if ($request_method = POST) {
            add_header Content-Type "application/json" always;
            return 401 '\''{"error":"Wrong nickname or password. Try again or try resetting your password","code":401}'\'';
        }
        return 405;
    }'
fi

log "Построение изолированных виртуальных хостов для Reality-доменов..."
ALT_HTTP_SERVERS=""
for ((i=1; i<${#DOMAINS[@]}; i++)); do
    alt_d="${DOMAINS[$i]}"
    if [ -d "/etc/letsencrypt/live/$alt_d" ]; then
        ALT_HTTP_SERVERS+="
server {
    listen 127.0.0.1:9443 ssl proxy_protocol; # <--- ИСПРАВЛЕНО: Добавлен proxy_protocol
    http2 on;
    server_name $alt_d;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    ssl_certificate     /etc/letsencrypt/live/$alt_d/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$alt_d/privkey.pem;
    ssl_dhparam         $DH_PARAM;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    root $WEBROOT;
    index index.html;
    server_tokens off;

    add_header X-Content-Type-Options \"nosniff\" always;
    add_header X-Frame-Options \"SAMEORIGIN\" always;
    $COSMOS_HEADER
    add_header Strict-Transport-Security \"max-age=15768000; includeSubDomains\" always;

    $COSMOS_MOCK_API

    location = / {
        default_type text/html;
        root $WEBROOT;
        try_files /index.html =404; 
    }

    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|webp)\$ {
        expires 7d;
        access_log off;
        try_files \$uri =404;
    }

    location / { return 404; }
}
"
    fi
done

log "Сборка основного HTTP/HTTPS ядра Nginx..."
cat << EOF > "/etc/nginx/conf.d/$PRIMARY_DOMAIN.conf"
server {
    listen 80;
    server_name $NGINX_80_SERVER_NAMES;
    server_tokens off;
    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        try_files \$uri =404;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:9443 ssl proxy_protocol; # <--- ИСПРАВЛЕНО: Добавлен proxy_protocol
    http2 on;
    server_name $PRIMARY_DOMAIN;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    ssl_certificate     /etc/letsencrypt/live/$PRIMARY_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PRIMARY_DOMAIN/privkey.pem;
    ssl_dhparam         $DH_PARAM;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    root $WEBROOT;
    index index.html;
    server_tokens off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    $COSMOS_HEADER
    add_header Strict-Transport-Security "max-age=15768000; includeSubDomains" always;

    location ^~ $PANEL_PATH {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_hide_header X-Cosmoscloud-Version;
        proxy_hide_header X-Frame-Options;
        proxy_intercept_errors off;
    }

    location ^~ /postkey/ {
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_hide_header X-Cosmoscloud-Version;
        proxy_hide_header X-Frame-Options;
    }

    $COSMOS_MOCK_API

    location = / {
        default_type text/html;
        root $WEBROOT;
        try_files /index.html =404; 
    }

    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|webp)$ {
        expires 7d;
        access_log off;
        try_files \$uri =404;
    }

    location / { return 404; }
}
EOF

if [ -n "$ALT_HTTP_SERVERS" ]; then
    echo "$ALT_HTTP_SERVERS" >> "/etc/nginx/conf.d/$PRIMARY_DOMAIN.conf"
fi

log "Тестирование и перезапуск веб-сервера..."
nginx -t || die "Критическая ошибка синтаксиса собранной конфигурации Nginx."

mkdir -p /etc/letsencrypt/renewal-hooks/deploy/
cat << 'EOF' > /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
#!/bin/bash
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh

systemctl unmask nginx || true
systemctl enable nginx || true
systemctl restart nginx

# ═════════════════════════════════════════════════════════════
#  ФИНАЛЬНЫЙ ВЫВОД И ИНСТРУКЦИЯ
# ═════════════════════════════════════════════════════════════
echo
echo -e "${GREEN}=========================================================${NC}"
echo -e "      СЦЕНАРИЙ Б (STEAL-ONESELF) НАСТРОЕН УСПЕШНО!"
echo -e "${GREEN}=========================================================${NC}"
echo -e "Адрес Облака-заглушки:  ${CYAN}https://${PRIMARY_DOMAIN}${NC}"
echo -e "Альтернативные домены:  ${YELLOW}${DOMAINS[@]:1}${NC} (Без связывания SSL!)"
echo -e "Вход в панель 3X-UI:     ${GREEN}https://${PRIMARY_DOMAIN}${PANEL_PATH}${NC}"
echo
echo -e "${YELLOW}ПОДГОТОВКА ФАЙЕРВОЛА (UFW):${NC}"
echo -e "  Выполните команды в терминале для защиты внутренних портов:"
echo -e "  ${CYAN}ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 8443/tcp${NC}"
echo -e "  ${CYAN}ufw allow 443/udp && ufw allow 8443/udp${NC}"
echo -e "  ${RED}ufw deny $PANEL_PORT/tcp && ufw deny $SUB_PORT/tcp${NC}"
for p in "${UNIQUE_PORTS[@]}"; do
    echo -e "  ${RED}ufw deny $p/tcp${NC}"
done
echo
echo -e "${YELLOW}ВАЖНО! НАСТРОЙКА ИНБАУНДОВ В ПАНЕЛИ 3X-UI:${NC}"
echo -e "Чтобы трафик успешно проходил через Nginx, настройте VLESS REALITY строго так:"
for ((i=1; i<${#DOMAINS[@]}; i++)); do
    echo -e "   - Инбаунд для домена ${CYAN}${DOMAINS[$i]}${NC}:"
    echo -e "     • ${YELLOW}Порт:${NC} ${GREEN}${REALITY_PORTS[$i]}${NC} | ${YELLOW}Listen IP:${NC} ${GREEN}127.0.0.1${NC}"
    echo -e "     • ${YELLOW}Accept Proxy Protocol (xver):${NC} ${GREEN}Включить (выбрать 1)${NC} <--- ОБЯЗАТЕЛЬНО!"
    echo -e "     • ${YELLOW}Dest (Назначение):${NC} ${GREEN}127.0.0.1:9443${NC} <--- СТРОГО ЭТОТ ПОРТ (Порт заглушки)"
    echo -e "     • ${YELLOW}Proxy Protocol для Dest (xver):${NC} ${GREEN}Включить (выбрать 1)${NC} <--- ОБЯЗАТЕЛЬНО!"
    echo -e "     • ${YELLOW}Server Names:${NC} ${CYAN}${DOMAINS[$i]}${NC}"
    echo -e "     • ${YELLOW}ShortIds:${NC} Сгенерируйте новые в панели."
done
echo
echo -e "2. Настройка инбаунда ${GREEN}Hysteria 2 (UDP)${NC} (напрямую, минуя Nginx):"
echo -e "   - ${YELLOW}Порт:${NC} ${GREEN}443${NC} (или 8443) | ${YELLOW}Listen IP:${NC} ${GREEN}0.0.0.0${NC}"
echo -e "   - ${YELLOW}Путь к сертификату:${NC} ${CYAN}/etc/letsencrypt/live/${PRIMARY_DOMAIN}/fullchain.pem${NC}"
echo -e "   - ${YELLOW}Путь к ключу:${NC}       ${CYAN}/etc/letsencrypt/live/${PRIMARY_DOMAIN}/privkey.pem${NC}"
echo
echo -e "3. Настройка безопасных подписок (Subscriptions):"
echo -e "   - Перейдите в настройки подписок панели 3X-UI и укажите:"
echo -e "     • ${YELLOW}Порт подписки:${NC} ${GREEN}$SUB_PORT${NC} | ${YELLOW}Путь подписки:${NC} ${GREEN}/postkey/${NC}"
echo -e "     • ${YELLOW}URL обратного прокси:${NC} ${GREEN}https://${PRIMARY_DOMAIN}/postkey/${NC}"
echo -e "${GREEN}=========================================================${NC}"
exit 0
