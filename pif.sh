#!/bin/bash
set -e

echo "Fetching Android 17 Beta OTA metadata directly..."

# Hardcoded primary and fallback URLs for Android 17 Beta OTA downloads
URL_A17="https://developer.android.com/about/versions/17/download-ota"
URL_PREVIEW="https://developer.android.com/about/versions/preview/download-ota"

# Attempt to fetch the Android 17 OTA page
if wget -q -O PIXEL_OTA_HTML --no-check-certificate "$URL_A17" 2>/dev/null && grep -q 'ota/.*_beta' PIXEL_OTA_HTML; then
  echo "Targeting Endpoint: $URL_A17"
elif wget -q -O PIXEL_OTA_HTML --no-check-certificate "$URL_PREVIEW" 2>/dev/null && grep -q 'ota/.*_beta' PIXEL_OTA_HTML; then
  echo "Targeting Endpoint: $URL_PREVIEW"
else
  echo "Error: Unable to locate Android 17 Beta OTA links on Google's portal!"
  exit 1
fi

# Extract date metadata
BETA_REL_DATE="$(date -d "$(grep -m1 -A1 'Release date' PIXEL_OTA_HTML | tail -n1 | sed 's;.*<td>\(.*\)</td>.*;\1;')" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')"
BETA_EXP_DATE="$(date -d "@$(($(date -d "$BETA_REL_DATE" '+%s' 2>/dev/null || echo 0) + 60 * 60 * 24 * 7 * 6))" '+%Y-%m-%d' 2>/dev/null || echo "Unknown")"

echo "Beta Released: $BETA_REL_DATE"
echo "Estimated Expiry: $BETA_EXP_DATE"

# Extract models, products, and OTA URL lists
MODEL_LIST="$(grep -A1 'tr id=' PIXEL_OTA_HTML | grep 'td' | sed 's;.*<td>\(.*\)</td>;\1;')"
PRODUCT_LIST="$(grep -o 'ota/.*_beta' PIXEL_OTA_HTML | cut -d\/ -f2)"
OTA_LIST="$(grep 'ota/.*_beta' PIXEL_OTA_HTML | cut -d\" -f2)"

if [ -z "$PRODUCT_LIST" ]; then
  echo "Error: No Pixel Beta OTA links found on page."
  exit 1
fi

# Target device override flag (-m device_name)
TARGET_DEVICE=""
if [ "$1" == "-m" ] && [ -n "$2" ]; then
  TARGET_DEVICE="$2"
fi

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

# Default to random selection if no specific device is targeted
if [ -z "$OTA" ] || [ -z "$PRODUCT" ]; then
  echo "Selecting random Pixel device from Android 17 list..."
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

# Download first 32KB of OTA zip headers safely for metadata parsing
wget -q --header="Range: bytes=0-32768" -O PIXEL_ZIP_METADATA --no-check-certificate "$OTA" || true

FINGERPRINT="$(grep -am1 'post-build=' PIXEL_ZIP_METADATA | cut -d= -f2 | tr -d '\r')"
SECURITY_PATCH="$(grep -am1 'security-patch-level=' PIXEL_ZIP_METADATA | cut -d= -f2 | tr -d '\r')"

if [ -z "$FINGERPRINT" ] || [ -z "$SECURITY_PATCH" ]; then
  echo "Error: Failed to extract fingerprint or security patch level from metadata!"
  exit 1
fi

echo "Extracted Fingerprint: $FINGERPRINT"
echo "Extracted Security Patch: $SECURITY_PATCH"

# Output pif.json
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

echo "Successfully dumped Android 17 values to pif.json"

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
