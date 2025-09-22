#!/bin/bash
echo "Scanning for AVP placeholders..."
echo "File,Placeholder,Type" > reports/avp-usage.csv

# Scan manifests directory
find manifests -type f \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null | while read -r file; do
    grep -o '<path:[^>]*>' "$file" 2>/dev/null | while read -r placeholder; do
        # Determine if it's a secret or config
        if echo "$placeholder" | grep -qE "password|secret|key|token"; then
            type="secret"
        else
            type="config"
        fi
        echo "$file,$placeholder,$type" >> reports/avp-usage.csv
    done
done

echo "AVP scan complete. Results in reports/avp-usage.csv"
echo ""
echo "Summary:"
wc -l < reports/avp-usage.csv | xargs -I {} echo "Total placeholders: {}"
grep ",config$" reports/avp-usage.csv | wc -l | xargs -I {} echo "Config placeholders: {}"
grep ",secret$" reports/avp-usage.csv | wc -l | xargs -I {} echo "Secret placeholders: {}"
echo ""
echo "First 10 entries:"
head -10 reports/avp-usage.csv | column -t -s ','