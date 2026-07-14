#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT_DIR/server/src"
DEPLOY_DIR="/opt/teamtalk"
WEB_DIR="/var/www/html/tt"
VERSION="bugfix-$(date +%Y%m%d)"

log() { echo "[deploy] $*"; }

install_build_deps() {
    log "安装编译依赖..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        build-essential cmake g++ make pkg-config unzip wget \
        uuid-dev libcurl4-openssl-dev libssl-dev \
        libprotobuf-dev protobuf-compiler libhiredis-dev \
        liblog4cxx-dev default-libmysqlclient-dev \
        nginx php-fpm php-cli php-mysql redis-server
}

prepare_mysql_paths() {
    log "配置 MySQL 库路径（兼容 CentOS CMake 配置）..."
    mkdir -p /usr/lib64/mysql
    if [ ! -e /usr/lib64/mysql/libmysqlclient_r.so ]; then
        MYSQL_LIB="$(find /usr/lib -name 'libmysqlclient.so*' | head -1)"
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

    export CC=gcc
    export CXX=g++
    export LIBRARY_PATH="/usr/lib/gcc/x86_64-linux-gnu/13:${LIBRARY_PATH:-}"

    log "编译 slog..."
    cd "$SRC_DIR/slog"
    if [ ! -f libslog.so ]; then
        rm -rf CMakeCache.txt CMakeFiles
        cmake .
        make -j"$(nproc)"
        mkdir -p ../base/slog/lib
        cp slog_api.h ../base/slog/
        cp libslog.so ../base/slog/lib/
        if [ -d lib ]; then
            cp -a lib/liblog4cxx.so* ../base/slog/lib/ 2>/dev/null || true
        fi
        find /usr/lib -name 'liblog4cxx.so*' -exec cp -a {} ../base/slog/lib/ \; 2>/dev/null || true
    fi
}

build_servers() {
    log "编译 TeamTalk 服务端..."
    cd "$SRC_DIR"
    export CC=gcc
    export CXX=g++
    export CPLUS_INCLUDE_PATH="$SRC_DIR/slog"
    export LD_LIBRARY_PATH="$SRC_DIR/slog:$SRC_DIR/base/slog/lib:${LD_LIBRARY_PATH:-}"
    export LIBRARY_PATH="/usr/lib/gcc/x86_64-linux-gnu/13:$SRC_DIR/slog:$SRC_DIR/base/slog/lib:${LIBRARY_PATH:-}"

    echo "#ifndef __VERSION_H__" > base/version.h
    echo "#define __VERSION_H__" >> base/version.h
    echo "#define VERSION \"$VERSION\"" >> base/version.h
    echo "#endif" >> base/version.h

    mkdir -p lib
    for mod in base slog login_server route_server msg_server http_msg_server file_server push_server db_proxy_server msfs; do
        log "编译 $mod ..."
        cd "$SRC_DIR/$mod"
        rm -rf CMakeCache.txt CMakeFiles
        cmake .
        make -j"$(nproc)"
    done

    log "编译 tools ..."
    cd "$SRC_DIR/tools"
    make -j"$(nproc)"

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

deploy_im_server() {
    log "部署 IM 服务端到 $DEPLOY_DIR ..."
    mkdir -p "$DEPLOY_DIR"
    BUILD_VERSION="im-server-$VERSION"
    tar zxf "$ROOT_DIR/server/im-server-$VERSION.tar.gz" -C "$DEPLOY_DIR"
    IM_DIR="$DEPLOY_DIR/$BUILD_VERSION"

    cp -f "$ROOT_DIR/auto_setup/im_server/conf/"*.conf "$IM_DIR/login_server/" 2>/dev/null || true
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/loginserver.conf" "$IM_DIR/login_server/"
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/msgserver.conf" "$IM_DIR/msg_server/"
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/routeserver.conf" "$IM_DIR/route_server/"
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/fileserver.conf" "$IM_DIR/file_server/"
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/msfs.conf" "$IM_DIR/msfs/"
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/httpmsgserver.conf" "$IM_DIR/http_msg_server/"
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/pushserver.conf" "$IM_DIR/push_server/"
    cp -f "$ROOT_DIR/auto_setup/im_server/conf/dbproxyserver.conf" "$IM_DIR/db_proxy_server/"

    cd "$IM_DIR"
    chmod +x sync_lib_for_zip.sh restart.sh
    ./sync_lib_for_zip.sh

    for svc in login_server route_server db_proxy_server msg_server file_server msfs http_msg_server push_server; do
        log "重启 $svc ..."
        ./restart.sh "$svc" || log "警告: $svc 启动可能失败（依赖 DB/Redis 未配置）"
    done
}

deploy_php() {
    log "部署 PHP 后台到 $WEB_DIR ..."
    mkdir -p "$(dirname "$WEB_DIR")"
    rm -rf "$WEB_DIR"
    cp -a "$ROOT_DIR/php" "$WEB_DIR"
    mkdir -p "$WEB_DIR/download"
    chmod -R 777 "$WEB_DIR/download" "$WEB_DIR/application/cache" 2>/dev/null || true

    if [ -f "$ROOT_DIR/auto_setup/im_web/conf/database.php" ]; then
        cp "$ROOT_DIR/auto_setup/im_web/conf/database.php" "$WEB_DIR/application/config/"
    fi
    if [ -f "$ROOT_DIR/auto_setup/im_web/conf/config.php" ]; then
        cp "$ROOT_DIR/auto_setup/im_web/conf/config.php" "$WEB_DIR/application/config/"
    fi

    PHP_FPM_SOCK="$(find /run/php -name 'php*-fpm.sock' 2>/dev/null | head -1)"
    if [ -z "$PHP_FPM_SOCK" ]; then
        PHP_FPM_SOCK="/run/php/php-fpm.sock"
    fi

    cat > /etc/nginx/sites-available/teamtalk <<NGINX
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html/tt;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
    }
}
NGINX

    ln -sf /etc/nginx/sites-available/teamtalk /etc/nginx/sites-enabled/teamtalk
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    nginx -t
    systemctl restart nginx redis-server || true
    if systemctl list-units --type=service --all | grep -q php8.3-fpm; then
        systemctl restart php8.3-fpm
    elif systemctl list-units --type=service --all | grep -q php-fpm; then
        systemctl restart php-fpm
    fi
    log "PHP 后台已部署，访问 http://<host>/"
}

main() {
    install_build_deps
    prepare_mysql_paths
    build_third_party
    build_servers
    deploy_im_server
    deploy_php
    log "全部完成。"
}

main "$@"
