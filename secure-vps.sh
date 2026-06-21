#!/bin/bash
set -euo pipefail

#####################################
# PROD VPS HARDENING (Ubuntu 24.04)
# + BBR + Disable IPv6 + Block Ping
# + IPv4 ONLY Firewall Rules
# + SSH Keys (Auto-gen or Paste)
# + 3x-ui
# + Extended Utilities
#####################################

DEFAULT_SSH_PORT=22
MIN_SSH_PORT=1024
MAX_SSH_PORT=65535

export DEBIAN_FRONTEND=noninteractive

#####################################
# ПРОВЕРКА ROOT
#####################################
if [[ $EUID -ne 0 ]]; then
    echo "Запусти скрипт от root"
    exit 1
fi

#####################################
# ОБНОВЛЕНИЕ И УСТАНОВКА СИСТЕМНЫХ УТИЛИТ
#####################################
echo "==========================================================="
echo "ОБНОВЛЕНИЕ ПАКЕТНОЙ БАЗЫ И КОМПОНЕНТОВ ОС..."
echo "==========================================================="
apt update && apt upgrade -y && apt autoremove -y && apt autoclean -y

echo "==========================================================="
echo "УСТАНОВКА СИСТЕМНЫХ И СЕТЕВЫХ УТИЛИТ ДИАГНОСТИКИ..."
echo "==========================================================="
apt install -y curl bash systemd iproute2 openssl gawk lsb-release gnupg2 dnsutils perl build-essential btop htop iperf3 iftop net-tools tcpdump mtr-tiny

#####################################
# ФУНКЦИИ
#####################################
prompt_yes_no() {
    while true; do
        read -rp "$1 (yes/no): " ans
        case "$ans" in
            yes|y|Y) return 0 ;;
            no|n|N) return 1 ;;
            *) echo "Введите yes или no" ;;
        esac
    done
}

validate_password() {
    local p="$1"
    [[ ${#p} -ge 12 ]] && \
    [[ "$p" =~ [a-z] ]] && \
    [[ "$p" =~ [A-Z] ]] && \
    [[ "$p" =~ [0-9] ]] && \
    [[ "$p" =~ [^a-zA-Z0-9] ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && \
    (( "$1" >= MIN_SSH_PORT && "$1" <= MAX_SSH_PORT ))
}

safe_sudoers() {
    local file="/etc/sudoers.d/$1"
    chmod 440 "$file"
    # Перехватываем ошибку visudo при включенном set -e
    if ! visudo -cf "$file"; then
        echo "Ошибка: некорректный синтаксис sudoers! Удаляем поврежденный файл: $file"
        rm -f "$file"
        return 1
    fi
}

restart_ssh() {
    # Специфика Ubuntu 24.04: переключаемся с socket-activation на классический сервис
    if systemctl is-active --quiet ssh.socket; then
        echo "Переключаем SSH с socket-activation на classic service (Ubuntu 24.04)..."
        systemctl stop ssh.socket
        systemctl disable ssh.socket
        systemctl enable ssh.service
    fi
    systemctl restart ssh || systemctl restart sshd
}

setup_ssh_keys() {
    local target_user="$1"
    local user_home

    if [ "$target_user" = "root" ]; then
        user_home="/root"
    else
        user_home="/home/$target_user"
    fi

    echo "-------------------------------------"
    echo "НАСТРОЙКА SSH КЛЮЧЕЙ ДЛЯ: $target_user"
    echo "1) Сгенерировать новую пару ключей на сервере (вы получите приватный ключ)"
    echo "2) Ввести (вставить) уже существующий Public Key"
    echo "3) Пропустить"

    local choice
    read -rp "Ваш выбор (1-3): " choice

    case "$choice" in
        1)
            mkdir -p "$user_home/.ssh"
            chmod 700 "$user_home/.ssh"
            rm -f "$user_home/.ssh/id_ed25519" "$user_home/.ssh/id_ed25519.pub"

            echo "Генерируем ключи Ed25519..."
            ssh-keygen -t ed25519 -f "$user_home/.ssh/id_ed25519" -C "vps-$target_user" -N "" -q

            cat "$user_home/.ssh/id_ed25519.pub" >> "$user_home/.ssh/authorized_keys"
            chmod 600 "$user_home/.ssh/authorized_keys"
            chown -R "$target_user":"$target_user" "$user_home/.ssh" 2>/dev/null || chown -R "$target_user" "$user_home/.ssh"

            echo ""
            echo "==========================================================="
            echo "!!! СОХРАНИТЕ ЭТОТ ПРИВАТНЫЙ КЛЮЧ ПРЯМО СЕЙЧАС !!!"
            echo "Скопируйте всё между линиями и сохраните в файл"
            echo "==========================================================="
            cat "$user_home/.ssh/id_ed25519"
            echo "==========================================================="
            echo ""
            read -rp "Нажмите Enter, когда сохраните ключ..."
            return 0
            ;;
        2)
            echo "Вставьте ваш публичный ключ (начинается с ssh-rsa или ssh-ed25519):"
            read -r pub_key

            if [[ -z "$pub_key" ]]; then
                echo "Ключ не введен."
                return 1
            fi

            mkdir -p "$user_home/.ssh"
            chmod 700 "$user_home/.ssh"
            echo "$pub_key" >> "$user_home/.ssh/authorized_keys"

            chmod 600 "$user_home/.ssh/authorized_keys"
            chown -R "$target_user":"$target_user" "$user_home/.ssh" 2>/dev/null || chown -R "$target_user" "$user_home/.ssh"

            echo "Публичный ключ добавлен."
            return 0
            ;;
        *)
            echo "Пропуск настройки ключей."
            return 1
            ;;
    esac
}

#####################################
# СЕТЕВЫЕ НАСТРОЙКИ (BBR + IPv6)
#####################################
if prompt_yes_no "Включить TCP BBR и отключить IPv6"; then
    # BBR (проверка по факту наличия параметра bbr)
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        fi
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        echo "TCP BBR добавлен в конфиг."
    fi

    # Disable IPv6
    if ! grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
        echo "IPv6 отключен в конфиге."
    fi

    sysctl --system || sysctl -p || true
    echo "Сетевые настройки применены."
fi

#####################################
# ROOT PASSWORD
#####################################
if prompt_yes_no "Сменить пароль root"; then
    while true; do
        read -rsp "Новый пароль root: " rp; echo
        read -rsp "Повтор: " rp2; echo
        [[ "$rp" == "$rp2" ]] || { echo "Пароли не совпадают"; continue; }
        validate_password "$rp" || { echo "Слабый пароль! Требуется: >=12 симв., заглавные, строчные, цифры и спецсимвол."; continue; }
        echo "root:$rp" | chpasswd
        break
    done
fi

#####################################
# СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ
#####################################
CREATED_USER=""

if prompt_yes_no "Создать обычного пользователя"; then
    read -rp "Имя пользователя: " uname
    if id "$uname" &>/dev/null; then
        echo "Пользователь уже существует"
        CREATED_USER="$uname"
    else
        while true; do
            read -rsp "Пароль для $uname: " up; echo
            read -rsp "Повтор: " up2; echo
            [[ "$up" == "$up2" ]] || { echo "Пароли не совпадают"; continue; }
            validate_password "$up" || { echo "Слабый пароль! Требуется: >=12 симв., заглавные, строчные, цифры и спецсимвол."; continue; }
            
            adduser --disabled-password --gecos "" "$uname"
            echo "$uname:$up" | chpasswd
            break
        done
        usermod -aG sudo "$uname"
        CREATED_USER="$uname"
    fi

    if prompt_yes_no "Разрешить sudo без пароля для $uname"; then
        echo "$uname ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$uname"
        safe_sudoers "$uname"
    fi
fi

#####################################
# НАСТРОЙКА SSH КЛЮЧЕЙ
#####################################
KEYS_INSTALLED=false

if [ -n "$CREATED_USER" ]; then
    if prompt_yes_no "Настроить SSH ключи для пользователя $CREATED_USER"; then
        if setup_ssh_keys "$CREATED_USER"; then
            KEYS_INSTALLED=true
        fi
    fi
else
    if prompt_yes_no "Настроить SSH ключи для ROOT"; then
        if setup_ssh_keys "root"; then
            KEYS_INSTALLED=true
        fi
    fi
fi

#####################################
# SSH HARDENING
#####################################
SSH_PORT="$DEFAULT_SSH_PORT"

if prompt_yes_no "Изменить порт SSH"; then
    while true; do
        read -rp "Новый порт SSH: " p
        validate_port "$p" || { echo "Недопустимый порт"; continue; }
        SSH_PORT="$p"
        break
    done

    sed -i '/^#\?Port /d' /etc/ssh/sshd_config
    echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
    sed -i '/^#\?AddressFamily /d' /etc/ssh/sshd_config
    echo "AddressFamily inet" >> /etc/ssh/sshd_config
fi

if [ "$KEYS_INSTALLED" = true ]; then
    if prompt_yes_no "Отключить вход по паролю (PasswordAuthentication no)?"; then
        sed -i '/^#\?PasswordAuthentication /d' /etc/ssh/sshd_config
        echo "PasswordAuthentication no" >> /etc/ssh/sshd_config

        sed -i '/^#\?KbdInteractiveAuthentication /d' /etc/ssh/sshd_config
        echo "KbdInteractiveAuthentication no" >> /etc/ssh/sshd_config

        sed -i '/^#\?UsePAM /d' /etc/ssh/sshd_config
        echo "UsePAM no" >> /etc/ssh/sshd_config

        echo "Вход по паролю ОТКЛЮЧЕН. Используйте ключи."
    fi
fi

sed -i '/^#\?PubkeyAuthentication /d' /etc/ssh/sshd_config
echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

# Перезапускаем службу (с учетом специфики 24.04)
restart_ssh

#####################################
# UFW (FIREWALL) 
#####################################
apt install -y ufw

sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw

ufw default deny incoming
ufw default allow outgoing

# Блокировка Ping (ICMP) через замену правила по умолчанию в UFW
if [ -f /etc/ufw/before.rules ]; then
    echo "Настройка блокировки ICMP (ping)..."
    sed -i 's/-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/g' /etc/ufw/before.rules
fi

echo "Настраиваем порты (только IPv4)..."

# Корректный синтаксис для UFW под кастомный порт
ufw allow "$SSH_PORT"/tcp comment 'SSH'

# Разрешаем веб-трафик (TCP)
TCP_PORTS=(80 443 8443)
for port in "${TCP_PORTS[@]}"; do
    ufw allow "$port"/tcp
done

# Разрешаем UDP-трафик для Hysteria 2 / TUIC напрямую
UDP_PORTS=(443 8443)
for port in "${UDP_PORTS[@]}"; do
    ufw allow "$port"/udp
done

ufw --force enable

#####################################
# FAIL2BAN (С установкой python3-systemd)
#####################################
apt install -y fail2ban python3-systemd

cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 5
findtime = 10m
bantime = 1h
backend = systemd
EOF

systemctl enable fail2ban
systemctl restart fail2ban

#####################################
# 3X-UI
#####################################
if prompt_yes_no "Установить 3x-ui"; then
    if ! command -v curl &> /dev/null; then
        apt install -y curl
    fi
    echo "Запуск установки 3x-ui"
    # Полностью снимаем strict mode для беспрепятственного выполнения интерактивного внешнего установщика
    set +euo pipefail
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    set -euo pipefail
fi

#####################################
# ФИНАЛ
#####################################
echo
echo "======================================"
echo "✔ PROD НАСТРОЙКА ЗАВЕРШЕНА"
echo "SSH порт: $SSH_PORT"
echo "IPv6: отключён (System + UFW)"
echo "UFW: включён (только v4 правила, входящий Ping заблокирован)"
echo "BBR: активирован"
echo "Fail2ban: активен (backend: systemd)"
if [ "$KEYS_INSTALLED" = true ]; then
    echo "SSH Ключи: УСТАНОВЛЕНЫ"
else
    echo "SSH Ключи: НЕ установлены"
fi
echo "======================================"
echo "ВАЖНО: Пожалуйста, НЕ закрывайте текущую сессию терминала!"
echo "Откройте новое окно терминала на вашем компьютере и попробуйте подключиться:"
if [ -n "$CREATED_USER" ]; then
    echo "  ssh -p $SSH_PORT $CREATED_USER@<IP_ВАШЕГО_СЕРВЕРА>"
else
    echo "  ssh -p $SSH_PORT root@<IP_ВАШЕГО_СЕРВЕРА>"
fi
echo "Убедитесь, что доступ по новому порту успешно работает, прежде чем завершить текущую сессию."
echo "======================================"
