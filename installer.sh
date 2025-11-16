#!/bin/bash
# Paymenter Installer – Hardened & Patched Final Version

# ---------------------------------------------------------
# Strict mode + ERR propagation
# ---------------------------------------------------------
set -e
set -E
set -o pipefail
shopt -s errtrace

# ---------------------------------------------------------
# COLORS
# ---------------------------------------------------------
COLOR_GREEN="\e[32m"
COLOR_RED="\e[31m"
COLOR_YELLOW="\e[33m"
COLOR_BLUE="\e[34m"
COLOR_RESET="\e[0m"

# ---------------------------------------------------------
# ROOT CHECK
# ---------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${COLOR_RED}This script must be run as root.${COLOR_RESET}"
    exit 1
fi

# ---------------------------------------------------------
# LOGGING + ERROR HANDLER
# ---------------------------------------------------------
LOGFILE="/var/log/paymenter-installer-$(date +%F-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

on_error() {
    echo -e "${COLOR_RED}"
    echo "============================================================"
    echo "  ERROR: Installer failed on line: $1"
    echo ""
    echo "  Check the log file:"
    echo "    $LOGFILE"
    echo "============================================================"
    echo -e "${COLOR_RESET}"
    exit 1
}
trap 'on_error ${LINENO}' ERR

# ---------------------------------------------------------
# HEADER
# ---------------------------------------------------------
echo -e "${COLOR_BLUE}"
echo "============================================================"
echo "                 PAYMENTER AUTO INSTALLER"
echo "============================================================"
echo -e "${COLOR_RESET}"

# ---------------------------------------------------------
# GLOBAL VARS
# ---------------------------------------------------------
PAYMENTER_DIR="/var/www/paymenter"
PHP_BIN="$(command -v php || echo /usr/bin/php)"
PHP_FPM_SOCK=""
OS_ID=""
OS_VERSION_ID=""
FINAL_URL=""

# ---------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------

generate_password() {
    openssl rand -hex 16 2>/dev/null || tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

check_disk_space() {
    local required=2000
    local free=$(df -m / | tail -1 | awk '{print $4}')
    if (( free < required )); then
        echo -e "${COLOR_RED}ERROR: Minimum 2GB free space required.${COLOR_RESET}"
        exit 1
    fi
}

detect_os() {
    source /etc/os-release
    OS_ID=$ID
    OS_VERSION_ID=$VERSION_ID
    echo -e "${COLOR_GREEN}Detected OS: $OS_ID $OS_VERSION_ID${COLOR_RESET}"
}

detect_php_socket() {
    PHP_FPM_SOCK=$(find /var/run/php -name "php*-fpm.sock" | head -n 1)
    if [[ -z "$PHP_FPM_SOCK" ]]; then
        echo -e "${COLOR_RED}Could not detect PHP-FPM socket.${COLOR_RESET}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${COLOR_BLUE}Installing dependencies...${COLOR_RESET}"

    if [[ "$OS_ID" == "ubuntu" ]]; then
        apt update
        apt install -y software-properties-common curl apt-transport-https ca-certificates gnupg lsof
        LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

        if [[ "$OS_VERSION_ID" != "24.04" ]]; then
            curl -sSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup \
                | bash -s -- --mariadb-server-version="mariadb-10.11"
        fi

        apt update
        apt install -y php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,redis} \
            mariadb-server nginx tar unzip git redis-server

    elif [[ "$OS_ID" == "debian" ]]; then
        apt update
        apt install -y software-properties-common curl ca-certificates gnupg2 sudo lsb-release lsof

        echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" \
            | tee /etc/apt/sources.list.d/sury-php.list
        
        curl -fsSL https://packages.sury.org/php/apt.gpg \
            | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-keyring.gpg

        apt update
        
        curl -sSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup \
            | bash -s -- --mariadb-server-version="mariadb-10.11"

        apt install -y php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,redis} \
            mariadb-server nginx tar unzip git redis-server
    else
        echo -e "${COLOR_RED}Unsupported OS.${COLOR_RESET}"
        exit 1
    fi

    PHP_BIN="$(command -v php)"
}

check_mysql() {
    echo -e "${COLOR_BLUE}Checking MySQL...${COLOR_RESET}"
    mysql -e "SELECT 1" >/dev/null 2>&1 || {
        echo -e "${COLOR_RED}MySQL root login failed.${COLOR_RESET}"
        exit 1
    }
}

download_paymenter() {
    echo -e "${COLOR_BLUE}Downloading Paymenter...${COLOR_RESET}"

    mkdir -p "$PAYMENTER_DIR"
    cd "$PAYMENTER_DIR"

    curl -fsSL -o paymenter.tar.gz \
        https://github.com/paymenter/paymenter/releases/latest/download/paymenter.tar.gz

    tar -xzf paymenter.tar.gz
    rm -f paymenter.tar.gz
}

setup_database() {
    local esc_pass=$(printf "%s" "$DB_PASS" | sed "s/'/''/g")

    mysql -e "CREATE USER IF NOT EXISTS 'paymenter'@'127.0.0.1' IDENTIFIED BY '${esc_pass}';"
    mysql -e "ALTER USER 'paymenter'@'127.0.0.1' IDENTIFIED BY '${esc_pass}';"
    mysql -e "CREATE DATABASE IF NOT EXISTS paymenter;"
    mysql -e "GRANT ALL PRIVILEGES ON paymenter.* TO 'paymenter'@'127.0.0.1';"
}

write_env() {
    echo -e "${COLOR_BLUE}Configuring .env...${COLOR_RESET}"
    cd "$PAYMENTER_DIR"

    cp -f .env.example .env

    sed -i "s|DB_DATABASE=.*|DB_DATABASE=paymenter|" .env
    sed -i "s|DB_USERNAME=.*|DB_USERNAME=paymenter|" .env
    sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env

    sed -i "s|REDIS_HOST=.*|REDIS_HOST=127.0.0.1|" .env
    sed -i "s|REDIS_PORT=.*|REDIS_PORT=6379|" .env
    sed -i "s|REDIS_PASSWORD=.*|REDIS_PASSWORD=null|" .env

    sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env
    sed -i "s|APP_URL=.*|APP_URL=${FINAL_URL}|" .env

    chmod 640 .env
    chown www-data:www-data .env
}

run_artisan() {
    cd "$PAYMENTER_DIR"

    $PHP_BIN artisan key:generate --force
    $PHP_BIN artisan storage:link || true
    $PHP_BIN artisan migrate --force --seed
    $PHP_BIN artisan db:seed --class=CustomPropertySeeder || true
    $PHP_BIN artisan app:init
}

setup_systemd() {
    cat >/etc/systemd/system/paymenter.service <<EOF
[Unit]
Description=Paymenter Queue Worker
After=network.target

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=${PHP_BIN} ${PAYMENTER_DIR}/artisan queue:work
WorkingDirectory=${PAYMENTER_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now paymenter.service
    systemctl enable --now redis-server
}

setup_cron() {
    local job="* * * * * ${PHP_BIN} ${PAYMENTER_DIR}/artisan schedule:run >/dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v "$job"; echo "$job") | crontab -
}

setup_autoupdate() {
    local job="15 3 * * * cd ${PAYMENTER_DIR} && ${PHP_BIN} artisan app:upgrade >> /var/log/paymenter-upgrade.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "$job"; echo "$job") | crontab -
}

nginx_http() {
    cat >/etc/nginx/sites-available/paymenter.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root ${PAYMENTER_DIR}/public;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:${PHP_FPM_SOCK};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/paymenter.conf /etc/nginx/sites-enabled/

    nginx -t
    systemctl restart nginx
}

install_ssl() {
    apt install -y python3-certbot-nginx
    systemctl stop nginx

    certbot certonly --standalone -d "$DOMAIN"

    [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] || {
        echo -e "${COLOR_RED}SSL generation failed.${COLOR_RESET}"
        exit 1
    }
}

nginx_ssl() {
    cat >/etc/nginx/sites-available/paymenter.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    root ${PAYMENTER_DIR}/public;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:${PHP_FPM_SOCK};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/paymenter.conf /etc/nginx/sites-enabled/

    nginx -t
    systemctl restart nginx
}

show_summary() {
    echo -e "${COLOR_GREEN}"
    echo "============================================================"
    echo " PAYMENTER INSTALLED SUCCESSFULLY!"
    echo ""
    echo " URL: ${FINAL_URL}"
    echo " Directory: ${PAYMENTER_DIR}"
    echo " Installer Log: ${LOGFILE}"
    echo "============================================================"
    echo -e "${COLOR_RESET}"
}

# ---------------------------------------------------------
# INSTALL PROCESS
# ---------------------------------------------------------

install_flow() {
    check_disk_space
    detect_os
    install_dependencies
    detect_php_socket
    check_mysql

    read -rp "Domain (panel.example.com): " DOMAIN

    echo "DB password (hidden, blank = random):"
    read -s -rp "> " DBP
    DB_PASS="${DBP:-$(generate_password)}"
    echo ""

    read -rp "Enable SSL? (y/n): " SSLY
    read -rp "Enable auto-update? (y/n): " UPY

    FINAL_URL="http://${DOMAIN}"

    download_paymenter
    setup_database

    write_env
    run_artisan

    setup_systemd
    setup_cron
    [[ "$UPY" =~ ^[Yy]$ ]] && setup_autoupdate

    if [[ "$SSLY" =~ ^[Yy]$ ]]; then
        install_ssl
        FINAL_URL="https://${DOMAIN}"
        write_env
        nginx_ssl
    else
        nginx_http
    fi

    show_summary
}

# ---------------------------------------------------------
# MENU
# ---------------------------------------------------------
echo "1) Install Paymenter"
echo "2) Upgrade Paymenter"
echo "3) Exit"
read -rp "> " CHOICE

case "$CHOICE" in
1) install_flow ;;
2) cd /var/www/paymenter && php artisan app:upgrade ;;
*) exit 0 ;;
esac
