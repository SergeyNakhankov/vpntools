# Meridian

MTProto-прокси для Telegram с веб-панелью управления. Ставится одной командой на чистый VPS. Всё крутится на порту 443 — снаружи выглядит как обычный HTTPS-сайт.

## Что входит

| Сервис | Роль |
|---|---|
| nginx | Читает SNI из TLS ClientHello, маршрутизирует TCP без терминации |
| [Teleproxy](https://github.com/teleproxy/teleproxy) | MTProto Fake TLS прокси с DPI-защитой: DRS, domain fronting, anti-replay, ServerHello фрагментация |
| Meridian Panel | Страница входа + React SPA + FastAPI backend. Управление пользователями, QR-коды, tg:// ссылки |
| Маскировочный сайт (опционально) | Фейковый корпоративный портал на корне домена при использовании собственного домена |

## Режимы

### Стандартный SNI (ya.ru, sberbank.ru и т.д.)

3 контейнера. Панель доступна по случайно сгенерированному пути.

```
Telegram   → :443 → nginx stream → SNI = ya.ru      → Teleproxy → Telegram серверы
DPI-проба  → :443 → nginx stream → SNI = ya.ru      → Teleproxy → реальный ya.ru (DRS)
Браузер    → :443 → nginx stream → SNI = что угодно → nginx:8443 → панель
```

### Собственный домен (с маскировочным сайтом)

4 контейнера. Корень домена отдаёт маскировочный корпоративный портал. Панель скрыта за секретным путём.

```
Telegram   → :443 → nginx stream → SNI = corp.example.com → Teleproxy → Telegram серверы
DPI-проба  → :443 → nginx stream → SNI = corp.example.com → Teleproxy → маскировочный сайт (через Docker DNS alias)
Браузер    → :443 → nginx stream → SNI = что угодно       → маскировочный сайт:443 → портал / панель
```

Маскировочный контейнер имеет Docker network alias на имя домена — teleproxy DRS попадает на него
напрямую без выхода в интернет.

## Установка

```bash
curl -sSL https://raw.githubusercontent.com/wooogoblin/meridian-mtproto-panel/main/install.sh | sudo bash
```

Скрипт показывает меню: установить, обновить, сбросить пароль, удалить.

**Без меню** (CI/автоматизация):

```bash
INSTALL="https://raw.githubusercontent.com/wooogoblin/meridian-mtproto-panel/main/install.sh"

curl -sSL $INSTALL | sudo FAKE_TLS_DOMAIN=corp.example.com bash -s -- install
curl -sSL $INSTALL | sudo bash -s -- update
curl -sSL $INSTALL | sudo bash -s -- reset-password
curl -sSL $INSTALL | sudo bash -s -- uninstall
```

## Выбор домена маскировки

**Свой домен** — рекомендуется. Скрипт автоматически получит Let's Encrypt сертификат если
DNS домена указывает на сервер. На корне домена будет маскировочный корпоративный портал.

**Популярные домены** (`ya.ru`, `sberbank.ru` и др.) — работает без своего домена.
Будет self-signed сертификат.

## Панель управления

После установки: `https://<адрес>/<случайный-секрет>/`

Точный URL показывается в конце установки. Генерируется заново при переустановке или сбросе пароля.

- До 16 пользователей, каждый со своим MTProto-секретом
- Включить / отключить без перезапуска (SIGHUP hot-reload)
- Счётчик активных соединений в реальном времени
- `tg://` ссылки, QR-коды, секреты

## Обновление

```bash
# 1. Собрать и запушить фронтенд локально
cd panel && npm run build && git add dist/ && git commit -m "build" && git push

# 2. На сервере
curl -sSL .../install.sh | sudo bash -s -- update
```

## Логи

```bash
docker logs nginx            --tail 50 -f
docker logs mtproto          --tail 50 -f
docker logs meridian-backend --tail 50 -f
docker logs decoy            --tail 50 -f  # только при собственном домене
```

## Структура репозитория

```
meridian-mtproto-panel/
├── panel/
│   ├── login/
│   │   └── index.html          # Страница входа
│   ├── decoy/
│   │   └── index.html          # Маскировочный сайт (собственный домен)
│   ├── src/                    # React SPA (Vite, base: './')
│   ├── dist/                   # Pre-built фронтенд (коммитится)
│   └── backend/                # FastAPI + uvicorn
│       ├── main.py, auth.py, users.py, teleproxy_config.py
│       ├── Dockerfile
│       └── requirements.txt
├── install.sh                  # install | update | reset-password | uninstall
└── README.md
```

## Структура на сервере

```
/opt/meridian/
├── docker-compose.yml
├── nginx.conf                  # стандартный SNI: stream+http; собственный домен: stream-only
├── mtproto.env
├── certs/                      # стандартный SNI: self-signed; собственный домен: LE или self-signed
├── html/
│   ├── index.html              # Страница входа
│   └── panel/                  # React SPA
├── decoy/                      # Только при собственном домене
│   ├── nginx.conf
│   └── html/index.html         # Маскировочный сайт с подставленным доменом
├── backend/
├── teleproxy-data/
│   └── config.toml
└── data/
    ├── config.json             # username, password_hash, jwt_secret, panel_path
    └── users.json
```

## Требования

- Linux (Ubuntu 20.04+ / Debian 11+)
- Порт 443 свободен
- root-доступ

Скрипт сам устанавливает: Docker, docker-compose-plugin, xxd, dnsutils, openssl, python3, python3-venv, bcrypt.
