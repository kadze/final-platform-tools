# DO NOT RELY ON STATE FILE FOR THE FILES IN THIS FOLDER
# TREAT THESE RESOURCES AS BEING CREATED MANUALLY AND STATE NOT BEING MANAGED IN TERRAFORM
# ALTERNATIVELY, YOU CAN JUST CREATE BUCKET MANUALLY IN AWS CONSOLE WITH DESIRED SETTINGS
resource "aws_s3_bucket" "statebucket" {
  bucket = "project-x-state-bucket-dev"

  tags = {
    Name        = "Terraform State bucket for Project X"
    Environment = "Dev"
  }
  versioning {
    enabled = true
  }
}

resource "aws_dynamodb_table" "basic-dynamodb-table" {
  name         = "terraformlock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = "dynamodb-lock-table"
    Environment = "dev"
  }
}