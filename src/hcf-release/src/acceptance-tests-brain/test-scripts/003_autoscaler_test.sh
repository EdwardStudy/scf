#!/bin/bash

set -o errexit
set -o xtrace

function random_suffix { head -c2 /dev/urandom | hexdump -e '"%04x"'; }
CF_ORG=${CF_ORG:-org}-$(random_suffix)
CF_SPACE=${CF_SPACE:-space}-$(random_suffix)

# where do i live ?
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# configuration
POL=${DIR}/../test-resources/policy.json
APP=${DIR}/../test-resources/php-mysql
APP_NAME=scale-test-app-$(random_suffix)
SCALESERVICE=scale-test-service

# login
cf api --skip-ssl-validation api.${CF_DOMAIN}
cf auth ${CF_USERNAME} ${CF_PASSWORD}

# create organization
cf create-org ${CF_ORG}
cf target -o ${CF_ORG}

# create space
cf create-space ${CF_SPACE}
cf target -s ${CF_SPACE}

# push an app
( cd ${APP}
  cf push ${APP_NAME}
)

# test autoscaler
cf create-service app-autoscaler default ${SCALESERVICE}
cf bind-service ${APP_NAME} ${SCALESERVICE}
cf restage ${APP_NAME}
cf autoscale set-policy ${APP_NAME} ${POL}

sleep 60
instances=$(cf apps|grep ${APP_NAME}|awk '{print $3}'|cut -f 1 -d /)

cf unbind-service ${APP_NAME} ${SCALESERVICE}

cf delete-service -f ${SCALESERVICE}

cf delete -f ${APP_NAME}

# delete space
cf delete-space -f ${CF_SPACE}

# delete org
cf delete-org -f ${CF_ORG}

[ -z "${instances}" ] && instances=0

if [ ! ${instances} -gt 1 ];
then
  echo "ERROR autoscaling app"
  echo "Autoscaling failed, only ${instances} instance(s)"
  exit 1
fi