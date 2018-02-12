## CiviCRM-Drupal

This is an sh(1) script to fully automate install of CiviCRM-Drupal.  It
assumes you are using some kind of Red Hat Linux (RHEL/OL/CentOS).  The
following software is installed and configured: Nginx, MariaDB, Certbot,
Drush, Drupal, CiviCRM.

## Install

Edit install.sh and change the default passwords and example.com domain
to match your environment.  Then run the script.

```
# ./install.sh
```

## Uninstall

This is a script to remove everything what was installed with install.sh

```
# ./clearinstall.sh
```
