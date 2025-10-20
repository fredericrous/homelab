# Building the Bootstrap Tool

This directory contains a Taskfile.yml for building and managing the bootstrap CLI tool.

## Prerequisites

- Go 1.21 or later
- [Task](https://taskfile.dev/) runner

Install Task on macOS:
```bash
brew install go-task/tap/go-task
```

## Quick Start

```bash
# Build the bootstrap binary
task build

# Build and run with help
task dev -- --help

# Run all checks (format, lint, test, build)
task check

# Build for multiple platforms
task build-all

# Clean build artifacts
task clean
```

## Available Tasks

```bash
task --list
```

### Main Tasks

- **`task build`** - Build the bootstrap binary
- **`task verify`** - Verify the build works by running version and help
- **`task dev -- [args]`** - Build and run in development mode with arguments
- **`task check`** - Run all checks (format, lint, test, build)

### Development Tasks

- **`task format`** - Format Go code
- **`task lint`** - Run linters (go vet)
- **`task test`** - Run tests with race detection
- **`task test-short`** - Run short tests only

### Build Tasks

- **`task build-linux`** - Build for Linux (amd64)
- **`task build-darwin`** - Build for macOS (amd64 + arm64)
- **`task build-windows`** - Build for Windows (amd64)
- **`task build-all`** - Build for all platforms

### Utility Tasks

- **`task clean`** - Clean build artifacts
- **`task deps`** - Download and verify dependencies
- **`task install`** - Install to GOPATH/bin
- **`task release`** - Prepare a complete release build

## Usage Examples

```bash
# Development workflow
task format
task lint
task test-short
task build
task verify

# Or run all at once
task check

# Build and test a command
task dev -- homelab --help
task dev -- nas status

# Build for distribution
task release
```

## Output

- Main binary: `./bootstrap`
- Multi-platform binaries: `./bin/bootstrap-{os}-{arch}`

## Integration with Project Taskfiles

This bootstrap tool replaces many operations from the main project Taskfiles:

```bash
# Instead of: task homelab:up
./bootstrap homelab up

# Instead of: task nas:status  
./bootstrap nas status

# Instead of: task homelab:suspend
./bootstrap homelab suspend
```

The tool provides guidance on when to fall back to the original Taskfile commands for operations requiring external tool integration.