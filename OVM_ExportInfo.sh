#!/bin/bash
# Y.ILAS : script used to make a monthly reporting of resources used by servers and VM

. /opt/tls/ovm/libbackup.sh  ||  echo "Fichier /opt/telindus/ovm/libbackup.sh inexistant" && exit 1

# D'abord on fait un refresh des repositories
/opt/telindus/ovm/OVM_RefreshRepository.sh

tmpfile1=$(mktemp /tmp/ovm_reporting.XXXXX) || { echo "Failed to create temp file"; exit 1; }
tmpfile2=$(mktemp /tmp/ovm_reporting.XXXXX) || { echo "Failed to create temp file"; exit 1; }

mgrhost=manager.ovm.dtc.int
today=`date +'%Y%m%d-%H%M'`

outputfileDom0=/tmp/dom0info-$mgrhost-$today.csv

dom0raw=`sshi  list server`
dom0list=`echo "$dom0raw" | grep  "id:" |cut -d ":" -f2-17 |cut -d " " -f1`

# Start with dom0 reporting
for dom0id in `echo "$dom0list"`; do
    dom0details=`sshi  show server id=$dom0id`
    ovmpool=`echo "$dom0details" | grep  "Server Pool =" |cut -d "[" -f2 |cut -d "]" -f1`
    dom0name=`echo "$dom0details" | grep  "  Name = "|cut -d "=" -f2`
    dom0ip=`echo "$dom0details" | grep  -i "IP Address =" |cut -d "=" -f2`
    dom0status=`echo "$dom0details" | grep  "Status =" |cut -d "=" -f2`
    dom0VMs=`echo "$dom0details" | grep  "  Vm " |awk '{print $5}'`
    TotalVmMemory=0

    for VmId in `echo "$dom0VMs"`; do
        vmraw=`sshi  show vm id=$VmId`
        # check if vm is running
        vmrunning=`echo "$vmraw" | grep  -c "Status = Stopped"`
        if [ "$vmrunning" = "0" ]; then
            vmmemory=`echo "$vmraw" | grep  "  Memory (MB)" |awk '{print $5}'`
            TotalVmMemory=`echo $((${vmmemory}+${TotalVmMemory}))`
        fi
    done

    totalmemory=`echo "$dom0details" | grep  "  Memory (MB) =" |cut -d "=" -f2`
    freememory=`echo "$dom0details" | grep  "  Usable Memory (MB) =" |cut -d "=" -f2`
    dom0memory=`echo $((${totalmemory}-${freememory}-${TotalVmMemory}))`
    dom0socket=`echo "$dom0details" | grep  "Processor Sockets Populated =" |cut -d "=" -f2`
    dom0proctype=`echo "$dom0details" | grep  "  Cpu Compatibility Group =" |cut -d "[" -f2 |cut -d "]" -f1`
    ovmrelease=`echo "$dom0details" | grep  "  OVM Version =" |cut -d "=" -f2`
    dom0arch=`echo "$dom0details" | grep  "  Processor Type =" |cut -d "=" -f2`

    dom0processors=`echo "$dom0details" | grep  "  Processors =" |cut -d "=" -f2`
    dom0model=`echo "$dom0details" | grep  "Product Name =" |cut -d "=" -f2`
    dom0man=`echo "$dom0details" | grep  "Manufacturer =" |cut -d "=" -f2`
    dom0hyp=`echo "$dom0details" | grep  "Hypervisor Type =" |cut -d "=" -f2`
    dom0bios=`echo "$dom0details" | grep  "BIOS Version =" |cut -d "=" -f2`
    dom0biosdate=`echo "$dom0details" | grep  "BIOS Release Date =" |cut -d "=" -f2`
    echo "$ovmpool;$dom0name;$dom0id;$dom0ip;$dom0status;$totalmemory;$dom0memory;$TotalVmMemory;$freememory;$dom0socket;$dom0processors;$dom0proctype;$ovmrelease;$dom0man$dom0model;$dom0arch;$dom0hyp;$dom0bios;$dom0biosdate" >> $tmpfile1
done

sort $tmpfile1 > $tmpfile2

echo "Server Pool;Oracle VM Server;dom0 UUID;Management IP Address;Status;Total Memory (MiB);dom0 Memory (MiB);VM Memory (MiB);Free Memory (MiB);Socket(s);Processors;CPU Compatibility Group;Oracle VM Release;Manufacturer/Model;Server Architecture;Hypervisor;BIOS Release;BIOS Date" > $outputfileDom0
cat  $tmpfile2  >> $outputfileDom0


# ...then VM reporting
rm -f $tmpfile1 $tmpfile2
outputfileVM=/tmp/vm_details_$mgrhost-$today.csv

vmraw=`sshi list vm | egrep -v 'CLONE|SNAP|FULL|OVA'`
vmlist=`echo "$vmraw" | grep  "id:" |cut -d ":" -f2 |cut -d " " -f1`

# loop on vdisks and check their ownership
for vmid in `echo "$vmlist"`; do
    vmdetails=`sshi  show vm id=$vmid`
    vdisk_tot_used=0
    vdisk_tot_max=0
    pdisk_tot=0
    vmdiskmapid=`echo "$vmdetails" | grep VmDiskMapping | grep  -v ".iso" | grep  -v "EMPTY_CDROM" |awk '{print $5}'`
    vmdiskid=`echo "$vmdetails" | grep  VmDiskMapping | grep  -v ".iso" | grep  -v "EMPTY_CDROM" |cut -d "(" -f2 |cut -d ")" -f1`
    for diskmapid in `echo "$vmdiskmapid"`; do
        diskdet=`sshi  show vmdiskmapping id=$diskmapid`
        isvirtual=`echo "$diskdet" | grep  -c "  Virtual Disk = "`
        if [ "$isvirtual" = "1" ]; then
            # it's virtual
            diskid=`echo "$diskdet" | grep  "  Virtual Disk = " |awk '{print $5}'`
            vdiskdet=`sshi  show virtualdisk id=$diskid`
            vdisk_used=`echo "$vdiskdet" | grep  "Used (GiB) =" |cut -d "=" -f2 |awk '{print int($1+0.9)}'`
            vdisk_max=`echo "$vdiskdet" | grep  "Max (GiB) =" |cut -d "=" -f2 |awk '{print int($1+0.9)}'`
            vdisk_tot_used=$(($vdisk_tot_used + $vdisk_used))
            vdisk_tot_max=$(($vdisk_tot_max + $vdisk_max))
        else
            # it's physical
            diskid=`echo "$diskdet" | grep  "  Physical Disk = " |awk '{print $5}'`
            pdiskdet=`sshi  show physicaldisk id=$diskid`
            pdisk_used=`echo "$pdiskdet" | grep  "Size (GiB) =" |cut -d "=" -f2 |awk '{print int($1+0.9)}'`
            pdisk_tot=$(($pdisk_tot + $pdisk_used))
        fi
    done

    vmname=`echo "$vmdetails" | grep  "Name =" |cut -d "=" -f2`
    vmmemory=`echo "$vmdetails" | grep  -v "Max." | grep  "Memory (MB) =" |cut -d "=" -f2`
    vmmaxmemory=`echo "$vmdetails" | grep  "Max. Memory (MB) =" |cut -d "=" -f2`
    vmproc=`echo "$vmdetails" | grep -v "Max." | grep  "Processors =" |cut -d "=" -f2`
    vmmaxproc=`echo "$vmdetails" | grep  "Max. Processors =" |cut -d "=" -f2`
    vmproccap=`echo "$vmdetails" | grep  "Processor Cap =" |cut -d "=" -f2`
    vmprocprio=`echo "$vmdetails" | grep  "Priority =" |cut -d "=" -f2`
    vmha=`echo "$vmdetails" | grep  "High Availability =" |cut -d "=" -f2`
    vmos=`echo "$vmdetails" | grep  "Operating System =" |cut -d "=" -f2`
    vmtype=`echo "$vmdetails" | grep  "Domain Type =" |cut -d "=" -f2`
    vmrepo=`echo "$vmdetails" | grep  "Repository =" |cut -d "[" -f2 |cut -d "]" -f1`
        echo "$vmid;$vmname;$vmmemory;$vmproc;$vmprocprio;$vmha;$vmos;$vmtype;$vmrepo;$vdisk_tot_used;$vdisk_tot_max;$pdisk_tot" >> $tmpfile1
done

echo "VM ID;VM Name;Memory (MiB);Processors;Max Processors;High Availability;Operating System;VM Type;OVM Repository;vDisks space Used (GiB);vDisks space Max (GiB);Physical Disk size (GiB)" > $outputfileVM
sort -k 9 $tmpfile1 |grep -v "LOCFS" > $tmpfile2
cat $tmpfile2 >> $outputfileVM


sizeFile01=$(stat --printf=%s $outputfileDom0)
sizeFile02=$(stat --printf=%s $outputfileVM)
if (( $sizeFile01 < 1000 )) || (( $sizeFile02 < 1000 )); then
    echo "Erreur lors de la génération du reporting OVM..." | mailx -s "Reporting OVM $today" -r noreply@company.lu someone@company.lu
else
    echo "Reporting OVM $today" \
    | mutt -e "set from=noreply@company.lu; set realname=\"DC_Unix\"; set content_type=text/html" -s "Reporting OVM $today" \
           -c yann.ilas@telindus.lu \
           -a $outputfileDom0 $outputfileVM --  \
      someone@company.lu
    echo "Reporting OVM $today" \
    | mutt -e "set from=noreply@company.lu; set realname=\"DC_Unix\"; set content_type=text/html" -s "Reporting OVM $today" \
           -a $outputfileDom0 $outputfileVM --  \
      someone@company.lu
fi

rm -f $tmpfile1 $tmpfile2
rm -f $outputfileDom0 $outputfileVM

exit 0
