#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT_DIR/server/src"
DEPLOY_DIR="/opt/teamtalk"
WEB_DIR="/var/www/html/tt"
VERSION="bugfix-$(date +%Y%m%d)"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-12345}"

log() { echo "[deploy] $*"; }

install_build_deps() {
    log "安装编译依赖..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        build-essential cmake make pkg-config unzip wget \
        uuid-dev libcurl4-openssl-dev libssl-dev \
        libprotobuf-dev protobuf-compiler libhiredis-dev \
        liblog4cxx-dev default-libmysqlclient-dev \
        nginx php-fpm php-cli php-mysql mariadb-server redis-server
}

setup_gcc() {
    log "安装并使用最新稳定版 GCC..."
    LATEST_GCC_PKG=$(apt-cache search '^gcc-[0-9]+$' | awk '{print $1}' | sort -t- -k2 -n | tail -1)
    LATEST_GPP_PKG="${LATEST_GCC_PKG/gcc/g++}"
    apt-get install -y "$LATEST_GCC_PKG" "$LATEST_GPP_PKG"
    GCC_VER="${LATEST_GCC_PKG#gcc-}"
    export CC="gcc-$GCC_VER"
    export CXX="g++-$GCC_VER"
    export GCC_LIB_DIR="/usr/lib/gcc/x86_64-linux-gnu/$GCC_VER"
    export LIBRARY_PATH="${GCC_LIB_DIR}:${LIBRARY_PATH:-}"
    log "使用编译器: $($CC --version | head -1)"
}

prepare_mysql_paths() {
    log "配置 MySQL 库路径（兼容 CentOS CMake 配置）..."
    mkdir -p /usr/lib64/mysql
    if [ ! -e /usr/lib64/mysql/libmysqlclient_r.so ]; then
        MYSQL_LIB="$(find /usr/lib -name 'libmysqlclient.so*' ! -name '*.a' | head -1)"
        ln -sf "$MYSQL_LIB" /usr/lib64/mysql/libmysqlclient_r.so
    fi
}

build_third_party() {
    log "编译 protobuf..."
    cd "$SRC_DIR"
    if [ ! -f base/pb/lib/linux/libprotobuf-lite.a ]; then
        bash make_protobuf.sh
    fi

    log "编译 hiredis..."
    if [ ! -f db_proxy_server/libhiredis.a ]; then
        bash make_hiredis.sh
    fi

    log "编译 slog..."
    cd "$SRC_DIR/slog"
    rm -rf CMakeCache.txt CMakeFiles
    cmake -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" .
    make -j"$(nproc)"
    mkdir -p ../base/slog/lib
    cp slog_api.h ../base/slog/
    cp libslog.so ../base/slog/lib/
    find /usr/lib -name 'liblog4cxx.so*' -exec cp -a {} ../base/slog/lib/ \; 2>/dev/null || true
}

build_servers() {
    log "编译 TeamTalk 服务端..."
    cd "$SRC_DIR"
    export CPLUS_INCLUDE_PATH="$SRC_DIR/slog"
    export LD_LIBRARY_PATH="$SRC_DIR/slog:$SRC_DIR/base/slog/lib:${LD_LIBRARY_PATH:-}"
    export LIBRARY_PATH="${GCC_LIB_DIR}:$SRC_DIR/slog:$SRC_DIR/base/slog/lib:${LIBRARY_PATH:-}"

    echo "#ifndef __VERSION_H__" > base/version.h
    echo "#define __VERSION_H__" >> base/version.h
    echo "#define VERSION \"$VERSION\"" >> base/version.h
    echo "#endif" >> base/version.h

    mkdir -p lib
    for mod in base slog login_server route_server msg_server http_msg_server file_server push_server db_proxy_server msfs; do
        log "编译 $mod ..."
        cd "$SRC_DIR/$mod"
        rm -rf CMakeCache.txt CMakeFiles
        cmake -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" .
        make -j"$(nproc)"
    done

    log "编译 tools ..."
    cd "$SRC_DIR/tools"
    make clean 2>/dev/null || true
    make -j"$(nproc)" CC="$CC" CXX="$CXX"

    cd "$SRC_DIR"
    cp base/libbase.a lib/ 2>/dev/null || true

    mkdir -p "$ROOT_DIR/server/run"/{login_server,route_server,msg_server,file_server,msfs,push_server,http_msg_server,db_proxy_server}
    cp login_server/login_server "$ROOT_DIR/server/run/login_server/"
    cp route_server/route_server "$ROOT_DIR/server/run/route_server/"
    cp msg_server/msg_server "$ROOT_DIR/server/run/msg_server/"
    cp http_msg_server/http_msg_server "$ROOT_DIR/server/run/http_msg_server/"
    cp file_server/file_server "$ROOT_DIR/server/run/file_server/"
    cp push_server/push_server "$ROOT_DIR/server/run/push_server/"
    cp db_proxy_server/db_proxy_server "$ROOT_DIR/server/run/db_proxy_server/"
    cp msfs/msfs "$ROOT_DIR/server/run/msfs/"
    cp tools/daeml "$ROOT_DIR/server/run/"

    BUILD_VERSION="im-server-$VERSION"
    BUILD_NAME="$BUILD_VERSION.tar.gz"
    rm -rf "$ROOT_DIR/server/$BUILD_VERSION" "$ROOT_DIR/server/$BUILD_NAME"
    mkdir -p "$ROOT_DIR/server/$BUILD_VERSION"/{login_server,route_server,msg_server,file_server,msfs,http_msg_server,push_server,db_proxy_server,lib}

    cp login_server/loginserver.conf "$ROOT_DIR/server/$BUILD_VERSION/login_server/"
    cp login_server/login_server "$ROOT_DIR/server/$BUILD_VERSION/login_server/"
    cp route_server/route_server "$ROOT_DIR/server/$BUILD_VERSION/route_server/"
    cp route_server/routeserver.conf "$ROOT_DIR/server/$BUILD_VERSION/route_server/"
    cp msg_server/msg_server "$ROOT_DIR/server/$BUILD_VERSION/msg_server/"
    cp msg_server/msgserver.conf "$ROOT_DIR/server/$BUILD_VERSION/msg_server/"
    cp http_msg_server/http_msg_server "$ROOT_DIR/server/$BUILD_VERSION/http_msg_server/"
    cp http_msg_server/httpmsgserver.conf "$ROOT_DIR/server/$BUILD_VERSION/http_msg_server/"
    cp file_server/file_server "$ROOT_DIR/server/$BUILD_VERSION/file_server/"
    cp file_server/fileserver.conf "$ROOT_DIR/server/$BUILD_VERSION/file_server/"
    cp push_server/push_server "$ROOT_DIR/server/$BUILD_VERSION/push_server/"
    cp push_server/pushserver.conf "$ROOT_DIR/server/$BUILD_VERSION/push_server/"
    cp db_proxy_server/db_proxy_server "$ROOT_DIR/server/$BUILD_VERSION/db_proxy_server/"
    cp db_proxy_server/dbproxyserver.conf "$ROOT_DIR/server/$BUILD_VERSION/db_proxy_server/"
    cp msfs/msfs "$ROOT_DIR/server/$BUILD_VERSION/msfs/"
    cp msfs/msfs.conf.example "$ROOT_DIR/server/$BUILD_VERSION/msfs/"
    cp slog/log4cxx.properties "$ROOT_DIR/server/$BUILD_VERSION/lib/"
    cp slog/libslog.so "$ROOT_DIR/server/$BUILD_VERSION/lib/"
    cp -a base/slog/lib/liblog4cxx.so* "$ROOT_DIR/server/$BUILD_VERSION/lib/" 2>/dev/null || true
    cp sync_lib_for_zip.sh "$ROOT_DIR/server/$BUILD_VERSION/"
    cp tools/daeml "$ROOT_DIR/server/$BUILD_VERSION/"
    cp "$ROOT_DIR/server/run/restart.sh" "$ROOT_DIR/server/$BUILD_VERSION/"

    cd "$ROOT_DIR/server"
    tar zcf "$BUILD_NAME" "$BUILD_VERSION"
    log "构建完成: $ROOT_DIR/server/$BUILD_NAME"
}

start_mariadb() {
    log "启动 MariaDB..."
    mkdir -p /run/mysqld
    chown mysql:mysql /run/mysqld 2>/dev/null || true
    if ! pgrep -x mariadbd >/dev/null; then
        mysqld_safe --datadir=/var/lib/mysql --user=mysql &
        sleep 5
    fi
    mysql -uroot -e "SELECT 1" 2>/dev/null || \
        mysql -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" 2>/dev/null || true
    mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS teamtalk DEFAULT CHARSET utf8mb4;" 2>/dev/null || true
    if ! mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" teamtalk -e "SHOW TABLES LIKE 'IMUser';" 2>/dev/null | grep -q IMUser; then
        mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" teamtalk < "$ROOT_DIR/auto_setup/mariadb/conf/ttopen.sql"
    fi
}

start_redis() {
    log "启动 Redis..."
    if ! pgrep -x redis-server >/dev/null; then
        redis-server --daemonize yes
    fi
}

start_php_fpm() {
    log "启动 PHP-FPM..."
    mkdir -p /run/php
    if ! pgrep -f php-fpm >/dev/null; then
        PHP_FPM_BIN="$(command -v php-fpm8.3 || command -v php-fpm)"
        "$PHP_FPM_BIN" --daemonize --fpm-config /etc/php/8.3/fpm/php-fpm.conf 2>/dev/null || \
        "$PHP_FPM_BIN" --daemonize
    fi
}

start_nginx() {
    log "启动 Nginx..."
    if ! pgrep -x nginx >/dev/null; then
        nginx
    else
        nginx -s reload 2>/dev/null || true
    fi
}

deploy_im_server() {
    log "部署 IM 服务端到 $DEPLOY_DIR ..."
    mkdir -p "$DEPLOY_DIR"
    BUILD_VERSION="im-server-$VERSION"
    rm -rf "$DEPLOY_DIR/$BUILD_VERSION"
    tar zxf "$ROOT_DIR/server/im-server-$VERSION.tar.gz" -C "$DEPLOY_DIR"
    IM_DIR="$DEPLOY_DIR/$BUILD_VERSION"

    cp -f "$ROOT_DIR/auto_setup/im_server/conf/loginserver.conf" "$IM_DIR/login_server/"
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/msgserver.conf" "$IM_DIR/msg_server/"
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/routeserver.conf" "$IM_DIR/route_server/"
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/fileserver.conf" "$IM_DIR/file_server/"
    cp -f "$ROOT_DIR/server/src/file_server/fileserver.conf" "$IM_DIR/file_server/"
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/msfs.conf" "$IM_DIR/msfs/"
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/httpmsgserver.conf" "$IM_DIR/http_msg_server/"
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/pushserver.conf" "$IM_DIR/push_server/"
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/dbproxyserver.conf" "$IM_DIR/db_proxy_server/"

    cd "$IM_DIR"
    chmod +x sync_lib_for_zip.sh restart.sh
    ./sync_lib_for_zip.sh

    for svc in login_server route_server db_proxy_server msg_server file_server msfs http_msg_server push_server; do
        mkdir -p "$IM_DIR/$svc/log"
        chmod -R 777 "$IM_DIR/$svc/log"
        log "重启 $svc ..."
        ./restart.sh "$svc" || log "警告: $svc 启动失败，请检查 $IM_DIR/$svc/log"
    done
}

deploy_php() {
    log "部署 PHP 后台到 $WEB_DIR ..."
    mkdir -p "$(dirname "$WEB_DIR")"
    rm -rf "$WEB_DIR"
    cp -a "$ROOT_DIR/php" "$WEB_DIR"
    mkdir -p "$WEB_DIR/download"
    chmod -R 777 "$WEB_DIR/download" "$WEB_DIR/application/cache" 2>/dev/null || true
    rm -rf "$WEB_DIR/application/cache/"* 2>/dev/null || true

    cp "$ROOT_DIR/auto_setup/im_web/conf/database.php" "$WEB_DIR/application/config/database.php"
    # 使用仓库内 config.php（含 REQUEST_URI 等 PHP 8 / Nginx 兼容配置）

    PHP_FPM_SOCK="$(find /run/php -name 'php*-fpm.sock' 2>/dev/null | head -1)"
    [ -n "$PHP_FPM_SOCK" ] || PHP_FPM_SOCK="/run/php/php-fpm.sock"

    cat > /etc/nginx/sites-available/teamtalk <<NGINX
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html/tt;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ ^/index\\.php(/|$) {
        include snippets/fastcgi-php.conf;
        fastcgi_split_path_info ^(.+?\\.php)(/.*)?\$;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_pass unix:${PHP_FPM_SOCK};
    }

    location ~ \\.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
    }
}
NGINX

    ln -sf /etc/nginx/sites-available/teamtalk /etc/nginx/sites-enabled/teamtalk
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    nginx -t
    start_php_fpm
    start_nginx
    log "PHP 后台已部署，访问 http://<host>/"
}

print_status() {
    log "========== 部署状态 =========="
    log "GCC: $($CC --version | head -1)"
    log "部署包: $ROOT_DIR/server/im-server-$VERSION.tar.gz"
    log "IM 目录: $DEPLOY_DIR/im-server-$VERSION"
    ps aux | grep -E 'login_server|route_server|db_proxy|msg_server|file_server|msfs|http_msg|push_server|nginx|php-fpm|redis|mariadb' | grep -v grep | awk '{print "  [运行] " $11}' || true
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/index.php/api/discovery || echo '000')
    log "API /index.php/api/discovery => HTTP $HTTP_CODE"
}

main() {
    install_build_deps
    setup_gcc
    prepare_mysql_paths
    start_mariadb
    start_redis
    build_third_party
    build_servers
    deploy_im_server
    deploy_php
    print_status
    log "全部完成。"
}

main "$@"
