#!/bin/bash

#
#   Global variable
#
g_counter=1

g_config_file='.haproxyctl.cfg'

g_haproxy_cfg='haproxy.cfg'

#
#   Template
#
haproxy_template='global
    maxconn 4096

defaults
    mode http
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms

frontend http-in
    bind *:80
    #__DOMAIN_NAME__

    #__DOMAIN_CHECK__

#__BACKEND__
    
listen admin
    bind 127.0.0.1:8080
    stats enable
'

#
#   functions
#
function get_container_ip() {
    if [ $# -eq 0 ]
    then
        return 1
    fi
    
    container_name=$1
    for i in $(docker ps -q)
    do
        if [ -n "$(docker inspect --format '{{.Name }}' $i | grep $container_name)" ]; then
            echo "$(docker inspect --format '{{.NetworkSettings.IPAddress }}' $i)"
            return 0
        fi
    done
    
    return 0
}

function update_template() {
    if [ $# -ne 3 ]
    then
        return 1
    fi
    
    domain=$1
    ip=$2
    port=$3
    
    domain_template="acl is_site$g_counter hdr_end(host) -i $domain"
    tmp_template="$(echo "$haproxy_template" | perl -pe "s/\Q#__DOMAIN_NAME__/$domain_template\n    #__DOMAIN_NAME__/g")"
    
    check_template="use_backend site$g_counter if is_site$g_counter"
    tmp_template="$(echo "$tmp_template" | perl -pe "s/\Q#__DOMAIN_CHECK__/$check_template\n    #__DOMAIN_CHECK__/g")"
    
    backend_template="backend site$g_counter
    balance roundrobin
    option httpclose
    option forwardfor
    server s2 $ip:$port maxconn 32"
    tmp_template="$(echo "$tmp_template" | perl -pe "s/\Q#__BACKEND__/$backend_template\n\n#__BACKEND__/g")"
    
    echo "$tmp_template"
    return 0
}

function cleanup_template() {
    if [ $# -ne 1 ]
    then
        return 1
    fi

    tmp_template="$(echo "$1" | sed '/#\_\_DOMAIN\_NAME\_\_/d')"
    tmp_template="$(echo "$tmp_template" | sed '/#\_\_DOMAIN\_CHECK\_\_/d')"
    tmp_template="$(echo "$tmp_template" | sed '/#\_\_BACKEND\_\_/d')"
    echo "$tmp_template"
    return 0
}

function sync() {
    while read -r line; do
        url="$(echo $line | cut -d " " -f 1)"
        container_name="$(echo $line | cut -d " " -f 2)"
        tmp_template=$(update_template $url $container_name 80)
        haproxy_template="$tmp_template"
        let g_counter++
    done <<< "$(jq -r '. | map("\(.url) \(.container_name)") | join("\n")'  $g_config_file)"
    tmp_template="$(cleanup_template "$haproxy_template")"
    echo "$tmp_template" > $g_haproxy_cfg
}

function help() {
    echo "help"
}

#
#   entrypoint
#

# add     <domain> <container_name>
# remove  <domain>
# sync


if [ ! -f $g_config_file ] || [ ! "$(jq '.' $g_config_file)" ]
then
    echo '[]' | jq '.' > $g_config_file
fi

if [ $# -eq 1 ]
then
    if [ $1 == "sync" ]; then
        sync
        exit 0
    fi
elif [ $# -eq 2 ]
then
    if [ $1 == "rm" ]; then
        jq_param='del(.[]|select(.url == "##URL##"))'
        jq_param="$(echo "$jq_param" | perl -pe "s/\Q##URL##/$2/g")"
        echo "$(cat "$g_config_file" | jq "$jq_param")" > $g_config_file
        sync
        exit 0
    fi
elif [ $# -eq 3 ]
then
    if [ $1 == "add" ]; then
        jq_param='del(.[]|select(.url == "##URL##")) | .  + [{url:"##URL##",container_name:"##CONTAINER##"}]'
        jq_param="$(echo "$jq_param" | perl -pe "s/\Q##URL##/$2/g")"
        jq_param="$(echo "$jq_param" | perl -pe "s/\Q##CONTAINER##/$3/g")"
        echo "$(cat "$g_config_file" | jq "$jq_param")" > $g_config_file
        sync
        exit 0
    fi    
fi

sync
help
exit 0

b=$(get_container_ip haproxy)
echo $b