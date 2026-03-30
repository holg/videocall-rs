#!/usr/bin/env bash
# File: scripts/test-ci-locally.sh
# Local build & check script for videocall-rs meeting-api
# Follows CONTRIBUTING.md requirements: fmt, clippy, tests

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== videocall-rs local checks ===${NC}\n"

# Step 1: cargo fmt
echo -e "${YELLOW}Step 1: cargo fmt check...${NC}"
if cargo fmt -p meeting-api -- --check; then
    echo -e "${GREEN}✓ fmt passed${NC}\n"
else
    echo -e "${RED}✗ fmt failed${NC}"
    echo -e "${YELLOW}Run 'cargo fmt -p meeting-api' to fix${NC}\n"
    exit 1
fi

# Step 2: clippy (postgres — default)
echo -e "${YELLOW}Step 2: clippy (postgres)...${NC}"
if cargo clippy -p meeting-api -- -D warnings; then
    echo -e "${GREEN}✓ clippy postgres passed${NC}\n"
else
    echo -e "${RED}✗ clippy postgres failed${NC}\n"
    exit 1
fi

# Step 3: clippy (sqlite)
echo -e "${YELLOW}Step 3: clippy (sqlite)...${NC}"
if cargo clippy -p meeting-api --no-default-features --features sqlite -- -D warnings; then
    echo -e "${GREEN}✓ clippy sqlite passed${NC}\n"
else
    echo -e "${RED}✗ clippy sqlite failed${NC}\n"
    exit 1
fi

# Step 4: check postgres build
echo -e "${YELLOW}Step 4: cargo check (postgres)...${NC}"
if cargo check -p meeting-api; then
    echo -e "${GREEN}✓ postgres build passed${NC}\n"
else
    echo -e "${RED}✗ postgres build failed${NC}\n"
    exit 1
fi

# Step 5: check sqlite build
echo -e "${YELLOW}Step 5: cargo check (sqlite)...${NC}"
if cargo check -p meeting-api --no-default-features --features sqlite; then
    echo -e "${GREEN}✓ sqlite build passed${NC}\n"
else
    echo -e "${RED}✗ sqlite build failed${NC}\n"
    exit 1
fi

# Step 6: unit tests
echo -e "${YELLOW}Step 6: unit tests...${NC}"
if cargo test -p meeting-api --lib; then
    echo -e "${GREEN}✓ unit tests passed${NC}\n"
else
    echo -e "${RED}✗ unit tests failed${NC}\n"
    exit 1
fi

echo -e "\n${GREEN}=== All checks passed! ===${NC}"
