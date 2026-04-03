#!/bin/bash

# Print a message indicating the start of the crawling process
echo "Crawling Android Developers for latest Pixel Beta ..."

wget -q -O PIXEL_VERSIONS_HTML --no-check-certificate https://developer.android.com/about/versions 2>&1 || exit 1;
wget -q -O PIXEL_LATEST_HTML --no-check-certificate $(grep -o 'https://developer.android.com/about/versions/.*[0-9]"' PIXEL_VERSIONS_HTML | sort -ru | cut -d\" -f1 | head -n1 | tail -n1) 2>&1 || exit 1;
wget -q -O PIXEL_OTA_HTML --no-check-certificate https://developer.android.com$(grep -o 'href=".*download-ota.*"' PIXEL_LATEST_HTML | grep 'qpr' | cut -d\" -f2 | head -n1 | tail -n1) 2>&1 || exit 1;
echo "$(grep -m1 -oE 'tooltip>Android .*[0-9]' PIXEL_OTA_HTML | cut -d\> -f2) $(grep -oE 'tooltip>QPR.* Beta' PIXEL_OTA_HTML | cut -d\> -f2 | head -n1 | tail -n1)";

if grep -q 'Release date' PIXEL_OTA_HTML; then
  LONG_REL_DATE="$(grep -m1 -A1 'Release date' PIXEL_OTA_HTML)";
else
  wget -q -O PIXEL_FI_HTML --no-check-certificate https://developer.android.com$(grep -o 'href=".*download.*"' PIXEL_LATEST_HTML | grep 'qpr' | cut -d\" -f2 | head -n1 | tail -n1) 2>&1 || exit 1;
  LONG_REL_DATE="$(grep -m1 -A1 'Release date' PIXEL_FI_HTML)";
fi;

BETA_REL_DATE="$(date -D '%B %e, %Y' -d "$(echo $LONG_REL_DATE | tail -n1 | sed 's;.*<td>\(.*\)</td>.*;\1;')" '+%Y-%m-%d')";
BETA_EXP_DATE="$(date -D '%s' -d "$(($(date -D '%Y-%m-%d' -d "$BETA_REL_DATE" '+%s') + 60 * 60 * 24 * 7 * 6))" '+%Y-%m-%d')";
echo "Beta Released: $BETA_REL_DATE \
  \nEstimated Expiry: $BETA_EXP_DATE";

MODEL_LIST="$(grep -A1 'tr id=' PIXEL_OTA_HTML | grep 'td' | sed 's;.*<td>\(.*\)</td>;\1;')";
PRODUCT_LIST="$(grep 'tr id=' PIXEL_OTA_HTML | sed 's;.*<tr id="\(.*\)">;\1_beta;')";
OTA_LIST="$(grep -o '>.*_beta.*</button' PIXEL_OTA_HTML | sed 's;.*>\(.*\)</button;\1;')";
OTA_PREFIX="$(grep -m1 'ota/.*_beta' PIXEL_OTA_HTML | cut -d\" -f2 | sed 's;\(.*\)/.*;\1;')";

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
item "Selecting Pixel Beta device ...";
if [ -z "$PRODUCT" ]; then
  set_random_beta() {
    local list_count="$(echo "$MODEL_LIST" | wc -l)";
    local list_rand="$((RANDOM % $list_count + 1))";
    local IFS=$'\n';
    set -- $MODEL_LIST;
    MODEL="$(eval echo \${$list_rand})";
    set -- $PRODUCT_LIST;
    PRODUCT="$(eval echo \${$list_rand})";
    set -- $OTA_LIST;
    OTA="$OTA_PREFIX/$(eval echo \${$list_rand})";
    DEVICE="$(echo "$PRODUCT" | sed 's/_beta//')";
  }
  set_random_beta;
fi;
echo "$MODEL ($PRODUCT)";

(ulimit -f 2; wget -q -O PIXEL_ZIP_METADATA --no-check-certificate $OTA) 2>/dev/null;
FINGERPRINT="$(grep -am1 'post-build=' PIXEL_ZIP_METADATA 2>/dev/null | cut -d= -f2)";
SECURITY_PATCH="$(grep -am1 'security-patch-level=' PIXEL_ZIP_METADATA 2>/dev/null | cut -d= -f2)";
if [ -z "$FINGERPRINT" -o -z "$SECURITY_PATCH" ]; then
  case "$(getprop ro.product.cpu.abi)" in
    armeabi-v7a|x86) [ "$BUSYBOX" ] && ISBB32MSG=", install wget2";;
  esac;
  echo "\nError: Failed to extract information from metadata$ISBB32MSG!";
  exit 1;
fi;

item "Dumping values to minimal pif.json ...";
cat <<EOF | tee pif.json;
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
    "VERSION.DEVICE_INITIAL_SDK_INT": "32"
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
