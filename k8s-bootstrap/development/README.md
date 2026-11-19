# Development cluster: manual bootstrap

Kubernetes objects that Terraform can't create, because CI can't reach the
cluster's Kubernetes API (IP allowlist) and has no in-cluster RBAC. Apply
them once, by hand, from an allowlisted IP. They can move into Argo CD later.

Terraform has already created the AWS side: the EBS CSI driver add-on and
its Pod Identity role, plus Karpenter's controller role (with its Pod
Identity association for `kube-system/karpenter`), node role, and
interruption queue.

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

## 2. StorageClass

```bash
kubectl apply -f k8s-bootstrap/development/storageclass-gp3.yaml

# The default gp2 StorageClass, if present, should stop being the default
kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class=false --overwrite

kubectl get storageclass
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-ebs-csi-driver
```

## 3. Karpenter controller

Pick the latest release from
https://github.com/aws/karpenter-provider-aws/releases and check it
supports the cluster's Kubernetes version.

```bash
export KARPENTER_VERSION="<version, e.g. 1.x.y>"
TF="terraform -chdir=member-accounts/development"
export QUEUE=$($TF output -raw karpenter_queue_name)
export NODE_ROLE=$($TF output -raw karpenter_node_iam_role_name)

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace kube-system \
  --set settings.clusterName=Dev-EKS \
  --set settings.interruptionQueue="${QUEUE}" \
  --set controller.resources.requests.cpu=250m \
  --set controller.resources.requests.memory=512Mi \
  --set controller.resources.limits.memory=512Mi \
  --wait

kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
```

The chart's default service account (`kube-system/karpenter`) matches the
Pod Identity association, so no role annotation is needed. Its default
affinity keeps the controller off nodes Karpenter itself manages, so it
runs on the `general` managed node group.

## 4. NodeClass and NodePool

```bash
sed "s/KARPENTER_NODE_ROLE_NAME/${NODE_ROLE}/" \
  k8s-bootstrap/development/karpenter-nodeclass.yaml | kubectl apply -f -
kubectl apply -f k8s-bootstrap/development/karpenter-nodepool.yaml

kubectl get ec2nodeclass default   # READY should be True
kubectl get nodepool default
```

## 5. Test

```bash
# Karpenter: a deployment that doesn't fit on the general nodes
kubectl create deployment inflate --image=public.ecr.aws/eks-distro/kubernetes/pause:3.7 --replicas=5
kubectl set resources deployment inflate --requests=cpu=1
kubectl get nodeclaims -w          # a new node should appear
kubectl delete deployment inflate  # node is removed after ~1 minute

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
