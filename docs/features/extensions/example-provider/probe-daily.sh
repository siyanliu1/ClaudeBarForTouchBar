#!/bin/sh
# Example daily usage probe — uses config values from Settings
# $TOUCHQUOTA_API_KEY and $TOUCHQUOTA_BASE_URL are injected automatically
#
# Replace with real data:
#   curl -s -H "Authorization: Bearer $TOUCHQUOTA_API_KEY" "$TOUCHQUOTA_BASE_URL/daily"

TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -v-1d +%Y-%m-%d)

cat <<EOF
{
    "dailyUsage": {
        "today": {
            "totalCost": 10.26,
            "totalTokens": 8300000,
            "workingTime": 454.0,
            "date": "$TODAY",
            "sessionCount": 12
        },
        "previous": {
            "totalCost": 711.84,
            "totalTokens": 8693000,
            "workingTime": 42514.0,
            "date": "$YESTERDAY",
            "sessionCount": 45
        }
    }
}
EOF
