#!/usr/bin/env bash
set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
INSTALL_DIR="${INSTALL_DIR:-/opt/meridian}"
DATA_DIR="${DATA_DIR:-/opt/meridian/data}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/wooogoblin/meridian-mtproto-panel/main}"
PROXY_PORT="${PROXY_PORT:-2443}"
USE_DECOY="${USE_DECOY:-false}"
PANEL_SECRET=""
MENU_MODE=false

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[96m'
YELLOW='\033[1;33m'; GRAY='\033[0;90m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}▸${NC} $*"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "${RED}✘${NC} $*" >&2; exit 1; }
hr()   { echo -e "${GRAY}──────────────────────────────────────────────────────${NC}"; }

require_root() {
    [[ $EUID -eq 0 ]] || { echo -e "${RED}✘${NC} Нужен root. Запусти через sudo." >&2; exit 1; }
}

# ── Logo & Menu ────────────────────────────────────────────────────────────────
show_logo() {
    echo ""
    echo -e "${CYAN}  ███╗   ███╗███████╗██████╗ ██╗██████╗ ██╗ █████╗ ███╗   ██╗${NC}"
    echo -e "${CYAN}  ████╗ ████║██╔════╝██╔══██╗██║██╔══██╗██║██╔══██╗████╗  ██║${NC}"
    echo -e "${CYAN}  ██╔████╔██║█████╗  ██████╔╝██║██║  ██║██║███████║██╔██╗ ██║${NC}"
    echo -e "${CYAN}  ██║╚██╔╝██║██╔══╝  ██╔══██╗██║██║  ██║██║██╔══██║██║╚██╗██║${NC}"
    echo -e "${CYAN}  ██║ ╚═╝ ██║███████╗██║  ██║██║██████╔╝██║██║  ██║██║ ╚████║${NC}"
    echo -e "${CYAN}  ╚═╝     ╚═╝╚══════╝╚═╝  ╚═╝╚═╝╚═════╝ ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝${NC}"
    echo -e "${GRAY}                    MTProto proxy + управление${NC}"
    echo ""
}

_pause() {
    echo ""
    printf "  Нажми Enter чтобы вернуться в меню…" >/dev/tty
    read -r </dev/tty 2>/dev/null || true
}

show_menu() {
    MENU_MODE=true
    while true; do
        clear
        show_logo

        local installed=false running=false
        { [[ -f "$INSTALL_DIR/.installed" ]] || [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; } && installed=true || true
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^nginx$' && running=true || true

        hr
        if $running; then
            echo -e "  Статус: ${GREEN}●${NC} работает  ${GRAY}(${INSTALL_DIR})${NC}"
        elif $installed; then
            echo -e "  Статус: ${YELLOW}●${NC} установлено, не запущено  ${GRAY}(${INSTALL_DIR})${NC}"
        else
            echo -e "  Статус: ${GRAY}○${NC} не установлено"
        fi
        hr
        echo ""

        if $installed; then
            echo -e "  ${YELLOW}[1]${NC}  Переустановить"
            echo -e "  ${GREEN}[2]${NC}  Обновить"
            echo -e "  ${GREEN}[3]${NC}  Сбросить пароль"
            echo -e "  ${RED}[4]${NC}  Удалить"
        else
            echo -e "  ${GREEN}[1]${NC}  Установить"
            echo -e "  ${GRAY}[2]  Обновить${NC}"
            echo -e "  ${GRAY}[3]  Сбросить пароль${NC}"
            echo -e "  ${GRAY}[4]  Удалить${NC}"
        fi
        echo ""
        echo -e "  ${BOLD}[0]${NC}  Выход"
        echo ""
        hr
        echo ""

        local choice
        printf "  Выбор: " >/dev/tty
        read -r choice </dev/tty 2>/dev/null || choice="0"
        choice=$(echo "${choice}" | tr -cd '0-9a-zA-Z')
        choice="${choice:-0}"

        case "$choice" in
            1)
                echo ""
                cmd_install
                _pause
                ;;
            2)
                if $installed; then
                    echo ""
                    cmd_update
                    _pause
                else
                    warn "Сначала нужно установить (пункт 1)"
                    sleep 2
                fi
                ;;
            3)
                if $installed; then
                    echo ""
                    cmd_reset_password
                    _pause
                else
                    warn "Сначала нужно установить (пункт 1)"
                    sleep 2
                fi
                ;;
            4)
                if $installed; then
                    echo ""
                    cmd_uninstall
                    break
                else
                    warn "Сначала нужно установить (пункт 1)"
                    sleep 2
                fi
                ;;
            0|"")
                echo ""
                break
                ;;
            *)
                warn "Неверный выбор: ${choice}"
                sleep 1
                ;;
        esac
    done
}

# ── Docker ─────────────────────────────────────────────────────────────────────
install_docker() {
    if ! command -v docker &>/dev/null; then
        info "Устанавливаю Docker (1-2 минуты)…"
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh >/tmp/docker-install.log 2>&1 \
            || { cat /tmp/docker-install.log; rm -f /tmp/get-docker.sh; fail "Не удалось установить Docker"; }
        rm -f /tmp/get-docker.sh /tmp/docker-install.log
        ok "Docker установлен"
    else
        ok "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"
    fi

    if ! docker compose version &>/dev/null; then
        info "Устанавливаю docker compose plugin…"
        apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || {
            apt-get update -qq
            apt-get install -y -qq ca-certificates curl gnupg >/dev/null 2>&1
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
                | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
            chmod a+r /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
                > /etc/apt/sources.list.d/docker.list
            apt-get update -qq
            apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 \
                || fail "Не удалось установить docker-compose-plugin"
        }
        ok "docker compose plugin установлен"
    else
        ok "Docker Compose: $(docker compose version --short)"
    fi
}

install_system_deps() {
    local pkgs=()
    command -v xxd     &>/dev/null || pkgs+=(xxd)
    command -v dig     &>/dev/null || pkgs+=(dnsutils)
    command -v openssl &>/dev/null || pkgs+=(openssl)
    command -v python3 &>/dev/null || pkgs+=(python3 python3-pip)

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        info "Устанавливаю зависимости: ${pkgs[*]}…"
        apt-get update -qq
        apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1 \
            || fail "Не удалось установить: ${pkgs[*]}"
    fi
    ok "Системные зависимости готовы"
}

install_python_deps() {
    local venv="$DATA_DIR/.venv"
    mkdir -p "$DATA_DIR"
    if [[ ! -f "$venv/bin/pip" ]]; then
        apt-get install -y -qq python3-venv >/dev/null 2>&1 \
            || fail "Не удалось установить python3-venv"
        python3 -m venv "$venv" \
            || fail "Не удалось создать Python venv"
    fi
    "$venv/bin/pip" install --quiet --upgrade bcrypt 2>/dev/null || {
        apt-get install -y -qq build-essential python3-dev >/dev/null 2>&1
        "$venv/bin/pip" install --quiet bcrypt
    }
    ok "Python venv + bcrypt готовы"
}

# ── SNI domain ─────────────────────────────────────────────────────────────────
select_sni() {
    local env_domain="${FAKE_TLS_DOMAIN:-}"
    FAKE_TLS_DOMAIN=""
    USE_DECOY=false
    if ! $MENU_MODE && [[ -n "$env_domain" ]]; then
        FAKE_TLS_DOMAIN="$env_domain"
        ok "SNI домен (из env): ${BOLD}${FAKE_TLS_DOMAIN}${NC}"
        return
    fi

    echo ""
    echo -e "${BOLD} Выбери домен маскировки (SNI):${NC}"
    echo ""
    echo -e "  При DPI-проверке Teleproxy прозрачно проксирует соединение на реальный сайт."
    echo ""
    echo -e "  ${CYAN}Популярные RU-домены:${NC}"
    echo "    1) ya.ru           3) gosuslugi.ru    5) wildberries.ru"
    echo "    2) sberbank.ru     4) mail.ru         6) ozon.ru"
    echo ""
    echo -e "  ${CYAN}Международные:${NC}"
    echo "    7) www.google.com  8) www.microsoft.com"
    echo ""
    echo -e "  ${YELLOW}0) Ввести свой домен${NC}  ${GRAY}(установит маскировочный сайт)${NC}"
    echo ""

    local choice
    while true; do
        printf "  Выбор (Enter = 1): " >/dev/tty
        read -r choice </dev/tty || choice="1"
        choice=$(echo "${choice:-1}" | tr -cd '0-9a-zA-Z')
        choice="${choice:-1}"
        case "$choice" in
            1) FAKE_TLS_DOMAIN="ya.ru";             break ;;
            2) FAKE_TLS_DOMAIN="sberbank.ru";        break ;;
            3) FAKE_TLS_DOMAIN="gosuslugi.ru";       break ;;
            4) FAKE_TLS_DOMAIN="mail.ru";            break ;;
            5) FAKE_TLS_DOMAIN="wildberries.ru";     break ;;
            6) FAKE_TLS_DOMAIN="ozon.ru";            break ;;
            7) FAKE_TLS_DOMAIN="www.google.com";     break ;;
            8) FAKE_TLS_DOMAIN="www.microsoft.com";  break ;;
            0)
                printf "  Введи домен: " >/dev/tty
                read -r FAKE_TLS_DOMAIN </dev/tty
                FAKE_TLS_DOMAIN=$(echo "$FAKE_TLS_DOMAIN" | tr -cd 'a-zA-Z0-9.\-')
                [[ -n "$FAKE_TLS_DOMAIN" ]] || { warn "Домен не может быть пустым"; continue; }
                if ! echo "$FAKE_TLS_DOMAIN" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$'; then
                    warn "Некорректный домен: $FAKE_TLS_DOMAIN"; continue
                fi
                USE_DECOY=true
                break ;;
            *) warn "Неверный выбор: $choice" ;;
        esac
    done

    ok "SNI домен: ${BOLD}${FAKE_TLS_DOMAIN}${NC}"
    $USE_DECOY && ok "Режим: с маскировочный сайтом" || true
}

get_server_ip() {
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me \
        || curl -s --max-time 5 api.ipify.org \
        || curl -s --max-time 5 icanhazip.com \
        || echo "")
    [[ -n "$SERVER_IP" ]] || fail "Не удалось определить внешний IP сервера"
    ok "IP сервера: ${SERVER_IP}"
}

# ── Panel secret ───────────────────────────────────────────────────────────────
generate_panel_secret() {
    if [[ -f "$DATA_DIR/config.json" ]]; then
        local existing
        existing=$(python3 -c "import json; d=json.load(open('$DATA_DIR/config.json')); print(d.get('panel_path','').lstrip('/'))" 2>/dev/null || true)
        if [[ -n "$existing" ]]; then
            PANEL_SECRET="$existing"
            ok "Путь панели сохранён: /${PANEL_SECRET}/"
            return
        fi
    fi
    PANEL_SECRET=$(openssl rand -hex 8)
    ok "Путь панели: /${PANEL_SECRET}/"
}

# ── TLS certificate ────────────────────────────────────────────────────────────
setup_cert_silent() {
    local cert_dir="$INSTALL_DIR/certs"
    mkdir -p "$cert_dir"
    if [[ -f "$cert_dir/fullchain.pem" ]]; then
        ok "Сертификат уже есть — переиспользую"
        return
    fi
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$cert_dir/privkey.pem" \
        -out    "$cert_dir/fullchain.pem" \
        -subj   "/CN=${SERVER_IP}" 2>/dev/null
    chmod 600 "$cert_dir/privkey.pem"
    ok "Self-signed сертификат сгенерирован"
}

setup_cert() {
    local domain="$1"
    local cert_dir="$INSTALL_DIR/certs"
    mkdir -p "$cert_dir"

    if [[ -f "$cert_dir/fullchain.pem" ]]; then
        local expiry days_left
        expiry=$(openssl x509 -enddate -noout -in "$cert_dir/fullchain.pem" | cut -d= -f2)
        days_left=$(( ( $(date -d "$expiry" +%s 2>/dev/null || date +%s) - $(date +%s) ) / 86400 ))
        if (( days_left > 30 )); then
            local issuer subject
            issuer=$(openssl x509 -noout -issuer -in "$cert_dir/fullchain.pem" 2>/dev/null || true)
            subject=$(openssl x509 -noout -subject -in "$cert_dir/fullchain.pem" 2>/dev/null || true)
            if [[ "$issuer" == "$subject" ]]; then
                info "Найден self-signed сертификат — пробую получить Let's Encrypt…"
                rm -f "$cert_dir/fullchain.pem" "$cert_dir/privkey.pem"
            else
                ok "Сертификат действителен ещё ${days_left} дней — переиспользую"
                return
            fi
        fi
    fi

    local dig_ip
    dig_ip=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' | tail -1 || true)

    if [[ "$dig_ip" == "$SERVER_IP" ]]; then
        info "DNS совпадает — пробую Let's Encrypt…"
        local email=""
        if [[ -z "${LETSENCRYPT_EMAIL:-}" ]]; then
            printf "  Email для Let's Encrypt (Enter — без email): " >/dev/tty
            read -r email </dev/tty 2>/dev/null || true
        else
            email="${LETSENCRYPT_EMAIL:-}"
        fi

        if apt-get install -y -qq certbot >/dev/null 2>&1; then
            local le_args=(certonly --standalone --non-interactive --agree-tos -d "$domain")
            [[ -n "$email" ]] && le_args+=(--email "$email") \
                              || le_args+=(--register-unsafely-without-email)

            if certbot "${le_args[@]}" >/dev/null 2>&1; then
                cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$cert_dir/fullchain.pem"
                cp "/etc/letsencrypt/live/$domain/privkey.pem"   "$cert_dir/privkey.pem"
                chmod 600 "$cert_dir/privkey.pem"
                ok "Let's Encrypt сертификат получен"
                setup_certbot_cron "$domain" "$cert_dir"
                return
            fi
        fi
        warn "Let's Encrypt не удался — генерирую self-signed"
    else
        info "DNS ${domain} → ${dig_ip:-не резолвится} (сервер: ${SERVER_IP}) — self-signed"
    fi

    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "$cert_dir/privkey.pem" \
        -out    "$cert_dir/fullchain.pem" \
        -subj   "/CN=${domain}" \
        -addext "subjectAltName=DNS:${domain}" 2>/dev/null
    chmod 600 "$cert_dir/privkey.pem"
    ok "Self-signed сертификат сгенерирован (10 лет)"
}

setup_certbot_cron() {
    local domain="$1" cert_dir="$2"
    local reload_target
    $USE_DECOY && reload_target="decoy" || reload_target="nginx"
    local hook="cp /etc/letsencrypt/live/${domain}/fullchain.pem ${cert_dir}/fullchain.pem && \
cp /etc/letsencrypt/live/${domain}/privkey.pem ${cert_dir}/privkey.pem && \
docker exec ${reload_target} nginx -s reload"
    ( crontab -l 2>/dev/null | grep -v "certbot renew"
      echo "0 3 * * 0 certbot renew --quiet --deploy-hook '${hook}'" ) | crontab -
}

# ── Credentials ────────────────────────────────────────────────────────────────
generate_credentials() {
    USERNAME=$(openssl rand -hex 4)
    PASSWORD=$(openssl rand -hex 6)
    BCRYPT_HASH=$("$DATA_DIR/.venv/bin/python3" -c \
        "import bcrypt; print(bcrypt.hashpw(b'${PASSWORD}', bcrypt.gensalt(12)).decode())")
    JWT_SECRET=$(openssl rand -hex 32)
}

save_config() {
    # Preserve existing panel_path when called from contexts that don't set PANEL_SECRET
    if [[ -z "${PANEL_SECRET:-}" && -f "$DATA_DIR/config.json" ]]; then
        PANEL_SECRET=$(python3 -c "import json; d=json.load(open('$DATA_DIR/config.json')); print(d.get('panel_path','').lstrip('/'))" 2>/dev/null || true)
    fi
    [[ -z "${PANEL_SECRET:-}" ]] && PANEL_SECRET=$(openssl rand -hex 8)

    cat > "$DATA_DIR/config.json" <<EOF
{
  "username": "${USERNAME}",
  "password_hash": "${BCRYPT_HASH}",
  "jwt_secret": "${JWT_SECRET}",
  "panel_path": "/${PANEL_SECRET}"
}
EOF
    chmod 600 "$DATA_DIR/config.json"
}

# ── File downloads ─────────────────────────────────────────────────────────────
download_backend() {
    local dest="$INSTALL_DIR/backend"
    mkdir -p "$dest"
    info "Скачиваю backend…"
    for f in Dockerfile requirements.txt main.py auth.py users.py teleproxy_config.py; do
        curl -fsSL "${REPO_BASE}/panel/backend/${f}" -o "$dest/$f" \
            || fail "Не удалось скачать backend/${f}"
    done
    ok "Backend скачан"
}

download_frontend() {
    local html_dir="$INSTALL_DIR/html"
    mkdir -p "$html_dir/panel/assets"
    info "Скачиваю фронтенд…"

    curl -fsSL "${REPO_BASE}/panel/login/index.html" -o "$html_dir/index.html" \
        || fail "Не удалось скачать login page"

    local tmp_index
    tmp_index=$(mktemp)
    curl -fsSL "${REPO_BASE}/panel/dist/index.html" -o "$tmp_index" \
        || fail "Не удалось скачать panel/dist/index.html (убедись что dist собран и запушен)"

    local assets
    assets=$(grep -oE 'assets/[A-Za-z0-9._-]+\.(js|css)' "$tmp_index" | sort -u)
    [[ -n "$assets" ]] || fail "Ассеты не найдены в panel/dist/index.html"

    while IFS= read -r asset; do
        [[ -z "$asset" ]] && continue
        curl -fsSL "${REPO_BASE}/panel/dist/${asset}" -o "$html_dir/panel/${asset}" \
            || fail "Не удалось скачать ${asset}"
    done <<< "$assets"

    cp "$tmp_index" "$html_dir/panel/index.html"
    rm -f "$tmp_index"
    chmod -R a+rX "$html_dir"
    ok "Фронтенд скачан"
}

download_frontend_update() {
    local html_dir="$INSTALL_DIR/html"
    mkdir -p "$html_dir/panel/assets"

    curl -fsSL "${REPO_BASE}/panel/login/index.html" -o "$html_dir/index.html" \
        || fail "Не удалось скачать login page"

    local tmp_index
    tmp_index=$(mktemp)
    curl -fsSL "${REPO_BASE}/panel/dist/index.html" -o "$tmp_index" \
        || fail "Не удалось скачать panel/dist/index.html"

    local new_assets
    new_assets=$(grep -oE 'assets/[A-Za-z0-9._-]+\.(js|css)' "$tmp_index" | sort -u)
    [[ -n "$new_assets" ]] || fail "Ассеты не найдены в panel/dist/index.html"

    local old_assets
    old_assets=$(find "$html_dir/panel/assets" -maxdepth 1 -type f \( -name "*.js" -o -name "*.css" \) \
        -printf "assets/%f\n" 2>/dev/null | sort -u || true)

    while IFS= read -r asset; do
        [[ -z "$asset" ]] && continue
        curl -fsSL "${REPO_BASE}/panel/dist/${asset}" -o "$html_dir/panel/${asset}" \
            || fail "Не удалось скачать ${asset}"
    done <<< "$new_assets"

    cp "$tmp_index" "$html_dir/panel/index.html"
    rm -f "$tmp_index"

    if [[ -n "$old_assets" ]]; then
        while IFS= read -r old_f; do
            [[ -z "$old_f" ]] && continue
            grep -qF "$old_f" <<< "$new_assets" || {
                rm -f "$html_dir/panel/${old_f}"
                warn "Удалён устаревший ассет: ${old_f}"
            }
        done <<< "$old_assets"
    fi

    chmod -R a+rX "$html_dir"
    ok "Фронтенд обновлён"
}

download_decoy() {
    local dest="$INSTALL_DIR/decoy/html"
    mkdir -p "$dest"
    info "Скачиваю маскировочный сайт…"
    curl -fsSL "${REPO_BASE}/panel/decoy/index.html" -o "$dest/index.html" \
        || fail "Не удалось скачать panel/decoy/index.html"
    sed -i "s|__DECOY_DOMAIN__|${FAKE_TLS_DOMAIN}|g" "$dest/index.html"
    ok "Decoy скачан"
}

# ── Config generation ──────────────────────────────────────────────────────────
generate_nginx_conf() {
    if $USE_DECOY; then
        # Mode 2: stream-only, TCP passthrough — default → decoy:443
        cat > "$INSTALL_DIR/nginx.conf" <<EOF
events {}

stream {
    resolver 127.0.0.11 valid=10s ipv6=off;
    map \$ssl_preread_server_name \$backend {
        ${FAKE_TLS_DOMAIN}  mtproto:${PROXY_PORT};
        default             decoy:443;
    }
    server {
        listen      443;
        ssl_preread on;
        proxy_pass  \$backend;
    }
}
EOF
    else
        # Mode 1: stream + http, panel at secret path
        cat > "$INSTALL_DIR/nginx.conf" <<EOF
events {}

stream {
    resolver 127.0.0.11 valid=10s ipv6=off;
    map \$ssl_preread_server_name \$backend {
        ${FAKE_TLS_DOMAIN}  mtproto:${PROXY_PORT};
        default             127.0.0.1:8443;
    }
    server {
        listen      443;
        ssl_preread on;
        proxy_pass  \$backend;
    }
}

http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;

    server {
        listen 8443 ssl;
        http2  on;
        ssl_certificate     /etc/nginx/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/privkey.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;
        ssl_prefer_server_ciphers on;
        server_tokens off;
        port_in_redirect  off;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Content-Type-Options    "nosniff" always;
        add_header X-Frame-Options           "DENY" always;
        add_header Referrer-Policy           "strict-origin-when-cross-origin" always;

        location /${PANEL_SECRET}/ {
            auth_request     /auth-check;
            error_page 401 = @login_redirect;
            alias /usr/share/nginx/html/panel/;
            index index.html;
            try_files \$uri \$uri/ /${PANEL_SECRET}/index.html;
        }

        location /${PANEL_SECRET}/login/ {
            root /usr/share/nginx/html;
            try_files /index.html =404;
        }

        location = /auth-check {
            internal;
            proxy_pass              http://meridian-backend:8000/api/v1/auth/me;
            proxy_pass_request_body off;
            proxy_set_header        Content-Length "";
            proxy_set_header        Cookie \$http_cookie;
        }

        location @login_redirect { return 302 /${PANEL_SECRET}/login/; }

        location /api/ {
            proxy_pass         http://meridian-backend:8000;
            proxy_http_version 1.1;
            proxy_set_header   Host              \$host;
            proxy_set_header   X-Real-IP         \$remote_addr;
            proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto \$scheme;
            proxy_read_timeout 30s;
        }

        location / { return 404; }
    }
}
EOF
    fi
}

generate_decoy_nginx_conf() {
    mkdir -p "$INSTALL_DIR/decoy"
    cat > "$INSTALL_DIR/decoy/nginx.conf" <<EOF
server {
    listen 443 ssl;
    http2  on;
    ssl_certificate     /certs/fullchain.pem;
    ssl_certificate_key /certs/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    server_tokens off;

    root /html/decoy;

    location /${PANEL_SECRET}/ {
        auth_request     /auth-check;
        error_page 401 = @login_redirect;
        alias /html/panel/;
        index index.html;
        try_files \$uri \$uri/ /${PANEL_SECRET}/index.html;
    }

    location /${PANEL_SECRET}/login/ {
        root /html/login;
        try_files /index.html =404;
    }

    location = /auth-check {
        internal;
        proxy_pass              http://meridian-backend:8000/api/v1/auth/me;
        proxy_pass_request_body off;
        proxy_set_header        Content-Length "";
        proxy_set_header        Cookie \$http_cookie;
    }

    location @login_redirect { return 302 /${PANEL_SECRET}/login/; }

    location /api/ {
        proxy_pass         http://meridian-backend:8000;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 30s;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
}

generate_docker_compose() {
    if $USE_DECOY; then
        cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  nginx:
    image: nginx:latest
    container_name: nginx
    restart: unless-stopped
    ports:
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - decoy
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}

  decoy:
    image: nginx:alpine
    container_name: decoy
    restart: unless-stopped
    volumes:
      - ./decoy/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./decoy/html:/html/decoy:ro
      - ./html/panel:/html/panel:ro
      - ./html/index.html:/html/login/index.html:ro
      - ./certs:/certs:ro
    expose:
      - "443"
    networks:
      default:
        aliases:
          - ${FAKE_TLS_DOMAIN}
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}

  mtproto:
    image: ghcr.io/teleproxy/teleproxy:latest
    container_name: mtproto
    restart: unless-stopped
    env_file: ./mtproto.env
    volumes:
      - ./teleproxy-data:/opt/teleproxy/data
    expose:
      - "${PROXY_PORT}"
    ulimits:
      nofile: {soft: 65536, hard: 65536}
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}

  meridian-backend:
    build: ./backend
    container_name: meridian-backend
    restart: unless-stopped
    environment:
      DATA_DIR: /data
      MTPROTO_ENV_PATH: /mtproto/.env
      TOML_PATH: /teleproxy/config.toml
      SERVER_IP: "${SERVER_IP}"
      EE_DOMAIN_RAW: "${FAKE_TLS_DOMAIN}"
    volumes:
      - ${DATA_DIR}:/data
      - ./mtproto.env:/mtproto/.env
      - ./teleproxy-data:/teleproxy
      - /var/run/docker.sock:/var/run/docker.sock
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}

networks:
  default:
    name: proxy
EOF
    else
        cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  nginx:
    image: nginx:latest
    container_name: nginx
    restart: unless-stopped
    ports:
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./html:/usr/share/nginx/html:ro
      - ./certs:/etc/nginx/certs:ro
    depends_on:
      - meridian-backend
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}

  mtproto:
    image: ghcr.io/teleproxy/teleproxy:latest
    container_name: mtproto
    restart: unless-stopped
    env_file: ./mtproto.env
    volumes:
      - ./teleproxy-data:/opt/teleproxy/data
    expose:
      - "${PROXY_PORT}"
    ulimits:
      nofile: {soft: 65536, hard: 65536}
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}

  meridian-backend:
    build: ./backend
    container_name: meridian-backend
    restart: unless-stopped
    environment:
      DATA_DIR: /data
      MTPROTO_ENV_PATH: /mtproto/.env
      TOML_PATH: /teleproxy/config.toml
      SERVER_IP: "${SERVER_IP}"
      EE_DOMAIN_RAW: "${FAKE_TLS_DOMAIN}"
    volumes:
      - ${DATA_DIR}:/data
      - ./mtproto.env:/mtproto/.env
      - ./teleproxy-data:/teleproxy
      - /var/run/docker.sock:/var/run/docker.sock
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}

networks:
  default:
    name: proxy
EOF
    fi
}

generate_mtproto_env() {
    # Mode 2 (decoy): teleproxy DRS connects to FAKE_TLS_DOMAIN:443 (decoy container via Docker alias)
    # Mode 1 (standard SNI): keep legacy 8443 — external domain DRS silently fails anyway
    local ee_port
    $USE_DECOY && ee_port=443 || ee_port=8443
    if [[ ! -f "$INSTALL_DIR/mtproto.env" ]]; then
        cat > "$INSTALL_DIR/mtproto.env" <<EOF
EE_DOMAIN=${FAKE_TLS_DOMAIN}:${ee_port}
PORT=${PROXY_PORT}
STATS_PORT=8888
EOF
        ok "MTProto env готов"
    else
        sed -i "s|^EE_DOMAIN=.*|EE_DOMAIN=${FAKE_TLS_DOMAIN}:${ee_port}|" "$INSTALL_DIR/mtproto.env"
        ok "mtproto.env обновлён"
    fi
}

generate_initial_toml() {
    local toml="$INSTALL_DIR/teleproxy-data/config.toml"
    [[ -f "$toml" ]] && return
    cat > "$toml" <<EOF
port = ${PROXY_PORT}
stats_port = 8888
http_stats = true
workers = 1
maxconn = 10000
user = "teleproxy"
EOF
}

# ── Commands ───────────────────────────────────────────────────────────────────
cmd_install() {
    if [[ -f "$INSTALL_DIR/.installed" ]]; then
        warn "Переустановка: логин, пароль и секретный путь панели будут сброшены."
        warn "Пользователи и их MTProto-секреты сохранятся."
        echo ""
        local ans
        printf "  Продолжить? [y/N] " >/dev/tty
        read -r ans </dev/tty 2>/dev/null || ans="n"
        ans=$(echo "${ans}" | tr -cd 'a-zA-Z')
        [[ "$ans" =~ ^[Yy]$ ]] || { warn "Отменено."; return; }
        echo ""
        info "Останавливаю текущий стек…"
        cd "$INSTALL_DIR" && docker compose down 2>/dev/null || true
        rm -f "$INSTALL_DIR/certs/fullchain.pem" "$INSTALL_DIR/certs/privkey.pem"
    elif ss -tlnp 2>/dev/null | grep -qE ':443\b'; then
        warn "Порт 443 занят:"
        ss -tlnp | grep ':443' || true
        local ans
        printf "  Продолжить? [y/N] " >/dev/tty
        read -r ans </dev/tty 2>/dev/null || ans="n"
        ans=$(echo "${ans}" | tr -cd 'a-zA-Z')
        [[ "$ans" =~ ^[Yy]$ ]] || { warn "Отменено."; return; }
    fi

    install_docker
    install_system_deps
    install_python_deps
    select_sni
    get_server_ip
    generate_panel_secret

    info "Создаю директории…"
    mkdir -p "$INSTALL_DIR"/{html/panel/assets,backend,certs,teleproxy-data}
    mkdir -p "$DATA_DIR"
    $USE_DECOY && mkdir -p "$INSTALL_DIR/decoy/html" || true

    if $USE_DECOY; then
        setup_cert "$FAKE_TLS_DOMAIN"
    else
        setup_cert_silent
    fi

    info "Генерирую учётные данные…"
    generate_credentials
    save_config
    [[ -f "$DATA_DIR/users.json" ]] || echo '[]' > "$DATA_DIR/users.json"
    ok "Конфиг сохранён"

    generate_mtproto_env
    download_backend
    download_frontend

    if $USE_DECOY; then
        download_decoy
        generate_decoy_nginx_conf
    fi

    info "Генерирую конфиги…"
    generate_nginx_conf
    generate_docker_compose
    generate_initial_toml

    local pull_targets=(nginx mtproto)
    $USE_DECOY && pull_targets+=(decoy) || true

    info "Скачиваю образы…"
    cd "$INSTALL_DIR"
    docker compose pull --quiet "${pull_targets[@]}" >/dev/null 2>&1

    info "Собираю образ meridian-backend…"
    docker compose build meridian-backend >/tmp/docker-build.log 2>&1 \
        || { cat /tmp/docker-build.log; rm -f /tmp/docker-build.log; fail "Сборка образа не удалась"; }
    rm -f /tmp/docker-build.log

    info "Запускаю стек…"
    docker compose up -d --remove-orphans >/dev/null 2>&1

    sleep 3

    local check_svcs=(nginx mtproto meridian-backend)
    $USE_DECOY && check_svcs+=(decoy) || true

    local failed=()
    for svc in "${check_svcs[@]}"; do
        docker ps --format '{{.Names}}' | grep -q "^${svc}$" || failed+=("$svc")
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        fail "Не запустились контейнеры: ${failed[*]}\nПроверь: cd ${INSTALL_DIR} && docker compose logs"
    fi

    touch "$INSTALL_DIR/.installed"

    local panel_url
    if $USE_DECOY; then
        panel_url="https://${FAKE_TLS_DOMAIN}/${PANEL_SECRET}/"
    else
        panel_url="https://${SERVER_IP}/${PANEL_SECRET}/"
    fi

    echo ""
    hr
    echo -e "  ${GREEN}${BOLD}Meridian установлен!${NC}"
    hr
    echo ""
    echo -e "  Панель:  ${BOLD}${panel_url}${NC}"
    echo -e "  Логин:   ${BOLD}${USERNAME}${NC}"
    echo -e "  Пароль:  ${BOLD}${PASSWORD}${NC}"
    echo ""
    hr
}

cmd_update() {
    [[ -f "$INSTALL_DIR/docker-compose.yml" ]] \
        || fail "Установка не найдена (${INSTALL_DIR}/docker-compose.yml отсутствует)"

    # Load existing install state
    PANEL_SECRET=$(python3 -c "import json; d=json.load(open('$DATA_DIR/config.json')); print(d.get('panel_path','').lstrip('/'))" 2>/dev/null || true)
    [[ -n "$PANEL_SECRET" ]] || fail "Не удалось прочитать panel_path из ${DATA_DIR}/config.json — переустанови"
    USE_DECOY=false
    [[ -d "$INSTALL_DIR/decoy" ]] && USE_DECOY=true
    FAKE_TLS_DOMAIN=$(grep '^EE_DOMAIN=' "$INSTALL_DIR/mtproto.env" 2>/dev/null | cut -d= -f2 | cut -d: -f1 || true)
    if $USE_DECOY && [[ -z "${FAKE_TLS_DOMAIN:-}" ]]; then
        fail "Не удалось прочитать домен из ${INSTALL_DIR}/mtproto.env — переустанови"
    fi

    download_backend

    download_frontend_update

    if $USE_DECOY; then
        info "Обновляю маскировочный сайт…"
        download_decoy
        cd "$INSTALL_DIR"
        docker compose pull --quiet decoy 2>/dev/null || true
        docker compose up -d --no-deps decoy >/dev/null 2>&1
    fi

    info "Пересобираю образ meridian-backend…"
    cd "$INSTALL_DIR"
    docker compose build --no-cache meridian-backend >/tmp/docker-build.log 2>&1 \
        || { cat /tmp/docker-build.log; rm -f /tmp/docker-build.log; fail "Сборка образа не удалась"; }
    rm -f /tmp/docker-build.log

    info "Перезапускаю meridian-backend…"
    docker compose up -d --no-deps meridian-backend >/dev/null 2>&1

    if ! $USE_DECOY; then
        info "Перезагружаю nginx…"
        docker exec nginx nginx -s reload >/dev/null 2>&1 \
            || warn "nginx reload не удался — перезапусти вручную: docker exec nginx nginx -s reload"
    fi

    ok "Обновление завершено"
}

cmd_reset_password() {
    [[ -f "$DATA_DIR/config.json" ]] \
        || fail "Данные не найдены: ${DATA_DIR}/config.json"

    install_python_deps

    # Read current panel secret before overwriting
    local old_secret
    old_secret=$(python3 -c "import json; d=json.load(open('$DATA_DIR/config.json')); print(d.get('panel_path','').lstrip('/'))" 2>/dev/null || true)

    # Detect mode
    USE_DECOY=false
    [[ -d "$INSTALL_DIR/decoy" ]] && USE_DECOY=true || true

    # Load domain for nginx config regen and URL display
    FAKE_TLS_DOMAIN=$(grep '^EE_DOMAIN=' "$INSTALL_DIR/mtproto.env" 2>/dev/null | cut -d= -f2 | cut -d: -f1 || true)
    get_server_ip

    info "Генерирую новые учётные данные…"
    USERNAME=$(openssl rand -hex 4)
    PASSWORD=$(openssl rand -hex 6)
    BCRYPT_HASH=$("$DATA_DIR/.venv/bin/python3" -c \
        "import bcrypt; print(bcrypt.hashpw(b'${PASSWORD}', bcrypt.gensalt(12)).decode())")
    JWT_SECRET=$(openssl rand -hex 32)

    # Generate new panel secret
    PANEL_SECRET=$(openssl rand -hex 8)
    ok "Новый путь панели: /${PANEL_SECRET}/"

    save_config

    # Regenerate nginx configs with new secret path
    generate_nginx_conf
    if $USE_DECOY; then
        generate_decoy_nginx_conf
        docker exec decoy nginx -s reload 2>/dev/null \
            && ok "decoy перезагружен" || warn "Не удалось перезагрузить decoy"
    fi
    docker exec nginx nginx -s reload 2>/dev/null \
        && ok "nginx перезагружен" || warn "Не удалось перезагрузить nginx"

    # Restart backend (new JWT secret + credentials)
    if docker ps --format '{{.Names}}' | grep -q '^meridian-backend$'; then
        info "Перезапускаю meridian-backend…"
        cd "$INSTALL_DIR"
        docker compose restart meridian-backend >/dev/null 2>&1
    fi

    local panel_url
    if $USE_DECOY && [[ -n "${FAKE_TLS_DOMAIN:-}" ]]; then
        panel_url="https://${FAKE_TLS_DOMAIN}/${PANEL_SECRET}/"
    else
        panel_url="https://${SERVER_IP}/${PANEL_SECRET}/"
    fi

    echo ""
    hr
    echo -e "  ${GREEN}${BOLD}Учётные данные сброшены${NC}"
    hr
    echo ""
    echo -e "  Панель:  ${BOLD}${panel_url}${NC}"
    echo -e "  Логин:   ${BOLD}${USERNAME}${NC}"
    echo -e "  Пароль:  ${BOLD}${PASSWORD}${NC}"
    echo ""
    hr
}

cmd_uninstall() {
    if [[ ! -d "$INSTALL_DIR" && ! -d "$DATA_DIR" ]]; then
        warn "Ничего не найдено для удаления."
        return
    fi

    echo -e "  ${RED}${BOLD}Полное удаление Meridian${NC}"
    echo -e "  ${GRAY}Удаляются: ${INSTALL_DIR}${NC}"
    echo ""

    local ans
    printf "  ${YELLOW}Продолжить удаление? [y/N]${NC} "
    read -r ans </dev/tty 2>/dev/null || ans="n"
        ans=$(echo "${ans}" | tr -cd 'a-zA-Z')
    [[ "$ans" =~ ^[Yy]$ ]] || { warn "Отменено."; return; }

    if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        info "Останавливаю контейнеры…"
        cd "$INSTALL_DIR"
        docker compose down -v --remove-orphans 2>/dev/null || true
    fi

    info "Удаляю Docker-сеть proxy…"
    docker network rm proxy 2>/dev/null || true

    if crontab -l 2>/dev/null | grep -q "certbot renew"; then
        info "Удаляю cron certbot…"
        crontab -l 2>/dev/null | grep -v "certbot renew" | crontab - || true
    fi

    info "Удаляю файлы…"
    cd /
    rm -rf "$INSTALL_DIR"

    ok "Meridian удалён"
}

# ── Entry point ────────────────────────────────────────────────────────────────
require_root

case "${1:-}" in
    install)        cmd_install ;;
    update)         cmd_update ;;
    reset-password) cmd_reset_password ;;
    uninstall)      cmd_uninstall ;;
    menu|"")        show_menu ;;
    *)
        warn "Неизвестный аргумент: ${1}"
        echo ""
        show_menu
        ;;
esac
