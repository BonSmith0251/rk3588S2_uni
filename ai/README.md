# ai/ — Layer 3: on-device AI (RK3588 NPU)

Run neural nets on the RK3588's 3-core NPU (`rockchip,rk3588-rknpu`, already enabled
in the DTS). Two halves:

- `convert/` — on the **x86 host**, `rknn-toolkit2` converts `.onnx`/`.pt` models to
  `.rknn` targeting `rk3588`. (Runs in its own Python venv — strict TF/numpy pins.)
- `runtime/` + `demos/` — on the **target**, the RKNPU2 runtime (`librknnrt.so`,
  shipped inside `third_party/rknn-toolkit2/rknpu2/`) runs the `.rknn`.
- `models/` — model sources + converted `.rknn` (large `.rknn` are gitignored).

First milestone: convert MobileNet, run the classification demo on the NPU, print
top-1 + inference time, and confirm it used the NPU (not CPU fallback) via
`/sys/kernel/debug/rknpu/load` showing non-zero utilization.
