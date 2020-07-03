!/bin/bash

. /opt/tls/libdcunix.sh || echo "Fichier /opt/tls/libdcunix.sh inexistant" && exit 1
. /opt/tls/ovm/libbackup.sh  ||  echo "Fichier /opt/tls/ovm/libbackup.sh inexistant" && exit 1

pstatus blue "Refresh des repositories..."
for repo in $(list_repository); do
    pstatus blue "  Repo $repo"
    sshi refresh Repository name=$repo
    if (( $? != 0 )); then
        pstatus red "    FAILED"
    else
        pstatus green "    SUCCESS"
    fi
    sleep 5
done

exit 0
