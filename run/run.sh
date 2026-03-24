#!/bin/bash

spdk_home="/root/spdk-git/"

set -e  # 出错时退出

echo "=== Starting NVMe-oF Target ==="

# 🎯 设置大页数量为 4096
echo "Setting HugePages to 4096..."
CURRENT_HUGEPAGES=$(cat /proc/sys/vm/nr_hugepages)
if [ "$CURRENT_HUGEPAGES" -ne "4096" ]; then
    echo "  Current: $CURRENT_HUGEPAGES, setting to 4096..."
    echo 4096 > /proc/sys/vm/nr_hugepages
    sleep 1
else
    echo "  HugePages already set to 4096"
fi

# 验证大页设置
TOTAL_HUGE=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
FREE_HUGE=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages)
echo "  HugePages: $FREE_HUGE free / $TOTAL_HUGE total"

# 检查配置文件
if [ ! -f "target_config.json" ]; then
    echo "Error: target_config.json not found!"
    exit 1
fi

# 检查可执行文件
if [ ! -x "${spdk_home}/build/bin/nvmf_tgt" ]; then
    echo "Error: nvmf_tgt not found or not executable!"
    exit 1
fi

# 清理旧的 target 进程
if pgrep -f nvmf_tgt > /dev/null; then
    echo "Stopping existing nvmf_tgt process..."
    sudo pkill -f nvmf_tgt
    sleep 3
fi

echo "Setup spdk env..."
${spdk_home}/scripts/setup.sh

# ✅ 使用 named pipe 或临时文件来获取退出状态
# 启动 target 并监控其状态
echo "Starting nvmf_tgt..."
${spdk_home}/build/bin/nvmf_tgt -c target_config.json > spdk.log 2>&1 &
TGT_PID=$!

# 等待 target 初始化并监控进程状态
echo "Waiting for target to initialize..."
MAX_WAIT=30
START_TIME=$(date +%s)

while true; do
    # 检查进程是否还在运行
    if ! kill -0 $TGT_PID 2>/dev/null; then
        # 进程已退出，检查退出码
        wait $TGT_PID
        EXIT_CODE=$?
        echo "Error: nvmf_tgt exited with code $EXIT_CODE during startup!"
        exit $EXIT_CODE
    fi
    
    # 检查日志中是否有成功标志
    if grep -q "NUVCODER CODEC WARMUP COMPLETE" spdk.log 2>/dev/null; then
        echo "Target started successfully!"
        break
    fi
    
    # 检查是否有错误标志 - 预热失败
    if grep -q "Encoder warmup failed" spdk.log 2>/dev/null; then
        echo "Error: Encoder warmup failed!"
        kill $TGT_PID
        exit 1
    fi
    
    # 检查是否有错误标志 - 解码器预热失败
    if grep -q "Decoder warmup failed" spdk.log 2>/dev/null; then
        echo "Error: Decoder warmup failed!"
        kill $TGT_PID
        exit 1
    fi
    
    # 检查是否有错误标志 - 通用错误
    if grep -q "FATAL ERROR" spdk.log 2>/dev/null; then
        echo "Error: Fatal error detected in nvmf_tgt!"
        kill $TGT_PID
        exit 1
    fi
    
    # 超时检查
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    if [ $ELAPSED -gt $MAX_WAIT ]; then
        echo "Error: Target startup timeout after ${MAX_WAIT}s!"
        kill $TGT_PID
        exit 1
    fi
    
    sleep 1
done

# 再次确认进程仍在运行
if ! kill -0 $TGT_PID 2>/dev/null; then
    echo "Error: Target died after appearing to start!"
    exit 1
fi

# 运行 Python 脚本
echo "Running manual_setup.py..."
if python manual_setup.py; then
    echo "Setup completed successfully!"
else
    echo "Error: manual_setup.py failed!"
    kill $TGT_PID
    exit 1
fi

echo ""
echo "=== All Done ==="
echo "Target PID: $TGT_PID"
echo "Log file: spdk.log"
echo ""
echo "To monitor: tail -f spdk.log"
echo "To stop: bash stop.sh"