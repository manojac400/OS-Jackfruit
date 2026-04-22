#!/bin/sh
echo "Starting memory hog..."
i=0
while [ $i -lt 100 ]; do
    dd if=/dev/zero of=/tmp/bigfile_$i bs=1M count=10 2>/dev/null
    i=$((i + 1))
    echo "Allocated $((i * 10)) MB"
    sleep 1
done
echo "Memory allocation complete. Sleeping..."
sleep 30
rm -f /tmp/bigfile_*
echo "Done"
