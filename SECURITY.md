# Security Policy

This document describes how security vulnerabilities are handled for the
**Matomo-for-AzureAppService** container project.

---

## Supported Versions

Only actively maintained major versions receive security fixes.

| Version | Supported               |
|-------- | ------------------------|
| 5.x     | :white_check_mark: Yes  |
| 4.x     | :white_check_mark: Yes  |
| 3.x     | :x: No                  |
| < 3.x   | :x: No                  |

---

## Reporting a Vulnerability

If you discover a vulnerability—including OS package issues, PHP/Apache
problems, exposed secrets, misconfigurations, or any behavior that may
affect security—please report it privately.

### 🔐 Private GitHub Security Advisory (Recommended)

Please create a private advisory:

👉 https://github.com/umaxiaotian/Matomo-for-AzureAppService/security/advisories/new

This creates a secure discussion space.

### ✉️ Email (Alternative)

If you prefer email, send reports to:

📧 **securityml@obata.me**

Please include:

- Description of the issue  
- Steps to reproduce  
- Impact assessment (if known)  
- Affected version(s) or container tag(s)  
- Suggested mitigation or patch (optional)  

---

## Security Issue Handling Process

We follow a structured response timeline:

- 🕒 **Acknowledgement:** within **72 hours**  
- 🔍 **Initial Investigation:** within **5 business days**  
- 🛠️ **Fix Development:** typically within **30 days**  
- 📢 **Coordinated Disclosure:** after the fix is published  

Your identity and report contents will be treated confidentially.

---

## Severity Levels

We categorize issues using common industry standards:

| Severity | Description |
|---------|-------------|
| CRITICAL | RCE, major secret exposure, full auth bypass |
| HIGH     | Privilege escalation, critical misconfigurations |
| MEDIUM   | Sensitive data leaks, unsafe defaults |
| LOW      | Minor or low-impact issues |

---

## Automated Security Monitoring

This repository runs automated scanning:

### ✔ Daily full scan of **all GHCR tags**
Using Trivy with:
- Vulnerability scanning (HIGH/CRITICAL)
- Secret scanning (detects exposed keys)
- Misconfiguration scanning (SSH, Apache, PHP, Dockerfile)

### ✔ Auto-generated GitHub Issues
- One issue per tag
- Automatically updated with new findings
- Labels: `container-security`, `security`, `automated`

### ✔ Build/Test workflow scanning
Every new image built in CI is validated:
- HIGH/CRITICAL vulnerabilities → **build fails**
- Secrets/Misconfig detections → reported in logs

---

## Responsible Disclosure Policy

Please **do not publicly disclose** vulnerabilities before:

1. Reporting privately  
2. Allowing time for analysis & fixes  
3. Coordinating disclosure timing with maintainers  

We deeply appreciate responsible security research.

---

## Thank You

Thank you for helping secure **Matomo-for-AzureAppService**.  
Your contributions make this project safer for everyone.
