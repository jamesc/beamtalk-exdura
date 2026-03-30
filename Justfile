# Exdura workflow engine

# Run all checks then tests
default: build test

# Format all .bt source files
fmt:
    beamtalk fmt

# Run linter on source files
lint:
    beamtalk lint

# Build (format + lint first)
build: fmt lint
    beamtalk build

# Run the test suite
test: build
    beamtalk test

# Remove build artifacts and test data
clean:
    rm -rf _build
    rm -rf src/build test/build test/fixtures/build
