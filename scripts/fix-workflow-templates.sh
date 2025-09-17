#!/bin/bash
# Fix workflow template references to use ClusterWorkflowTemplates
# This script adds clusterScope: true to all templateRef sections

set -e

# Find all workflow files that use templateRef
echo "Finding workflows that use templateRef..."
workflows=$(grep -r "templateRef:" manifests/ --include="workflow-*.yaml" -l | grep -v "/charts/" | sort -u)

for workflow in $workflows; do
    echo "Processing: $workflow"
    
    # Check if file already has clusterScope
    if grep -q "clusterScope: true" "$workflow" 2>/dev/null; then
        echo "  ✓ Already has clusterScope references"
        continue
    fi
    
    # Create a temporary file
    temp_file=$(mktemp)
    
    # Process the file line by line
    in_template_ref=false
    while IFS= read -r line; do
        echo "$line" >> "$temp_file"
        
        # Check if we're starting a templateRef block
        if [[ "$line" =~ ^[[:space:]]*templateRef:[[:space:]]*$ ]]; then
            in_template_ref=true
        # Check if we're at the template: line within a templateRef block
        elif [[ "$in_template_ref" == true ]] && [[ "$line" =~ ^[[:space:]]*template:[[:space:]] ]]; then
            # Add clusterScope: true with proper indentation
            # Extract indentation from the template line
            indent=$(echo "$line" | sed 's/\(^[[:space:]]*\).*/\1/')
            echo "${indent}clusterScope: true" >> "$temp_file"
            in_template_ref=false
        # Reset if we hit a non-indented line (new section)
        elif [[ "$line" =~ ^[^[:space:]] ]]; then
            in_template_ref=false
        fi
    done < "$workflow"
    
    # Replace the original file
    mv "$temp_file" "$workflow"
    echo "  ✓ Added clusterScope to templateRef sections"
done

echo "✅ Workflow template references fixed!"