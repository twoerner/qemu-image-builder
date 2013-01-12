#!/bin/bash

if [ -z "$BASE" ]; then
	echo "the 'BASE' environment variable needs to be set"
	exit 1
fi
if [ -z "$PROJECT" ]; then
	echo "the 'PROJECT' environment variable needs to be set"
	exit 1
fi

pushd $BASE
	mkdir -p dev etc/init.d proc sys
	cat > etc/init.d/rcS <<EOF
#!/bin/sh
mount -t sysfs sysfs /sys
mount -t proc proc /proc
ifconfig lo 127.0.0.1
ifconfig eth0 192.168.7.21
EOF
	chmod +x etc/init.d/rcS
	cat > etc/passwd <<EOF
root::0:0:root:/:/bin/sh
EOF

popd
