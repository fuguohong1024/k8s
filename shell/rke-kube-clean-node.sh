#!/bin/bash

####清理安装过k8s的服务器
####运行此脚本必须读懂脚本具体做了什么操作

KUBE_SVC='
kubelet
kube-scheduler
kube-proxy
kube-controller-manager
kube-apiserver
'

for kube_svc in ${KUBE_SVC};
do
  # 停止服务
  if [[ `systemctl is-active ${kube_svc}` == 'active' ]]; then
    systemctl stop ${kube_svc}
  fi
  # 禁止服务开机启动
  if [[ `systemctl is-enabled ${kube_svc}` == 'enabled' ]]; then
    systemctl disable ${kube_svc}
  fi
done

# 停止所有容器
docker stop $(docker ps -aq)

# 删除所有容器
docker rm -f $(docker ps -qa)

# 删除所有容器卷
docker volume rm $(docker volume ls -q)

# 卸载mount目录
for Mount in $(mount | grep tmpfs | grep '/var/lib/kubelet' | awk '{ print $3 }') /var/lib/kubelet /var/lib/rancher;
do
  umount $Mount; 
done

# 备份目录
##mv /etc/kubernetes /etc/kubernetes-bak-$(date +"%Y%m%d%H%M")
##mv /var/lib/etcd /var/lib/etcd-bak-$(date +"%Y%m%d%H%M")
##mv /var/lib/rancher /var/lib/rancher-bak-$(date +"%Y%m%d%H%M")


# 删除残留路径
rm -rf /etc/cni \
    /opt/cni \
    /run/secrets/kubernetes.io \
    /run/calico \
    /var/lib/calico \
    /var/lib/cni \
    /var/lib/kubelet \
    /var/log/containers \
    /var/log/pods \
    /var/run/calico

## 清理网络接口
no_del_net_inter='lo docker0 eth en bond dummy0'

network_interface=`ls /sys/class/net`

for net_inter in $network_interface;
do
  if ! echo "${no_del_net_inter}" | grep -E ${net_inter:0:3}; then
    ip link delete $net_inter
  fi
done


# 清理残留进程
port_list='
80
443
6443
2376
2379
2380
8472
9099
10250
10254
'

for port in $port_list;
do
  Pid=`netstat -atlnup | awk '{if ($4 ~/^.*:'"$port"'$/) print $7}'| awk -F '/' '{print $1}' | grep -v - | sort -rnk2 | uniq`
  if [[ -n $Pid ]]; then
    kill -9 $Pid
  fi
done

kube_pid=`ps -ef | grep -v grep | grep kube | awk '{print $2}'`

if [[ -n $kube_pid ]]; then
  kill -9 $kube_pid
fi

# 清理iptables表
## 注意：如果节点iptables有特殊配置，以下命令请谨慎操作
iptables -F
iptables -X

###清理 ipvs 表 
[ -x /sbin/ipvsadm ] && /sbin/ipvsadm -C

###清理Docker Root Dir
systemctl stop docker

rm -rf /data/docker

systemctl start docker
