# ============================================================================
# ShadowCrypt Koyeb Deployment - Quick Reference Checklist
# ============================================================================

## 📋 PRE-DEPLOYMENT CHECKLIST

### Environment Setup
- [ ] Windows PowerShell or WSL2 available
- [ ] Docker Desktop installed and running (`docker version`)
- [ ] Go 1.21+ installed (`go version`)
- [ ] Git configured (`git config --global user.name`)
- [ ] Koyeb CLI installed (`koyeb version`)
- [ ] Koyeb API token ready (from dashboard)
- [ ] GitHub account with repository created

### Configuration
- [ ] `$ALLOWED_ORIGIN` set to your Flutter app domain (e.g., https://app.shadowcrypt.me)
- [ ] `$PORT` confirmed to be 3000 (Koyeb default)
- [ ] `$SESSION_TIMEOUT_MINUTES` configured (recommended: 30)
- [ ] All secrets stored in Koyeb UI (not in code)

---

## 🐳 LOCAL DOCKER BUILD TESTING

```powershell
# 1. Build Docker image
docker build -t shadowcrypt-blindrelay:latest .

# 2. Run container locally
docker run -it `
  -p 3000:3000 `
  -e PORT=3000 `
  -e ALLOWED_ORIGIN=http://localhost:3000 `
  shadowcrypt-blindrelay:latest

# 3. Test health endpoints (in new PowerShell window)
curl http://localhost:3000/health
curl http://localhost:3000/ready
curl http://localhost:3000/live

# 4. Test CORS rejection
curl -i -N `
  -H "Origin: https://attacker.com" `
  -H "Connection: Upgrade" `
  -H "Upgrade: websocket" `
  -H "Sec-WebSocket-Key: test" `
  -H "Sec-WebSocket-Version: 13" `
  http://localhost:3000/ws
# Expected: 403 Forbidden ✅

# 5. Kill container (Ctrl+C)
```

- [ ] Docker build succeeds
- [ ] Container starts on port 3000
- [ ] Health endpoints respond with 200 OK
- [ ] CORS rejection works (403 on wrong origin)
- [ ] No errors in logs

---

## 📤 GITHUB PUSH

```powershell
# 1. Verify all files are committed
git status

# 2. Create .gitignore if needed
git add .gitignore

# 3. Commit
git add .
git commit -m "Production-ready Koyeb deployment: Dockerfile, koyeb.yaml, security fixes"

# 4. Push to main
git branch -M main
git push -u origin main

# 5. Verify
git log --oneline -1
```

- [ ] All changes committed
- [ ] Pushed to GitHub successfully
- [ ] No sensitive data in repo (secrets only in Koyeb UI)

---

## 🚀 KOYEB DEPLOYMENT

```powershell
# 1. Authenticate with Koyeb
koyeb config create
# (Paste your API token)

# 2. Verify authentication
koyeb apps list

# 3. Deploy using koyeb.yaml
koyeb service create shadowcrypt-blindrelay `
  --git repository=https://github.com/YOUR-ORG/shadowcrypt `
  --git branch=main `
  --dockerfile=./Dockerfile `
  -f koyeb.yaml

# 4. Get public URL
$KOYEB_URL = $(koyeb app get shadowcrypt-blindrelay --json | ConvertFrom-Json | Select -ExpandProperty url)
Write-Host "Relay URL: $KOYEB_URL"

# 5. Monitor deployment
koyeb service logs shadowcrypt-blindrelay --follow
```

- [ ] Koyeb API authenticated
- [ ] Service deployed successfully
- [ ] Deployment URL obtained
- [ ] Logs show "Server running on :3000"

---

## ✅ PRODUCTION VERIFICATION

```powershell
# Set your Koyeb URL
$KOYEB_URL = "https://shadowcrypt-blindrelay-xxxxx.koyeb.app"

# 1. Health endpoints
curl "$KOYEB_URL/health"   # Expected: {"status":"healthy"}
curl "$KOYEB_URL/ready"    # Expected: {"ready":true,...}
curl "$KOYEB_URL/live"     # Expected: {"alive":true,...}

# 2. CORS validation - CORRECT origin
curl -i -N `
  -H "Origin: https://app.shadowcrypt.me" `
  -H "Connection: Upgrade" `
  -H "Upgrade: websocket" `
  -H "Sec-WebSocket-Key: test" `
  -H "Sec-WebSocket-Version: 13" `
  "$KOYEB_URL/ws"
# Expected: 101 Switching Protocols ✅

# 3. CORS validation - WRONG origin
curl -i -N `
  -H "Origin: https://attacker.com" `
  -H "Connection: Upgrade" `
  -H "Upgrade: websocket" `
  -H "Sec-WebSocket-Key: test" `
  -H "Sec-WebSocket-Version: 13" `
  "$KOYEB_URL/ws"
# Expected: 403 Forbidden ✅

# 4. Verify logs for security events
koyeb service logs shadowcrypt-blindrelay --follow
# Look for: "CORS REJECTED" entries

# 5. View metrics
koyeb service metrics shadowcrypt-blindrelay --duration 300
```

**Verification Results**:
- [ ] /health returns 200 with correct JSON
- [ ] /ready returns 200 with correct JSON
- [ ] /live returns 200 with correct JSON
- [ ] Correct origin connects with 101 (WebSocket upgrade)
- [ ] Wrong origin rejected with 403
- [ ] Logs show security events
- [ ] Metrics are available

---

## 🔒 SECURITY VERIFICATION

```powershell
# 1. Verify environment variables are set
koyeb service get shadowcrypt-blindrelay --json | ConvertFrom-Json | Select -ExpandProperty env

# 2. Verify Docker image is distroless (no shell)
# This should fail:
docker run shadowcrypt-blindrelay:latest /bin/sh
# Expected: stat /bin/sh: no such file or directory ✅

# 3. Verify security context
koyeb service get shadowcrypt-blindrelay --json | ConvertFrom-Json | Select -ExpandProperty securityContext
# Expected: runAsNonRoot=true, readOnlyRootFilesystem=true

# 4. Check for data leaks (relay should be blind)
# Send message from User A, verify User B cannot see plaintext

# 5. Verify graceful shutdown working
# Monitor logs during Koyeb restart:
koyeb service logs shadowcrypt-blindrelay --follow
# Look for: "[INFO] Received signal: SIGTERM"
```

- [ ] Environment variables correctly set
- [ ] Docker image is distroless
- [ ] Security context enforced
- [ ] Relay is blind (cannot see message content)
- [ ] Graceful shutdown working (SIGTERM logged)

---

## 📊 LOAD TESTING (Optional)

```powershell
# 1. Install load testing tool
npm install -g artillery

# 2. Create test config
@"
config:
  target: '$KOYEB_URL'
  phases:
    - duration: 60
      arrivalRate: 10
      name: "Warm up"
    - duration: 60
      arrivalRate: 50
      name: "Load"

scenarios:
  - name: "Health Check Load"
    flow:
      - get:
          url: "/health"
          expect: 200
"@ | Out-File load_test.yml

# 3. Run test
artillery run load_test.yml

# 4. Monitor server
koyeb service metrics shadowcrypt-blindrelay
```

- [ ] Load test completes without errors
- [ ] No 5xx errors during load
- [ ] CPU/memory scale appropriately

---

## 📝 POST-DEPLOYMENT MONITORING

### Daily Checks
- [ ] Review logs for errors: `koyeb service logs shadowcrypt-blindrelay | findstr ERROR`
- [ ] Monitor metrics: `koyeb service metrics shadowcrypt-blindrelay`
- [ ] Check CORS security: `koyeb service logs shadowcrypt-blindrelay | findstr "CORS"`

### Weekly Checks
- [ ] Review scaling metrics
- [ ] Check for security events
- [ ] Test graceful restart (manual redeploy): `koyeb service redeploy shadowcrypt-blindrelay`

### Monthly Reviews
- [ ] Update Go dependencies: `go mod update`
- [ ] Review security advisories
- [ ] Audit access logs for anomalies

---

## 🔧 TROUBLESHOOTING COMMANDS

```powershell
# View all logs
koyeb service logs shadowcrypt-blindrelay -n 200

# Follow logs in real-time (60 seconds)
koyeb service logs shadowcrypt-blindrelay --follow

# View metrics over last hour
koyeb service metrics shadowcrypt-blindrelay --duration 3600

# Get service details (JSON)
koyeb service get shadowcrypt-blindrelay --json

# Manual redeploy
koyeb service redeploy shadowcrypt-blindrelay

# View deployment history
koyeb service history shadowcrypt-blindrelay

# Rollback to previous version
koyeb service rollback shadowcrypt-blindrelay

# Update environment variable
koyeb service update shadowcrypt-blindrelay `
  --env ALLOWED_ORIGIN=https://new-domain.com

# Scale replicas
koyeb service update shadowcrypt-blindrelay --replicas 5
```

---

## 📞 INCIDENT RESPONSE QUICK GUIDE

| Incident | Command | Expected |
|----------|---------|----------|
| **High Memory** | `koyeb service metrics shadowcrypt-blindrelay` | Auto-scales to 2-3 replicas |
| **CORS Bypass Attempt** | `koyeb service logs shadowcrypt-blindrelay \| grep "CORS"` | "CORS REJECTED" entries |
| **Connection Timeouts** | `koyeb service metrics shadowcrypt-blindrelay` | CPU < 70% (not overloaded) |
| **Deployment Failed** | `koyeb service logs shadowcrypt-blindrelay` | Check Docker build errors |
| **Graceful Shutdown Failed** | `koyeb service logs shadowcrypt-blindrelay` | "SIGTERM" and "Server stopped" |

---

## 🎯 SUCCESS CRITERIA

**Deployment is successful when**:

✅ All health checks return 200 OK
✅ WebSocket accepts only from $ALLOWED_ORIGIN
✅ WebSocket rejects other origins with 403
✅ Logs show no errors
✅ Metrics available
✅ Graceful shutdown logs appear on redeploy
✅ Load test completes without 5xx errors

**Deployment is FAILED if**:

❌ Health endpoints return 5xx
❌ Cannot connect to WebSocket from correct origin
❌ Accept connections from wrong origin
❌ Errors in logs
❌ Deployment stuck in pending state for > 5 minutes

---

## 📚 REFERENCE DOCUMENTS

- 📄 PRODUCTION_READINESS_ANALYSIS.md - Detailed security analysis
- 📄 KOYEB_DEPLOYMENT_GUIDE.md - Step-by-step deployment guide
- 📄 Dockerfile - Multi-stage, distroless build
- 📄 koyeb.yaml - Complete Koyeb configuration
- 📄 backend/cmd/blindrelay/main.go - Entry point with env config

---

## ✨ COMPLETION STATUS

**Deployment Status**: [  ]  READY FOR PRODUCTION

**Date**: _______________
**Deployed By**: _______________
**Approval**: _______________

---

*This checklist should be printed and kept handy during deployment.*
