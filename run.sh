#!/bin/bash

set -euo pipefail

echo "Starting"

INSTALATION_TYPE="${1}"

ROLE_NAME="DeliveryRole"

echo "Ensure desired role: $ROLE_NAME"

echo "{}" > /tmp/config.json
aws ssm get-parameter \
       --name "/install/config" \
       --with-decryption \
       --query 'Parameter.Value' \
       --output text > /tmp/config.json || echo "No config"

if aws iam get-role --role-name $ROLE_NAME &> /dev/null; then
    echo "Role $ROLE_NAME already exists. Skipping creation."
else
    ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text)"
    TRUST_POLICY_DOCUMENT=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com" 
      },
      "Action": "sts:AssumeRole"
    },
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "${ROLE_ARN}" 
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

    echo "Creating role $ROLE_NAME..."
    aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document "$TRUST_POLICY_DOCUMENT"

fi


POLICY_ARN="arn:aws:iam::aws:policy/AdministratorAccess"
echo "Attaching AdministratorAccess policy to $ROLE_NAME..."
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN

POLICY_ARN="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
echo "Attaching SSM policy to $ROLE_NAME..."
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN

for policy in $(cat /tmp/config.json | jq -r '.builder.role.additionalPolicies | join(" ")'); do 
  echo "Adding $policy"
  aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $policy
done

if aws iam get-instance-profile --instance-profile-name $ROLE_NAME &> /dev/null; then
    echo "Instance profile $ROLE_NAME already exists."
else
    # Create the instance profile
    echo "Creating instance profile $ROLE_NAME..."
    aws iam create-instance-profile --instance-profile-name $ROLE_NAME

    # Add the role to the instance profile
    echo "Adding role $ROLE_NAME to instance profile..."
    aws iam add-role-to-instance-profile --instance-profile-name $ROLE_NAME --role-name $ROLE_NAME
    echo "Sleeping 15 seconds becaue otherwise AWS reports invalid instance profile :S)"
    sleep 15
fi

INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile \
    --instance-profile-name $ROLE_NAME \
    --query 'InstanceProfile.Arn' \
    --output text)

echo "Using instance profile ${INSTANCE_PROFILE_ARN}"

SECURITY_GROUP_NAME="DeliverySecurityGroup"
echo "Creating security group: $SECURITY_GROUP_NAME"

REGION="${AWS_DEFAULT_REGION}"

SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
    --region $REGION \
    --filters Name=group-name,Values=$SECURITY_GROUP_NAME \
    --query 'SecurityGroups[*].GroupId' \
    --output text)

VPC_ID=$(aws ec2 describe-vpcs \
    --region $REGION \
    --query 'Vpcs[0].VpcId' \
    --output text)

echo "Using VPC: ${VPC_ID}"

# Create the security group if it doesn't exist
if [ -z "$SECURITY_GROUP_ID" ]; then
    echo "Creating security group..."
    aws ec2 create-security-group \
        --region $REGION \
        --vpc-id $VPC_ID \
        --group-name $SECURITY_GROUP_NAME \
        --description "Delivery security group" \
        --output text
else 
    echo "Group already exists ${SECURITY_GROUP_ID}"
fi 

TAG="DeliveryBuilder"

echo "Terminating old instances with tag; ${TAG}"
INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${TAG}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text)

if [ -z "$INSTANCE_IDS" ]; then
    echo "No instances found with the tag Name: ${TAG}"
else
    # Terminate the instances
    echo "Terminating instances: $INSTANCE_IDS"
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS
fi


SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --filters "Name=tag:Name,Values=*PrivateSubnet*,*Internal*" \
  --query 'Subnets[0].SubnetId' \
  --output text)

ami_filter="al2023-ami-2023*"
if [[ ! -z "$(cat /tmp/config.json | jq -r '.builder.amiFilter // empty')" ]]; then 
   ami_filter="$(cat /tmp/config.json | jq -r '.builder.amiFilter')"
fi

echo "Get the latest x86_64 $ami_filter"
latest_ami_id=$(aws ec2 describe-images \
  --filters "Name=name,Values=${ami_filter}" "Name=architecture,Values=x86_64" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)

echo "Check if an AMI was found"
if [ -n "$latest_ami_id" ]; then
  echo "Latest x86_64 AMI ID for '$ami_filter': $latest_ami_id"
else
  echo "No x86_64 AMI found with name '$ami_filter'"
  exit 1
fi


echo "Creating EC2 instance in subnet $SUBNET_ID ..."
public_ip="--associate-public-ip-address"
if [[ "$(cat /tmp/config.json | jq -r '.builder."associate-public-ip-address" // empty')" == "False" ]]; then 
   public_ip=""
fi
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $latest_ami_id \
    --count 1 \
    --instance-type t3.small \
    --security-group-ids $SECURITY_GROUP_ID \
    --iam-instance-profile "Arn=$INSTANCE_PROFILE_ARN" \
    --subnet-id $SUBNET_ID \
    ${public_ip} \
    --query 'Instances[0].InstanceId' \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=5" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG}]" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"Encrypted\":true,\"VolumeSize\":100}}]" \
    --output text)

echo "Instance created with ID: $INSTANCE_ID"
echo "Waiting for instance to be in running state..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

echo "Wait for instanc ok"
aws ec2 wait instance-status-ok --instance-ids $INSTANCE_ID

aws ec2 modify-instance-metadata-options \
    --instance-id $INSTANCE_ID \
    --http-put-response-hop-limit 3 \
    --http-endpoint enabled

install () {
  INSTANCE_ID="${1}"
  COMMAND="${2}"
  COMMAND_ID=$(aws ssm send-command \
    --instance-ids "${INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" \
    --comment "${COMMAND:0:99}" \
    --parameters '{"commands":["if [[ -f /etc/bash_init ]]; then source /etc/bash_init; fi", "'"${COMMAND}"'"]}' \
    --output text \
    --query "Command.CommandId")

  echo "Command ID: $COMMAND_ID"

  aws ssm wait command-executed \
    --command-id $COMMAND_ID \
    --instance-id "$INSTANCE_ID"

  echo "Command execution completed."


  echo "Get detailed results ${COMMAND_ID}"
  aws ssm get-command-invocation \
    --command-id $COMMAND_ID \
    --instance-id "$INSTANCE_ID" | jq -r '.StandardOutputContent'
}


install $INSTANCE_ID "update-ca-trust extract"

install $INSTANCE_ID "yum install -y git"
install $INSTANCE_ID "yum install -y jq"
install $INSTANCE_ID "yum install -y docker"
install $INSTANCE_ID "systemctl start docker"
install $INSTANCE_ID "cat /etc/passwd"

install $INSTANCE_ID 'useradd -m ssm-user -s /bin/sh;'
install $INSTANCE_ID 'passwd --delete ssm-user;'
install $INSTANCE_ID 'echo \"ssm-user ALL=(ALL) NOPASSWD:ALL\" | tee -a /etc/sudoers.d/ssm-agent-users;'
install $INSTANCE_ID "usermod -aG docker ssm-user"

echo "Loading custom certificates"
parameter_names=$(aws ssm get-parameters-by-path \
                     --path '/install/certificates/' \
                     --recursive \
                     --query 'Parameters[*].[Name]' \
                     --output text | xargs -I {} basename {})
for parameter_name in $parameter_names; do \
   echo "Processing ${parameter_name}"; \
   out=; \
   cert=$(aws ssm get-parameter \
     --name /install/certificates/${parameter_name} \
     --with-decryption \
     --query 'Parameter.Value' \
     --output text | base64 -w0); \
   install $INSTANCE_ID "echo $cert | base64 -d > /etc/pki/ca-trust/source/anchors/${parameter_name}"
done
install $INSTANCE_ID "update-ca-trust extract"

echo "Configure environment"
echo "{}" > /tmp/environment.json
aws ssm get-parameter \
       --name "/install/config" \
       --with-decryption \
       --query 'Parameter.Value' \
       --output text > /tmp/environment.json || echo "No config"
for environment in $(cat /tmp/environment.json | jq -r '.builder.environment | join(" ")'); do 
  echo "Adding environment:"
  install $INSTANCE_ID "echo $environment >> /etc/environment"
  env_export="export $environment"
  install $INSTANCE_ID "echo $env_export >> /etc/bash_init"
done
install $INSTANCE_ID "echo source /etc/bash_init >> /etc/bashrc"
echo "Done config environment"

echo "Cloning installation repo"
install $INSTANCE_ID "git clone https://github.com/alpha-prosoft/alpha-jenkins-svc.git /root/alpha-jenkins-svc"
install $INSTANCE_ID "git clone https://github.com/alpha-prosoft/alpha-gerrit-svc.git /root/alpha-gerrit-svc"
install $INSTANCE_ID "git clone https://github.com/alpha-prosoft/alpha-base-svc.git /root/alpha-base-svc"

project_name="alpha*"
if [[ ! -z "$(cat /tmp/config.json | jq -r '."project-name" // empty')" ]]; then 
   project_name="$(cat /tmp/config.json | jq -r '."project-name"')"
fi

echo "Done setting up config for project ${project_name}"
echo "####################################"
echo "Now you can connect with session manager to instance $INSTANCE_ID,"
echo "go to /root/alpha-${INSTALATION_TYPE}-svc and run ./build-and-deploy.sh"
echo "########### THANK YOU ##############"
