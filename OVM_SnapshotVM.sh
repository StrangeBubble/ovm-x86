#!/bin/bash
# Y.ILAS : Snapshot d'une VM dans OVM

. /opt/tls/libdcunix.sh || echo "Fichier /opt/tls/libdcunix.sh inexistant" && exit 1
. /opt/tls/ovm/libbackup.sh || echo "Fichier /opt/tls/ovm/libbackup.sh inexistant" && exit 1

##############################################################################################
## VARIABLES
##############################################################################################
SCRIPT=`readlink -m ${0##*/}`
today=`date +'%Y%m%d-%H%M'`
guest=$1
pool=$2
unset -v DISK_LIST

##############################################################################################
## FUNCTIONS
##############################################################################################
EndScript() {
    rm -f $TMPFILE $TMP_BCK_FILE ${TMPCSVFILE}{,.html,.tmp}
    pstatus green "Fin du script..."
    exit 0
}
trap EndScript INT EXIT

help () {
    cat  <<EOF
    Usage:
        $SCRIPT  <guest name> <Oracle VM Server Pool>

    Example:
        $SCRIPT test-vm.0 COF

EOF

    exit -1
}


##############################################################################################
# Main
##############################################################################################
pstatus blue "Script to snapshot VM"

if [ $# -lt 2 ]; then
    pstatus yellow "Number of arguments is incorrect" "should have 2 args"
    help
fi

# Get mapping-id of virtual-disks owned by the guest
DISK_MAP=$(sshi show vm name=$guest | grep VmDiskMapping | awk '{print $5}')

# Get the association between mapping-id and disk-name of disks owned by the guest - both physical and virtual
for diskid in $(echo "$DISK_MAP"); do
    tmp=$(echo $diskid "$(sshi show VmDiskMapping id=$diskid | egrep "(Virtual|Physical)" | awk '{print $5}')")
    if [ "x$DISK_LIST" = "x" ]; then
        DISK_LIST=$(echo $tmp)
    else
        DISK_LIST=$(echo -e "$DISK_LIST\n$tmp")
    fi
done
TOTAL_DISKS=`echo "$DISK_LIST" | wc -l`
PHY_DISKS=`echo "$DISK_LIST" | grep -cv "\.img"`
VIR_DISKS=`echo "$DISK_LIST" | grep -c "\.img"`

if [ "$TOTAL_DISKS" = "$PHY_DISKS" ]; then
    echo "Virtual Machine $guest owns only physical disks - hot-clone not possible"
    exit 1
fi

# Create Customizer to clone only virtual-disks owned by the guest
sshi create VmCloneCustomizer name=vDisks-$guest-$today description=vDisks-$guest-$today on Vm name=$guest
MAP=`echo "$DISK_LIST" | grep "\.img" | awk '{print $1 }'`
declare DISKS=($(echo $(echo "$DISK_LIST" |grep "\.img" |awk '{print $2}')))
i=0
copytype=THIN_CLONE
for diskmapping in $(echo "$MAP"); do
    # Get Repository that hosts the virtual-disk
    diskid=${DISKS[$i]}
    ((i++))
    reposource=`sshi show VirtualDisk id=$diskid |grep "Repository Id" |awk '{print $6}' |cut -d "[" -f2 | cut -d "]" -f1`
    echo $reposource
    # Prepare CloneCustomizer with THIN_CLONE of virtual-disks only
    sshi create VmCloneStorageMapping cloneType=$copytype name=vDisks-Mapping-$diskmapping vmDiskMapping=$diskmapping repository=$reposource on VmCloneCustomizer name=vDisks-$guest-$today
done

# Create a clone of the guest with only virtual-disks on board and delete custom CloneCustomizer
sshi clone Vm name=$guest destType=Vm destName=$guest-SNAPSHOT-$today ServerPool=$pool cloneCustomizer=vDisks-$guest-$today
sshi delete VmCloneCustomizer name=vDisks-$guest-$today

exit 0
