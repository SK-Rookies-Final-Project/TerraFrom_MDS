#!/bin/bash

sh scripts/inventory_setting.sh

sh scripts/ip_vars_setting.sh

ansible-playbook -i inventory.ini setup.yml