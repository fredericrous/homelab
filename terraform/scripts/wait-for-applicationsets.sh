#!/bin/bash

echo "Waiting for ApplicationSets to be healthy..."

# Wait for ApplicationSet controller to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-applicationset-controller -n argocd

# Check each ApplicationSet
for appset in core apps harbor stremio; do
    echo "Checking ApplicationSet: $appset"
    
    # Wait for ApplicationSet to exist
    while ! kubectl get applicationset $appset -n argocd &>/dev/null; do
        echo "Waiting for ApplicationSet $appset to be created..."
        sleep 5
    done
    
    # Check for errors in ApplicationSet status
    max_attempts=30
    attempt=0
    while [ $attempt -lt $max_attempts ]; do
        # Get ApplicationSet status
        status=$(kubectl get applicationset $appset -n argocd -o json)
        
        # Check for ErrorOccurred condition
        error_occurred=$(echo "$status" | jq -r '.status.conditions[]? | select(.type == "ErrorOccurred") | .status')
        error_message=$(echo "$status" | jq -r '.status.conditions[]? | select(.type == "ErrorOccurred") | .message')
        
        if [ "$error_occurred" == "True" ]; then
            # Check if it's a DNS error (which might be temporary)
            if echo "$error_message" | grep -q "dial tcp: lookup"; then
                echo "ApplicationSet $appset has DNS errors (may be temporary): $error_message"
                echo "Waiting for DNS to stabilize..."
                sleep 10
                ((attempt++))
                continue
            else
                echo "ERROR: ApplicationSet $appset has errors: $error_message"
                
                # Check for duplicate key errors specifically
                if echo "$error_message" | grep -q "duplicate key"; then
                    echo "CRITICAL: ApplicationSet $appset has duplicate key errors!"
                    echo "This needs to be fixed before continuing."
                    exit 1
                fi
            fi
        fi
        
        # Check if ApplicationSet has generated applications
        app_count=$(kubectl get applications -n argocd -l "argocd.argoproj.io/application-set-name=$appset" --no-headers 2>/dev/null | wc -l)
        
        if [ "$app_count" -gt 0 ]; then
            echo "✓ ApplicationSet $appset has generated $app_count applications"
            break
        else
            echo "ApplicationSet $appset hasn't generated applications yet (attempt $((attempt+1))/$max_attempts)"
            sleep 10
            ((attempt++))
        fi
    done
    
    if [ $attempt -eq $max_attempts ]; then
        echo "WARNING: ApplicationSet $appset didn't generate applications within timeout"
        echo "Checking for persistent errors..."
        
        # Get final status
        kubectl get applicationset $appset -n argocd -o yaml
        
        # Don't fail on DNS errors as they might resolve later
        if echo "$error_message" | grep -q "dial tcp: lookup"; then
            echo "Continuing despite DNS errors (they may resolve when services come up)"
        else
            echo "CRITICAL: ApplicationSet $appset failed to generate applications"
            exit 1
        fi
    fi
done

echo "All ApplicationSets checked!"