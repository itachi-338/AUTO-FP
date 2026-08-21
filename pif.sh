#!/bin/bash

#!/bin/bash
set -e

echo "Crawling Android Developers for latest Pixel Beta..."

# Fetch main Android versions page
wget -q -O PIXEL_VERSIONS_HTML --no-check-certificate https://developer.android.com/about/versions || exit 1

# Extract latest numeric Android version URL using version sort (sort -V)
LATEST_VERSION_URL=$(grep -oE 'https://developer\.android\.com/about/versions/[0-9a-zA-Z_-]+' PIXEL_VERSIONS_HTML | grep -v 'download' | sort -V -r | head -n1)

if [ -z "$LATEST_VERSION_URL" ]; then
  echo "Error: Could not find latest Android version page!"
  exit 1
fi

echo "Found Latest Release Page: $LATEST_VERSION_URL"
wget -q -O PIXEL_BETA_HTML --no-check-certificate "$LATEST_VERSION_URL" || exit 1

# Extract OTA download page URL
OTA_PAGE_PATH=$(grep -oE 'href="[^"]*download-ota[^"]*"' PIXEL_BETA_HTML | cut -d'"' -f2 | head -n1)

if [ -z "$OTA_PAGE_PATH" ]; then
  OTA_PAGE_PATH=$(grep -oE 'href="[^"]*download-ota[^"]*"' PIXEL_VERSIONS_HTML | cut -d'"' -f2 | head -n1)
fi

if [[ "$OTA_PAGE_PATH" != http* ]]; then
  OTA_PAGE_URL="https://developer.android.com${OTA_PAGE_PATH}"
else
  OTA_PAGE_URL="$OTA_PAGE_PATH"
fi

echo "Fetching OTA Page: $OTA_PAGE_URL"
wget -q -O PIXEL_OTA_HTML --no-check-certificate "$OTA_PAGE_URL" || exit 1

# Extract date metadata
BETA_REL_DATE="$(date -d "$(grep -m1 -A1 'Release date' PIXEL_OTA_HTML | tail -n1 | sed 's;.*<td>\(.*\)</td>.*;\1;')" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')"
BETA_EXP_DATE="$(date -d "@$(($(date -d "$BETA_REL_DATE" '+%s' 2>/dev/null || echo 0) + 60 * 60 * 24 * 7 * 6))" '+%Y-%m-%d' 2>/dev/null || echo "Unknown")"

echo "Beta Released: $BETA_REL_DATE"
echo "Estimated Expiry: $BETA_EXP_DATE"

# Extract models, products, and OTA URL lists
MODEL_LIST="$(grep -A1 'tr id=' PIXEL_OTA_HTML | grep 'td' | sed 's;.*<td>\(.*\)</td>;\1;')"
PRODUCT_LIST="$(grep -o 'ota/.*_beta' PIXEL_OTA_HTML | cut -d\/ -f2)"
OTA_LIST="$(grep 'ota/.*_beta' PIXEL_OTA_HTML | cut -d\" -f2)"

# Check if a specific model was passed via command line (e.g., ./script.sh -m panther)
TARGET_DEVICE=""
if [ "$1" == "-m" ] && [ -n "$2" ]; then
  TARGET_DEVICE="$2"
fi

# GitHub Actions runner check: Use getprop only if running directly on an Android device
if [ -n "$TARGET_DEVICE" ]; then
  PRODUCT="${TARGET_DEVICE}_beta"
  DEVICE="$TARGET_DEVICE"
  MODEL=$(echo "$MODEL_LIST" | grep -i "$TARGET_DEVICE" | head -n1 || echo "Pixel Device")
  OTA=$(echo "$OTA_LIST" | grep "$PRODUCT" | head -n1)
elif command -v getprop >/dev/null 2>&1 && [ -n "$(getprop ro.product.device 2>/dev/null)" ]; then
  DEVICE="$(getprop ro.product.device)"
  MODEL="$(getprop ro.product.model)"
  PRODUCT="${DEVICE}_beta"
  OTA="$(echo "$OTA_LIST" | grep "$PRODUCT" | head -n1)"
fi

# Default to random device selection for automated non-interactive runners
if [ -z "$OTA" ] || [ -z "$PRODUCT" ]; then
  echo "Selecting random Pixel Beta device..."
  list_count="$(echo "$PRODUCT_LIST" | wc -l)"
  list_rand="$((RANDOM % list_count + 1))"

  IFS=$'\n'
  set -- $MODEL_LIST
  MODEL="$(eval echo \${$list_rand})"

  set -- $PRODUCT_LIST
  PRODUCT="$(eval echo \${$list_rand})"

  set -- $OTA_LIST
  OTA="$(eval echo \${$list_rand})"

  DEVICE="$(echo "$PRODUCT" | sed 's/_beta//')"
fi

echo "Selected Device: $MODEL ($PRODUCT)"

# Download OTA header metadata
(ulimit -f 4; wget -q -O PIXEL_ZIP_METADATA --no-check-certificate "$OTA") 2>/dev/null || true

FINGERPRINT="$(grep -am1 'post-build=' PIXEL_ZIP_METADATA | cut -d= -f2 | tr -d '\r')"
SECURITY_PATCH="$(grep -am1 'security-patch-level=' PIXEL_ZIP_METADATA | cut -d= -f2 | tr -d '\r')"

if [ -z "$FINGERPRINT" ] || [ -z "$SECURITY_PATCH" ]; then
  echo "Error: Failed to extract fingerprint or security patch level!"
  exit 1
fi

echo "Extracted Fingerprint: $FINGERPRINT"
echo "Extracted Security Patch: $SECURITY_PATCH"

# Write pif.json output
cat <<EOF > pif.json
{
  "MANUFACTURER": "Google",
  "MODEL": "$MODEL",
  "FINGERPRINT": "$FINGERPRINT",
  "PRODUCT": "$PRODUCT",
  "DEVICE": "$DEVICE",
  "SECURITY_PATCH": "$SECURITY_PATCH",
  "DEVICE_INITIAL_SDK_INT": "32"
}
EOF

# Remove temporary HTML files if they exist
find . -maxdepth 1 -name "*_HTML" -exec rm {} \;
find . -maxdepth 1 -name "*_METADATA" -exec rm {} \;

# Add fields to chiteroman.json
cp pif.json chiteroman.json

# Migrate data using the migrate_osmosis.sh script and output to osmosis.json
./migrate_osmosis.sh -a pif.json device_osmosis.json
sed -i 's|//.*||g; /^[[:space:]]*$/d' device_osmosis.json
jq '(.spoofBuild, .spoofVendingFinger, .spoofProps) = "1" | (.spoofProvider, .spoofSignature, .spoofVendingSdk) = "0"' device_osmosis.json > tmp.json && mv tmp.json device_osmosis.json


./migrate_osmosis.sh -a pif.json osmosis.json
sed -i 's|//.*||g; /^[[:space:]]*$/d' osmosis.json
jq '(.spoofBuild, .spoofProvider, .spoofVendingFinger, .spoofProps) = "1" | (.spoofSignature, .spoofVendingSdk) = "0"' osmosis.json > tmp.json && mv tmp.json osmosis.json

# Delete the previously created pif.json as it's no longer needed
rm pif.json

# Remove any backup files with the .bak extension if they exist
find . -maxdepth 1 -name "*.bak" -exec rm {} \;
