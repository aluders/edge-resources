#!/bin/bash

echo "=== deSEC Restricted Token Generator ==="

# --- Login credentials ---
read -p "Email: " EMAIL
read -s -p "Password: " PASSWORD
echo ""

# --- Login and extract main auth token ---
echo "Logging into deSEC..."
LOGIN_RESPONSE=$(curl -s -X POST https://desec.io/api/v1/auth/login/ \
  --header "Content-Type: application/json" \
  --data "{\"email\": \"$EMAIL\", \"password\": \"$PASSWORD\"}")

AUTH_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.token')

if [[ "$AUTH_TOKEN" == "null" || -z "$AUTH_TOKEN" ]]; then
  echo "❌ Login failed. Response:"
  echo "$LOGIN_RESPONSE"
  exit 1
fi

echo "✔ Login successful."


# --- Ask for domain + subdomain ---
read -p "Domain (example: example.com): " DOMAIN
read -p "Subdomain (just the label, example: test): " SUBNAME


# --- Extract TLD (last segment of domain) ---
TLD="${DOMAIN##*.}"

# --- Generate token name following your rule ---
TOKEN_NAME="${SUBNAME}-${TLD}"

echo "Generated token name: $TOKEN_NAME"
echo "Creating restricted token..."


# --- Create restricted token ---
TOKEN_CREATE_RESPONSE=$(curl -s -X POST https://desec.io/api/v1/auth/tokens/ \
  --header "Authorization: Token $AUTH_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"name\": \"$TOKEN_NAME\"}")

RESTRICTED_TOKEN=$(echo "$TOKEN_CREATE_RESPONSE" | jq -r '.token')
TOKEN_ID=$(echo "$TOKEN_CREATE_RESPONSE" | jq -r '.id')

if [[ -z "$TOKEN_ID" || "$TOKEN_ID" == "null" ]]; then
  echo "❌ Failed to create restricted token:"
  echo "$TOKEN_CREATE_RESPONSE"
  exit 1
fi

echo "✔ Restricted token created. ID: $TOKEN_ID"


# --- Default policy ---
echo "Creating default policy..."
curl -s -X POST https://desec.io/api/v1/auth/tokens/$TOKEN_ID/policies/rrsets/ \
  --header "Authorization: Token $AUTH_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{"domain": null, "subname": null, "type": null}' > /dev/null
echo "✔ Default policy created."


# --- A record policy ---
echo "Creating A-record policy ($SUBNAME.$DOMAIN)..."
curl -s -X POST https://desec.io/api/v1/auth/tokens/$TOKEN_ID/policies/rrsets/ \
  --header "Authorization: Token $AUTH_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"domain\": \"$DOMAIN\", \"subname\": \"$SUBNAME\", \"type\": \"A\", \"perm_write\": true}" > /dev/null
echo "✔ A record policy created."


# --- AAAA record policy ---
echo "Creating AAAA-record policy ($SUBNAME.$DOMAIN)..."
curl -s -X POST https://desec.io/api/v1/auth/tokens/$TOKEN_ID/policies/rrsets/ \
  --header "Authorization: Token $AUTH_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"domain\": \"$DOMAIN\", \"subname\": \"$SUBNAME\", \"type\": \"AAAA\", \"perm_write\": true}" > /dev/null
echo "✔ AAAA record policy created."


# --- Done ---
echo ""
echo "=============================================="
echo " Restricted Token Successfully Created!"
echo " Token name: $TOKEN_NAME"
echo " Domain:     $DOMAIN"
echo " Subdomain:  $SUBNAME"
echo ""
echo " Use this token for DDNS updates:"
echo ""
echo "$RESTRICTED_TOKEN"
echo "=============================================="
echo ""
