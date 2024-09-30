#!/bin/bash

set -euo pipefail

echo "Starting"

INSTALATION_TYPE="${1}"

ROLE_NAME="DeliveryRole"

echo "Ensure desired role: $ROLE_NAME"


if aws iam get-role --role-name $ROLE_NAME &> /dev/null; then
    echo "Role $ROLE_NAME already exists. Skipping creation."
else
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




if aws iam get-instance-profile --instance-profile-name $ROLE_NAME &> /dev/null; then
    echo "Instance profile $ROLE_NAME already exists."
else
    # Create the instance profile
    echo "Creating instance profile $ROLE_NAME..."
    aws iam create-instance-profile --instance-profile-name $ROLE_NAME

    # Add the role to the instance profile
    echo "Adding role $ROLE_NAME to instance profile..."
    aws iam add-role-to-instance-profile --instance-profile-name $ROLE_NAME --role-name $ROLE_NAME
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
  --query 'Subnets[0].SubnetId' \
  --output text)


echo "Creating EC2 instance in subnet $SUBNET_ID ..."

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2 \
    --count 1 \
    --instance-type t3.small \
    --security-group-ids $SECURITY_GROUP_ID \
    --iam-instance-profile "Arn=$INSTANCE_PROFILE_ARN" \
    --subnet-id $SUBNET_ID \
    --associate-public-ip-address \
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

install () {
  INSTANCE_ID="${1}"
  COMMAND="${2}"
  COMMAND_ID=$(aws ssm send-command \
    --instance-ids "${INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" \
    --comment "${COMMAND}" \
    --parameters '{"commands":["#!/usr/bin/bash","'"${COMMAND}"'"]}' \
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

install $INSTANCE_ID "yum install -y git"
install $INSTANCE_ID "yum install -y jq"
install $INSTANCE_ID "yum install -y docker"
install $INSTANCE_ID "systemctl start docker"
install $INSTANCE_ID "cat /etc/passwd"

install $INSTANCE_ID 'useradd -m ssm-user -s /bin/sh;'
install $INSTANCE_ID 'passwd --delete ssm-user;'
install $INSTANCE_ID 'echo \"ssm-user ALL=(ALL) NOPASSWD:ALL\" | tee -a /etc/sudoers.d/ssm-agent-users;'
install $INSTANCE_ID "usermod -aG docker ssm-user"


install $INSTANCE_ID "git clone https://github.com/alpha-prosoft/alpha-${INSTALATION_TYPE}-svc.git /tmp/jenkins"


echo "Done"
