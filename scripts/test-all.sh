#!/usr/bin/env bash
set -eo pipefail

echo "=== Step 1: vitest ==="
pnpm vitest run src/channels/ios-read-receipts.test.ts src/channels/ios-app.ws.test.ts src/channels/ios-app.context.test.ts

echo "=== Step 2: mock WS server ==="
npx tsx scripts/mock-ws-server.ts &
MOCK_PID=$!
cleanup() { kill "$MOCK_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
sleep 1

echo "=== Step 3: xcodegen + xcodebuild UITest ==="
cd ios/JarvisApp
xcodegen generate --quiet
xcodebuild test \
  -project JarvisApp.xcodeproj \
  -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisUITests \
  -quiet
cd ../..

echo "=== All tests passed ==="
