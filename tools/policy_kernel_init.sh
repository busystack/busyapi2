#!/bin/busybox sh
# Test-only initramfs entry. No host mounts or network interfaces are supplied.
/bin/busybox mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
export PATH=/bin
export BUSYAPI_TEST_POLICY_ISOLATION=/policy/policy-isolation.node
export BUSYAPI_TEST_POLICY_LAUNCHER=/policy/policy-launcher
export BUSYAPI_TEST_POLICY_ATTEMPTS=/policy/attempts.node
export BUSYAPI_TEST_POLICY_ENTRY=/policy/policy-worker.cjs
export BUSYAPI_TEST_POLICY_TRANSPORT=/policy/transport.cjs
export BUSYAPI_TEST_POLICY_GOVERNANCE=/policy/governance.cjs
export BUSYAPI_TEST_POLICY_REVIEW=/policy/review.cjs
uname -a
/runtime/node -e 'console.log(JSON.stringify(require(process.env.BUSYAPI_TEST_POLICY_ISOLATION).capabilities()))'
result=$?
for suite in isolation process execution; do
  /runtime/node "/tests/test_policy_$suite.cjs" || result=1
done
if test "$result" = 0; then echo BUSYAPI_KERNEL_TEST_PASS; else echo BUSYAPI_KERNEL_TEST_FAIL; fi
poweroff -f
