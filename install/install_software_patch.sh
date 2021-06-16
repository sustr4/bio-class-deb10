#!/bin/bash
# Install patch if difference betweenprepared image/upstream repository versions
PATH=$PATH;PATH+=":/bin" ;PATH+=":/usr/bin";PATH+=":/usr/sbin";PATH+=":/usr/local/bin";
dirname=$(dirname $0)
cd "$dirname"
SCRIPTDIR=$(pwd)
dirname=$(dirname pwd)
PATH+=":$dirname"
export PATH

CONF_DIR="$dirname"/../conf
LIB_DIR="$dirname"/../lib

BIOUSER=$(curl -s  http://169.254.169.254/openstack/2016-06-30/meta_data.json 2>/dev/null | python -m json.tool | egrep -i Bioclass_user |cut -f 2 -d ':' | tr -d ' ' | sed -rn "s/.*\"(.*)\".*/\1/p"| tr '[:upper:]' '[:lower:]')
if [[ -z "$BIOUSER" ]]; then
  echo "Empty Bioclass_user from METADATA, exiting!"
  exit 1
fi

echo "Install patch if needed"

# Patch

tmp_installed=$(apt list --installed 2>/dev/null| egrep -v "^WARNING"| grep "libpng++-dev" | egrep -i "installed")
if [[ -z "$tmp_installed" ]];then
  #libpng++-dev
  apt-get -y install libpng++-dev
fi

# Update startHTTPS
tmp_exist=$(egrep buster-backports /home/"${BIOUSER}"/HTTPS/startHTTPS.sh 2>/dev/null)
if [[ -z "$tmp_exist" ]];then
  mkdir -p /home/"${BIOUSER}"/HTTPS/conf
  cp ${SCRIPTDIR}/startHTTPS.sh /home/"${BIOUSER}"/HTTPS
  chown "${BIOUSER}": /home/"${BIOUSER}"/HTTPS -R
  chmod +x /home/"${BIOUSER}"/HTTPS/startHTTPS.sh
  for file in ${CONF_DIR}/.conf ${CONF_DIR}/nginx.conf ${CONF_DIR}/nginx.conf.clean ${CONF_DIR}/rserver.conf.clean ; do \
  cp $file /home/"${BIOUSER}"/HTTPS/conf ; done
  chmod 644 /home/"${BIOUSER}"/HTTPS/conf/* ; chown root: /home/"${BIOUSER}"/HTTPS/conf/*
fi

# fail2ban
tmp_exist=$(egrep repeat-offender-pers /etc/fail2ban/jail.local 2>/dev/null)
if [[ -f ${CONF_DIR}/nginx-rstudio.conf ]] && [[ -f ${CONF_DIR}/jail.local ]] && [[ -z "$tmp_exist" ]];then
  echo "Going to copy updated nginx-rstudio.conf and jail.local"
  cp ${CONF_DIR}/jail.local /etc/fail2ban
  cp ${CONF_DIR}/nginx-rstudio.conf /etc/fail2ban/filter.d
  cp ${CONF_DIR}/repeat-offender.conf /etc/fail2ban/filter.d
  cp ${CONF_DIR}/repeat-offender-found.conf /etc/fail2ban/filter.d
  for file in /etc/fail2ban/filter.d/nginx-rstudio.conf /etc/fail2ban/jail.local /etc/fail2ban/filter.d/repeat-offender.conf /etc/fail2ban/filter.d/repeat-offender-found.conf ; do \
  chown root: $file ; \
  chmod 644 $file ; done

  iptables-save > /root/iptables-rules.v4.OLD

  echo "# Generated by iptables-save v1.8.2 on Tue Mar  9 14:01:22 2021
*filter
:INPUT ACCEPT [338:29434]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [322:75282]
:f2b-nginx-rstudio - [0:0]
:f2b-repeat-offender - [0:0]
:f2b-repeat-offender-found - [0:0]
:f2b-repeat-offender-pers - [0:0]
:f2b-ssh - [0:0]
:f2b-sshd - [0:0]
-A INPUT -p tcp -j f2b-repeat-offender-found
-A INPUT -p tcp -j f2b-repeat-offender
-A INPUT -p tcp -m multiport --dports 80,443 -j f2b-nginx-rstudio
-A INPUT -p tcp -m multiport --dports 22 -j f2b-ssh
-A INPUT -p tcp -m multiport --dports 22 -j f2b-sshd
-A f2b-nginx-rstudio -j RETURN
-A f2b-repeat-offender -j RETURN
-A f2b-repeat-offender-found -j RETURN
-A f2b-repeat-offender-pers -j RETURN
-A f2b-ssh -j RETURN
-A f2b-sshd -j RETURN
COMMIT" > /root/iptables-rules.v4

  iptables-restore /root/iptables-rules.v4
  iptables-save > /etc/iptables/rules.v4
  ip6tables-save > /etc/iptables/rules.v6
  service fail2ban restart
  iptables -L -n --line-numbers

  echo -E "/var/log/fail2ban.log {

    weekly
    rotate 6
    compress

    delaycompress
    missingok
    postrotate
        fail2ban-client flushlogs 1>/dev/null
    endscript

    # If fail2ban runs as non-root it still needs to have write access
    # to logfiles.
    # create 640 fail2ban adm
    create 640 root adm
}"  > /etc/logrotate.d/fail2ban

  chmod 644 /etc/logrotate.d/fail2ban
  chown root: /etc/logrotate.d/fail2ban
  service logrotate restart

fi

# Ignoreip for fail2ban
tmp_restart=0 ;
BIOSW_IPV4=$(curl -s  http://169.254.169.254/openstack/2016-06-30/meta_data.json 2>/dev/null | python -m json.tool | egrep -i Bioclass_ipv4 |cut -f 2 -d ':' | tr -d ' ' | sed -rn "s/.*\"(.*)\".*/\1/p"| tr '[:upper:]' '[:lower:]' | sed "s/  \+/ /g" | sed "s/,/ /g");
for address in $BIOSW_IPV4; do
  BIOSW_IPV4_ADDRESS=$( echo "$address"| grep -E -o "\b([0-9]{1,3}[\.]){3}[0-9]{1,3}(/[0-9]{1,3}){0,1}\b");
  if [[ -n "$BIOSW_IPV4_ADDRESS" ]];then
    tmp_ipv4_jail_local=$(grep -F $BIOSW_IPV4_ADDRESS /etc/fail2ban/jail.local);
    tmp4sed=$(echo $BIOSW_IPV4_ADDRESS |sed -e 's/\//\\\//g');
  fi
  if [[ -n "$BIOSW_IPV4_ADDRESS" ]];then
  mkdir -p /var/lock/bio-class/ && cd /var/lock/bio-class && /usr/bin/flock -w 10 /var/lock/bio-class/f2b-ignoreip [ -n "$BIOSW_IPV4_ADDRESS" ] && [ -f /etc/fail2ban/jail.local ] && [ -z "$tmp_ipv4_jail_local" ] && sed -i '/ignoreip/s/$/,'$tmp4sed'/' /etc/fail2ban/jail.local && tmp_restart=1 && for item in sshd ssh nginx-rstudio repeat-offender repeat-offender-found repeat-offender-pers ; do /usr/bin/fail2ban-client set $item unbanip $BIOSW_IPV4_ADDRESS  ; done  ;
  fi

done ;
[ $tmp_restart -eq 1 ] && echo "$BIOSW_IPV4"> /root/IP4 && /usr/bin/sleep 5 && /usr/sbin/service fail2ban restart

#Fix: nfs issue #852196
tmp_nfs_clientid_conf=$(sed -rn "s/^options nfs nfs4_unique_id=(.*)$/\1/p" /etc/modprobe.d/nfs_clientid.conf)
if [[ ! -f /etc/modprobe.d/nfs_clientid.conf ]] || [[ -z "$tmp_nfs_clientid_conf" ]];then
  tmp_uuid=$(curl -s  http://169.254.169.254/openstack/2016-06-30/meta_data.json 2>/dev/null | python -m json.tool | egrep "uuid" |cut -f 2 -d ':' | tr -d ' ' | tr -d '"'| tr -d ',')
  echo "Openstack instance uuid: $tmp_uuid"
  if [[ -z "$tmp_uuid=" ]] ;then
    apt-get -y install uuid-runtime
    tmp_uuid=$(uuidgen)
    echo "Uuidgen uuid: $tmp_uuid"
  fi
  if [[ -n "$tmp_uuid" ]] ;then
    echo "Set $tmp_uuid to /etc/modprobe.d/nfs_clientid.conf"
    echo -e "options nfs nfs4_unique_id=${tmp_uuid}" >  /etc/modprobe.d/nfs_clientid.conf
    chown root: /etc/modprobe.d/nfs_clientid.conf
    chmod 644 /etc/modprobe.d/nfs_clientid.conf
    umount -f /data
    rmmod nfsv4
    rmmod nfs
    modprobe nfs
    mount /data
  fi
fi

#backports buster
tmp_buster_backports=$(egrep "debian buster-backports main" /etc/apt/sources.list | egrep -v "^#")
tmp_stretch_backports=$(egrep "debian stretch-backports main" /etc/apt/sources.list.d/backports.list 2>/dev/null)
if [[ -f /etc/apt/sources.list.d/backports.list ]] && [[ -n "$tmp_buster_backports" ]] && [[ -n "$tmp_stretch_backports" ]];then
  tmp_nginx_running=$(service nginx status | grep active | grep running)
  if [[ -n "$tmp_nginx_running" ]];then
    service nginx stop
  fi
  rm -rf /etc/apt/sources.list.d/backports.list
  apt remove -y python-certbot-nginx
  apt-get update
  apt-get -y install python3-acme python3-certbot python3-mock python3-openssl python3-pkg-resources python3-pyparsing python3-zope.interface
  apt-get update
  apt-get -y install certbot python3-certbot-nginx -t buster-backports
  if [[ -n "$tmp_nginx_running" ]];then
    service nginx start
  fi
fi

if [[ ! -f /etc/cron.d/checkIgnoreIP ]];then
  if [[ -n "$BIOSW_IPV4" ]];then
    tmp_text="$BIOSW_IPV4"
  else
    tmp_text="(PUBLIC IPv4 NOT SET YET, PLEASE USE METAFATA Bioclass_ipv4 TO IGNORE YOUR IP FROM FAIL2BAN IF NEEDED)"
  fi
  echo "Cron to apply user IPv4 $tmp_text from instance metadata"
  echo -e "#Cleanup jail.local first, then update ignoreip from instance Metadata" > /etc/cron.d/checkIgnoreIP

  echo -e "*/10 * * * * root IP4=\$(curl -s  http://169.254.169.254/openstack/2016-06-30/meta_data.json 2>/dev/null | python -m json.tool | egrep -i Bioclass_ipv4 |cut -f 2 -d ':' | tr -d ' ' | sed -rn \"s/.*\\\"(.*)\\\".*/\1/p\"| tr '[:upper:]' '[:lower:]' | sed \"s/  \+/ /g\" | sed \"s/,/ /g\");  tmp=\$(cat /root/IP4 2>/dev/null); mkdir -p /var/lock/bio-class/ && cd /var/lock/bio-class && /usr/bin/flock -w 10 /var/lock/bio-class/f2b-ignoreip [ \"\$IP4\" !=  \"\$tmp\" ] && echo \"DIFFERENT \$IP4 - \$tmp\" && for file in /home/debian/bio-class/conf/jail.local ; do cp \$file /etc/fail2ban/ && chown root: \$file && chmod 644 \$file ; done; [ -z \"\$IP4\" ] && [ -n \"\$tmp\" ] && /usr/sbin/service fail2ban restart && echo \"\" > /root/IP4">> /etc/cron.d/checkIgnoreIP

  echo -e "*/10 * * * * root /usr/bin/sleep 30; t_r=0 ;IP4=\$(curl -s  http://169.254.169.254/openstack/2016-06-30/meta_data.json 2>/dev/null|python -m json.tool|egrep -i Bioclass_ipv4|cut -f 2 -d ':'|tr -d ' '|sed -rn \"s/.*\\\"(.*)\\\".*/\1/p\"|tr '[:upper:]' '[:lower:]'|sed \"s/  \+/ /g\"|sed \"s/,/ /g\");for a in \$IP4; do IP4_A=\$( echo \"\$a\"|grep -E -o \"\\\b([0-9]{1,3}[\.]){3}[0-9]{1,3}(/[0-9]{1,3}){0,1}\\\b\");tmp_ipv4_jl=\$(grep -F \"\$IP4_A\" /etc/fail2ban/jail.local);t4s=\$(echo \$IP4_A |sed -e 's/\//\\\\\\\\\\\\\\\\\\\\\//g');mkdir -p /var/lock/bio-class/ && cd /var/lock/bio-class && /usr/bin/flock -w 60 /var/lock/bio-class/f2b-ignoreip [ -n \"\$IP4_A\" ] && [ -z \"\$tmp_ipv4_jl\" ] && sed -i '/ignoreip/s/\$/,'\"\$t4s\"'/' /etc/fail2ban/jail.local && t_r=1 &&  t=\"repeat-offender\" && for i in sshd ssh nginx-rstudio \$t \${t}-found \${t}-pers ; do /usr/bin/fail2ban-client set \$i unbanip \$IP4_A ; done ; done ; [ \$t_r -eq 1 ] && echo \"\$IP4\"> /root/IP4 && /usr/sbin/service fail2ban restart >/dev/null 2>&1" >> /etc/cron.d/checkIgnoreIP

fi

#KEGG.db removed with Bioconductor 3.13 release
tmp_keggdb=$(find /usr/local/lib/R/site-library/KEGG.db/R/ -maxdepth 1 -type f -name KEGG.db)
if [[ -z "$tmp_keggdb" ]];then
  tmp_keggdb=$(Rscript -e "installed.packages()" | egrep "^KEGG.db" | egrep "site-library")
fi
if [[ -z "$tmp_keggdb" ]];then
  echo "Install KEGG.db from tar"
  TMP_DIR="/tmp/${name}-tmp" ;
  mkdir -p "${TMP_DIR}";
  cd ${TMP_DIR}
  [ ! -f "${TMP_DIR}/KEGG.db_3.2.4.tar.gz" ] && wget --no-verbose https://bioconductor.org/packages/3.12/data/annotation/src/contrib/KEGG.db_3.2.4.tar.gz -P "$TMP_DIR"
  [ -f "${TMP_DIR}/KEGG.db_3.2.4.tar.gz" ] && tar -zxf KEGG.db_3.2.4.tar.gz -C "${TMP_DIR}"
  [ -f "${TMP_DIR}/KEGG.db_3.2.4.tar.gz" ] && Rscript -e "install.packages(\"KEGG.db_3.2.4.tar.gz\", repos = NULL, type=\"source\")"
  Rscript -e "installed.packages()" | egrep "^KEGG.db" | egrep "site-library"

fi


# Patch
echo "Install patch has finished"

# Print user to check in log
echo "BIOUSER: $BIOUSER"

exit 0
