### Parameters

########## Parameters (Start)

### VPC Parameters (start)
vpcstack="emr-eks-vpc" ## Name of the CloudFormation stack name for VPC creation
VpcCidr="172.20.0.0/16" ## CIDR for the VPC (new)
PrivateSubnet0Cidr="172.20.1.0/24" ## CIDR for the private subnet in first AZ
PrivateSubnet1Cidr="172.20.2.0/24" ## CIDR for the private subnet in second AZ
PublicSubnet0Cidr="172.20.3.0/24" ## CIDR for the public subnet in first AZ
PublicSubnet1Cidr="172.20.4.0/24" ## CIDR for the public subnet in second AZ

### VPC Parameters (end)

### EKS Cluster Parameters (start)
clustername="eks-emr-spark-cluster" ## EKS Cluster Name
version="1.18" ## EKS Version -- Do not use Version 1.19 at this moment.
managedNodeName="spark-nodes" ## EKS Managed Node Name
instanceType="m5.xlarge" ## EC2 Instance Type
volumeSize="30" ## Volume Size of EC2 EBS Vol
desiredCapacity="3" ## Desired capacity
maxPodsPerNode="10" ## Maximum number of Pods Per Node
pubkey="va-emr-1" ## Public Key for the EC2 instasnce
policyarn="arn:aws:iam::${accountid}:policy/s3-eks-spark-bucket"  ## Additional IAM Policy ARN to be added to the managed nodes

### EKS Cluster Parameters (end)

### Virtual EMR Cluster Parameters (start)
namespace="sparkns"
virtclustername="virt-emr-cluster" ## EKS Cluster Name
emr_release_label="emr-6.2.0-latest" ## EMR Release Label version
cf_virtclustername="cf-virt-emr-cluster"
### Virtual EMR Cluster Parameters (end)

### Virtual Managed Endpoint (start)
virtendpointname="virtual-emr-endpoint-demo"
### Virtual Managed Endpoint (end)

### IAM Roles and policies (start)
cf_iam_stackname="emr-eks-iam-stack" # CloudFormation Stack Name for IAM roles for Job Execution
cf_iam_alb_policy_stackname="emr-eks-aws-alb-policy-stack" # CloudFormation Stack Name for IAM policy for ALB Controller 

### IAM Roles and policies (end)

### Certificate Information (start)
certarn="arn:aws:acm:${region}:${accountid}:certificate/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" # ARN of the SSL/TLS cert to use from ACM
### Certificate Information (end)

### EMR Studio Parameters (start)
studio_name="emr-studio-1" # Name of the EMR Studio desired
cf_launch_studio_stackname="cf-emr-studio-1" # CloudFormation Stack name that launches EMR Studio
studio_auth_mode="SSO" # The type of Authentication for EMR Studio -- keep it as SSO for this example
cf_studio_sg_stackname="emr-studio-securitygroup" # CloudFormation Stack Name for Security groups for EMR Studio
cf_studio_role_service_stackname="emr-studio-service-role" # CloudFormation Stack Name for Service IAM Role for EMR Studio
cf_studio_role_user_stackname="emr-studio-user-role" # CloudFormation Stack Name for User IAM Role for EMR Studio
cf_studio_policy_user_stackname="emr-studio-user-policy" # CloudFormation Stack Name for User IAM Policy for EMR Studio
studio_default_s3_location_bucket="< BUCKET NAME >" # S3 bucket must be in the same region
studio_default_s3_location="s3://${studio_default_s3_location_bucket}/studio/"
studio_usertype_to_map="USER" # Type -- USER | GROUP
studio_user_to_map="< USER NAME >" # Name of the user in your SSO set up that will be associated with the EMR Studio
### EMR Studio Parameters (end)


########## Parameters (End)
