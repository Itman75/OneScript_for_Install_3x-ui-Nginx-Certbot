#!/usr/bin/env bash
#
# Production AutoSetup from ItMan75 (Hardened & Multi-Domain Cosmos-Only Ultimate v1.0.9-Clean)
# Highly Configurable Nginx Stream L4 Router & Mask for 3X-UI from ItMan75
# Supported external ports: 443 (TCP) and 8443 (TCP) simultaneously
# Fully interactive domain-to-port mapping logic
#

set -euo pipefail

# ─────────────────────────── Цвета ───────────────────────────
GREEN='\033;0;32m'
CYAN='\033;0;36m'
RED='\033;0;31m'
YELLOW='\033;1;33m'
NC='\033[0m'

log()  { echo -e "${CYAN}[+]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗] $*${NC}" >&2; exit 1; }

trap 'die "Скрипт аварийно прерван на строке $LINENO"' ERR

echo -e "${CYAN}=========================================================${NC}"
echo -e "${GREEN}  Nginx L4 Stream Router & Mask v1.0.9 (Ultimate Clean)  ${NC}"
echo -e "${CYAN}=========================================================${NC}"

# ─────────────────────── Предусловия ─────────────────────────
if [ "$EUID" -ne 0 ]; then
  die "Пожалуйста, запустите скрипт от имени root (через sudo)."
fi

# Проверка и установка утилит с правильным маппингом пакетов APT
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

# Функция для интерактивного ввода со значениями по умолчанию
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
echo -e "${YELLOW}Шаг 1: Основной домен (для маскировки, панели и подписок)${NC}"
read -rp "Введите основной домен (например, www.host74.ru): " PRIMARY_DOMAIN
[[ "$PRIMARY_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] \
    || die "Некорректный формат главного домена: $PRIMARY_DOMAIN"

DOMAINS=("$PRIMARY_DOMAIN")
REALITY_PORTS=("") # Плейсхолдер для основного домена (у него нет Reality-порта)

echo
echo -e "${YELLOW}Шаг 1.2: Альтернативные домены и привязка портов Reality${NC}"
echo -e "Введите ваши домены для Reality по очереди. Для каждого домена вы укажете внутренний порт."
echo -e "Чтобы завершить ввод доменов, просто нажмите Enter на пустой строке."
echo

while true; do
    read -rp "Введите альтернативный домен (или Enter для завершения): " ALT_DOMAIN
    if [ -z "$ALT_DOMAIN" ]; then
        break
    fi
    
    # Валидация домена
    if [[ ! "$ALT_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        warn "Некорректный формат домена. Попробуйте еще раз."
        continue
    fi
    
    read -rp "Укажите внутренний порт Reality для $ALT_DOMAIN [45443]: " ALT_PORT
    ALT_PORT="${ALT_PORT:-45443}"
    
    # Валидация порта
    if [[ ! "$ALT_PORT" =~ ^[0-9]+$ ]] || [ "$ALT_PORT" -le 0 ] || [ "$ALT_PORT" -gt 65535 ]; then
        warn "Некорректный порт. Будет назначен порт по умолчанию: 45443."
        ALT_PORT="45443"
    fi
    
    DOMAINS+=("$ALT_DOMAIN")
    REALITY_PORTS+=("$ALT_PORT")
    ok "Добавлено: $ALT_DOMAIN будет перенаправлен на порт $ALT_PORT"
    echo
done

if [ ${#DOMAINS[@]} -eq 1 ]; then
    die "Вы должны добавить хотя бы один альтернативный домен для Reality!"
fi

echo
echo -e "${YELLOW}Шаг 2: Настройка портов и путей панели 3X-UI${NC}"
prompt_default "Внутренний порт вашей веб-панели 3X-UI" "10443" PANEL_PORT
prompt_default "Секретный путь к веб-панели (например, /dashboard/)" "/dashboard/" RAW_PATH
PANEL_PATH=$(echo "/${RAW_PATH}/" | tr -s '/')

# Выделенный внутренний порт подписок
prompt_default "Выделенный внутренний порт подписок 3X-UI" "55443" SUB_PORT

# Валидация портов панели и подписок
if [[ ! "$PANEL_PORT" =~ ^[0-9]+$ ]] || [ "$PANEL_PORT" -le 0 ] || [ "$PANEL_PORT" -gt 65535 ]; then
    die "Некорректный порт панели: $PANEL_PORT."
fi
if [[ ! "$SUB_PORT" =~ ^[0-9]+$ ]] || [ "$SUB_PORT" -le 0 ] || [ "$SUB_PORT" -gt 65535 ]; then
    die "Некорректный порт подписок: $SUB_PORT."
fi
if [ "$PANEL_PORT" -eq "$SUB_PORT" ]; then
    die "Порт панели и порт подписок не должны совпадать!"
fi

echo
echo -e "${GREEN}[i] ОПЦИЯ АКТИВНА — HYSTERIA 2 (UDP):${NC}"
echo -e "    Входные порты ${CYAN}443/UDP${NC} и ${CYAN}8443/UDP${NC} автоматически доступны для прямого биндинга в Xray."
echo -e "    Nginx не будет обрабатывать этот UDP-трафик, гарантируя максимальную скорость."

echo
echo -e "${YELLOW}Шаг 4: Выбор шаблона маскировки (Decoy)${NC}"
echo -e " 1) Имитация CosmosCloud (авторизация, API-заглушки, заголовок X-Cosmoscloud)"
echo -e " 2) Стандартный минималистичный веб-сайт Nginx"
prompt_default "Выберите вариант (1 или 2)" "1" DECOY_TEMPLATE

echo
echo -e "${YELLOW}Шаг 5: Служебные параметры${NC}"
prompt_default "Email для Let's Encrypt (Enter — без уведомлений)" "" LE_EMAIL

# Проверка DNS
log "Проверка DNS-записей..."
WAN_IP=$(curl -s4 --connect-timeout 5 icanhazip.com || curl -s4 --connect-timeout 5 ifconfig.me || echo "")
dns_error=0
if [ -n "$WAN_IP" ]; then
    for d in "${DOMAINS[@]}"; do
        resolved_ip=$(dig +short "$d" @8.8.8.8 | tail -n1 || echo "")
        if [ -z "$resolved_ip" ]; then
            resolved_ip=$(getent ahosts "$d" | awk '{print $1}' | head -n1 || echo "")
        fi
        
        if [ -z "$resolved_ip" ]; then
            warn "Домен $d не разрешается в IP-адрес (возможно, DNS-запись еще не обновилась)."
            dns_error=1
        elif [ "$resolved_ip" != "$WAN_IP" ]; then
            warn "Домен $d указывает на IP ($resolved_ip), а ваш server имеет IP ($WAN_IP)."
            dns_error=1
        fi
    done
    if [ "$dns_error" -eq 1 ]; then
        read -rp "Обнаружены несовпадения DNS. Всё равно продолжить? [y/N]: " dns_ans
        [[ "${dns_ans,,}" == "y" ]] || die "Исправьте DNS-записи и запустите скрипт повторно."
    fi
else
    warn "Не удалось определить внешний IP-адрес сервера для автоматической проверки DNS."
fi

# ═════════════════════════════════════════════════════════════
# 6. ПОДКЛЮЧЕНИЕ REPO NGINX И УСТАНОВКА СЛУЖБ
# ═════════════════════════════════════════════════════════════
log "Подключение репозитория Nginx.org..."
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

log "Установка официальной сборки Nginx..."
apt-get update -q
apt-get install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nginx -y -q

NGINX_USER="nginx"
if ! id -u nginx >/dev/null 2>&1; then
    NGINX_USER="www-data"
fi

log "Подготовка директорий..."
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

NGINX_SERVER_NAMES="${DOMAINS[*]}"

log "Создание временного хоста для верификации Certbot..."
cat << EOF > "/etc/nginx/conf.d/$PRIMARY_DOMAIN.conf"
server {
    listen 80;
    server_name $NGINX_SERVER_NAMES;
    server_tokens off;
    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        try_files \$uri =404;
    }
    location / { return 404; }
}
EOF

nginx -t || die "Ошибка во временной конфигурации Nginx."
systemctl restart nginx || systemctl start nginx

# ═════════════════════════════════════════════════════════════
# 7. УСТАНОВКА CERTBOT ЧЕРЕЗ SNAP
# ═════════════════════════════════════════════════════════════
log "Подготовка окружения Snap..."
apt-get purge -y certbot || true

systemctl start snapd.socket || true
systemctl enable snapd.socket || true

log "Ожидание инициализации службы snapd..."
for i in {1..15}; do
    if snap version >/dev/null 2>&1; then
        log "Служба snapd запущена и готова к работе."
        break
    fi
    warn "Инициализация snapd в фоне... Попытка $i/15"
    sleep 2
done

log "Установка Certbot..."
snap install core || true
snap refresh core || true
snap install --classic certbot

ln -sf /snap/bin/certbot /usr/bin/certbot

# ═════════════════════════════════════════════════════════════
# 8. ВЫПУСК СЕРТИФИКАТА С ПОДДЕРЖКОЙ SAN
# ═════════════════════════════════════════════════════════════
log "Запрос SSL-сертификата Let's Encrypt для всех доменов..."
CERTBOT_ARGS=(certonly --webroot -w "$WEBROOT" --agree-tos -n --expand)
for d in "${DOMAINS[@]}"; do
    CERTBOT_ARGS+=(-d "$d")
done
if [ -n "$LE_EMAIL" ]; then
    CERTBOT_ARGS+=(--email "$LE_EMAIL")
else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
fi

if ! certbot "${CERTBOT_ARGS[@]}"; then
    warn "Certbot завершил работу с ошибкой. Проверяем, появились ли сертификаты..."
fi

if [ ! -d "/etc/letsencrypt/live/$PRIMARY_DOMAIN" ]; then
    die "Не удалось получить SSL-сертификат (папка /etc/letsencrypt/live/$PRIMARY_DOMAIN не найдена)."
fi

chmod 755 /etc/letsencrypt/archive
chmod 755 /etc/letsencrypt/live

DH_PARAM="/etc/nginx/dhparam.pem"
if [ ! -f "$DH_PARAM" ]; then
    warn "Генерация параметров Диффи-Хеллмана..."
    openssl dhparam -out "$DH_PARAM" 2048 2>/dev/null
fi

# ═════════════════════════════════════════════════════════════
# 9. ГЕНЕРАЦИЯ СТРАНИЦЫ МАСКИРОВКИ (ВЫБОР ШАБЛОНА)
# ═════════════════════════════════════════════════════════════
log "Создание frontend-страницы маскировки (Шаблон: $DECOY_TEMPLATE)..."
if [ "$DECOY_TEMPLATE" = "1" ]; then
    # Шаблон 1: CosmosCloud
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
        .footer-text a:hover { text-decoration:underline; }
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
            <form id="loginForm" onsubmit="fakeLogin(event)">
                <div class="input-group"><input id="user" type="text" placeholder="Имя пользователя или email" autocomplete="username" required></div>
                <div class="input-group"><input id="pass" type="password" placeholder="Пароль" autocomplete="current-password" required></div>
                <button type="submit" id="loginBtn">Войти</button>
            </form>
        </div>
    </div>
    <div class="footer-text">
        <a href="#">Cosmos Cloud</a> – безопасный дом для ваших данных<br>
        <span id="server-time"></span>
    </div>
    <script>
        function setFakeCookie() { document.cookie = "cosmos_session=" + Math.random().toString(36).substring(2) + "; path=/; Secure; SameSite=Lax"; }
        function fakeLogin(e) {
            e.preventDefault();
            const btn = document.getElementById("loginBtn"), errBox = document.getElementById("errorBox");
            errBox.style.display = "none"; btn.disabled = true; btn.innerHTML = '<div class="spinner"></div>';
            setTimeout(() => {
                btn.disabled = false; btn.innerHTML = 'Войти';
                errBox.innerText = "Неверное имя пользователя или указанный пароль.";
                errBox.style.display = "block";
                document.getElementById("pass").value = ""; document.getElementById("pass").focus();
            }, 1500);
        }
        function updateServerTime() { const t = document.getElementById("server-time"); if (t) t.innerText = "Время сервера: " + new Date().toLocaleTimeString(); }
        setInterval(updateServerTime, 1000); updateServerTime(); setFakeCookie();
    </script>
</body>
</html>
EOF

    # Скачивание оригинального логотипа Cosmos Cloud с резервным CDN-зеркалом
    log "Скачивание оригинального логотипа для заглушки Cosmos Cloud..."
    if ! curl -fsSL --connect-timeout 10 "https://raw.githubusercontent.com/Itman75/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/logo.webp" -o "$WEBROOT/logo.webp"; then
        warn "Прямой доступ к GitHub Raw ограничен. Пробуем скачать через зеркало CDN..."
        if ! curl -fsSL --connect-timeout 10 "https://cdn.jsdelivr.net/gh/Itman75/Nginx-L4-Stream-Router-Mask-for-3x-ui@main/logo.webp" -o "$WEBROOT/logo.webp"; then
            warn "Пробуем скачать без проверки SSL (для старых ca-certificates)..."
            curl -fsSLk --connect-timeout 10 "https://cdn.jsdelivr.net/gh/Itman75/Nginx-L4-Stream-Router-Mask-for-3x-ui@main/logo.webp" -o "$WEBROOT/logo.webp" || warn "Не удалось скачать оригинальный логотип."
        fi
    fi

    if [ -f "$WEBROOT/logo.webp" ]; then
        chown "$NGINX_USER:$NGINX_USER" "$WEBROOT/logo.webp"
        chmod 644 "$WEBROOT/logo.webp"
        ok "Логотип успешно загружен."
    fi

else
    # Шаблон 2: Минималистичный Nginx
    cat << 'EOF' > /var/www/html/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Welcome to nginx!</title>
    <style>
        body { width: 35em; margin: 0 auto; font-family: Tahoma, Verdana, Arial, sans-serif; background-color: #fcfcfc; color: #333; padding-top: 50px; }
    </style>
</head>
<body>
    <h1>Welcome to nginx!</h1>
    <p>If you see this page, the nginx web server is successfully installed and working. Further configuration is required.</p>
    <p>For online documentation and support please refer to <a href="http://nginx.org/">nginx.org</a>.</p>
    <p><em>Thank you for using nginx.</em></p>
</body>
</html>
EOF
fi
chown "$NGINX_USER:$NGINX_USER" "$WEBROOT/index.html"
chmod 644 "$WEBROOT/index.html"

# ═════════════════════════════════════════════════════════════
# 10. НАСТРОЙКА NGINX CONFIGS (STREAM + HTTP)
# ═════════════════════════════════════════════════════════════
log "Бэкап и замена глобального nginx.conf..."
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

mkdir -p /etc/nginx/stream.d

cat << 'EOF' > /etc/nginx/conf.d/00-maps.conf
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

log "Сборка конфигурации L4 Stream..."
STREAM_MAP_RULES=""
ALL_REALITY_PORTS=()

for ((i=1; i<${#DOMAINS[@]}; i++)); do
    STREAM_MAP_RULES+="    ${DOMAINS[$i]}      reality_backend_${REALITY_PORTS[$i]};\n"
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

cat << EOF > "/etc/nginx/stream.d/$PRIMARY_DOMAIN.conf"
map \$ssl_preread_server_name \$backend_gate {
    ""                 nginx_http_backend;
    $PRIMARY_DOMAIN     nginx_http_backend;
$(echo -e "$STREAM_MAP_RULES")
    default              nginx_http_backend;
}

upstream nginx_http_backend {
    server 127.0.0.1:8444;
}

$REALITY_UPSTREAMS

server {
    listen 127.0.0.1:8444;
    proxy_pass 127.0.0.1:9443;
    proxy_protocol on;
}

server {
    listen 443;
    listen 8443; # Поддержка внешнего порта 8443
    ssl_preread on;
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
            add_header Set-Cookie "cosmos_session=$request_id; path=/; Secure; HttpOnly; SameSite=Lax" always;
            return 200 '\''{"status":"OK","message":"Authenticated"}'\'';
        }
        return 405;
    }'
fi

log "Сборка HTTP-конфигурации веб-сервера..."
cat << EOF > "/etc/nginx/conf.d/$PRIMARY_DOMAIN.conf"
server {
    listen 80;
    server_name $NGINX_SERVER_NAMES;
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
    listen 127.0.0.1:9443 ssl proxy_protocol;
    listen 127.0.0.1:9444 ssl;
    http2 on;
    server_name $NGINX_SERVER_NAMES;

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

log "Проверка и перезапуск конфигурации Nginx..."
nginx -t || die "Ошибка конфигурации Nginx."

mkdir -p /etc/letsencrypt/renewal-hooks/deploy/
cat << 'EOF' > /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
#!/bin/bash
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh

systemctl unmask nginx || true
systemctl enable nginx || true
systemctl restart nginx

FORMATTED_PORTS=$(echo "${UNIQUE_PORTS[@]}" | sed 's/ /, /g')

# ═════════════════════════════════════════════════════════════
#  ФИНАЛЬНЫЙ ВЫВОД
# ═════════════════════════════════════════════════════════════
echo
echo -e "${GREEN}=========================================================${NC}"
echo -e "        УСТАНОВКА И НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА!"
echo -e "${GREEN}=========================================================${NC}"
echo -e "Адрес Облака-заглушки:  ${CYAN}https://${PRIMARY_DOMAIN}${NC}"
echo -e "Альтернативные (SAN): ${YELLOW}${DOMAINS[@]:1}${NC}"
echo -e "Вход в панель 3X-UI:  ${CYAN}https://${PRIMARY_DOMAIN}${PANEL_PATH}${NC}"
echo -e "SSL Сертификаты:      ${GREEN}/etc/letsencrypt/live/${PRIMARY_DOMAIN}/${NC}"
echo
echo -e "${YELLOW}ВАЖНО: ВЫ ДОЛЖНЫ ВРУЧНУЮ НАСТРОИТЬ ВАШ ФАЙЕРВОЛ:${NC}"
echo -e "Разрешите входящие порты:   ${GREEN}80/TCP, 443/TCP, 8443/TCP, 443/UDP, [Ваш кастомный порт SSH]${NC}"
echo -e "Заблокируйте для внешних:   ${RED}$PANEL_PORT (Панель 3X-UI), $FORMATTED_PORTS (Reality порты)${NC}"
echo
echo -e "${YELLOW}ФИНАЛЬНЫЙ ШАГ: НАСТРОЙТЕ ИНБАУНДЫ В ПАНЕЛИ 3X-UI:${NC}"
echo -e "1. Настройка инбаундов ${GREEN}VLESS REALITY${NC}:"
for ((i=1; i<${#DOMAINS[@]}; i++)); do
    echo -e "   - Создайте инбаунд под домен ${CYAN}${DOMAINS[$i]}${NC} на внутренний порт: ${GREEN}${REALITY_PORTS[$i]}${NC}"
    echo -e "     (Для этого инбаунда установите ${CYAN}Listen IP${NC} в значение ${GREEN}127.0.0.1${NC} и пропишите ${CYAN}serverNames: ${DOMAINS[$i]}${NC})"
done
echo
echo -e "2. Настройка инбаунда ${GREEN}Hysteria 2${NC}:"
echo -e "   - Порт: ${GREEN}443${NC}, Listen IP: ${GREEN}0.0.0.0${NC} (Протокол: ${CYAN}UDP${NC})."
echo -e "   - Пути к сертификатам: ${CYAN}/etc/letsencrypt/live/${PRIMARY_DOMAIN}/fullchain.pem${NC} / ${CYAN}privkey.pem${NC}"
echo
echo -e "3. Настройка системы подписок (Subscriptions) в 3X-UI:"
echo -e "   - Перейдите в веб-интерфейс панели -> ${CYAN}Настройки панели${NC} -> вкладка ${CYAN}Настройки подписок${NC}."
echo -e "   - Нажмите галочку ${GREEN}Включить подписку (Enable Subscription)${NC}."
echo -e "   - В поле ${CYAN}Порт подписки (Subscription port)${NC} впишите выделенный порт: ${GREEN}$SUB_PORT${NC}."
echo -e "   - В поле ${CYAN}URI-путь подписки (Subscription path)${NC} строго укажите: ${GREEN}/postkey/${NC}."
echo -e "   - В поле ${CYAN}URI обратного прокси пропишите адрес подписки без портов:"
echo -e "     ${GREEN}https://${PRIMARY_DOMAIN}:8443/postkey/${NC} или ${GREEN}https://${PRIMARY_DOMAIN}/postkey/${NC}."
echo -e "   - Нажмите ${YELLOW}Сохранить настройки${NC} и обязательно нажмите ${CYAN}Перезапустить панель${NC}."
echo -e "   - ${CYAN}Важно:${NC} Теперь все запросы клиентов будут идти на стандартный безопасный порт 443 или 8443, а Nginx сам передаст их панели."
echo

exit 0
