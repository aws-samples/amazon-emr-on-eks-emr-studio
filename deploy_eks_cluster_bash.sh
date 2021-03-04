#!/bin/bash

### How to run this shell script and pass in the account ID parameter (start)
#
#  $ bash deploy_eks_cluster_bash.sh "< account id >" 
#
### How to run this shell script and pass in the account ID parameter (end)

### Test for account ID parameter passed through else exit from script
echo $# arguments 
if [ "$#" -lt 2 ]; then
    echo "Please make sure you provide 2 parameters: Region and Account ID; example: bash deploy_eks_cluster_bash.sh 'us-east-1' '12345678'";
    exit 1
fi

### Parameters

########## Parameters (Start)

### Global parameters (start)
region="${1}"  ## Region VPC and cluster will be implemented
accountid="${2}" ## AWS Account ID
### Global parameters (end)

source ./parameters.sh

########## Parameters (End)

####################### Functions (start) ###############################

### CloudFormation create stack wait function

cf_stack_status () {

  local cf_stackname=${1}

  local vpccfstatus="NOT STARTED"
  local timesec=15
  local timewait=15

  sleep ${timewait}

  echo "CloudFormation Stack ${cf_stackname} Status..."

  while [ "${vpccfstatus}" != "CREATE_COMPLETE" ]
  do
  
    vpccfstatus=$(aws cloudformation describe-stacks \
      --stack-name ${cf_stackname} \
      --region ${region} | jq '.Stacks[].StackStatus' | sed 's/\"//g')

    echo "Status at ${timesec} sec.: ${vpccfstatus}"
    sleep ${timewait}
    timesec=$(($timesec+${timewait}))
  done

  echo "Status at ${timesec} sec.: ${vpccfstatus}"

}

####################### Functions (end) ###############################


####################### Main Script Starts here ##############################
tagarray=(
    "clustername" 
    "region" 
    "managedNodeName" 
    "instanceType" 
    "volumeSize" 
    "desiredCapacity" 
    "maxPodsPerNode" 
    "pubkey" 
    "policyarn"
)

tagarrayvalue=(
  "$clustername" 
  "$region" 
  "$managedNodeName" 
  "$instanceType" 
  "$volumeSize" 
  "$desiredCapacity" 
  "$maxPodsPerNode" 
  "$pubkey" 
  "$policyarn"
)

# Create VPC

aws cloudformation create-stack \
  --stack-name ${vpcstack} \
  --template-body file://templates/cf_vpc.yaml \
  --parameters ParameterKey=VpcCidr,ParameterValue="${VpcCidr}" \
    ParameterKey=PrivateSubnet0Cidr,ParameterValue="${PrivateSubnet0Cidr}" \
    ParameterKey=PrivateSubnet1Cidr,ParameterValue="${PrivateSubnet1Cidr}" \
    ParameterKey=PublicSubnet0Cidr,ParameterValue="${PublicSubnet0Cidr}" \
    ParameterKey=PublicSubnet1Cidr,ParameterValue="${PublicSubnet1Cidr}" \
  --region ${region}

# Check VPC create status before moving on
cf_stack_status ${vpcstack}

vpcarray=(
  "Vpc" "VpcCidr" 
  "PrivateSubnet0" "PrivateSubnet0Cidr" 
  "PrivateSubnet1" "PrivateSubnet1Cidr" 
  "PublicSubnet0" "PublicSubnet0Cidr" 
  "PublicSubnet1" "PublicSubnet1Cidr"
)

## Create temporary folder
mkdir temp

## Copy deployment template
cp templates/eks_cluster_spark_deployment.yaml.template temp/eks_cluster_spark_deployment.yaml

## Get VPC Info from CloudFormation output
vpcinfo=$(aws cloudformation describe-stacks \
  --stack-name ${vpcstack} \
  --region $region | jq '.Stacks[].Outputs[]')

vpcid=""

for k in ${vpcarray[*]}
  do
    #echo ${k}
    slct="jq 'select(.OutputKey==\"${k}\")' | jq .OutputValue | sed 's/\"//g'"
    vl=$(echo $vpcinfo | eval $slct)

    
    ## Correct for CIDR /
    if grep -q -i ".*cidr" <<< "$k"; then
       vl=$(echo ${vl} | sed 's/\//\\\//')
    fi

    echo "${k}: ${vl}"

    ## Set the AZs
    if grep -q "subnet-" <<< "$vl"; then

        az=$(aws ec2 describe-subnets --region ${region} --subnet-id $vl | jq '.Subnets[0].AvailabilityZone' | sed 's/\"//g')
        echo $az
        aztag=""

        if grep -q -i "^private.*" <<< "$k"; then
          aztag+="%private_az_${k: -1}%"
        fi 

        if grep -q -i "^public.*" <<< "$k"; then
          aztag+="%public_az_${k: -1}%"
        fi
        #echo $aztag

        sedstr="s/${aztag}/${az}/"
        #echo ${sedstr}
        sed -i ${sedstr} temp/eks_cluster_spark_deployment.yaml

    fi

    ## Set the VPC and subnet values
    sedstr="s/%${k}%/${vl}/"
    sed -i ${sedstr} temp/eks_cluster_spark_deployment.yaml

    if [[ "${k}" == "Vpc" ]]; then
      vpcid=${vl}
    fi

done

## Replace tags in the tagarray 

stcount=0

for t in ${tagarray[*]}
  do
    tagvalue=$(echo ${tagarrayvalue[${stcount}]} | sed 's/\//\\\//g')
    echo "${t}: ${tagvalue}"
    ((stcount=stcount+1))
    sedstr="s/%${t}%/${tagvalue}/"
    echo $sedstr
    sed -i ${sedstr} temp/eks_cluster_spark_deployment.yaml
done

## Create EKS Cluster

eksctl create cluster -f temp/eks_cluster_spark_deployment.yaml

## Check EKS Cluster

eksctl get cluster -n ${clustername} --region ${region} --output json

ekscluster_status=$(eksctl get cluster \
  -n ${clustername} \
  --region ${region} --output json | jq .[0].Status | sed 's/"//g')

echo "EKS Cluster ${clustername} is ${ekscluster_status}."

### Pre-Requisite installs on the Cloud9 

## Install Helm
curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

helm repo add stable https://charts.helm.sh/stable

#helm search repo stable

helm completion bash >> ~/.bash_completion
. /etc/profile.d/bash_completion.sh
. ~/.bash_completion
source <(helm completion bash)

## Enable EKS cluster access to EMR

eksctl create iamidentitymapping \
  --cluster ${clustername} \
  --namespace default \
  --service-name "emr-containers" \
  --region ${region}

## Create OpenID Connect Provider

# Create an IAM OIDC identity provider for your cluster with eksctl
eksctl utils associate-iam-oidc-provider --cluster ${clustername} --region ${region} --approve

## Create EMR on EKS Job Execution Policy

aws cloudformation create-stack --stack-name ${cf_iam_stackname} --region ${region} --template-body file://templates/iam_role_job_execution.yaml --capabilities CAPABILITY_IAM

## Check Status before continuing
cf_stack_status ${cf_iam_stackname}

role_arn=$(aws cloudformation describe-stacks \
    --stack-name ${cf_iam_stackname} \
    --region ${region} | jq '.Stacks[].Outputs[]' | jq 'select(.OutputKey=="IAMRoleArn")' | jq .OutputValue | sed 's/\"//g')

echo "Job Execution Role ARN: ${role_arn}"

role_name=$(aws cloudformation describe-stacks \
    --stack-name ${cf_iam_stackname} \
    --region ${region} | jq '.Stacks[].Outputs[]' | jq 'select(.OutputKey=="IAMRole")' | jq .OutputValue | sed 's/\"//g')

echo "Job Execution Role Name: ${role_name}"

# Modify the Trust Relationship

aws emr-containers update-role-trust-policy \
  --cluster-name ${clustername} \
  --namespace default \
  --role-name ${role_name} \
  --region ${region}

## Create IAM Policy for the AWS Load Balancer Controller

aws cloudformation create-stack --stack-name ${cf_iam_alb_policy_stackname} --region ${region} --template-body file://templates/iam_policy_alb.yaml --capabilities CAPABILITY_IAM

# Check status before moving on
cf_stack_status ${cf_iam_alb_policy_stackname}

policy_arn=$(aws cloudformation describe-stacks \
    --stack-name ${cf_iam_alb_policy_stackname} \
    --region ${region} | jq '.Stacks[].Outputs[]' | jq 'select(.OutputKey=="IAMPolicyRole")' | jq .OutputValue | sed 's/\"//g')

echo "ALB controller Policy ARN: ${policy_arn}"


# Create an IAM role and annotate the Kubernetes service account 
# named aws-load-balancer-controller in the kube-system namespace 
# for the AWS Load Balancer Controller using one of the following options.

eksctl create iamserviceaccount \
  --cluster=${clustername} \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=${policy_arn} \
  --override-existing-serviceaccounts \
  --region ${region} \
  --approve

roleArn=$(eksctl get iamserviceaccount \
  --cluster ${clustername} \
  --region ${region} \
  --output json | jq .iam.serviceAccounts | jq '.[] | select(.metadata.name=="aws-load-balancer-controller")' | jq .status.roleARN | sed 's/"//g' | sed 's/\//\\\//g')

echo "Role ARN of ALB Controller IAM Role: ${roleArn}"

#Copy LB controller service template file
cp templates/aws-load-balancer-controller-service-account.yaml.template temp/aws-load-balancer-controller-service-account.yaml

# Prepare LB controller service template file

sedstr="s/%alb_role_arn%/${roleArn}/"
echo $sedstr
sed -i ${sedstr} temp/aws-load-balancer-controller-service-account.yaml

# Create service account on the cluster

kubectl apply -f temp/aws-load-balancer-controller-service-account.yaml

# Install the TargetGroupBinding custom resource definitions

kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller//crds?ref=master"

# Add the eks-charts repository

helm repo add eks https://aws.github.io/eks-charts

# Install the AWS Load Balancer Controller using the command that 
# corresponds to the Region that your cluster is in


helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
  --set clusterName=${clustername} \
  --set region=${region} \
  --set vpcId=${vpcid} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  -n kube-system

sleep 15
# Test controller is installed

kubectl get deployment -n kube-system aws-load-balancer-controller

## Creating the Virtual EMR Cluster

aws emr-containers create-virtual-cluster \
  --name ${virtclustername} \
  --container-provider "{
    \"id\": \"${clustername}\",
    \"type\": \"EKS\",
    \"info\": {
      \"eksInfo\": {
        \"namespace\": \"default\"
      }
    } 
  }" \
  --region ${region}

## Verify and get the virtual EMR cluster ID

# Get json of virt cluster

arrlength=$(aws emr-containers list-virtual-clusters --region ${region} | jq '.virtualClusters | length')

arrcount=0
virtclusterid=""
_virtclusterid=""
virtclusterstate=""
vc_running=0

while [ ${arrcount} -le ${arrlength} ]
do
  virt_name=$(aws emr-containers list-virtual-clusters --region ${region} | jq .virtualClusters[${arrcount}].name | sed 's/"//g')

  if [[ "${virt_name}" == "${virtclustername}" ]]; then

    _virtclusterid=$(aws emr-containers list-virtual-clusters --region ${region} | jq .virtualClusters[${arrcount}].id | sed 's/"//g')

    virtclusterstate=$(aws emr-containers list-virtual-clusters --region ${region} | jq .virtualClusters[${arrcount}].state | sed 's/"//g')

    echo "Virt Cluster: ${virt_name} | ${_virtclusterid} is in ${virtclusterstate} state."

    if [[ "${virtclusterstate}" == "RUNNING" ]]; then
      vc_running=$((vc_running+1))
      virtclusterid=${_virtclusterid}
    fi
  fi

  arrcount=$((arrcount+1))

done


## Create Virtual Endpoint

aws emr-containers create-managed-endpoint \
--type JUPYTER_ENTERPRISE_GATEWAY \
--virtual-cluster-id ${virtclusterid} \
--name ${virtendpointname} \
--execution-role-arn ${role_arn} \
--release-label ${emr_release_label} \
--certificate-arn ${certarn} \
--region ${region} \
--configuration-overrides '{
    "applicationConfiguration": [
      {
        "classification": "spark-defaults",
        "properties": {
          "spark.hadoop.hive.metastore.client.factory.class": "com.amazonaws.glue.catalog.metastore.AWSGlueDataCatalogHiveClientFactory",
          "spark.sql.catalogImplementation": "hive"
        }
      }
    ]
  }'


virt_ep_state="CREATING"

while [ "${virt_ep_state}" == "CREATING" ]
do

  virt_ep_json=$(aws emr-containers list-managed-endpoints \
    --region $region \
    --virtual-cluster-id ${virtclusterid} | jq .endpoints | jq ".[] | select(.name==\"${virtendpointname}\")")

  virt_ep_state=$(echo $virt_ep_json | jq .state | sed 's/"//g')
  virt_ep_name=$(echo $virt_ep_json | jq .name | sed 's/"//g')
  virt_ep_id=$(echo $virt_ep_json | jq .id | sed 's/"//g')

  echo "${virt_ep_name} | ${virt_ep_id} is in ${virt_ep_state} state ..."
  sleep 15

done

### Create EMR Studio Steps

## Create EMR Studio Security Groups

aws cloudformation create-stack --stack-name ${cf_studio_sg_stackname} \
  --region ${region} \
  --template-body file://templates/emr_studio_security_groups.yaml \
  --parameters ParameterKey=Vpc,ParameterValue="${vpcid}" \
  --capabilities CAPABILITY_IAM

# Check status before moving on
cf_stack_status ${cf_studio_sg_stackname}

## Create Security Groups for EMR Studio

engineSg=$(aws cloudformation describe-stacks \
    --stack-name ${cf_studio_sg_stackname} \
    --region ${region} | jq '.Stacks[].Outputs[]' | jq 'select(.OutputKey=="engineSecurityGroup")' | jq .OutputValue | sed 's/\"//g')

echo "Engine Security Group: ${engineSg}"

workspaceSg=$(aws cloudformation describe-stacks \
    --stack-name ${cf_studio_sg_stackname} \
    --region ${region} | jq '.Stacks[].Outputs[]' | jq 'select(.OutputKey=="workspaceSecurityGroup")' | jq .OutputValue | sed 's/\"//g')

echo "Workspace Security Group: ${workspaceSg}"

########### Create IAM roles for EMR Studio

### Create service IAM role for EMR Studio

aws cloudformation create-stack --stack-name ${cf_studio_role_service_stackname} \
  --region ${region} \
  --template-body file://templates/emr_studio_service_role.yaml \
  --capabilities CAPABILITY_IAM

# Check status before moving on
cf_stack_status ${cf_studio_role_service_stackname}

role_arn_service=$(aws cloudformation describe-stacks \
    --stack-name ${cf_studio_role_service_stackname} \
    --region ${region} | jq '.Stacks[].Outputs[]' | jq 'select(.OutputKey=="IAMRoleArn")' | jq .OutputValue | sed 's/\"//g')

echo "Studio Service IAM Role ARN: ${role_arn_service}"

### Create user IAM role for EMR Studio

cp templates/emr_studio_user_role.yaml.template temp/emr_studio_user_role.yaml

## Set the CloudFormation template variables for deploying

_role_arn_service=$(echo ${role_arn_service} | sed 's/\//\\\//g')

sed -i "s/%accountid%/${accountid}/g" temp/emr_studio_user_role.yaml
sed -i "s/%studio_default_s3_location_bucket%/${studio_default_s3_location_bucket}/" temp/emr_studio_user_role.yaml
sed -i "s/%region%/${region}/g" temp/emr_studio_user_role.yaml
sed -i "s/%role_arn_service%/${_role_arn_service}/" temp/emr_studio_user_role.yaml

aws cloudformation create-stack --stack-name ${cf_studio_role_user_stackname} \
  --region ${region} \
  --template-body file://temp/emr_studio_user_role.yaml \
  --capabilities CAPABILITY_IAM

# Check status before moving on
cf_stack_status ${cf_studio_role_user_stackname}

role_arn_user=$(aws cloudformation describe-stacks \
    --stack-name ${cf_studio_role_user_stackname} \
    --region ${region} | jq '.Stacks[].Outputs[]' | jq 'select(.OutputKey=="IAMRoleArn")' | jq .OutputValue | sed 's/\"//g')

echo "Studio User IAM Role ARN: ${role_arn_user}"

cp templates/iam_policy_studio_user.yaml.template temp/iam_policy_studio_user.yaml

sed -i "s/%accountid%/${accountid}/g" temp/iam_policy_studio_user.yaml
sed -i "s/%studio_default_s3_location_bucket%/${studio_default_s3_location_bucket}/" temp/iam_policy_studio_user.yaml
sed -i "s/%region%/${region}/g" temp/iam_policy_studio_user.yaml
sed -i "s/%role_arn_service%/${_role_arn_service}/" temp/iam_policy_studio_user.yaml

## Create IAM Policy for EMR Studio
aws cloudformation create-stack --stack-name ${cf_studio_policy_user_stackname} \
  --region ${region} \
  --template-body file://temp/iam_policy_studio_user.yaml \
  --capabilities CAPABILITY_IAM

cf_stack_status ${cf_studio_policy_user_stackname}

policy_studio_user_arn=$(aws cloudformation describe-stacks \
  --stack-name ${cf_studio_policy_user_stackname} \
  --region ${region} | jq '.Stacks[].Outputs[]' | jq 'select(.OutputKey=="IAMPolicyArn")' | jq .OutputValue | sed 's/\"//g')

echo "User Policy ARN for EMR Studio: ${policy_studio_user_arn}"

## Get EKS cluster subnets

subnetArray=$(aws eks describe-cluster --name ${clustername} \
--region ${region} | jq .cluster.resourcesVpcConfig.subnetIds)

arraycount=$(echo ${subnetArray} | jq length)
arraycount=$((arraycount -1))

i=0
subnetString=""

while [ ${i} -le ${arraycount} ]; do

  subnetString+=$(echo $subnetArray | jq .[${i}];i=$((i+1)))
  subnetString+=" "
  #echo ${subnetString}
  i=$((i+1))

done

subnetString=$(echo ${subnetString} | sed 's/"//g')
echo "Subnets to be used: ${subnetString}"

## Create EMR Studio

studio_json=$(aws emr create-studio \
  --name ${studio_name} \
  --auth-mode ${studio_auth_mode} \
  --vpc-id ${vpcid} \
  --subnet-ids ${subnetString} \
  --service-role ${role_arn_service} \
  --user-role ${role_arn_user} \
  --workspace-security-group-id ${workspaceSg} \
  --engine-security-group-id ${engineSg} \
  --default-s3-location ${studio_default_s3_location} \
  --region ${region})

studio_id=$(echo ${studio_json} | jq .StudioId | sed 's/"//g')
studio_url=$(echo ${studio_json} | jq .Url | sed 's/"//g')

echo "Studio created... ID: ${studio_id} | URL: ${studio_url}"

## Assign user to EMR Studio

aws emr create-studio-session-mapping \
 --studio-id ${studio_id} \
 --identity-name ${studio_user_to_map} \
 --identity-type USER \
 --session-policy-arn ${policy_studio_user_arn}

## List Studio mapping to user

aws emr list-studio-session-mappings --region ${region}

## Conclusion

echo "Go to ${studio_url} and login using ${studio_user_to_map} ..."

