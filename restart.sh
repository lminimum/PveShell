#!/bin/bash
# 功能：每天建新快照删两天前快照；每星期一建新快照删上上星期一快照；每月1号建新快照删上上月1号快照
# 并重启虚拟机，若无法启动则回滚到上一个快照，直到虚拟机成功启动

# TODO 列出要保存快照的QVMIDs
qvmids=(100)
# 日志文件
LOG_FILE="/var/log/restart_vm_with_snapshot.log"
# 最大回滚重试次数
MAX_RETRY=3

# 获取当前时间戳
timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

# 统一日志输出
log() {
    local level=$1
    local vmid=$2
    local message=$3
    echo "[$(timestamp)] [VM ${vmid}] [${level}] ${message}" >> "$LOG_FILE"
}

# 获取日期
current_date=$(date +%Y%m%d)
two_days_ago=$(date -d "2 days ago" +%Y%m%d)
last_last_monday=$(date -d "last Monday -1 week" +%Y%m%d)
last_last_month_first=$(date -d "$(date +%Y%m01) -2 months" +%Y%m%d)
last_month_first=$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m-%d)
PATH=$PATH:/usr/sbin/

# 创建快照并管理过期快照
manage_snapshot() {
    id=$1
    log "INFO" "$id" "开始管理快照"
    # 每日快照
    if ! qm listsnapshot $id | grep -q "daily-${current_date}"; then
        qm snapshot $id "daily-${current_date}"
        log "SUCCESS" "$id" "创建快照 daily-${current_date}"
    fi
    if qm listsnapshot $id | grep -q "daily-${two_days_ago}"; then
        qm delsnapshot $id "daily-${two_days_ago}"
        log "SUCCESS" "$id" "删除过期快照 daily-${two_days_ago}"
    fi

    # 每周快照
    if [ "$(date +%u)" -eq 1 ]; then
        if ! qm listsnapshot $id | grep -q "weekly-${current_date}"; then
            qm snapshot $id "weekly-${current_date}"
            log "SUCCESS" "$id" "创建快照 weekly-${current_date}"
        fi
        if qm listsnapshot $id | grep -q "weekly-${last_last_monday}"; then
            qm delsnapshot $id "weekly-${last_last_monday}"
            log "SUCCESS" "$id" "删除过期快照 weekly-${last_last_monday}"
        fi
    fi

    # 每月快照
    if [ "$(date +%d)" -eq 01 ]; then
        if ! qm listsnapshot $id | grep -q "monthly-${current_date}"; then
            qm snapshot $id "monthly-${current_date}"
            log "SUCCESS" "$id" "创建快照 monthly-${current_date}"
        fi
        if qm listsnapshot $id | grep -q "monthly-${last_last_month_first}"; then
            qm delsnapshot $id "monthly-${last_last_month_first}"
            log "SUCCESS" "$id" "删除过期快照 monthly-${last_last_month_first}"
        fi
    fi

    # 删除早于上个月1号的快照
    snapshots_to_delete=$(qm listsnapshot $id | grep -E 'daily|monthly|weekly' | awk -v last_month_first="$last_month_first" '$3 < last_month_first {print $2}')
    for snapshot in $snapshots_to_delete; do
        qm delsnapshot $id "$snapshot"
        log "SUCCESS" "$id" "删除僵尸快照 ${snapshot}"
    done
    log "INFO" "$id" "快照管理完成"
}

# 回滚到最近快照
rollback_to_snapshot() {
    local id=$1
    log "ERROR" "$id" "启动失败，尝试回滚到最近快照"

    latest_snapshot=$(qm listsnapshot $id | grep -E 'daily|weekly|monthly' | tail -n 1 | awk '{print $2}')
    if [ -n "$latest_snapshot" ]; then
        qm rollback $id "$latest_snapshot"
        log "SUCCESS" "$id" "回滚到快照 ${latest_snapshot}"
        return 0
    else
        log "ERROR" "$id" "未找到可用快照，回滚失败"
        return 1
    fi
}

# 重启虚拟机，检测失败则回滚
restart_vm() {
    local id=$1
    local retry_count=0
    log "INFO" "$id" "开始重启虚拟机"

    qm shutdown $id --timeout 60
    sleep 5

    if ! qm status $id | grep -q "stopped"; then
        log "INFO" "$id" "未优雅关机，强制停止"
        qm stop $id
    fi

    while [ $retry_count -lt $MAX_RETRY ]; do
        qm start $id
        sleep 10

        if qm status $id | grep -q "running"; then
            log "SUCCESS" "$id" "虚拟机启动成功"
            return
        else
            log "ERROR" "$id" "虚拟机启动失败，开始回滚 (尝试次数: $((retry_count + 1)))"
            rollback_to_snapshot $id
            ((retry_count++))
        fi
    done

    log "ERROR" "$id" "虚拟机启动失败，重试 ${MAX_RETRY} 次后放弃"
}

log "INFO" "ALL" "开始执行批量虚拟机快照管理与重启任务"
for qvmid in "${qvmids[@]}"; do
    manage_snapshot "$qvmid"
    restart_vm "$qvmid"
done
log "INFO" "ALL" "任务执行完成"
