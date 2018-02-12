#!/bin/sh

cd /root
yum -q -y remove mariadb nginx httpd* certbot-nginx python2-certbot php5* epel-release* remi-release*
rm -rf /var/lib/mysql
rm -rf /etc/nginx
rm -rf /etc/letsencrypt
rm -rf /opt/remi
rm -rf /root/.config /root/.drush
rm -rf /usr/local/bin/*
rm -f /usr/bin/php
rm -rf /usr/share/nginx
rm -rf /var/log/nginx
rm -rf /var/log/httpd
rm -rf /var/log/mariadb
sed -i '/.*certbot.*/d' /etc/crontab
userdel -rf admin
