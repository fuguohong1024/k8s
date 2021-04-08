#!/bin/bash
#localip=`ip route sh|egrep "^default"|awk '{print $5}'| xargs ip a sh |egrep "^\s+inet\s+"|awk '{print $2}'`
docker_daemon_conf=/etc/docker/daemon.json
sysctl_conf=/etc/sysctl.conf
ipvs_modules=/etc/sysconfig/modules/ipvs.modules
docker_version='19.03.4'
docker_service=/usr/lib/systemd/system/docker.service

### 安装docker docker
[ ! -f /etc/yum.repos.d/docker-ce.repo ] && curl -s -o /etc/yum.repos.d/docker-ce.repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
yum install -y yum-utils device-mapper-persistent-data lvm2 && yum makecache fast

if [ $? -eq 0 ];then
 yum list docker-ce --showduplicates|grep ${docker_version}
 if [ $? -eq 0 ];then
  yum install docker-ce-${docker_version} -y && systemctl enable docker
 fi
fi
[ $? -ne 0 ] && exit 1

####添加账号

useradd rke && usermod -aG docker rke

###加载ipvs modules
cat <<EOF > ${ipvs_modules}
#!/bin/bash
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack
EOF

chmod 0750 ${ipvs_modules} && /bin/bash ${ipvs_modules}



#####内核优化
cat  <<EOE > ${sysctl_conf}
net.bridge.bridge-nf-call-ip6tables=1
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.neigh.default.gc_thresh1=4096
net.ipv4.neigh.default.gc_thresh2=6144
net.ipv4.neigh.default.gc_thresh3=8192
net.ipv4.neigh.default.gc_interval=60
net.ipv4.neigh.default.gc_stale_time=120

# 参考 https://github.com/prometheus/node_exporter#disabled-by-default
kernel.perf_event_paranoid=-1

#sysctls for k8s node config
net.ipv4.tcp_slow_start_after_idle=0
net.core.rmem_max=16777216
fs.inotify.max_user_watches=33554432
kernel.softlockup_all_cpu_backtrace=1

kernel.softlockup_panic=0

kernel.watchdog_thresh=30
fs.file-max=50331648
fs.nr_open = 16777216
fs.inotify.max_user_instances=8192
fs.inotify.max_queued_events=16384
vm.max_map_count=262144
fs.may_detach_mounts=1
net.core.netdev_max_backlog=16384
net.ipv4.tcp_wmem=4096 12582912 16777216
net.core.wmem_max=16777216
net.core.somaxconn=32768
net.ipv4.ip_forward=1
net.ipv4.tcp_max_syn_backlog=8096
net.ipv4.tcp_rmem=4096 12582912 16777216

#net.ipv6.conf.all.disable_ipv6=1
#net.ipv6.conf.default.disable_ipv6=1
#net.ipv6.conf.lo.disable_ipv6=1

kernel.yama.ptrace_scope=0
vm.swappiness=0

# 可以控制core文件的文件名中是否添加pid作为扩展。
kernel.core_uses_pid=1

# Do not accept source routing
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.conf.all.accept_source_route=0

# Promote secondary addresses when the primary address is removed
net.ipv4.conf.default.promote_secondaries=1
net.ipv4.conf.all.promote_secondaries=1

# Enable hard and soft link protection
fs.protected_hardlinks=1
fs.protected_symlinks=1

# 源路由验证
# see details in https://help.aliyun.com/knowledge_detail/39428.html
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce=2
net.ipv4.conf.all.arp_announce=2

# see details in https://help.aliyun.com/knowledge_detail/41334.html
net.ipv4.tcp_max_tw_buckets=20000
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_synack_retries=2
kernel.sysrq=1
EOE

/sbin/sysctl --system


sed -i 's/210000/1100000/g' /etc/security/limits.conf  
sed -i 's/200000/1000000/g' /etc/security/limits.conf 
sed -i 's/210000/1100000/g' /etc/security/limits.d/20-nproc.conf

####修改docker daemon.json
[ ! -d /etc/docker ] && mkdir -p /etc/docker && chmod 0750 /etc/docker

echo "{
  \"oom-score-adjust\": -1000,
  \"registry-mirrors\": [\"https://5twf62k1.mirror.aliyuncs.com\"],
  \"exec-opts\": [\"native.cgroupdriver=systemd\"],
  \"graph\": \"/data/docker\",
  \"log-driver\": \"json-file\",
  \"log-opts\": {
    \"max-size\": \"200m\",
    \"max-file\": \"20\"
  },
  \"max-concurrent-downloads\": 10,
  \"max-concurrent-uploads\": 10,
  \"storage-driver\": \"overlay2\",
  \"storage-opts\": [
  \"overlay2.override_kernel_check=true\"
  ]
}" > ${docker_daemon_conf}


#### 修改 docker.service
echo '
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
BindsTo=containerd.service
After=network-online.target firewalld.service containerd.service
Wants=network-online.target
Requires=docker.socket

[Service]
Type=notify
# the default is not to use systemd for cgroups because the delegate issues still
# exists and systemd currently does not support the cgroup feature set required
# for containers run by docker
ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
## Enable iptables forwarding chain
ExecStartPost=/usr/sbin/iptables -P FORWARD ACCEPT
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutSec=0
RestartSec=2
Restart=always

# Note that StartLimit* options were moved from "Service" to "Unit" in systemd 229.
# Both the old, and new location are accepted by systemd 229 and up, so using the old location
# to make them work for either version of systemd.
StartLimitBurst=3

# Note that StartLimitInterval was renamed to StartLimitIntervalSec in systemd 230.
# Both the old, and new name are accepted by systemd 230 and up, so using the old name to make
# this option work for either version of systemd.
StartLimitInterval=60s

# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity

# Comment TasksMax if your systemd version does not support it.
# Only systemd 226 and above support this option.
TasksMax=infinity

# set delegate yes so that systemd does not reset the cgroups of docker containers
Delegate=yes

# kill only the docker process, not all processes in the cgroup
KillMode=process

[Install]
WantedBy=multi-user.target
' > ${docker_service}



###重启docker 
systemctl daemon-reload && systemctl start docker && systemctl enable docker

