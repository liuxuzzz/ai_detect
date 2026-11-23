#!/bin/sh
set -eu
umask 077

secret_dir=${SECRET_DIR:-/run/secrets}
postgres_data=${POSTGRES_DATA_DIR:-/existing-postgres}
mkdir -p "$secret_dir"
chmod 700 "$secret_dir"

# An existing database cannot adopt a newly generated password. Preserve its
# original password from .env when upgrading from a release without this volume.
if [ -f "$postgres_data/PG_VERSION" ] &&
   [ ! -s "$secret_dir/postgres_password" ] &&
   [ -z "${POSTGRES_PASSWORD:-}" ]; then
    echo '检测到已有数据库，请从原部署 .env 恢复 POSTGRES_PASSWORD；不会修改数据库或重置密码。' >&2
    exit 1
fi
if [ -f "$postgres_data/PG_VERSION" ] &&
   [ ! -s "$secret_dir/jwt_secret" ] &&
   [ -z "${JWT_SECRET:-}" ]; then
    echo '检测到已有数据库，请从原部署 .env 恢复 JWT_SECRET；不会更换已有账号和 Client Key 的密钥。' >&2
    exit 1
fi

temporary=
trap 'if [ -n "$temporary" ]; then rm -f "$temporary"; fi' EXIT HUP INT TERM

save_secret() {
    name=$1
    supplied=$2
    destination="$secret_dir/$name"
    if [ -z "$supplied" ] && [ -s "$destination" ]; then
        return
    fi
    if [ -z "$supplied" ] && [ -e "$destination" ]; then
        echo "密钥文件 $name 为空，请从备份恢复。" >&2
        exit 1
    fi
    if [ -z "$supplied" ]; then
        supplied=$(od -An -N32 -tx1 -v /dev/urandom | tr -d ' \n')
        if [ "${#supplied}" -ne 64 ]; then
            echo '无法生成随机密钥。' >&2
            exit 1
        fi
    fi
    temporary=$(mktemp "$secret_dir/.$name.XXXXXX")
    printf '%s' "$supplied" > "$temporary"
    if [ -n "$2" ]; then
        # Explicit environment overrides retain their previous semantics.
        mv -f "$temporary" "$destination"
    elif ! ln "$temporary" "$destination" 2>/dev/null; then
        # Another first start may have initialized the same volume meanwhile.
        test -s "$destination"
    fi
    rm -f "$temporary"
    temporary=
    chmod 600 "$destination"
}

save_secret postgres_password "${POSTGRES_PASSWORD:-}"
save_secret jwt_secret "${JWT_SECRET:-}"

# Older releases used JWT_SECRET for encryption when no separate key was set.
# Keep that key when importing an existing .env so saved Client Keys still work.
encryption_secret=${CLIENT_KEY_ENCRYPTION_SECRET:-}
if [ -z "$encryption_secret" ] &&
   [ ! -e "$secret_dir/client_key_encryption_secret" ] &&
   [ -n "${JWT_SECRET:-}" ]; then
    encryption_secret=$JWT_SECRET
fi
save_secret client_key_encryption_secret "$encryption_secret"
echo '部署密钥已就绪；后续启动会复用已保存的密钥。'
