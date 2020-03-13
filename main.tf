# ---------------------------------------------------------------------------------------------------------------------
# DEPLOY A CI/CD PIPELINE WITH CODECOMMIT USING AWS
# This module creates a CodePipeline with CodeBuild that is linked to a CodeCommit repository.
# Note: CodeCommit does not create a master branch initially. Once this script is run, you must clone the repo, and
# then push to origin master.
# ---------------------------------------------------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region
}

# Generate a unique label for naming resources
module "unique_label" {
  source     = "git::https://github.com/rakeshsinghtomar/terraform-null-label-master.git"
  namespace  = var.organization_name
  name       = var.repo_name
  stage      = var.environment
  delimiter  = var.char_delimiter
  attributes = []
  tags       = {}
}

# Create ECR repo
#resource "aws_ecr_repository" "foo" {
#  name                 = var.repo_name 
#  image_tag_mutability = "IMMUTABLE"
#  image_scanning_configuration {
#    scan_on_push = true
#  }
#}


# CodeCommit resources
resource "aws_codecommit_repository" "repo" {
  repository_name = var.repo_name
  description     = "${var.repo_name} repository."
  default_branch  = var.repo_default_branch
}

# CodePipeline resources
resource "aws_s3_bucket" "build_artifact_bucket" {
  bucket        = module.unique_label.id
  acl           = "private"
  force_destroy = var.force_artifact_destroy
}

data "aws_iam_policy_document" "codepipeline_assume_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codepipeline_role" {
  name               = "${module.unique_label.name}-codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume_policy.json
}

# CodePipeline policy needed to use CodeCommit and CodeBuild
data "template_file" "codepipeline_policy_template" {
  template = file("${path.module}/iam-policies/codepipeline.tpl")
  vars = {
    aws_kms_key     = aws_kms_key.artifact_encryption_key.arn
    artifact_bucket = aws_s3_bucket.build_artifact_bucket.arn
  }
}

resource "aws_iam_role_policy" "attach_codepipeline_policy" {
  name = "${module.unique_label.name}-codepipeline-policy"
  role = aws_iam_role.codepipeline_role.id

  policy = data.template_file.codepipeline_policy_template.rendered

}



resource "aws_iam_role" "codedeploy_service" {
  name = "${module.unique_label.name}-codedeploy-service-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "codedeploy.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

# attach AWS managed policy called AWSCodeDeployRole
# required for deployments which are to an EC2 compute platform
resource "aws_iam_role_policy_attachment" "codedeploy_service" {
  role       = "${aws_iam_role.codedeploy_service.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

# create a service role for ec2 
resource "aws_iam_role" "instance_profile" {
  name = "${module.unique_label.name}-codedeploy-instance-profile"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "ec2.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

# provide ec2 access to s3 bucket to download revision. This role is needed by the CodeDeploy agent on EC2 instances.
resource "aws_iam_role_policy_attachment" "instance_profile_codedeploy" {
  role       = "${aws_iam_role.instance_profile.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforAWSCodeDeploy"
}

resource "aws_iam_instance_profile" "main" {
  name = "codedeploy-instance-profile"
  role = "${aws_iam_role.instance_profile.name}"
}





# Encryption key for build artifacts
resource "aws_kms_key" "artifact_encryption_key" {
  description             = "artifact-encryption-key"
  deletion_window_in_days = 10
}

# CodeBuild IAM Permissions
data "template_file" "codepipeline_assume_role_policy_template" {
  template = file("${path.module}/iam-policies/codebuild_assume_role.tpl")
}

resource "aws_iam_role" "codebuild_assume_role" {
  name               = "${module.unique_label.name}-codebuild-role"
  assume_role_policy = data.template_file.codepipeline_assume_role_policy_template.rendered
}


data "template_file" "codebuild_policy_template" {
  template = file("${path.module}/iam-policies/codebuild.tpl")
  vars = {
    artifact_bucket         = aws_s3_bucket.build_artifact_bucket.arn
    aws_kms_key             = aws_kms_key.artifact_encryption_key.arn
    codebuild_project_build  = aws_codebuild_project.build_project.id
    codebuild_project_test = aws_codebuild_project.Unit_test.id
    codebuild_project_sonar  = aws_codebuild_project.Sonar_Check.id
    codebuild_project_artifact = aws_codebuild_project.Artifact.id
  }
}

resource "aws_iam_role_policy" "codebuild_policy" {
  name = "${module.unique_label.name}-codebuild-policy"
  role = aws_iam_role.codebuild_assume_role.id

  policy = data.template_file.codepipeline_policy_template.rendered
}

# CodeBuild Section for the Build stage
resource "aws_codebuild_project" "build_project" {
  name           = "${var.repo_name}-Build"
  description    = "The CodeBuild project for ${var.repo_name}"
  service_role   = aws_iam_role.codebuild_assume_role.arn
  build_timeout  = var.build_timeout
  encryption_key = aws_kms_key.artifact_encryption_key.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = var.build_compute_type
    image           = var.build_image
    type            = "LINUX_CONTAINER"
    privileged_mode = var.build_privileged_override
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = var.build_buildspec
  }
}

# CodeBuild Section for the Unit Test stage
resource "aws_codebuild_project" "Unit_test" {
  name           = "${var.repo_name}-Test"
  description    = "The CodeBuild project for ${var.repo_name}"
  service_role   = aws_iam_role.codebuild_assume_role.arn
  build_timeout  = var.build_timeout
  encryption_key = aws_kms_key.artifact_encryption_key.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = var.build_compute_type
    image           = var.build_image
    type            = "LINUX_CONTAINER"
    privileged_mode = var.build_privileged_override
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = var.unittest_buildspec
  }
}


# CodeBuild Section for the Sonar stage
resource "aws_codebuild_project" "Sonar_Check" {
  name           = "${var.repo_name}-Sonar"
  description    = "The CodeBuild project for ${var.repo_name}"
  service_role   = aws_iam_role.codebuild_assume_role.arn
  build_timeout  = var.build_timeout
  encryption_key = aws_kms_key.artifact_encryption_key.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = var.build_compute_type
    image           = var.build_image
    type            = "LINUX_CONTAINER"
    privileged_mode = var.build_privileged_override
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = var.sonar_buildspec
  }
}

# CodeBuild Section for the create JAR stage
resource "aws_codebuild_project" "Artifact" {
  name           = "${var.repo_name}-Package"
  description    = "The CodeBuild project for ${var.repo_name}"
  service_role   = aws_iam_role.codebuild_assume_role.arn
  build_timeout  = var.build_timeout
  encryption_key = aws_kms_key.artifact_encryption_key.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = var.build_compute_type
    image           = var.build_image
    type            = "LINUX_CONTAINER"
    privileged_mode = var.build_privileged_override
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = var.artifact_buildspec
  }
}

# CodeBuild Section for the target Infra EC2
resource "aws_codebuild_project" "Target" {
  name           = "${var.repo_name}-target"
  description    = "The CodeBuild project for ${var.repo_name}"
  service_role   = aws_iam_role.codebuild_assume_role.arn
  build_timeout  = var.build_timeout
  encryption_key = aws_kms_key.artifact_encryption_key.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = var.build_compute_type
    image           = var.build_image
    type            = "LINUX_CONTAINER"
    privileged_mode = var.build_privileged_override
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = var.target_buildspec
  }
}

# create a CodeDeploy application
resource "aws_codedeploy_app" "main" {
  name = var.repo_name
}

# create a deployment group
resource "aws_codedeploy_deployment_group" "main" {
  app_name              = "${aws_codedeploy_app.main.name}"
  deployment_group_name = "Sample_DepGroup"
  deployment_config_name = "CodeDeployDefault.OneAtATime"
  service_role_arn      = "${aws_iam_role.codedeploy_service.arn}"

  ec2_tag_set {
        ec2_tag_filter {
            key   = "Name"
            type  = "KEY_AND_VALUE"
            value = "Development"
        }
    }

  # trigger a rollback on deployment failure event
  auto_rollback_configuration {
    enabled = true
    events = [
      "DEPLOYMENT_FAILURE",
    ]
  }
}



# Full CodePipeline
resource "aws_codepipeline" "codepipeline" {
  name     = var.repo_name
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.build_artifact_bucket.bucket
    type     = "S3"

    encryption_key {
      id   = aws_kms_key.artifact_encryption_key.arn
      type = "KMS"
    }
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["sourceArtifacts"]

      configuration = {
        RepositoryName = var.repo_name
        BranchName     = var.repo_default_branch
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["sourceArtifacts"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.build_project.name
      }
    }
  }

stage {
    name = "Unit_Test"

    action {
      name             = "Test"
      category         = "Test"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["sourceArtifacts"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.Unit_test.name
      }
    }
  }

  stage {
    name = "Sonar_Check"

    action {
      name             = "Sonar"
      category         = "Test"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["sourceArtifacts"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.Sonar_Check.name
      }
    }
  }

  stage {
    name = "Package"

    action {
      name             = "Package"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["sourceArtifacts"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.Artifact.name
      }
    }
  }
  stage {
    name = "target_EC2_Provison"

    action {
      name             = "target_ec2"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["sourceArtifacts"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.Target.name
      }
    }
  }

 stage {
     name = "Deploy"

     action {
      name             = "Deploy"
      category         = "Deploy"
      owner            = "AWS"
      provider         = "CodeDeploy"
      input_artifacts  = ["sourceArtifacts"]
      version          = "1"
      configuration  = {
       ApplicationName   = aws_codedeploy_app.main.name
       DeploymentGroupName            = aws_codedeploy_deployment_group.main.deployment_group_name
      }


    }
  }
}

