#!/bin/bash

### How to run this shell script and pass in the account ID parameter (start)
#
#  $ bash deploy_eks_cluster_bash.sh ## If using default accountid and region of Cloud9 Desktop
#  $ bash deploy_eks_cluster_bash.sh "<region>" "< account id >" ## If choosing different account id and region
#
### How to run this shell script and pass in the account ID parameter (end)

### Parameters

########## Parameters (Start)

### Global parameters (start)
region="${1}"  ## Region VPC and cluster will be implemented
accountid="${2}" ## AWS Account ID
### Global parameters (end)

### Test for account ID parameter passed through else exit from script
echo $# arguments 
if [ "$#" -lt 2 ]; then
    accountid=$(aws sts get-caller-identity | jq .Account | sed 's/"//g')
    region=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
    echo "Using default $region and $accountid. If not desired, please make sure you provide 2 parameters: Region and Account ID; example: bash deploy_eks_cluster_bash.sh 'us-east-1' '12345678'"
fi

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
# Variables for replacing EKS Deployment YAML script
tagarray=(
    "clustername" 
    "region" 
    "version" 
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
  "$version" 
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

## Replace tags in the eks deployment file in the tagarray 

stcount=0

for t in ${tagarray[*]}
  do
    tagvalue=$(echo ${tagarrayvalue[${stcount}]} | sed 's/\//\\\//g')
    echo "${t}: ${tagvalue}"
    ((stcount=stcount+1))
    sedstr="s/%${t}%/${tagvalue}/g"
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

# Deploy Container Insights for EKS Cluster in CloudWatch
ClusterName="${clustername}"
LogRegion="${region}"
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'
curl https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluent-bit-quickstart.yaml | sed 's/{{cluster_name}}/'${ClusterName}'/;s/{{region_name}}/'${LogRegion}'/;s/{{http_server_toggle}}/"'${FluentBitHttpServer}'"/;s/{{http_server_port}}/"'${FluentBitHttpPort}'"/;s/{{read_from_head}}/"'${FluentBitReadFromHead}'"/;s/{{read_from_tail}}/"'${FluentBitReadFromTail}'"/' | kubectl apply -f - 


# Create name space for Spark
kubectl create ns ${namespace}

### Pre-Requisite installs on the Cloud9 for EKS

## Install Helm
bash helm/get-helm-3

helm repo add stable https://charts.helm.sh/stable

#helm search repo stable

helm completion bash >> ~/.bash_completion
. /etc/profile.d/bash_completion.sh
. ~/.bash_completion
source <(helm completion bash)

## Enable EKS cluster access to EMR

eksctl create iamidentitymapping \
  --cluster ${clustername} \
  --namespace ${namespace} \
  --service-name "emr-containers" \
  --region ${region}

## Create VpcId from EKS
vpcid=$(eksctl get cluster ${clustername} \
  --region ${region} -o json | jq .[].ResourcesVpcConfig.VpcId | sed 's/"//g')

## Create OpenID Connect Provider

# Create an IAM OIDC identity provider for your cluster with eksctl

eksctl utils associate-iam-oidc-provider --cluster ${clustername} --region ${region} --approve

## Create EMR on EKS Job Execution Policy
aws cloudformation create-stack \
  --stack-name ${cf_iam_stackname} \
  --region ${region} \
  --template-body file://templates/iam_role_job_execution.yaml \
  --capabilities CAPABILITY_IAM

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
  --namespace ${namespace} \
  --role-name ${role_name} \
  --region ${region}

aws cloudformation create-stack \
  --stack-name ${cf_iam_alb_policy_stackname} \
  --region ${region} \
  --template-body file://templates/iam_policy_alb.yaml \
  --capabilities CAPABILITY_IAM

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
  --output json | jq '.[] | select(.metadata.name=="aws-load-balancer-controller")' | jq .status.roleARN | sed 's/"//g' | sed 's/\//\\\//g')

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


# Create EMR Virtual Cluster

aws cloudformation create-stack \
  --stack-name ${cf_virtclustername} \
  --template-body file://templates/emr-container-virtual-cluster.yaml \
  --parameters ParameterKey=VirtualClusterName,ParameterValue="${virtclustername}" \
    ParameterKey=EksClusterName,ParameterValue="${clustername}" \
    ParameterKey=EksNamespace,ParameterValue="${namespace}" \
  --region ${region} \
  --capabilities CAPABILITY_IAM

# Check status before moving on
cf_stack_status ${cf_virtclustername}

# Get the Virtual Cluster ID
virtclusterid=$(aws cloudformation describe-stacks \
  --stack-name ${cf_virtclustername} \
  --region ${region} | jq '.Stacks[].Outputs[]' | jq 'select(.OutputKey=="PrimaryId")' | jq .OutputValue | sed 's/\"//g')

echo "Virtual Cluster ID: $virtclusterid"

# Create Managed Endpoint
echo "Creating Managed Endpoint ..."

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
  
# Get private subnets
subnetArray=$(aws eks describe-cluster --name ${clustername} \
--region ${region} | jq .cluster.resourcesVpcConfig.subnetIds)

arraycount=$(echo ${subnetArray} | jq length)
arraycount=$((arraycount -1))

i=0
priv_count=0
sbnet1=""
sbnet2=""

while [ ${i} -le ${arraycount} ]; do

  subnetString=$(echo $subnetArray | jq .[${i}];i=$((i+1)))
  subnetString=$(echo $subnetString | sed 's/"//g')
  
  # Check for private subnet
  exist=$(aws ec2 describe-subnets \
  --subnet-ids ${subnetString} \
  --region $region | jq .Subnets | jq .[].Tags | jq .[] | jq 'select(.Key=="kubernetes.io/role/internal-elb")' | jq .Value | sed 's/"//g')
  
  if [ "${exist}" == "1" ] && [ "$priv_count" == "1" ]; then
    priv_count=$((priv_count+1))
    subnet2=${subnetString}
  fi
  
  if [ "${exist}" == "1" ] && [ "$priv_count" == "0" ]; then
    priv_count=$((priv_count+1))
    subnet1=${subnetString}
  fi
  
  i=$((i+1))

done
echo "Private subnet 1: $subnet1"
echo "Private subnet 2: $subnet2"

# Create EMR Studio and map user and IAM policy to Studio
aws cloudformation create-stack \
  --stack-name ${cf_launch_studio_stackname} \
  --template-body file://templates/emr_studio_launch.yaml \
  --parameters ParameterKey=Vpc,ParameterValue="${vpcid}" \
    ParameterKey=AccountId,ParameterValue="${accountid}" \
    ParameterKey=Region,ParameterValue="${region}" \
    ParameterKey=EksCluster,ParameterValue="${clustername}" \
    ParameterKey=EmrStudioName,ParameterValue="${studio_name}" \
    ParameterKey=StudioAuthMode,ParameterValue="${studio_auth_mode}" \
    ParameterKey=StudioDefaultS3Bucket,ParameterValue="${studio_default_s3_location_bucket}" \
    ParameterKey=Subnet1,ParameterValue="${subnet1}" \
    ParameterKey=Subnet2,ParameterValue="${subnet2}" \
    ParameterKey=IdentityUserName,ParameterValue="${studio_user_to_map}" \
    ParameterKey=IdentityUserType,ParameterValue="${studio_usertype_to_map}" \
  --region ${region} \
  --capabilities CAPABILITY_IAM
