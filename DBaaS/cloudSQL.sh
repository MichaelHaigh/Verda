#!/bin/bash

BACKUP_DESCRIPTION=$(date "+%Y%m%d%H%M%S")

# Error Codes
ebase=20
eusage=$((ebase+1))
eaction=$((ebase+2))
efailedbackup=$((ebase+3))

gcloud_login() {
  echo "--> logging into gcloud based on mounted SA creds"
  gcloud auth activate-service-account --key-file=/etc/gcloud/gcloud-credentials.json
}

install_jq() {
  echo "--> Installing jq"
  apt-get install -y jq
  if [ ${rc} -ne 0 ] ; then
    echo "--> Error installing jq"
    return ${rc}
  fi
}

prepare_for_action() {
  gcloud_login
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "--> Error logging into gcloud"
    return ${rc}
  fi

  install_jq
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "--> Error checking for / installing jq"
    return ${rc}
  fi
}

gcloud_sql_backup() {
  echo "--> creating asynchronous Cloud SQL backup for ${DBAAS_NAME}"
  gcloud sql backups create --async --instance=${DBAAS_NAME} --description=${BACKUP_DESCRIPTION}
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "--> Error initiating Cloud SQL backup for ${DBAAS_NAME}"
    return ${rc}
  fi
}

gcloud_check_ops() {
  while true; do
    sleep 5
    echo "--> checking for any running operations on ${DBAAS_NAME}"
    NUM_RUNNING_OPS=$(gcloud sql operations list --instance=${DBAAS_NAME} --format=json | jq -r '.[] | select(.status == "RUNNING") | .name' | wc -l)
    rc=$?
    if [ ${rc} -ne 0 ] ; then
      echo "--> Error checking number of running operations"
      return ${rc}
    fi
    echo "--> ${NUM_RUNNING_OPS} running operation(s) on ${DBAAS_NAME}"
    if [ ${NUM_RUNNING_OPS} -eq 0 ] ; then
      break
    fi
  done
}

gcloud_check_backup_status() {
  echo "--> checking status on all backups for ${DBAAS_NAME}"
  FAILED_BACKUPS=$(gcloud sql backups list --instance=${DBAAS_NAME} --format=json | jq -r '.[] | select(.type == "ON_DEMAND") | select((.status != "SUCCESSFUL") and (.status != "RUNNING")) | .id' | wc -l)
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "--> Error running backups list on ${DBAAS_NAME}"
    return ${rc}
  fi
  if [ ${FAILED_BACKUPS} -gt 0 ] ; then
    echo "--> Error: failed backup found on ${DBAAS_NAME}"
    exit ${efailedbackup}
  fi
}

gcloud_delete_backup() {
  echo "--> deleting oldest ON_DEMAND backup for ${DBAAS_NAME}"
  BACKUP_ID=$(gcloud sql backups list --instance=${DBAAS_NAME} --format=json | jq -r '.[] | select(.type == "ON_DEMAND") | .id' | tail -1)
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "--> Error running backups list on ${DBAAS_NAME}"
    return ${rc}
  fi
  gcloud sql backups delete ${BACKUP_ID} --instance=${DBAAS_NAME} --async --quiet
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "--> Error deleting backup ${BACKUP_ID} from ${DBAAS_NAME}"
    return ${rc}
  fi
  sleep 5
  gcloud_check_ops
}

gcloud_check_num_backups() {
  echo "--> checking for number of ON_DEMAND backups on ${DBAAS_NAME}"
  NUM_BACKUPS=$(gcloud sql backups list --instance=${DBAAS_NAME} --format=json | jq -r '.[] | select(.type == "ON_DEMAND") | .id' | wc -l)
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "--> Error running backups list for ${DBAAS_NAME}"
    return ${rc}
  fi
  while [ ${NUM_BACKUPS} -gt ${BACKUPS_TO_KEEP} ] ; do
    echo "--> Backups found: ${NUM_BACKUPS} is greater than backups to keep: ${BACKUPS_TO_KEEP}"
    gcloud_delete_backup
    NUM_BACKUPS=$(gcloud sql backups list --instance=${DBAAS_NAME} --format=json | jq -r '.[] | select(.type == "ON_DEMAND") | .id' | wc -l)
    rc=$?
    if [ ${rc} -ne 0 ] ; then
      echo "--> Error running backups list for ${DBAAS_NAME}"
      return ${rc}
    fi
  done
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
  exit ${eaction}
fi

prepare_for_action
if [ ${rc} -ne 0 ]; then
  echo "--> Error setting up for ${action}"
  exit ${rc}
fi

if [ "${action}" = "pre" ]; then
  gcloud_sql_backup
else
  gcloud_check_ops
  gcloud_check_backup_status
  gcloud_check_num_backups
fi
