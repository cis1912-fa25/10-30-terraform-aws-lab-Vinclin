[![Review Assignment Due Date](https://classroom.github.com/assets/deadline-readme-button-22041afd0340ce965d47ae6ef1cefeee28c7c493a6346c4f15d667ab976d596c.svg)](https://classroom.github.com/a/ZoxUVHrL)
# Infrastructure as Code with Terraform

In the last lab, you deployed a web application to AWS EC2 by clicking through the console, manually creating security groups, downloading key pairs, and SSHing into instances. It worked - you got a running web server accessible to the internet. But imagine you need to do this 10 more times for different environments (development, staging, production). Or imagine you need to tear everything down and recreate it exactly the same way next week. How confident are you that you'd remember every setting, every security rule, every configuration choice?

This is where **Infrastructure as Code (IaC)** comes in. Instead of clicking buttons and running ad-hoc CLI commands, you write declarative configuration files that describe your desired infrastructure state. Tools like Terraform read these files and make API calls to create, update, or destroy resources to match your specification. This gives you version control, reproducibility, automation, and documentation all in one.

In this lab, we'll deploy a containerized web application using Terraform. We'll package our application in a Docker image, push it to Amazon ECR (Elastic Container Registry), and provision EC2 instances that pull and run the container. This mirrors how you'd deploy to Kubernetes: build once, deploy anywhere. By the end, you'll see how infrastructure becomes code you can read, review, version, and reuse at scale.

## Setup

First, you'll need to make sure you've followed the setup in the previous lab. In particular, you'll need to have your AWS credentials set. There should be a file `~/.aws/credentials` that has something like:

```bash
[default]
aws_access_key_id = AKI...
aws_secret_access_key = <secret>
```

Next, install Terraform. Follow the [official installation guide](https://developer.hashicorp.com/terraform/install) for your operating system. Verify your installation:

```bash
terraform --version
```

You should see output like `Terraform v1.x.x`.

## Understanding Terraform

Before we write any code, let's review how Terraform works.

**Terraform** is a declarative IaC tool. You describe *what* infrastructure you want (not *how* to create it), and Terraform figures out the necessary API calls to make it happen. It's cloud-agnostic - the same concepts work with AWS, GCP, Azure, etc.

### Terraform Workflow

```text
1. Write .tf configuration files
2. terraform init     → Download provider plugins
3. terraform plan     → Preview what will change
4. terraform apply    → Execute the changes
5. terraform destroy  → Clean up when done
```

The beauty of this workflow is that **it's idempotent**. Run `terraform apply` ten times on the same configuration, and you'll get the same infrastructure state.

## Project Setup

Now, let's take a look at the provided code. `main.py` has the code for the `fastapi` app we used last lab. It's now a simple `uv` project that has a Dockerfile. The goal here is to deploy our application using Terraform. First, let's create a directory for Terraform:

```bash
mkdir terraform
cd terraform
```

Add a new file here `main.tf`:

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}
```

Terraform configuration is written in **HCL** (HashiCorp Configuration Language), a declarative language designed for infrastructure.
The `main.tf` file we've defined tells Terraform:

- We need the AWS provider (version 5.x)
- Use the `us-east-1` region
- Credentials come from `~/.aws/credentials` (implicit default)

Now, let's initialize Terraform to download the AWS provider:

```bash
terraform init
```

You should see output confirming the provider was installed. Take a look at your `terraform/` directory - Terraform created `.terraform/` and `.terraform.lock.hcl` to track provider versions.

Before we proceed further, let's create a variable in `variables.tf` for your pennkey. We'll use this to add your pennkey to any resources we create easily.

```hcl
variable "pennkey" {
  type = string
  default = "davidcao"
}
```

### Step 2: Create an ECR Repository

Before we can deploy our infrastructure, we need to be able to build and push the Docker image to Amazon ECR (Elastic Container Registry). ECR is AWS's container registry service - like Docker Hub, but integrated with AWS. Let's create the ECR repository first, add this to `main.tf`:

```hcl
# Get current AWS account ID
data "aws_caller_identity" "current" {}

# Create ECR repository for our Docker image
resource "aws_ecr_repository" "webapp" {
  name                 = "terraform-webapp-${var.pennkey}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "terraform-webapp-${var.pennkey}"
  }
}

# Output the ECR repository URL
output "ecr_repository_url" {
  description = "ECR repository URL for Docker images"
  value       = aws_ecr_repository.webapp.repository_url
}
```

This creates a private container registry where we'll push our Docker image. The `scan_on_push` feature automatically scans images for vulnerabilities. Let's create this ECR repository, but first let's take a look at the plan Terraform will execute:

```bash
terraform plan
```

You should see output that has the ECR resource to be created along with

```
Plan: 1 to add, 0 to change, 0 to destroy.
```

This plan looks good, so let's go ahead and let Terraform actually create this!

```bash
terraform apply
```

You'll see the output of the same plan before, type "yes" to apply the change. You should see output like:

```bash
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:

ecr_repository_url = "12345689012.dkr.ecr.us-east-1.amazonaws.com/terraform-webapp-<pennkey>"
```

The ECR repository has been created! You can view this in the console if you'd like by navigating to the ECR page.

### Step 3: Creating an EC2 Instance

If you recall, we needed a handful of things to create our EC2 instance last week. Specifically, we needed a
*security group* that acted as a firewall to allow HTTP and SSH traffic, an AMI image to start the instance with, and a key pair to be able to SSH into the machine.
We'll need one more thing for this lab, since the EC2 instance will be running Docker, it needs to pull the image from ECR. To do this, it needs permissions, which
we can grant it by providing it an IAM user.

First, let's add the security group to `main.tf`:

```hcl
resource "aws_security_group" "web_server" {
  name        = "terraform-web-server-sg-${var.pennkey}"
  description = "Security group for web server - allows SSH and HTTP"

  # Allow SSH from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  # Allow HTTP from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP access"
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "terraform-web-server-sg-${var.pennkey}"
  }
}
```

Note that this is more expressive than the view we had when creating a security group in the AWS EC2 create page, particularly we can express arbitrary *ingress* and *egress* traffic rules. Let's add the key pair to SSH with next. First, let's generate one:

```bash
# Generate a new SSH key pair locally
ssh-keygen -t rsa -b 2048 -f ~/.ssh/terraform-aws-key -N ""
```

This creates:

- `~/.ssh/terraform-aws-key` (private key)
- `~/.ssh/terraform-aws-key.pub` (public key)

Now add the key pair resource to `main.tf`:

```js
resource "aws_key_pair" "deployer" {
  key_name   = "terraform-deployer-key-${var.pennkey}"
  public_key = file("~/.ssh/terraform-aws-key.pub")
}
```

This uploads the public key to AWS, which will allow us to SSH into machines that use this key pair.

Now, let's pick an AMI to use. Hardcoding an AMI ID is an ok approach, but we can use a *data source* to always reference the latest
Amazon Linux 2023 AMI. Add to `main.tf`:

```hcl
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
```

Finally, let's create an IAM role for the EC2 instances to be able to pull images from ECR. Add this to `main.tf`:

```hcl
# IAM role for EC2 instances to pull from ECR
resource "aws_iam_role" "ec2_ecr_role" {
  name = "terraform-ec2-ecr-role-${var.pennkey}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "terraform-ec2-ecr-role-${var.pennkey}"
  }
}

# Attach policy to allow ECR access
resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.ec2_ecr_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Create instance profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "terraform-ec2-profile-${var.pennkey}"
  role = aws_iam_role.ec2_ecr_role.name
}
```

This will create an IAM role, then attach a policy to it to be able to read from ECR.

Now, we can finally define the EC2 instance that will run our Docker container. This will reference all of the previous pieces we added, add the following to `main.tf`:

```hcl
resource "aws_instance" "web_server" {
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = "t2.micro"
  key_name      = aws_key_pair.deployer.key_name

  vpc_security_group_ids = [aws_security_group.web_server.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  # Enable public IP
  associate_public_ip_address = true

  tags = {
    Name = "terraform-web-server-${var.pennkey}"
  }

  # Ensure ECR repository exists first
  depends_on = [aws_ecr_repository.webapp]
}

output "instance_public_ip" {
  description = "Public IP address of the web server"
  value       = aws_instance.web_server.public_ip
}

output "instance_url" {
  description = "URL to access the web server"
  value       = "http://${aws_instance.web_server.public_ip}"
}
```

Take a look at the values we set for `ami`, `key_name`, `vpc_security_group_ids`, and `iam_instance_profile`. These are all referencing the resources we defined above!

Go ahead and run `terraform plan` and `terraform apply`. After a minute or so, Terraform should finish creating everything! You'll see the outputs we defined printed out as well:

```bash
ecr_repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/terraform-webapp-<pennkey>"
instance_public_ip = "123.123.123.123"
instance_url = "http://123.123.123.123"
```

## Building and Pushing the Docker Image

Before we can run our actual webapp, we need to build and push the Docker image to ECR. Export the ECR URL we got from Terraform as an environment variable.
Note that Terraform provides a nice command line function for this:

```bash
export ECR_REPO=$(terraform output -raw ecr_repository_url)
echo $ECR_REPO
```

Now authenticate Docker to ECR:

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $ECR_REPO
```

You should see: `Login Succeeded`

Navigate back to the root of the project and build the Docker image (note that we need to pick the correct platform for Amazon Linux):

```bash
cd ..
docker build -t terraform-webapp . --platform=linux/amd64
```

Once complete, tag it for ECR:

```bash
docker tag terraform-webapp:latest $ECR_REPO
```

Push to ECR:

```bash
docker push '${ECR_REPO}:latest'
```

You'll see the layers being pushed. Once complete, verify it's in ECR:

```bash
aws ecr list-images --repository-name terraform-webapp-<pennkey>
```

Perfect! Your Docker image is now in a private registry, ready to be pulled by EC2 instances.

## Deploying the Webapp

Now let's actually deploy the webapp. SSH into the instance:

```bash
cd terraform/
ssh -i ~/.ssh/terraform-aws-key ec2-user@$(terraform output -raw instance_public_ip)
```

We'll need to do a few things before we can run the docker image:

1. We need to get the credentials for the IAM profile we made
2. Use these credentials to pull the docker image
3. Finally run the docker container

Thankfully, the Amazon Linux AMI has docker installed already, along with the AWS CLI. First, let's export our ECR URL as a variable:

```bash
export ecr_repository_url=<your ECR URL>
```

Then, run the following:

```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <PASTE_ECR_REPOSITORY_URL>
```

This will get the password for ECR from AWS (which is allowed since the EC2 instance has the correct IAM profile), then pipe it to authenticate docker against the ECR repository we created.
Now, we can pull the docker image and run it!

```bash
docker pull ${ecr_repository_url}:latest
docker run -d \
  --name webapp \
  --restart unless-stopped \
  -p 80:80 \
  ${ecr_repository_url}:latest
```

Check that Docker is running:

```bash
docker ps
```

You should see:

```
CONTAINER ID   IMAGE                                                        COMMAND                  CREATED         STATUS         PORTS                NAMES
abc123def456   123...ecr.us-east-1.amazonaws.com/terraform-webapp:latest   "uvicorn app:app --h…"   2 minutes ago   Up 2 minutes   0.0.0.0:80->80/tcp   webapp
```

Check the container logs:

```bash
docker logs webapp
```

You should see FastAPI startup logs. Exit the SSH session and verify you can view the webapp at the IP for you EC2 instance!

## Task: Leveraging user_data

Let's recap. We used terraform to easily manage and spin up exactly the resources we needed to get an EC2 instance running
our webapp in docker. However, we still had to manually SSH into the machine, get credentials, pull the image, and then finally run the container. This is rather unwieldy, and is infeasible for many many machines.

Thankfully, [Amazon has a feature on EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html) that allows you to run a script when the instance launches, which they call user data. [Terraform provides a `user_data` property](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance#user_data-1) on `aws_instance` that you can effectively use to set a start up script. However, you'll also need to pass in some variables such as the ECR repository URL, which shouldn't be hardcoded. Your goal is to implement the `user_data` for our `aws_instance` to automatically pull the docker image and run it.

1. Create a script `terraform/user_data.sh` that authenticates against ECR, pulls the relevant docker image, and runs it. It should use a variable for the ECR repository URL
2. Use [Terraform's `templatefile` function](https://developer.hashicorp.com/terraform/language/functions/templatefile) to inject the ECR URL variable
3. Set this as `user_data` for the `aws_instance`

If all goes well, on apply, you EC2 should restart and serve the webapp automatically!

## Further Reading

- [Terraform Modules Documentation](https://developer.hashicorp.com/terraform/language/modules)
- [AWS ECR User Guide](https://docs.aws.amazon.com/ecr/)
- [Terraform Count and For Each](https://developer.hashicorp.com/terraform/language/meta-arguments/count)
- [Docker Best Practices](https://docs.docker.com/develop/dev-best-practices/)
