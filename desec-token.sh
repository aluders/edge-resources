#!/bin/bash

echo "=== deSEC Restricted Token Generator ==="

################################################################################
# LOGIN
################################################################################

# --- Login credentials ---
read -p "Email: " EMAIL
read -s -p "Password: " PASSWORD
echo ""

# --- Safely build compact JSON using jq ($ARGS.named prevents any quoting issues) ---
LOGIN_PAYLOAD=$(jq -c -n --arg email "$EMAIL" --arg password "$PASSWORD" '$ARGS.named')

echo "Logging into deSEC..."

LOGIN_RESPONSE=$(curl -s -X POST https://desec.io/api/v1/auth/login/ \
  --header "Content-Type: application/json" \
  --data "$LOGIN_PAYLOAD")

AUTH_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.token')

if [[ "$AUTH_TOKEN" == "null" || -z "$AUTH_TOKEN" ]]; then
  echo "❌ Login failed. Response:"
  echo "$LOGIN_RESPONSE"
  exit 1
fi

echo "✔ Login successful."


################################################################################
# SINGLE DOMAIN INPUT
################################################################################

# Example input: test.example.com
read -p "Full domain (example: test.example.com): " FULLDOMAIN

# Extract subname (before the first dot)
SUBNAME="${FULLDOMAIN%%.*}"

# Extract the domain (after the first dot)
DOMAIN="${FULLDOMAIN#*.}"

# Extract TLD (after the last dot)
TLD="${DOMAIN##*.}"

# Auto-generate token name per your rule
TOKEN_NAME="${SUBNAME}-${TLD}"

echo ""
echo "Parsed domain:"
echo "  Subname: $SUBNAME"
echo "  Domain:  $DOMAIN"
echo "  TLD:     $TLD"
echo "Generated token name: $TOKEN_NAME"
echo ""


################################################################################
# CREATE TOKEN
################################################################################

TOKEN_CREATE_PAYLOAD=$(jq -c -n --arg name "$TOKEN_NAME" '$ARGS.named')

echo "Creating restricted token..."

TOKEN_CREATE_RESPONSE=$(curl -s -X POST https://desec.io/api/v1/auth/tokens/ \
  --header "Authorization: Token $AUTH_TOKEN" \
  --header "Content-Type: application/json" \
  --data "$TOKEN_CREATE_PAYLOAD")

RESTRICTED_TOKEN=$(echo "$TOKEN_CREATE_RESPONSE" | jq -r '.token')
TOKEN_ID=$(echo "$TOKEN_CREATE_RESPONSE" | jq -r '.id')

if [[ "$TOKEN_ID" == "null" || -z "$TOKEN_ID" ]]; then
  echo "❌ Failed to create restricted token:"
  echo "$TOKEN_CREATE_RESPONSE"
  exit 1
fi

echo "✔ Restricted token created. ID: $TOKEN_ID"


################################################################################
# DEFAULT POLICY
################################################################################

echo "Creating default policy..."

DEFAULT_POLICY_PAYLOAD=$(jq -c -n \
  '{domain: null, subname: null, type: null}')

curl -s -X POST https://desec.io/api/v1/auth/tokens/'"$TOKEN_ID"'/policies/rrsets/ \
  --header "Authorization: Token $AUTH_TOKEN" \
  --header "Content-Type: application/json" \
  --data "$DEFAULT_POLICY_PAYLOAD" > /dev/null

echo "✔ Default policy created."


################################################################################
# A RECORD POLICY
################################################################################

echo "Creating A-record policy for $FULLDOMAIN ..."

A_POLICY_PAYLOAD=$(jq -c -n \
  --arg domain "$DOMAIN" \
  --arg subname "$SUBNAME" \
  '{domain: $domain, subname: $subname, type: "A", perm_write: true}')

curl -s -X POST https://desec.io/api/v1/auth/tokens/'"$TOKEN_ID"'/policies/rrsets/ \
  --header "Authorization: Token $AUTH_TOKEN" \
  --header "Content-Type: application/json" \
  --data "$A_POLICY_PAYLOAD" > /dev/null

echo "✔ A record policy created."


################################################################################
# AAAA RECORD POLICY
################################################################################

echo "Creating AAAA-record policy for $FULLDOMAIN ..."

AAAA_POLICY_PAYLOAD=$(jq -c -n \
  --arg domain "$DOMAIN" \
  --arg subname "$SUBNAME" \
  '{domain: $domain, subname: $subname, type: "AAAA", perm_write: true}')

curl -s -X POST https://desec.io/api/v1/auth/tokens/'"$TOKEN_ID"'/policies/rrsets/ \
  --header "Authorization: Token $AUTH_TOKEN" \
  --header "Content-Type: application/json" \
  --data "$AAAA_POLICY_PAYLOAD" > /dev/null

echo "✔ AAAA record policy created."


################################################################################
# FINISH
################################################################################

echo ""
echo "=============================================="
echo " Restricted Token Successfully Created!"
echo ""
echo " Token name:   $TOKEN_NAME"
echo " Full domain:  $FULLDOMAIN"
echo " Domain:       $DOMAIN"
echo " Subname:      $SUBNAME"
echo ""
echo " Use this token for DDNS updates:"
echo ""
echo "$RESTRICTED_TOKEN"
echo "=============================================="
echo ""
