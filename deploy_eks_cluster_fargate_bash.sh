#!/bin/bash

### How to run this shell script (start)
#
#  $ bash deploy_eks_cluster_bash.sh 
#
### How to run this shell script (end)

### Instruction page before install

echo "Deployment Script -- EMR on EKS with EMR Studio"
echo "-----------------------------------------------"
echo ""
echo "Please provide the following information before deployment:"
echo "1. Region (If your Cloud9 desktop is in the same region as your deployment, you can leave this blank)"
echo "2. Account ID (If your Cloud9 desktop is running in the same Account ID as where your deployment will be, you can leave this blank)"
echo "3. Name of the S3 bucket to be created for the EMR Studio S3 storage location"
echo "4. Name of the SSO User that will be associated with the EMR Studio deployment"
echo ""
echo "*** Please make sure you have enabled AWS SSO and have a user available to be associated with the EMR Studio session"
echo ""

read -p "Have you enabled AWS SSO in the region you want to deploy this stack? (y/n) " get_sso_question
echo ""

if [ "$get_sso_question" != "y" ]
  then
    echo "Please enable AWS SSO before deploying this stack. Thank you."
    exit 0
fi

### Parameters

########## Parameters (Start)

### User provided parameters (start)
region=""  
accountid="" 
studio_default_s3_location_bucket=""
studio_user_to_map=""
### User provided parameters (end)

### Test for account ID parameter passed through else exit from script
accountid_=$(aws sts get-caller-identity | jq .Account | sed 's/"//g')
region_=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

# Get Region
read -p "Region: [$region_]: " get_region

# Get Account ID
read -p "Account ID [$accountid_]: " get_accountid

# EC2 Public Key
read -p "EC2 Public Key name: " get_pubkey

# Get Default S3 bucket
read -p "Default S3 bucket name for EMR Studio (do not add s3://): " get_studio_default_s3_location_bucket

# Get SSO User
read -p "SSO Username to use: " get_studio_user_to_map

if [ "$get_region" == "" ]
  then
    get_region=$region_
fi

if [ "$get_accountid" == "" ]
  then
    get_accountid=$accountid_
fi

accountid=$get_accountid
region=$get_region
pubkey=$get_pubkey
studio_default_s3_location_bucket=$get_studio_default_s3_location_bucket
studio_user_to_map=$get_studio_user_to_map

no_parameters_num=0

if [ -z "$pubkey" ]
  then
    no_parameters_num=$((no_parameters_num+1))
    pubkey="< MISSING >"
fi


if [ -z "$studio_default_s3_location_bucket" ]
  then
    no_parameters_num=$((no_parameters_num+1))
    studio_default_s3_location_bucket="< MISSING >"
fi

if [ -z "$studio_user_to_map" ]
  then
    no_parameters_num=$((no_parameters_num+1))
    studio_user_to_map="< MISSING >"
fi

#echo $no_parameters_num

if [ $no_parameters_num -gt 0 ]
  then
    echo "Insufficient parameters provided..."
    echo "Region: $region | Account ID: $accountid | EC2 Public Key: $pubkey | S3 Bucket: $studio_default_s3_location_bucket | SSO Username: $studio_user_to_map"
    exit 0
fi

# Test for presence of S3 bucket
#s3bucket=$(aws s3 ls s3://$studio_default_s3_location_bucket)

bucket_list=$(aws s3api list-buckets --query "Buckets[].Name")
bucket_size=$(echo $bucket_list | jq length)
bucket_counter=0
bucket_exist=0

while [ $bucket_counter -lt $bucket_size ]
do
  bucket_name=$(echo $bucket_list | jq ".[$bucket_counter]" | sed 's/"//g')
  
  if [ "$bucket_name" == "$studio_default_s3_location_bucket" ]
    then
      bucket_exist=1
      break
  fi
  
  bucket_counter=$((bucket_counter+1))

done


if [ $bucket_exist -eq 1 ]
  then
    echo ""
    echo "Bucket $studio_default_s3_location_bucket already exist in your account. Please use a different name."
    echo "Exit from deployment ..."
    exit 0
fi


bucket_to_use=""

nb=$(aws s3 mb s3://$studio_default_s3_location_bucket --region $region)
    
if [ -z $nb ]
  then
    echo "Bucket $studio_default_s3_location_bucket is not unique. Please retry with a unique S3 bucket name"
    echo "Exit from deployment ..."
    exit 0
fi
    
bucket_to_use=$(echo $nb | awk '{print $2}')

echo "Bucket created: $bucket_to_use ..."
    
echo "Deploying CloudFormation stack with the following parameters..."
echo "Region: $region | Account ID: $accountid | S3 Bucket: $studio_default_s3_location_bucket | SSO Username: $studio_user_to_map"

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

## Create IAM Policy for $studio_default_s3_location_bucket

aws cloudformation create-stack \
  --stack-name ${cf_iam_s3bucket_policy} \
  --template-body file://templates/s3-eks-policy.yaml \
  --parameters ParameterKey=StudioDefaultS3Bucket,ParameterValue="${studio_default_s3_location_bucket}" \
  --region ${region} \
  --capabilities CAPABILITY_IAM


# Check IAM policy create status before moving on
cf_stack_status ${cf_iam_s3bucket_policy}

s3eks_policyarn=$(aws cloudformation describe-stacks \
  --stack-name ${cf_iam_s3bucket_policy} | jq .Stacks | jq .[].Outputs | jq .[].OutputValue | sed 's/"//g')

echo "IAM Policy created for S3 bucket $studio_default_s3_location_bucket: $s3eks_policyarn ..."


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
    "namespace"
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
  "$s3eks_policyarn" 
  "$namespace"
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
    #echo $sedstr
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
tar -zxf helm/helm-v3.5.4-linux-amd64.tar.gz --directory ./temp/  
sudo mv temp/linux-amd64/helm /usr/local/bin/helm

helm repo add stable https://charts.helm.sh/stable

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

# Create Certificate for use in Managed Endpoint
#certdomain taken from parameters.sh
openssl req -x509 -newkey rsa:1024 \
  -keyout temp/privateKey.pem \
  -out temp/certificateChain.pem -days 365 -nodes \
  -subj "/C=US/ST=Washington/L=Seattle/O=MyOrg/OU=MyDept/CN=${certdomain}"

cp temp/certificateChain.pem temp/trustedCertificates.pem

certjson=$(aws acm import-certificate \
  --certificate fileb://temp/certificateChain.pem \
  --private-key fileb://temp/privateKey.pem \
  --certificate-chain fileb://temp/certificateChain.pem \
  --region ${region})

certarn=$(echo $certjson | jq .CertificateArn | sed 's/"//g')

echo "Certificate ARN: $certarn"
echo ""

# Create Managed Endpoint
echo "Creating Managed Endpoint"
echo "Using: "
echo "Virtual cluster id: ${virtclusterid}"
echo "Execution Role ARN: ${role_arn}"
echo "Release label: ${emr_release_label}"
echo "Certificate ARN: ${certarn}"
echo "Region: ${region}"



#read -p "Press enter to continue"

sleep 10

echo "Starting to create managed endpoint ..."
echo "Using the following command: "
echo "aws emr-containers create-managed-endpoint \
--type JUPYTER_ENTERPRISE_GATEWAY \
--virtual-cluster-id ${virtclusterid} \
--name ${virtendpointname} \
--execution-role-arn ${role_arn} \
--release-label ${emr_release_label} \
--certificate-arn ${certarn} \
--region ${region} \
--configuration-overrides '{
    \"applicationConfiguration\": [
      {
        \"classification\": \"spark-defaults\",
        \"properties\": {
          \"spark.hadoop.hive.metastore.client.factory.class\": \"com.amazonaws.glue.catalog.metastore.AWSGlueDataCatalogHiveClientFactory\",
          \"spark.sql.catalogImplementation\": \"hive\"
        }
      }
    ]
  }'"


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

cf_stack_status ${cf_launch_studio_stackname}

studio_json=$(aws cloudformation describe-stacks --stack-name ${cf_launch_studio_stackname} --region $region | jq .Stacks[].Outputs[] | jq 'select(.OutputKey=="EMRStudioId")')
emr_studio_id=$(echo $studio_json | jq .OutputValue | sed 's/"//g')

studio_info_json=$(aws emr describe-studio --region $region --studio-id $emr_studio_id)
studio_url=$(echo $studio_info_json | jq .Studio.Url | sed 's/"//g')

## Conclusion

echo "Go to ${studio_url} and login using ${studio_user_to_map} ..."
