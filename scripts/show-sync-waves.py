#!/usr/bin/env python3
"""
show-sync-waves.py - Display all ArgoCD applications organized by sync wave

This script analyzes ArgoCD application manifests to display deployment ordering
based on sync waves, helping understand application dependencies and deployment sequence.
"""

import sys
from collections import Counter
from pathlib import Path
from typing import Optional
from dataclasses import dataclass


@dataclass
class AppInfo:
    """Represents an ArgoCD application with its metadata."""
    name: str
    namespace: str = "default"
    sync_wave: int = 0
    project: str = "default"
    path: str = ""
    has_dependencies: bool = False


class AppManifestParser:
    """Parses ArgoCD application manifests in different formats."""
    
    @staticmethod
    def parse_file(file_path: Path) -> Optional[AppInfo]:
        """
        Parse an app.yaml file and extract relevant information.
        
        Supports both simple format and full ArgoCD Application manifests.
        """
        try:
            content = file_path.read_text(encoding='utf-8')
            
            if content.startswith('apiVersion:'):
                return AppManifestParser._parse_argocd_format(content)
            else:
                return AppManifestParser._parse_simple_format(content)
        except Exception as e:
            print(f"Error parsing {file_path}: {e}", file=sys.stderr)
            return None
    
    @staticmethod
    def _parse_argocd_format(content: str) -> Optional[AppInfo]:
        """Parse full ArgoCD Application manifest format."""
        app_info = {}
        lines = content.splitlines()
        in_metadata = False
        in_spec = False
        
        for line in lines:
            line = line.strip()
            if line == 'metadata:':
                in_metadata = True
                in_spec = False
            elif line == 'spec:':
                in_spec = True
                in_metadata = False
            elif in_metadata and line.startswith('name:'):
                app_info['name'] = line.split(':', 1)[1].strip()
            elif in_metadata and line.startswith('namespace:'):
                app_info['namespace'] = line.split(':', 1)[1].strip()
            elif 'sync-wave:' in line:
                # Extract sync wave from annotation
                wave = line.split('"')[1] if '"' in line else line.split(':', 1)[1].strip()
                try:
                    app_info['sync_wave'] = int(wave)
                except ValueError:
                    app_info['sync_wave'] = 0
            elif in_spec and line.startswith('project:'):
                app_info['project'] = line.split(':', 1)[1].strip()
        
        return AppInfo(**app_info) if 'name' in app_info else None
    
    @staticmethod
    def _parse_simple_format(content: str) -> Optional[AppInfo]:
        """Parse simple app.yaml format."""
        app_info = {}
        has_dependencies = False
        
        for line in content.splitlines():
            line = line.strip()
            if line.startswith('name:'):
                app_info['name'] = line.split(':', 1)[1].strip()
            elif line.startswith('namespace:'):
                app_info['namespace'] = line.split(':', 1)[1].strip()
            elif line.startswith('syncWave:'):
                # Extract just the number, ignore comments
                wave_value = line.split(':', 1)[1].strip().strip('"')
                wave_value = wave_value.split('#')[0].strip().strip('"')
                try:
                    app_info['sync_wave'] = int(wave_value)
                except ValueError:
                    app_info['sync_wave'] = 0
            elif line.startswith('project:'):
                app_info['project'] = line.split(':', 1)[1].strip()
            elif line.startswith('dependsOn:'):
                has_dependencies = True
        
        if 'name' not in app_info:
            return None
            
        return AppInfo(**app_info, has_dependencies=has_dependencies)


class SyncWaveAnalyzer:
    """Analyzes and displays ArgoCD sync waves."""
    
    def __init__(self, project_root: Path):
        self.project_root = project_root
        self.apps: list[AppInfo] = []
    
    def collect_apps(self) -> None:
        """Collect all app.yaml files from the manifests directory."""
        manifest_patterns = [
            "manifests/*/app.yaml",
            "manifests/*/*/app.yaml",
        ]
        
        for pattern in manifest_patterns:
            for app_file in self.project_root.glob(pattern):
                app_info = AppManifestParser.parse_file(app_file)
                if app_info:
                    app_info.path = str(app_file.relative_to(self.project_root))
                    self.apps.append(app_info)
        
        # Sort by sync wave
        self.apps.sort(key=lambda x: x.sync_wave)
    
    def display_results(self) -> None:
        """Display the analysis results."""
        self._print_header()
        self._print_apps_by_wave()
        self._print_summary()
        self._print_wave_distribution()
        self._print_wave_ranges()
        self._check_potential_issues()
    
    def _print_header(self) -> None:
        """Print the header information."""
        print("ArgoCD Application Sync Waves")
        print("=" * 29)
        print()
        
        # Table header
        print(f"{'Wave':>5} | {'App Name':<30} | {'Namespace':<20} | {'Project':<7} | {'Deps':<4} | Path")
        print(f"{'-'*5}-|-{'-'*30}-|-{'-'*20}-|-{'-'*7}-|-{'-'*4}-|-{'-'*40}")
    
    def _print_apps_by_wave(self) -> None:
        """Print applications grouped by sync wave."""
        current_wave = None
        
        for app in self.apps:
            if app.sync_wave != current_wave:
                current_wave = app.sync_wave
                print(f"\n=== Sync Wave: {current_wave} ===")
            
            deps = "yes" if app.has_dependencies else "no"
            print(f"{app.sync_wave:>5} | {app.name:<30} | {app.namespace:<20} | "
                  f"{app.project:<7} | {deps:<4} | {app.path}")
    
    def _print_summary(self) -> None:
        """Print summary statistics."""
        print("\nSummary:")
        print("-" * 8)
        print(f"Total applications: {len(self.apps)}")
        
        unique_waves = len(set(app.sync_wave for app in self.apps))
        print(f"Unique sync waves: {unique_waves}")
    
    def _print_wave_distribution(self) -> None:
        """Print distribution of applications across sync waves."""
        print("\nWave Distribution:")
        
        wave_counts = Counter(app.sync_wave for app in self.apps)
        
        for wave in sorted(wave_counts.keys()):
            print(f"  Wave {wave:3d}: {wave_counts[wave]:2d} apps")
    
    def _print_wave_ranges(self) -> None:
        """Print information about wave ranges."""
        print("\nWave Ranges:")
        print("  Negative waves (-30 to -1): Core infrastructure (deployed first)")
        print("  Zero wave (0): Default wave (no explicit ordering)")
        print("  Positive waves (1+): Applications (deployed last)")
    
    def _check_potential_issues(self) -> None:
        """Check for potential configuration issues."""
        print("\nPotential Issues:")
        
        # Check for duplicate names
        names = [app.name for app in self.apps]
        duplicates = [name for name in set(names) if names.count(name) > 1]
        
        if duplicates:
            print(f"  ⚠ Duplicate app names found: {', '.join(duplicates)}")
        else:
            print("  ✓ No duplicate app names")
        
        # Check for apps with dependencies but early sync waves
        early_deps = [app for app in self.apps 
                      if app.has_dependencies and app.sync_wave < -20]
        
        for app in early_deps:
            print(f"  ⚠ {app.name} (wave {app.sync_wave}) has dependencies but deploys very early")
        
        # Count apps without explicit sync waves
        no_wave = [app for app in self.apps if app.sync_wave == 0]
        if no_wave:
            print(f"  ℹ {len(no_wave)} apps without explicit sync waves (default to 0)")


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
    
    # Analyze sync waves
    analyzer = SyncWaveAnalyzer(project_root)
    analyzer.collect_apps()
    
    if not analyzer.apps:
        print("No applications found!")
        sys.exit(1)
    
    analyzer.display_results()


if __name__ == "__main__":
    main()