#!/bin/sh
# Example quota probe — uses config values from Settings
# $TOUCHQUOTA_API_KEY and $TOUCHQUOTA_BASE_URL are injected automatically
#
# Replace this with real API calls:
#   curl -s -H "Authorization: Bearer $TOUCHQUOTA_API_KEY" "$TOUCHQUOTA_BASE_URL/usage"

# For demo purposes, return mock data
cat <<'EOF'
{
    "quotas": [
        {
            "type": "session",
            "percentRemaining": 85.0,
            "resetsAt": "2026-03-17T23:00:00Z"
        },
        {
            "type": "weekly",
            "percentRemaining": 62.0,
            "resetsAt": "2026-03-21T00:00:00Z"
        }
    ],
    "account": {
        "email": "user@example.com",
        "tier": "Pro"
    }
}
EOF
