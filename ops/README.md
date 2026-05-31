# Karpenter Ops

Karpenter 실습 자산과 운영 보조 자료를 두는 공간입니다.

| 폴더 | 내용 |
|------|------|
| `install/` | Helm 기반 Karpenter 설치 스크립트와 values |
| `upgrade/` | Karpenter 업그레이드 스크립트 |
| `karpenter/` | NodePool, EC2NodeClass 기본 YAML |
| `crd-yamls/` | CRD별 예제 YAML과 실습 자료 |
| `app/` | 스케일 테스트용 워크로드 |

프로비저닝 원리를 설명하는 문서는 `docs/`에 두고, 실제 적용 가능한 YAML은 `ops/`에 둡니다.
