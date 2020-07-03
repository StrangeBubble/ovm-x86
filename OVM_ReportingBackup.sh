#!/bin/bash
# Y. ILAS : Reporting Backup

. /opt/tls/libdcunix.sh || echo "Fichier /opt/tls/libdcunix.sh inexistant"
. /opt/tls/ovm/libbackup.sh || echo "Fichier /opt/tls/ovm/libbackup.sh inexistant"

## Variables
SCRIPT=`readlink -m ${0##*/}`
TODAY=`date +'%Y%m%d-%H%M'`
TMPFILE=$(mktemp /tmp/ovm_reporting.XXXX) || { echo "Failed to create temp file"; exit 1; }
TMPFILE1=$(mktemp /tmp/ovm_reporting.XXXX) || { echo "Failed to create temp file"; exit 1; }
TMPFILE2=$(mktemp /tmp/ovm_reporting.XXXX) || { echo "Failed to create temp file"; exit 1; }
TMPFILE3=$(mktemp /tmp/ovm_reporting.XXXX) || { echo "Failed to create temp file"; exit 1; }

## Functions
EndScript() {
    rm -f $TMPFILE ${TMPFILE}.html $TMPFILE1 $TMPFILE2 $TMPFILE3
    pstatus green "Fin du script..."
    exit 0
}
trap EndScript INT EXIT


# Main
pstatus blue "Script de reporting des derniers backup"

cat << EOF > ${TMPFILE}.html
<p>Bonjour,</p>
<p>Veuillez trouver ci-dessous le compte rendu des backup OVM.</p>
<p>Cordialement</p>
<hr />
EOF

sshi list vm \
    | grep CLONE \
    | awk -F name\: '{print $2}' \
    > $TMPFILE3

if [ -s $TMPFILE3 ]; then
    echo 'SUBJECT:Liste des clones présents dans OVM... A supprimer rapidement ! '
    echo 'HEADER:CLONE VM'
    for vm in $(cat $TMPFILE3); do
        echo "DATA:$vm"
    done
fi > $TMPFILE

convertCsv2Html ${TMPFILE} >> ${TMPFILE}.html

cd /opt/telindus/ovm/status/
{
    for report in `ls -t`; do
        grep ^DATA $report|head -n1
    done
    echo 'SUBJECT:Liste des derniers backup OVM'
    echo 'HEADER:BACKUP TYPE;BACKUP DATE;BACKUP TIME;BACKUP NAME'
} > $TMPFILE

convertCsv2Html ${TMPFILE} >> ${TMPFILE}.html

cat << EOF >> ${TMPFILE}.html
<p></p>
<p></p>
<hr />
<p>Le status du backup de chaque VM :</p>
<hr />
EOF

cd /opt/tls/ovm/status/
for report in `ls`; do
    cp $report $TMPFILE2
    nbBackup=$(grep ^DATA $TMPFILE2|wc -l)
    lineSubject=$(grep ^SUBJECT $TMPFILE2)
    sed -i "s#^SUBJECT\(.*\)#SUBJECT\1   (nb total de backups: $nbBackup)#" $TMPFILE2
    convertCsv2Html $TMPFILE2 >> ${TMPFILE}.html
done

cat ${TMPFILE}.html \
    | mutt -e "set from=noreply@company.lu; set realname=\"DC_Unix\"; set content_type=text/html" -s "Status Backup des VM OVM du $TODAY" \
        someone@company.lu

exit 0
