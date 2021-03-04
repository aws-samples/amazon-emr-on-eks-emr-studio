#!/bin/bash

### How to run this shell script and pass in the account ID parameter (start)
#
#  $ bash remove_setup.sh "< account id >" 
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

## Remove EMR Studio

studio_json=$(aws emr list-studios --region ${region} | jq .Studios)
studio_length=$(echo ${studio_json} | jq length)

studio_count=0

echo "Deleting EMR Studio..."
while [ ${studio_count} -lt ${studio_length} ]
do
  
  studio_id=$(aws emr list-studios \
    --region ${region} | jq .Studios[${studio_count}].StudioId | sed 's/"//g')
  echo ${studio_id}
  aws emr delete-studio --region ${region} --studio-id ${studio_id}
  studio_count=$((studio_count+1))

done

## Remove Managed Endpoints

vc_json=$(aws emr-containers list-virtual-clusters \
  --region ${region} | jq .virtualClusters) 
vc_length=$(echo ${vc_json} | jq length)

vc_count=0

echo "Deleting Managed Endpoints and Virtual clusters"

while [ ${vc_count} -lt ${vc_length} ]
do
  id=$(echo ${vc_json} | jq .[${vc_count}].id | sed 's/"//g')
  state=$(echo ${vc_json} | jq .[${vc_count}].state | sed 's/"//g')
  name=$(echo ${vc_json} | jq .[${vc_count}].name | sed 's/"//g')
  echo "Virtual cluster ${name} | ${id} is currently in ${state} state."

  if [ "${state}" != "TERMINATED" ]; then
    echo "Removing managed endpoints in Virtual Cluster ${name} | ${id} "

    ## List managed endpoints in this cluster

    ep_json=$(aws emr-containers list-managed-endpoints \
      --region ${region} \
      --virtual-cluster-id ${id} | jq .endpoints)
    ep_length=$(echo ${ep_json} | jq length)

    ep_count=0

    while [ ${ep_count} -lt ${ep_length} ]
    do
      epid=$(echo ${ep_json} | jq .[${ep_count}].id | sed 's/"//g')
      name=$(echo ${ep_json} | jq .[${ep_count}].name | sed 's/"//g')
      state=$(echo ${ep_json} | jq .[${ep_count}].state | sed 's/"//g')
      echo "Endpoint ${epid} | ${name} is in ${state} state"

      if [ "${state}" == "ACTIVE" ]; then
        echo "Endpoint ${epid} | ${name} will be terminated..."
        
        aws emr-containers delete-managed-endpoint \
          --id ${epid} \
          --virtual-cluster-id ${id}
        
        newstatus=$(aws emr-containers describe-managed-endpoint \
          --id ${epid} \
          --virtual-cluster-id ${id} | jq .endpoint.state | sed 's/"//g')

        echo "Endpoint ${epid} | ${name} is in ${newstatus} state."
      else
        echo "Endpoint ${epid} | ${name} is already terminated..."
      fi

      ep_count=$((ep_count+1))
    done

    ## Delete Virtual Cluster

    aws emr-containers delete-virtual-cluster \
      --region ${region} \
      --id ${id}

    newstatus=$(aws emr-containers describe-virtual-cluster --id xzhwukhzhicl1mqaf08kafq7t --region $region | jq .virtualCluster.state | sed 's/"//g')

    echo "Virtual cluster ${id} | ${name} is in ${newstatus} state."

  else
      echo "Ignoring this Virtual Cluster: ${name} | ${id} as it is already in ${state} state."
  fi

  vc_count=$((vc_count+1))
done

## Remove Studio User Policy

aws cloudformation delete-stack --stack-name ${cf_studio_policy_user_stackname}

## Remove Studio User Role

aws cloudformation delete-stack --stack-name ${cf_studio_role_user_stackname}

## Remove Studio Service Role

aws cloudformation delete-stack --stack-name ${cf_studio_role_service_stackname}

## Remove Studio Security Group

aws cloudformation delete-stack --stack-name ${cf_studio_sg_stackname}

## Remove EKS IAM Service Account

eksctl delete iamserviceaccount \
  --cluster=${clustername} \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --region ${region}

## Remove EKS ALB IAM Policy 
aws cloudformation delete-stack --stack-name ${cf_iam_alb_policy_stackname}

## Remove IAM Role for Job Execution
aws cloudformation delete-stack --stack-name ${cf_iam_stackname}

## Remove EKS Cluster

# Delete Node Group
eksctl delete nodegroup \
  --name ${managedNodeName} \
  --cluster ${clustername} \
  --region ${region}

delete_status="DELETE_IN_PROGRESS"
while [[ "${delete_status}" == "DELETE_IN_PROGRESS" ]]
do
  delete_status=$(eksctl get nodegroup \
    --name ${managedNodeName} \
    --cluster ${clustername} \
    --region ${region} \
    --output json | jq .[].Status | sed 's/"//g')
  echo "Status: ${delete_status}..."
  sleep 15
done

# Delete EKS Cluster
eksctl delete cluster --name ${clustername} --region ${region}

delete_status="DELETING"
while [[ "${delete_status}" == "DELETING" ]]
do
  delete_status=$(eksctl get cluster \
    --name ${clustername} \
    --region ${region} \
    --output json | jq .[].Status | sed 's/"//g')
  echo "Status: ${delete_status}..."
  sleep 15
done

## Delete VPC

aws cloudformation delete-stack --stack-name ${vpcstack}


echo "All resources have been deleted."
