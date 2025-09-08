#!/bin/bash

# Find all unreferenced YAML files in directories with kustomization.yaml

echo "=== Finding unreferenced YAML files ==="
echo

# Store results in temp files
safe_file=$(mktemp)
review_file=$(mktemp)

# Find all kustomization.yaml files
find manifests -name "kustomization.yaml" -type f | while read kustomization; do
    dir=$(dirname "$kustomization")
    
    # Get all YAML files in the directory
    find "$dir" -maxdepth 1 -name "*.yaml" -o -name "*.yml" | while read yaml_file; do
        [ "$yaml_file" = "$kustomization" ] && continue
        
        filename=$(basename "$yaml_file")
        
        # Skip app.yaml files (ArgoCD applications)
        if [ "$filename" = "app.yaml" ]; then
            continue
        fi
        
        # Check if file is referenced in kustomization.yaml
        if ! grep -qE "^\s*-\s*${filename}(\s|$)" "$kustomization" 2>/dev/null; then
            # Categorize the file
            if echo "$filename" | grep -qE "(job-|job\.yaml|-job\.yaml|postgres-setup|vault-secrets-init|authelia-db-|fix-pool-size|init-databases-job|create-app-db)"; then
                echo "✓ SAFE TO REMOVE: $yaml_file (old job file)"
                echo "$yaml_file" >> "$safe_file"
            elif echo "$filename" | grep -qE "(test|example|sample|\.bak|\.old|temp-)"; then
                echo "✓ SAFE TO REMOVE: $yaml_file (test/example/backup)"
                echo "$yaml_file" >> "$safe_file"
            elif echo "$filename" | grep -qE "(values-.*\.yaml|.*-nodeport\.yaml)"; then
                echo "✓ SAFE TO REMOVE: $yaml_file (unused values/service file)"
                echo "$yaml_file" >> "$safe_file"
            elif [[ "$yaml_file" =~ charts/ ]] || [[ "$yaml_file" =~ templates/ ]]; then
                # Skip files in charts/templates directories
                :
            else
                echo "⚠ NEEDS REVIEW: $yaml_file"
                echo "$yaml_file" >> "$review_file"
            fi
        fi
    done
done

echo
echo "=== Summary ==="
echo

# Process safe to remove files
if [ -s "$safe_file" ]; then
    echo "Files safe to remove:"
    sort -u "$safe_file" | while read file; do
        echo "  $file"
    done
    echo
    
    # Create removal script
    cat > remove-unreferenced-files.sh << 'EOF'
#!/bin/bash
# Script to remove unreferenced YAML files

FILES_TO_REMOVE=(
EOF
    
    sort -u "$safe_file" | while read file; do
        echo "    \"$file\"" >> remove-unreferenced-files.sh
    done
    
    cat >> remove-unreferenced-files.sh << 'EOF'
)

echo "The following files will be removed:"
echo "================================="
for file in "${FILES_TO_REMOVE[@]}"; do
    if [ -f "$file" ]; then
        echo "  $file"
    fi
done

echo
read -p "Do you want to proceed with deletion? (y/N) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    for file in "${FILES_TO_REMOVE[@]}"; do
        if [ -f "$file" ]; then
            rm -f "$file"
            echo "Removed: $file"
        fi
    done
    echo "Cleanup completed!"
else
    echo "Cleanup cancelled."
fi
EOF
    
    chmod +x remove-unreferenced-files.sh
    echo "Created remove-unreferenced-files.sh"
fi

# Process files needing review
if [ -s "$review_file" ]; then
    echo
    echo "Files needing manual review:"
    sort -u "$review_file" | while read file; do
        echo "  $file"
    done
fi

# Cleanup temp files
rm -f "$safe_file" "$review_file"