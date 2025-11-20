# Makefile for ext4-defrag-tui (Go Bubbletea version)

BINARY_NAME=ext4-defrag-tui
GO=go
GOFLAGS=-ldflags="-s -w"

.PHONY: all build clean install uninstall run test deps

all: build

# Build the binary
build:
	@echo "Building $(BINARY_NAME)..."
	$(GO) build $(GOFLAGS) -o $(BINARY_NAME) .
	@echo ""
	@echo "✓ Built successfully!"
	@echo "  Run with: sudo ./$(BINARY_NAME) -a /path/to/analyze"

# Build with debugging symbols
debug:
	@echo "Building $(BINARY_NAME) with debug symbols..."
	$(GO) build -o $(BINARY_NAME) .

# Download dependencies
deps:
	@echo "Downloading dependencies..."
	$(GO) mod download
	$(GO) mod tidy

# Clean build artifacts
clean:
	@echo "Cleaning..."
	rm -f $(BINARY_NAME)
	$(GO) clean

# Install to /usr/local/bin
install: build
	@echo "Installing $(BINARY_NAME) to /usr/local/bin..."
	install -m 755 $(BINARY_NAME) /usr/local/bin/
	@echo "✓ Installed successfully!"

# Uninstall from /usr/local/bin
uninstall:
	@echo "Uninstalling $(BINARY_NAME)..."
	rm -f /usr/local/bin/$(BINARY_NAME)

# Run in analyze mode (for testing)
run: build
	@echo "Running in analyze mode on /tmp..."
	sudo ./$(BINARY_NAME) -a /tmp

# Run tests (if any)
test:
	$(GO) test -v ./...

# Format code
fmt:
	$(GO) fmt ./...

# Check for issues
vet:
	$(GO) vet ./...

# Build for multiple platforms
build-all:
	@echo "Building for multiple platforms..."
	GOOS=linux GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BINARY_NAME)-linux-amd64 .
	GOOS=linux GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(BINARY_NAME)-linux-arm64 .
	@echo "✓ Built for all platforms!"

# Show help
help:
	@echo "Available targets:"
	@echo "  all         - Build the binary (default)"
	@echo "  build       - Build the binary"
	@echo "  debug       - Build with debug symbols"
	@echo "  deps        - Download dependencies"
	@echo "  clean       - Remove build artifacts"
	@echo "  install     - Install to /usr/local/bin"
	@echo "  uninstall   - Uninstall from /usr/local/bin"
	@echo "  run         - Build and run on /tmp (test)"
	@echo "  test        - Run tests"
	@echo "  fmt         - Format code"
	@echo "  vet         - Check for issues"
	@echo "  build-all   - Build for multiple platforms"
	@echo "  help        - Show this help"
