# BFT-SMaRt 重配置机制源码分析

本文基于当前仓库源码，分析 README 中“增加/减少节点”的 reconfiguration 机制，重点回答三件事：

1. 触发方式
2. 协议流程
3. 是否导致节点停机

---

## 1. 触发方式

### 1.1 外部触发入口（README 命令）

README 明确给出动态增删节点命令，入口是 DefaultVMServices：

- 增加节点命令见 [README.md](README.md#L85)
- 删除节点命令见 [README.md](README.md#L90)

对应主程序逻辑在 [src/main/java/bftsmart/reconfiguration/util/DefaultVMServices.java](src/main/java/bftsmart/reconfiguration/util/DefaultVMServices.java#L14)：

- 参数长度为 4 时调用 addServer，见 [src/main/java/bftsmart/reconfiguration/util/DefaultVMServices.java](src/main/java/bftsmart/reconfiguration/util/DefaultVMServices.java#L24)
- 参数长度为 1 时调用 removeServer，见 [src/main/java/bftsmart/reconfiguration/util/DefaultVMServices.java](src/main/java/bftsmart/reconfiguration/util/DefaultVMServices.java#L15)

### 1.2 可信管理者与鉴权

reconfiguration 请求不是任意客户端都能生效。服务端只接受来自 TTP 且签名正确的请求：

- TTP id 来自配置项 system.ttp.id，见 [src/main/java/bftsmart/reconfiguration/util/TOMConfiguration.java](src/main/java/bftsmart/reconfiguration/util/TOMConfiguration.java#L256)
- 服务端校验 sender 是否等于 TTP id，并校验签名，见 [src/main/java/bftsmart/reconfiguration/ServerViewController.java](src/main/java/bftsmart/reconfiguration/ServerViewController.java#L121)

请求签名由发起端生成：

- Reconfiguration.execute 中使用私钥对请求字符串签名，见 [src/main/java/bftsmart/reconfiguration/Reconfiguration.java](src/main/java/bftsmart/reconfiguration/Reconfiguration.java#L75)

### 1.3 触发消息类型

重配置请求通过正常 BFT 请求路径发送，但消息类型为 RECONFIG：

- 发起端调用 ServiceProxy.invoke 并指定 TOMMessageType.RECONFIG，见 [src/main/java/bftsmart/reconfiguration/Reconfiguration.java](src/main/java/bftsmart/reconfiguration/Reconfiguration.java#L79)
- 副本交付时识别 RECONFIG 并入队更新，见 [src/main/java/bftsmart/tom/ServiceReplica.java](src/main/java/bftsmart/tom/ServiceReplica.java#L416)

结论：该机制是“外部命令触发 + TTP 身份与签名约束 + 走 RECONFIG 共识通道”。

---

## 2. 协议流程（从命令到新视图生效）

### 2.1 管理端发起

1. DefaultVMServices 解析参数，调用 VMServices 的 addServer/removeServer，见 [src/main/java/bftsmart/reconfiguration/util/DefaultVMServices.java](src/main/java/bftsmart/reconfiguration/util/DefaultVMServices.java#L14)
2. VMServices 创建 ViewManager，并执行 executeUpdates，见 [src/main/java/bftsmart/reconfiguration/VMServices.java](src/main/java/bftsmart/reconfiguration/VMServices.java#L56)
3. ViewManager 将变更写入 Reconfiguration 请求对象，再执行 rec.execute，见 [src/main/java/bftsmart/reconfiguration/ViewManager.java](src/main/java/bftsmart/reconfiguration/ViewManager.java#L94) 与 [src/main/java/bftsmart/reconfiguration/ViewManager.java](src/main/java/bftsmart/reconfiguration/ViewManager.java#L110)

### 2.2 共识排序与执行

1. 请求以 RECONFIG 类型进入共识日志，副本在交付阶段将其入更新队列，见 [src/main/java/bftsmart/tom/ServiceReplica.java](src/main/java/bftsmart/tom/ServiceReplica.java#L416)
2. DeliveryThread 在该共识批次交付后检查 hasUpdates，存在更新则执行 processReconfigMessages，见 [src/main/java/bftsmart/tom/core/DeliveryThread.java](src/main/java/bftsmart/tom/core/DeliveryThread.java#L318)
3. processReconfigMessages 调用 ServerViewController.executeUpdates 计算新视图并回包，见 [src/main/java/bftsmart/tom/core/DeliveryThread.java](src/main/java/bftsmart/tom/core/DeliveryThread.java#L394)

### 2.2.1 RECONFIG 是否经历完整 BFT 共识流程

结论：会。RECONFIG 在副本侧被当作“需要有序处理的请求”，进入与普通 ORDERED_REQUEST 相同的共识主路径，而不是旁路配置通道。

关键证据链如下：

1. TOMLayer.requestReceived 的类型分发里，RECONFIG 与 ORDERED_REQUEST 同处一个处理分支（非 read-only），见 [src/main/java/bftsmart/tom/core/TOMLayer.java](src/main/java/bftsmart/tom/core/TOMLayer.java#L384)
2. 进入该分支后，统一走 clientsManager.requestReceived 并触发 batch/propose 机制，见 [src/main/java/bftsmart/tom/core/TOMLayer.java](src/main/java/bftsmart/tom/core/TOMLayer.java#L406)
3. DeliveryThread 对“含 RECONFIG 的决定”做显式识别，说明 RECONFIG 是先被某个 consensus instance 决定后才进入重配置执行，见 [src/main/java/bftsmart/tom/core/DeliveryThread.java](src/main/java/bftsmart/tom/core/DeliveryThread.java#L120)
4. 如果一个共识批次只有 reconfiguration，不会交付业务命令而是 no-op 给 recoverer，这进一步说明 RECONFIG 也是以“共识决定批次”的形式出现，见 [src/main/java/bftsmart/tom/ServiceReplica.java](src/main/java/bftsmart/tom/ServiceReplica.java#L433)

补充说明：

- RECONFIG 与 ORDERED_REQUEST 的差异主要在“决定之后的执行动作”：ORDERED_REQUEST 进入应用执行；RECONFIG 进入 SVController.enqueueUpdate + DeliveryThread.processReconfigMessages 进行视图切换。
- 因此可以把 RECONFIG 理解为“走完整有序共识路径的系统控制命令”。

### 2.3 新视图计算与安装

ServerViewController.executeUpdates 会解析变更集合并构造新视图：

- 解析 ADD_SERVER / REMOVE_SERVER / CHANGE_F，见 [src/main/java/bftsmart/reconfiguration/ServerViewController.java](src/main/java/bftsmart/reconfiguration/ServerViewController.java#L143)
- 合成 nextV，生成 View 并 reconfigureTo(newV)，见 [src/main/java/bftsmart/reconfiguration/ServerViewController.java](src/main/java/bftsmart/reconfiguration/ServerViewController.java#L184) 与 [src/main/java/bftsmart/reconfiguration/ServerViewController.java](src/main/java/bftsmart/reconfiguration/ServerViewController.java#L222)
- 返回 ReconfigureReply（包含新视图、joinSet、执行 cid、leader），见 [src/main/java/bftsmart/reconfiguration/ServerViewController.java](src/main/java/bftsmart/reconfiguration/ServerViewController.java#L238) 与 [src/main/java/bftsmart/reconfiguration/ReconfigureReply.java](src/main/java/bftsmart/reconfiguration/ReconfigureReply.java#L46)

### 2.4 回包与连接更新

DeliveryThread 在新视图安装后：

- 向原 RECONFIG 请求发送者返回 RECONFIG 回复，见 [src/main/java/bftsmart/tom/core/DeliveryThread.java](src/main/java/bftsmart/tom/core/DeliveryThread.java#L399)
- 仍在新视图内的副本调用 updateServersConnections 更新连接，见 [src/main/java/bftsmart/tom/core/DeliveryThread.java](src/main/java/bftsmart/tom/core/DeliveryThread.java#L404)

### 2.5 新加入节点接入（Join 通知）

这一步是很多人容易忽略的“第二通道”：

1. ViewManager 在管理端收到 ReconfigureReply 后，会把 VMMessage 主动发给新增节点 addIds，见 [src/main/java/bftsmart/reconfiguration/ViewManager.java](src/main/java/bftsmart/reconfiguration/ViewManager.java#L116)
2. ServerConnection 对来自 TTP 的连接启用专门的 TTPReceiverThread，并把 VMMessage 交给 ServiceReplica.joinMsgReceived，见 [src/main/java/bftsmart/communication/server/ServerConnection.java](src/main/java/bftsmart/communication/server/ServerConnection.java#L114) 与 [src/main/java/bftsmart/communication/server/ServerConnection.java](src/main/java/bftsmart/communication/server/ServerConnection.java#L465)
3. 加入节点收到 join 消息后执行 processJoinResult，初始化 TOM 层并放行启动等待，见 [src/main/java/bftsmart/tom/ServiceReplica.java](src/main/java/bftsmart/tom/ServiceReplica.java#L172)

结论：协议上不是“直接改配置文件即生效”，而是“RECONFIG 共识执行 + join 专用通知”组合流程。

---

## 3. 是否会导致节点停机

### 3.1 对仍在新视图中的副本

不会主动停机，只做连接更新：

- 逻辑分支在 DeliveryThread.processReconfigMessages，成员仍在新视图则 updateServersConnections，见 [src/main/java/bftsmart/tom/core/DeliveryThread.java](src/main/java/bftsmart/tom/core/DeliveryThread.java#L398)

### 3.2 对被移出新视图的副本

会触发 restart，等价于一次停止再重启：

- 不在新视图分支直接调用 receiver.restart，见 [src/main/java/bftsmart/tom/core/DeliveryThread.java](src/main/java/bftsmart/tom/core/DeliveryThread.java#L406)
- restart 内部先 shutdown TOM 线程并 join，再重新 init，见 [src/main/java/bftsmart/tom/ServiceReplica.java](src/main/java/bftsmart/tom/ServiceReplica.java#L309)

这意味着“被移除的节点”在本实现中会经历服务中断。

### 3.3 对新加入节点

典型行为是“先启动进程并等待”，收到 TTP join 消息后才真正进入服务：

- 如果本节点不在当前视图，初始化时阻塞等待 canProceed，见 [src/main/java/bftsmart/tom/ServiceReplica.java](src/main/java/bftsmart/tom/ServiceReplica.java#L159)
- 收到 join 消息后 signal 并继续初始化，见 [src/main/java/bftsmart/tom/ServiceReplica.java](src/main/java/bftsmart/tom/ServiceReplica.java#L181)

这不是传统意义“停机”，更准确说是“未入组前不对外提供副本服务”。

### 3.4 触发重配置时，正常 BFT 共识会不会被停止/阻塞

结论先行：

- 集群级别看，不会因为触发 reconfiguration 而“全局停止”正常 BFT 共识。
- 单副本级别看，会在“该副本的交付线程”里插入一次 reconfig 后处理，因此会有短暂的本地串行阻塞窗口。

证据与解释：

1. reconfiguration 路径没有调用 DeliveryThread.pauseDecisionDelivery/resumeDecisionDelivery；这些暂停接口主要由状态传输使用，见 [src/main/java/bftsmart/statemanagement/StateManager.java](src/main/java/bftsmart/statemanagement/StateManager.java#L222)
2. DeliveryThread 在每轮决定交付后，若有更新就在同一线程内执行 processReconfigMessages，这说明阻塞点是“本地交付线程串行执行”，见 [src/main/java/bftsmart/tom/core/DeliveryThread.java](src/main/java/bftsmart/tom/core/DeliveryThread.java#L318)
3. RECONFIG 与普通有序请求可在同一 decided batch 中被遍历处理，随后再统一触发 reconfig 后处理，不是提前打断共识，见 [src/main/java/bftsmart/tom/ServiceReplica.java](src/main/java/bftsmart/tom/ServiceReplica.java#L364)

因此更准确的描述是：

- 共识协议本身继续运行；
- 但在安装新视图的那个交付点，本地会有一个“额外处理段”，会推迟该副本后续消息交付。

### 3.5 阻塞时长与是否会出现明显长延迟

通常情况下：

- 延迟增加为“有界、一次性抖动”，一般不会长期拉高；
- 额外开销主要来自 reconfig 后处理，而非 RECONFIG 进入共识本身（它和普通 ORDERED 请求同路径）。

源码上可见的主要耗时点：

1. 视图重算与安装（内存计算 + 持久化 currentView），见 [src/main/java/bftsmart/reconfiguration/ServerViewController.java](src/main/java/bftsmart/reconfiguration/ServerViewController.java#L184)
2. 更新副本连接（增删连接、可能触发新连接建立），见 [src/main/java/bftsmart/communication/server/ServersCommunicationLayer.java](src/main/java/bftsmart/communication/server/ServersCommunicationLayer.java#L176)
3. 新建 ServerConnection 时可能同步发起 SSL/TLS 建连，见 [src/main/java/bftsmart/communication/server/ServerConnection.java](src/main/java/bftsmart/communication/server/ServerConnection.java#L98)

这些操作都在 reconfig 处理阶段触发，所以会在该时刻形成额外延迟峰值。若网络连通性差或新增节点不可达，建连阶段可能放大这次峰值。

和“正常 BFT 共识”相比可以总结为：

- RECONFIG 的共识阶段：与普通 ORDERED 请求同量级。
- RECONFIG 的生效阶段：比普通业务请求多出“视图切换 + 连接重建”成本，因此更容易出现短时尾延迟上升。
- 对被移除节点：会走 restart 路径，局部中断显著高于普通共识开销，见 [src/main/java/bftsmart/tom/core/DeliveryThread.java](src/main/java/bftsmart/tom/core/DeliveryThread.java#L406)

---

## 4. 关键实现特征与运维注意点

1. 重配置请求必须由 TTP 身份并签名，否则被丢弃，见 [src/main/java/bftsmart/reconfiguration/ServerViewController.java](src/main/java/bftsmart/reconfiguration/ServerViewController.java#L121)
2. README 强调 currentView 需要外部分发一致，系统不自动分发，见 [README.md](README.md#L95)
3. 被移除节点并非“优雅下线”实现，源码中还留有 LEAVE TODO，见 [src/main/java/bftsmart/reconfiguration/ServerViewController.java](src/main/java/bftsmart/reconfiguration/ServerViewController.java#L299)

整体判断：

- 触发方式是可信管理端命令触发
- 协议流程是有序共识执行，不是本地热改配置
- 对集群其余节点一般无需停机，但被移除节点会触发重启路径，新加入节点会在收到 join 通知前阻塞等待

---

## 5. 时序图风格流程（RECONFIG）

下面给出一版“文本时序图”，把 RECONFIG 与普通有序请求的共识路径和后处理差异放在一张图里。

```
TTP/DefaultVMServices        ServiceProxy          Replica TOMLayer/Consensus      DeliveryThread+SVController     Join Replica
	|                         |                           |                                |                      |
1. CLI  | add/remove 命令        |                           |                                |                      |
	|------------------------>|                           |                                |                      |
2. 组包 | Reconfiguration.execute |                           |                                |                      |
	| 生成签名并 invoke(RECONFIG)                          |                                |                      |
	|------------------------>|                           |                                |                      |
3. 广播 |                         | TOM 多播 RECONFIG        |                                |                      |
	|                         |-------------------------->| requestReceived: RECONFIG      |                      |
	|                         |                           | (与 ORDERED_REQUEST 同分支)     |                      |
4. 共识 |                         |                           | 进入 pending/batch/propose/decide|                      |
	|                         |                           |======== BFT 共识完成 ==========>|                      |
5. 交付 |                         |                           | deliverMessages                 | enqueueUpdate        |
	|                         |                           |-------------------------------->| executeUpdates       |
6. 生效 |                         |                           |                                | 安装 newView          |
	|                         |                           |                                | updateConnections     |
7. 回复 | 收到 ReconfigureReply   |<--------------------------| RECONFIG reply                  |                      |
	| 更新本地 view            |                           |                                |                      |
8. 入组 |                         |                           |                                | VMMessage(join info)  |
	|                         |                           |                                |--------------------->|
9. 放行 |                         |                           |                                |                      | joinMsgReceived
	|                         |                           |                                |                      | processJoinResult+initTOMLayer
```

对应代码定位：

1. 发起与 RECONFIG 调用：[src/main/java/bftsmart/reconfiguration/Reconfiguration.java](src/main/java/bftsmart/reconfiguration/Reconfiguration.java#L75)
2. RECONFIG 与 ORDERED_REQUEST 同分支接入：[src/main/java/bftsmart/tom/core/TOMLayer.java](src/main/java/bftsmart/tom/core/TOMLayer.java#L384)
3. 决定后执行重配置：[src/main/java/bftsmart/tom/core/DeliveryThread.java](src/main/java/bftsmart/tom/core/DeliveryThread.java#L394)
4. 新节点 join 通知与接入：[src/main/java/bftsmart/reconfiguration/ViewManager.java](src/main/java/bftsmart/reconfiguration/ViewManager.java#L116)、[src/main/java/bftsmart/tom/ServiceReplica.java](src/main/java/bftsmart/tom/ServiceReplica.java#L172)
