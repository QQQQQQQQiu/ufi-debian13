#!/usr/bin/env python3
"""
=============================================================================
 MSM8916 CPU OPP 超频补丁生成器
=============================================================================
为什么不能手写死数值：
  主线内核里 MSM8916 的电压由 CPR(Core Power Reduction) 驱动按 fuse corner
  动态调节，OPP 节点里的 opp-microvolt / qcom,opp-fuse-level 必须和源码树中
  已有频点的取值方式一致。不同内核版本这两个属性的写法不同，写死就会出错，
  最坏情况是电压不足直接死机或电压过高烧芯片。

所以本脚本的做法是：
  1) 解析 arch/arm64/boot/dts/qcom/msm8916.dtsi 里的 cpu_opp_table
  2) --check 模式：把现有 OPP 表完整打印出来，先看清楚再动手
  3) --apply 模式：克隆「当前最高频点」节点的全部属性，生成目标频点的新节点

用法：
  python3 tools/opp-overclock.py --check --dtsi src/linux/arch/arm64/boot/dts/qcom/msm8916.dtsi
  python3 tools/opp-overclock.py --apply --hz 1401600000 --microvolt 1250000 \
          --dtsi src/linux/arch/arm64/boot/dts/qcom/msm8916.dtsi
=============================================================================
"""
import argparse
import re
import shutil
import sys
from pathlib import Path


def find_opp_table(text: str):
    """定位 cpu_opp_table 节点体"""
    m = re.search(
        r"(\bcpu_opp_table\b\s*:\s*opp-table(?:-cpu)?\s*\{)", text
    ) or re.search(r"(\bopp-table\b\s*\{)", text)
    if not m:
        return None
    start = text.index("{", m.start(1))
    depth, i = 0, start
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return start, i + 1, m.group(1)
        i += 1
    return None


def parse_opps(body: str):
    """返回 [(name, hz, props_dict), ...]，按频率升序"""
    out = []
    # 匹配 opp-xxxx { ... };
    for m in re.finditer(
        r"(opp[\w,-]*)\s*\{(.*?)\n\s*\};", body, re.S
    ):
        name, inner = m.group(1), m.group(2)
        hz = None
        hm = re.search(r"opp-hz\s*=\s*/bits/\s*64\s*<([^>]*)>", inner)
        if hm:
            tok = hm.group(1).strip()
            hz = int(tok, 0) if tok.lower().startswith("0x") else int(tok)
        else:
            hm2 = re.search(r"opp-hz\s*=\s*<([^>]*)>", inner)
            if hm2:
                hz = int(hm2.group(1).strip(), 0)
        if hz is None:
            hm3 = re.search(r"opp-(\d+)\s*$", name)
            if hm3:
                hz = int(hm3.group(1))
        props = {}
        for pm in re.finditer(
            r"([A-Za-z0-9,._-]+)\s*=\s*(/bits/\s*64\s*)?<([^>]*)>", inner
        ):
            props[pm.group(1)] = pm.group(3).strip()
        for pm in re.finditer(
            r"([A-Za-z0-9,._-]+)\s*=\s*\"([^\"]*)\"", inner
        ):
            props[pm.group(1)] = pm.group(2)
        out.append((name, hz, props))
    return sorted([o for o in out if o[1]], key=lambda x: x[1])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dtsi", required=True)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--hz", type=int, default=1401600000)
    ap.add_argument("--microvolt", type=int, default=None,
                    help="覆盖 opp-microvolt；不填则继承最高频点的取值")
    ap.add_argument("--fuse-level", type=int, default=None,
                    help="覆盖 qcom,opp-fuse-level；不填则继承最高频点的取值")
    ap.add_argument("--no-backup", action="store_true")
    a = ap.parse_args()

    p = Path(a.dtsi)
    if not p.is_file():
        sys.exit(f"!! 找不到 {p}")
    text = p.read_text()

    loc = find_opp_table(text)
    if not loc:
        sys.exit("!! 未在 dtsi 中定位到 cpu_opp_table，请确认文件路径与内核版本")
    start, end, header = loc
    body = text[start + 1:end - 1]
    opps = parse_opps(body)

    print(f"==> 文件: {p}")
    print(f"==> OPP 节点: {header}")
    print("==> 现有频点：")
    for name, hz, props in opps:
        mv = props.get("opp-microvolt", "-")
        fl = props.get("qcom,opp-fuse-level", "-")
        print(f"    {hz:>12} Hz  ({hz/1e6:6.2f} MHz)  "
              f"microvolt={mv:<10} fuse-level={fl:<4}  [{name}]")

    if not opps:
        sys.exit("!! 未解析到任何 OPP，请手动检查 dtsi")

    top_name, top_hz, top_props = opps[-1]
    print(f"\n==> 当前最高频点: {top_hz} Hz ({top_hz/1e6:.2f} MHz)  [{top_name}]")

    if a.check:
        print("\n[--check] 只查看，未修改任何文件。")
        return

    if not a.apply:
        print("\n提示：加 --apply 才会写入，加 --check 只看不改。")
        return

    if a.hz <= top_hz:
        print(f"\n!! 目标 {a.hz} Hz 不高于现有最高频点 {top_hz} Hz，无需打补丁。")
        return

    if any(hz == a.hz for _, hz, _ in opps):
        print(f"\n!! {a.hz} Hz 已存在于 OPP 表中，跳过。")
        return

    if not a.no_backup:
        shutil.copy2(p, str(p) + ".orig")
        print(f"==> 已备份 {p} -> {p}.orig")

    # 克隆最高频点属性，构造新节点
    new_props = dict(top_props)
    new_props["opp-hz"] = str(a.hz)
    if a.microvolt is not None:
        new_props["opp-microvolt"] = str(a.microvolt)
    if a.fuse_level is not None:
        new_props["qcom,opp-fuse-level"] = str(a.fuse_level)

    # 插到最高频点节点之后；顺便照抄该节点的前导空白，让缩进保持整齐。
    # 注意：lines 只能构造一次——opp-hz 用 pop 取出，构造两遍会导致
    # 第二遍丢失 opp-hz（pop 已经弹掉了），生成空节点。
    m = re.search(
        r"(?:\n([ \t]*)opp-" + re.escape(str(top_hz)) +
        r"\s*\{.*?\n[ \t]*\};)",
        body, re.S
    )
    if m:
        indent = m.group(1)
        inner = indent + "\t"
    else:
        indent, inner = "\t\t", "\t\t\t"

    lines = [f"{indent}opp-{a.hz} {{"]
    if "opp-hz" in new_props:
        lines.append(f"{inner}opp-hz = /bits/ 64 <{new_props.pop('opp-hz')}>;")
    for k, v in new_props.items():
        lines.append(f"{inner}{k} = <{v}>;")
    lines.append(f"{indent}}};")

    if not m:
        anchor = body.rstrip()
        new_body = anchor + "\n\n" + "\n".join(lines) + "\n"
    else:
        new_body = (body[:m.end()] + "\n\n" + "\n".join(lines)
                    + body[m.end():])

    p.write_text(text[:start + 1] + new_body + text[end - 1:])
    print(f"\n==> 已插入 opp-{a.hz}：")
    print("\n".join(lines))
    print(f"\n==> 写入完成：{p}")

    has_uv = "opp-microvolt" in new_props
    print(f"""
==============================================================================
 接下来的必做检查
 1) 本节点属性来源：克隆自原最高频点 opp-{top_hz}。
    {'  · 含 opp-microvolt，电压已随新节点固定' if has_uv else
     '  · 无 opp-microvolt —— 说明这棵树的电压由 CPR 驱动按 fuse corner 动态算出，'
     '不在设备树里写死。新频点的电压同样是 CPR 外推，没有手动调压的余地。'}
 2) 启动后核对实际频率上限：
      cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
    若不是目标值，多半被 speed-bin / CPR / rpmpd(VDD_APC) 挡住了。
 3) 无 opp-microvolt 时的风险边界：
      CPR 只按出厂 fuse 校准到原最高频点（本树为 {top_hz/1e6:.2f} MHz）。
      超出部分的电压靠驱动外推，跨度越大越可能高负载死机。
      从 {top_hz/1e6:.2f} MHz 起跳：1.2GHz 约 +21%（社区验证可行），
      1.4GHz 约 +40%（激进，需自行承担）。
 4) 随身WiFi 无散热片，长时间满载建议加散热片或限制上限，长期高温缩短寿命。
 5) 若开机死机：进 fastboot 重刷未超频的 boot 分区即可恢复，不伤硬件。
==============================================================================
""")


if __name__ == "__main__":
    main()
