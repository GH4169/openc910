# C910 LSU 中一条 Store 的处理流程

本文记录普通 store 从 LSIQ 发射到写入缓存或向外部总线发出写请求的主要路径。重点是区分 LSU 执行完成、RTU commit 和存储层次中的实际写入。

## 总览

LSIQ 可以乱序选择 load/store 发射给 LSU，但每条指令携带的 IID 保留了原来的程序顺序。Store 在 LSU 中的地址控制路径和数据路径分开：

```text
地址 / 控制：IDU pipe4 → ST_AG → ST_DC → ST_DA → ST_WB → RTU
写数据：     IDU pipe5 → SD_EX1 ───────────────→ SQ entry
                                                    │
                                      RTU commit 后 │
                                                    ▼
                                         SQ → WMB CE → WMB
                                                    │
                                       D-cache 或 BIU 写通路
```

## 阶段说明

### 1. LSIQ 发射

LSIQ 选择一条 store 后，经 IDU 的 LSU pipe4 提供基址、偏移、IID、访问大小、指令属性和队列标识等信息。发射顺序可以不同于程序顺序，但 IID 不变，因此 LSU 后续仍能判断 store 的年龄。

Store 的写数据走 IDU pipe5，由 `SD_EX1` 接收。地址和数据并不要求在同一拍到达 LSU。

### 2. ST_AG：计算地址并请求翻译

`ST_AG` 用基址和偏移计算有效虚拟地址，配合 MMU 翻译，并生成访问字节掩码。它也处理非对齐、跨页等情况，并请求 D-cache 访问。

如果翻译尚未就绪、发生端口冲突，或需要处理跨页访问，store 会等待或重发；不能把这次未完成的尝试当作成功访问。

### 3. ST_DC：检查并创建 SQ entry

得到有效物理地址后，`ST_DC` 检查异常、μTLB 状态、重复发射以及 SQ 空间。创建成功时，SQ entry 保存物理地址、IID、字节有效掩码、页属性和 store 类型等信息。

如果 SQ 满，LSU 向 IDU/LSIQ 返回等待或重发控制，store 会留在 LSIQ 中，待空间可用后重新发射。

### 4. SD_EX1：store 数据进入 SQ

写数据从 `SD_EX1` 到达 SQ。SQ 用 store-data queue 标识（SDIQ/SDID）找到对应 entry，并按地址偏移和访问大小对数据进行旋转、对齐。

因此，可能出现地址已经记入 SQ、数据稍后才补入的情况。数据有效之前，该 entry 不能作为完整 store 排出。

### 5. ST_DA：检查 D-cache 并更新 SQ 状态

`ST_DA` 检查 D-cache 的 tag 和状态，判断命中 way、dirty/valid 状态，以及是否要申请读缓冲和补行；也会处理异常与重发条件。检查结果和是否还需重发等信息会写回 SQ entry。

对普通 cacheable store，`ST_DA` 通常是在检查缓存状态并登记队列信息，不意味着 store 数据已经在这一阶段写进 D-cache。若 cache line 缺失，可能先申请补行，store 仍由 SQ 保存。

### 6. ST_WB：向 RTU 报告 LSU 执行状态

通过 LSU 的地址和异常检查后，store 可以经 `ST_WB` 向 RTU 报告对应 IID 的完成状态。

这里的 `cmplt` 表示 LSU 已完成这次执行阶段的处理，并不表示数据已写入 D-cache 或外部内存。Store 仍需要等待 RTU commit。

### 7. RTU commit：允许 SQ 排出

RTU 按程序顺序提交指令。SQ 根据 commit IID 标记对应的 store 已提交。一个普通 store entry 要满足已提交、数据有效、无需重发等条件，才有资格产生 pop 请求。

SQ 使用年龄状态选择最老的可排出 entry，避免年轻 store 越过更老 store 进入后续写入路径。

### 8. SQ → WMB CE → WMB：合并并执行写入

SQ 将可排出的 store 交给 WMB 的合并入口 `WMB CE`。CE 根据地址、已有 WMB 项和资源状态，决定新建 WMB entry 或合并数据；遇到冲突或资源不足时会等待。

随后 WMB 按访问属性推进写操作：cacheable store 更新 D-cache；非缓存、强序等访问可走 BIU 写请求路径。WMB 与 cache/bus 的仲裁和等待决定真正写入存储层次的时间。

## 关键结论

- LSIQ 发射可以乱序；IID 保留程序年龄，SQ/WMB 再按要求维护 store 的排出顺序。
- 地址和数据是两条路径，SQ 负责保存地址并与稍后到达的数据配对。
- `ST_WB` 报告 LSU 执行完成，不等于 store 已经写入内存系统。
- 普通 store 在 RTU commit 后才具备从 SQ 排出的条件，之后经 WMB CE/WMB 合并并写入 D-cache 或发出 BIU 请求。

## RTL 入口

- 地址生成与 MMU 接口：`ct_lsu_st_ag.v`
- Store DC 检查和 SQ 创建条件：`ct_lsu_st_dc.v`
- D-cache 检查、异常/重发和完成请求：`ct_lsu_st_da.v`
- 写数据接收：`ct_lsu_sd_ex1.v`
- SQ 管理、依赖检查和 pop：`ct_lsu_sq.v`、`ct_lsu_sq_entry.v`
- WMB 合并和写入调度：`ct_lsu_wmb.v`、`ct_lsu_wmb_ce.v`
- Store 完成状态到 RTU：`ct_lsu_st_wb.v`
