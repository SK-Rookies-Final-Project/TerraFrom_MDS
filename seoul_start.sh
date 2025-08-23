cd seoul
terraform init
terraform plan -var-file="../common/terraform.tfvars"
terraform apply -auto-approve -var-file="../common/terraform.tfvars"

cd ansible
sh ip_setup.sh

sh start_ansible.sh