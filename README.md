# karpenter-practice

A hands-on repository for learning Karpenter on EKS.
- **Environment**: EKS / Karpenter 1.2.1
- **Namespaces**: controller `kube-system`, app `default`

---

## Learning Path

```
1. Installation    → install.md
2. Core Concepts   → nodepool-guide.md, ec2nodeclass-guide.md
3. Advanced
   ├── Cost        → consolidation-guide.md, spot-guide.md
   ├── Control     → disruption-guide.md
   └── Observability → observability-guide.md
4. Hands-on        → scale-test.md
```

---

## Documents

### Installation
| File | Description |
|------|-------------|
| [install.md](./install.md) | Install Karpenter via Helm on EKS (IAM, IRSA, Helm) |

### Core Concepts
| File | Description |
|------|-------------|
| [nodepool-guide.md](./nodepool-guide.md) | NodePool — node provisioning rules (instance types, limits, taints) |
| [ec2nodeclass-guide.md](./ec2nodeclass-guide.md) | EC2NodeClass — AWS-specific settings (AMI, subnet, security group) |

### Advanced
| File | Description |
|------|-------------|
| [consolidation-guide.md](./consolidation-guide.md) | Node Consolidation — automatic bin-packing and cost optimization |
| [spot-guide.md](./spot-guide.md) | Spot Instances — interruption handling and mixed capacity strategy |
| [disruption-guide.md](./disruption-guide.md) | Disruption Controls — budgets, do-not-disrupt annotations, drift |
| [observability-guide.md](./observability-guide.md) | Prometheus + Grafana setup, key Karpenter metrics |

### Hands-on
| File | Description |
|------|-------------|
| [scale-test.md](./scale-test.md) | Step-by-step scale-out / scale-in test with inflate workload |

---

## Manifest Structure

```
app/
├── deployment-inflate.yaml   # scale-out test workload (replicas: 0 → N)
├── deployment-spot.yaml      # workload targeting Spot nodes
└── deployment-ondemand.yaml  # workload targeting On-Demand nodes

karpenter/
├── ec2nodeclass-default.yaml   # AMI, subnet, security group, instance profile
├── nodepool-default.yaml       # On-Demand NodePool
└── nodepool-spot.yaml          # Spot NodePool
```

---

## Key Concept Summary

**NodePool + EC2NodeClass** is the core of Karpenter node provisioning.

```
Pending Pod
    │
    ▼
[NodePool]       → "What nodes can be provisioned?" (instance types, limits, taints)
    │
    ▼
[EC2NodeClass]   → "How should the node be launched?" (AMI, subnet, security group)
    │
    ▼
EC2 Instance (Node joins cluster)
```

> The `nodeClassRef` in NodePool must point to the name of an existing EC2NodeClass.
