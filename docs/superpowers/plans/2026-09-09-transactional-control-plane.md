# OpenConnect Master Transactional Control Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不改变现有菜单、公开命令、正常输出和 OpenConnect 数据路径的前提下，把当前依赖可变账户索引和松散文件的控制面改为按 `run_id` 隔离、可原子确认/回滚、可验证清理的事务化实现。

**Architecture:** 保留单文件 `oc_master.sh`、systemd 监督、Proxy 的 `--script-tun + ocproxy` 和 Global 的 `ocm0 + source policy routing`。新增严格解析的 snapshot/state/route-plan 文件、三层锁和代际 compare-and-set；systemd worker 只读取不可变 snapshot，Global 只执行 manager 预先生成且与当前代际匹配的 route plan。

**Tech Stack:** Bash 4.4+、systemd 252 兼容语法、OpenConnect、ocproxy、iproute2、flock、curl；测试使用 Bash 函数 mock、临时目录和现有 ShellCheck/JSON 检查，不新增运行时依赖。

**Spec:** `docs/superpowers/specs/2026-09-08-transactional-control-plane-design.md`

## Global Constraints

- 功能目标、菜单布局、公开命令、正常路径 stdout/stderr、确认词、账户格式、`profile.conf` 四字段和 curl/wget 安装方式保持兼容；只允许不安全失败分支增加明确错误。
- `/usr/local/sbin/oc-master` 继续作为持久程序本体，`/usr/local/bin/ocm` 继续是受管 symlink。
- Proxy 数据路径仍是 `OpenConnect --script-tun -> ocproxy -k 30 -D PORT`，不得修改宿主路由、防火墙、sysctl 或 DNS。
- Global 数据路径仍使用 `ocm0`、表 `51888/51889`、优先级 `10000/10001`；无法唯一证明单出口回程时必须在任何网络写入前拒绝启动。
- `active-run.conf` 是当前代际不可变运行快照，`run-state.conf` 是唯一生命周期权威；两者 `RUN_ID` 不同或格式不合法时拒绝网络变更。
- 锁序固定为 manager lock -> service-operation lock -> state lock；state lock 内不得调用 `systemctl`、HTTP、sleep 或读取交互输入；`ExecStopPost` 不得获取 service-operation lock。
- `KEEP` 与 rollback 只能从同一 `RUN_ID` 的 `AWAITING_CONFIRMATION` 原子 claim；失败方不得反转胜者结果。持久 `CONFIRMED` 成功后，即使 transient unit 删除失败也只警告。
- 账户增删、状态、profile、route plan、owner marker、程序副本和 unit 内容均用同目录临时文件加原子 rename；不得 `source` 状态文件，不得吞掉关键清理/状态提交错误。
- 不新增常驻进程、运行时语言、容器、netns、GOST、sing-box、nftables/iptables 依赖；README 只补充功能说明，不重写既有结构。
- 所有测试使用 `OCM_*` 路径覆盖和临时目录；不得在开发/验证中修改 <测试机 A> 的真实 VPN、默认路由或生产 systemd 单元。

---

## Task 1: 固化公开契约与测试夹具

**Files:**
- Create: `tests/testlib.sh`
- Create: `tests/compat.sh`
- Modify: `tests/static.sh`

- [ ] **Step 1: 提取共用隔离夹具**

在 `tests/testlib.sh` 提供 `new_test_root`、`cleanup_test_root`、`fail`、`assert_eq`、`assert_file_mode` 和 `export_test_paths`。`export_test_paths` 必须覆盖 `OCM_INSTALL_PATH`、`OCM_SHORTCUT_PATH`、`OCM_CONFIG_DIR`、`OCM_RUNTIME_DIR`、三把锁、`OCM_SYSTEMD_DIR`、`OCM_DDNS_SCAN_ROOT`、`OCM_BOOT_ID_FILE`、`OCM_UUID_FILE`，所有路径均位于测试临时目录。

- [ ] **Step 2: 写旧版行为 characterization**

`tests/compat.sh` 接受 `OCM_BASELINE_SCRIPT`；未设置时用 `git show e03f2aa:oc_master.sh` 写入临时文件。对 baseline 和当前脚本分别执行下列无网络场景，并比较退出码及归一化输出：未知命令、无 profile 的 `status`、主菜单输入 `0`、无账户时 `start-proxy`、无账户的账户菜单输入 `0`。归一化只替换版本行中的脚本绝对路径、临时根路径和公网 IP 查询结果，不过滤菜单文字、确认词或错误文字。

- [ ] **Step 3: 记录现有外部常量**

在 `tests/compat.sh` 直接断言当前脚本仍包含公开命令集合 `start-proxy|start-global|stop|accounts|deps|install|uninstall|status|check|logs`、菜单提示 `请选择 [0-9]:`、`GLOBAL`、`GLOBAL-DDNS-RISK`、`KEEP`、默认 SOCKS 端口 `1080`、表号和 rule priority。

- [ ] **Step 4: 接入总测试入口并运行**

将 `tests/testlib.sh`、`tests/compat.sh` 加入 `bash -n` 和 ShellCheck 文件列表，并在 `tests/static.sh` 中于 `tests/functions.sh` 后运行 `tests/compat.sh`。

Run: `bash tests/compat.sh && bash tests/static.sh`

Expected: characterization 全部通过；这一步只建立 baseline，不改生产代码，因此不要求人为制造 RED。

- [ ] **Step 5: 提交测试基线**

```bash
git add tests/testlib.sh tests/compat.sh tests/static.sh
git commit -m "test: 固化公开行为兼容基线"
```

## Task 2: 实现严格、原子的代际状态存储

**Files:**
- Create: `tests/state.sh`
- Modify: `tests/static.sh`
- Modify: `oc_master.sh`

- [ ] **Step 1: 为状态文件写失败测试**

`tests/state.sh` source `tests/testlib.sh` 和 `oc_master.sh`，覆盖：合法 UUID；拒绝大写/截断 UUID；`active-run.conf` 和 `run-state.conf` 写入后权限为 `0600`；缺字段、重复字段、未知字段、未知 `FORMAT_VERSION`、非法枚举、嵌入换行的账户记录均被拒绝；写入失败不替换旧文件；`RUN_ID` 不匹配被拒绝；compare-and-set 的旧阶段不匹配时文件字节不变。

Run: `bash tests/state.sh`

Expected: 因 `write_active_run`、`write_run_state`、`load_runtime_state`、`transition_run_state` 尚不存在而失败。

- [ ] **Step 2: 增加状态路径与生成源覆盖**

在常量区新增：

```bash
readonly ACTIVE_RUN_FILE="${OCM_ACTIVE_RUN_FILE:-${CONFIG_DIR}/active-run.conf}"
readonly RUN_STATE_FILE="${OCM_RUN_STATE_FILE:-${CONFIG_DIR}/run-state.conf}"
readonly ROUTE_PLAN_FILE="${OCM_ROUTE_PLAN_FILE:-${CONFIG_DIR}/route-plan.conf}"
readonly STATE_LOCK_FILE="${OCM_STATE_LOCK_FILE:-/run/lock/oc-master-state.lock}"
readonly SERVICE_LOCK_FILE="${OCM_SERVICE_LOCK_FILE:-/run/lock/oc-master-service.lock}"
readonly SERVICE_RUN_ID_FILE="${OCM_SERVICE_RUN_ID_FILE:-${RUNTIME_DIR}/service.run-id}"
readonly BOOT_ID_FILE="${OCM_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
readonly UUID_FILE="${OCM_UUID_FILE:-/proc/sys/kernel/random/uuid}"
readonly NON_RESTARTABLE_EXIT=78
```

实现 `new_run_id()`、`current_boot_id()` 和 `valid_uuid()`；只接受小写 RFC 4122 形式，读取文件必须恰好一行。

- [ ] **Step 3: 实现原子替换原语**

实现 `atomic_replace_from_stdin TARGET MODE`：在 `dirname TARGET` 下 `mktemp`，写完整 stdin，`chown 0:0`、`chmod MODE`、验证为普通文件且非 symlink 后 `mv -f --`；用局部 trap 清理临时文件。函数失败时目标必须保持原内容。

- [ ] **Step 4: 实现严格解析和写入接口**

实现以下签名：

```bash
write_active_run RUN_ID BOOT_ID MODE ACCOUNT_INDEX PROTOCOL SOCKS_PORT ACCOUNT_LINE
load_active_run
write_run_state RUN_ID PHASE DESIRED_ACTIVE ROLLBACK_DEADLINE
load_run_state
load_runtime_state
transition_run_state RUN_ID ALLOWED_OLD_PHASES NEW_PHASE DESIRED_ACTIVE ROLLBACK_DEADLINE
```

`load_*` 用逐行 `IFS='=' read -r key value` 和显式 case 解析，不使用 `source`/`eval`。快照字段固定为 `FORMAT_VERSION,RUN_ID,CREATED_BOOT_ID,MODE,ACCOUNT_INDEX,VPN_PROTOCOL,SOCKS_PORT,ACCOUNT_RECORD`；状态字段固定为 `FORMAT_VERSION,RUN_ID,PHASE,DESIRED_ACTIVE,ROLLBACK_DEADLINE`。状态阶段只允许 `PREPARING,STARTING,RUNNING,AWAITING_CONFIRMATION,CONFIRMED,ROLLBACK_CLAIMED,STOPPING,CLEANUP_FAILED,CLEANED`。字段缺失、重复和未知键均失败。

- [ ] **Step 5: 在 state lock 中完成 CAS**

`transition_run_state` 获取 `STATE_LOCK_FILE` 的阻塞 flock，重新加载并校验 snapshot/state 的相同 `RUN_ID`，检查旧阶段属于逗号分隔的 `ALLOWED_OLD_PHASES`，再原子写入新状态；释放锁后返回。不得在持锁区调用日志之外的外部网络或 systemd 操作。

- [ ] **Step 6: 跑定向与总测试**

将 `tests/state.sh` 接入 `tests/static.sh`。

Run: `bash tests/state.sh && bash tests/static.sh && git diff --check`

Expected: 全部通过，无 warning/noise。

- [ ] **Step 7: 提交状态存储**

```bash
git add oc_master.sh tests/state.sh tests/static.sh
git commit -m "refactor: 引入严格代际状态存储"
```

## Task 3: 用不可变快照解耦账户索引

**Files:**
- Create: `tests/snapshot.sh`
- Modify: `tests/static.sh`
- Modify: `oc_master.sh`

- [ ] **Step 1: 写账户重排和 restart 的失败测试**

`tests/snapshot.sh` 创建 A/B 两个账户，选择 B 并调用 `create_run_snapshot proxy 1 nc 1080`；随后删除 B 或把 A/B 对调。断言 `load_runtime_configuration` 和 mock `_service_run` 仍得到 B 的 `VPN_DESC/VPN_USER/VPN_PASS/VPN_HOST/VPN_GROUP`，且 openconnect 参数和密码 stdin 与快照一致。另测无 snapshot 但有合法旧 `profile.conf + accounts` 时，显式迁移函数能创建一次新快照；worker 自身不得在缺 snapshot 时静默迁移。

Run: `bash tests/snapshot.sh`

Expected: 当前 `load_profile` 仍按 `ACCOUNT_INDEX` 读取，重排后测试失败。

- [ ] **Step 2: 分离兼容 profile 与运行时配置**

保留 `write_profile MODE ACCOUNT_INDEX PROTOCOL SOCKS_PORT` 的四字段输出。把现有 `load_profile` 拆成：

```bash
load_profile_values          # 只解析并验证四字段，不读取账户
load_legacy_profile_account  # 仅显式迁移/旧版 cleanup 使用
load_runtime_configuration   # 严格 snapshot + state，填充 PROFILE_* 和 VPN_*
```

`load_runtime_configuration` 必须验证 snapshot/state 同代际；运行中 status/health/service 不再访问可变账户索引。

- [ ] **Step 3: 创建并提交一次运行快照**

实现 `create_run_snapshot MODE ACCOUNT_INDEX PROTOCOL SOCKS_PORT ACCOUNT_LINE`：读取 kernel UUID/boot ID，先写 `PREPARING` 状态，再写不可变快照与兼容 profile，重新解析成功后返回 `RUN_ID`；任一写入失败时不得进入 `STARTING`。账户记录不写日志。

- [ ] **Step 4: 账户文件改为完整原子替换**

实现 `replace_accounts_from_stdin` 并让添加、删除都经同目录临时文件和原子 rename；保留注释、空行和原顺序，最终 owner root、mode `0600`。添加不再用 `>>`，删除不再用跨目录 `install`。

- [ ] **Step 5: 接入 service/status/health 配置读取**

`service_run`、`health_once`、`show_status`、`check_data_plane` 改用 `load_runtime_configuration`。只有显式 manager start 在检测到旧 profile 且没有新状态时调用兼容迁移；非法或半写状态必须报错，不得回退到可变账户文件。

- [ ] **Step 6: 跑定向与总测试**

将 `tests/snapshot.sh` 接入 `tests/static.sh`。

Run: `bash tests/snapshot.sh && bash tests/functions.sh && bash tests/static.sh && git diff --check`

Expected: 全部通过，baseline 正常输出保持一致。

- [ ] **Step 7: 提交快照集成**

```bash
git add oc_master.sh tests/snapshot.sh tests/static.sh
git commit -m "fix: 固化当前连接账户快照"
```

## Task 4: 串行化生命周期并消除 KEEP/rollback 竞态

**Files:**
- Create: `tests/lifecycle.sh`
- Modify: `tests/static.sh`
- Modify: `oc_master.sh`

- [ ] **Step 1: 写状态机和竞态失败测试**

`tests/lifecycle.sh` 用临时锁和 mock systemctl 覆盖：Proxy 正常 `PREPARING -> STARTING -> RUNNING`；Global 正常到 `AWAITING_CONFIRMATION`；KEEP 先赢后 rollback 无副作用；rollback 先赢后 KEEP 返回失败且不输出“取消独立回滚”；旧 `run_id` rollback 无副作用；timer 在 deadline 前释放锁并只等待剩余时间；跨 boot 的未确认 Global `_service_run` 返回 78；stop 将 `DESIRED_ACTIVE=0` 后 health 无权 restart；failure/cooldown 文件中的旧 `run_id` 不继承。

Run: `bash tests/lifecycle.sh`

Expected: 现有无代际 rollback/health 实现导致测试失败。

- [ ] **Step 2: 增加 service-operation lock 接口**

实现：

```bash
acquire_service_operation_lock wait|try
release_service_operation_lock
state_allows_service_run RUN_ID
```

公开 start/stop/rollback 使用 `wait`；health 使用 `try`，失败即正常跳过本轮。实现中维持 manager -> service-operation -> state 顺序；任何 `systemctl`/sleep/HTTP 前确认未持有 state lock。

- [ ] **Step 3: 让 systemd worker 服从代际状态**

`service_run` 严格读取 snapshot/state，拒绝非 active 阶段、`CLEANUP_FAILED`、不匹配代际，以及跨 boot 的 `PREPARING/STARTING/AWAITING_CONFIRMATION/ROLLBACK_CLAIMED` Global，并返回 `NON_RESTARTABLE_EXIT`。成功时原子写 `SERVICE_RUN_ID_FILE`，再执行 backend prepare 并 `exec openconnect`。

- [ ] **Step 4: 重写 rollback 与 KEEP claim**

接口改为：

```bash
arm_rollback RUN_ID
rollback_now RUN_ID
confirm_global_run RUN_ID
cancel_rollback RUN_ID
```

`systemd-run` 命令必须携带 `_rollback RUN_ID`。健康后 manager 以 CAS 写 `AWAITING_CONFIRMATION` 与 `now+120`；worker 过早触发时读取剩余秒数、释放锁、sleep、重读。只有 CAS 到 `ROLLBACK_CLAIMED` 的 worker 执行 stop/cleanup。`confirm_global_run` 先持久 CAS 到 `CONFIRMED`，再清 transient unit；unit 清理失败返回逻辑成功但输出明确警告。

- [ ] **Step 5: 使 stop、cleanup 和 health 代际安全**

显式 stop 在 service-operation lock 内先把同代际置为 `STOPPING,DESIRED_ACTIVE=0`，再按 timer -> health -> main 顺序停止。`service_cleanup` 读取 `SERVICE_RUN_ID_FILE`；旧代际不得改当前状态。若 desired active 仍为 1，清理后保留 restart 允许阶段；若为 0，成功转 `CLEANED`，失败转 `CLEANUP_FAILED`。health 文件格式改为 `RUN_ID=count` 和 `RUN_ID=epoch`，每次探测后、restart 前重新验证代际和 active 状态。

- [ ] **Step 6: 更新 systemd restart 策略**

主 unit 保留 `Restart=always`、`StartLimitIntervalSec=300`、`StartLimitBurst=3`，增加：

```ini
RestartPreventExitStatus=78
```

公开正常日志和菜单不显示 `run_id`。

- [ ] **Step 7: 跑定向与总测试**

将 `tests/lifecycle.sh` 接入 `tests/static.sh`。

Run: `bash tests/lifecycle.sh && bash tests/functions.sh && bash tests/static.sh && git diff --check`

Expected: 全部通过；竞态用固定 barrier 文件而非随机 sleep 断言。

- [ ] **Step 8: 提交生命周期事务**

```bash
git add oc_master.sh tests/lifecycle.sh tests/static.sh
git commit -m "fix: 事务化确认回滚与服务生命周期"
```

## Task 5: 将 Global 路由改为先规划、精确应用与验证清理

**Files:**
- Create: `tests/routes.sh`
- Modify: `tests/static.sh`
- Modify: `oc_master.sh`

- [ ] **Step 1: 写 route plan 和故障注入失败测试**

`tests/routes.sh` 用 mock `ip` 覆盖：单 IPv4；同接口多 IPv4；IPv4+IPv6；缺失 IPv6 FIB 表；两个不同 default；ECMP/nexthop；blackhole/unreachable default；地址跨接口；已有 priority/table/link 冲突；route plan 未匹配当前 `RUN_ID`。对 apply 的 owner write/table/rule/route-get 每一步注入失败，对 cleanup 的 rule/table/link/default/route-get 每一步注入失败；断言失败时 owner/plan 保留，成功验证后才删除。

Run: `bash tests/routes.sh`

Expected: 当前 `setup_return_routes` 选择第一条默认路由并直接修改网络，多个拒绝用例失败。

- [ ] **Step 2: 实现只读 route plan 生成与严格解析**

实现：

```bash
build_route_plan RUN_ID
write_route_plan RUN_ID
load_route_plan EXPECTED_RUN_ID
validate_route_plan_against_snapshot EXPECTED_RUN_ID
```

只允许每族至多一条可用的非 VPN default；拒绝 `nexthop`、不同出口、多 WAN、blackhole/unreachable/prohibit、缺少 `dev` 和不能证明归属的现有 policy rules。允许一个出口接口有多个 global 地址。文件字段固定为 `FORMAT_VERSION,RUN_ID,DEFAULT4,DEV4,RETURN4_ADDRESS`（可重复）、`DEFAULT6,DEV6,RETURN6_ADDRESS`（可重复）；重复地址去重，其他字段不得重复。

- [ ] **Step 3: 在 manager preflight 阶段落盘计划**

Global start 在持有 service-operation lock、清理旧代际并验证 clean 后调用 `build_route_plan`。先把完整内容写入 `route-plan.conf` 并重新解析，再把 run state 从 `PREPARING` 转 `STARTING`；在这之前不得调用任何 `ip ... add|replace|del|flush`。

- [ ] **Step 4: 精确 apply 当前计划**

把 `setup_return_routes` 替换为 `apply_route_plan RUN_ID`：验证同代际后先原子写兼容 owner marker；先写表，再按 plan 中每个地址写精确 rule；逐地址用 `ip -4/-6 route get DEST from SOURCE` 验证走记录的原出口设备。任一失败返回非零并保留恢复证据，由生命周期 cleanup 收敛。

- [ ] **Step 5: 精确 cleanup 并保留旧格式兼容**

实现 `cleanup_route_plan RUN_ID`：新 plan 存在时只删除记录的源规则，再 flush 两个受管表并删 `ocm0`；旧 owner marker 无 plan 时保留现有受限循环兼容。仅当没有可用非 VPN default 时恢复保存 default。重新验证 rules/tables/link/default 与每个保存源地址的 route-get；全部成功才删除 plan 和 owner marker。

- [ ] **Step 6: 阻止带残留的模式替换**

`start_mode` 必须先完整停止旧单元和清理旧 route state；若状态成为 `CLEANUP_FAILED` 或 owner/plan 无法证明已清理，Global -> Proxy 和 Proxy -> Global 均不得写新 snapshot/profile，也不得输出启动成功。

- [ ] **Step 7: 跑定向与总测试**

将 `tests/routes.sh` 接入 `tests/static.sh`。

Run: `bash tests/routes.sh && bash tests/functions.sh && bash tests/static.sh && git diff --check`

Expected: 全部通过，现有缺失 FIB 表与 owner marker 回归仍通过。

- [ ] **Step 8: 提交路由事务**

```bash
git add oc_master.sh tests/routes.sh tests/static.sh
git commit -m "fix: 用代际路由计划保护全局回程"
```

## Task 6: 原子部署程序和 systemd units

**Files:**
- Create: `tests/install.sh`
- Modify: `tests/static.sh`
- Modify: `oc_master.sh`

- [ ] **Step 1: 写安装事务失败测试**

`tests/install.sh` 使用 `OCM_SYSTEMD_DIR` 临时目录和 mock systemctl 覆盖：foreign shortcut 冲突零写入；foreign unit 冲突零写入；现有 v8 unit 可迁移；主 service 为 `active/activating/deactivating/reloading` 均拒绝替换；程序或任一 unit rename 失败、`daemon-reload` 失败、unit 属性验证失败时恢复全部旧文件；成功文件权限程序 `0755`、unit `0644`；uninstall 不删除 foreign unit。

Run: `bash tests/install.sh`

Expected: 当前 unit 使用直接 heredoc 覆盖且只检查 active，测试失败。

- [ ] **Step 2: 增加 unit 目录覆盖与归属判断**

新增 `SYSTEMD_DIR="${OCM_SYSTEMD_DIR:-/etc/systemd/system}"`。生成的三个 unit 第一行加入稳定注释 `# Managed by oc-master`。实现 `unit_is_ours FILE KIND`：接受该 header，或严格匹配旧版 Description、`ExecStart=${INSTALL_PATH} _service_*` 及主 unit 的 ExecStopPost；无法证明归属时拒绝覆盖或删除。

- [ ] **Step 3: 阻止过渡状态升级**

实现 `service_state_allows_install`，仅 `inactive`、`failed` 或 unit 不存在时允许；`active` 及任何过渡/未知状态均拒绝，错误继续提示先 `sudo ocm stop`。

- [ ] **Step 4: 实现 staged install 和恢复**

实现 `install_self_and_units` 的两阶段流程：先预检 shortcut/全部 units；在各目标目录生成并校验临时文件；备份现有受管文件；逐个原子 rename；`daemon-reload`；用 `systemctl show` 验证 `ExecStart/ExecStopPost/Restart/RestartPreventExitStatus`。任一步失败恢复旧文件，删除本轮新建且原先不存在的文件，再次 reload，并返回原失败。

- [ ] **Step 5: 原子安装持久程序与 shortcut**

`install_managed_copy` 先把脚本写到 `dirname INSTALL_PATH` 的临时文件、校验 `bash -n` 和 mode，再 rename；shortcut 只在目标不存在或已指向 `INSTALL_PATH` 时创建。预检失败时程序、shortcut 和 units 均不变化。

- [ ] **Step 6: 跑定向与总测试**

将 `tests/install.sh` 接入 `tests/static.sh`。

Run: `bash tests/install.sh && bash tests/functions.sh && bash tests/static.sh && git diff --check`

Expected: 全部通过，无临时/备份文件泄漏。

- [ ] **Step 7: 提交安装事务**

```bash
git add oc_master.sh tests/install.sh tests/static.sh
git commit -m "fix: 原子部署受管程序与服务单元"
```

## Task 7: 强化健康归属、升级恢复和卸载边界

**Files:**
- Create: `tests/health-uninstall.sh`
- Modify: `tests/static.sh`
- Modify: `oc_master.sh`

- [ ] **Step 1: 写 listener 归属和卸载失败测试**

`tests/health-uninstall.sh` mock `ss -H -ltnp`、`systemctl show -p ControlGroup` 和 `/proc` 覆盖：端口由主 service cgroup 的 ocproxy/openconnect 子进程监听才健康；相同端口由 foreign PID 占用时失败；无法取得 PID/cgroup 时 fail-closed；systemd 状态 unknown 时不报告健康。卸载成功删除程序、owned shortcut、owned units、profile、snapshot、state、route plan、owner marker和运行态文件，但保留账户文件、foreign shortcut/unit；cleanup 失败时所有恢复证据都保留。

Run: `bash tests/health-uninstall.sh`

Expected: 当前 Proxy 只看端口是否监听，foreign listener 会被误判健康。

- [ ] **Step 2: 证明 SOCKS listener 属于受管 cgroup**

实现：

```bash
service_control_group
listener_pids_for_tcp_port PORT
pid_belongs_to_service_cgroup PID CONTROL_GROUP
managed_tcp_listener_is_ready PORT
```

解析 `ss -H -ltnp` 的 pid，要求至少一个 PID 的 `/proc/PID/cgroup` 精确落在 `oc-master.service` ControlGroup 或其子层级；无法证明即不健康。Global health 还必须验证 route plan 与 `run_id`、普通 IPv4 route-get 走 `ocm0`、每个保存源地址回程仍走 plan 设备。

- [ ] **Step 3: 收敛旧版升级状态**

显式 start/stop 在没有新 state 但存在旧 profile/owner/unit 时走 `recover_legacy_installation`：先停止旧受管单元，按旧 marker 安全清理并验证；只有 clean 后才能创建新 snapshot。半成品新状态不得按 legacy 处理。

- [ ] **Step 4: 收紧卸载归属和证据保留**

`uninstall_manager` 在 stop/cleanup/CLEANED 验证完成后才删除受管对象；units 必须逐个 `unit_is_ours` 后删除，foreign 文件警告保留。删除新内部文件和 `SERVICE_RUN_ID_FILE`，保留 `ACCOUNTS_FILE`、共享软件包及 journal；daemon-reload 失败返回非零并说明磁盘文件状态。

- [ ] **Step 5: 跑定向与总测试**

将 `tests/health-uninstall.sh` 接入 `tests/static.sh`。

Run: `bash tests/health-uninstall.sh && bash tests/functions.sh && bash tests/static.sh && git diff --check`

Expected: 全部通过，公开菜单和正常 status 文案不变。

- [ ] **Step 6: 提交健康和卸载边界**

```bash
git add oc_master.sh tests/health-uninstall.sh tests/static.sh
git commit -m "fix: 验证数据面归属并收紧卸载边界"
```

## Task 8: 行为等价、性能、文档和最终验收

**Files:**
- Create: `tests/performance.sh`
- Modify: `tests/compat.sh`
- Modify: `tests/static.sh`
- Modify: `README.md`
- Modify: `README_EN.md`
- Modify: `docs/REVIEW.md`

- [ ] **Step 1: 扩展旧/新行为差分**

在 `tests/compat.sh` 加入 mock systemctl/ip/openconnect 的 Proxy 正常 start/status/stop 和 Global 正常 start/KEEP/stop transcript；分别运行 `e03f2aa` 与新脚本，对临时路径、PID、epoch、UUID 做逐字段明确归一化。允许差异清单只包括新增内部文件、managed header、`RestartPreventExitStatus=78` 和设计明确收紧的错误分支；任何菜单、确认词、成功文案、openconnect 参数或密码 stdin 差异均失败。

- [ ] **Step 2: 增加本地控制面微基准**

`tests/performance.sh` 在临时目录创建合法 proxy/global 状态，各执行 200 次 `load_runtime_state` 和 CAS 往返，记录 elapsed 与最大状态目录字节数；断言状态文件总量小于 32 KiB、脚本没有新增后台常驻进程、`show_status` 的公网请求次数不高于 baseline。时间只打印，不以 Windows 开发机绝对耗时作为失败阈值。

- [ ] **Step 3: 最小更新使用文档**

保留 README/README_EN 的既有章节顺序、菜单展示、curl/wget 安装和 `sudo ocm` 管理方式。仅补充：运行账户快照不受账户列表重排影响；Global 对多出口/ECMP fail-closed；`CLEANUP_FAILED` 需要先恢复；`/usr/local/sbin/oc-master` 是持久程序本体。sing-box 仍只是既有用法示例，不升格为项目主线。

- [ ] **Step 4: 更新审查证据**

在 `docs/REVIEW.md` 追加本次架构问题、实现映射、测试命令、Linux 隔离测试结果、性能/RSS/状态大小和未施工候选；保留既有 live proof，不声称执行过 <测试机 A> 真实 VPN/路由测试。

- [ ] **Step 5: 运行完整本地验证**

```bash
bash -n oc_master.sh oc_master_en.sh tests/*.sh
shellcheck -x -S warning oc_master.sh oc_master_en.sh tests/*.sh
bash tests/static.sh
bash tests/compat.sh
bash tests/performance.sh
git diff --check
```

Expected: 全部退出 0，ShellCheck 无 warning，测试输出无意外 skip/noise；若缺 ShellCheck/sing-box，记录工具缺失并在 Linux 隔离环境补跑可用项。

- [ ] **Step 6: 在 <测试机 A> 仅做隔离 Linux 验证**

把干净 worktree 内容复制到远端 `/tmp/oc-master-verify-<run-id>`，只在该目录与其内部 `OCM_*` 路径运行语法、ShellCheck、全部测试、compat 和 performance；不得调用真实 start-global/start-proxy，不得写 `/etc/systemd/system`、`/etc/oc-master`、`/run/oc-master` 或真实 route table。记录 `/usr/bin/time -v` 的 elapsed/max RSS，结束后删除该精确临时目录。

- [ ] **Step 7: 独立完整分支 code review**

以 `e03f2aa` 为 base、当前 HEAD 为 head，使用 `superpowers:requesting-code-review` 检查 spec/plan 对齐、状态机、锁序、route cleanup、secret handling、legacy 兼容、测试有效性和文档。修复所有 Critical/Important 以及本轮引入且明确有效的 Minor，并重跑覆盖测试。

- [ ] **Step 8: 运行候选版本完整验证并写入证据**

重新运行 Step 5 全套与 Linux 隔离验证，把这一次的命令、退出码、elapsed/max RSS 和状态目录大小写入 `docs/REVIEW.md`。不复用前面任务的输出；若审查修复触及生产代码，先单独提交该修复及覆盖测试。

- [ ] **Step 9: 提交最终文档和验证工具**

```bash
git add tests/performance.sh tests/compat.sh tests/static.sh README.md README_EN.md docs/REVIEW.md
git commit -m "docs: 补充事务化控制面验证证据"
```

- [ ] **Step 10: verification-before-completion 新鲜验证**

从 clean worktree 再次运行 Step 5 全套与 Linux 隔离验证，不复用 Step 8 输出。检查：

```bash
git status --short
git diff --check
git log --oneline e03f2aa..HEAD
git diff --name-only e03f2aa..HEAD
```

Expected: 工作树 clean，只包含 spec、plan、`.gitignore`、脚本、测试和最小文档改动。

- [ ] **Step 11: 合并、推送并远端核验**

把实现分支 fast-forward 合并到本地 `main`，在 `main` 再跑 `bash tests/static.sh` 和 `git diff --check`，然后：

```bash
git -c http.sslBackend=openssl push origin main
git ls-remote origin refs/heads/main
```

Expected: 远端 `refs/heads/main` 与本地 `main` HEAD 完全一致；推送前只显式暂存计划列出的文件。
