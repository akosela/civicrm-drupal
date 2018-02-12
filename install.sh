#!/bin/sh
# Copyright (c) 2018 Andy Kosela.  All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

###############################
# Passwords - CHANGE IT!      #
###############################
admin='admin'
admin_pass='pass123'
civicrm='civicrm'
domain='example.com'
drupal='drupal'
drupal_admin='admin'
drupal_admin_pass='pass'
email='email@example.com'
mysql_root='pass'
###############################

# Start of script

# Make sure selinux is disabled
if [ ! `grep SELINUX=disabled /etc/sysconfig/selinux` ]; then
	sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/sysconfig/selinux
fi
setenforce 0 >/dev/null 2>&1

# Make swap (for AWS microinstance)
if [[ ! `swapon | grep NAME` ]]; then 
	echo "Make swap (for AWS microinstance)..."
	dd if=/dev/zero of=/var/swap.1 bs=1M count=1024
	chmod 600 /var/swap.1
	mkswap /var/swap.1
	swapon /var/swap.1
fi

# Install Nginx and MariDB
echo "Install Nginx and MariaDB..."
yum -q -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
yum -q -y install nginx mariadb-server
systemctl enable nginx
systemctl enable mariadb
systemctl start mariadb

# Mysql_secure_installation + CiviCRM db create
echo "MySQL_secure_installation..."
mysql -u root <<EOF
update mysql.user set password=password('$mysql_root') where user='root';
delete from mysql.user where user='root' and host not in ('localhost', '127.0.0.1', '::1');
delete from mysql.user where user='';
delete from mysql.db where db='test' or db='test_%';
create database civicrm;
grant all privileges on civicrm.* to civicrm@localhost identified by '$civicrm';
flush privileges;
EOF

cat > /root/.my.cnf <<EOF
[client]
user=root
password=$mysql_root
EOF

chmod 600 /root/.my.cnf

# Configure Nginx
echo "Configure Nginx..."
sed -i -e '1,/server_name/{/server_name/d;}' \
    -e '1,/root/{/root/d;}' /etc/nginx/nginx.conf
mkdir /usr/share/nginx/html/drupal
mkdir /etc/nginx/default.d
cat > /etc/nginx/default.d/site.conf <<EOF
server_name	$domain;
root		/usr/share/nginx/html/drupal;
EOF

# Start Nginx
echo "Start Nginx..."
systemctl start nginx

# Install Certbot
echo "Install Certbot..."
yum-config-manager --enable rhui-REGION-rhel-server-extras \
    rhui-REGION-rhel-server-optional >/dev/null
yum -q -y install certbot-nginx >/dev/null 2>&1
certbot -n --authenticator webroot --installer nginx -d $domain \
    --agree-tos --email $email --webroot-path /usr/share/nginx/html/drupal
certbot renew --dry-run
echo "0 23 * * * root certbot renew" >> /etc/crontab
systemctl reload crond

# Install PHP
echo "Install PHP..."
yum -q -y install http://rpms.remirepo.net/enterprise/remi-release-7.rpm
yum -q -y install php56 php56-php-fpm php56-php-mysql php56-php-gd \
    php56-php-mbstring
sed -i 's/memory_limit.*M/memory_limit = 512M/' /etc/opt/remi/php56/php.ini
ln -s /usr/bin/php56 /usr/bin/php
cat > /etc/nginx/default.d/php-fpm.conf <<'EOF'
# pass the PHP scripts to FastCGI server listening on 127.0.0.1:9000
#
location ~ \.php$ {
	fastcgi_pass   127.0.0.1:9000;
	fastcgi_index  index.php;
	fastcgi_param  SCRIPT_FILENAME   $document_root$fastcgi_script_name;
	include        fastcgi_params;
}
EOF

# Install Drupal Nginx conf
echo "Install Drupal Nginx conf..."
cat >> /etc/nginx/default.d/site.conf <<'EOF'

location / {
	index index.php index.html;
	try_files $uri /index.php?$query_string; # For Drupal >= 7
}

location = /favicon.ico {
	log_not_found off;
	access_log off;
}

location = /robots.txt {
	allow all;
	log_not_found off;
	access_log off;
}

# Very rarely should these ever be accessed outside of your lan
location ~* \.(txt|log)$ {
	allow 192.168.0.0/16;
	deny all;
}

location ~ \..*/.*\.php$ {
	return 403;
}

location ~ ^/sites/.*/private/ {
	return 403;
}

# Allow "Well-Known URIs" as per RFC 5785
location ~* ^/.well-known/ {
	allow all;
}

# Block access to "hidden" files and directories whose names begin with a
# period. This includes directories used by version control systems such
# as Subversion or Git to store control files.
location ~ (^|/)\. {
	return 403;
}

location @rewrite {
	rewrite ^/(.*)$ /index.php?q=$1;
}

# Don't allow direct access to PHP files in the vendor directory.
location ~ /vendor/.*\.php$ {
	deny all;
	return 404;
}

# Fighting with Styles? This little gem is amazing.
location ~ ^/sites/.*/files/styles/ { # For Drupal >= 7
	try_files $uri @rewrite;
}

# Handle private files through Drupal. Private file's path can come
# with a language prefix.
location ~ ^(/[a-z\-]+)?/system/files/ { # For Drupal >= 7
	try_files $uri /index.php?$query_string;
}

location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
	try_files $uri @rewrite;
	expires max;
	log_not_found off;
}

# civiCRM security
location ~* /(sites/default/)?files/civicrm/(ConfigAndLog|custom|upload|templates_c)/ {
	deny all;
}
EOF

sed -i '/location \//,+1 d' /etc/nginx/nginx.conf
systemctl start php56-php-fpm
systemctl restart nginx

# Install Drush
echo "Install Drush..."
unset module
cd /root
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer
composer -q --no-plugins --no-scripts global require drush/drush:8.*
ln -s /root/.config/composer/vendor/bin/drush /usr/local/bin/drush

# Install Drupal
echo "Install Drupal..."
cd /usr/share/nginx/html
drush dl drupal-7.56
cp -r drupal-7.56/* drupal
rm -rf drupal-7.56
cd drupal
drush si standard --account-name=$drupal_admin \
    --account-pass=$drupal_admin_pass          \
    --db-url=mysql://drupal:$drupal@localhost/drupal \
    --db-su=root --db-su-pw=$mysql_root -y >/dev/null
chmod 755 /usr/share/nginx/html/drupal/sites/default

# Install Civicrm
echo "Install CiviCRM..."
cd /root/.drush
curl -O https://raw.githubusercontent.com/civicrm/civicrm-drupal/7.x-master/drush/civicrm.drush.inc
drush cc -y
cd /usr/share/nginx/html
curl -o civicrm-drupal.tar.gz -L https://sourceforge.net/projects/civicrm/files/civicrm-stable/4.7.29/civicrm-4.7.29-drupal.tar.gz/download
cd drupal
drush cvi --dbuser=civicrm --dbpass=$civicrm --dbhost=localhost \
    --dbname=civicrm --tarfile=/usr/share/nginx/html/civicrm-drupal.tar.gz \
    --destination=sites/all/modules --site_url=$domain --ssl=on \
    --load_generated_data=0 -y >/dev/null

# create admin user
echo "Create $admin user..."
useradd $admin
echo $admin_pass | passwd --stdin $admin
cp -r /root/.drush /home/$admin
chown -R $admin:$admin /home/$admin/.drush
chown -R $admin:$admin /usr/share/nginx/html
su - admin -c "composer -q --no-plugins --no-scripts global require drush/drush:8.*"

# Drupal private file directory
echo "Drupal private file directory..."
mkdir files
chown apache:apache files
drush -y vset file_private_path /usr/share/nginx/html/drupal/files

# Install Backup and Migrate module for Drupal
echo "Install backup_migrate module for Drupal..."
chown -R apache:apache /usr/share/nginx/html/drupal/sites/default/files
drush -y en backup_migrate

# CiviCRM views integration
echo "CiviCRM views integration..."
drush -y en views

mysql -u root -D civicrm <<EOF
grant select on civicrm.* to drupal@localhost identified by '$drupal';
EOF

rm -f /root/.my.cnf
rm /usr/local/bin/drush
ln -s /home/admin/.config/composer/vendor/bin/drush /usr/local/bin/drush
cat >> /usr/share/nginx/html/drupal/sites/default/settings.php <<'EOF'

# integrate views
$databases['default']['default']['prefix']= array(
  'default' => '',
  'civicrm_acl'                              => '`civicrm`.',
  'civicrm_acl_cache'                        => '`civicrm`.',
  'civicrm_acl_contact_cache'                => '`civicrm`.',
  'civicrm_acl_entity_role'                  => '`civicrm`.',
  'civicrm_action_log'                       => '`civicrm`.',
  'civicrm_action_mapping'                   => '`civicrm`.',
  'civicrm_action_schedule'                  => '`civicrm`.',
  'civicrm_activity'                         => '`civicrm`.',
  'civicrm_activity_contact'                 => '`civicrm`.',
  'civicrm_address'                          => '`civicrm`.',
  'civicrm_address_format'                   => '`civicrm`.',
  'civicrm_batch'                            => '`civicrm`.',
  'civicrm_cache'                            => '`civicrm`.',
  'civicrm_campaign'                         => '`civicrm`.',
  'civicrm_campaign_group'                   => '`civicrm`.',
  'civicrm_case'                             => '`civicrm`.',
  'civicrm_case_activity'                    => '`civicrm`.',
  'civicrm_case_contact'                     => '`civicrm`.',
  'civicrm_case_type'                        => '`civicrm`.',
  'civicrm_component'                        => '`civicrm`.',
  'civicrm_contact'                          => '`civicrm`.',
  'civicrm_contact_type'                     => '`civicrm`.',
  'civicrm_contribution'                     => '`civicrm`.',
  'civicrm_contribution_page'                => '`civicrm`.',
  'civicrm_contribution_product'             => '`civicrm`.',
  'civicrm_contribution_recur'               => '`civicrm`.',
  'civicrm_contribution_soft'                => '`civicrm`.',
  'civicrm_contribution_widget'              => '`civicrm`.',
  'civicrm_country'                          => '`civicrm`.',
  'civicrm_county'                           => '`civicrm`.',
  'civicrm_currency'                         => '`civicrm`.',
  'civicrm_custom_field'                     => '`civicrm`.',
  'civicrm_custom_group'                     => '`civicrm`.',
  'civicrm_cxn'                              => '`civicrm`.',
  'civicrm_dashboard'                        => '`civicrm`.',
  'civicrm_dashboard_contact'                => '`civicrm`.',
  'civicrm_dedupe_exception'                 => '`civicrm`.',
  'civicrm_dedupe_rule'                      => '`civicrm`.',
  'civicrm_dedupe_rule_group'                => '`civicrm`.',
  'civicrm_discount'                         => '`civicrm`.',
  'civicrm_domain'                           => '`civicrm`.',
  'civicrm_email'                            => '`civicrm`.',
  'civicrm_entity_batch'                     => '`civicrm`.',
  'civicrm_entity_file'                      => '`civicrm`.',
  'civicrm_entity_financial_account'         => '`civicrm`.',
  'civicrm_entity_financial_trxn'            => '`civicrm`.',
  'civicrm_entity_tag'                       => '`civicrm`.',
  'civicrm_event'                            => '`civicrm`.',
  'civicrm_event_carts'                      => '`civicrm`.',
  'civicrm_events_in_carts'                  => '`civicrm`.',
  'civicrm_extension'                        => '`civicrm`.',
  'civicrm_file'                             => '`civicrm`.',
  'civicrm_financial_account'                => '`civicrm`.',
  'civicrm_financial_item'                   => '`civicrm`.',
  'civicrm_financial_trxn'                   => '`civicrm`.',
  'civicrm_financial_type'                   => '`civicrm`.',
  'civicrm_grant'                            => '`civicrm`.',
  'civicrm_group'                            => '`civicrm`.',
  'civicrm_group_contact'                    => '`civicrm`.',
  'civicrm_group_contact_cache'              => '`civicrm`.',
  'civicrm_group_nesting'                    => '`civicrm`.',
  'civicrm_group_organization'               => '`civicrm`.',
  'civicrm_im'                               => '`civicrm`.',
  'civicrm_job'                              => '`civicrm`.',
  'civicrm_job_log'                          => '`civicrm`.',
  'civicrm_line_item'                        => '`civicrm`.',
  'civicrm_loc_block'                        => '`civicrm`.',
  'civicrm_location_type'                    => '`civicrm`.',
  'civicrm_log'                              => '`civicrm`.',
  'civicrm_mail_settings'                    => '`civicrm`.',
  'civicrm_mailing'                          => '`civicrm`.',
  'civicrm_mailing_abtest'                   => '`civicrm`.',
  'civicrm_mailing_bounce_pattern'           => '`civicrm`.',
  'civicrm_mailing_bounce_type'              => '`civicrm`.',
  'civicrm_mailing_component'                => '`civicrm`.',
  'civicrm_mailing_event_bounce'             => '`civicrm`.',
  'civicrm_mailing_event_confirm'            => '`civicrm`.',
  'civicrm_mailing_event_delivered'          => '`civicrm`.',
  'civicrm_mailing_event_forward'            => '`civicrm`.',
  'civicrm_mailing_event_opened'             => '`civicrm`.',
  'civicrm_mailing_event_queue'              => '`civicrm`.',
  'civicrm_mailing_event_reply'              => '`civicrm`.',
  'civicrm_mailing_event_subscribe'          => '`civicrm`.',
  'civicrm_mailing_event_trackable_url_open' => '`civicrm`.',
  'civicrm_mailing_event_unsubscribe'        => '`civicrm`.',
  'civicrm_mailing_group'                    => '`civicrm`.',
  'civicrm_mailing_job'                      => '`civicrm`.',
  'civicrm_mailing_recipients'               => '`civicrm`.',
  'civicrm_mailing_spool'                    => '`civicrm`.',
  'civicrm_mailing_trackable_url'            => '`civicrm`.',
  'civicrm_managed'                          => '`civicrm`.',
  'civicrm_mapping'                          => '`civicrm`.',
  'civicrm_mapping_field'                    => '`civicrm`.',
  'civicrm_membership'                       => '`civicrm`.',
  'civicrm_membership_block'                 => '`civicrm`.',
  'civicrm_membership_log'                   => '`civicrm`.',
  'civicrm_membership_payment'               => '`civicrm`.',
  'civicrm_membership_status'                => '`civicrm`.',
  'civicrm_membership_type'                  => '`civicrm`.',
  'civicrm_menu'                             => '`civicrm`.',
  'civicrm_navigation'                       => '`civicrm`.',
  'civicrm_note'                             => '`civicrm`.',
  'civicrm_openid'                           => '`civicrm`.',
  'civicrm_option_group'                     => '`civicrm`.',
  'civicrm_option_value'                     => '`civicrm`.',
  'civicrm_participant'                      => '`civicrm`.',
  'civicrm_participant_payment'              => '`civicrm`.',
  'civicrm_participant_status_type'          => '`civicrm`.',
  'civicrm_payment_processor'                => '`civicrm`.',
  'civicrm_payment_processor_type'           => '`civicrm`.',
  'civicrm_payment_token'                    => '`civicrm`.',
  'civicrm_pcp'                              => '`civicrm`.',
  'civicrm_pcp_block'                        => '`civicrm`.',
  'civicrm_persistent'                       => '`civicrm`.',
  'civicrm_phone'                            => '`civicrm`.',
  'civicrm_pledge'                           => '`civicrm`.',
  'civicrm_pledge_block'                     => '`civicrm`.',
  'civicrm_pledge_payment'                   => '`civicrm`.',
  'civicrm_preferences_date'                 => '`civicrm`.',
  'civicrm_premiums'                         => '`civicrm`.',
  'civicrm_premiums_product'                 => '`civicrm`.',
  'civicrm_prevnext_cache'                   => '`civicrm`.',
  'civicrm_price_field'                      => '`civicrm`.',
  'civicrm_price_field_value'                => '`civicrm`.',
  'civicrm_price_set'                        => '`civicrm`.',
  'civicrm_price_set_entity'                 => '`civicrm`.',
  'civicrm_print_label'                      => '`civicrm`.',
  'civicrm_product'                          => '`civicrm`.',
  'civicrm_queue_item'                       => '`civicrm`.',
  'civicrm_recurring_entity'                 => '`civicrm`.',
  'civicrm_relationship'                     => '`civicrm`.',
  'civicrm_relationship_type'                => '`civicrm`.',
  'civicrm_report_instance'                  => '`civicrm`.',
  'civicrm_saved_search'                     => '`civicrm`.',
  'civicrm_setting'                          => '`civicrm`.',
  'civicrm_sms_provider'                     => '`civicrm`.',
  'civicrm_state_province'                   => '`civicrm`.',
  'civicrm_subscription_history'             => '`civicrm`.',
  'civicrm_survey'                           => '`civicrm`.',
  'civicrm_system_log'                       => '`civicrm`.',
  'civicrm_tag'                              => '`civicrm`.',
  'civicrm_tell_friend'                      => '`civicrm`.',
  'civicrm_timezone'                         => '`civicrm`.',
  'civicrm_uf_field'                         => '`civicrm`.',
  'civicrm_uf_group'                         => '`civicrm`.',
  'civicrm_uf_join'                          => '`civicrm`.',
  'civicrm_uf_match'                         => '`civicrm`.',
  'civicrm_website'                          => '`civicrm`.',
  'civicrm_word_replacement'                 => '`civicrm`.',
  'civicrm_worldregion'                      => '`civicrm`.',
);
EOF

echo "Script finished."
