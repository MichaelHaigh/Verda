#!/bin/sh

# mariadb_mysql.sh
#
#
# Pre- and post-snapshot execution hooks for MariaDB and MySQL with NetApp Astra Control.
# Tested with MySQL 8.0.29 (deployed by Bitnami helm chart 9.1.7)/MariaDB 10.6.8 (deployed by Bitnami helm chart 11.0.13) and NetApp Astra Control Service 22.04.
#
# args: [pre|post]
# pre: Flush all tables with read lock
# post: Take database out of read-only mode
#

# Complex shell commands are difficult to get right through a remote execution api.
# For something like this obtuse procedure, an alternative approach is to mount a
# script into the container.

# To quiesce and hold mariadb/mysql databases we need to iterate over each one
# and open a client connection to it, then issue a 'flush tables with read lock'
# and then sleep, holding the connection open indefinitely.  When the snapshot
# is done, the read lock is released by terminating the mysql process (from
# outside this script)

# DB variants & config vars:
#
# It does not matter significantly if we are using Maria or MySQL, but in general the assumption
# is that if any of the relevant environment variables starting with 'MARIADB' are set, we're
# dealing with Maria and we should prefer those variables over the mysql versions.

#
# Invocation & auth variables
#
optfile="/tmp/freeze_opts"
hostname="localhost"
mysql="mysql --defaults-extra-file=${optfile}"
user="root"
password=""

#
# Operational parameters and commands
#
sleeptime=86400
sleep="SELECT SLEEP(${sleeptime})"
flush="FLUSH TABLES WITH READ LOCK; ${sleep}"

#
# Error codes
# These are important for finding out what went wrong from the other end of the k8s api
# Only change existing ones (delete deprecated and shift codes, frex) across version boundaries.
#
ebase=20
efilecreate=$((ebase+1))
edesync=$((ebase+2))
eresync=$((ebase+3))
eenboot=$((ebase+4))
edisboot=$((ebase+5))
eaccess=$((ebase+6))
eusage=$((ebase+7))
ebadaction=$((ebase+8))

#
# setup_auth figures out what to use for user and password and writes the options file out
#
# The password handling here is based on the conventions established by the Bitnami MariaDB & MySQL
# docker images.  We may need to expand this to account for other usage models but as of the time of
# writing don't know of anything else vaguely standard in the container world.
#
# Documentation:
# https://github.com/bitnami/bitnami-docker-mariadb
# https://github.com/bitnami/bitnami-docker-mysql
#
setup_auth() {
  setup_user
  setup_pass
  setup_hostname
  write_opt_file
  rc=$?
  return ${rc}
}

#
# setup_user overrides defaults with env vars if set
#
setup_user() {
  if [ -n "${MARIADB_ROOT_USER}" ] ; then
    user=${MARIADB_ROOT_USER}
  elif [ -n "${MYSQL_ROOT_USER}" ] ; then
    user=${MYSQL_ROOT_USER}
  fi
}

#
# setup_hostname overrides defaults with env vars if set
#
setup_hostname() {
  if [ -n "${HOSTNAME}" ] ; then
    hostname=${HOSTNAME}
    mysql="${mysql}  -h ${hostname}"
  fi
}

# setup_pass_file optionally overrides defaults and vars with a file
#
setup_pass_file() {
  if [ -n "${MARIADB_ROOT_PASSWORD_FILE}" ] ; then
    password=$(cat "${MARIADB_ROOT_PASSWORD_FILE}")
  elif [ -n "${MYSQL_ROOT_PASSWORD_FILE}" ] ; then
    password=$(cat "${MYSQL_ROOT_PASSWORD_FILE}")
  fi
}

#
# setup_pass figures out if we have a password in an env var to use
#
setup_pass() {
  setup_pass_file
  if [ -n "${password}" ]; then
    return
  fi
  if [ -n "${MARIADB_ROOT_PASSWORD}" ] ; then
    password=${MARIADB_ROOT_PASSWORD}
  elif [ -n "${MYSQL_ROOT_PASSWORD}" ] ; then
    password=${MYSQL_ROOT_PASSWORD}

  # if only MARIADB_MASTER_ROOT_PASSWORD is set, then it's a replication db ("sl*v*")
  elif [ -n "${MARIADB_MASTER_ROOT_PASSWORD}" ] ; then
    password=${MARIADB_MASTER_ROOT_PASSWORD}

  elif [ -n "${MYSQL_MASTER_ROOT_PASSWORD}" ] ; then
    password=${MYSQL_MASTER_ROOT_PASSWORD}
  fi
}

#
# test_access makes sure we can issue commands to the database
#
# the real freeze processes are started in the background and we can't ensure that they
# were started based on return codes.  Make sure we can execute commands by using a simple one here.
test_access() {
  ${mysql} -A -e 'show processlist;' >/dev/null 2>&1
  rc=$?
  if [ "${rc}" -ne "0" ] ; then
    return ${eaccess}
  fi
  return 0
}

#
# write_opt_file writes out a temporary authentication options file for the mysql client
#
write_opt_file() {
  echo "[client]" > ${optfile}
  echo "user=${user}" >> ${optfile}
  if [ -n "${password}" ] ; then
    echo "password=${password}" >> ${optfile}
  fi
  if [ ! -e ${optfile} ] ; then
    return ${efilecreate}
  fi
  #make sure opt file is not world write-able 
  chmod o-w ${optfile} 
  rc=$?
  if [ "${rc}" -ne "0" ] ; then
	return ${efilecreate}
  fi

  # Success
  return 0
}

#
# cleanup deletes any temporary files
#
cleanup() {
  rm -f ${optfile}
}

#
# enable_bootstrap sets safe_to_bootstrap to 1 in the grastate.dat file
#
enable_bootstrap() {
  rc=0
  echo "export MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes" >> /opt/bitnami/scripts/mariadb-env.sh
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "Error setting MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP in /opt/bitnami/scripts/mariadb-env.sh"
    break
  fi
  echo "export MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes" >> /opt/bitnami/scripts/mariadb-env.sh
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "Error setting MARIADB_GALERA_CLUSTER_BOOTSTRAP in /opt/bitnami/scripts/mariadb-env.sh"
    break
  fi
  sed -i 's/safe_to_bootstrap: 0/safe_to_bootstrap: 1/g' /bitnami/mariadb/data/grastate.dat
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "Error changing grastate.dat safe_to_bootstrap to 1"
    break
  fi
  sed -i 's/bootstrap: 0/bootstrap: 1/g' /bitnami/mariadb/data/gvwstate.dat
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "Error changing gvwstate.dat bootstrap to 1"
    break
  fi
}

#
# disable_bootstrap sets safe_to_bootstrap to 0 in the grastate.dat file
#
disable_bootstrap() {
  rc=0
  sed -i '/MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP/d' /opt/bitnami/scripts/mariadb-env.sh
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "Error removing MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP"
    break
  fi
  sed -i '/MARIADB_GALERA_CLUSTER_BOOTSTRAP/d' /opt/bitnami/scripts/mariadb-env.sh
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "Error removing MARIADB_GALERA_CLUSTER_BOOTSTRAP"
    break
  fi
  sed -i 's/safe_to_bootstrap: 1/safe_to_bootstrap: 0/g' /bitnami/mariadb/data/grastate.dat
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "Error changing grastate.dat safe_to_bootstrap to 0"
    break
  fi
  sed -i 's/bootstrap: 1/bootstrap: 0/g' /bitnami/mariadb/data/gvwstate.dat
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "Error changing gvwstate.dat bootstrap to 0"
    break
  fi
}

#
# desync stops the node from processing new transactions, but keeps it in the cluster
#
desync() {
  rc=0
  ${mysql} --execute "SET GLOBAL wsrep_desync = ON"
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "Error desyncing ${i}"
    break
  fi
}


#
# resync processes any transactions that are queued and waiting to be executed on the node
#
resync() {
  ${mysql} --execute "SET GLOBAL wsrep_desync = OFF"
  rc=$?
  if [ ${rc} -ne 0 ]; then
    echo "Error resuming databases"
    return ${rc}
  fi
}

#
# prepare_for_action sets up common parameters and auth for a primary action
#
prepare_for_action() {
  setup_auth
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "Error during setup"
    return ${rc}
  fi

  test_access
  rc=$?
  if [ ${rc} -ne 0 ]; then
    echo "Problem accessing database"
    return ${rc}
  fi
}

#
# "main"
#
action=$1
if [ -z "${action}" ]; then
  echo "Usage: $0 <pre|post>"
  exit ${eusage}
fi

if [ "${action}" != "pre" ] && [ "${action}" != "post" ]; then
  echo "Invalid subcommand: ${action}"
  exit ${ebadaction}
fi

prepare_for_action
rc=$?
if [ ${rc} -ne 0 ]; then
  echo "Error setting up for ${action}"
  cleanup
  exit ${rc}
fi

if [ "${action}" = "pre" ]; then
  desync
  rc=$?
  if [ ${rc} -ne 0 ]; then
    echo "Error desyncing node"
    exit ${edesync}
  fi
  enable_bootstrap
  rc=$?
  if [ ${rc} -ne 0 ]; then
    echo "Error enabling safe_to_bootstrap"
    exit ${eenboot}
  fi
elif [ "${action}" = "post" ]; then
  disable_bootstrap
  rc=$?
  if [ ${rc} -ne 0 ]; then
    echo "Error disabling safe_to_bootstrap"
    exit ${edisboot}
  fi
  resync
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "Error resyncing node"
    exit ${eresync}
  fi
fi

cleanup
exit ${rc}
