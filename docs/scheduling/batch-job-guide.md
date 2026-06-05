# 배치/Job 워크로드 패턴

배치 잡은 "시작 → 처리 → 완료"의 수명주기를 갖습니다.
Karpenter와 올바르게 연동하면 잡 실행 중 노드 중단을 막고, 완료 후에는 즉시 노드를 반납할 수 있습니다.

---

## 핵심 문제: 배치 잡 중 Consolidation 발생

```
상황:
  배치 잡이 노드에서 2시간짜리 처리 중
      │
      ▼
  Karpenter가 해당 노드를 통합 대상으로 선택
      │
      ▼
  Pod Eviction → 잡 중단 (처리 결과 유실)
```

**해결책:** `do-not-disrupt` 어노테이션으로 처리 중 노드 보호

---

## 패턴 1 — do-not-disrupt로 잡 보호

잡이 실행되는 동안 노드를 보호하고, 완료 후 자동으로 Consolidation 허용합니다.

```yaml
# job-protected.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: data-processor
spec:
  template:
    metadata:
      annotations:
        karpenter.sh/do-not-disrupt: "true"   # 이 Pod가 있는 동안 노드 보호
    spec:
      restartPolicy: OnFailure
      tolerations:
      - key: workload-type
        value: batch
        effect: NoSchedule
      nodeSelector:
        workload-type: batch
      containers:
      - name: processor
        image: myrepo/data-processor:latest
        resources:
          requests:
            cpu: "4"
            memory: 8Gi
        env:
        - name: BATCH_SIZE
          value: "10000"
      # terminationGracePeriodSeconds는 Pod 수준에서도 설정 가능
      terminationGracePeriodSeconds: 120
```

> Pod가 완료(`Succeeded`)되면 `do-not-disrupt` 어노테이션이 더 이상 적용되지 않습니다.
> Karpenter는 이후 해당 노드를 Consolidation 대상으로 처리합니다.

---

## 패턴 2 — Graceful Shutdown 구현

Spot 인터럽션이나 드리프트로 인해 Pod가 종료될 때 작업 상태를 안전하게 저장합니다.

```yaml
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 120   # 2분 내 정리 작업 완료
      containers:
      - name: worker
        image: myrepo/worker:latest
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh", "-c", "echo 'checkpoint saved' && sleep 5"]
```

```python
# 애플리케이션 레벨의 graceful shutdown 예시 (Python)
import signal
import sys

def save_checkpoint(signum, frame):
    print("SIGTERM received, saving checkpoint...")
    # 현재 처리 위치 저장
    save_progress_to_s3()
    sys.exit(0)

signal.signal(signal.SIGTERM, save_checkpoint)
```

---

## 패턴 3 — Job 완료 후 즉시 노드 반납

배치 잡 전용 NodePool에서 `WhenEmpty` + 짧은 `consolidateAfter`를 사용합니다.

```yaml
# nodepool-batch.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: batch
spec:
  template:
    metadata:
      labels:
        workload-type: batch
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["spot"]
      - key: karpenter.k8s.aws/instance-category
        operator: In
        values: ["c", "m"]
      taints:
      - key: workload-type
        value: batch
        effect: NoSchedule
      expireAfter: Never    # 잡 완료 후 Consolidation으로만 삭제
  disruption:
    consolidationPolicy: WhenEmpty        # Pod가 없으면 즉시 삭제
    consolidateAfter: 30s                 # 비워진 후 30초 대기
  limits:
    cpu: "500"
  weight: 80
```

---

## 패턴 4 — PodDisruptionBudget으로 병렬 잡 보호

여러 잡이 동시에 실행될 때 Disruption이 한꺼번에 너무 많이 발생하지 않도록 제한합니다.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: batch-pdb
spec:
  minAvailable: "80%"    # 동시에 최대 20%만 중단 허용
  selector:
    matchLabels:
      workload-type: batch
```

---

## 패턴 5 — CronJob + Karpenter (스케줄 배치)

정해진 시간에 대량의 잡을 실행하는 패턴입니다.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-etl
spec:
  schedule: "0 2 * * *"      # 매일 새벽 2시 (KST 11시)
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      parallelism: 20         # 동시 실행 Pod 수
      completions: 100        # 총 완료해야 할 잡 수
      template:
        metadata:
          annotations:
            karpenter.sh/do-not-disrupt: "true"
        spec:
          restartPolicy: OnFailure
          tolerations:
          - key: workload-type
            value: batch
            effect: NoSchedule
          nodeSelector:
            workload-type: batch
          containers:
          - name: etl
            image: myrepo/etl:latest
            resources:
              requests:
                cpu: "2"
                memory: 4Gi
```

> 새벽 2시에 잡이 시작되면 Karpenter가 20개 Pod를 위한 노드를 프로비저닝합니다.
> 잡이 완료되는 새벽 3~4시경 노드가 자동으로 반납됩니다.

---

## 패턴 6 — ML 학습 잡 보호

ML 학습은 수 시간~수 일이 걸리므로 중단되면 전체를 재시작해야 합니다.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ml-training
spec:
  backoffLimit: 3   # 실패 시 최대 3번 재시도
  template:
    metadata:
      annotations:
        karpenter.sh/do-not-disrupt: "true"
    spec:
      restartPolicy: OnFailure
      tolerations:
      - key: nvidia.com/gpu
        value: "true"
        effect: NoSchedule
      - key: workload-type
        value: batch
        effect: NoSchedule
      containers:
      - name: trainer
        image: myrepo/ml-trainer:latest
        resources:
          requests:
            cpu: "8"
            memory: 32Gi
            nvidia.com/gpu: "1"
          limits:
            nvidia.com/gpu: "1"
        volumeMounts:
        - name: checkpoint
          mountPath: /checkpoints
      volumes:
      - name: checkpoint
        persistentVolumeClaim:
          claimName: ml-checkpoint-pvc   # EFS 등 공유 스토리지
```

---

## Job TTL (완료된 Job 자동 정리)

완료된 Job이 쌓이면 리소스가 낭비됩니다.

```yaml
spec:
  ttlSecondsAfterFinished: 3600   # 완료 후 1시간 뒤 자동 삭제
```

---

## 확인 명령어

```bash
# Job 실행 상태 확인
kubectl get jobs
kubectl get pods -l job-name=data-processor

# do-not-disrupt 어노테이션 확인
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.annotations.karpenter\.sh/do-not-disrupt}{"\n"}{end}'

# 잡 완료 후 Consolidation 발생 확인
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter \
  | grep -i "consolidat"

# 배치 전용 노드 확인
kubectl get nodes -l karpenter.sh/nodepool=batch
```

---

## 참고

- [공식문서 - do-not-disrupt](https://karpenter.sh/docs/concepts/disruption/#pod-level-controls)
- [공식문서 - Kubernetes Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/)
