#!/bin/bash

sh ip_setup.sh

sh ip_vars_setup.sh

# aws 키를 기입해야 함
ansible-playbook -i inventory.ini setup_connect.yml
