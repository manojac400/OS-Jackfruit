#!/bin/bash
cd ~/OS-Jackfruit/boilerplate

# Clean start
sudo pkill -9 -f engine
sudo rmmod monitor
sudo rm -f /tmp/mini_runtime.sock
sleep 1

# Build
make clean > /dev/null 2>&1
make all > /dev/null 2>&1

# Load module
sudo insmod monitor.ko

# Start supervisor in background
sudo ./engine supervisor ../rootfs-base > /tmp/supervisor.out 2>&1 &
SUPERVISOR_PID=$!
sleep 3

# Create logs directory with proper permissions
sudo mkdir -p logs
sudo chmod 777 logs

# Run a simple echo container
echo "Starting test container..."
sudo ./engine start test1 ../rootfs-alpha "/bin/echo 'Hello from container'" --soft-mib 50 --hard-mib 100

sleep 2

# Check if log file was created
echo ""
echo "Log directory contents:"
ls -la logs/

# Try to read any log files
if [ -f logs/test1.log ]; then
    echo ""
    echo "test1.log contents:"
    cat logs/test1.log
else
    echo ""
    echo "No test1.log found. Checking for any logs:"
    find logs -type f 2>/dev/null
fi

# Cleanup
sudo ./engine stop test1 2>/dev/null
sudo kill $SUPERVISOR_PID
sudo rmmod monitor
sudo rm -f /tmp/mini_runtime.sock

echo ""
echo "Test complete"
