#!/usr/bin/env bash
#
# verify.sh
#
# One-command proof that the system is healthy AND that the internal services
# are sealed off from the outside. Safe to run repeatedly. Exits non-zero if a
# critical check fails, so it can also be used in CI.
#
# Run on the VM:  bash verify.sh
#
# Note: the security test reaches the VM's own NON-loopback IP. Because
# Inventory/Payment bind to 127.0.0.1, a connection to the VM's public IP must
# fail - which proves no external host can reach them either.

PASS=0; FAIL=0
green(){ printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
red(){   printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
note(){  printf '  ----  %s\n' "$1"; }
section(){ printf '\n== %s ==\n' "$1"; }

VM_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

# -- helpers ------------------------------------------------------------------
listen_addrs(){ ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E "[:.]${1}\$"; }

check_loopback_only(){            # $1 port  $2 name
  local addrs; addrs=$(listen_addrs "$1")
  if [ -z "$addrs" ]; then red "$2 ($1): NOT listening (service down?)"; return; fi
  if echo "$addrs" | grep -qvE '^127\.0\.0\.1:'; then
    red "$2 ($1): listening on a NON-loopback address -> $addrs"
  else
    green "$2 ($1): loopback only"
  fi
}

check_public(){                   # $1 port  $2 name
  local addrs; addrs=$(listen_addrs "$1")
  if echo "$addrs" | grep -qE '0\.0\.0\.0:|\[::\]:|\*:'; then
    green "$2 ($1): publicly bound (correct)"
  else
    red "$2 ($1): not publicly listening ($addrs)"
  fi
}

# -- 1. discovery -------------------------------------------------------------
section "1. Service discovery names resolve"
for n in order inventory payment; do
  if getent hosts "$n.internal" >/dev/null; then green "$n.internal resolves"
  else red "$n.internal does not resolve (add to /etc/hosts)"; fi
done

# -- 2. bindings --------------------------------------------------------------
section "2. Services bind to loopback only; Nginx is the only public port"
check_loopback_only 3001 "order"
check_loopback_only 3002 "inventory"
check_loopback_only 3003 "payment"
check_public        80   "nginx"

# -- 3. health ----------------------------------------------------------------
section "3. Health endpoints (liveness, via loopback)"
for pp in order:3001 inventory:3002 payment:3003; do
  name=${pp%%:*}; port=${pp##*:}
  if curl -fsS -m3 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then green "$name /health ok"
  else red "$name /health failed"; fi
done

# -- 3b. readiness ------------------------------------------------------------
section "3b. Readiness endpoints (reflect downstream availability)"
for pp in order:3001 inventory:3002 payment:3003; do
  name=${pp%%:*}; port=${pp##*:}
  code=$(curl -s -o /dev/null -w "%{http_code}" -m3 "http://127.0.0.1:$port/ready" 2>/dev/null)
  if [ "$code" = "200" ]; then green "$name /ready -> 200 (ready)"
  elif [ "$code" = "503" ]; then note "$name /ready -> 503 (a dependency is unavailable)"
  else red "$name /ready -> ${code:-no response}"; fi
done

# -- 4. end-to-end flow through Nginx ----------------------------------------
section "4. Full checkout pipeline through Nginx:80"
resp=$(curl -fsS -m8 -X POST http://localhost/checkout \
  -H 'Content-Type: application/json' -d '{"items":["TEST"],"amount":100}' 2>/dev/null)
if echo "$resp" | grep -qE '"outcome": *"success"'; then green "checkout -> success (Order/Inventory/Payment all responded)"
else red "checkout failed: ${resp:-<no response>}"; fi

# -- 5. SECURITY: internal services sealed from the outside -------------------
section "5. Network security: internal services unreachable on public IP"
if [ -n "$VM_IP" ] && [ "$VM_IP" != "127.0.0.1" ]; then
  note "testing against this VM's public IP: $VM_IP"
  for p in 3001 3002 3003; do
    if curl -fsS -m3 "http://$VM_IP:$p/health" >/dev/null 2>&1; then
      red "port $p is REACHABLE on $VM_IP (it must NOT be!)"
    else
      green "port $p sealed on $VM_IP (refused/timed out, as required)"
    fi
  done
  if curl -fsS -m5 "http://$VM_IP/health" >/dev/null 2>&1; then green ":80 reachable on $VM_IP (public entry, correct)"
  else red ":80 NOT reachable on $VM_IP (Nginx should be public)"; fi
else
  note "no non-loopback IP detected; skipping external-reach test"
fi

# -- 6. firewall (informational) ---------------------------------------------
section "6. Firewall (informational)"
if command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q "Status: active"; then green "ufw active"
  else note "ufw present but inactive, or needs sudo to read status"; fi
else
  note "ufw not installed (loopback binding still protects the services)"
fi

# -- 7. systemd (informational) ----------------------------------------------
section "7. systemd units (informational)"
if command -v systemctl >/dev/null 2>&1; then
  for s in order inventory payment nginx; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then green "$s active under systemd"
    else note "$s not active under systemd (ok if started manually)"; fi
  done
else
  note "systemctl not available"
fi

# -- summary ------------------------------------------------------------------
section "Summary"
printf "  PASS=%d  FAIL=%d\n" "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  ALL CRITICAL CHECKS PASSED"; exit 0
else echo "  SOME CHECKS FAILED - see above"; exit 1; fi