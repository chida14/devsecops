#!/bin/bash

set -eo pipefail

JENKINS_URL="http://cmandolk.australiasoutheast.cloudapp.azure.com:8080"
AUTH="admin:${JENKINS_TOKEN}"   # or admin:YOUR_API_TOKEN

java -jar jenkins-cli.jar -s "$JENKINS_URL" -auth "$AUTH" install-plugin \
  performance docker-workflow dependency-check-jenkins-plugin blueocean \
  coverage \
  slack sonar pitmutation kubernetes-cli \
  -deploy -restart

