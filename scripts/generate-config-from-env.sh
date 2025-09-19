#!/bin/bash

# Generate temporary global-config.yaml from .env ARGO_ variables
# Converts ARGO_SNAKE_CASE to camelCase and removes ARGO_ prefix

set -euo pipefail

# Function to convert snake_case to camelCase
snake_to_camel() {
  local snake_case="$1"
  # Convert to lowercase first, then capitalize each word after underscore
  echo "$snake_case" | awk -F_ '{
    for (i=1; i<=NF; i++) {
      if (i==1) {
        printf "%s", tolower($i)
      } else {
        printf "%s", toupper(substr($i,1,1)) tolower(substr($i,2))
      }
    }
  }'
}

# Check if .env exists
if [ ! -f ".env" ]; then
  echo "Error: .env file not found" >&2
  exit 1
fi

# Output file
OUTPUT_FILE="global-config.yaml"

echo "Generating global-config.yaml from .env..."

# Start YAML with header
cat > "$OUTPUT_FILE" << EOF
# Global configuration values for all applications
# This file is generated from .env - DO NOT EDIT MANUALLY
# Last updated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

EOF

# Process only ARGO_ prefixed variables from .env
while IFS='=' read -r key value; do
  # Skip empty lines and comments
  [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
  
  # Only process ARGO_ prefixed variables
  if [[ "$key" =~ ^ARGO_ ]]; then
    # Remove ARGO_ prefix and convert to lowercase
    var_name="${key#ARGO_}"
    var_name=$(echo "$var_name" | tr '[:upper:]' '[:lower:]')
    
    # Convert snake_case to camelCase
    camel_name=$(snake_to_camel "$var_name")
    
    # Remove quotes from value if present
    value="${value%\"}"
    value="${value#\"}"
    
    # Write to YAML
    echo "${camel_name}: ${value}" >> "$OUTPUT_FILE"
  fi
done < .env

echo "Generated $OUTPUT_FILE"

# Also create a temp copy for terraform compatibility
cp "$OUTPUT_FILE" ".global-config.yaml.tmp"