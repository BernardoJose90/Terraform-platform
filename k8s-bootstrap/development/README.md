# Development cluster: in-cluster setup

Kubernetes objects that Terraform can't create, because CI can't reach the
cluster's Kubernetes API (IP allowlist) and has no in-cluster RBAC. They are
applied by hand with [install.sh](install.sh), from an allowlisted IP.

Terraform creates the AWS side first: the EBS CSI driver add-on and its Pod
Identity role, plus Karpenter's controller role (with its Pod Identity
association for `kube-system/karpenter`), node role, and interruption queue.

## Layout

```
install.sh                 Applies everything below, in order. Safe to re-run.
storage/
  storageclass-gp3.yaml    Default StorageClass (EBS gp3, encrypted)
karpenter/
  values.yaml              Helm values for the controller
  ec2nodeclass.yaml        How nodes are built (role, subnets, AMI, disk)
  nodepool.yaml            Which instances may be launched, limits, consolidation
```

## Rules

- **Change a file, then re-run `install.sh`.** No `kubectl edit`, no one-off
  `--set` flags, no `helm upgrade` by hand. Otherwise this folder stops
  describing the cluster.
- **Versions are pinned at the top of `install.sh`.** Bump them in a PR.
- **Check for drift** now and then: `kubectl diff -f storage/` and
  `kubectl diff -f karpenter/nodepool.yaml`, and `helm get values karpenter -n kube-system`.

## 1. Log in to the cluster

```bash
# Your IP must be in eks_endpoint_public_access_cidrs (terraform.tfvars)
curl -s https://checkip.amazonaws.com

aws sso login --profile development
aws eks update-kubeconfig --name Dev-EKS --region eu-west-2 \
  --profile development --alias dev-eks

kubectl get nodes
```

The `development` profile uses the AdministratorAccess SSO role, which has
cluster-admin through the `james_admin` access entry. An EKS-Admin
permission set profile works too (`platform_admins` entry).

## 2. Install or update

```bash
export AWS_PROFILE=development      # Terraform reads its outputs with this
./k8s-bootstrap/development/install.sh   # from the repo root; context defaults to dev-eks
```

The script checks the kube context and API access, reads the queue and node
role names from Terraform outputs, then:

1. applies the gp3 StorageClass and stops gp2 from being the default;
2. installs or upgrades Karpenter's CRDs (`karpenter-crd` chart) and the
   controller (`karpenter` chart);
3. applies the EC2NodeClass (with the node role filled in) and the NodePool.

If the cluster API times out, check your public IP against the allowlist
first. It's usually that.

## 3. Test

```bash
# Karpenter: a deployment that doesn't fit on the general nodes
kubectl create deployment inflate --image=public.ecr.aws/eks-distro/kubernetes/pause:3.7 --replicas=5
kubectl set resources deployment inflate --requests=cpu=1
kubectl get nodeclaims -w          # a new node should appear (Ctrl+C to stop)
kubectl delete deployment inflate  # node is removed after ~1-2 minutes

# EBS: a PVC is bound once a pod uses it
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: ebs-test }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: ebs-test }
spec:
  containers:
    - name: app
      image: public.ecr.aws/docker/library/busybox:1.36
      command: ["sh", "-c", "echo ok > /data/test && sleep 3600"]
      volumeMounts: [{ name: data, mountPath: /data }]
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: ebs-test }
EOF
kubectl get pvc ebs-test   # STATUS Bound
kubectl delete pod/ebs-test pvc/ebs-test
```

## Adding a component

1. Create its AWS side (IAM role, Pod Identity association) in Terraform first.
2. Add a folder here with its `values.yaml` and manifests.
3. Add a pinned version and a step to `install.sh`.
4. Add its checks to this README.
