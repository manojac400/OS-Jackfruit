#!/bin/bash
cd ~/OS-Jackfruit/boilerplate

echo "=== CLEAN START ==="
sudo killall -9 engine 2>/dev/null
sudo pkill -9 -f engine 2>/dev/null
sudo rmmod monitor 2>/dev/null
sudo rm -f /tmp/mini_runtime.sock 2>/dev/null
sudo rm -rf logs 2>/dev/null
sleep 2

echo "=== BUILDING ==="
make clean > /dev/null 2>&1
make all > /dev/null 2>&1
echo "Build complete"

echo "=== LOADING MODULE ==="
sudo insmod monitor.ko
echo "Module loaded"

echo "=== STARTING SUPERVISOR (FOREGROUND IN BACKGROUND) ==="
sudo ./engine supervisor ../rootfs-base &
SUPER_PID=$!
echo "Supervisor PID: $SUPER_PID"
sleep 3

echo "=== CREATING LOGS DIRECTORY ==="
mkdir -p logs
chmod 777 logs

echo "=== TEST 1: Simple echo container ==="
sudo ./engine start test1 ../rootfs-alpha "/bin/echo 'Hello World'" --soft-mib 50 --hard-mib 100

echo "Waiting 2 seconds..."
sleep 2

echo ""
echo "=== CHECKING LOGS ==="
ls -la logs/
if [ -f logs/test1.log ]; then
    echo "--- test1.log content ---"
    cat logs/test1.log
else
    echo "No test1.log found"
fi

echo ""
echo "=== TEST 2: Another echo container ==="
sudo ./engine start test2 ../rootfs-beta "/bin/echo 'Second message'" --soft-mib 50 --hard-mib 100

sleep 2
echo ""
echo "=== LOGS AFTER TEST2 ==="
ls -la logs/
for f in logs/*.log; do
    if [ -f "$f" ]; then
        echo "--- $(basename $f) ---"
        cat "$f"
    fi
done

echo ""
echo "=== LISTING CONTAINERS ==="
sudo ./engine ps

echo ""
echo "=== CLEANUP ==="
sudo ./engine stop test1 2>/dev/null
sudo ./engine stop test2 2>/dev/null
sleep 1
sudo kill $SUPER_PID 2>/dev/null
sleep 1
sudo rmmod monitor 2>/dev/null
sudo rm -f /tmp/mini_runtime.sock 2>/dev/null

echo "=== DONE ==="
