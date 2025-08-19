# Using NVIDIA GPU with Talos Linux on Proxmox

This guide explains how to pass through an NVIDIA RTX GPU (example: RTX
3090) to a Talos Linux worker node running in Proxmox, and configure
Kubernetes to use it.

------------------------------------------------------------------------

## 1. Configure Proxmox for GPU Passthrough

On the Proxmox host:

1.  **Enable IOMMU**


4.  **Configure VM Hardware**

    -   Use **Q35** machine type, **OVMF (UEFI)** BIOS, CPU type `host`.
    -   Add **PCIe Device** for both GPU functions (`01:00.0` and
        `01:00.1`).
    -   Tick **PCI-Express** and **All functions**.

------------------------------------------------------------------------

## 2. Build a Talos Image with NVIDIA Extensions

Talos does not allow installing packages at runtime. The NVIDIA drivers
must be included via **system extensions**.

Extensions required: - `nonfree-kmod-nvidia` -
`nvidia-container-toolkit`

### Using Talos Image Factory

1.  Go to [Talos Image Factory](https://factory.talos.dev).
2.  Select your Talos release (e.g., `v1.7.5`).
3.  Add system extensions:
    -   `nonfree-kmod-nvidia:<driver>-v1.7.5`
    -   `nvidia-container-toolkit:<driver>-<toolkit-version>`
4.  Build and copy the **Upgrade Image URL**.

### Upgrade worker node

``` bash
talosctl -e <CONTROLPLANE_IP> -n <GPU_NODE_IP>   upgrade --image <IMAGE_URL> --preserve=true --wait=true
```

Verify extensions:

``` bash
talosctl -e <CONTROLPLANE_IP> -n <GPU_NODE_IP> get extensions
```

------------------------------------------------------------------------

## 3. Load NVIDIA Kernel Modules

Patch the worker node:

``` yaml
# gpu-worker-patch.yaml
machine:
  kernel:
    modules:
      - name: nvidia
      - name: nvidia_uvm
      - name: nvidia_drm
      - name: nvidia_modeset
  sysctls:
    net.core.bpf_jit_harden: 1
```

Apply:

``` bash
talosctl -e <CONTROLPLANE_IP> -n <GPU_NODE_IP> patch mc --patch @gpu-worker-patch.yaml
```

Verify:

``` bash
talosctl -e <CONTROLPLANE_IP> -n <GPU_NODE_IP> read /proc/modules | grep nvidia
talosctl -e <CONTROLPLANE_IP> -n <GPU_NODE_IP> read /proc/driver/nvidia/version
```

------------------------------------------------------------------------

## 4. Configure Kubernetes

### RuntimeClass

``` yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
```

Apply:

``` bash
kubectl apply -f runtimeclass-nvidia.yaml
```

### Install NVIDIA Device Plugin

``` bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
helm upgrade --install nvidia-device-plugin nvdp/nvidia-device-plugin   --namespace kube-system   --set runtimeClassName=nvidia   --version 0.13.0
```

Verify:

``` bash
kubectl -n kube-system get ds nvidia-device-plugin -o wide
```

### Confirm node advertises GPU

``` bash
kubectl describe node <GPU_NODE_NAME> | grep nvidia.com/gpu
```

------------------------------------------------------------------------

## 5. Test with CUDA

Create a test pod (pick CUDA image matching your driver):

``` yaml
apiVersion: v1
kind: Pod
metadata:
  name: nvidia-test
spec:
  nodeSelector:
    kubernetes.io/hostname: <GPU_NODE_NAME>
  runtimeClassName: nvidia
  restartPolicy: Never
  containers:
    - name: cuda
      image: docker.io/nvidia/cuda:12.3.2-base-ubuntu22.04
      command: ["bash","-lc","nvidia-smi && sleep 5"]
      resources:
        limits:
          nvidia.com/gpu: 1
```

Run:

``` bash
kubectl apply -f nvidia-test.yaml
kubectl logs nvidia-test
```

Expected: `nvidia-smi` shows your RTX GPU.

------------------------------------------------------------------------

## 6. Notes

-   Driver and CUDA image versions **must match**.\
    Example: driver 535 works with CUDA 12.3, but CUDA 12.5 requires
    driver ≥ 550.
-   For production, prefer using the [NVIDIA GPU
    Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/),
    but disable driver/toolkit installs (Talos handles them via
    extensions).
