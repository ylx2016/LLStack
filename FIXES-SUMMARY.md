# LLStack 修复与审查总结（中文）

> 给明天的我/你留的方向记录。所有修复已在 fork `ylx2016/LLStack` 的 `fix/supply-chain` 分支上，**9 个 commit，smoke 87/87 通过**。

---

## TL;DR

我审了 `Z:\t\LLStack-main` 整个 shell 脚本（80+ 个 `.sh` + `llstack-ctl`），找出并修了一批**真 bug**：
- JSON 注入（用户控制的变量裸插进 heredoc）
- 静默失败（`2>/dev/null || true` 吞关键错）
- 供应链隐患（curl | bash + 硬编码上游仓库）
- 装包/装库时的可恢复性（`mktemp` 模板、trap 泄漏、幂等性、版本检查）

**并修了一堆你 VPS 实测撞到的 install 流程 bug**（见下方"install bug 修复"）。

**但有相当一部分 bug 我改不了**——它们在 `backend/app.cpython-312-x86_64-linux-gnu.so`（闭源编译产物）和 React 编译 bundle 里，**源码不发**。这些必须报给 upstream `web-casa/LLStack` 修。

---

## 1. 分支状态（你的 fork `ylx2016/LLStack`）

| 分支 | 内容 | 状态 |
|---|---|---|
| `main` | upstream `web-casa/LLStack` 的 `v0.8.8`，**未动** | 等两条 PR 合并 |
| `fix/security-hardening` | 17 commits 的 bug 修复（参数校验、JSON 转义、dnf5、mktemp、trap、错误检查等） | ready for upstream PR |
| `fix/supply-chain` | 基于 security-hardening + 4 轮 install bug 修复（**9 commits, 87 smoke**） | **当前最完整** |

**重要分支关系**：
```
fix/supply-chain ← fix/security-hardening ← main
        ↑ 多了 9 个 install 流程相关的 commits
```

要合并回 security-hardening：fast-forward 即可。

---

## 2. 完整 commit 清单

### `fix/supply-chain` 最新 9 个 commits

```
44b7d9e fix(install): install adminer (panel was returning adminer_not_installed)
5d6f762 fix(ssl-issue,redis-install): Let's Encrypt + Valkey compat
510c687 test(smoke): fix the install.sh cd /tmp test (was looking at wrong line range)
1813459 fix(install.sh): anchor CWD to /tmp at start (avoids "cannot access parent directories")
d73a289 fix(php-install,db-install-*): make idempotent so the setup wizard can resume
73ff7cb fix(php-install): make idempotent (single-file version)
3e16d01 test(smoke): add regression tests for mysql --version banner parsing
f90318d fix(db-install-mariadb,mysql): version_mismatch regex catches protocol not server
de1203e fix(install,upgrade): handle commit-SHA refs (not just branches/tags)
86e5a07 fix(install,upgrade): make panel source overridable + supply-chain aware
```

### `fix/security-hardening` 17 commits（按主题）

```
P1-P3 backlog（46 文件改动，+2308/-689 行）：
  720d6bd fix(scripts): P1–P3 backlog

high-severity audit（9 文件）：
  1d1a5b6 fix(scripts): audit findings — high severity
  └─ redis-instance-create.sh: ExecStop 用 bash -c 双重 shell 展开密码
  └─ install.sh: 缺 visudo -c 校验、firewall 没加 ssh
  └─ db-install-mysql/percona: ALTER USER 失败被 || true 吞
  └─ backup-restic-restore.sh: 缺 --force 守卫
  └─ db-install: 缺版本检查
  └─ upgrade.sh: trap 冻结了 $SRC（泄漏 /tmp）
  └─ app-install.sh: 最终 JSON 用 printf '%s'（注入风险）

round 2 medium（6 文件）：
  49a4ead fix(scripts): audit findings — round 2
  └─ panel-export.sh: SSL 模式只匹配 *.pem（漏 acme.sh 的 .cer/.key）
  └─ wp-smart-update.sh: DB_NAME 为空时静默失败
  └─ app-laravel.sh: 全重写（composer 输出到 stdout、静默吞未知参数、rm -rf DOC_ROOT）
  └─ app-typecho.sh: 布局识别坏（缺 wrapper/build 嵌套逻辑）
  └─ app-wordpress.sh: LSBruteForce 在 OLS 上 500、缺 SHA256、JSON 注入

round 3（3 文件）：
  bb35380 fix(install,upgrade,db-clone): refuse symlinks + clone failure detection
  └─ install.sh / upgrade.sh: 拒绝 /opt/llstack-panel symlink
  └─ db-clone.sh: 源库不存在时不再静默创建空库

round 4 db（5 文件）：
  e10e678 fix(db): consistent error handling + JSON contract
  └─ db-create/delete/clone/export/import/user-create: 统一用 Python json.dumps、显式错误检查
  └─ db-install-mariadb/postgresql: 加 dnf5 兼容 + 版本检查
  └─ db-install-mysql: 修 dnf5 检测 regex

smoke harness 扩展（4 commits，17→87 cases）：
  e847436 test(smoke): initial harness (17 cases)
  2fe0d28 test(smoke): +db scripts (42 cases)
  9580709 test(smoke): +cron scripts (55 cases)
  f0d8e70 test(smoke): drop fake sqlite3, extend to status scripts (60 cases)
```

---

## 3. Install 流程 bug 修复（**你 VPS 实测撞到**的）

| Commit | 文件 | 修复 |
|---|---|---|
| `de1203e` | install.sh/upgrade.sh | `git clone --branch <sha>` 在 `--depth 1` 下找不到任意 SHA（仅 default branch tip）。改用完整 clone + `git checkout` 用于 SHA；branch/tag 走 `--depth 1 --branch` 快路径 |
| `86e5a07` | install.sh/upgrade.sh | `LLSTACK_REPO` 改为 `${LLSTACK_REPO:-web-casa}` env 覆盖；加 `LLSTACK_COMMIT` SHA 锁定；`curl rpms.litehttpd.com/setup.sh \| bash` 改为显性警告 + `LLSTACK_SKIP_LITEHTTPD_REPO=1` 跳过开关 |
| `f90318d` | db-install-mariadb.sh/mysql.sh | `mysql --version` 输出是 `Ver 15.1 Distrib 10.11.19-MariaDB`，之前的 regex 抓第一个 X.Y (15.1) 是协议版本。改用 `Distrib X.Y` 优先；MySQL/Percona 无 Distrib 走 fallback |
| `d73a289` / `73ff7cb` | php-install.sh、db-install-*.sh | 加 `--force` 标志；已装时返回 `ok:true, already_installed:true` 而非 `error: already_installed`。setup wizard 重试能继续 |
| `1813459` / `510c687` | install.sh | 开头加 `cd /tmp 2>/dev/null \|\| cd /`，防 `shell-init: error retrieving current directory` |
| `5d6f762` | ssl-issue.sh | acme.sh v3 默认用 ZeroSSL（要邮箱注册）。加 `--server letsencrypt` 用 Let's Encrypt（无邮箱） |
| `5d6f762` | redis-install.sh | EL10 把 redis 包换成了 valkey。`systemctl enable --now redis` 失败。脚本装完后建 `/etc/systemd/system/redis.service → valkey.service` 符号链接，让所有查 `redis.service` 的工具看到跑着 |
| `44b7d9e` | adminer-install.sh（新文件）| 面板的 `.so` 引用 `/opt/llstack/web/adminer/index.php` 但 install 从来不装它（所以 `adminer_not_installed` 永远出）。新脚本从 adminer.org 拉 single-file adminer.php，sanity-check 是 PHP 开头，幂等 + `--force` |

---

## 4. Smoke harness 现状

`Z:\t\smoke.sh` 在 Windows 跑（不依赖 EL 机器），用 fake bin 库（wp-cli、mysql、crontab、systemctl、id、curl、stat 等）模拟各种调用。

**87 cases 全部通过**：
- 参数校验（未知参数、缺参数、注入检测）
- 错误码一致性（`unknown_arg` / `invalid_*` / `engine_conflict`）
- 端到端 happy path（app-install 装到 fake doc-root、cron add+remove+sync、db clone+export+import）
- JSON 契约（Python json.dumps 替换 printf '%s' 后的回归）
- 资源保护（manifest 权限、sudoers 校验标记）
- 新增 install 流程的回归（cd /tmp、--force、idempotent、adminer 路径、symlink 标记）

跑命令：`bash Z:\t\smoke.sh`（任何机器，Linux/Mac/Windows Git Bash 都行）

---

## 5. 仍未修的 bug（**在 `.so` 闭源里，必须报给 upstream**）

| 你撞到的现象 | 在哪 | 必须报给谁 |
|---|---|---|
| 站点管理：点停止/删除没反应 | `.so` Python backend 的 sites blueprint | upstream `web-casa/LLStack` |
| 增量备份：React 报 `Items must have a value prop that is not an empty string` | React bundle（看到 `useState({name:""})` 用了空串） | upstream |
| 完整备份体积显示 0 | `.so` 不读 JSON 的 `size` 字段（shell 脚本里 `stat -c%s` 输出是对的） | upstream |
| 备份恢复失败 | `.so` 调 `backup-restic-restore.sh` 的传参链 | upstream |
| 创建账号：弱密码失败后，rate_limit 触发 | `.so` 闭源：前端未把改后的强密码重提交给后端验证 | upstream |
| 顶部"PostgreSQL not running" | `.so` 硬编码服务列表 | upstream（你已确认忽略） |

**报 issue 的建议标题**（全部丢给 `https://github.com/web-casa/LLStack/issues/new`）：
```
[bug] adminer_not_installed: install flow never creates /opt/llstack/web/adminer/
[bug] redis service status: EL10 ships Valkey, not Redis
[bug] acme.sh v3+ defaults to ZeroSSL which requires email
[bug] site Stop/Delete buttons don't respond (UI no-op)
[bug] incremental backup: React empty-string prop error
[bug] backup size shown as 0
[bug] backup restore returns "operation failed"
[bug] auth/setup: rate_limit hit when weak password retry fixed
```

---

## 6. 你 fork 的实际工作流

### 安装（你已跑过成功）
```bash
# LiteHttpd yum 源（自己看 setup.sh 再跑）
curl -sSL https://rpms.litehttpd.com/setup.sh > /tmp/lh-setup.sh
less /tmp/lh-setup.sh
bash /tmp/lh-setup.sh

# 干净重装
sudo rm -rf /opt/llstack /opt/llstack-panel
id llstack 2>/dev/null && sudo userdel llstack

# 跑最新 install（用分支名，最不易错）
LLSTACK_REPO=https://github.com/ylx2016/LLStack \
LLSTACK_COMMIT=fix/supply-chain \
LLSTACK_SKIP_LITEHTTPD_REPO=1 \
bash <(curl -sSL https://raw.githubusercontent.com/ylx2016/LLStack/fix/supply-chain/scripts/install.sh)
```

### 重装（已装过后想重跑）
```bash
# 直接跑就行 — 5/8 步会秒过（already_installed:true）
# 想强制重装某个组件：
/opt/llstack/scripts/php/php-install.sh --version 85 --force
/opt/llstack/scripts/db/db-install-mariadb.sh --version 10.11 --force
/opt/llstack/scripts/adminer-install.sh --force
```

### 推送 / 拿最新
```bash
git -c http.proxy=socks5://127.0.0.1:7890 fetch origin fix/supply-chain
git checkout fix/supply-chain
git pull
# 重新跑 install.sh，会自动 fetch 最新代码
```

### smoke
```bash
cd /z/t/   # Windows
PATH="/usr/local/bin:/tmp/smoke/bin:/usr/bin:/bin" bash smoke.sh
```

---

## 7. 上游 PR 计划

两条独立 PR（互不阻塞）：

### PR 1: `fix/security-hardening` → `web-casa/LLStack:main`
- 17 commits，~70 文件
- 内容：脚本 bug 修复（参数校验、JSON 转义、dnf5、mktemp、trap、错误检查）
- 不引入任何新文件，不改任何依赖
- 风险低，纯内部修复

### PR 2: `fix/supply-chain` → `web-casa/LLStack:main`
- 9 commits
- 内容：install 流程的 supply-chain + UX 改进（env override、commit pin、LLSTACK_SKIP_LITEHTTPD_REPO、idempotency、adminer 装、cd /tmp、SSL/Redis 兼容）
- **风险中**：改了 install.sh 主流程，upstream 可能希望保持原样
- 建议：等用户试过没问题后提

**步骤**：
```bash
# 1. fast-forward security-hardening 到 supply-chain
git checkout fix/security-hardening
git merge --ff-only fix/supply-chain
git push origin fix/security-hardening

# 2. 两个 PR：
#    - web UI 上：Compare & pull request → base: web-casa/main
#    - 分别选 fix/security-hardening 和 fix/supply-chain
```

---

## 8. 我审了但**故意没改**的（小风险，没收益）

- `2>/dev/null || true` 在清理路径（`DROP USER IF EXISTS`、`dnf config-manager` 不可用等）—— 这些是 best-effort cleanup，失败不应该 fail 整个 install
- `cat << EOF` 中嵌入系统控制变量（不是用户控制）—— 风险低
- `monitoring/sysinfo.sh` 里 90+ 行的 CPU/disk/load 统计 —— 都不接受用户输入

---

## 9. 仍未做（如果你明天想继续）

按 ROI 排：

1. **把 `fix/supply-chain` 合并回 `fix/security-hardening`**（让那个分支也带 install bug 修复）
2. **给 upstream 开两个 PR**（上面 §7）
3. **重整 commit**：当前 9 个 fix/supply-chain commit 里有 2 个 commit 是修 smoke 测试的（`510c687`），可以 squash 进功能 commit
4. **加更多 smoke 覆盖**：`site-clone.sh` 端到端、`wp-smart-update.sh` 真实 wp-cli 测试、LiteHttpd vhost 配置测试
5. **重看一次 site-clone.sh** —— 之前审计标了一些 risk 但没修

---

## 10. 关键文件位置速查

| 用途 | 路径 |
|---|---|
| 远端 fork | `https://github.com/ylx2016/LLStack` |
| 主分支 | `main`（upstream v0.8.8，未动） |
| bug 修复分支 | `fix/security-hardening`（17 commits） |
| install 流程修复分支 | `fix/supply-chain`（9 commits，最新最完整） |
| 本地工作树 | `Z:\t` |
| 脚本目录 | `Z:\t\LLStack-main\scripts\` |
| 后端（闭源）| `Z:\t\LLStack-main\backend\app.cpython-312-x86_64-linux-gnu.so` |
| Smoke harness | `Z:\t\smoke.sh`（也 push 到 `smoke-app-install.sh`） |
| 上一轮总结 | `Z:\t\_prev_state.txt`、`Z:\t\_prev_tasks.txt`（自动保存） |

---

## 11. 远端最新 commit

```
$ git -c http.proxy=socks5://127.0.0.1:7890 ls-remote https://github.com/ylx2016/LLStack.git refs/heads/fix/supply-chain
44b7d9e9d8b3...   refs/heads/fix/supply-chain
```

SHA = `44b7d9e`。任何时候用这个 SHA 都能装到最新版本。
