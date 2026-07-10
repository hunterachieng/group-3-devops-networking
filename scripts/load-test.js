// k6 load test for the observability lab.
//
// Three scenarios, selected with the SCENARIO env var, each driving the MELT
// signals differently:
//   baseline - steady, low-rate checkout traffic (healthy reference load)
//   stress   - high-concurrency checkout traffic (pushes request rate + p95)
//   failure  - hits the failure endpoints (errors, latency, broken traces)
//
// Usage (stack already up):
//   k6 run scripts/load-test.js                       # baseline
//   k6 run -e SCENARIO=stress  scripts/load-test.js   # stress
//   k6 run -e SCENARIO=failure scripts/load-test.js   # failure
//   k6 run -e SCENARIO=all     scripts/load-test.js   # all three, sequentially
// Override the target with -e BASE_URL=http://localhost:8080

import http from "k6/http";
import { check, sleep } from "k6";
import { Counter } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";
const SCENARIO = (__ENV.SCENARIO || "baseline").toLowerCase();

// Optional overrides so a run can be shortened for a quick smoke check
// without editing the script, e.g. -e DURATION=30s -e RATE=8
const DURATION = __ENV.DURATION || null;
const RATE = __ENV.RATE ? parseInt(__ENV.RATE, 10) : null;

// Custom counters so the k6 summary breaks results down by intent.
const checkoutOk = new Counter("checkout_success");
const checkoutErr = new Counter("checkout_failed");
const faultHits = new Counter("fault_injected");

// ---- scenario definitions ---------------------------------------------------

const baseline = {
  executor: "constant-arrival-rate",
  rate: RATE || 5,
  timeUnit: "1s",
  duration: DURATION || "2m",
  preAllocatedVUs: 10,
  maxVUs: 20,
  exec: "checkout",
  tags: { scenario: "baseline" },
};

const stress = {
  executor: "ramping-arrival-rate",
  startRate: 10,
  timeUnit: "1s",
  preAllocatedVUs: 50,
  maxVUs: 200,
  stages: [
    { target: 50, duration: "30s" },
    { target: 150, duration: "1m" },
    { target: 0, duration: "30s" },
  ],
  exec: "checkout",
  tags: { scenario: "stress" },
};

const failure = {
  executor: "constant-arrival-rate",
  rate: RATE || 10,
  timeUnit: "1s",
  duration: DURATION || "3m",
  preAllocatedVUs: 20,
  maxVUs: 50,
  exec: "faults",
  tags: { scenario: "failure" },
};

// "all" runs the three back-to-back using startTime offsets so a single run
// produces a full baseline -> stress -> failure story in Grafana.
const allScenarios = {
  baseline_phase: { ...baseline, startTime: "0s" },
  stress_phase: { ...stress, startTime: "2m" },
  failure_phase: { ...failure, startTime: "4m" },
};

const scenarioMap = {
  baseline: { baseline },
  stress: { stress },
  failure: { failure },
  all: allScenarios,
};

if (!scenarioMap[SCENARIO]) {
  throw new Error(
    `Unknown SCENARIO="${SCENARIO}". Use baseline | stress | failure | all.`
  );
}

export const options = {
  scenarios: scenarioMap[SCENARIO],
  thresholds: {
    http_req_duration: ["p(95)<1500"],
    checkout_failed: ["count>=0"],
  },
};

// ---- traffic generators -----------------------------------------------------

function headers() {
  // Unique request id per iteration so logs/traces are individually greppable.
  return {
    "Content-Type": "application/json",
    "X-Request-ID": `k6-${SCENARIO}-${__VU}-${__ITER}-${Date.now()}`,
  };
}

// Healthy checkout through the full order -> inventory -> payment pipeline.
export function checkout() {
  const payload = JSON.stringify({
    items: ["SKU-1", "SKU-2"],
    amount: 4200,
  });
  const res = http.post(`${BASE_URL}/checkout`, payload, {
    headers: headers(),
  });
  const ok = check(res, {
    "checkout status 200": (r) => r.status === 200,
  });
  ok ? checkoutOk.add(1) : checkoutErr.add(1);
  sleep(0.1);
}

// Failure traffic: rotate across the fault endpoints so every MELT signal
// moves — 5xx counters, p95 latency, and a broken cross-service trace.
export function faults() {
  const endpoints = [
    { path: "/fail", expect: 500 },
    { path: "/slow?seconds=1.5", expect: 200 },
    { path: "/error", expect: 500 },
    { path: "/dependency-fail", expect: 502 },
  ];
  const target = endpoints[__ITER % endpoints.length];
  const res = http.post(`${BASE_URL}${target.path}`, null, {
    headers: headers(),
  });
  check(res, {
    [`${target.path} -> ${target.expect}`]: (r) => r.status === target.expect,
  });
  faultHits.add(1);
  sleep(0.1);
}
