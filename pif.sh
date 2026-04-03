#!/bin/sh

echo "Crawling Android Developers for latest Pixel Beta (A17+ Support) ..."

# 1. Fetch main versions page and find the highest numeric version (e.g., 17)
wget -q -O PIXEL_VERSIONS_HTML --no-check-certificate https://developer.android.com/about/versions 2>&1 || exit 1;
LATEST_VER_URL=$(grep -o 'https://developer.android.com/about/versions/[0-9]\{2\}' PIXEL_VERSIONS_HTML | sort -Vru | head -n1)

wget -q -O PIXEL_LATEST_HTML --no-check-certificate "$LATEST_VER_URL" 2>&1 || exit 1;

# 2. Find the OTA page. Removed the strict 'qpr' requirement to allow early Betas.
OTA_RELATIVE_URL=$(grep -o 'href="[^"]*download-ota[^"]*"' PIXEL_LATEST_HTML | cut -d\" -f2 | head -n1)
wget -q -O PIXEL_OTA_HTML --no-check-certificate "https://developer.android.com$OTA_RELATIVE_URL" 2>&1 || exit 1;

# 3. Extract Version Info
# Updated regex to be more flexible with Android version naming
ANDROID_VER=$(grep -m1 -oE 'tooltip>Android [0-9]+' PIXEL_OTA_HTML | cut -d\  -f2)
BETA_VER=$(grep -oE 'tooltip>(QPR|Beta|Developer Preview).*[0-9]' PIXEL_OTA_HTML | cut -d\> -f2 | head -n1)
echo "Found: Android $ANDROID_VER ($BETA_VER)"

# 4. Handle Release Dates
if grep -q 'Release date' PIXEL_OTA_HTML; then
  LONG_REL_DATE="$(grep -m1 -A1 'Release date' PIXEL_OTA_HTML | tail -n1 | sed 's;.*<td>\(.*\)</td>.*;\1;')";
else
  # Fallback to the 'get' or 'download' page if date is missing from OTA page
  GET_URL=$(grep -o 'href="[^"]*download[^"]*"' PIXEL_LATEST_HTML | head -n1 | cut -d\" -f2)
  wget -q -O PIXEL_FI_HTML --no-check-certificate "https://developer.android.com$GET_URL" 2>&1 || exit 1;
  LONG_REL_DATE="$(grep -m1 -A1 'Release date' PIXEL_FI_HTML | tail -n1 | sed 's;.*<td>\(.*\)</td>.*;\1;')";
fi;

# Date formatting (Using standard -d for compatibility)
BETA_REL_DATE="$(date -d "$LONG_REL_DATE" '+%Y-%m-%d')";
BETA_EXP_DATE="$(date -d "$BETA_REL_DATE + 42 days" '+%Y-%m-%d')";
echo "Beta Released: $BETA_REL_DATE | Estimated Expiry: $BETA_EXP_DATE";

# 5. Build Device Lists
MODEL_LIST="$(grep -A1 'tr id=' PIXEL_OTA_HTML | grep 'td' | sed 's;.*<td>\(.*\)</td>;\1;')";
PRODUCT_LIST="$(grep 'tr id=' PIXEL_OTA_HTML | sed 's;.*<tr id="\(.*\)">;\1_beta;')";
OTA_LIST="$(grep -o '>.*_beta.*</button' PIXEL_OTA_HTML | sed 's;.*>\(.*\)</button;\1;')";
OTA_PREFIX="$(grep -m1 'ota/.*_beta' PIXEL_OTA_HTML | cut -d\" -f2 | sed 's;\(.*\)/.*;\1;')";

# 6. Device Selection
if [ "$FORCE_MATCH" ]; then
  DEVICE="$(getprop ro.product.device)";
  case "$(echo ' '$PRODUCT_LIST' ')" in
    *" ${DEVICE}_beta "*)
      MODEL="$(getprop ro.product.model)";
      PRODUCT="${DEVICE}_beta";
      OTA="$OTA_PREFIX/$(echo "$OTA_LIST" | grep "$PRODUCT")";
    ;;
  esac;
fi;

if [ -z "$PRODUCT" ]; then
  set_random_beta() {
    local list_count="$(echo "$MODEL_LIST" | wc -l)";
    local list_rand="$((RANDOM % $list_count + 1))";
    MODEL="$(echo "$MODEL_LIST" | sed -n "${list_rand}p")";
    PRODUCT="$(echo "$PRODUCT_LIST" | sed -n "${list_rand}p")";
    OTA_FILE="$(echo "$OTA_LIST" | sed -n "${list_rand}p")";
    OTA="$OTA_PREFIX/$OTA_FILE";
    DEVICE="$(echo "$PRODUCT" | sed 's/_beta//')";
  }
  set_random_beta;
fi;
echo "Selected: $MODEL ($PRODUCT)";

# 7. Extract Fingerprint & Security Patch
(ulimit -f 2; wget -q -O PIXEL_ZIP_METADATA --no-check-certificate "https://developer.android.com/$OTA") 2>/dev/null;
FINGERPRINT="$(grep -am1 'post-build=' PIXEL_ZIP_METADATA 2>/dev/null | cut -d= -f2)";
SECURITY_PATCH="$(grep -am1 'security-patch-level=' PIXEL_ZIP_METADATA 2>/dev/null | cut -d= -f2)";

if [ -z "$FINGERPRINT" ]; then
  echo "Error: Could not extract metadata from OTA link.";
  exit 1;
fi;

# 8. Generate pif.json
# Note: For Android 17, the SDK Level is 37.
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
