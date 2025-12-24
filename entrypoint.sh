#!/bin/bash
set -eo pipefail

echo "Launching MariaDB server..."
mkdir -p /var/run/mysqld
chown mysql:mysql /var/run/mysqld
/usr/sbin/mysqld --user=mysql --datadir=/var/lib/mysql --skip-networking --socket=/var/run/mysqld/mysqld.sock &
MYSQL_PID=$!
sleep 3 # Wait for mysql to start up

# Проверяем, жив ли процесс mysqld (процесс мог завершиться сразу из-за ошибки)
if ! kill -0 $MYSQL_PID 2>/dev/null; then
    echo "ERROR: MariaDB process failed to start." >&2
    exit 1
fi

echo "Creating Slurm account database..."
# Дожидаемся готовности MySQL
timeout=5
while [ $timeout -gt 0 ]; do
    if mysqladmin ping --silent 2>/dev/null; then
        break
    fi
    sleep 1
    ((timeout--))
done
if [ $timeout -eq 0 ]; then
    echo "ERROR: Timeout waiting for MariaDB." >&2
    exit 1
fi
mysql -NBe "CREATE DATABASE IF NOT EXISTS slurm_acct_db"
mysql -NBe "CREATE USER IF NOT EXISTS 'slurm'@'localhost'"
mysql -NBe "GRANT USAGE ON *.* to 'slurm'@'localhost'"
mysql -NBe "GRANT ALL PRIVILEGES on slurm_acct_db.* to 'slurm'@'localhost'"
mysql -NBe "FLUSH PRIVILEGES"

echo "Create munge key..."
dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 0600 /etc/munge/munge.key

echo "Starting munge..."
runuser -u munge -- /usr/sbin/munged --num-threads=10 --foreground &
MUNGE_PID=$!
sleep 2

# Быстрая проверка, что MUNGE работает
echo "Testing MUNGE authentication for Slurm user..."
if ! runuser -u slurm -- munge -n | unmunge 2>/dev/null; then
    echo "WARNING: MUNGE test for 'slurm' user failed. Slurm daemons may not authenticate."
    echo "         Check that /etc/munge/munge.key is readable by user 'slurm'."
fi

echo "Creating JWT key..."
mkdir -p /var/slurmstate
chown slurm:slurm /var/slurmstate
dd if=/dev/random of=/var/slurmstate/jwt_hs256.key bs=32 count=1
chown slurm:slurm /var/slurmstate/jwt_hs256.key
chmod 0600 /var/slurmstate/jwt_hs256.key

echo "Starting slurmdbd..."
/usr/sbin/slurmdbd -D &
SLURMDBD_PID=$!
sleep 3 # Wait for slurmdbd to start up

echo "Starting slurmctld..."
/usr/sbin/slurmctld -Dc &
SLURMCTLD_PID=$!
sleep 3

# Wait for slurmctld to start up
echo "Waiting for slurmctld to start..."
timeout=5
while [ $timeout -gt 0 ]; do
  echo "  Pinging slurmctld...";
  if scontrol ping | grep -q 'UP'; then
    echo "slurmctld is up"
    break
  fi
  sleep 1
  ((timeout--))
done

if [ $timeout -eq 0 ]; then
    echo "ERROR: slurmctld failed to start"
    exit 1
fi

echo "Starting slurmd..."
/usr/sbin/slurmd -D -N c1 &
SLURMD_PID=$!
sleep 2

echo "Starting slurmrestd..."
SLURM_JWT=daemon /usr/sbin/slurmrestd -u slurm 0.0.0.0:6820 &
SLURMRESTD_PID=$!
sleep 2

# Создание тестовых аккаунтов (только если они не существуют)
echo "Checking for existing accounts..."
if ! sacctmgr list account -n | grep -q "account1"; then
    echo "Creating mock user accounts..."
    sacctmgr -i add account account1 description="account1_desc" organization="account1_org"
    sacctmgr -i add account account2 description="account2_desc" organization="account2_org"
else
    echo "Mock accounts already exist"
fi

echo "Environment is ready"
hostname
exec "$@"
