// 실행 방법:
// export TARGET_URL=$(kubectl get svc y2ks-frontend-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
// export AMP_ENDPOINT=$(cd monitoring && terraform output -raw amp_endpoint)
// k6 run \
//   --out prometheus-remote-write \
//   -e K6_PROMETHEUS_RW_SERVER_URL=$AMP_ENDPOINT \
//   -e K6_PROMETHEUS_RW_REGION=ap-northeast-2 \
//   -e K6_PROMETHEUS_RW_AWS_SIGV4_ENABLED=true \
//   -e TARGET_URL=http://$TARGET_URL \
//   k6/coupon-load-test.js

import http from 'k6/http';
import { sleep, check } from 'k6';

export const options = {
  scenarios: {
    coupon_load: {
      executor: 'ramping-vus',
      stages: [
        { duration: '30s', target: 1000 }, // ramp-up
        { duration: '2m',  target: 1000 }, // sustained load
        { duration: '30s', target: 0 },    // ramp-down
      ],
    },
  },
  thresholds: {
    'http_req_duration': ['p(95)<2000'],
    'http_req_failed': ['rate<0.05'],
  },
};

const BASE_URL = __ENV.TARGET_URL || 'http://localhost:5000';

export default function () {
  // 1. POST /api/claim
  const claimRes = http.post(`${BASE_URL}/api/claim`, null, {
    headers: { 'Content-Type': 'application/json' },
  });

  // 2. check: status 200, request_id 존재
  const claimOk = check(claimRes, {
    'claim status 200': (r) => r.status === 200,
    'claim has request_id': (r) => r.json('request_id') !== null && r.json('request_id') !== undefined,
  });

  if (!claimOk) return;

  const requestId = claimRes.json('request_id');
  if (!requestId) return;

  // 3. GET /api/check/{request_id} 폴링 최대 10회, 500ms 간격
  for (let i = 0; i < 10; i++) {
    sleep(0.5);
    const checkRes = http.get(`${BASE_URL}/api/check/${requestId}`);
    const status = checkRes.json('status');

    // 4. status가 winner/loser면 break
    if (status === 'winner' || status === 'loser') break;
  }
}
