#!/bin/bash

# This test checks that SSO does push us to the underlying app if we are
# authenticated correctly

set -o errexit
set -o xtrace

# where do i live ?
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

APP_NAME=go-env
DESIRED_STRING="INSTANCE_INDEX=0"
SSO_SERVICE="sso-service-test-brain"
DOMAIN=$(echo $CF_API | sed -e 's/^[^.]*\.//')

# login
cf api --skip-ssl-validation ${CF_API}
cf auth ${CF_USERNAME} ${CF_PASSWORD}

do_cleanup() {
    # unbind route
    if test -n "${hostname:-}" ; then
        cf unbind-route-service ${DOMAIN} ${SSO_SERVICE} -f --hostname ${hostname}
    fi

    cf delete-service -f ${SSO_SERVICE}

    # cleanup
    cf delete -f node-env
    cf delete-space -f ${SPACE}
    cf delete-org -f ${ORG}
}
trap do_cleanup EXIT

# create org and space
cf create-org ${ORG}
cf target -o ${ORG}
cf create-space ${SPACE}
cf target -s ${SPACE}

# push an app
cd ${DIR}/../test-resources/${APP_NAME}-*
cf push ${APP_NAME}

url=${APP_NAME}.${DOMAIN}
test -n "${url}"
hostname="${url%%.*}"
test -n "${hostname}"

# Test that the app is working as intended (before SSO)
curl "${url}/env" | grep ${DESIRED_STRING}

# Set up SSO
cf create-service sso-routing default ${SSO_SERVICE}
cf bind-route-service ${DOMAIN} ${SSO_SERVICE} --hostname ${hostname}

# SSO only applies after restaging
cf restage ${APP_NAME}

# Check that the output is correct
oauth_token="$(cf oauth-token | cut -d ' ' -f 2-)" # Drop the "bearer" prefix
curl --cookie "ssoCookie=${oauth_token}" "${url}/env" 1>/tmp/${APP_NAME}.log

if ! grep ${DESIRED_STRING} /tmp/${APP_NAME}.log ; then
    printf "%bERROR%b SSO failed to have expected output" "${RED}" "${NORMAL}"
    command="${me} curl --cookie ssoCookie=${oauth_token:0:8}... ${url}/env"
    echo "SSO failed to have expected output"
    echo "${command} headers:"
    cat /tmp/${APP_NAME}.header
    echo "${command} body:"
    cat /tmp/${APP_NAME}.log
fi
