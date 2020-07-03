#!/bin/bash
# Ecrit dans un fichier de log la liste des VM de type CLONE
#  => fichier utilisé pour le morning check

. /opt/tls/libdcunix.sh || echo "Fichier /opt/tls/libdcunix.sh inexistant" && exit 1
. /opt/tls/ovm/libbackup.sh || echo "Fichier /opt/tls/ovm/libbackup.sh inexistant" && exit 1

## Variables
SCRIPT=`readlink -m ${0##*/}`
TODAY=`date +'%Y%m%d-%H%M'`
LOGFILE=/opt/tls/ovm/status/__status_SNAPSHOT__

## Functions
EndScript() {
    exit 0
}
trap EndScript INT EXIT

# Main
rm -f ${LOGFILE}

sshi list vm \
    | grep SNAPSHOT \
    | awk -F name\: '{print $2}' \
    > ${LOGFILE}

touch ${LOGFILE}
exit 0
