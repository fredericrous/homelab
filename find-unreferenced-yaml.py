#!/usr/bin/env python3
import os
import yaml
import re
from pathlib import Path

def get_referenced_files(kustomization_path):
    """Extract all referenced files from a kustomization.yaml"""
    referenced = set()
    
    try:
        with open(kustomization_path, 'r') as f:
            content = f.read()
            
        # Try to parse as YAML first
        try:
            data = yaml.safe_load(content)
            
            # Common fields that reference files
            file_fields = ['resources', 'patches', 'patchesStrategicMerge', 'patchesJson6902', 
                          'configurations', 'crds', 'openapi', 'generators', 'transformers',
                          'components', 'configMapGenerator', 'secretGenerator']
            
            for field in file_fields:
                if field in data and data[field]:
                    if isinstance(data[field], list):
                        for item in data[field]:
                            if isinstance(item, str) and not item.startswith('http'):
                                # Handle relative paths
                                if '/' not in item or item.startswith('./'):
                                    referenced.add(os.path.basename(item))
                            elif isinstance(item, dict):
                                # Handle configMapGenerator/secretGenerator
                                if 'files' in item:
                                    for file in item.get('files', []):
                                        if isinstance(file, str):
                                            referenced.add(os.path.basename(file))
                                elif 'path' in item:
                                    path = item['path']
                                    if '/' not in path or path.startswith('./'):
                                        referenced.add(os.path.basename(path))
                                        
            # Handle patches with target
            if 'patches' in data and data['patches']:
                for patch in data['patches']:
                    if isinstance(patch, dict) and 'path' in patch:
                        path = patch['path']
                        if '/' not in path or path.startswith('./'):
                            referenced.add(os.path.basename(path))
                            
        except yaml.YAMLError:
            # Fallback to regex if YAML parsing fails
            # Match lines like "- filename.yaml"
            pattern = re.compile(r'^\s*-\s*([^/\s#]+\.(yaml|yml))\s*(?:#.*)?$', re.MULTILINE)
            for match in pattern.finditer(content):
                referenced.add(match.group(1))
                
    except Exception as e:
        print(f"Error reading {kustomization_path}: {e}")
        
    return referenced

def find_unreferenced_files(directory):
    """Find all YAML files in directory not referenced by kustomization.yaml"""
    kustomization_path = os.path.join(directory, 'kustomization.yaml')
    
    if not os.path.exists(kustomization_path):
        return []
        
    # Get all YAML files in directory (not in subdirs)
    yaml_files = []
    for file in os.listdir(directory):
        if file.endswith(('.yaml', '.yml')) and file != 'kustomization.yaml':
            yaml_files.append(file)
            
    # Get referenced files
    referenced = get_referenced_files(kustomization_path)
    
    # Find unreferenced files
    unreferenced = []
    for file in yaml_files:
        if file not in referenced:
            unreferenced.append(os.path.join(directory, file))
            
    return unreferenced

def analyze_file(filepath):
    """Analyze a file to determine if it's safe to remove"""
    try:
        with open(filepath, 'r') as f:
            content = f.read()
            
        # Check for important markers
        if 'IMPORTANT' in content or 'DO NOT DELETE' in content or 'KEEP' in content:
            return False, "Contains important markers"
            
        # Check if it's a Job that was replaced
        if 'kind: Job' in content:
            if 'job-' in os.path.basename(filepath) or '-job' in os.path.basename(filepath):
                return True, "Old Job file (likely replaced by workflow)"
                
        # Check for old patterns
        if any(pattern in filepath for pattern in [
            'job-', '-job.yaml', 'postgres-setup.yaml', 'vault-secrets-init.yaml',
            'authelia-db-', 'fix-pool-size.yaml', 'job.yaml'
        ]):
            return True, "Matches old job pattern"
            
        # Check if it's a test or example file
        if any(pattern in filepath.lower() for pattern in ['test', 'example', 'sample', '.bak', '.old']):
            return True, "Test/example/backup file"
            
    except Exception as e:
        return False, f"Error reading file: {e}"
        
    return False, "Unknown file - manual review needed"

def main():
    manifests_dir = Path("manifests")
    all_unreferenced = []
    
    # Find all directories with kustomization.yaml
    for kustomization in manifests_dir.rglob("kustomization.yaml"):
        directory = kustomization.parent
        unreferenced = find_unreferenced_files(directory)
        
        if unreferenced:
            all_unreferenced.extend(unreferenced)
            
    if not all_unreferenced:
        print("No unreferenced files found!")
        return
        
    # Categorize files
    safe_to_remove = []
    needs_review = []
    
    print("=== Unreferenced YAML Files Analysis ===\n")
    
    for filepath in sorted(all_unreferenced):
        safe, reason = analyze_file(filepath)
        
        if safe:
            safe_to_remove.append(filepath)
            print(f"✓ SAFE TO REMOVE: {filepath}")
            print(f"  Reason: {reason}")
        else:
            needs_review.append(filepath)
            print(f"⚠ NEEDS REVIEW: {filepath}")
            print(f"  Reason: {reason}")
        print()
        
    print(f"\nSummary:")
    print(f"- Safe to remove: {len(safe_to_remove)} files")
    print(f"- Needs review: {len(needs_review)} files")
    
    if safe_to_remove:
        print(f"\nFiles safe to remove:")
        for f in safe_to_remove:
            print(f"  {f}")
            
    if needs_review:
        print(f"\nFiles needing review:")
        for f in needs_review:
            print(f"  {f}")

if __name__ == "__main__":
    main()