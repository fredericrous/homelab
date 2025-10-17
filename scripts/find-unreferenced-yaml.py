#!/usr/bin/env python3
"""
find-unreferenced-yaml.py - Find YAML files not referenced in kustomization.yaml

This script helps identify orphaned YAML files in a Kustomize-based project by
analyzing kustomization.yaml files to find unreferenced resources.
"""

import os
import re
import sys
from pathlib import Path
from typing import Set, List
from dataclasses import dataclass
from enum import Enum

try:
    import yaml
except ImportError:
    print("Error: PyYAML is required but not installed.", file=sys.stderr)
    print("\nInstallation options:", file=sys.stderr)
    print("\n1. Using Pipenv (recommended - Pipfile exists in project):", file=sys.stderr)
    print("   pipenv install", file=sys.stderr)
    print("   pipenv run python scripts/find-unreferenced-yaml.py", file=sys.stderr)
    print("\n2. Using pip with --user flag:", file=sys.stderr)
    print("   python3 -m pip install --user pyyaml", file=sys.stderr)
    print("\n3. In a virtual environment:", file=sys.stderr)
    print("   python3 -m venv venv", file=sys.stderr)
    print("   source venv/bin/activate", file=sys.stderr)
    print("   pip install pyyaml", file=sys.stderr)
    sys.exit(1)


class FileStatus(Enum):
    """Categorization of unreferenced files."""
    SAFE_TO_REMOVE = "safe_to_remove"
    NEEDS_REVIEW = "needs_review"


@dataclass
class AnalysisResult:
    """Result of analyzing an unreferenced file."""
    filepath: Path
    status: FileStatus
    reason: str


class KustomizationParser:
    """Parses kustomization.yaml files to extract referenced resources."""

    # Fields in kustomization.yaml that can reference files
    FILE_REFERENCE_FIELDS = [
        'resources', 'patches', 'patchesStrategicMerge', 'patchesJson6902',
        'configurations', 'crds', 'openapi', 'generators', 'transformers',
        'components', 'configMapGenerator', 'secretGenerator'
    ]

    def __init__(self, kustomization_path: Path):
        self.kustomization_path = kustomization_path
        self.directory = kustomization_path.parent

    def get_referenced_files(self) -> Set[str]:
        """Extract all referenced files from the kustomization.yaml."""
        referenced = set()

        try:
            content = self.kustomization_path.read_text(encoding='utf-8')

            # Try to parse as YAML first
            try:
                data = yaml.safe_load(content)
                if isinstance(data, dict):
                    self._parse_yaml_references(data, referenced)
            except yaml.YAMLError:
                # Fallback to regex if YAML parsing fails
                self._parse_regex_references(content, referenced)

        except Exception as e:
            print(f"Error reading {self.kustomization_path}: {e}", file=sys.stderr)

        return referenced

    def _parse_yaml_references(self, data: dict, referenced: Set[str]) -> None:
        """Parse YAML data to extract file references."""
        for field in self.FILE_REFERENCE_FIELDS:
            if field in data and data[field]:
                if isinstance(data[field], list):
                    for item in data[field]:
                        self._extract_file_reference(item, referenced)

        # Handle patches with target
        if 'patches' in data and isinstance(data['patches'], list):
            for patch in data['patches']:
                if isinstance(patch, dict) and 'path' in patch:
                    self._add_local_file(patch['path'], referenced)

    def _extract_file_reference(self, item, referenced: Set[str]) -> None:
        """Extract file reference from a YAML item."""
        if isinstance(item, str) and not item.startswith('http'):
            self._add_local_file(item, referenced)
        elif isinstance(item, dict):
            # Handle configMapGenerator/secretGenerator
            if 'files' in item:
                for file in item.get('files', []):
                    if isinstance(file, str):
                        self._add_local_file(file, referenced)
            elif 'path' in item:
                self._add_local_file(item['path'], referenced)

    def _add_local_file(self, path: str, referenced: Set[str]) -> None:
        """Add a local file reference, extracting basename if needed."""
        if path and not path.startswith('http'):
            # Handle relative paths
            if '/' not in path or path.startswith('./'):
                referenced.add(os.path.basename(path))

    def _parse_regex_references(self, content: str, referenced: Set[str]) -> None:
        """Fallback regex parsing for invalid YAML."""
        # Match lines like "- filename.yaml"
        pattern = re.compile(r'^\s*-\s*([^/\s#]+\.(yaml|yml))\s*(?:#.*)?$', re.MULTILINE)
        for match in pattern.finditer(content):
            referenced.add(match.group(1))


class UnreferencedFileAnalyzer:
    """Analyzes unreferenced files to determine if they're safe to remove."""

    # Patterns that indicate files safe to remove
    SAFE_PATTERNS = [
        'job-', '-job.yaml', 'postgres-setup.yaml', 'vault-secrets-init.yaml',
        'authelia-db-', 'fix-pool-size.yaml', 'job.yaml'
    ]

    # Important markers that indicate a file should be kept
    IMPORTANT_MARKERS = ['IMPORTANT', 'DO NOT DELETE', 'KEEP']

    # Test/example patterns
    TEST_PATTERNS = ['test', 'example', 'sample', '.bak', '.old']

    def __init__(self, project_root: Path):
        self.project_root = project_root
        self.manifests_dir = project_root / "manifests"

    def find_all_unreferenced(self) -> List[Path]:
        """Find all unreferenced YAML files in the project."""
        all_unreferenced = []

        # Find all kustomization.yaml files
        for kustomization_path in self.manifests_dir.rglob("kustomization.yaml"):
            directory = kustomization_path.parent
            unreferenced = self._find_unreferenced_in_directory(directory)
            all_unreferenced.extend(unreferenced)

        return sorted(all_unreferenced)

    def _find_unreferenced_in_directory(self, directory: Path) -> List[Path]:
        """Find unreferenced files in a specific directory."""
        kustomization_path = directory / 'kustomization.yaml'

        if not kustomization_path.exists():
            return []

        # Get all YAML files in directory (not in subdirs)
        yaml_files = []
        for file in directory.iterdir():
            if file.is_file() and file.suffix in ('.yaml', '.yml') and file.name != 'kustomization.yaml':
                yaml_files.append(file.name)

        # Get referenced files
        parser = KustomizationParser(kustomization_path)
        referenced = parser.get_referenced_files()

        # Find unreferenced files
        unreferenced = []
        for filename in yaml_files:
            if filename not in referenced:
                unreferenced.append(directory / filename)

        return unreferenced

    def analyze_file(self, filepath: Path) -> AnalysisResult:
        """Analyze a file to determine if it's safe to remove."""
        try:
            content = filepath.read_text(encoding='utf-8')

            # Check for important markers
            if any(marker in content for marker in self.IMPORTANT_MARKERS):
                return AnalysisResult(filepath, FileStatus.NEEDS_REVIEW, "Contains important markers")

            # Check if it's a Job that was replaced
            if 'kind: Job' in content:
                if 'job-' in filepath.name or '-job' in filepath.name:
                    return AnalysisResult(filepath, FileStatus.SAFE_TO_REMOVE, "Old Job file (likely replaced by workflow)")

            # Check for old patterns
            if any(pattern in str(filepath) for pattern in self.SAFE_PATTERNS):
                return AnalysisResult(filepath, FileStatus.SAFE_TO_REMOVE, "Matches old job pattern")

            # Check if it's a test or example file
            if any(pattern in filepath.name.lower() for pattern in self.TEST_PATTERNS):
                return AnalysisResult(filepath, FileStatus.SAFE_TO_REMOVE, "Test/example/backup file")

        except Exception as e:
            return AnalysisResult(filepath, FileStatus.NEEDS_REVIEW, f"Error reading file: {e}")

        return AnalysisResult(filepath, FileStatus.NEEDS_REVIEW, "Unknown file - manual review needed")


def main():
    """Main entry point."""
    # Find project root
    script_dir = Path(__file__).resolve().parent
    project_root = script_dir.parent

    # Check if manifests directory exists
    manifests_dir = project_root / "manifests"
    if not manifests_dir.exists():
        print(f"Error: manifests directory not found at {manifests_dir}", file=sys.stderr)
        sys.exit(1)

    # Initialize analyzer
    analyzer = UnreferencedFileAnalyzer(project_root)

    # Find unreferenced files
    print("Scanning for unreferenced YAML files...")
    unreferenced_files = analyzer.find_all_unreferenced()

    if not unreferenced_files:
        print("No unreferenced files found!")
        return

    # Analyze each file
    results = []
    for filepath in unreferenced_files:
        result = analyzer.analyze_file(filepath)
        results.append(result)

    # Display results
    print("\n=== Unreferenced YAML Files Analysis ===\n")

    safe_to_remove = []
    needs_review = []

    for result in results:
        rel_path = result.filepath.relative_to(project_root)

        if result.status == FileStatus.SAFE_TO_REMOVE:
            safe_to_remove.append(result)
            print(f"✓ SAFE TO REMOVE: {rel_path}")
            print(f"  Reason: {result.reason}")
        else:
            needs_review.append(result)
            print(f"⚠ NEEDS REVIEW: {rel_path}")
            print(f"  Reason: {result.reason}")
        print()

    # Summary
    print("\nSummary:")
    print(f"- Safe to remove: {len(safe_to_remove)} files")
    print(f"- Needs review: {len(needs_review)} files")

    if safe_to_remove:
        print("\nFiles safe to remove:")
        for result in safe_to_remove:
            print(f"  {result.filepath.relative_to(project_root)}")

    if needs_review:
        print("\nFiles needing review:")
        for result in needs_review:
            print(f"  {result.filepath.relative_to(project_root)}")

    # Optional: Generate removal command
    if safe_to_remove:
        print("\nTo remove safe files, run:")
        files_to_remove = ' '.join(f'"{r.filepath.relative_to(project_root)}"' for r in safe_to_remove)
        print(f"  rm {files_to_remove}")


if __name__ == "__main__":
    main()

