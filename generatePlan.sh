#!/bin/bash

echo "Initializing Terraform..."
terraform init

#  Create dummy zip if not exists
ZIP_FILE="lambda_function_payload.zip"
if [ ! -f "$ZIP_FILE" ]; then
  echo "📦 Creating dummy Lambda zip file..."
  echo "dummy" > dummy.txt
  zip $ZIP_FILE dummy.txt > /dev/null
  rm dummy.txt
fi

echo "Generating Terraform plan..."
terraform plan -out=plan.out

echo "Exporting Terraform plan to JSON..."
terraform show -json plan.out > plan.json

echo "Done!"
