#!/bin/bash

. /opt/tls/libdcunix.sh || echo "Fichier /opt/tls/libdcunix.sh inexistant"
. /opt/tls/ovm/libbackup.sh  ||  echo "Fichier /opt/tls/ovm/libbackup.sh inexistant"

rm -f /tmp/OVM_Remove_GX_Backup.script

#pstatus blue "Remove des GX_Backup"
sshi list vm | grep GX_BACKUP | awk -Fid: '{print $2}' |\
    while read id x; do
        echo sshi delete vm id=$id >> /tmp/OVM_Remove_GX_Backup.script
    done

test -f /tmp/OVM_Remove_GX_Backup.script && . /tmp/OVM_Remove_GX_Backup.script

rm -f /tmp/OVM_Remove_GX_Backup.script

exit 0
