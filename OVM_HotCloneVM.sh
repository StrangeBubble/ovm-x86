#!/bin/bash
# Y.ILAS : hot clone of a VM

. /opt/tls/libdcunix.sh || echo "Fichier /opt/tls/libdcunix.sh inexistant" && exit 1
. /opt/tls/ovm/libbackup.sh || echo "Fichier /opt/tls/ovm/libbackup.sh inexistant" && exit 1

##############################################################################################
## VARIABLES
##############################################################################################
SCRIPT=`readlink -m ${0##*/}`
today=`date +'%Y%m%d-%H%M'`
guest=$1
pool=$2
repotarget=$3
retention=$4
backup_type=${5,,}
retention_count=`echo ${retention//[^0-9]/}`
retention_type=`echo ${retention//[^A-Z]/}`
TMPFILE=$(mktemp /tmp/ovm_backup.XXXXX) || { echo "Failed to create temp file"; exit 1; }
TMPCSVFILE=$(mktemp /tmp/ovm_backup_csv.XXXXX) || { echo "Failed to create temp file"; exit 1; }

# Default copy-type is SPARSE
# If you want you can modify to "NON_SPARSE_COPY"
#    copytype=NON_SPARSE_COPY
#    copytype=SPARSE_COPY
#    copytype=THIN_CLONE

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
        $SCRIPT  <guest name> <Oracle VM Server Pool> <target Repository> <Backup Retention> <backup_type>

    Where:
        <backup_type> options are (no case-sensitive):
            - FULL => HotClone will create a full vdisk backup on a further repository
            - SNAP => HotClone will create an ocfs2 reference-link snapshot of the vm on the same repository
            - OVA  => HotClone will create a packaged OVA file on a further repository - available only from 3.4

    Example:
        $SCRIPT vmdb01 myPool repotarget 8d FULL ( retention will be 8 days )
        $SCRIPT vmdb01 myPool repotarget d8 SNAP ( retention will be 8 days )
        $SCRIPT vmdb01 myPool repotarget 8c OVA ( retention will be 8 copies of that guest )
        $SCRIPT vmdb01 myPool repotarget c8 FULL ( retention will be 8 copies of that guest )

EOF

    exit 1
}


Check ()
{
    case $1 in
        prerequisites)
            if [ $retention_count -lt 1 ] || ( [ "$retention_type" != "d" ] && [ "$retention_type" != "c" ] ); then
                pstatus red "Invalid Retention Type or Count specified! "
                exit 1
            fi
            if [ "$backup_type" != "ova" ] && [ "$backup_type" != "full" ] && [ "$backup_type" != "snap" ]; then
                exit 1
            fi
        ;;
        checkguest)
            checkguest=`sshi show vm name=$guest | grep -ci "Locked = false"`
            if [ $checkguest -lt 1 ]; then
                pstatus red "Unable to identify Virtual Machine $guest specified ! "
                exit 1
            fi
            echo "Check VM name $guest... OK"
        ;;
        checkpool)
            checkpool=`sshi show ServerPool name=$pool | grep -c $guest`
            if [ $checkpool -lt 1 ]; then
                pstatus red "Unable to identify Server Pool $pool specified or Vm is not part of this pool"
                exit 1
            fi
            echo "Check pool name ($pool) and vm membership ($guest)... OK"
        ;;
        checkrepotarget)
            checkrepotarget=`sshi show repository name=$repotarget | grep -ci "Locked = false"`
            if [ $checkrepotarget -lt 1 ]; then
                pstatus red "The Target Repository seems to be locked..."
                exit 1
            fi
            echo "Check repotarget ($repotarget) name... OK"
        ;;
        ovmclirel)
            echo "Check OVMCLI Release"
            ovmclirel=`sshi showversion | grep '[0-9].[0-9]' | cut -d "." -f1,2 | sed 's|[^0-9]*||'`
            case $ovmclirel in
                3.2)
                    pstatus red "Oracle VM 3.2.x release is not supported by this script."
                    exit 1
                ;;
                3.3)
                    if [ "$backup_type" = "ova" ]; then
                        pstatus red "Oracle VM 3.3.x does not support OVA export functionality"
                        exit 1
                    fi
                ;;
                3.4)
                    pstatus green "Oracle VM 3.4.x CLI"
                ;;
                *)
                    exit -1
                ;;
            esac
        ;;
        *)
            exit -1
        ;;
    esac;
    return 0
}


##############################################################################################
# Main
##############################################################################################
pstatus blue "Script to backup VM on OVM infrastructure"
/bin/echo

if [ $# -lt 5 ]; then
    pstatus yellow "Number of arguments is incorrect" "should have 5 args"
    help
fi

# Execute checks
Check prerequisites
Check ovmclirel
Check checkguest
Check checkpool
Check checkrepotarget

# (1) Get the number of physical and virtual disks to understand the correct approach
# Get mapping-id of virtual-disks owned by the guest
DISK_MAP=`sshi show vm name=$guest | grep VmDiskMapping | awk '{print $5}'`

# Get the association between mapping-id and disk-name of disks owned by the guest - both physical and virtual
unset -v DISK_LIST
for diskid in `echo "$DISK_MAP"`; do
    tmp=`echo $diskid "$(sshi show VmDiskMapping id=$diskid | egrep "(Virtual|Physical)" | awk '{print $5}')"`
    if [ "x$DISK_LIST" = "x" ]; then
        DISK_LIST=`echo $tmp`
    else
        DISK_LIST=`echo -e "$DISK_LIST\n$tmp"`
    fi
done
TOTAL_DISKS=`echo "$DISK_LIST" | wc -l`
PHY_DISKS=`echo "$DISK_LIST" | grep -cv "\.img"`
VIR_DISKS=`echo "$DISK_LIST" | grep -c "\.img"`
echo "$DISK_MAP"
echo "$DISK_LIST"

if [ "$TOTAL_DISKS" = "$PHY_DISKS" ]; then
    echo "Virtual Machine $guest owns only physical disks - hot-clone not possible"
    exit 1
fi

# Create Customizer to clone only virtual-disks owned by the guest
sshi create VmCloneCustomizer name=vDisks-$guest-$today description=vDisks-$guest-$today on Vm name=$guest
MAP=`echo "$DISK_LIST" | grep "\.img" | awk '{print $1 }'`
declare DISKS=($(echo `echo "$DISK_LIST" |grep "\.img" |awk '{print $2}'`))
i=0
copytype=THIN_CLONE
for diskmapping in `echo "$MAP"`; do
    # Get Repository that hosts the virtual-disk
    diskid=${DISKS[$i]}
    ((i++))
    reposource=`sshi show VirtualDisk id=$diskid |grep "Repository Id" |awk '{print $6}' |cut -d "[" -f2 | cut -d "]" -f1`
    echo $reposource
    # Prepare CloneCustomizer with THIN_CLONE of virtual-disks only
    sshi create VmCloneStorageMapping cloneType=$copytype name=vDisks-Mapping-$diskmapping vmDiskMapping=$diskmapping repository=$reposource on VmCloneCustomizer name=vDisks-$guest-$today
done

# Create a clone of the guest with only virtual-disks on board and delete custom CloneCustomizer
sshi clone Vm name=$guest destType=Vm destName=$guest-CLONE-$today ServerPool=$pool cloneCustomizer=vDisks-$guest-$today
sshi delete VmCloneCustomizer name=vDisks-$guest-$today

case $backup_type in
    [full]*)
        # COPY-TYPE becomes SPARSE for moving on further repository
        copytype=SPARSE_COPY

        # (1) Create a new temporary Clone Customizer for machine moving
        sshi create VmCloneCustomizer name=$guest-$today description=$guest-$today on Vm name=$guest-CLONE-$today

        # (2) Prepare storage mappings for clone customizer created
        MAP=`sshi show vm name=$guest-CLONE-$today | grep VmDiskMapping | awk '{print $5}'`

        for diskmapping in `echo "$MAP"`; do
            sshi create VmCloneStorageMapping cloneType=$copytype name=Storage_Mapping-$diskmapping vmDiskMapping=$diskmapping repository=$repotarget on VmCloneCustomizer name=$guest-$today
        done

        # (3) Move cloned guest to target repository, delete Clone Customizer and move the target guest under "Unassigned Virtual Machine" folder
        sshi moveVmToRepository Vm name=$guest-CLONE-$today CloneCustomizer=$guest-$today targetRepository=$repotarget &
        each_cycle=30
        sleep $each_cycle

        # Wait until moveVmToRepository job completed
#        job_id=`sshi list job |grep -i "Move Vm" |grep $guest-CLONE-$today |cut -d ":" -f2|cut -d " " -f1`

        > /tmp/job03
        while ! test -s /tmp/job03; do
            job_id=$(sshi list job | tee /tmp/job01 | grep -i "Move Vm" | tee /tmp/job02 | grep $guest-CLONE-$today | tee /tmp/job03 | cut -d ":" -f2|cut -d " " -f1)
            sleep 10
        done

        done=0
        i=$each_cycle
        while [ $done -lt 1 ]; do
            echo "Waiting for Vm moving to complete...... $i seconds"
            let i=i+$each_cycle
            sleep $each_cycle
            done=`sshi show job id=$job_id |grep -c "Summary Done = Yes"`
        done

        # Rename vm to "FULL BACKUP"
        sshi edit vm name=$guest-CLONE-$today name=$guest-FULL-$today

        # Verify VM moving completed successfully
        sshi show job id=$job_id > /tmp/$job_id-ovmm.out
        job_status=`cat /tmp/$job_id-ovmm.out |grep "Summary State" |cut -d "=" -f2`

        if [ "$job_status" = " Success" ]; then
                echo "Backup of Virtual Machine $guest-FULL-$today completed successfully; here the details:"
            cat /tmp/$job_id-ovmm.out
            rm -f /tmp/$job_id-ovmm.out
        else
            echo "Backup of Virtual Machine $guest-FULL-$today in error state; here the details:"
            cat /tmp/$job_id-ovmm.out
            rm -f /tmp/$job_id-ovmm.out
                exit 1
        fi

        sshi   delete VmCloneCustomizer name=$guest-$today
        sshi   migrate Vm name=$guest-FULL-$today

        # (4) Add HotClone-Backup tag to vm cloned and moved to backup repository
        sshi  create tag name=HotClone-Backup-$guest-FULL-$today
        sshi  add tag name=HotClone-Backup-$guest-FULL-$today to Vm name=$guest-FULL-$today
        echo "Guest Machine $guest has cloned and moved to $guest-FULL-$today on repository $repotarget"
        echo "Guest Machine $guest-FULL-$today resides under 'Unassigned Virtual Machine Folder'"
    ;;

    [ova]*) # Rename temporary snapshot to "OVA" before exporting
        sshi edit vm name=$guest-CLONE-$today name=$guest-OVA-$today

        # Create OVA package starting from temporary snapshot
        sshi   exportVirtualAppliance Repository name=$repotarget name=$guest-OVA-$today vms=$guest-OVA-$today &
        each_cycle=10
        sleep $each_cycle

        # Wait until OvaCreation job completed
        job_id=`sshi   list job |grep -i "Export VM" |grep $guest-OVA-$today |cut -d ":" -f2|cut -d " " -f1`
        done=0
        i=$each_cycle
        while [ $done -lt 1 ]; do
            echo "Waiting for OVA Package to create......$i seconds"
            let i=i+$each_cycle
            sleep $each_cycle
            done=`sshi   show job id=$job_id |grep -c "Summary Done = Yes"`
        done

        # Add specific description to Appliance created
        sshi edit VirtualAppliance name=$guest-OVA-$today description=HotClone-Backup-$guest-OVA-$today

        # Check backup
        sshi show job id=$job_id > /tmp/$job_id-ovmm.out
        job_status=`cat /tmp/$job_id-ovmm.out |grep "Summary State" |cut -d "=" -f2`

        if [ "$job_status" = " Success" ]; then
            echo "OVA Backup $guest-OVA-$today creation of Virtual Machine $guest completed successfully; here the details:"
            cat /tmp/$job_id-ovmm.out
            rm -f /tmp/$job_id-ovmm.out
        else
            echo "OVA Backup $guest-OVA-$today creation of Virtual Machine $guest in error state; here the details:"
            cat /tmp/$job_id-ovmm.out
            rm -f /tmp/$job_id-ovmm.out
            exit 1
        fi
        # Delete temporary OCFS2 ref-clone of the vm
        DISK_MAP=`sshi   show vm name=$guest-OVA-$today |grep VmDiskMapping|awk '{print $5}'`

        for diskid in `echo "$DISK_MAP"`; do
            virtualdisk=`sshi   show VmDiskMapping id=$diskid |grep Virtual|awk '{print $5}'`
            sshi   delete VmDiskMapping id=$diskid
            sshi   delete VirtualDisk id=$virtualdisk
                done
        sshi   delete vm name=$guest-OVA-$today

        ### Unable to add TAG to a VirtualAppliance (OVA)
    ;;

    [snap]*) # Manage OCFS2-reflink snapshot created on the same repository
        sshi edit vm name=$guest-CLONE-$today name=$guest-SNAP-$today
        # (4) Add HotClone-Backup tag to vm cloned and moved to backup repository
        sshi create tag name=HotClone-Backup-$guest-SNAP-$today
        sshi add tag name=HotClone-Backup-$guest-SNAP-$today to Vm name=$guest-SNAP-$today
        # Move vm to Unassigned Folder
        sshi migrate Vm name=$guest-SNAP-$today
        ;;

    *)
        clear
        echo "\n Invalid Backup Type Selection"
        exit 1;;
esac

# (5) Retention Management: get list of vm backupped
vmlist=`sshi list vm |egrep "($guest-CLONE|$guest-SNAP|$guest-FULL)" |grep -v $today|cut -d ":" -f3`

# (6) Retention Management: get list of OVA exported
ovalist=`sshi list VirtualAppliance |grep $guest-OVA|grep -v $today|cut -d ":" -f3`
totlist=`echo "$vmlist"$'\n'"$ovalist"$'\n'`

# (7) VM Retention Management: get list of vm backupped that need to be removed
if [ "x$totlist" != "x" ]; then
    rm -f /tmp/backup_blacklist_$guest-$today
    case $retention_type in
    [d]*)
        echo "Retention type is time-based"
        echo "Actual reference is: $today"
        echo "All backups of this guest older than $retention_count days will be deleted!!!"
        dayinseconds=86400
        retention_seconds=$[$dayinseconds*$retention_count]
        today_date=`echo $today|awk '{print $1}'|cut -d "-" -f1`
        today_time=`echo $today|awk '{print $1}'|cut -d "-" -f2`
        today_seconds=$[`date --utc -d $today_date +%s`+`echo $today|cut -c1-2|sed 's/^0*//'`*3600+`echo $today|cut -c3-4|sed 's/^0*//'`*60]
        for backup_guest in `echo "$totlist"`; do
            case $backup_guest in
                $guest-CLONE-*)
                    backup_date=`echo $backup_guest|awk -F "$guest-CLONE-" '{print $2}'|cut -d "-" -f1`
                    backup_time=`echo $backup_guest|awk -F "$guest-CLONE-" '{print $2}'|cut -d "-" -f2`
                    backup_taken_type=CLONE;;
                $guest-SNAP-*)
                    backup_date=`echo $backup_guest|awk -F "$guest-SNAP-" '{print $2}'|cut -d "-" -f1`
                    backup_time=`echo $backup_guest|awk -F "$guest-SNAP-" '{print $2}'|cut -d "-" -f2`
                    backup_taken_type=SNAP;;
                $guest-FULL-*)
                    backup_date=`echo $backup_guest|awk -F "$guest-FULL-" '{print $2}'|cut -d "-" -f1`
                    backup_time=`echo $backup_guest|awk -F "$guest-FULL-" '{print $2}'|cut -d "-" -f2`
                    backup_taken_type=FULL;;
                $guest-OVA-*)
                    backup_date=`echo $backup_guest|awk -F "$guest-OVA-" '{print $2}'|cut -d "-" -f1`
                    backup_time=`echo $backup_guest|awk -F "$guest-OVA-" '{print $2}'|cut -d "-" -f2`
                    backup_taken_type=OVA;;
            esac
            backup_seconds=$[`date --utc -d $backup_date +%s`+`echo $backup_time|cut -c1-2|sed 's/^0*//'`*3600+`echo $backup_time|cut -c3-4|sed 's/^0*//'`*60]
            diff_seconds=$[$today_seconds-$backup_seconds]
            if [ $diff_seconds -gt $retention_seconds ]; then
                if [ "$backup_taken_type" = "OVA" ]; then
                    check_ova_desc=`sshi show VirtualAppliance name=$backup_guest |grep Description|grep -c HotClone-Backup-$guest`
                    if [ check_ova_desc -gt 0 ]; then
                        if [ "x$OVA_REMOVE_LIST" = "x" ]; then
                            OVA_REMOVE_LIST=`echo $backup_guest`
                        else
                            OVA_REMOVE_LIST=`echo -e "$OVA_REMOVE_LIST\n$backup_guest"`
                        fi
                    else
                        echo "===============================================" >> /tmp/backup_blacklist_$guest-$today
                        echo "=====> FOLLOWING OVA WON'T BE REMOVED: <<======" >> /tmp/backup_blacklist_$guest-$today
                        echo "===============================================" >> /tmp/backup_blacklist_$guest-$today
                        echo "OVA $backup_guest hasn't a properly configured description and won't be deleted." >> /tmp/backup_blacklist_$guest-$today
                        echo "===============================================" >> /tmp/backup_blacklist_$guest-$today
                    fi
                else
                    check_vm_tag=`sshi show vm name=$backup_guest |grep Tag|grep -c HotClone-Backup-$guest`
                    if [ $check_vm_tag -gt 0 ]; then
                        if [ "x$GUEST_REMOVE_LIST" = "x" ]; then
                            GUEST_REMOVE_LIST=`echo $backup_guest`
                        else
                            GUEST_REMOVE_LIST=`echo -e "$GUEST_REMOVE_LIST\n$backup_guest"`
                        fi
                    else
                        echo "===============================================" >> /tmp/backup_blacklist_$guest-$today
                        echo "=====> FOLLOWING GUEST WON'T BE REMOVED: <<====" >> /tmp/backup_blacklist_$guest-$today
                        echo "===============================================" >> /tmp/backup_blacklist_$guest-$today
                        echo "$backup_guest hasn't a properly configured tag and won't be deleted." >> /tmp/backup_blacklist_$guest-$today
                        echo "===============================================" >> /tmp/backup_blacklist_$guest-$today
                    fi
                fi
            fi
        done;;
    [c]*)
        echo "Retention type is Redundancy-Based"
        echo "Actual reference is: $today"
        echo "Latest $retention_count backup images will be retained while other backup images will be deleted!!!"
        # Creating "reverse-list" to have the list sorted by date
        for backup_guest in `echo "$totlist"`; do
          if echo $backup_guest | grep -q -- -${backup_type^^}- ; then
            case $backup_guest in
                $guest-CLONE-*)
                    backup_date=`echo $backup_guest|awk -F "$guest-CLONE-" '{print $2}'|cut -d "-" -f1`
                    backup_time=`echo $backup_guest|awk -F "$guest-CLONE-" '{print $2}'|cut -d "-" -f2`
                    tmp_list=`echo -e "$tmp_list\n$backup_date-$backup_time-CLONE-$guest"`;;
                $guest-SNAP-*)
                    backup_date=`echo $backup_guest|awk -F "$guest-SNAP-" '{print $2}'|cut -d "-" -f1`
                    backup_time=`echo $backup_guest|awk -F "$guest-SNAP-" '{print $2}'|cut -d "-" -f2`
                    tmp_list=`echo -e "$tmp_list\n$backup_date-$backup_time-SNAP-$guest"`;;
                $guest-FULL-*)
                    backup_date=`echo $backup_guest|awk -F "$guest-FULL-" '{print $2}'|cut -d "-" -f1`
                    backup_time=`echo $backup_guest|awk -F "$guest-FULL-" '{print $2}'|cut -d "-" -f2`
                    tmp_list=`echo -e "$tmp_list\n$backup_date-$backup_time-FULL-$guest"`;;
                $guest-OVA-*)
                    backup_date=`echo $backup_guest|awk -F "$guest-OVA-" '{print $2}'|cut -d "-" -f1`
                    backup_time=`echo $backup_guest|awk -F "$guest-OVA-" '{print $2}'|cut -d "-" -f2`
                    tmp_list=`echo -e "$tmp_list\n$backup_date-$backup_time-OVA-$guest"`;;
            esac
          fi
        done
        reverse_list=`echo -e "$tmp_list"|sort -n|grep -v "^$"`
        backup_count=`echo "$reverse_list"|wc -l`
        num_guest_to_delete=$[$backup_count-$retention_count+1]
        if [ $num_guest_to_delete -gt 0 ]; then
            unset -v GUEST_REMOVE_LIST
            unset -v OVA_REMOVE_LIST
            unset -v tmp_list
            # rebuild vm-list names based on num_guest_to_delete
            for reverse_guest in `echo -e "$reverse_list"|head -$num_guest_to_delete`; do
                case $reverse_guest in
                    *-CLONE-$guest)
                        backup_date=`echo $reverse_guest|awk -F "-CLONE-$guest" '{print $1}'|cut -d "-" -f1`
                        backup_time=`echo $reverse_guest|awk -F "-CLONE-$guest" '{print $1}'|cut -d "-" -f2`
                        backup_taken_type=CLONE
                        backup_guest=`echo -e "$guest-CLONE-$backup_date-$backup_time"`;;
                    *-SNAP-$guest)
                        backup_date=`echo $reverse_guest|awk -F "-SNAP-$guest" '{print $1}'|cut -d "-" -f1`
                        backup_time=`echo $reverse_guest|awk -F "-SNAP-$guest" '{print $1}'|cut -d "-" -f2`
                        backup_taken_type=SNAP
                        backup_guest=`echo -e "$guest-SNAP-$backup_date-$backup_time"`;;
                    *-FULL-$guest)
                        backup_date=`echo $reverse_guest|awk -F "-FULL-$guest" '{print $1}'|cut -d "-" -f1`
                        backup_time=`echo $reverse_guest|awk -F "-FULL-$guest" '{print $1}'|cut -d "-" -f2`
                        backup_taken_type=FULL
                        backup_guest=`echo -e "$guest-FULL-$backup_date-$backup_time"`;;
                    *-OVA-$guest)
                        backup_date=`echo $reverse_guest|awk -F "-OVA-$guest" '{print $1}'|cut -d "-" -f1`
                        backup_time=`echo $reverse_guest|awk -F "-OVA-$guest" '{print $1}'|cut -d "-" -f2`
                        backup_taken_type=OVA
                        backup_guest=`echo -e "$guest-OVA-$backup_date-$backup_time"`;;
                esac
                if [ "$backup_taken_type" = "OVA" ]; then
                    check_ova_desc=`sshi  show VirtualAppliance name=$backup_guest |grep Description|grep -c HotClone-Backup-$guest`
                    if [ $check_ova_desc -gt 0 ]; then
                        if [ "x$OVA_REMOVE_LIST" = "x" ]; then
                            OVA_REMOVE_LIST=`echo $backup_guest`
                        else
                            OVA_REMOVE_LIST=`echo -e "$OVA_REMOVE_LIST\n$backup_guest"`
                        fi
                    else
                        echo "===============================================" >> /tmp/backup_blacklist_$guest-$today
                        echo "=====> FOLLOWING OVA WON'T BE REMOVED: <<======" >> /tmp/backup_blacklist_$guest-$today
                        echo "===============================================" >> /tmp/backup_blacklist_$guest-$today
                        echo "OVA $backup_guest hasn't a properly configured description and won't be deleted." >> /tmp/backup_blacklist_$guest-$today
                        echo "===============================================" >> /tmp/backup_blacklist_$guest-$today
                    fi
                else
                    check_vm_tag=`sshi  show vm name=$backup_guest |grep Tag|grep -c HotClone-Backup-$guest`
                    if [ $check_vm_tag -gt 0 ]; then
                        #if [[ $backup_guest =~ ${backup_type^^} ]]; then
                            if [ "x$GUEST_REMOVE_LIST" = "x" ]; then
                                GUEST_REMOVE_LIST=`echo $backup_guest`
                            else
                                GUEST_REMOVE_LIST=`echo -e "$GUEST_REMOVE_LIST\n$backup_guest"`
                            fi
                        #fi
                    else
                        echo "===============================================" >> /tmp/backup_blacklist_$guest-$today
                        echo "=====> FOLLOWING GUEST WON'T BE REMOVED: <<====" >> /tmp/backup_blacklist_$guest-$today
                        echo "===============================================" >> /tmp/backup_blacklist_$guest-$today
                        echo "$backup_guest hasn't a properly configured tag and won't be deleted." >> /tmp/backup_blacklist_$guest-$today
                        echo "===============================================" >> /tmp/backup_blacklist_$guest-$today
                    fi
                fi
            done
        fi;;
    esac
fi

# (7) Verify if guest is running, has virtual-disks or have configured vNic & Delete obsolete VmDiskMapping / VirtualDisk / Vm
TMP_BCK_FILE=/tmp/backup-$guest-$today.log
rm -f $TMP_BCK_FILE

#echo "All backupped guests that:" >> /tmp/backup-$guest-$today.log
#echo "=================================" >> /tmp/backup-$guest-$today.log
#echo "1) aren't in a stopped state" >> /tmp/backup-$guest-$today.log
#echo "2) have physical disk configured" >> /tmp/backup-$guest-$today.log
#echo "3) have configured vNIC" >> /tmp/backup-$guest-$today.log
#echo "=================================" >> /tmp/backup-$guest-$today.log
#echo "Won't be removed by the automatic retention even if are obsolete backups." >> /tmp/backup-$guest-$today.log
#echo "" >> /tmp/backup-$guest-$today.log

# For final reporting
echo "===============================================" >> $TMP_BCK_FILE
echo "=======>> GUEST EXPIRED AND REMOVED: <<========" >> $TMP_BCK_FILE
echo "===============================================" >> $TMP_BCK_FILE

if [ "x$GUEST_REMOVE_LIST" = "x" ] && [ "x$OVA_REMOVE_LIST" = "x" ]; then
        echo "=============================================================" >> $TMP_BCK_FILE
        echo "Based on retention policy any guest backup will be deleted!!!" >> $TMP_BCK_FILE
        echo "=============================================================" >> $TMP_BCK_FILE
else
    for guest_to_delete in `echo "$GUEST_REMOVE_LIST"`; do
        guest_candidate=`sshi show vm name=$guest_to_delete`
        guest_status=`echo "$guest_candidate"|grep -c "Status = Stopped"`
        # guest_status=1 -> proceed!
        guest_vnics=`echo "$guest_candidate"|grep -c "Vnic 1"`
        # guest_vnic=1 -> stop!
        DISK_MAP=`sshi show vm name=$guest_to_delete |grep VmDiskMapping|awk '{print $5}'`
        guest_phydisks=0
        for disktmp in `echo "$DISK_MAP"`; do
            physicaldisk=`sshi show VmDiskMapping id=$disktmp |grep -c Physical`
            guest_phydisks=$[$guest_phydisks+$physicaldisk]
        done
        if [ $guest_status -eq 1 ] && [ $guest_vnics -eq 0 ] && [ $guest_phydisks -eq 0 ]; then
            unset -v DISK_LIST
            unset -v diskid
            for diskid in `echo "$DISK_MAP"`; do
                virtualdisk=`sshi show VmDiskMapping id=$diskid |grep Virtual|awk '{print $5}'`
                sshi delete VmDiskMapping id=$diskid
                sshi delete VirtualDisk id=$virtualdisk
            done
            sshi delete vm name=$guest_to_delete
            sshi delete tag name=HotClone-Backup-$guest_to_delete
            echo "$guest_to_delete" >> $TMP_BCK_FILE
        else
            echo "===============================================" >> $TMP_BCK_FILE
            echo "====> FOLLOWING GUEST CANNOT BE REMOVED: <<====" >> $TMP_BCK_FILE
            echo "===============================================" >> $TMP_BCK_FILE
            echo "$guest_to_delete due to one of the following possible reason(s):" >> $TMP_BCK_FILE
            echo " - Guest is running" >> $TMP_BCK_FILE
            echo " - Guest owns physical disks" >> $TMP_BCK_FILE
            echo " - Guest has virtual-nics configured" >> $TMP_BCK_FILE
            echo "===============================================" >> $TMP_BCK_FILE
        fi
    done

#    # For final reporting
#    echo "===============================================" >> /tmp/backup-$guest-$today.log
#    echo "===============================================" >> /tmp/backup-$guest-$today.log
#    echo "=======>> OVA EXPIRED AND REMOVED: <<========" >> /tmp/backup-$guest-$today.log
#    echo "===============================================" >> /tmp/backup-$guest-$today.log
#    for ova_to_delete in `echo "$OVA_REMOVE_LIST"`; do
#        ova_candidate=`sshi   show VirtualAppliance name=$ova_to_delete`
#        sshi   delete VirtualAppliance name=$ova_to_delete
#        echo "$ova_to_delete" >> /tmp/backup-$guest-$today.log
#    done
#    echo "===============================================" >> /tmp/backup-$guest-$today.log
fi

# Merge reports file
if [ -f /tmp/backup_blacklist_$guest-$today ]; then
    cat /tmp/backup_blacklist_$guest-$today >> $TMP_BCK_FILE
    rm -f /tmp/backup_blacklist_$guest-$today
fi

# Prepare report guest backup available ( FULL & SNAP & CLONE & OVA )
vmlist=`sshi  list vm |egrep "($guest-CLONE|$guest-SNAP|$guest-FULL)" |cut -d ":" -f3`
ovalist=`sshi list VirtualAppliance |grep $guest-OVA|cut -d ":" -f3`
totlist=`echo "$vmlist"$'\n'"$ovalist"$'\n'`
echo "SUBJECT:Backup de la VM $guest" > $TMPCSVFILE
echo "HEADER:BACKUP TYPE;BACKUP DATE;BACKUP TIME;BACKUP NAME" >> $TMPCSVFILE

echo "" >> $TMP_BCK_FILE
echo "Backup available for guest $guest :" >> $TMP_BCK_FILE
echo "" >> $TMP_BCK_FILE
echo "===============================================================================" >> $TMP_BCK_FILE
echo "= BACKUP TYPE == BACKUP  DATE == BACKUP  TIME == BACKUP  NAME =================" >> $TMP_BCK_FILE
echo "===============================================================================" >> $TMP_BCK_FILE
for guest_available in `echo -e "$totlist"`; do
    case $guest_available in
        $guest-CLONE-*)
            backup_date=`echo $guest_available|awk -F "$guest-CLONE-" '{print $2}'|cut -d "-" -f1`
            backup_time=`echo $guest_available|awk -F "$guest-CLONE-" '{print $2}'|cut -d "-" -f2`
            backup_type="CLONE";;
        $guest-SNAP-*)
            backup_date=`echo $guest_available|awk -F "$guest-SNAP-" '{print $2}'|cut -d "-" -f1`
            backup_time=`echo $guest_available|awk -F "$guest-SNAP-" '{print $2}'|cut -d "-" -f2`
            backup_type="SNAP ";;
        $guest-FULL-*)
            backup_date=`echo $guest_available|awk -F "$guest-FULL-" '{print $2}'|cut -d "-" -f1`
            backup_time=`echo $guest_available|awk -F "$guest-FULL-" '{print $2}'|cut -d "-" -f2`
            backup_type="FULL ";;
        $guest-OVA-*)
            backup_date=`echo $guest_available|awk -F "$guest-OVA-" '{print $2}'|cut -d "-" -f1`
            backup_time=`echo $guest_available|awk -F "$guest-OVA-" '{print $2}'|cut -d "-" -f2`
            backup_type="OVA  ";;
    esac
    echo "=    $backup_type    ==   $backup_date   ==     $backup_time     == $guest_available ==" >> $TMP_BCK_FILE
    echo "DATA:$backup_type;$backup_date;$backup_time;$guest_available" >> $TMPCSVFILE
done

echo "===============================================================================" >> $TMP_BCK_FILE

# Report guest backup expired&removed and not removed due to inconsitencies ( FULL & SNAP & CLONE & OVA )
echo ===========================================================================================================================
cat $TMP_BCK_FILE
#SendEmail $guest $TMP_BCK_FILE

cat $TMPCSVFILE | sort -t \; -rk 2 > ${TMPCSVFILE}.tmp
convertCsv2Html ${TMPCSVFILE}.tmp > ${TMPCSVFILE}.html
SendEmailHTMLCPTRenduBackupOVM "noreply@company.lu" "DC_Unix" "Backup de la VM $guest du $today" ${TMPCSVFILE}.html

\cp -f ${TMPCSVFILE}.tmp /opt/telindus/ovm/status/$guest

exit 0
