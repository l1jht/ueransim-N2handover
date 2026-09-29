# 构建指南（BUILD）

## 1. 环境要求

| 依赖 | 版本/说明 |
|---|---|
| UERANSIM 基线 | **v3.3.0**（tag，commit `6bf5a1a`） |
| CMake | ≥ 3.17 |
| g++ | ≥ 11（C++17） |
| libsctp-dev | gNB↔AMF 的 N2/SCTP 需要 |

## 2. 拉取基线并应用补丁

```bash
git clone https://github.com/aligungr/UERANSIM
cd UERANSIM
git checkout v3.3.0

# 仅本功能
git apply <path-to>/ueransim-N2handover/patch/n2handover.patch

# 与 ueransim-ims 同时使用（顺序不限，两者均已验证）
git apply <path-to>/ueransim-ims/patch/ims.patch
git apply <path-to>/ueransim-N2handover/patch/n2handover.patch
```

> 说明：补丁面向**原始 UERANSIM v3.3.0**，不依赖 ims 补丁。

## 3. 构建与测试

```bash
mkdir build && cd build
cmake ..
make -j$(nproc)

# 单元测试（ho-tests；若同时打了 ims 补丁则含 ims-tests）
ctest --output-on-failure
```

产物：`build/nr-gnb`、`build/nr-ue`、`build/nr-cli`。

## 4. 无本地依赖时的 Docker 构建（可选）

```dockerfile
# Dockerfile
FROM ubuntu:22.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential cmake libsctp-dev iproute2 iputils-ping tcpdump \
    && rm -rf /var/lib/apt/lists/*
```

```bash
docker build -t ueransim-build:22.04 .
docker run --rm -v "$PWD":/work -w /work/UERANSIM --user $(id -u):$(id -g) ueransim-build:22.04 \
    bash -lc "cmake -S . -B build && cmake --build build -j$(nproc) && ctest --test-dir build --output-on-failure"
```

该镜像同样可作为运行容器（`docs/RUN.md` 的端到端流程即用此方式，二进制以只读挂载注入）。

## 5. 已验证的兼容性矩阵

在干净 v3.3.0 上验证（每个场景均重新 configure/build/test；**宿主机原生**与 Docker 容器两种方式均通过）：

| 场景 | apply | 构建 | ctest |
|---|---|---|---|
| 仅 `n2handover.patch` | ✅ | ✅ | `ho-tests` 1/1 通过 |
| `ims.patch` → `n2handover.patch` | ✅ | ✅ | `ims-tests` + `ho-tests` 2/2 通过 |
| `n2handover.patch` → `ims.patch` | ✅ | ✅ | 2/2 通过 |

宿主机依赖（Ubuntu 22.04）：`sudo apt install cmake libsctp-dev`（libsctp 头文件位于 `/usr/include/netinet/sctp.h`）。

## 6. 常见问题

| 症状 | 处理 |
|---|---|
| `fatal error: netinet/sctp.h: No such file or directory`（或旧版/其他发行版的 `sctp/sctp.h`） | `sudo apt install libsctp-dev` |
| 修改源码后构建未反映新增文件 | 本仓库按 GLOB 收集源文件，重新执行 `cmake ..` |
| `nr-ue` 启动报 TUN 权限 | 需要 root 或 `CAP_NET_ADMIN` + `/dev/net/tun`（容器运行见 RUN.md） |
| 单测可执行文件链接失败（缺 `HexStringToVector` 等） | `tests/handover/CMakeLists.txt` 已包含 `src/utils/common.cpp`，无需处理；如自行改造请保持该依赖 |
