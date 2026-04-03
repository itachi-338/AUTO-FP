#!/bin/bash

set -e

BASE_URL="https://developer.android.com"

echo "🔍 Fetching Android versions page..."
wget -q -O versions.html --no-check-certificate "$BASE_URL/about/versions" || exit 1

echo "🔍 Detecting latest Android version page..."
LATEST_URL=$(grep -oE "$BASE_URL/about/versions/[a-zA-Z0-9\-]+" versions.html | sort -u | tail -n1)

[ -z "$LATEST_URL" ] && { echo "❌ Failed to find latest version page"; exit 1; }

echo "➡️ Latest page: $LATEST_URL"

wget -q -O latest.html --no-check-certificate "$LATEST_URL" || exit 1

echo "🔍 Extracting OTA or factory image link..."

DOWNLOAD_PATH=$(grep -oE 'href="[^"]*download[^"]*"' latest.html \
  | cut -d\" -f2 \
  | head -n1)

if [ -z "$DOWNLOAD_PATH" ]; then
  echo "⚠️ OTA not found, trying factory images..."
  DOWNLOAD_PATH=$(grep -oE 'href="[^"]*factory[^"]*"' latest.html \
    | cut -d\" -f2 \
    | head -n1)
fi

[ -z "$DOWNLOAD_PATH" ] && { echo "❌ No download path found"; exit 1; }

FULL_URL="$BASE_URL$DOWNLOAD_PATH"
echo "➡️ Download page: $FULL_URL"

wget -q -O download.html --no-check-certificate "$FULL_URL" || exit 1

echo "🔍 Extracting Beta version info..."

ANDROID_VER=$(grep -m1 -oE 'Android [0-9]+' download.html)
BETA_TAG=$(grep -m1 -oE 'Beta [0-9]+' download.html)

echo "📱 Version: $ANDROID_VER $BETA_TAG"

echo "🔍 Extracting release date..."

REL_DATE_RAW=$(grep -A1 'Release date' download.html \
  | tail -n1 \
  | sed -E 's/.*<td>(.*)<\/td>.*/\1/')

if [ -n "$REL_DATE_RAW" ]; then
  REL_DATE=$(date -d "$REL_DATE_RAW" '+%Y-%m-%d' 2>/dev/null || echo "unknown")
else
  REL_DATE="unknown"
fi

if [ "$REL_DATE" != "unknown" ]; then
  EXP_DATE=$(date -d "$REL_DATE +42 days" '+%Y-%m-%d')
else
  EXP_DATE="unknown"
fi

echo "📅 Released: $REL_DATE"
echo "⏳ Estimated expiry: $EXP_DATE"

echo "🔍 Extracting device list..."

MODELS=$(grep -oE '<td>Pixel[^<]+' download.html | sed 's/<td>//')
PRODUCTS=$(grep -oE '<tr id="[^"]+"' download.html | cut -d\" -f2)

MODEL=$(echo "$MODELS" | head -n1)
PRODUCT=$(echo "$PRODUCTS" | head -n1)
DEVICE=$(echo "$PRODUCT" | sed 's/_beta//')

echo "📦 Selected: $MODEL ($PRODUCT)"

echo "🔍 Extracting OTA zip link..."

OTA_LINK=$(grep -oE 'https://[^"]+\.zip' download.html | head -n1)

[ -z "$OTA_LINK" ] && { echo "❌ OTA link not found"; exit 1; }

echo "⬇️ Fetching metadata (partial download)..."

(ulimit -f 2; wget -q -O metadata.bin --no-check-certificate "$OTA_LINK") 2>/dev/null || true

echo "🔍 Extracting fingerprint..."

FINGERPRINT=$(strings metadata.bin | grep -m1 'post-build=' | cut -d= -f2)
SECURITY_PATCH=$(strings metadata.bin | grep -m1 'security-patch-level=' | cut -d= -f2)

if [ -z "$FINGERPRINT" ] || [ -z "$SECURITY_PATCH" ]; then
  echo "❌ Failed to extract fingerprint or patch level"
  exit 1
fi

echo "✅ Fingerprint: $FINGERPRINT"
echo "🔐 Patch: $SECURITY_PATCH"

echo "📝 Writing pif.json..."

cat <<EOF | tee pif.json
{
  "MANUFACTURER": "Google",
  "MODEL": "$MODEL",
  "FINGERPRINT": "$FINGERPRINT",
  "PRODUCT": "$PRODUCT",
  "DEVICE": "$DEVICE",
  "SECURITY_PATCH": "$SECURITY_PATCH",
  "DEVICE_INITIAL_SDK_INT": "34"
}
EOF

item "Dumping values to minimal pif2.json ...";
cat <<EOF | tee pif2.json;
{
    "MANUFACTURER": "Google",
    "MODEL": "$MODEL",
    "FINGERPRINT": "$FINGERPRINT",
    "BRAND": "$(echo "$FINGERPRINT" | cut -d '/' -f 1)",
    "PRODUCT": "$PRODUCT",
    "DEVICE": "$DEVICE",
    "VERSION.RELEASE": "$(echo "$FINGERPRINT" | cut -d ':' -f 2 | cut -d '/' -f 1)",
    "ID": "$(echo "$FINGERPRINT" | cut -d '/' -f 4)",
    "VERSION.SECURITY_PATCH": "$SECURITY_PATCH",
    "VERSION.DEVICE_INITIAL_SDK_INT": "34"
}
EOF

# Remove temporary HTML files if they exist
find . -maxdepth 1 -name "*_HTML" -exec rm {} \;
find . -maxdepth 1 -name "*_METADATA" -exec rm {} \;

# Add fields to chiteroman.json
cp pif.json chiteroman.json

# Add fields to gms_certified_props.json
cp pif2.json gms_certified_props.json

# Migrate data using the migrate_osmosis.sh script and output to osmosis.json
./migrate_osmosis.sh -a pif.json device_osmosis.json
sed -i 's|//.*||g; /^[[:space:]]*$/d' device_osmosis.json
jq '(.spoofBuild, .spoofVendingFinger, .spoofProps) = "1" | (.spoofProvider, .spoofSignature, .spoofVendingSdk) = "0"' device_osmosis.json > tmp.json && mv tmp.json device_osmosis.json


./migrate_osmosis.sh -a pif.json osmosis.json
sed -i 's|//.*||g; /^[[:space:]]*$/d' osmosis.json
jq '(.spoofBuild, .spoofProvider, .spoofVendingFinger, .spoofProps) = "1" | (.spoofSignature, .spoofVendingSdk) = "0"' osmosis.json > tmp.json && mv tmp.json osmosis.json

# Delete the previously created pif.json as it's no longer needed
rm pif.json
rm pif2.json

# Remove any backup files with the .bak extension if they exist
find . -maxdepth 1 -name "*.bak" -exec rm {} \;
