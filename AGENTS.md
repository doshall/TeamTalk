# AGENTS.md

TeamTalk is an enterprise IM solution (circa 2015, originally `mogujie/TeamTalk`). This
repo is a monorepo: a C++ server cluster (`server/`), a PHP/CodeIgniter web admin (`php/`),
native clients (`android/`, `ios/`, `mac/`, `win-client/`), the shared Protobuf protocol
(`pb/`), and one-click deploy scripts (`auto_setup/`).

On a Linux dev VM the runnable product is the **C++ IM server cluster + MySQL + Redis**.
The native clients require Android Studio / Xcode / Visual Studio and cannot run headless.

## Cursor Cloud specific instructions

The startup update script installs the apt dependencies. Everything below (building the
third-party libs, building the servers, starting services) is **not** done by the update
script — do it explicitly when you need to run the product. None of the build outputs are
committed.

### Critical gotchas (read before building)

- **Compile with g++, not clang.** The default `c++`/`cc` alternative on this image is
  clang 18, which fails to link `libstdc++` (`cannot find -lstdc++`). The build scripts call
  bare `cmake .`, so you MUST export `CC=gcc CXX=g++` before building anything (cmake honors
  these env vars). Symptom if you forget: `Configuring incomplete` during the cmake compiler
  check.
- **Protobuf must be 2.6.1.** The generated `*.pb.cc` in `server/src/base/pb/protocol/` were
  produced by protobuf 2.6.1. Do NOT link the system protobuf (3.x). Build the bundled
  `server/src/protobuf/protobuf-2.6.1.tar.gz` and use its static `libprotobuf-lite.a`.
- **log4cxx:** the bundled `make_log4cxx.sh` downloads 0.10.0 from a dead mirror. Use the
  system package instead (`liblog4cxx-dev`, v1.1.0). `slog` only uses stable APIs and links
  cleanly against it. No source changes needed.
- **`msfs` (image/file storage) does not build** with gcc 13: `FileManager.cpp:230` has an
  ambiguous `abs(unsigned long long)`. It is optional and not needed for login/text chat.
- **`msg_server` requires >= 2 DB instances** or it exits at startup with
  `DBServerIP need 2 instance at lest`. `server/src/msg_server/msgserver.conf` is configured
  with `DBServerIP1`/`DBServerIP2` both pointing at the single local `db_proxy_server`.

### Building the server cluster

Run from `server/src/` with `CC=gcc CXX=g++` exported. One-time third-party builds:

```bash
cd server/src/protobuf && tar -xzf protobuf-2.6.1.tar.gz && cd protobuf-2.6.1 \
  && ./configure --prefix=$PWD/../../protobuf-install --disable-shared CXXFLAGS="-O2 -fPIC" \
  && make -j$(nproc) && make install
cp ../../protobuf-install/lib/libprotobuf-lite.a ../../base/pb/lib/linux/
cp -r ../../protobuf-install/include/* ../../base/pb/

cd server/src/hiredis && unzip -o hiredis-master.zip && cd hiredis-master && make -j$(nproc)
cp -a libhiredis.a ../../db_proxy_server/ && cp -a hiredis.h async.h read.h sds.h adapters ../../db_proxy_server/
```

`slog` uses the system log4cxx; stage it where the CMake files expect it:

```bash
cd server/src/slog && cmake . && make
mkdir -p ../base/slog/lib && cp slog_api.h ../base/ ... # see below
```

Then build each component (`base` first, then the services). Each is a `cmake . && make` in
its own directory. `msfs` is the only one that fails (skip it). The official `build.sh`
(CentOS/yum) and `build_ubuntu.sh` (Ubuntu/apt) automate the full sequence but also run
`apt-get`/`yum` and produce a tarball; for incremental dev work, building per-directory with
`CC=gcc CXX=g++` is simpler.

### Running the product (services start order matters)

`db_proxy_server` → `login_server` → `route_server` → `msg_server`. Each binary reads its
`*.conf` from its CWD, needs a `./log/` dir, and needs `libslog.so` on the library path:

```bash
export LD_LIBRARY_PATH=/workspace/server/src/base/slog/lib
( cd server/src/db_proxy_server && mkdir -p log && nohup ./db_proxy_server > run.out 2>&1 & )
( cd server/src/login_server   && mkdir -p log && nohup ./login_server   > run.out 2>&1 & )
( cd server/src/route_server   && mkdir -p log && nohup ./route_server   > run.out 2>&1 & )
( cd server/src/msg_server     && mkdir -p log && nohup ./msg_server     > run.out 2>&1 & )
```

Confirm `server/src/msg_server/log/default.log` shows `connect to db/login/route server
success`. Ports: msg_server 8000, login_server client 8008 / http 8080 / msgsrv 8100,
route_server 8200, db_proxy_server 10600. `file_server`/`push_server`/`msfs` are optional and
their "onclose" lines in the msg_server log are harmless.

### MySQL + Redis setup

MariaDB and Redis are installed but there is no systemd in the container — start them
manually:

```bash
sudo mkdir -p /var/run/mysqld && sudo chown mysql:mysql /var/run/mysqld
sudo bash -c 'nohup mariadbd-safe > /var/log/mariadb-safe.log 2>&1 &'
sudo bash -c 'nohup redis-server --bind 127.0.0.1 --port 6379 > /var/log/redis-manual.log 2>&1 &'
```

Load the schema and create the DB user the configs expect (`test`/`12345`, db `teamtalk`):

```bash
sudo mariadb < auto_setup/mariadb/conf/ttopen.sql
sudo mariadb -e "CREATE USER IF NOT EXISTS 'test'@'127.0.0.1' IDENTIFIED BY '12345';
                 CREATE USER IF NOT EXISTS 'test'@'localhost' IDENTIFIED BY '12345';
                 GRANT ALL ON teamtalk.* TO 'test'@'127.0.0.1';
                 GRANT ALL ON teamtalk.* TO 'test'@'localhost'; FLUSH PRIVILEGES;"
```

`IMUser` ships empty. A login is verified as `MD5(plaintext_password + salt)` against the
`password` column, and the login query requires `status=0`. Create a user e.g.:

```bash
HASH=$(printf '%s' "1234562abcd" | md5sum | awk '{print $1}')  # md5(password+salt)
# (use password "123456", salt "abcd" -> HASH=bc9b5718afdffe85fb13555347969ff5)
mariadb -h127.0.0.1 -utest -p12345 teamtalk -e \
  "INSERT INTO IMUser (sex,name,domain,nick,password,salt,departId,status,created,updated)
   VALUES (1,'alice','alice','Alice','bc9b5718afdffe85fb13555347969ff5','abcd',1,0,UNIX_TIMESTAMP(),UNIX_TIMESTAMP());"
```

### Smoke test (login + send message, end-to-end)

`server/src/test/tt_login_client.py` is a dependency-free Python client that speaks the
TeamTalk wire protocol directly. It logs in and sends a text message, which `msg_server`
persists to MySQL via `db_proxy_server`:

```bash
python3 server/src/test/tt_login_client.py 127.0.0.1 8000 alice 123456 2 "hello"
# Verify persistence: SELECT * FROM teamtalk.IMMessage_<n>;  (sharded 0-7)
```

The bundled C++ `server/src/test/` client is outdated (bad default login domain, uses
`hash_map`) — prefer the Python client above.
