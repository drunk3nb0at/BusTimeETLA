###########################
# PROVIDERS & VARIABLES
###########################

provider "aws" {
  access_key = "mock_access"
  secret_key = "mock_secret"
  region     = "us-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}


variable "project_name" {
  default = "etla-pipeline"
}

###########################
# S3 BUCKET FOR RAW DATA
###########################
resource "aws_s3_bucket" "raw_data" {
  bucket = "${var.project_name}-raw"
  force_destroy = true

  tags = {
    Name = "Raw Data Bucket"
    Project = var.project_name
  }
}

###########################
# DYNAMODB FOR TRANSFORMED DATA
###########################
resource "aws_dynamodb_table" "bus_data" {
  name           = "${var.project_name}-bus-events"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "RouteNumber"
  range_key      = "OccurredOn"

  attribute {
    name = "RouteNumber"
    type = "S"
  }

  attribute {
    name = "OccurredOn"
    type = "S"
  }

  tags = {
    Name = "Transformed Bus Events"
    Project = var.project_name
  }
}

###########################
# COGNITO USER POOL
###########################
resource "aws_cognito_user_pool" "auth_pool" {
  name = "${var.project_name}-user-pool"
}

resource "aws_cognito_user_pool_client" "auth_client" {
  name         = "${var.project_name}-app-client"
  user_pool_id = aws_cognito_user_pool.auth_pool.id
  generate_secret = false
  allowed_oauth_flows_user_pool_client = true
  explicit_auth_flows = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
}

resource "aws_apigatewayv2_authorizer" "cognito_auth" {
  api_id          = aws_apigatewayv2_api.http_api.id
  authorizer_type = "JWT"
  identity_sources = ["$request.header.Authorization"]

  name = "${var.project_name}-cognito-auth"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.auth_client.id]
    issuer   = "https://${aws_cognito_user_pool.auth_pool.endpoint}" 
  }
}

resource "aws_apigatewayv2_route" "default_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /bus-event"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
  authorizer_id = aws_apigatewayv2_authorizer.cognito_auth.id
  authorization_type = "JWT"
}

###########################
# IAM ROLE FOR LAMBDA
###########################
resource "aws_iam_role" "lambda_exec" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Principal = {
        Service = "lambda.amazonaws.com"
      },
      Effect = "Allow",
      Sid    = ""
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = ["s3:PutObject"],
        Resource = ["${aws_s3_bucket.raw_data.arn}/*"],
        Effect   = "Allow"
      },
      {
        Action = ["dynamodb:PutItem"],
        Resource = [aws_dynamodb_table.bus_data.arn],
        Effect   = "Allow"
      },
      {
        Action = ["cloudwatch:PutMetricData"],
        Resource = ["*"],
        Effect   = "Allow"
      },
      {
        Action = ["sns:Publish"],
        Resource = ["*"],
        Effect   = "Allow"
      }
    ]
  })
}

resource "aws_iam_policy_attachment" "lambda_custom_policy" {
  name       = "lambda-custom-policy-attachment"
  roles      = [aws_iam_role.lambda_exec.name]
  policy_arn = aws_iam_policy.lambda_policy.arn
}

###########################
# LAMBDA FUNCTION
###########################
resource "aws_lambda_function" "bus_event_handler" {
  function_name = "${var.project_name}-handler"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "main.handler"
  runtime       = "python3.11"
  timeout       = 10

  filename         = "lambda_function_payload.zip"
  source_code_hash = filebase64sha256("lambda_function_payload.zip")

  environment {
    variables = {
      RAW_BUCKET_NAME = aws_s3_bucket.raw_data.bucket
      TABLE_NAME      = aws_dynamodb_table.bus_data.name
      METRIC_NAMESPACE = "ETLA"
    }
  }

  tags = {
    Project = var.project_name
  }
}

###########################
# API GATEWAY
###########################
resource "aws_apigatewayv2_api" "http_api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id             = aws_apigatewayv2_api.http_api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.bus_event_handler.invoke_arn
  integration_method = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bus_event_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

###########################
# CLOUDWATCH METRICS & ALARMS
###########################
resource "aws_cloudwatch_metric_alarm" "high_priority_alerts" {
  alarm_name          = "HighPriorityAlertThreshold"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "HighPriorityAlerts"
  namespace           = "ETLA"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  alarm_description   = "Triggers if more than 3 high priority alerts are processed in 5 minutes"

  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_error_alarm" {
  alarm_name          = "LambdaErrorThreshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Triggers if any Lambda errors occur"

  dimensions = {
    FunctionName = aws_lambda_function.bus_event_handler.function_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}
