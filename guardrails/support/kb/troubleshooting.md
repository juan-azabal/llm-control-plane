# Troubleshooting — AcmeCo Analytics Platform

## Common Issues

### Dashboard not loading
1. Clear browser cache and cookies
2. Try a different browser (Chrome, Firefox, Safari supported)
3. Check system status at status.acmeco.com
4. Disable browser extensions that may block JavaScript

### CSV import failing
- Maximum file size: 100MB
- Supported encodings: UTF-8 only
- Required: header row in first line
- Date format must be YYYY-MM-DD or MM/DD/YYYY
- Columns with special characters in names are not supported

### Data not updating
- Free plan: data refreshes every 1 hour
- Pro/Enterprise: data refreshes every 15 minutes
- Manual refresh: click the refresh icon on the dashboard
- If data is stale for more than 2 hours, contact support

### Cannot log in
1. Reset password at app.acmeco.com/reset-password
2. Check if account is active (admin can verify)
3. Enterprise SSO users: contact your IT admin for SSO configuration
4. Two-factor authentication issues: use backup codes

### Export not working
- PDF exports may take up to 5 minutes for large datasets
- CSV exports limited to 1 million rows
- Export queue: maximum 3 concurrent exports per user
- Check Downloads folder — exports don't open automatically
