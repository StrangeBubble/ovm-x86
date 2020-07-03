#!/bin/bash

. /opt/tls/ovm/libbackup.sh  ||  echo "Fichier /opt/tls/ovm/libbackup.sh inexistant" && exit 1

##############################################################################################
## VARIABLES
##############################################################################################
:

##############################################################################################
## FUNCTIONS
##############################################################################################
header() {
cat << EOF
<html>
<head>
<title></title>
</head>
<body>
<p><u>$1</u></p>
<table border="1">
<tbody>
<tr>
<th>$2</th>
<th>$3</th>
</tr>
EOF
}

footer() {
cat << EOF
</tbody>
</table>
</body>
</html>
EOF
}

color() {
    case $1 in
        Running)
            echo "<span style=\"background-color:#00FF00;\">$1</span>"
        ;;
        *)
            echo "<span style=\"background-color:#FF0000;\">$1</span>"
        ;;
    esac

}


##############################################################################################
# Main
##############################################################################################
i=0
(
    header "Status des serveurs OVM" "Server Name" "Status"
    for server in `ListServers`; do
        echo '<tr>'
        status=`sshi   show server name=$server|awk -F 'Status =' '/Status =/{print $2}'|grep -o '[[:alpha:]]*'`
        echo -e "<td>$server</td>\n<td>`color $status`</td>"
        ((i++))
        echo '</tr>'
    done
    footer

    for cluster in `ListCluster`; do
         header "Status des VM OVM du cluster $cluster" "VM Name" "Status"
         for vm in `sshi show serverpool name=$cluster|grep '.*Vm.*000.*'|awk -F '[' '{print $2}'|tr -d ']'`; do
             echo '<tr>'
             status=`sshi   show vm name=$vm|awk -F 'Status =' '/Status =/{print $2}'|grep -o '[[:alpha:]]*'`
             echo -e "<td>$vm</td>\n<td>`color $status`</td>"
             echo '</tr>'
         done
         footer
    done
) > /tmp/status.html

SendEmailHTML "ovm.status@company.lu" "OVM Status" "Status des serveurs OVM" "/tmp/status.html"

exit 0
