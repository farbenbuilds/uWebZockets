#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
cd "$script_dir/.."
sql_zig=${UWZ_ZIG:-zig}
sql_image=${UWZ_SQL_TEST_IMAGE:-postgres@sha256:f4c66b820c6f974249089d3d16d86a3698eae11e8746eb6644b2271031e91232}
sql_directory=$(mktemp -d "${TMPDIR:-/tmp}/uwz_sql_test.XXXXXXXX")
sql_container=

cleanup()
{
    if [ -n "$sql_container" ]; then
        # Cleanup is best effort if the daemon already removed the --rm container.
        docker rm --force "$sql_container" >/dev/null 2>&1 || true
    fi
    rm -rf "$sql_directory"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

umask 077
printf 'POSTGRES_PASSWORD=' > "$sql_directory/postgres.env"
openssl rand -hex 24 >> "$sql_directory/postgres.env"
printf '%s\n' 'POSTGRES_USER=uwz_test' 'POSTGRES_DB=uwz_test' >> "$sql_directory/postgres.env"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$sql_directory/ca.key" \
    -out "$sql_directory/ca.pem" -days 1 -subj /CN=uwz-sql-test-ca \
    2> "$sql_directory/openssl.log"
openssl req -newkey rsa:2048 -nodes -keyout "$sql_directory/server.key" \
    -out "$sql_directory/server.csr" -subj /CN=localhost \
    2>> "$sql_directory/openssl.log"
printf '%s\n' 'subjectAltName=DNS:localhost,IP:127.0.0.1' 'extendedKeyUsage=serverAuth' > "$sql_directory/extensions.cnf"
openssl x509 -req -in "$sql_directory/server.csr" -CA "$sql_directory/ca.pem" \
    -CAkey "$sql_directory/ca.key" -CAcreateserial -out "$sql_directory/server.pem" \
    -days 1 -extfile "$sql_directory/extensions.cnf" 2>> "$sql_directory/openssl.log"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$sql_directory/untrusted.key" \
    -out "$sql_directory/untrusted.pem" -days 1 -subj /CN=uwz-sql-untrusted-ca \
    2>> "$sql_directory/openssl.log"

sql_container=$(docker run --detach --rm --env-file "$sql_directory/postgres.env" \
    --publish 127.0.0.1::5432 --tmpfs /var/lib/postgresql/data "$sql_image")
sql_attempt=0
until docker exec "$sql_container" pg_isready -h 127.0.0.1 -U uwz_test -d uwz_test >/dev/null 2>&1; do
    sql_attempt=$((sql_attempt + 1))
    if [ "$sql_attempt" -ge 30 ]; then
        printf '%s\n' 'PostgreSQL test database did not become ready' >&2
        exit 1
    fi
    sleep 1
done
docker exec "$sql_container" mkdir -p /tmp/uwz_sql_tls
docker cp "$sql_directory/server.pem" "$sql_container:/tmp/uwz_sql_tls/server.pem" >/dev/null
docker cp "$sql_directory/server.key" "$sql_container:/tmp/uwz_sql_tls/server.key" >/dev/null
docker exec "$sql_container" chown -R postgres:postgres /tmp/uwz_sql_tls
docker exec "$sql_container" chmod 600 /tmp/uwz_sql_tls/server.key
docker exec "$sql_container" psql -U uwz_test -d uwz_test -v ON_ERROR_STOP=1 \
    -c "ALTER SYSTEM SET ssl = 'on'" \
    -c "ALTER SYSTEM SET ssl_cert_file = '/tmp/uwz_sql_tls/server.pem'" \
    -c "ALTER SYSTEM SET ssl_key_file = '/tmp/uwz_sql_tls/server.key'" \
    -c 'SELECT pg_reload_conf()' \
    -c "CREATE ROLE uwz_unicode LOGIN PASSWORD U&'x\0340'" \
    -c "CREATE ROLE uwz_unicode_cjk LOGIN PASSWORD U&'x\+02F868'" >/dev/null

# SIGHUP applies SSL settings asynchronously; wait for the configured value.
sql_attempt=0
until [ "$(docker exec "$sql_container" psql -U uwz_test -d uwz_test -Atc 'SHOW ssl')" = on ]; do
    sql_attempt=$((sql_attempt + 1))
    if [ "$sql_attempt" -ge 30 ]; then
        printf '%s\n' 'PostgreSQL TLS configuration did not become ready' >&2
        exit 1
    fi
    sleep 1
done
sql_mapping=$(docker port "$sql_container" 5432/tcp)
UWZ_SQL_TEST_PORT=${sql_mapping##*:}
UWZ_SQL_TEST_TLS_PORT=$UWZ_SQL_TEST_PORT
UWZ_SQL_TEST_PASSWORD=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$sql_directory/postgres.env")
UWZ_SQL_TEST_UNICODE_PASSWORD=$(printf 'x\315\200')
UWZ_SQL_TEST_CJK_PASSWORD=$(printf 'x\360\257\241\250')
UWZ_SQL_TEST_CA_PATH=$sql_directory/ca.pem
UWZ_SQL_TEST_UNTRUSTED_CA_PATH=$sql_directory/untrusted.pem
export UWZ_SQL_TEST_PORT UWZ_SQL_TEST_TLS_PORT UWZ_SQL_TEST_PASSWORD
export UWZ_SQL_TEST_CA_PATH UWZ_SQL_TEST_UNTRUSTED_CA_PATH UWZ_SQL_TEST_UNICODE_PASSWORD
export UWZ_SQL_TEST_CJK_PASSWORD

printf '%s\n' "SQL integration image: $sql_image"
docker exec "$sql_container" psql -U uwz_test -d uwz_test -Atc 'SHOW server_version'
"$sql_zig" build test -Dsql=true -Dsqlite=true "$@"
