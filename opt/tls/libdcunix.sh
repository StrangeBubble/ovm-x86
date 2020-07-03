#!/bin/sh

pstatus ()
{
    case "$1" in
        red)
            col="\033[101m\033[30m"
        ;;
        green)
            col="\033[102m\033[30m"
        ;;
        yellow)
            col="\033[103m\033[30m"
        ;;
        blue)
            col="\033[104m\033[30m"
        ;;
        *)
            col=""
        ;;
    esac;
    /bin/echo -ne "$col $2 \033[0m";
    [ -n "$3" ] && /bin/echo -n " ($3)";
    /bin/echo
}

color ()
{
    local s;
    s=${1,,};
    case $s in
        running | ok)
            col=adff2f
        ;;
        stop* | nok)
            col=ff0000
        ;;
        warn*)
            col=ffa500
        ;;
        *)
            col=FF0000
        ;;
    esac;
    echo "<span style=\"background-color:#$col;\">$1</span>"
}

cssStyle() {
cat << EOF
<!-- Start Styles. Move the 'style' tags and everything between them to between the 'head' tags -->
<style type="text/css">
.myTable { background-color:#eee;border-collapse:collapse; width:100%;}
.myTable th { background-color:#2e5894;color:white; }
.myTable td, .myTable th { padding:5px;border:1px solid #000; }
</style>
<!-- End Styles -->

EOF
}

convertCsv2Html() {
    from=$1

    echo '<html>'
    echo '<head> <title></title> </head>'

    cssStyle

    echo '<body>'
    h=`awk -F'SUBJECT:' '/^SUBJECT:/{print $2}' $1`
    echo "<p><u>$h</u></p>"

    echo '<table class="myTable"> <tbody> <tr>'
    awk -F'HEADER:' '/^HEADER:/{print $2}' $1 |tr ';' '\n'| while read colName; do
        echo "<th>$colName</th>"
    done
    echo '</tr>'
    awk -F'DATA:' '/^DATA:/{print $2}' $1 | while read Name; do
        echo '<tr>'
        echo $Name|tr ';' '\n'|while read colName; do
            case $colName in
                STATUS:*)
                    status=`echo $colName|awk -F'STATUS:' {'print $2'}`
                    echo "<td>`color $status`</td>"
                ;;
                *)
                    echo "<td>$colName</td>"
                ;;
            esac
        done
        echo '</tr>'
    done

    echo '</tbody> </table> </body> </html>'
}

SendEmailHTMLMorningCheckTEST() {
    FROM=$1
    REAL_NAME=$2
    SUBJECT=$3
    FICHIER=$4
    cat $FICHIER |\
        mutt -e "set from=$FROM; set realname=\"$REAL_NAME\"; set content_type=text/html" -s "$SUBJECT" \
             someone@company.lu
    return $?
}

SendEmailHTMLMorningCheck() {
    FROM=$1
    REAL_NAME=$2
    SUBJECT=$3
    FICHIER=$4
    cat $FICHIER |\
        mutt -e "set from=$FROM; set realname=\"$REAL_NAME\"; set content_type=text/html" -s "$SUBJECT" \
             -c someone@company.lu \
             someoneElse@company.lu
    return $?
}
