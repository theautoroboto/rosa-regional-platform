#!/bin/bash
set -e

# 1. Define your stacks and their folder paths
declare -A STACKS
STACKS=( 
    ["vpc"]="infrastructure/vpc"
    ["database"]="infrastructure/rds"
    ["app"]="application/backend"
)

# 2. Get the list of changed files
# Note: In CodeBuild, we usually compare HEAD against the previous commit.
# We use || true to prevent failure if it's the very first commit.
CHANGED_FILES=$(git diff --name-only HEAD^ HEAD || echo "")

echo "--- Dectecting Changes ---"
echo "Changed files:"
echo "$CHANGED_FILES"
echo "--------------------------"

# 3. Loop through stacks and check for matches
for stack_name in "${!STACKS[@]}"; do
    folder_path=${STACKS[$stack_name]}
    
    # Check if any changed file starts with the folder path
    if echo "$CHANGED_FILES" | grep -q "^$folder_path"; then
        echo "✅ Changes detected in $stack_name. Marking for deployment."
        # Export a variable named DO_DEPLOY_<STACK_NAME>
        echo "export DO_DEPLOY_${stack_name^^}=true" >> build_vars.env
    else
        echo "zzz No changes in $stack_name. Skipping."
        echo "export DO_DEPLOY_${stack_name^^}=false" >> build_vars.env
    fi
done