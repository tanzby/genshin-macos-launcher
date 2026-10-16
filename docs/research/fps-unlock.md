# 帧率解锁逆向（Unlocker 2.9.2 p3）

目的：弄清第三方解锁器怎样把原神的帧率上限从 60 提到 120，为本启动器实现帧率解锁提供依据。相关的旧决定见 [hk4e-rules.md](hk4e-rules.md) 的 LCH-033、CFG-019（帧率上限固定为 60，FPS 解锁设置已删除）。

## 结论速览

- 解锁器不改游戏文件。它以挂起状态启动 `YuanShen.exe`，用特征码在内存里找到游戏读取“目标帧率”的那条指令，把这条 `rip` 相对寻址指令改成去读解锁器自己分配的一个 4 字节槽位，再往游戏进程里注入一段 shellcode 和一个线程，每 500 ms 把用户设定的帧率写进这个槽位。
- 改指令这一步不是直接写进去的。解锁器 hook 了游戏 `il2cpp` 段里的一个代码校验函数（源码里叫 `verfiy`，报错字符串里叫 `GIverf`/`GIxv`）。每次游戏调用它，hook 都会先把补丁撤掉，调用原函数，然后再把补丁打回去。校验函数看到的始终是原始代码。
- 写进游戏的值有两道限制：shellcode 把它钳在 240 以内；游戏失去前台时改用 `PowerSaveTarget`（默认 10）。
- shellcode 会检查 ntdll 是否导出 `wine_get_version`。在 Wine 下它直接调 ntdll 导出的 Nt 函数，在 Windows 下改走直接系统调用。也就是说作者考虑过 Wine 环境。
- **对本启动器来说，光解除游戏内上限不够。** 启动配方写死了 `DXMT_CONFIG=d3d11.preferredMaxFrameRate=60;`（`Sources/GenshinCN/GenshinLaunchRecipe.swift:58`），DXMT 会在呈现层再限一次 60。要跑到 120，两处都得改。

## 样本与工具

| 项 | 值 |
|---|---|
| 样本 | `Unlocker_292_p3.exe`，PE32+ x86-64 控制台程序，285 696 字节 |
| SHA-256 | `7972a9e5829d007f2b58c2238a5435a23a541144cfc9cb89197cd6a27689c5b7` |
| PDB 引用 | `Unlocker_292.pdb`，GUID `32d3e3b8-5b74-4754-8bd0-38930143113a` |
| 配置文件 | 同目录 `hoyofps_config.ini`（UTF-16LE，`[Setting]` 节） |
| 上游源码 | [winTEuser/Genshin_StarRail_fps_unlocker](https://github.com/winTEuser/Genshin_StarRail_fps_unlocker)，MIT。字符串、特征码、shellcode 布局都和 `src/main.cpp` 对得上；上游 `main`（2026-10-05）比样本多了两个版本号探测特征码和一个 `GIxv` 备用特征码 |
| 逆向工具 | [morluto/rea](https://github.com/morluto/rea) 6.5.0（npm `rea-agents`），后端 Ghidra 12.1.4 + OpenJDK 21，Linux x86-64；shellcode 用 GNU objdump 反汇编 |

下文地址均为样本的虚拟地址（image base `0x140000000`）。shellcode 偏移相对于注入缓冲区起点。

## 解锁流程

### 1. 启动游戏

主函数 `0x1400094b0`：

1. `0x140008170` 解析命令行（`-genshin`、`-loadlib`、`-enablemobileui`）；`0x140006c20` 读 `hoyofps_config.ini`，游戏路径缺失时从注册表 `Software\miHoYo\HYP\1_2\hk4e_cn` 查找。
2. `0x140003040` 初始化 Nt 函数表；`CreateProcessW` 的地址按位取反后存在 `0x140045e18`。
3. 调用 `CreateProcessW` 时，`dwCreationFlags` 是 `GameProcessPriority` 对应的优先级类再或上 `CREATE_SUSPENDED`（`0x140009940` 处的 `or ecx,0x4`）。游戏主线程这时还没开始跑。

### 2. 在 `.text` 里找特征码

解锁器读出远程主模块的 PE 头和整段 `.text`，然后在本地副本上扫特征码。如果 `YuanShen.exe` 小于 8 MB（旧版布局），改扫 `UnityPlayer.dll`。

| 特征码 | 用途 |
|---|---|
| `66 0F 6E 0D ?? ?? ?? ?? 0F 57 C0 0F 5B C9` | **目标帧率读取点**（`movd xmm1,[rip+X]` → `cvtdq2ps`）。上游注释：5.5 起 |
| `7E 0C E8 …` / `7F 0E E8 …` / `7F 0F 8B 05 …` | 同一用途的旧版本特征码（5.4、3.7–5.3、更早） |
| `C7 44 24 28 00 00 00 80 C7 44 24 20 00 00 00 80 FF 15 …` | `CreateWindowEx(CW_USEDEFAULT…)` 之后保存 HWND 的全局变量，供省电判断前台窗口 |
| `48 83 EC 28 FF D1 31 C0 48 83 C4 28 C3` | 游戏 `.text` 里的 `call rcx` 跳板，用作远程线程的起始地址（找不到就随机挑一个 `FF E1`）。这样线程起点落在游戏模块内 |

解锁器记录的不是帧率变量本身的地址，而是那条指令里 **disp32 字段的地址**（`0x140009cc5`：匹配地址 + 4）。

### 3. 在 `il2cpp` 段里找校验函数

接着读主模块里名为 `il2cpp` 的段（原 `UserAssembly.dll` 合并进来后的段）：

| 特征码 | 用途 |
|---|---|
| `E8 ?? ?? ?? ?? EB 0D 48 89 F1 BA 02 00 00 00 E8 ?? ?? ?? ?? 48 89 F1 31 D2` | 第一个 `call` 的目标就是**代码校验函数**。找不到就报 `GetFunc Fail ! GIxv` 并结束游戏，所以这一项是必需的 |
| `48 89 F1 E8 ?? ?? ?? ?? 8B 3D ?? ?? ?? ?? 48 8B 0D` | 只在 `IsHookGameSet=1` 时用：游戏设置里帧率选项（30/45/60）对应的全局变量 |
| 另外三条 `48 8B 05 …` / `E8 … 80 3D …` | 只在 `-enablemobileui` 时用（`GIui`，切换移动端 UI），与帧率无关 |

### 4. 构造补丁并注入（`0x140008700`）

1. 把 `0x14003dd80` 处 `0x1120` 字节的 shellcode 模板复制到一块 `0x4000` 的缓冲区，填好参数表（见下一节），再用 `NtAllocateVirtualMemory` 在游戏里分配同样大小的内存。
2. **近址槽位（`Base_fps`）**：从 `模块基址 - 0x10000` 开始往低地址逐页尝试 `VirtualAllocEx`，直到分到一页。这一页必须离模块足够近，`rip` 相对的 disp32（±2 GB）才够得着。这一页的首 4 字节就是新的帧率槽位。
3. 读出读取点所在的、按 8 字节对齐的 16 字节作为“原始”副本，复制一份作为“补丁”副本，把补丁副本里的 disp32 改成 `槽位 - disp字段地址 - 4`，两份都存进 shellcode 的补丁表（`+0x2000`）。这时还**没有**写进游戏代码。
4. **hook 校验函数**：读出它开头 16 字节存到 `+0x60`，然后往函数入口写 `FF 25 02 00 00 00 00 00` + 8 字节绝对地址（`jmp [rip+2]` → `shellcode+0x2d0`）。这份 hook 字节同时存到 `+0x70`。
5. 写入 shellcode，用 `VirtualProtectEx` 改成 RWX，再用 `NtCreateThreadEx` 起线程：起点是步骤 2 找到的跳板，参数是 `shellcode+0x1d0`。等 1 秒，检查线程有没有崩。
6. 最后 `ResumeThread` 恢复游戏主线程，把自身进程优先级降到普通。

### 5. shellcode 参数表

| 偏移 | 内容 |
|---|---|
| `+0x00` | 解锁器自己的 PID |
| `+0x08` | 解锁器进程里帧率变量的地址（`0x140044ad0`） |
| `+0x10` | 游戏设置帧率变量地址（仅 `IsHookGameSet`） |
| `+0x18` | 写入目标：Genshin 是近址槽位，StarRail 是帧率变量本身 |
| `+0x20` | 补丁表 `+0x2000`：每项 `0x30` 字节 `{地址, …, 补丁 16B @+0x10, 原始 16B @+0x20}`，以地址 0 结尾 |
| `+0x28` | 校验函数地址 |
| `+0x30` | 帧率过滤回调（省电判断，`+0x560`） |
| `+0x38` | 取反存放的 Nt 函数表指针（由 `+0x720` 填） |
| `+0x60` / `+0x70` | 校验函数的原始 16 字节 / hook 16 字节 |
| `+0x80..+0x90` | `MessageBoxA`、`CloseHandle`、`GetForegroundWindow`（系统 DLL 在两个进程里基址相同） |
| `+0x150` / `+0x158` | 指令立即数，分别写入 `GenShinTarget60`、`GenShinTarget30` |
| `+0x18a` | `AutoExit=1` 时改成 `EB 3A`，解锁器退出后不再弹 “Sync failed!” |
| `+0x570` / `+0x57c` | HWND 全局变量地址 / `PowerSaveTarget` |

### 6. shellcode 运行时

- `+0x1d0` 入口：调 `+0x720` 解析 ntdll。它沿 PEB 的模块链表找到 ntdll，用取反的字符串按名字查导出表，查的是 `wine_get_version`、`NtAllocateVirtualMemory`、`NtFreeVirtualMemory`、`NtReadVirtualMemory`、`NtProtectVirtualMemory`、`NtOpenProcess`、`NtDelayExecution`。`wine_get_version` 存在时直接用导出函数，否则从函数桩里取出系统调用号，自己生成 syscall 桩。然后把自身改成 RX，进入同步循环。
- `+0xa0` 同步循环：
  1. 用 `NtOpenProcess(PROCESS_ALL_ACCESS)` 打开解锁器进程。
  2. 每轮用 `NtReadVirtualMemory` 读出解锁器里的帧率值（4 字节）。读失败（解锁器已退出）就关句柄、弹一次错误框，之后一直沿用最后一次的值。
  3. `+0x130` 加工这个值：如果开了 `IsHookGameSet`，游戏设置为 30 时取 `GenShinTarget30`，为 45 时取用户值，为其他值时取 `GenShinTarget60`。再经过 `+0x560`：游戏窗口不在前台就返回 `PowerSaveTarget`。最后 `cmp ecx,0xf0; cmova ecx,edx`，**钳到 240**。
  4. 写进 `+0x18` 指向的槽位，用 `NtDelayExecution` 睡 500 ms。
- `+0x2d0` 校验函数 hook：
  1. 把补丁表每一项的读取点改成 RWX，写回**原始**字节。
  2. 把校验函数开头恢复成原始 16 字节，用原参数调用它并保存返回值，然后重新写回 hook 字节。
  3. 把补丁表每一项写回**补丁**字节，再改回 RX，返回原函数的返回值。

  所以第一次调用校验函数之前，读取点还是原样。之后除了校验期间，读取点一直指向槽位。

### 7. 解锁器前台

`ResumeThread` 之后，主线程每 50 ms 轮询一次方向键：↑/↓ ±20，←/→ ±2，范围 10–1000。`IsAntiMisscontact=1` 时只在控制台窗口位于前台时响应。帧率值变化后写回 ini。另有一个线程在控制台刷新状态行 `FPS: %d - Normal/Low power state`。游戏退出后解锁器跟着退出。

## 配置项对照（`hoyofps_config.ini`）

| 键 | 全局变量 | 作用 |
|---|---|---|
| `FPS` | `0x140044ad0` | 目标帧率，读入时上限 1000；shellcode 写入时再钳到 240 |
| `PowerSaveTarget` | `0x140044ac8` | 失去前台时的帧率，默认 10 |
| `IsHookGameSet` | `0x140045e10` | 把游戏设置里的 30/60 档映射到下面两个值 |
| `GenShinTarget30` / `GenShinTarget60` | `0x140044acc` / `0x140044ad4` | 上述映射的目标值 |
| `AutoExit` | `0x140045e12` | 注入后解锁器立即退出（之后游戏帧率固定为退出前的值） |
| `IsAntiMisscontact` | `0x140044ac6` | 只在控制台位于前台时响应方向键 |
| `EnableErrorMsg` | `0x140044ac5` | 解锁器自身的错误弹窗 |
| `GameProcessPriority` | `0x140044ac7` | 游戏进程优先级类 |

## 对本启动器的含义

1. **DXMT 上限必须一起改。** 现在固定是 `d3d11.preferredMaxFrameRate=60`（LCH-033；`Tests/GenshinCNTests/GenshinLaunchRecipeTests.swift` 的 `CFG_019_…` 断言了它）。解锁游戏内上限之后，这里还要改成目标值（如 120）。测试 `CFG_019_noFpsSettingExists` 和 `AppSourceTests` 里“不得出现 fps”的断言也要随新决定一起修改。
2. **可选的实现路线**（都需要先在真机上验证，按 AGENTS.md 用限时的文本输出确认，结束后关闭游戏）：
   - **A. 让 Wine 直接跑这个解锁器**，由它拉起 `YuanShen.exe`。改动最小，shellcode 也支持 Wine。代价是要分发第三方二进制，而且游戏一更新特征码就可能失效。还有一点待验证：游戏变成解锁器的子进程之后，`wine-shim` 还能不能按 `GENSHIN_LAUNCHER_GAME_HOST_MATCH` 认出它（Game Mode、原生全屏都依赖这一步）。
   - **B. 自己写一个 Windows x86-64 helper**（像 `Helpers/turner.c` 那样用 llvm-mingw 编译），只实现必要的部分：挂起启动、扫两个特征码（读取点和校验函数）、近址槽位、校验 hook。帧率固定不变时不需要跨进程同步线程，启动前用 `WriteProcessMemory` 把 120 写进槽位就够了。不需要省电、热键和移动端 UI。上游是 MIT，可以参考。
   - **C. 放进 `gamehost.c`**。它通过 `DYLD_INSERT_LIBRARIES` 注入游戏的 Wine 宿主进程，和 PE 代码共用一个地址空间，所以能直接改内存，不需要新的外部进程。难点在时机：要在 `YuanShen.exe` 映射之后、校验函数第一次运行之前装好 hook，还要在 Unix 侧操作 PE 内存。
3. **风险**：这类修改违反游戏条款，存在封号风险。特征码依赖游戏版本，每次大版本都可能需要更新（样本对新版本会报 `Genshin Pattern Outdated!`）。上限 240 是解锁器自己加的，与 120 的目标无关。

## 复现

```bash
npm install --global rea-agents          # rea 6.5.0
# Ghidra 12.1.4：ghidra_12.1.4_PUBLIC_20260921.zip，SHA-256 ddac49f9…d4db（与 rea 仓库记录一致）
export GHIDRA_INSTALL_DIR=/abs/ghidra_12.1.4_PUBLIC JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
rea doctor --provider ghidra
rea analyze /abs/Unlocker_292_p3.exe --provider ghidra --json
```

每条 CLI 命令都会重新导入一次（约 40 秒），所以这次用 `rea --mcp` 起 stdio 服务，在同一个会话里依次调用 `open_binary`、`list_strings`、`xrefs`、`resolve_containing_procedure`、`procedure_pseudo_code`。shellcode 模板位于文件偏移 `0x3cd80`，长 `0x1120`，用 `objdump -D -b binary -m i386:x86-64 -M intel` 反汇编。
