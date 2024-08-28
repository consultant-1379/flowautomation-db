#!/bin/bash
###########################################################################
# COPYRIGHT Ericsson 2018
#
# The copyright to the computer program(s) herein is the property of
# Ericsson Inc. The programs may be used and/or copied only with written
# permission from Ericsson Inc. or in accordance with the terms and
# conditions stipulated in the agreement/contract under which the
# program(s) have been supplied.
###########################################################################

#Standard linux commands
_GREP=/bin/grep
_ECHO=/bin/echo
_SED=/bin/sed
_AWK=/bin/awk

#For logging
LOG_TAG="FLOW_AUTOMATION"
SCRIPT_NAME="${0}"

#Comes from pom.xml properties via maven filtering.
readonly PG_CLIENT=@postgres.client@
readonly PG_USER=@postgres.user@
readonly PG_HOSTNAME=${POSTGRES_SERVICE:-@flowautomationds.serverName@}
readonly DB=@flowautomationds.databaseName@
readonly DB_ROLE=@flowautomationds.role.name@
readonly DB_ROLE_PSW=@flowautomationds.role.password@

#Variables
UPDATE_QUERY="UPDATE act_ge_property SET value_='2' WHERE name_='historyLevel';"

#######################################
# Action :
#   This function will print an INFO message to /var/log/messages
# Globals:
#   None
# Arguments:
#   $1 - Message string
# Returns:
#
#######################################
info() {
  logger -t ${LOG_TAG} -p user.notice "( ${SCRIPT_NAME} ): $1"
}

#######################################
# Action :
#   This function will print an ERROR message to /var/log/messages
# Globals:
#   None
# Arguments:
#   $1 - Message string
# Returns:
#
#######################################
error() {
  logger -t ${LOG_TAG} -p user.err "( ${SCRIPT_NAME} ): $1"
}

#######################################
# Action :
#   Restore Camunda Audit Level
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   0 if success
#   1 exit on failure.
#######################################
restoreCamundaAuditLevel() {
  #PGPASSWORD=fa_pass /opt/rh/postgresql92/root/usr/bin/psql -U fa_admin -h postgresql01 -d flowautomationdb -A -t -c "update act_ge_property set value_='2' where name_='historyLevel';"
  history_level=$(PGPASSWORD=${DB_ROLE_PSW} ${PG_CLIENT} -U ${DB_ROLE} -h ${PG_HOSTNAME} -d ${DB} -A -t -c "${UPDATE_QUERY}" 2>&1)
  # Verifying command execution
  if [ $? -eq 0 ]; then
      info "DB Updated successfully"
      return 0;
  else
      error "Error updating DB."
      exit 1
  fi
}

#////////////////////////////////
# Script main starts here.
#////////////////////////////////
info "Running Flow Automation Service pre-start"
restoreCamundaAuditLevel

info "Flow Automation Service pre-start completed"
exit 0
