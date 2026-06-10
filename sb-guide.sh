--- a/sb-guide.sh
+++ b/sb-guide.sh
@@ -25,7 +25,7 @@
 
 set -u
 
-VERSION="3.0.3-upstream-clean"
+VERSION="3.0.4-upstream-clean"
 OFFICIAL_SCRIPT_URL="${OFFICIAL_SCRIPT_URL:-https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh}"
 OFFICIAL_CONFIG_URL="${OFFICIAL_CONFIG_URL:-https://raw.githubusercontent.com/fscarmen/sing-box/main/config.conf}"
 WORK_DIR="${WORK_DIR:-/root/.sb-guide}"
@@ -1636,38 +1636,214 @@
   warn "脚本不能突破商家端口限速、CPU 配额、共享带宽或线路本身的物理上限。"
 }
 
+detect_install_state() {
+  INSTALL_STATE="absent"
+  INSTALL_EVIDENCE=""
+
+  if has sb; then
+    INSTALL_STATE="complete"
+    INSTALL_EVIDENCE="${INSTALL_EVIDENCE} sb-command"
+  fi
+
+  if find_singbox_binary >/dev/null 2>&1; then
+    [ "$INSTALL_STATE" = "complete" ] || INSTALL_STATE="partial"
+    INSTALL_EVIDENCE="${INSTALL_EVIDENCE} sing-box-binary"
+  fi
+
+  if [ -f /etc/init.d/sing-box ] ||
+     [ -f /etc/systemd/system/sing-box.service ] ||
+     [ -f /usr/lib/systemd/system/sing-box.service ] ||
+     [ -f /lib/systemd/system/sing-box.service ]; then
+    [ "$INSTALL_STATE" = "complete" ] || INSTALL_STATE="partial"
+    INSTALL_EVIDENCE="${INSTALL_EVIDENCE} service-file"
+  fi
+
+  if [ -d /etc/sing-box ]; then
+    [ "$INSTALL_STATE" = "complete" ] || INSTALL_STATE="partial"
+    INSTALL_EVIDENCE="${INSTALL_EVIDENCE} /etc/sing-box"
+  fi
+
+  if has sb && find_singbox_binary >/dev/null 2>&1; then
+    INSTALL_STATE="complete"
+  fi
+}
+
+show_install_residue() {
+  say
+  say "------------- 安装状态诊断 -------------"
+  say "状态：$INSTALL_STATE"
+  say "依据：${INSTALL_EVIDENCE:-无}"
+
+  for path in \
+    /usr/bin/sb \
+    /usr/local/bin/sb \
+    /etc/init.d/sing-box \
+    /etc/systemd/system/sing-box.service \
+    /usr/lib/systemd/system/sing-box.service \
+    /lib/systemd/system/sing-box.service \
+    /etc/sing-box
+  do
+    if [ -e "$path" ] || [ -L "$path" ]; then
+      ls -ld "$path" 2>/dev/null || true
+    fi
+  done
+
+  if has pgrep; then
+    pgrep -a -x sing-box 2>/dev/null || true
+  else
+    ps 2>/dev/null | grep '[s]ing-box' || true
+  fi
+  say "----------------------------------------"
+}
+
+backup_and_clear_partial_install() {
+  stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || printf 'unknown-time')"
+  recovery_dir="${WORK_DIR}/recovery/${stamp}"
+  mkdir -p "$recovery_dir" ||
+    die "无法创建残留备份目录：$recovery_dir"
+  chmod 700 "$recovery_dir" 2>/dev/null || true
+
+  info "停止可能残留的 sing-box 服务/进程。"
+  if has rc-service; then
+    rc-service sing-box stop >/dev/null 2>&1 || true
+  fi
+  if has rc-update; then
+    rc-update del sing-box default >/dev/null 2>&1 || true
+  fi
+  if has systemctl; then
+    systemctl stop sing-box >/dev/null 2>&1 || true
+    systemctl disable sing-box >/dev/null 2>&1 || true
+  fi
+  if has pkill; then
+    pkill -TERM -x sing-box >/dev/null 2>&1 || true
+    sleep 1
+  fi
+
+  moved=0
+  for path in \
+    /etc/sing-box \
+    /etc/init.d/sing-box \
+    /etc/conf.d/sing-box \
+    /usr/bin/sb \
+    /usr/local/bin/sb \
+    /etc/systemd/system/sing-box.service \
+    /etc/systemd/system/sing-box.service.d \
+    /usr/lib/systemd/system/sing-box.service \
+    /lib/systemd/system/sing-box.service
+  do
+    if [ -e "$path" ] || [ -L "$path" ]; then
+      safe_name="$(printf '%s' "$path" | sed 's|^/||; s|/|__|g')"
+      mv "$path" "${recovery_dir}/${safe_name}" ||
+        die "无法备份残留路径：$path"
+      info "已备份：$path"
+      moved=$((moved + 1))
+    fi
+  done
+
+  # Remove stale OpenRC runlevel symlinks that may remain after a broken install.
+  for link in /etc/runlevels/*/sing-box; do
+    [ -e "$link" ] || [ -L "$link" ] || continue
+    safe_name="$(printf '%s' "$link" | sed 's|^/||; s|/|__|g')"
+    mv "$link" "${recovery_dir}/${safe_name}" 2>/dev/null || rm -f "$link"
+    moved=$((moved + 1))
+  done
+
+  if has systemctl; then
+    systemctl daemon-reload >/dev/null 2>&1 || true
+  fi
+
+  # Refresh the current shell's command cache where supported.
+  hash -r 2>/dev/null || true
+
+  if [ "$moved" -gt 0 ]; then
+    ok "残留文件没有删除，已集中备份到：$recovery_dir"
+  else
+    info "未发现需要移动的残留文件。"
+  fi
+
+  detect_install_state
+  if [ "$INSTALL_STATE" != "absent" ]; then
+    show_install_residue
+    die "清理后仍检测到 sing-box 安装痕迹，请人工检查后重试。"
+  fi
+}
+
 handle_existing_install() {
-  if has sb || [ -d /etc/sing-box ]; then
-    warn "检测到系统中可能已经安装 sing-box。"
-    say "  1. 只查看节点"
-    say "  2. 只做网络检测/优化"
-    say "  3. 卸载后重新安装"
-    say "  4. 退出"
-
-    existing_choice="$(ask "请选择" "2")"
-    case "$existing_choice" in
-      1)
-        export_nodes
-        exit 0
-        ;;
-      2)
-        network_optimize
-        exit 0
-        ;;
-      3)
-        confirm "重新安装会删除现有节点配置，确认继续？" "n" ||
-          die "用户取消。"
-        if has sb; then
+  detect_install_state
+
+  case "$INSTALL_STATE" in
+    absent)
+      return 0
+      ;;
+    complete)
+      warn "检测到完整的 sing-box 安装。"
+      say "  1. 只查看节点"
+      say "  2. 只做网络检测/优化"
+      say "  3. 使用原版 sb -u 卸载后重新安装"
+      say "  4. 查看安装状态"
+      say "  5. 退出"
+
+      existing_choice="$(ask "请选择" "2")"
+      case "$existing_choice" in
+        1)
+          export_nodes
+          exit 0
+          ;;
+        2)
+          choose_transport_mode
+          network_optimize
+          exit 0
+          ;;
+        3)
+          confirm "将调用现有原版 sb -u 卸载；确认继续？" "n" ||
+            die "用户取消。"
           sb -u
-        else
-          die "找不到 sb 管理命令，请先手动备份/卸载。"
-        fi
-        ;;
-      *)
-        exit 0
-        ;;
-    esac
-  fi
+          hash -r 2>/dev/null || true
+          detect_install_state
+          if [ "$INSTALL_STATE" != "absent" ]; then
+            warn "原版卸载后仍有残留，将先备份残留再继续。"
+            backup_and_clear_partial_install
+          fi
+          ;;
+        4)
+          show_install_residue
+          exit 0
+          ;;
+        *)
+          exit 0
+          ;;
+      esac
+      ;;
+    partial)
+      warn "检测到不完整/残留的 sing-box 安装。"
+      say "这通常表示配置目录、二进制或服务文件只剩下一部分。"
+      say "  1. 查看残留详情"
+      say "  2. 备份残留后继续全新安装"
+      say "  3. 只做网络检测/优化"
+      say "  4. 退出"
+
+      existing_choice="$(ask "请选择" "1")"
+      case "$existing_choice" in
+        1)
+          show_install_residue
+          exit 0
+          ;;
+        2)
+          confirm "残留将移动到恢复目录，不会直接删除；确认继续？" "y" ||
+            die "用户取消。"
+          backup_and_clear_partial_install
+          ;;
+        3)
+          choose_transport_mode
+          network_optimize
+          exit 0
+          ;;
+        *)
+          exit 0
+          ;;
+      esac
+      ;;
+  esac
 }
 
 print_summary() {
@@ -1704,7 +1880,7 @@
       say "  SB_PROFILE=auto|lean|compat|custom|all"
       say "  SB_NAT_LIMITED=true|false"
       say
-      say "安装原则：原样下载并执行官方 sing-box.sh；不对上游源码打补丁。"
+      say "安装原则：原样执行官方 sing-box.sh；残留安装只做外部备份清理，不修改上游源码。"
       exit 0
       ;;
     --auto-tcp|auto-tcp)
@@ -1760,7 +1936,7 @@
       say "  SB_PROFILE=auto|lean|compat|custom|all"
       say "  SB_NAT_LIMITED=true|false"
       say
-      say "安装原则：原样下载并执行官方 sing-box.sh；不对上游源码打补丁。"
+      say "安装原则：原样执行官方 sing-box.sh；残留安装只做外部备份清理，不修改上游源码。"
       exit 0
       ;;
     install|"")
