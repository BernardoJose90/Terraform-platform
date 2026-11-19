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

## Before disabling EKS (`eks_enabled = false`)

Do this **before** merging the PR that sets `eks_enabled = false`, while the
cluster and Karpenter's controller are still running. Karpenter creates AWS
resources that aren't in Terraform state (EC2 instances, an instance profile),
and only the controller can clean them up. Terraform destroys the
controller's IAM role early in the teardown, so after that nothing removes
them.

```bash
# 1. Karpenter's nodes: deleting the NodePool drains and terminates them
kubectl delete nodepool default
kubectl get nodeclaims                 # wait until empty

# 2. Karpenter's instance profile: deleting the EC2NodeClass removes it
kubectl delete ec2nodeclass default
kubectl get ec2nodeclass               # wait until empty

# 3. EBS volumes from PVCs: these outlive the cluster if left behind
kubectl get pvc -A                     # delete any that remain (and the pods using them)
```

Then check nothing is left in AWS:

```bash
aws ec2 describe-instances --profile development --region eu-west-2 \
  --filters Name=tag-key,Values=karpenter.sh/nodepool \
            Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].InstanceId'          # []

aws iam list-instance-profiles --profile development \
  --query "InstanceProfiles[?starts_with(InstanceProfileName, 'Dev-EKS_')].InstanceProfileName"   # []
```

**If you skip step 2**, the destroy fails deleting the Karpenter node role:
`AccessDenied ... iam:RemoveRoleFromInstanceProfile` on a `Dev-EKS_<number>`
instance profile. TerraformDeploy's boundary deliberately doesn't allow that
action. Remove the profile with your SSO admin login, then rerun the apply:

```bash
aws iam remove-role-from-instance-profile --profile development \
  --instance-profile-name <Dev-EKS_number> --role-name <Karpenter node role>
aws iam delete-instance-profile --profile development \
  --instance-profile-name <Dev-EKS_number>
```

### Bringing the cluster back

1. Set `eks_enabled = true` **and** `bootstrap_cni_via_node_role = true`
   (`member-accounts/development/main.tf`) for the first apply. A new cluster
   needs it, see that variable's description.
2. Once the nodes are Ready, run `install.sh` (above).
3. Set `bootstrap_cni_via_node_role = false` and apply again.

The Spot service-linked role and the deploy role's permissions aren't gated on
`eks_enabled`, so they stay in place while the cluster is off.

## Adding a component

1. Create its AWS side (IAM role, Pod Identity association) in Terraform first.
2. Add a folder here with its `values.yaml` and manifests.
3. Add a pinned version and a step to `install.sh`.
4. Add its checks to this README.
