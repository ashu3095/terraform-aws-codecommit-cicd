# terraform-aws-cicd
Terraform module that provsion a new AWS CodeCommit repository Codebuilds and Codedeploy projects and integrated with AWS CodePipeline. The CodePipeline consists of multiple stages:

1. Source stage that is fed by the repository.
2. Build stage to check and complie the sourcecode.
3. Unit_Test stage to run the Junit test cases for the application.
4. Sonar_Check stage to run the static code analysis for the application code.
5. Package stage to create the artifact for the application after all above steps.
6. target_EC2_Provison stage is to provision the target Dev envirnment for deployment of application.
7. Deploy stage is deploy the artifact on target envirnment.


## Usage
```hcl
module "codecommit-cicd" {
    source                 = "git::https://github.com/rakeshsinghtomar/terraform-aws-codecommit-cicd.git?ref=master"
    repo_name              = "repo_name_details"
    organization_name      = "org_name"
    repo_default_branch    = "master/dev"
    aws_region             = "us-east-1"
    char_delimiter         = "-"
    environment            = "dev"
    build_timeout          = "5"
    build_compute_type     = "BUILD_GENERAL1_SMALL"
    build_image            = "aws/codebuild/standard:2.0"
    build_buildspec        = "buildspec_build.yml"
    unittest_buildspec     = "buildspec_test.yml"
    sonar_buildspec        = "buildspec_sonar.yml"
    artifact_buildspec     = "buildspec_artifact.yml"
    target_buildspec       = "buildspec_tf.yml"
    force_artifact_destroy = "false"
}
```

### CodeCommit Note
New repositories are **not** created with their default branch. Therefore, once the module has ran you must clone the repository, add a file, and then push to `origin/<repo_default_branch>` to initialize the repository.

Your command line execution might look something like this:

```bash
$>terraform apply
$>git clone https://git-codecommit.us-east-1.amazonaws.com/v1/repos/new-appname-repo
$>cd repo_name
$>echo 'hello world' > touch.txt
$>git commit -a -m 'init master'
$>git push -u origin master
```
