#!/bin/bash
##########################################################################
# COPYRIGHT Ericsson 2018
#
# The copyright to the computer program(s) herein is the property of
# Ericsson Inc. The programs may be used and/or copied only with written
# permission from Ericsson Inc. or in accordance with the terms and
# conditions stipulated in the agreement/contract under which the
# program(s) have been supplied.
##########################################################################

#Standard linux commands
_GREP=/bin/grep
_ECHO=/bin/echo
_SORT=/bin/sort
_FIND=/bin/find
_SED=/bin/sed
_HEAD=/usr/bin/head
_TAIL=/usr/bin/tail
_BASENAME=/bin/basename
_LS=/bin/ls
_AWK=/bin/awk
_CAT=/bin/cat

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

#Variables to be used for connecting to postgres
PG_PASSWORD=""
PG_COMMON_SCRIPTS_LIB_DIR=/ericsson/enm/pg_utils/lib
CONNECT_TO_FA_DB="\c ${DB}"
FA_SCHEMA_VERSION_QUERY="SELECT version FROM fa_db_version WHERE schema_group = 'FlowAutomation' ORDER BY updated_date DESC LIMIT 1;"
NUM_TRIES_FOR_CREATEDB=3
WAIT_TIME_FOR_CREATEDB=1
NUM_TRIES_FOR_CREATEROLE=3
WAIT_TIME_FOR_CREATEROLE=1
INITIAL_INSTALL_VERSION="0.0.0"
CAMUNDA_SCHEMA_EXISTS="SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'act_ge_property');"
FA_SCHEMA_EXISTS="SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'fa_db_version');"
DB_LOCKED_QUERY="SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'install_lock');"
PG_TERMINATE_CONNECTIONS="SELECT pg_terminate_backend(pid) FROM pg_stat_get_activity(NULL::integer) WHERE pid <> pg_backend_pid() AND datid=(SELECT oid from pg_database where datname = 'flowautomationdb') AND usesysid=(SELECT usesysid from pg_user where usename = 'fa_admin');"
CAMUNDA_SCHEMA_TABLE_EXISTS_QUERY="SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'act_ge_schema_log');"
CAMUNDA_SCHEMA_VERSION_QUERY="SELECT MAX(version_) FROM act_ge_schema_log;"

readonly CREATE="create"
readonly DROP="drop"
readonly UPGRADE="upgrade"

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
# Action :
#   Runs an SQL query on flowautomationdb as fa_admin
# Globals:
#   DB_ROLE_PSW
#   PG_CLIENT
#   DB_ROLE
#   PG_HOSTNAME
#   DB
# Arguments:
#   query
# Returns:
#   None
#######################################
fa_user_login_and_connect_to_fa_db(){
  local sqlquery=$*
  PGPASSWORD=${DB_ROLE_PSW} ${PG_CLIENT} -U ${DB_ROLE} -h ${PG_HOSTNAME} -d ${DB} -A -t -c "${sqlquery}" 2>&1
}

#######################################
# Action :
#   Runs an SQL command towards postgres
# Globals:
#   PG_PASSWORD
#   PG_CLIENT
#   PG_USER
#   PG_HOSTNAME
# Arguments:
#   sqlcommand
# Returns:
#   None
#######################################
login_to_pg_superuser(){
  local sqlcommand=$*
  PGPASSWORD=${PG_PASSWORD} ${PG_CLIENT} -U ${PG_USER} -h ${PG_HOSTNAME} -A -t -c "${sqlcommand}" 2>&1
}

#######################################
# Action : 3
#   Checks the connection to postgres server
# Globals:
#   PG_HOSTNAME
#   DB
# Arguments:
#   None
# Returns:
#   0 if success
#   1 exit on failure.
#######################################
check_postgres_service_running() {
  is_running=$(login_to_pg_superuser "select true;")
  if [ $? -eq 0 ]; then
    info "Postgres is running on ${PG_HOSTNAME}. we can now deploy database ${DB} objects!"
  else
    exit_with_error "Postgres is not running on ${PG_HOSTNAME}. Hence cannot install database ${DB} Objects at this time. Error : ${is_running}"
  fi
}

#######################################
# Action : 4
#   A retry mechanism for ${DB} db creation if it does not exist.
# Globals:
#   NUM_TRIES_FOR_CREATEDB
#   WAIT_TIME_FOR_CREATEDB
#   DB
# Arguments:
#   None
# Returns:
#   0 if success
#   1 exit on failure.
#######################################
check_and_create_db() {
  if ! createDb; then
    exit_with_error "createDb failed. "
  fi
}

#######################################
# Action : 4.1
#   Creates the db ${DB} if does not exist.
# Globals:
#   CONNECT_TO_FA_DB
#   DB
# Arguments:
#   None
# Returns:
#   0 if success
#   1 exit on failure.
#######################################
is_flowautomationdb_created() {
  login_to_pg_superuser ${CONNECT_TO_FA_DB}
  return_code=$?
  if [ $return_code -eq 0 ]; then
    info "Database '$DB' exists, Can now continue..."
  else
    info "Database '$DB' does not exists, Creating now..."
    login_to_pg_superuser "CREATE DATABASE ${DB}"
    return_code=$?
    if [ $return_code -eq 0 ]; then
      info "Database '$DB' created, Can now continue..."
    fi
  fi
  return $return_code
}

#######################################
# Action : 5
#   A retry mechanism for flowautomation db role creation.
# Globals:
#   NUM_TRIES_FOR_CREATEROLE
#   WAIT_TIME_FOR_CREATEROLE
#   DB_ROLE
# Arguments:
#   None
# Returns:
#   0 if success
#   1 exit on failure.
#######################################
check_and_create_db_role() {
  if ! role_create "NOSUPERUSER NOCREATEDB NOCREATEROLE"; then
    exit_with_error "Could not correctly create the role."
  fi
}

function updateRole(){
  #Check the role exists
  if ! check_role_exists; then
    exit_with_error "Role $DB_ROLE doesnt exist"
  fi
  if ! change_db_ownership; then
    exit_with_error "Could not change ownership of db $DB to role $DB_ROLE"
  fi
  if ! grant_connect_privilege_on_database_for_role; then
    exit_with_error "failed to grant connect priveleges on db $DB for role $DB_ROLE"
  fi
  if ! revoke_connect_for_user_on_database; then
    exit_with_error "failed to revoke public privileges on db $DB"
  fi
}

check_and_create_db_schema() {
  local camunda_schema_exists_in_db=$(fa_user_login_and_connect_to_fa_db ${CAMUNDA_SCHEMA_EXISTS})
  if [ $? -eq 0 ]; then
    local fa_schema_exists_in_db=$(fa_user_login_and_connect_to_fa_db ${FA_SCHEMA_EXISTS})
    if [[ "${camunda_schema_exists_in_db,,}" =~ ^f.* ]]; then
      process_camunda_initial_install_request
      process_flowautomation_schema_request "$INITIAL_INSTALL_VERSION"
    elif [[ "${camunda_schema_exists_in_db,,}" =~ ^t.* ]] && [[ "${fa_schema_exists_in_db}" =~ ^t.* ]]; then
      schema_version_in_db=$(fa_user_login_and_connect_to_fa_db ${FA_SCHEMA_VERSION_QUERY})
      if [ $? -eq 0 ]; then
        info "The flowautomation schema version in db is $schema_version_in_db"
        latest_ddl_available=$($_FIND ${FA_DDL_PATH} -name "FlowAutomationSchema?*.ddl" -exec basename {} \; | $_SORT --version-sort | $_TAIL -n1)
        info "The latest DDL file.version available in the release is $latest_ddl_available"
        process_flowautomation_schema_request "${schema_version_in_db}"
      else
        exit_with_error "Unable to get schema version in db: $schema_version_in_db"
      fi

      upgrade_camunda_schema_if_required
    elif [[ "${camunda_schema_exists_in_db,,}" =~ ^t.* ]] && [[ "${fa_schema_exists_in_db}" =~ ^f.* ]]; then
      info "The camunda schema exists and fa schema doesn't exists.."
      process_flowautomation_schema_request "$INITIAL_INSTALL_VERSION"
      upgrade_camunda_schema_if_required
    else
      exit_with_error "Unexpected query response $camunda_schema_exists_in_db, $fa_schema_exists_in_db, Failed to check if schema exists."
    fi
  else
    exit_with_error "Unable to determine the schema existence."
  fi
}

upgrade_camunda_schema_if_required() {
  info "Checking if upgrade of camunda schema required!!"
  # Check camunda version in db, if not found assume it to be 7.9.0
  # Then run all the upgrade scripts which are newer than current version.
  local camunda_schema_table_exists=$(fa_user_login_and_connect_to_fa_db ${CAMUNDA_SCHEMA_TABLE_EXISTS_QUERY})
  if [[ "${camunda_schema_table_exists,,}" =~ ^t.* ]]; then
    camunda_schema_version_in_db=$(fa_user_login_and_connect_to_fa_db ${CAMUNDA_SCHEMA_VERSION_QUERY})
  elif [[ "${camunda_schema_table_exists,,}" =~ ^f.* ]]; then
    camunda_schema_version_in_db='7.9.0'
  else
    exit_with_error "Failed to determine if the camunda schema table act_ge_schema_log exists. $camunda_schema_table_exists"
  fi

  info "The current version of camunda schema in the database is $camunda_schema_version_in_db"
  local upgrade_scripts_to_execute=""
  local upgrade_required=false
  for script in $($_LS -A "${CAMUNDA_DDL_PATH}/${UPGRADE}" | $_SORT -V); do
    if is_camunda_upgrade_script_newer_than_current_version "$script" "$camunda_schema_version_in_db"; then
      upgrade_required=true
      upgrade_scripts_to_execute="${upgrade_scripts_to_execute} ${CAMUNDA_DDL_PATH}/${UPGRADE}/${script}"
    fi
  done

  if [[ ${upgrade_required} == true ]]; then
    info "The upgrade command to be executed in a single transaction is ${upgrade_scripts_to_execute}"

    #terminate existing connections to flowautomationdb
    terminate_connections=$(fa_user_login_and_connect_to_fa_db ${PG_TERMINATE_CONNECTIONS})
    if [[ $? -ne 0 ]]; then
      error "Failed to terminate the active connections, reason: ${terminate_connections}"
    fi
    # Execute all the upgrade scripts together within a single transaction, using -1 option below
    info "Trying to run the upgrade scripts!!"
    local upgrade_logs=$($_CAT ${upgrade_scripts_to_execute} | PGPASSWORD=${DB_ROLE_PSW} ${PG_CLIENT} --single-transaction -U ${DB_ROLE} -h ${PG_HOSTNAME} -d ${DB} 2>&1)
    info "Logs after running camunda upgrade scripts:${upgrade_logs}"
  fi

}

#######################################
# Action : 6.3
#   The schema to be executed.
# Globals:
#   FA_DDL_PATH
# Arguments:
#   $1 ddl files to execute
#   $2 version
#   $3 version query
# Returns:
#   0 if success
#   1 exit on failure.
#######################################
process_flowautomation_schema_request() {
  local schema_version_in_db="$1"
  local available_ddl_files=$($_FIND $FA_DDL_PATH -name "FlowAutomationSchema?*.ddl" -exec basename {} \; | $_SORT --version-sort)
  for ddl_file in $available_ddl_files; do
    ddl_version=$($_ECHO "${ddl_file}" | $_SED "s/FlowAutomationSchema_//" | $_SED "s/\.[^.]*$//" | $_SED "s/\_/./g")
    if is_version_less_than "${schema_version_in_db}" "${ddl_version}"; then
      execute_schema_script "${FA_DDL_PATH}/${ddl_file}"
      verify_schema_in_db_equals_version "${ddl_version}"
    fi
  done
}

is_version_less_than() {
  local smaller_version=$($_ECHO -e "$1\n$2" | $_SORT -V | $_HEAD -n1)
  if [[ "$1" != "$2" ]] && [[ "$1" == "$smaller_version" ]]; then
    return 0
  fi
  return 1
}

is_camunda_upgrade_script_newer_than_current_version() {
  local current_version="$2"
  local upgrade_script_version=$($_BASENAME "$1" | $_AWK -F'_' '{print $3}')
  ! is_version_less_than "$upgrade_script_version.0" "$current_version"
  return $?
}

#######################################
# Action : 6.3.3
#   Function to verify the correct schema version is executed.
# Globals:
#   None
# Arguments:
#   $1 Schema version query
#   $2 DDL Version
# Returns:
#   0 if success
#   1 exit on failure.
#######################################
verify_schema_in_db_equals_version() {
  local expected_version="$1"
  local schema_version_in_db=$(fa_user_login_and_connect_to_fa_db ${FA_SCHEMA_VERSION_QUERY})
  if [ $? -eq 0 ]; then
    if [ "$expected_version" == "$schema_version_in_db" ]; then
      info "Version $expected_version installed successfully"
      return 0
    fi
  fi
  exit_with_error "Error applying schema version $expected_version . Exiting with error, $schema_version_in_db"
}

#######################################
# Action :
#   Goes through all the sql files in a given path and executes them.
# Globals:
#   None
# Arguments:
#   $1 root directory
#   $2 subdirectory to execute
# Returns:
#   0 if success
#   1 exit on failure.
#######################################
process_camunda_initial_install_request() {
  info "Path with scripts to be executed ${CAMUNDA_DDL_PATH}/${CREATE}"
  for sql_file in "${CAMUNDA_DDL_PATH}/${CREATE}"/*.sql; do
    execute_schema_script "${sql_file}"
  done
}
#######################################
# Action :
#   Helper function.
# Globals:
#   DB_ROLE_PSW
#   PG_CLIENT
#   DB_ROLE
#   PG_HOSTNAME
#   DB
# Arguments:
#   $1 schema sql file to execute
# Returns:
#   0 if success
#   1 exit on failure.
#######################################
execute_schema_script() {
  local schema_script=$1
  info "sql/ddl to be executed = ${schema_script}"
  PGPASSWORD=${DB_ROLE_PSW} ${PG_CLIENT} -U ${DB_ROLE} -h ${PG_HOSTNAME} -d ${DB} -q -w -f "${schema_script}"
  if [ $? -ne 0 ]; then
    exit_with_error "Failed to execute schema sql ${schema_script}"
  fi
}

#////////////////////////////////
# Script main starts here.
#////////////////////////////////
#Sourcing global config
. $GLOBAL_PROPS
source $PG_COMMON_SCRIPTS_LIB_DIR/pg_syslog_library.sh
source $PG_COMMON_SCRIPTS_LIB_DIR/pg_password_library.sh
source $PG_COMMON_SCRIPTS_LIB_DIR/pg_dblock_library.sh
source $PG_COMMON_SCRIPTS_LIB_DIR/pg_dbcreate_library.sh
source $PG_COMMON_SCRIPTS_LIB_DIR/pg_rolecreate_library.sh

decode_postgres_password
check_postgres_service_running
check_and_create_db
if ! lockDb; then
  exit_with_error "Error while trying to acquire lock on database"
fi
trap 'unlockDb "$DB_LOCK_OWNER"' EXIT
check_and_create_db_role
updateRole
check_and_create_db_schema

