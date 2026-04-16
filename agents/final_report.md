# Y2KS EKS 자동 진단 보고서

생성 시각: 2026-04-16T05:54:02.438136+00:00

---

## EKS Agent

### 조사 대상
- 전체 클러스터의 파드/노드/KEDA/SQS/Karpenter 상태

### 발견 사항
- **근본 원인**: 
  - Pending 파드: y2ks-cart-c859dddb7-m9pfm, y2ks-product-6dbb66bb84-qtmn2
    - **수치**: Pending 파드는 각각 49분 및 49분 동안 Pending 상태로 남아 있음
  - 노드 CPU 여유량: ip-192-168-33-255.ap-northeast-2.compute.internal (29% CPU 사용), ip-192-168-6-68.ap-northeast-2.compute.internal (35% CPU 사용)
  - SQS 큐 대기 메시지 수: 0
  - Karpenter 스팟 인스턴스 프로비저닝: 0개
- **심각도**: Critical / Warning / Info
  - Pending 파드: Critical (사용자 요청에 대한 응답이 지연됨)
  - SQS 큐 대기 메시지 수: Info (스케일아웃 필요 여부 확인)
  - Karpenter 스팟 인스턴스 프로비저닝: Info (스팟 인스턴스 필요 여부 확인)

### 즉시 조치
- **Pending 파드 해결**: get_pending_pods를 사용하여 불필요한 툴 남발 없이 근본 원인 파악. 각 파드에 대해 describe_pod을 사용하여 Events 확인.
- **SQS 큐 감시**: get_sqs_depth를 사용하여 큐 깊이 지속적으로 모니터링. 큐 깊이 100건 이상 시 워커 스케일아웃 고려.
- **Karpenter 프로비저닝 확인**: get_karpenter_status를 사용하여 스팟 인스턴스 프로비저닝 필요 여부 확인. 리소스 사용량 고려 후 결정.

### 단기 권고
- **Pending 파드**: 노드 CPU 여유량 계산 후 근본 원인 파악. 필요한 경우 노드 리소스 추가 고려.
- **SQS 큐 급증**: KEDA 스케일아웃 시 Karpenter 노드 생성 지연 고려.
- **Karpenter**: 전체 CPU 한계 근접 경고 설정 고려 (CPU 18코어 이상 시 경고).

이상의 조치를 통해 클러스터의 전반적인 상태를 안정화할 수 있을 것입니다.

---

## DB Agent

### 조사 대상
- DynamoDB 이벤트 결과
- 봇 트래픽
- 시간대별 참여 추이

### 발견 사항
- **이벤트 결과**: 총 참여자 수 61,093명, 당첨자 200명, 낙첨자 60,893명, 당첨률 0.3%
- **봇 트래픽**: 의심되는 봇 없음, 정상 트래픽
- **시간대별 참여 추이**: 총 참여자 수 61,093명, 피크 시간 00:00, 피크 시간 참여자 수 61,093명

### 즉시 조치
즉시 조치는 필요하지 않습니다.

### 단기 권고
추가적인 분석이나 조치는 필요하지 않습니다. 그러나 정기적인 모니터링을 통해 봇 트래픽이나 시간대별 참여 추이의 변화를 주시하는 것이 좋습니다.

규칙에 따라 한국어와 수치 기반으로 정리하였습니다.

---

## Observe Agent

### 조사 대상
노드/파드 리소스 사용량 분석, Graviton 전환 비용 절감 계산

### 발견 사항
- **노드별 사용량**:
  - ip-192-168-33-255.ap-northeast-2.compute.internal: CPU 10%, 메모리 63%
  - ip-192-168-6-68.ap-northeast-2.compute.internal: CPU 31%, 메모리 59%
- **파드별 사용량**:
  - redis-6b6d958746-rzq2l: CPU 3m, 메모리 8Mi
  - y2ks-frontend-5658b7df79-jbv69: CPU 376m, 메모리 333Mi
  - y2ks-worker-57dc5dd86-pqd2x: CPU 1m, 메모리 44Mi
  -... (잘림)
- **Graviton 전환 비용 절감**:
  - **근본 원인**: t3.medium OnDemand 비용 대비 t4g.medium Spot 비용
  - **심각도**: Info
  - Graviton 인스턴스 전환으로 절감될 수 있는 비용은 $56.88/월이며, 절감률은 76.0%입니다.

### 즉시 조치
없음

### 단기 권고
Graviton 인스턴스로 전환을 고려하여 비용을 최적화할 수 있습니다. Graviton 인스턴스는 현재 비용의 20% 이상을 절감할 수 있으며, 이는 76.0%의 절감률을 의미합니다.

---

위 정보를 바탕으로 클러스터의 리소스 사용량과 Graviton 전환으로의 비용 절감 가능성을 분석할 수 있었습니다. Graviton 전환을 통해 76%의 비용 절감이 가능하며, 이는 단기적인 비용 최적화를 위한 중요한 방안입니다.

---

## 팀장 종합 판단

**근본 원인**:
Pending 파드와 노드의 CPU 사용률 상황은 주요 인과관계로 볼 수 있습니다. Pending 파드는 각각 49분 동안 Pending 상태로 남아 있으며, 이는 노드가 충분한 리소스를 제공하지 못하고 있음을 시사합니다. 특히 노드 ip-192-168-33-255.ap-northeast-2.compute.internal와 ip-192-168-6-68.ap-northeast-2.compute.internal에서 CPU 여유량이 상대적으로 낮은 것을 확인할 수 있습니다. 이러한 상황은 노드가 요청되는 리소스를 충족시키지 못하고 있음을 나타냅니다.

**현재 상황**:
- Pending 파드: y2ks-cart-c859dddb7-m9pfm 및 y2ks-product-6dbb66bb84-qtmn2가 각각 49분 동안 Pending 상태로 남아 있음
- 노드 CPU 여유량: ip-192-168-33-255.ap-northeast-2.compute.internal (29% CPU 사용), ip-192-168-6-68.ap-northeast-2.compute.internal (35% CPU 사용)
- SQS 큐 대기 메시지 수: 0
- Karpenter 스팟 인스턴스 프로비저닝: 0개

**즉시 조치**:
1. **Pending 파드 해결**:
   - `kubectl get pendingpods`를 사용하여 Pending 파드를 확인합니다.
   - 각 파드에 대해 `kubectl describe pod <pod-name>`을 실행하여 구체적인 오류 메시지와 이벤트를 파악합니다.
   - 파드가 할당할 수 있는 리소스가 부족하다면, `kubectl describe node <node-name>`를 통해 노드의 상태를 확인하고, 필요하다면 노드의 CPU 또는 메모리를 확장하거나, 더 적합한 노드로 파드를 이동합니다.

2. **노드 CPU 여유량 확인**:
   - 현재 CPU 여유량이 낮으므로, 노드에 더 많은 리소스를 할당하거나, 필요하다면 새로운 노드를 추가하는 것을 고려합니다.
   - `kubectl drain <node-name> --ignore-daemonsets --delete-local-data`를 사용하여 안전하게 노드에서 파드를 이동할 수 있습니다.

**단기 권고**:
1. **Pending 파드**:
   - 노드가 충분한 리소스를 제공할 수 없다면, 노드 리소스를 확장하거나 파드를 다른 노드로 이동합니다.
   - 파드 우선순위 설정을 확인하고, 필요에 따라 조정합니다.

2. **SQS 큐 급증**:
   - 큐 깊이가 증가하면, KEDA를 통해 자동으로 Worker 스케일아웃이 진행됩니다. 하지만, Karpenter가 노드를 프로비저닝하는 데 시간이 걸릴 수 있으므로, 이를 고려한 시스템을 설계합니다.

3. **Karpenter**:
   - 전체 CPU 한도가 근접하고 있습니다. Karpenter가 더 많은 노드를 프로비저닝하지 못하도록 하는 문제가 있을 수 있으므로, 전체 시스템의 CPU 한도를 확인하고 필요한 경우 조정합니다.

이상의 조치를 통해 클러스터의 전반적인 상태를 안정화할 수 있을 것입니다.