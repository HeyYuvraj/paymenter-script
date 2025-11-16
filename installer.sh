#!/bin/bash

set -e
set -o pipefail

# --------- basic styling ----------
COLOR_GREEN="\e[32m"
COLOR_RED="\e[31m"
COLOR_YELLOW="\e[33m"
COLOR_BLUE="\e[34m"
COLOR_RESET="\e[0m"

# --------- must be root ----------
if [[ $EUID -ne 0 ]]; then
    echo -e "${COLOR_RED}This script must be run as root.${COLOR_RESET}"
    exit 1
fi

# --------- logging & error trap ----------
LOGFILE="/var/log/paymenter-installer-$(date +%F-%H%M%S).log"
mkdir -p /var/log
exec > >(tee -a "$LOGFILE") 2>&1

on_error() {
    local exit_code=$?
    local line_no=$1
    echo -e "${COLOR_RED}"
    echo "============================================================"
    echo " ERROR: Installation failed on line ${line_no} (exit code ${exit_code})"
    echo " See log file for details:"
    echo "   ${LOGFILE}"
    echo "============================================================"
    echo -e "${COLOR_RESET}"
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

echo -e "${COLOR_BLUE}"
echo "============================================================"
echo "                  Paymenter Installer"
echo "============================================================"
echo -e "${COLOR_RESET}"

PAYMENTER_DIR="/var/www/paymenter"
PHP_BIN="$(command -v php || echo /usr/bin/php)"
PHP_FPM_SOCK=""
OS_ID=""
OS_VERSION_ID=""

# --------- helper functions ----------

pause() {
    read -rp "Press Enter to continue..."
}

generate_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
    fi
}

check_disk_space() {
    local required_mb=2000
    local free_mb
    free_mb=$(df -m / | tail -1 | awk '{print $4}')
    if (( free_mb < required_mb )); then
        echo -e "${COLOR_RED}Not enough disk space. Need at least ${required_mb}MB free on /.${COLOR_RESET}"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_ID=$ID
        OS_VERSION_ID=$VERSION_ID
    else
        echo -e "${COLOR_RED}Could not detect OS. Exiting.${COLOR_RESET}"
        exit 1
    fi
    echo -e "Detected OS: ${COLOR_GREEN}${OS_ID} ${OS_VERSION_ID}${COLOR_RESET}"
}

detect_php_fpm_socket() {
    if [ -S /var/run/php/php8.3-fpm.sock ]; then
        PHP_FPM_SOCK="/var/run/php/php8.3-fpm.sock"
    else
        PHP_FPM_SOCK=$(find /var/run/php -maxdepth 1 -type s -name "php*-fpm.sock" | head -n 1 || true)
    fi

    if [[ -z "$PHP_FPM_SOCK" ]]; then
        echo -e "${COLOR_RED}Could not find a PHP-FPM socket. Ensure php8.3-fpm is installed and running.${COLOR_RESET}"
        exit 1
    fi

    echo -e "Using PHP-FPM socket: ${COLOR_GREEN}${PHP_FPM_SOCK}${COLOR_RESET}"
}

install_dependencies() {
    echo -e "${COLOR_BLUE}Installing dependencies...${COLOR_RESET}"

    if [[ "$OS_ID" == "ubuntu" ]]; then
        apt update
        apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg lsof

        LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

        if [[ "$OS_VERSION_ID" != "24.04" ]]; then
            curl -sSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup \
                | bash -s -- --mariadb-server-version="mariadb-10.11"
        fi

        apt update
        apt -y install php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,redis} \
            mariadb-server nginx tar unzip git redis-server

    elif [[ "$OS_ID" == "debian" ]]; then
        apt update
        apt -y install software-properties-common curl ca-certificates gnupg2 sudo lsb-release lsof

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
        echo -e "${COLOR_RED}Unsupported OS. Only Ubuntu and Debian are supported.${COLOR_RESET}"
        exit 1
    fi

    PHP_BIN="$(command -v php || echo /usr/bin/php)"
}

check_mysql_connection() {
    echo -e "${COLOR_BLUE}Checking MySQL connectivity as root...${COLOR_RESET}"
    if ! mysql -e "SELECT 1" >/dev/null 2>&1; then
        echo -e "${COLOR_RED}Unable to connect to MySQL as root.${COLOR_RESET}"
        echo "Run:  mysql -u root -p   and ensure you can connect, then rerun this script."
        exit 1
    fi
}

setup_paymenter_files() {
    echo -e "${COLOR_BLUE}Downloading Paymenter...${COLOR_RESET}"

    mkdir -p "$PAYMENTER_DIR"
    cd "$PAYMENTER_DIR"

    if ! curl -fsSL -o paymenter.tar.gz \
        https://github.com/paymenter/paymenter/releases/latest/download/paymenter.tar.gz; then
        echo -e "${COLOR_RED}Failed to download Paymenter archive. Check your network or GitHub availability.${COLOR_RESET}"
        exit 1
    fi

    tar -xzvf paymenter.tar.gz
    rm -f paymenter.tar.gz

    chmod -R 755 storage/* bootstrap/cache/ || true
}

setup_database() {
    echo -e "${COLOR_BLUE}Setting up MySQL database...${COLOR_RESET}"

    SQL_DB_PASS=$(printf "%s" "$DB_PASS" | sed "s/'/''/g")

    # If user exists, just update its password & privileges to avoid weird states
    mysql -e "CREATE USER IF NOT EXISTS 'paymenter'@'127.0.0.1' IDENTIFIED BY '${SQL_DB_PASS}';"
    mysql -e "ALTER USER 'paymenter'@'127.0.0.1' IDENTIFIED BY '${SQL_DB_PASS}';"
    mysql -e "CREATE DATABASE IF NOT EXISTS paymenter;"
    mysql -e "GRANT ALL PRIVILEGES ON paymenter.* TO 'paymenter'@'127.0.0.1' WITH GRANT OPTION;"
    mysql -e "FLUSH PRIVILEGES;"
}

configure_env() {
    echo -e "${COLOR_BLUE}Configuring .env...${COLOR_RESET}"
    cd "$PAYMENTER_DIR"

    cp -n .env.example .env

    sed -i '/^DB_DATABASE=/d' .env
    sed -i '/^DB_USERNAME=/d' .env
    sed -i '/^DB_PASSWORD=/d' .env

    {
        printf '%s\n' "DB_DATABASE=paymenter"
        printf '%s\n' "DB_USERNAME=paymenter"
        printf '%s\n' "DB_PASSWORD=${DB_PASS}"
    } >> .env

    chmod 640 .env || true
    chown www-data:www-data .env || true
}

run_artisan_setup() {
    echo -e "${COLOR_BLUE}Running artisan setup...${COLOR_RESET}"
    cd "$PAYMENTER_DIR"

    "$PHP_BIN" artisan key:generate --force
    "$PHP_BIN" artisan storage:link || true

    if ! "$PHP_BIN" artisan migrate --force --seed; then
        echo -e "${COLOR_RED}Artisan migrate/seed failed.${COLOR_RESET}"
        exit 1
    fi

    "$PHP_BIN" artisan db:seed --class=CustomPropertySeeder || true
    "$PHP_BIN" artisan app:init
}

setup_cron() {
    echo -e "${COLOR_BLUE}Configuring cron for scheduler...${COLOR_RESET}"
    CRON_LINE="* * * * * ${PHP_BIN} ${PAYMENTER_DIR}/artisan schedule:run >> /dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v -F "$CRON_LINE" ; echo "$CRON_LINE") | crontab -
}

setup_auto_update_cron() {
    echo -e "${COLOR_BLUE}Configuring optional automatic updates (daily)...${COLOR_RESET}"
    UPDATE_LINE="15 3 * * * cd ${PAYMENTER_DIR} && ${PHP_BIN} artisan app:upgrade >> /var/log/paymenter-upgrade.log 2>&1"
    (crontab -l 2>/dev/null | grep -v -F "$UPDATE_LINE" ; echo "$UPDATE_LINE") | crontab -
}

setup_systemd() {
    echo -e "${COLOR_BLUE}Creating systemd service...${COLOR_RESET}"

    cat >/etc/systemd/system/paymenter.service <<EOF
[Unit]
Description=Paymenter Queue Worker
After=network.target

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=${PHP_BIN} ${PAYMENTER_DIR}/artisan queue:work
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s
WorkingDirectory=${PAYMENTER_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now paymenter.service
    systemctl enable --now redis-server
}

setup_nginx_http_only() {
    echo -e "${COLOR_BLUE}Creating Nginx HTTP (non-SSL) config...${COLOR_RESET}"

    cat >/etc/nginx/sites-available/paymenter.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${PAYMENTER_DIR}/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ ^/index\.php(/|$) {
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/paymenter.conf /etc/nginx/sites-enabled/paymenter.conf
    rm -f /etc/nginx/sites-enabled/default || true

    if ! nginx -t; then
        echo -e "${COLOR_RED}Nginx configuration test failed. Check /etc/nginx/sites-available/paymenter.conf.${COLOR_RESET}"
        exit 1
    fi
    systemctl restart nginx
}

install_certbot_and_ssl() {
    echo -e "${COLOR_BLUE}Installing Certbot and requesting certificate...${COLOR_RESET}"
    apt install -y python3-certbot-nginx

    echo -e "${COLOR_BLUE}Checking that port 80 is free...${COLOR_RESET}"
    if lsof -i:80 >/dev/null 2>&1; then
        echo -e "${COLOR_RED}Port 80 is in use. Stop any services using port 80 and rerun.${COLOR_RESET}"
        exit 1
    fi

    systemctl stop nginx || true
    if ! certbot certonly --standalone -d "${DOMAIN}"; then
        echo -e "${COLOR_RED}Certbot failed to obtain a certificate for ${DOMAIN}.${COLOR_RESET}"
        exit 1
    fi

    if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
        echo -e "${COLOR_RED}SSL certificate files not found for ${DOMAIN}.${COLOR_RESET}"
        exit 1
    fi

    RENEW_LINE="0 23 * * * certbot renew --quiet --deploy-hook 'systemctl restart nginx'"
    (crontab -l 2>/dev/null | grep -v -F "$RENEW_LINE" ; echo "$RENEW_LINE") | crontab -
}

setup_nginx_ssl() {
    echo -e "${COLOR_BLUE}Creating Nginx HTTPS config...${COLOR_RESET}"

    cat >/etc/nginx/sites-available/paymenter.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};
    root ${PAYMENTER_DIR}/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;
    charset utf-8;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ ^/index\.php(/|$) {
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/paymenter.conf /etc/nginx/sites-enabled/paymenter.conf
    rm -f /etc/nginx/sites-enabled/default || true

    if ! nginx -t; then
        echo -e "${COLOR_RED}Nginx configuration test failed. Check /etc/nginx/sites-available/paymenter.conf.${COLOR_RESET}"
        exit 1
    fi

    pkill -9 nginx || true
    systemctl restart nginx
}

fix_permissions() {
    echo -e "${COLOR_BLUE}Fixing permissions...${COLOR_RESET}"
    chown -R www-data:www-data "${PAYMENTER_DIR}"
}

show_summary() {
    echo -e "${COLOR_GREEN}"
    echo "============================================================"
    echo " Paymenter installation completed!"
    echo ""
    echo " URL: ${FINAL_URL}"
    echo " DB Name: paymenter"
    echo " DB User: paymenter"
    echo " (DB password was set securely and stored in .env)"
    echo ""
    echo " Directory: ${PAYMENTER_DIR}"
    echo " Log file: ${LOGFILE}"
    echo "============================================================"
    echo -e "${COLOR_RESET}"
}

upgrade_paymenter() {
    if [ ! -d "${PAYMENTER_DIR}" ]; then
        echo -e "${COLOR_RED}Paymenter does not appear to be installed in ${PAYMENTER_DIR}.${COLOR_RESET}"
        exit 1
    fi

    echo -e "${COLOR_BLUE}Running Paymenter upgrade...${COLOR_RESET}"
    cd "${PAYMENTER_DIR}"
    "$PHP_BIN" artisan app:upgrade

    echo -e "${COLOR_GREEN}Upgrade completed successfully.${COLOR_RESET}"
}

# --------- main flows ----------

install_flow() {
    check_disk_space
    detect_os
    install_dependencies
    detect_php_fpm_socket
    check_mysql_connection

    echo ""
    read -rp "Enter your domain (example: panel.example.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${COLOR_RED}Domain cannot be empty.${COLOR_RESET}"
        exit 1
    fi

    echo ""
    echo "Enter MySQL password for user 'paymenter'."
    echo "(leave blank to auto-generate; input will be hidden)"
    read -s -rp "Password: " DB_PASS_INPUT
    echo ""
    if [ -z "$DB_PASS_INPUT" ]; then
        DB_PASS=$(generate_password)
        # Do NOT echo the generated password
    else
        DB_PASS="$DB_PASS_INPUT"
    fi

    echo ""
    read -rp "Use SSL with Let's Encrypt? (y/n): " SSL_CHOICE

    echo ""
    read -rp "Enable automatic daily updates (php artisan app:upgrade)? (y/n): " AUTO_UPDATE_CHOICE

    setup_paymenter_files
    setup_database
    configure_env
    run_artisan_setup
    setup_cron
    setup_systemd
    fix_permissions

    if [[ "$AUTO_UPDATE_CHOICE" =~ ^[Yy]$ ]]; then
        setup_auto_update_cron
    fi

    if [[ "$SSL_CHOICE" =~ ^[Yy]$ ]]; then
        install_certbot_and_ssl
        setup_nginx_ssl
        FINAL_URL="https://${DOMAIN}"
    else
        setup_nginx_http_only
        FINAL_URL="http://${DOMAIN}"
    fi

    fix_permissions
    show_summary
}

# --------- menu ----------

echo "Choose an action:"
echo "  1) Install Paymenter"
echo "  2) Upgrade existing Paymenter (php artisan app:upgrade)"
echo "  3) Exit"
read -rp "Select an option [1-3]: " ACTION

case "$ACTION" in
    1)
        install_flow
        ;;
    2)
        upgrade_paymenter
        ;;
    3)
        echo "Exiting."
        exit 0
        ;;
    *)
        echo -e "${COLOR_RED}Invalid option.${COLOR_RESET}"
        exit 1
        ;;
esac
