#!/bin/sh

echo "Crawling Android Developers for latest Pixel Beta (A17 Support) ..."

# 1. Get the latest version number (e.g., 17) and its specific download page
wget -q -O PIXEL_VERSIONS_HTML --no-check-certificate https://developer.android.com/about/versions 2>&1 || exit 1;
LATEST_VER=$(grep -o 'https://developer.android.com/about/versions/[0-9]\{2\}' PIXEL_VERSIONS_HTML | sort -Vru | head -n1 | grep -o '[0-9]\{2\}')
echo "Detected Latest Version: Android $LATEST_VER"

# 2. Fetch the OTA page for that version
wget -q -O PIXEL_OTA_HTML --no-check-certificate "https://developer.android.com/about/versions/$LATEST_VER/download-ota" 2>&1 || exit 1;

# 3. Extract Version Info (Support for 'Baklava' / A17)
ANDROID_VER=$(grep -m1 -oE 'tooltip>Android [0-9]+' PIXEL_OTA_HTML | cut -d\  -f2)
BETA_VER=$(grep -oE 'tooltip>(QPR|Beta|Developer Preview).*[0-9]' PIXEL_OTA_HTML | cut -d\> -f2 | head -n1)
echo "Found: Android $ANDROID_VER ($BETA_VER)"

# 4. Handle Release Dates
LONG_REL_DATE="$(grep -m1 -A1 'Release date' PIXEL_OTA_HTML | tail -n1 | sed 's;.*<td>\(.*\)</td>.*;\1;')";
if [ -z "$LONG_REL_DATE" ] || echo "$LONG_REL_DATE" | grep -q "tr"; then
  # Fallback if date is missing from OTA page
  wget -q -O PIXEL_DL_HTML --no-check-certificate "https://developer.android.com/about/versions/$LATEST_VER/download" 2>&1 || exit 1;
  LONG_REL_DATE="$(grep -m1 -A1 'Release date' PIXEL_DL_HTML | tail -n1 | sed 's;.*<td>\(.*\)</td>.*;\1;')";
fi;

BETA_REL_DATE="$(date -d "$LONG_REL_DATE" '+%Y-%m-%d' 2>/dev/null || echo "Unknown")";
echo "Beta Released: $BETA_REL_DATE"

# 5. Build Device and OTA Lists
# We extract the full dl.google.com URLs directly
OTA_FULL_URLS="$(grep -o 'https://dl.google.com/android/repository/ota/google/[^"]*.zip' PIXEL_OTA_HTML)"
MODEL_LIST="$(grep -A1 'tr id=' PIXEL_OTA_HTML | grep 'td' | sed 's;.*<td>\(.*\)</td>;\1;')";
# Extract product codenames from the 'tr id'
PRODUCT_LIST="$(grep -o '<tr id="[^"]*">' PIXEL_OTA_HTML | cut -d\" -f2)"

# 6. Device Selection Logic
if [ "$FORCE_MATCH" ]; then
  DEVICE="$(getprop ro.product.device)";
  MODEL="$(getprop ro.product.model)";
  # Find the URL that contains the device codename
  OTA="$(echo "$OTA_FULL_URLS" | grep -i "$DEVICE" | head -n1)"
  PRODUCT="${DEVICE}_beta"
else
  # Random selection for generic dumping
  list_count=$(echo "$PRODUCT_LIST" | wc -l)
  list_rand=$(( (RANDOM % list_count) + 1 ))
  
  DEVICE=$(echo "$PRODUCT_LIST" | sed -n "${list_rand}p")
  MODEL=$(echo "$MODEL_LIST" | sed -n "${list_rand}p")
  OTA=$(echo "$OTA_FULL_URLS" | grep -i "$DEVICE" | head -n1)
  PRODUCT="${DEVICE}_beta"
fi

echo "Selected: $MODEL ($PRODUCT)"
echo "OTA URL: $OTA"

# 7. Extract Metadata (FINGERPRINT & SECURITY_PATCH)
# Using a 16KB range request is much more reliable than ulimit for zips
wget -q --header="Range: bytes=0-16384" -O PIXEL_ZIP_METADATA --no-check-certificate "$OTA" 2>/dev/null;

FINGERPRINT="$(grep -am1 'post-build=' PIXEL_ZIP_METADATA 2>/dev/null | cut -d= -f2)";
SECURITY_PATCH="$(grep -am1 'security-patch-level=' PIXEL_ZIP_METADATA 2>/dev/null | cut -d= -f2)";

if [ -z "$FINGERPRINT" ]; then
  echo "Error: Could not extract metadata. The ZIP structure may have changed or the link is invalid.";
  exit 1;
fi;

# 8. Generate pif.json (A17 is SDK 37)
cat <<EOF | tee pif.json;
{
  "MANUFACTURER": "Google",
  "MODEL": "$MODEL",
  "FINGERPRINT": "$FINGERPRINT",
  "PRODUCT": "$PRODUCT",
  "DEVICE": "$DEVICE",
  "SECURITY_PATCH": "$SECURITY_PATCH",
  "DEVICE_INITIAL_SDK_INT": "37"
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
    "VERSION.DEVICE_INITIAL_SDK_INT": "37"
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
