# OpenConnect Master 事务化控制面设计

- 日期：2026-09-08
- 基线提交：`e03f2aa4d15406895df766113228826543d27e85`
- 状态：交互设计已批准，等待书面设计复核
- 目标版本：保持现有对外版本、CLI 与安装体验；版本发布策略不属于本设计

## 1. 背景与目标

OpenConnect Master 当前向 Linux VPS 提供两个运行模式：

1. `OpenConnect --script-tun + ocproxy` 提供本机 TCP/IPv4 SOCKS5 出口，不修改宿主机路由、防火墙、sysctl 或 DNS。
2. OpenConnect 在 `ocm0` 上建立整机全局 VPN，并用源地址策略路由保护既有公网入站连接的回程。

现有数据面在已验证的单出口 VPS 上能够达到产品目标，主要风险集中在控制面：活动配置依赖可变账户索引、多个 systemd/manager 进程缺少统一运行代际、rollback 与 `KEEP` 存在竞态、模式替换未把旧网络状态的成功清理作为提交前置条件、安装 I/O 不是完整事务。

本设计选择保留两个现有数据面，重构其上方的状态、并发、持久化、安装和错误恢复逻辑。只有能消除已证明故障或显著提高可验证性的改动才进入实现。

## 2. 成功标准

实现完成后必须同时满足：

- 功能目标、公开命令、菜单、交互输入、正常路径输出和退出码保持兼容。
- 账户文件、四字段 profile、默认安装路径及 systemd 单元名称保持兼容。
- SOCKS 模式仍不修改宿主路由、防火墙、sysctl 或 DNS。
- Global 模式在支持的单出口拓扑上保持普通出站经 VPN、既有公网入站原路回程。
- 账户删除或重排不能改变当前运行代际在自动重启时使用的凭据。
- 旧代际的 health、rollback 或 cleanup 不能操作新代际。
- 未完成的 global cleanup 必须阻止启动任意下一模式。
- `KEEP` 与 rollback 同时发生时必须只有一个确定赢家，不能伪报取消成功。
- 不增加常驻 daemon、运行时语言、容器、netns、veth、nftables 或 iptables 依赖。
- 现有测试、新增回归测试、行为差分、Linux 隔离测试、code review 和最终验证全部通过。

## 3. 非目标

以下内容不在本轮施工范围：

- 把 SOCKS 模式扩展为通用 UDP、IPv6 或透明代理。
- 用 GOST、sing-box OpenConnect endpoint、Docker、VRF 或 netns 替换现有数据面。
- 自动支持多 WAN、ECMP、DNAT 容器、公网地址跨多个出口设备等无法唯一证明回程的拓扑。
- 接管或改写用户的 nftables/iptables、Docker 网络、DDNS、DNS 服务或第三方 policy routing。
- 改变账户存储为密钥服务或加密数据库。
- 重写 README、改变菜单风格或增加新的公开管理命令。
- 仅为减少文件行数而拆分代码或更换实现语言。

## 4. 已确认问题

### 4.1 可变账户索引污染自动重启

`profile.conf` 仅保存 `ACCOUNT_INDEX`，而 systemd 每次启动都会重新从当前账户数组按索引读取记录。删除活动账户之前的记录会重排索引，使后续自动重启静默改用另一账户；删除活动记录可能使 health 与 service 进入失败循环。

### 4.2 rollback 与 `KEEP` 缺少原子所有权

独立 rollback 不在 manager 锁域中，`cancel_rollback` 吞掉错误且不验证最终状态。timer 到期和用户输入 `KEEP` 可以同时执行，前台可能报告取消成功，随后连接仍被 rollback 停止。三分钟 timer 又从健康等待之前开始计时，不能严格保证健康成功后的完整 120 秒输入窗口。

### 4.3 Global 到 SOCKS 的清理缺口

`ExecStopPost=-...` 会让 systemd 忽略 cleanup 失败，模式替换只确认单元停稳，没有再次显式验证旧 global 路由已清理。随后 profile 可被覆盖为 proxy，proxy 的健康检查也不会发现旧策略路由残留。

### 4.4 状态和安装事务分散

运行事实分散在 profile、账户文件、route owner、health 文件、persistent units 和 transient rollback unit 中，没有共同的 `run_id` 与阶段。unit 和程序副本直接覆盖，失败时可能留下跨版本组合；同名 foreign unit 也缺少归属保护。

### 4.5 支持边界未被强制执行

Global 回程实现只复制第一条非 VPN 默认路由，并保护该出口设备上的地址。多 WAN、ECMP 或跨接口公网地址没有被证明安全，但当前实现可能继续启动，而不是明确拒绝。

## 5. 备选方案

### 方案 A：局部补丁

只增加账户删除保护、rollback 状态复核、模式切换后的显式 cleanup 和原子文件写入。

- 优点：改动少、交付快。
- 缺点：多个进程仍从分散状态推导事实，同类竞态容易再次出现。

### 方案 B：事务化控制面（采用）

保留数据面和单文件发行物，引入不可变运行快照、持久状态机、运行代际、短事务锁、可验证 cleanup 及原子安装。

- 优点：直接消除三个重要缺陷；失败恢复有确定语义；大量逻辑可在 mock 环境验证。
- 缺点：内部生命周期代码需要较大重构。

### 方案 C：替换数据面

使用 named netns + GOST/sing-box，或 sing-box 原生 OpenConnect endpoint。

- 优点：指定应用隔离、UDP/IPv6 扩展能力更强。
- 缺点：新增依赖；不能等价实现当前整机全局语义；目标 VPN 的 `nc/pulse/anyconnect` 认证兼容和长期重连尚未在本项目环境证明。

## 6. 总体架构

公开发行物仍为一个可直接下载执行的 `oc_master.sh`。`/usr/local/sbin/oc-master` 继续作为安装后的持久程序本体，`/usr/local/bin/ocm` 继续是快捷符号链接。该持久副本由 systemd `ExecStart`、`ExecStopPost` 和独立 rollback 使用，不能删除。

代码内部按职责组织为五层，物理上可以继续保留在同一文件：

```text
CLI / 菜单 / 原有输出
          │
          ▼
生命周期协调器 ──────── 账户与配置存储
          │
          ▼
运行代际状态机 run_id
          │
     ┌────┴────┐
     ▼         ▼
 SOCKS 后端   Global 后端
 ocproxy      policy routing
     └────┬────┘
          ▼
systemd / OpenConnect / ip / curl 适配层
```

职责边界：

- CLI 层只负责分派、菜单、输入和兼容输出。
- 生命周期协调器负责启动、确认、停止、模式替换与恢复，不直接拼接网络命令。
- 存储层严格解析并原子写入账户、profile、运行快照和状态。
- 后端统一实现 `preflight / prepare / build_openconnect_args / health / cleanup`。
- 适配层封装 systemd、OpenConnect、`ip`、`ss` 和 `curl` 副作用，以便测试替换。

## 7. 对外兼容契约

以下行为必须保持：

- 无参数进入原中文主菜单。
- 公开命令仍为 `start-proxy`、`start-global`、`stop`、`accounts`、`deps`、`install`、`uninstall`、`status`、`check`、`logs`。
- 未知命令返回 `2`；现有取消、信号和常规失败返回码不变。
- 现有菜单编号、确认词 `GLOBAL`、`GLOBAL-DDNS-RISK`、`KEEP`、`REMOVE` 不变。
- `/root/.vpn_accounts.env` 继续使用六字段竖线格式，并兼容旧五字段记录。
- `/etc/oc-master/profile.conf` 继续只包含 `MODE`、`ACCOUNT_INDEX`、`VPN_PROTOCOL`、`SOCKS_PORT`。
- `/usr/local/sbin/oc-master`、`/usr/local/bin/ocm`、三个 persistent systemd unit 名、固定 rollback unit 名保持。
- `ocm0`、表 `51888/51889` 和优先级 `10000/10001` 在受支持的单出口场景保持。
- SOCKS 继续监听 `127.0.0.1:PORT`，使用 `ocproxy -k 30`。
- OpenConnect 协议集合、认证组、密码 stdin、reconnect 和 tcp keepalive 行为保持。
- `Restart=always`、15 秒间隔、300 秒内三次限速、health timer 周期保持。
- stop 和 uninstall 的账户/软件包保留语义保持。
- 正常路径终端文案不加入 `run_id` 或新的噪声。仅原先不安全、无确定语义的失败分支可以增加明确错误。

## 8. 持久状态模型

### 8.1 不可变运行快照

新增 `/etc/oc-master/active-run.conf`，权限 `root:root 0600`。每次显式启动创建新文件；同一 `run_id` 生命周期内不修改。

概念字段：

```text
FORMAT_VERSION=1
RUN_ID=<kernel UUID>
CREATED_BOOT_ID=<Linux boot ID>
MODE=proxy|global
ACCOUNT_INDEX=<兼容展示用零基索引>
VPN_PROTOCOL=anyconnect|nc|pulse
SOCKS_PORT=<proxy 端口或空>
ACCOUNT_RECORD=<完整、单行、六字段账户记录>
```

`ACCOUNT_RECORD` 允许包含 `=`、空格和 shell 元字符，但现有账户格式本身不允许换行或字段内 `|`。解析器按精确键前缀读取，绝不 `source`、`eval` 或进行 shell 展开。

该快照会在磁盘上形成第二份明文凭据，这是保持“账户删除后当前代际仍可自动重启”所必需的明确代价。它与原账户文件采用相同的 root-only 信任边界，不进入备份文件、日志或命令行，并在卸载时删除。

### 8.2 可变运行状态

新增 `/etc/oc-master/run-state.conf`，权限 `root:root 0600`，每次转换整文件原子替换。

概念字段：

```text
FORMAT_VERSION=1
RUN_ID=<与 active-run 一致>
PHASE=<状态枚举>
DESIRED_ACTIVE=0|1
ROLLBACK_DEADLINE=<epoch 或 0>
```

阶段枚举：

- `PREPARING`
- `STARTING`
- `RUNNING`
- `AWAITING_CONFIRMATION`
- `CONFIRMED`
- `ROLLBACK_CLAIMED`
- `STOPPING`
- `CLEANUP_FAILED`
- `CLEANED`

`DESIRED_ACTIVE` 用于区分意外进程退出与人工停止。意外退出时仍为 `1`，允许 systemd 在 cleanup 成功后重启；人工 stop/rollback 在执行 systemctl 前将其置为 `0`。

### 8.3 临时运行文件

保留 `/run/oc-master`，并增加：

- `service.run-id`：当前 MainPID 在 exec OpenConnect 前写入的代际。
- health failure/cooldown 文件：内容同时携带 `run_id`。

`/run` 文件只用于当前启动周期的协调，不是持久真相。持久真相始终是 `active-run.conf` 与 `run-state.conf`。

### 8.4 严格解析和原子写入

- 新状态文件必须有唯一 `FORMAT_VERSION=1`。
- 必填字段缺失、重复、非法枚举、非法 UUID、未知键或未知版本均拒绝继续。
- 不通过 `source` 加载任何状态文件。
- 写入使用目标目录内 `mktemp`、完整内容和权限校验后 `mv` 原子替换。
- 状态转换使用 compare-and-set：调用方必须同时声明期望 `run_id` 和允许的旧阶段。

新增路径默认从现有 `CONFIG_DIR/RUNTIME_DIR` 派生，并保留环境覆盖能力，确保现有隔离测试不接触真实 `/etc` 或 `/run`。

## 9. 状态机与不变量

### 9.1 正常转换

Proxy：

```text
CLEANED/无状态 → PREPARING → STARTING → RUNNING → STOPPING → CLEANED
```

Global：

```text
CLEANED/无状态 → PREPARING → STARTING → AWAITING_CONFIRMATION
                                            │             │
                                          KEEP      timer/timeout
                                            │             │
                                        CONFIRMED  ROLLBACK_CLAIMED
                                            │             │
                                            └──→ STOPPING ─┘
                                                   │
                                                CLEANED
```

任意需要 cleanup 的阶段如果无法证明清理成功，进入 `CLEANUP_FAILED`。

### 9.2 强制不变量

- `active-run.RUN_ID` 必须等于 `run-state.RUN_ID`，否则拒绝网络变更。
- 只有 `STARTING/RUNNING/AWAITING_CONFIRMATION/CONFIRMED` 且 `DESIRED_ACTIVE=1` 的当前代际可以运行或重启 service。
- 只有 `AWAITING_CONFIRMATION` 可以转换为 `CONFIRMED` 或 `ROLLBACK_CLAIMED`。
- 一旦进入 `ROLLBACK_CLAIMED/STOPPING`，`KEEP` 不得成功。
- `CLEANUP_FAILED` 时任何新模式启动必须先完成显式恢复。
- 新 run 的 snapshot/profile 不得在旧 run 单元与网络状态清理完成前提交。
- route owner 和 route plan 只有在清理后验证成功才删除。
- 旧 `run_id` 的 health、rollback 和 cleanup 只能无副作用退出。

## 10. 并发与锁设计

### 10.1 Manager lock

保留 `/run/lock/oc-master.lock` 及当前非阻塞语义，串行化公开变更型命令。只读 `status/check/logs` 仍不占 manager lock。

### 10.2 State lock

新增 `/run/lock/oc-master-state.lock`，只保护：

- 读取并验证当前 snapshot/state 组合。
- compare-and-set 状态转换。
- health 计数和 cooldown 代际更新。

持有 state lock 时禁止读取用户输入、sleep、HTTP 探测、执行 `systemctl` 或进行长网络操作。

### 10.3 Service-operation lock

新增 `/run/lock/oc-master-service.lock`，串行化可能反转服务目标状态的操作：

- start
- stop
- restart
- rollback claim 后的 stop

公开 manager 操作和 rollback 可等待该锁；health 获取不到时跳过本轮，避免阻塞停止流程。

固定锁序：

```text
manager lock（仅公开命令） → service-operation lock → state lock（短时）
```

`ExecStopPost` 不获取 service-operation lock，且调用者在等待 systemd 时不能持有 state lock，因此不会形成 systemctl 与 cleanup 的循环等待。

## 11. 生命周期算法

### 11.1 显式启动

1. 获取 manager lock。
2. 检查依赖和用户输入，但不修改网络。
3. 获取 service-operation lock。
4. 停止旧 timer、health 和主 service，并等待稳定状态。
5. 根据旧状态及 owner marker 执行显式 cleanup；验证失败则进入 `CLEANUP_FAILED` 并终止。
6. 执行新后端只读 preflight；Global 在内存中生成完整 route plan，但此时不落网络状态。
7. 创建 kernel UUID，写 `PREPARING` 状态。
8. 原子写入 snapshot、原四字段 profile，以及 Global 的 route plan，并重新解析验证。
9. 转换为 `STARTING`。
10. Global 在任何网络变更前武装 `_rollback RUN_ID` 三分钟 transient timer。
11. 启动主 service 和 health timer，释放 service-operation lock。
12. 最多等待现有 60 秒数据面健康窗口。
13. Proxy 转换为 `RUNNING` 并成功返回。
14. Global 转换为 `AWAITING_CONFIRMATION`，记录 `now + 120s`，等待原 `KEEP` 输入。

任一步失败均根据当前阶段调用显式 stop/cleanup；不能证明安全时保留状态和 owner marker。

### 11.2 systemd service 运行

`_service_run`：

1. 严格读取 snapshot/state，验证相同 `run_id` 和允许阶段。
2. 对跨 boot 的未确认 global、`CLEANUP_FAILED` 或非 active 目标返回专用不可重启退出码。
3. 将 `run_id` 写入 `/run/oc-master/service.run-id`。
4. Global 执行本代际 route plan apply；Proxy 不修改宿主网络。
5. 构造参数数组，使用 stdin 传密码并 `exec openconnect`。

systemd unit 增加 `RestartPreventExitStatus=` 对应专用退出码，避免确定性坏状态触发 `Restart=always` 风暴。正常意外退出仍保持现有 restart 行为。

### 11.3 ExecStopPost

- 从 `service.run-id` 确定正在清理的代际。
- 旧代际与当前 state 不匹配时不得修改当前 state。
- Global 始终尝试清理本项目拥有的路由；Proxy 只清运行态文件。
- 若当前仍 `DESIRED_ACTIVE=1`，cleanup 成功后保留原 active 阶段，允许 systemd 重启。
- 若已由 stop/rollback 置为 inactive，cleanup 成功后转为 `CLEANED`。
- cleanup 失败转为 `CLEANUP_FAILED`，下一次 `_service_run` 使用不可重启退出码拒绝继续。

### 11.4 健康检查与 restart

1. 读取当前 `run_id` 和 active 阶段。
2. service-operation lock 正被生命周期操作持有时跳过本轮，不累计失败。
3. 探测完成后重新验证 `run_id` 与阶段。
4. failure 和 cooldown 文件必须匹配同一 `run_id`。
5. 第三次连续失败且不在 900 秒 cooldown 时，获取 service-operation lock，再次复核状态后 restart。
6. stop/rollback 已把阶段改为 inactive 时，health 无权 restart。

保留当前启动限速策略。OpenConnect 自身持续退出达到 StartLimit 后仍需人工处理，避免错误凭据被长期自动提交。

### 11.5 `KEEP` 与独立 rollback

Global 仍在启动前武装三分钟 transient timer，参数携带 `run_id`。

健康成功后，manager 写入完整的 120 秒 `ROLLBACK_DEADLINE`。timer worker 触发时：

1. 读取 state；代际过期、已确认、已停止或已清理则无副作用退出。
2. 若仍处于启动阶段且三分钟已到，立即尝试 claim。
3. 若为 `AWAITING_CONFIRMATION` 且 deadline 尚未到，释放所有锁，等待剩余时间后重读。
4. deadline 到达后，按 service-operation → state 顺序加锁并执行 compare-and-set。
5. 只有成功写入 `ROLLBACK_CLAIMED` 的 worker 才能 stop/cleanup。

`KEEP` 在 state lock 内将同一代际从 `AWAITING_CONFIRMATION` 原子转换为 `CONFIRMED`。如果 rollback 已 claim，`KEEP` 必须失败且不得输出取消成功；如果 `KEEP` 先成功，任何已启动的旧 worker 重读 state 后都只能退出。随后停止 transient timer/service；即使 systemd 单元清理失败，持久 `CONFIRMED` 状态也已撤销该 worker 的回滚权限。此时 `KEEP` 仍代表逻辑确认成功，但必须额外输出可操作警告并保留单元清理证据；只有状态提交本身失败时才按确认失败处理。

### 11.6 显式停止和模式替换

Stop：

1. 获取 manager 和 service-operation lock。
2. 在 state lock 内把当前 run 转为 `STOPPING`、`DESIRED_ACTIVE=0`。
3. 按 timer → health service → main service 顺序停止并验证。
4. 显式调用后端 cleanup，再次验证网络基线。
5. 成功后转为 `CLEANED` 并取消 rollback；失败保留 rollback 和 owner 信息。

模式替换复用完全相同的停止事务。只有 `CLEANED` 才能写入下一代 snapshot/profile，因此 Global → Proxy 不可能带着已知残留报告成功。

## 12. SOCKS 后端

数据路径不变：

```text
OpenConnect --script-tun → ocproxy -k 30 -D PORT → 127.0.0.1:PORT
```

后端职责：

- `preflight`：端口合法且当前无 TCP listener；依赖存在；不触碰网络。
- `prepare`：无宿主网络动作。
- `build_openconnect_args`：保持当前 protocol、user、stdin password、authgroup、timestamp、reconnect、tcp keepalive 和 script-tun 参数。
- `health`：MainPID 必须是 OpenConnect；端口 listener 必须属于 `oc-master.service` cgroup；真实 SOCKS HTTPS 请求成功。
- `cleanup`：只处理项目运行态文件，不修改路由、防火墙、sysctl 或 DNS。

listener 归属通过 root 可见的 `ss` PID 信息与 systemd ControlGroup 交叉验证。无法证明归属时判为不健康，不能只凭“该端口有人监听”通过。

## 13. Global 后端

### 13.1 支持边界

本轮只承诺能唯一证明的单出口拓扑：

- 每个地址族最多一条有效的非 VPN 默认出口。
- 同一出口接口可有多个 global 地址。
- 项目保留的接口、表和 rule priority 未被占用。

存在多个不同出口、ECMP、多 WAN、跨出口公网地址或无法解析的现有 policy rule 时，Global 必须在网络写入前 fail-closed。项目不引入 connmark/nftables 来猜测复杂回程。

### 13.2 Route plan

新增 `/etc/oc-master/route-plan.conf`，权限 `0600`。它记录：

- 格式版本和 `run_id`。
- 原 IPv4/IPv6 默认路由整行。
- 每族原出口设备。
- 每个受保护 global 地址。
- 项目将创建的精确规则、表和预期验证条件。

重复地址字段由专用严格解析器处理。现有 `/etc/oc-master/owns-return-routing` 继续保持 `DEFAULT4/DEFAULT6` 兼容格式，作为旧版 cleanup 和人类恢复的最小 owner marker。

### 13.3 Apply 事务

1. 完成全部只读 preflight。
2. 校验 manager 预先写入的 route plan 与当前 snapshot/run state 一致，再原子写 owner marker；先记录所有权再修改网络。
3. 先填充专用 route table，再添加源地址 rule，避免 rule 指向空表。
4. 对每个地址执行 route-get 验证，确认回程仍走原设备。
5. 只有验证全部成功才允许 OpenConnect 接管普通默认出站。

单出口场景继续使用表 `51888/51889` 和优先级 `10000/10001`。

### 13.4 Cleanup 事务

新格式 route plan 存在时，删除其中记录的精确规则；旧格式则使用现有受限循环兼容清理。随后：

1. flush 两张受管表。
2. 删除受管 `ocm0`。
3. 仅在不存在其他可用非 VPN 默认路由时恢复保存路由。
4. 重新读取 rules、tables、links 和 defaults。
5. 验证每个保存的公网源地址仍能走原出口。
6. 只有全部成功才删除 route plan 和 owner marker。

### 13.5 Global health

健康条件同时包括：

- 当前 MainPID 和 cgroup 正确。
- 普通 IPv4 出站 route-get 经 `ocm0`。
- route plan 与当前 `run_id` 一致。
- 每个受保护公网源地址仍从原设备回程。
- 至少一个现有真实 IPv4 HTTPS 探测成功。

本轮不增加健康结果缓存。现有实测没有证明缓存值得承担公网 IP 或路由状态过期风险。

## 14. 配置和账户 I/O

- 账户添加与删除均改成完整文件的原子替换，继续保留注释、空行和顺序。
- snapshot 创建后，service/status 不再为当前代际按可变索引重新读取凭据。
- 删除、重排账户不影响当前连接及其自动重启；下一次显式启动只显示当时账户文件中的记录。
- profile 继续作为兼容的用户选择记录，snapshot 是运行时权威。
- 升级后若尚无 snapshot，首次启动可从旧 profile + account 生成一次兼容快照；生成后立即改用新权威状态。

多文件无法形成单次 filesystem rename，因此采用状态提交点：先写 `PREPARING`，再写 snapshot/profile，全部重新解析成功后才进入 `STARTING`。进程在中间崩溃时尚未获得网络写权限，下一命令可安全丢弃或重建未提交文件。

## 15. 安装和 systemd 事务

### 15.1 保留路径

- `/usr/local/sbin/oc-master`：持久程序本体，保留。
- `/usr/local/bin/ocm`：指向本体的快捷 symlink，保留。
- curl/wget 下载到 `/tmp` 后仍可删除临时脚本。

### 15.2 归属预检

- 在改受管程序前检查 shortcut 冲突。
- 新 unit 带稳定 managed header。
- 旧版 unit 通过严格的 Description/ExecStart/ExecStopPost 特征识别为可迁移对象。
- 同名但无法证明属于本项目的 unit 一律拒绝覆盖。
- `install` 对 `active` 及 `activating/deactivating/reloading` 等过渡状态均拒绝替换。

### 15.3 原子部署与恢复

1. 在目标文件系统内生成程序与三个 unit 临时文件。
2. 校验内容、权限和必要 unit 语义。
3. 备份当前受管文件。
4. 逐个原子 rename。
5. 执行 `daemon-reload` 并读取 unit 属性验证。
6. 任一步命令失败则恢复旧文件并再次 reload。

单次 rename 提供单文件原子可见性；多 unit 的命令失败由备份恢复覆盖。突然断电无法提供跨文件 ACID，但所有新旧 unit 都保持相同内部 `_service_*` 接口，且下一次安装会重新校验并收敛。

## 16. 错误处理与日志

- 保留 `set -Eeuo pipefail`、参数数组和密码 stdin。
- 关键 cleanup、rollback 取消、状态提交和安装恢复不得使用无条件 `|| true` 吞错。
- 可忽略的“对象本来不存在”必须由专用幂等函数识别，不能把所有错误视为不存在。
- 临时文件使用 trap 清理；网络资源仅由状态机显式 cleanup，通用 `ERR` trap 不做网络删除。
- 正常路径日志和菜单输出保持；新错误必须说明失败阶段、保留了什么以及下一步安全动作。
- 密码、完整账户记录、认证 cookie 不得出现在终端、journal 或测试失败输出。
- 内部 journal 可记录短 `run_id` 以关联并发事件，但公开正常输出不新增该字段。

## 17. 升级、降级与卸载

### 17.1 从当前 v8 升级

- 活跃 service 仍拒绝被 `install` 直接替换。
- 第一次显式 start/stop 识别旧 profile、旧 owner marker 和旧 unit。
- 必须先按旧兼容逻辑清理并验证，再创建新 snapshot/state。
- 已有账户文件不迁移、不重排、不改权限语义。

### 17.2 重启恢复

- 已确认 Global 和正常 Proxy 在新 boot 上可由 systemd 自动恢复。
- `AWAITING_CONFIRMATION`、`PREPARING`、`STARTING` 或 `ROLLBACK_CLAIMED` 跨 boot 后不得绕过确认自动建 VPN；利用 snapshot 的 `CREATED_BOOT_ID` 判定。
- `CLEANUP_FAILED` 永远要求下一次管理操作先显式恢复。

### 17.3 卸载

- 先执行既有 stop 顺序并证明网络清理成功。
- 删除本项目拥有的程序、shortcut、units、profile、snapshot、state、route plan 和 owner marker。
- 保留账户文件、共享软件包及 journal 历史。
- 无法停稳或 cleanup 失败时拒绝删除恢复证据。

## 18. 测试策略

### 18.1 Characterization 与行为差分

以 `e03f2aa` 为旧实现，使用相同 mock PATH、环境覆盖和输入 transcript 对旧/新脚本比较：

- 所有公开命令和 unknown 命令退出码。
- 主菜单、账户菜单、确认词及 stdout/stderr。
- 账户/profile 内容、权限、注释与保留集合。
- OpenConnect 参数数组、密码 stdin 和 authgroup。
- systemd unit 关键属性。
- SOCKS/Global 正常 start/status/stop。

允许差异只限于本设计列出的不安全失败分支和新增内部文件。差分测试对临时路径、PID、时间等非确定字段做明确归一化，不使用宽泛过滤掩盖真实差异。

### 18.2 状态机和并发回归

必须覆盖：

- 删除/重排账户后 restart 仍使用原快照。
- `KEEP` 先赢、rollback 先赢、旧 rollback 迟到三种路径。
- 旧 health/cleanup/rollback 面对新 `run_id` 无副作用。
- health restart 与人工 stop 的关键交错。
- Global cleanup 失败后拒绝 Proxy。
- 每个状态提交点发生进程中断后的恢复。
- 跨 boot 未确认状态拒绝自动启动。
- health failure/cooldown 不跨代际继承。

### 18.3 路由故障注入

必须覆盖：

- route plan 各 apply 步骤逐点失败。
- rule/table/link/default cleanup 逐点失败。
- 单出口单地址、单出口多地址、IPv4+IPv6。
- 多 default、ECMP、跨接口公网地址的预检拒绝。
- 缺失 IPv6 FIB 表、blackhole/unreachable default 和 owner marker 损坏。
- cleanup 失败时 marker/plan 保留，成功时才删除。

### 18.4 安装事务

必须覆盖：

- shortcut 和 foreign unit 冲突时零写入。
- 旧 unit 合法迁移。
- 每个原子替换/daemon-reload/验证点失败后的旧文件恢复。
- active 及过渡 service 状态拒绝安装。
- uninstall 只删除确认归属的对象。

### 18.5 现有测试

持续运行：

- `bash -n`
- ShellCheck warning 级
- `tests/functions.sh`
- `tests/static.sh`
- JSON 解析和可用时的 `sing-box check`
- `git diff --check`

## 19. 性能与资源验收

基线实测环境为 NMCloud-Hinet，OpenConnect 9.01、systemd 252、iproute2 6.1：

- 完整现有检查：0.82 秒。
- Bash 函数回归：0.66 秒，最大 RSS 约 17 MiB。
- 隔离无 profile 的 `status` 五次：0.32–0.51 秒，最大 RSS 约 53 MiB。
- 完整检查约 200 MiB 的峰值主要来自可选 sing-box 配置校验，不代表常驻脚本开销。

实现后的要求：

- 不增加常驻进程；`_service_run` 最终仍 `exec` OpenConnect。
- 新持久状态总量保持 KB 级。
- 纯本地状态读取/转换进行重复微基准，不得出现数量级退化。
- `status` 使用多次中位数比较，避免公网 RTT 波动误判；不得增加新的网络请求轮次。
- 生产启动新增的纯本地控制面目标低于约 1 秒，不含 VPN 认证、systemd 等待和公网探测。
- 测试套件可因新增覆盖增长，不把测试时长当作生产性能；仍记录 elapsed 与最大 RSS 供回归比较。

## 20. Code review 与最终验证

实施完成后按以下顺序验收：

1. 运行现有测试和新增定向测试。
2. 运行旧/新行为差分。
3. 在隔离 Linux 环境执行 systemd、路由和故障注入。
4. 对完整 diff 做独立 code review，按 Critical/Important/Minor 分级。
5. 修正 Critical/Important 及本轮引入的有效 Minor，再重跑相关测试。
6. 使用 `verification-before-completion` 从干净状态重新执行完整验证，不能复用旧结果作完成证据。
7. 检查工作树、暂存路径、commit diff 和远端目标，禁止带入无关文件。
8. 任何 NMCloud-Hinet 真实 VPN 或 Global 路由测试，在执行前单独说明修改范围、SSH 保护和回滚方式并取得确认。

最终交付必须明确回答：原实现问题、实际改动、设计理由、性能/复杂度/可靠性变化、仍值得后续研究但未施工的事项。

## 21. 外部依据

- [OpenConnect manual](https://www.infradead.org/openconnect/manual.html)：`--script-tun`、`--interface`、reconnect、tcp keepalive、信号及 VPN 数据通道语义。
- [OpenConnect vpnc-script](https://www.infradead.org/openconnect/vpnc-script.html)：OpenConnect 与系统路由/DNS 配置层的职责边界。
- [ocproxy](https://github.com/cernekee/ocproxy)：用户态 lwIP SOCKS/端口转发及不接管宿主路由的设计。
- [sing-box OpenConnect endpoint](https://sing-box.sagernet.org/configuration/endpoint/openconnect/)：1.14 起的内部网络栈替代方案，本轮仅作为后续试验候选。
- [sing-box network namespace](https://sing-box.sagernet.org/configuration/network-namespace/)：Linux netns 能力边界。
- [vopono](https://github.com/jamesmcm/vopono)：以临时 netns 隔离指定应用的成熟参考，不等价于整机全局模式。
- [Linux VRF documentation](https://docs.kernel.org/networking/vrf.html)：VRF 只提供 L3 路由域及应用绑定约束。
