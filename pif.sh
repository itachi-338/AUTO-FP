#!/bin/bash

# Print a message indicating the start of the crawling process
wget -q -O PIXEL_VERSIONS_HTML --no-check-certificate "https://developer.android.com/about/versions" 2>&1 || exit 1;
wget -q -O PIXEL_LATEST_HTML --no-check-certificate "$(grep -o 'https://developer.android.com/about/versions/.*[0-9]"' PIXEL_VERSIONS_HTML | sort -ru | cut -d\" -f1 | head -n1 | tail -n1)" 2>&1 || exit 1;
wget -q -O PIXEL_FI_HTML --no-check-certificate "https://developer.android.com$(grep -o 'href=".*download.*"' PIXEL_LATEST_HTML | grep 'qpr' | cut -d\" -f2 | head -n1 | tail -n1)" 2>&1 || exit 1;
wget -q -O PIXEL_OTA_HTML --no-check-certificate "https://developer.android.com$(grep -o 'href=".*download-ota.*"' PIXEL_LATEST_HTML | grep 'qpr' | cut -d\" -f2 | head -n1 | tail -n1)" 2>&1 || exit 1;
SRC=FI; [ "$(grep 'tr id=' PIXEL_FI_HTML | sed 's;.*<tr id="\(.*\)">.*;\1;' | wc -w)" -lt "$(grep 'tr id=' PIXEL_OTA_HTML | sed 's;.*<tr id="\(.*\)">.*;\1;' | wc -w)" ] && SRC=OTA;
MODEL_LIST="$(grep -A1 'tr id=' PIXEL_${SRC}_HTML | grep 'td' | sed 's;.*<td>\(.*\)</td>.*;\1;')";
PRODUCT_LIST="$(grep 'tr id=' PIXEL_${SRC}_HTML | sed 's;.*<tr id="\(.*\)">.*;\1_beta;')";
echo "$PRODUCT_LIST" | wc -w;

if [ "$FORCE_MATCH" ]; then
  DEVICE="$(getprop ro.product.device)";
  case "$(echo ' '$PRODUCT_LIST' ')" in
    *" ${DEVICE}_beta "*)
      MODEL="$(getprop ro.product.model)";
      PRODUCT="${DEVICE}_beta";
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
    DEVICE="$(echo "$PRODUCT" | sed 's/_beta//')";
  }
  set_random_beta;
fi;
echo "$MODEL ($PRODUCT)";

item "Crawling Android Flash Tool for latest Pixel Canary build info ...";
wget -q -O PIXEL_FLASH_HTML --no-check-certificate "https://flash.android.com/" 2>&1 || exit 1;
wget -q -O PIXEL_STATION_JSON --header "Referer: https://flash.android.com" --no-check-certificate "https://content-flashstation-pa.googleapis.com/v1/builds?product=$PRODUCT&key=$(grep -o '<body data-client-config=.*' PIXEL_FLASH_HTML | cut -d\; -f2 | cut -d\& -f1)" 2>&1 || exit 1;
tac PIXEL_STATION_JSON | grep -m1 -A13 '"canary": true' > PIXEL_CANARY_JSON;
ID="$(grep 'releaseCandidateName' PIXEL_CANARY_JSON | cut -d\" -f4)";
INCREMENTAL="$(grep 'buildId' PIXEL_CANARY_JSON | cut -d\" -f4)";
[ -z "$ID" -o -z "$INCREMENTAL" ] && die "Failed to extract build info from JSON";
echo "Android $(grep 'releaseTrackVersionName' PIXEL_CANARY_JSON | cut -d\" -f4)";

FI="$(grep 'factoryImageDownloadUrl' PIXEL_CANARY_JSON | cut -d\" -f4)";
FI_HOST="$(echo "$FI" | sed 's;^.*://\(.*\)$;\1;' | cut -d/ -f1)";
FI_PATH="/$(echo "$FI" | sed 's;^.*://\(.*\)$;\1;' | cut -d/ -f2-)";
if [ "$FI" -a "$FI_HOST" -a "$FI_PATH" ]; then
  nc $FI_HOST 80 <<EOF | tr -d '\r' > PIXEL_ZIP_HEADERS;
HEAD $FI_PATH HTTP/1.1
Host: $FI_HOST
Connection: close

EOF
else
  warn "Failed to extract Factory Image URL from JSON";
fi;
if [ ! -s PIXEL_ZIP_HEADERS ] || ! grep -q 'Last-Modified' PIXEL_ZIP_HEADERS; then
  wget -q -S --spider -o PIXEL_ZIP_HEADERS --no-check-certificate "$FI" 2>&1;
fi;
if [ -f PIXEL_ZIP_HEADERS ] && grep -q 'Last-Modified' PIXEL_ZIP_HEADERS; then
  CANARY_REL_DATE="$(date -D '%a, %d %b %Y %H:%M:%S %Z' -d "$(grep -o 'Last-Modified.*' PIXEL_ZIP_HEADERS | cut -d\  -f2-)" '+%Y-%m-%d')";
  CANARY_EXP_DATE="$(date -D '%s' -d "$(($(date -D '%Y-%m-%d' -d "$CANARY_REL_DATE" '+%s') + 60 * 60 * 24 * 7 * 6))" '+%Y-%m-%d')";
  echo "Canary Released: $CANARY_REL_DATE \
    \nEstimated Expiry: $CANARY_EXP_DATE";
else
  warn "Failed to determine Release Date from HTTP headers";
  CANARY_REL_DATE="Unknown";
  CANARY_EXP_DATE="Unknown";
fi;

item "Crawling Pixel Update Bulletins for corresponding security patch level ...";
CANARY_ID="$(grep '"id"' PIXEL_CANARY_JSON | sed -e 's;.*canary-\(.*\)".*;\1;' -e 's;^\(.\{4\}\);\1-;')";
[ -z "$CANARY_ID" ] && die "Failed to extract build info from JSON";
wget -q -O PIXEL_SECBULL_HTML --no-check-certificate "https://source.android.com/docs/security/bulletin/pixel" 2>&1 || exit 1;
SECURITY_PATCH="$(grep "<td>$CANARY_ID" PIXEL_SECBULL_HTML | sed 's;.*<td>\(.*\)</td>;\1;')";
if [ -z "$SECURITY_PATCH" ]; then
  warn "Failed to determine exact security patch level from Pixel Update Bulletins";
  item "Assuming probable security patch level from Canary build info ...";
  SECURITY_PATCH="${CANARY_ID}-05";
fi;
echo "$SECURITY_PATCH";

item "Dumping values to minimal pif.json ...";
cat <<EOF | tee pif.json;
{
  "MANUFACTURER": "Google",
  "MODEL": "$MODEL",
  "FINGERPRINT": "google/$PRODUCT/$DEVICE:CANARY/$ID/$INCREMENTAL:user/release-keys",
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
    "FINGERPRINT": "google/$PRODUCT/$DEVICE:CANARY/$ID/$INCREMENTAL:user/release-keys",
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
