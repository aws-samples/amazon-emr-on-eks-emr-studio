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

# Fill out the variables in ./parameters.sh to match your desired environment
```
### Deploy Script
Before running the script, have the AWS account id available and the region. 

```
# Launch the script
$ bash ./deploy_eks_cluster_bash.sh '<Account ID>' '<region>'

...
## Once the script is completed, you will see a line that looks like this:

Go to https://***. emrstudio-prod.us-east-1.amazonaws.com and login using < SSO user > ...


```


## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

