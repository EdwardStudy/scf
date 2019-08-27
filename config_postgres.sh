#!/bin/bash
#
# ########################################################### {COPYRIGHT-TOP} ####
# # Licensed Materials - Property of IBM
# # IBM Cloud
# #
# # (C) Copyright IBM Corp. 2018
# #
# # US Government Users Restricted Rights - Use, duplication, or
# # disclosure restricted by GSA ADP Schedule Contract with IBM Corp.
# ########################################################### {COPYRIGHT-END} ####
#

set -eEu -o pipefail
shopt -s extdebug

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../" && pwd)"

source "${WORKSPACE}"/scripts/postgres_utils.sh
echo -e "\\n========== START CONFIGURING POSTGRES =========="

HOST=$1
PORT=$2
USER=$3
PASSWORD=$4
DBNAME=$5
FORCEDROP=$6

if [ "${HOST}" == "" ]; then
  echo "[ERROR] You must specify Postgres Host"
  exit 1
fi
if [ "${PORT}" == "" ]; then
  echo "[ERROR] You must specify Postgres Port"
  exit 1
fi
if [ "${USER}" == "" ]; then
  echo "[ERROR] You must specify User of Postgres"
  exit 1
fi
if [ "${PASSWORD}" == "" ]; then
  echo "[ERROR] You must specify Password for the User of Postgres"
  exit 1
fi
if [ "${DBNAME}" == "" ]; then
  echo "[ERROR] You must specify Default Database name of Postgres"
  exit 1
fi
if [ "${FORCEDROP}" == "" ]; then
  echo "[INFO] set FORCEDROP to false by default"
  FORCEDROP="false"
fi


echo "[INFO] Config External Postgres ${HOST}:${PORT}"

# To ensure psql login with no password prompted
export PGPASSWORD=${PASSWORD}
max_attempts=3
if [ "${FORCEDROP}" == "true" ]; then
  echo "[INFO] Force close active connections, drop databases, roles and extensions before creations"
  echo "[INFO] Grant pg_signal_backend to admin user to close active connections"
  pgexec "${DBNAME}" "GRANT pg_signal_backend TO admin"
  for db_name in cloud_controller uaa diego locket routing_api
  do
    if pgexec "${DBNAME}" "SELECT 1 FROM pg_database WHERE datname='${db_name}'" |grep -q "1 row"
    then
      echo "[INFO] Database ${db_name} exists"

      echo "[INFO] Delete extenstion citext for Database ${db_name}"
      pgexec "${db_name}" "DROP EXTENSION IF EXISTS citext CASCADE"

      echo "[INFO] Delete extenstion pgcrypto for Database ${db_name}"
      pgexec "${db_name}" "DROP EXTENSION IF EXISTS pgcrypto"

      for (( i=1; i<=max_attempts; i++ ))
      do
        echo "[INFO] Close all active connections in Database ${db_name}"
        pgexec "${DBNAME}" "SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.datname = '${db_name}' AND pg_stat_activity.pid <> pg_backend_pid()"

        echo "[INFO] Drop Database ${db_name}"
        if pgexec "${DBNAME}" "DROP DATABASE IF EXISTS ${db_name}" > /dev/null 2>&1; then
          echo "[INFO] Database ${db_name} is dropped successfully"
          break
        elif [ ${i} -eq ${max_attempts} ]; then
          echo "[ERROR] Failed to drop Database ${db_name} after retry ${max_attempts} times"
          exit 1
        else
          echo "[INFO] Failed to drop Database ${db_name} after retry ${i} time(s), retry again..."
        fi
      done
    else
      echo "[INFO] Database ${db_name} does not exists."
    fi
  done
  echo "[INFO] Revoke pg_signal_backend from admin user"
  pgexec "${DBNAME}" "REVOKE pg_signal_backend FROM admin"

  for role_name in cloud_controller uaa diego locket routing_api
  do
    echo "[INFO] Delete role ${role_name}."
    pgexec "${DBNAME}" "DROP ROLE IF EXISTS ${role_name}"
  done
fi

for db_name in cloud_controller uaa diego locket routing_api network_policy
do
  if pgexec "${DBNAME}" "SELECT 1 FROM pg_database WHERE datname='${db_name}'" |grep -q "1 row"
  then
    echo "[ERROR] Database ${db_name} already exists. Specify --forcedrop true if you want to force drop it"
    exit 1
  else
     # Create databases in Postgres
     create_database ${db_name} true
  fi
done

# Create roles in Postgres
cloud_controller_password=$(generate_password)
uaa_password=$(generate_password)
diego_password=$(generate_password)
locket_password=$(generate_password)
routing_api_password=$(generate_password)

create_role cloud_controller "${cloud_controller_password}"
create_role uaa "${uaa_password}"
create_role diego "${diego_password}"
create_role locket "${locket_password}"
create_role routing_api "${routing_api_password}"

# Render external-db-password-secret.yml
export cloud_controller_password
export uaa_password
export diego_password
export locket_password
export routing_api_password

echo "cloud_controller_password: ${cloud_controller_password}"
echo "uaa_password: ${uaa_password}"
echo "diego_password: ${diego_password}"
echo "locket_password: ${locket_password}"
echo "routing_api_password: ${routing_api_password}"

echo -e "\\n========== END CONFIGURING POSTGRES =========="
