#!/bin/bash
##########################################################################
# COPYRIGHT Ericsson 2019
#
# The copyright to the computer program(s) herein is the property of
# Ericsson Inc. The programs may be used and/or copied only with written
# permission from Ericsson Inc. or in accordance with the terms and
# conditions stipulated in the agreement/contract under which the
# program(s) have been supplied.
##########################################################################

#Standard linux commands
_ECHO=/bin/echo

#For logging
SCRIPT_NAME="${0}"
LOG_TAG="FLOW_AUTOMATION"

readonly GLOBAL_PROPS=/ericsson/tor/data/global.properties

#Comes from pom.xml properties via maven filtering.
readonly PG_CLIENT=@postgres.client@
readonly INSTALL_PATH=@install-path@
readonly CAMUNDA_DDL_PATH=${INSTALL_PATH}/@camunda-sql-path@
readonly FA_DDL_PATH=${INSTALL_PATH}/@fa-sql-path@
readonly PG_USER=@postgres.user@
readonly PG_HOSTNAME=${POSTGRES_SERVICE:-@flowautomationds.serverName@}
readonly DB=@flowautomationds.databaseName@
readonly DB_ROLE=@flowautomationds.role.name@
readonly DB_ROLE_PSW=@flowautomationds.role.password@

readonly FULL_VACUUM_START_TIME="015500"
readonly FULL_VACUUM_END_TIME="020500"
readonly ONE_MIN_IN_SECONDS=60

#Variables to be used for connecting to postgres
PG_PASSWORD=""
PG_COMMON_SCRIPTS_LIB_DIR=/ericsson/enm/pg_utils/lib
CONNECT_TO_FA_DB=""
LOGIN_TO_PG_SUPERUSER=""
LOGIN_AND_CONNECT_TO_FA_DB=""
CHECK_CLIENT_RUNNING_FULL_VACUUM=""

readonly CREATE="create"
readonly DROP="drop"
readonly UPGRADE="upgrade"
declare -a TABLES_TO_VACUUM=("act_hi_actinst" "act_ge_bytearray" "act_hi_varinst" "act_hi_procinst" "act_ru_execution" "act_ru_variable" "act_ru_job")
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
#   This function will print a WARNING message to /var/log/messages
# Globals:
#   None
# Arguments:
#   $1 - Message string
# Returns:
#
#######################################
warn() {
  logger -t ${LOG_TAG} -p user.warning "( ${SCRIPT_NAME} ): $1"
}

#######################################
# Action : 1
#   Decodes the postgres super user:"postgres" password.
# Globals:
#   GLOBAL_PROPS
#   postgresql01_admin_password (from global properties)
# Arguments:
#   None
# Returns:
#   None
#######################################
decode_postgres_password() {
  export_password
  PG_PASSWORD=$PGPASSWORD
}

#######################################
# Action : 3
#   Checks the connection to postgres server
# Globals:
#   LOGIN_TO_PG_SUPERUSER
#   PG_HOSTNAME
#   DB
# Arguments:
#   None
# Returns:
#   0 if success
#   1 exit on failure.
#######################################
check_postgres_service_running() {
  local is_running=$(sudo su - root -c "$LOGIN_TO_PG_SUPERUSER -A -t -c 'SELECT true;'" 2>&1)
  if [[ $? -eq 0 ]]; then
    info "Postgres is running on ${PG_HOSTNAME}."
  else
    exit_with_error "Postgres is not running on ${PG_HOSTNAME}. Error : ${is_running}"
  fi
}

#######################################
# Action : 4
#   A retry mechanism for connection to ${DB}.
# Globals:
#   DB
# Arguments:
#   None
# Returns:
#   0 if success
#   1 exit on failure.
#######################################
check_db_created() {
  sudo su - root -c "$LOGIN_TO_PG_SUPERUSER -A -t -c '${CONNECT_TO_FA_DB}'" >/dev/null 2>&1
  if [[ $? -ne 0 ]] ; then
    exit_with_error "There is currently no $DB on this server"
  fi
}

#######################################
# Action : 5
#   Execute Vaccum on ${DB}
# Globals:
#   PG_PASSWORD
#   PG_CLIENT
#   PG_USER
#   PG_HOSTNAME
#   DB
# Arguments:
#   None
#######################################
executeVacuum() {
  if is_execution_for_full_vacuum; then
    set_connection_limit 0
    for table in "${TABLES_TO_VACUUM[@]}"; do
      info "Performing vacuum full on table ${table}.."
      PGPASSWORD=${PG_PASSWORD} ${PG_CLIENT} -U ${PG_USER} -h ${PG_HOSTNAME} -d ${DB} -qAt -c "VACUUM FULL $table;" >/dev/null 2>&1
      if [[ $? -ne 0 ]]; then
        error "Failed to perform vacuum full on table $table.."
      fi
    done
    set_connection_limit -1
  else
    info "Performing VACUUM (not FULL) on ${DB}.."
    PGPASSWORD=${DB_ROLE_PSW} ${PG_CLIENT} -U ${DB_ROLE} -h ${PG_HOSTNAME} -d ${DB} -qAt -c "VACUUM;" >/dev/null 2>&1
  fi
}

is_execution_for_full_vacuum() {
  currentTime=$(date +%H%M%S)
  ((currentTime>=FULL_VACUUM_START_TIME && currentTime<=FULL_VACUUM_END_TIME))
  return $?
}

#######################################
# Action : set_connection_limit
#   Sets the database connection limit to the passed value.
# Globals:
#   PG_PASSWORD
#   PG_CLIENT
#   PG_USER
#   PG_HOSTNAME
#   DB
# Arguments:
#   1 - number of connections to set
# Returns:
#   None
#######################################
set_connection_limit() {
  local num_of_connections="$1"
  info "setting the $DB connection limit to ${num_of_connections}"
  PGPASSWORD=${PG_PASSWORD} ${PG_CLIENT} -U ${PG_USER} -h ${PG_HOSTNAME} -qAt -c "ALTER DATABASE ${DB} CONNECTION LIMIT ${num_of_connections};" >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    error "Failed to set the connection limit to ${num_of_connections} for ${DB}.."
  fi
}

#######################################
# Action : 2
#   Initializes the global variables for connecting to postgres.
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
initialize_variables() {
  CONNECT_TO_FA_DB="\c ${DB}"
  LOGIN_TO_PG_SUPERUSER="PGPASSWORD=${PG_PASSWORD} ${PG_CLIENT} -U ${PG_USER} -h ${PG_HOSTNAME} "
  LOGIN_AND_CONNECT_TO_FA_DB="${LOGIN_TO_PG_SUPERUSER} -d ${DB} "
  CHECK_CLIENT_RUNNING_FULL_VACUUM="SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname='flowautomationdb' AND pid <> pg_backend_pid() AND query LIKE '%VACUUM FULL%');"
}

exit_with_error() {
  error $1
  exit 1
}

#////////////////////////////////
# Script main starts here.
#////////////////////////////////
#Sourcing global config
. $GLOBAL_PROPS
source $PG_COMMON_SCRIPTS_LIB_DIR/pg_syslog_library.sh
source $PG_COMMON_SCRIPTS_LIB_DIR/pg_password_library.sh
source $PG_COMMON_SCRIPTS_LIB_DIR/pg_dblock_library.sh

decode_postgres_password
initialize_variables
check_postgres_service_running
check_db_created
if ! lockDb; then
  exit_with_error "Error while trying to acquire lock on database"
fi
trap 'unlockDb "$DB_LOCK_OWNER"' EXIT
executeVacuum
exit 0
