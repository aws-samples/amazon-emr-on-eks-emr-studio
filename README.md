# Installing EMR on EKS with Managed Endpoint and EMR Studio


## Introduction
Amazon EMR on EKS provides a deployment option for Amazon EMR that allows you to run analytics workloads on Amazon Elastic Kubernetes Service (EKS). This is an attractive option as it permits running applications on a common pool of resources without having to provision infrastructure. In addition, you can use Amazon EMR Studio to build analytics code running on EKS clusters. EMR Studio is a web-based, integrated development environment (IDE) using fully managed Jupyter notebooks that can be attached to any EMR cluster including EMR on EKS. It uses AWS Single Sign-On (SSO) to log directly to EMR Studio through a secure URL using corporate credentials.

## Setting up EMR on EKS and EMR Studio
There are several steps and pieces required to set up both EMR on EKS and EMR Studio. The general steps are as follows, if there are no existing appropriate VPC and an EKS cluster:
- Enable AWS SSO in the region where the EMR Studio will reside
- Set up a VPC that also has private subnets and appropriately tagged for external load balancers
- Launch an EKS Cluster with at least one (1) Managed Node Group
- Create an Identity Provider (IdP) in IAM based on the EKS OIDC provider URL
- Create the relevant IAM policies and roles:
1. Job Execution role
2. IAM policy for the AWS Load Balancer controller
3. EMR Studio Service Role
4. EMR Studio User Role
5. EMR Studio User Policies associated with SSO users and groups
- Create the appropriate Security Groups to be attached to each EMR Studio created:
1. Workspace security group
2. Engine security group
- Deploy the AWS Load Balancer Controller in the EKS cluster
- Create at least one (1) EMR Virtual Cluster associated with the EKS cluster
- Create at least one (1) Managed Endpoint and associated, if necessary, an unique configuration
- Create at least one (1) EMR Studio with at least one (1) of the private subnets that exists with the Managed Node Group in the EKS cluster
- Map the SSO users and groups to the appropriate EMR Studio created above

## Launch Script
The scripts provided here are designed as a prescriptive architecture that helps you launch an end-to-end solution with a new VPC, EKS cluster, and all the necessary IAM roles and policies. What is left out here are:

- A configured SSO set up in a supported region
- A SSL/TLS certificate available in ACM
- An IAM policy specific to resources of the user
- A S3 bucket for storage of EMR Studio content

These can and will be configured in the parameters.sh file included here.

## Pre-Requisites

The script requires using AWS Cloud9. Follow the instructions listed out in the [EKS Workshop](https://www.eksworkshop.com/020_prerequisites/workspace/). Once the Cloud9 desktop is deployed, follow the steps outlined here below.

### Preparation
```
# Download script from the repository
$ git clone https://github.com/aws-samples/amazon-emr-on-eks-emr-studio.git

# Prepare the Cloud9 Desktop pre-requisites
$ cd eks_emr_studio
$ bash ./prepare_cloud9.sh

# Modify the variables in ./parameters.sh to match your desired environment and names
```
### Deploy Script
Before running the script, have the AWS account id available and the region if you are deploying in an environemnt that is the same as your EKS cluster. 

```
# Launch the script; fill out the questions asked

$ bash ./deploy_eks_cluster_bash.sh

## If you want to run your Spark executors in Fargate, run the alternative deployment script

$ bash ./deploy_eks_cluster_fargate_bash.sh

...
## Once the script is completed, you will see a line that looks like this:

Go to https://***. emrstudio-prod.us-east-1.amazonaws.com and login using < SSO user > ...


```

### Cleaning up and removing the deployment entirely
To remove the entire deployment, follow the steps outlined below:

#### Remove the managed endpoint that was created by doing the following steps

1. Identify the virtual cluster id:

```
$ aws emr-containers list-virtual-clusters --region ${region} | jq .virtualClusters | jq '.[] | select(.state=="RUNNING")'
{
  "id": "abcd1efgh2ijklmn3opqr4st",
  "name": "virt-emr-cluster-demo",
  "arn": "arn:aws:emr-containers:us-east-1:123456789012:/virtualclusters/abcd1efgh2ijklmn3opqr4st",
  "state": "RUNNING",
```
2. Find the Managed endpoint ID:

```
$ aws emr-containers list-managed-endpoints --region ${region} --virtual-cluster-id abcd1efgh2ijklmn3opqr4st
    "endpoints": [
        {
            "id": "abcdefghijklm",
            "name": "virtual-emr-endpoint-demo",
            "arn": "arn:aws:emr-containers:us-east-1:123456789012:/virtualclusters/abcd1efgh2ijklmn3opqr4st/endpoints/abcdefghijklm",
            "virtualClusterId": "abcd1efgh2ijklmn3opqr4st",
            "type": "JUPYTER_ENTERPRISE_GATEWAY",
            "state": "ACTIVE",
```
3. Delete the Managed Endpoint

```
$ aws emr-containers delete-managed-endpoint --region ${region} --virtual-cluster-id abcd1efgh2ijklmn3opqr4st --id abcdefghijklm
{
    "id": "abcdefghijklm",
    "virtualClusterId": "abcd1efgh2ijklmn3opqr4st"
}
```
4. Check the managed endpoint has been deleted (it will take some time)

```
aws emr-containers describe-managed-endpoint --region ${region} --virtual-cluster-id abcd1efgh2ijklmn3opqr4st --id abcdefghijklm
{
    "endpoint": {
        "id": "abcdefghijklm",
        "name": "virtual-emr-endpoint-demo",
        "arn": "arn:aws:emr-containers:us-east-1:699130936416:/virtualclusters/abcd1efgh2ijklmn3opqr4st/endpoints/abcdefghijklm",
        "virtualClusterId": "abcd1efgh2ijklmn3opqr4st",
        "type": "JUPYTER_ENTERPRISE_GATEWAY",
        "state": "TERMINATED",
```
5. Delete the Virtual Cluster

```
$ aws emr-containers delete-virtual-cluster --region ${region} --id abcd1efgh2ijklmn3opqr4st
{
    "id": "abcd1efgh2ijklmn3opqr4st"
}
```

6. Delete the CloudFormation stacks and eksctl created cluster

```
$ source ./parameters.sh

$ aws cloudformation delete-stack --stack-name ${cf_launch_studio_stackname} --region ${region}

$ aws cloudformation delete-stack \
  --stack-name ${cf_virtclustername} \
  --region ${region}

$ aws cloudformation delete-stack \
  --stack-name eksctl-${clustername}-addon-iamserviceaccount-kube-system-aws-load-balancer-controller \
  --region ${region}

$ aws cloudformation delete-stack \
  --stack-name ${cf_iam_alb_policy_stackname} \
  --region ${region}

$ aws cloudformation delete-stack \
  --stack-name ${cf_iam_stackname} \
  --region ${region}

$ eksctl delete cluster -f temp/eks_cluster_spark_deployment.yaml 

$ aws cloudformation delete-stack \
  --stack-name ${vpcstack} \
  --region ${region}

$ aws cloudformation delete-stack \
  --stack-name ${cf_iam_s3bucket_policy} \
  --region ${region}

```
6. Remove the S3 bucket created

```
$ aws s3 rm --recursive s3://tanmatth-emr-eks-studio-demo/ \
  --region ${region}

$ aws s3 rb  s3://tanmatth-emr-eks-studio-demo/ \
  --region ${region}
```

7. Remove the Certificate

```
$ certarnjson=$(aws acm list-certificates \
  --region ${region} | jq .CertificateSummaryList | jq ".[] | select (.DomainName==\"${certdomain}\")") 
 
$ certarn=$(echo $certarnjson | jq .CertificateArn | sed 's/"//g')

$ aws acm delete-certificate \
  --certificate-arn $certarn \
  --region $region
```

